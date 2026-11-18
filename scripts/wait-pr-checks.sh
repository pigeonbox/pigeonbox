#!/usr/bin/env bash
#
# 等一个 PR 的 checks 到达**终态**，并给出**可信**的三态结论。
#
# 为什么有这个脚本（2026-11-02 实录）：
#   此前等 CI 的写法是 `sleep 240; gh pr checks <pr> -R <repo> 2>&1`，
#   连踩三个坑：
#
#   ① **退出码 8 = 还在跑**，不是失败（`gh help exit-codes` 明载：8=Checks pending）。
#      `2>&1` 只并流不并码 ⇒ 后台任务被判 "failed" ⇒ **CI 其实绿着却被报成失败**。
#      实录：任务 bg_cd369233 退出码 8，输出里 test 是 pending ⇒ 假红。
#
#   ② **`gh pr checks` 的判绿口径本身是错的**：它按**所有** check run 判定
#      ⇒ 重跑前的失败 attempt 也列进来 ⇒ 最新一次已绿仍整体报失败。
#      仓内 reference 实现（release/trainctl/advance.go 的 checksAllGreenLatest，
#      2026-10-23 实弹：NAS 三仓 lint 重跑绿了、列车仍卡 draft 半天）早就绕开它，
#      改用 `gh pr view --json statusCheckRollup` 并**按检查名取最新一次 attempt**。
#      本脚本与它同一口径 ⇒ 两边不会再「一边说绿、一边说红」。
#
#   ③ **`sleep N` 是猜时长而不是等条件**：CI 5 秒完成也空等 4 分钟；
#      没跑完则只拿到一个**非终态**快照 ⇒ 还得再发一次命令接着猜。
#      本脚本按条件轮询（有 pending 就继续等），直到终态或超时。
#
# 额外处理：
#   · **零检查项 ≠ 就绪**：workflow 还没注册上时 rollup 也是空 ⇒ 空一次先继续等，
#     连续两次空才按「就绪」处理（与 trainctl 的 hasChecks=false 同义，但多防一跳）。
#   · **超时 ≠ 失败**：超时单独用退出码 2，绝不与「有检查失败」混用。
#
# 依赖：gh（带仓库读权限）、jq。
#
# 用法:
#   bash scripts/wait-pr-checks.sh <owner/repo> <pr> [--timeout 30m] [--interval 15s]
#   bash scripts/wait-pr-checks.sh --selfcheck
#
# 退出码（本脚本自有语义，**与 gh 的不同**）:
#   0 = 全绿（所有检查最新一次 attempt 通过）
#   1 = 有检查失败（打印失败的检查名与结论）
#   2 = 超时仍未达终态（**不是失败**）
#   3 = 用法 / 取数错误
set -uo pipefail

# ── shellkit（CI 侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SK_BOOTSTRAP="$HUB_ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

DEFAULT_TIMEOUT="30m"
DEFAULT_INTERVAL="15s"
# 连续多少次「零检查项」才判定为就绪（防 workflow 尚未注册的空快照）
EMPTY_ROUNDS_BEFORE_READY=2

# ───────────────────────── 用法 ─────────────────────────

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/wait-pr-checks.sh <owner/repo> <pr> [--timeout 30m] [--interval 15s]
  bash scripts/wait-pr-checks.sh --selfcheck

退出码（本脚本自有语义，与 gh 的不同）:
  0 = 全绿    1 = 有检查失败    2 = 超时未达终态（不是失败）    3 = 用法 / 取数错误
EOF
}

# ───────────────────────── 参数 ─────────────────────────

# parse_duration 把 "30m"/"90s"/"1h" 解析成秒数；非法输入返回 1。
parse_duration() {
  local d="${1:-}"
  local n u
  case "$d" in
    *s)
      n="${d%s}"
      u=1
      ;;
    *m)
      n="${d%m}"
      u=60
      ;;
    *h)
      n="${d%h}"
      u=3600
      ;;
    *)
      n="$d"
      u=1
      ;;
  esac
  case "$n" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$((n * u))"
}

# ───────────────────────── 判定 ─────────────────────────

# latest_attempts：读入 gh 的 statusCheckRollup JSON（stdin），
# 按「工作流名/检查名」取**最新一次** attempt，输出 TSV：名称<TAB>结论。
#
# 结论取值：SUCCESS / SKIPPED / NEUTRAL = 通过；空串 = 仍在跑；其余 = 失败。
#
# 为什么按最新一次：gh pr checks 按**所有** attempt 判定 ⇒ 重跑前的失败
# attempt 留在列表里 ⇒ 最新一次已绿仍报失败（2026-10-23 实弹，见文件头）。
latest_attempts() {
  jq -r '
	  (if type == "array" then . else (.statusCheckRollup // []) end)
	  | [ .[]
	      | { k: ((.workflowName // "") + "/" + (.name // "")),
	          ts: (.completedAt // .startedAt // ""),
	          c:  (.conclusion // "") } ]
	  | group_by(.k)
	  | map(sort_by(.ts) | last)
	  | sort_by(.k)
	  | .[]
	  | "\(.k)\t\(.c)"
	'
}

# verdict：读入 TSV（stdin），打印结论摘要。
# 返回：0 = 全绿 / 1 = 有失败 / 2 = 仍在跑（pending）/ 3 = 零检查项（就绪）
verdict() {
  local name c
  local n_all=0 n_pending=0 n_failed=0
  local pending_list="" failed_list=""
  # ⚠️ `|| [ -n "$name" ]`：read 遇到 EOF 且无尾换行时**仍赋值但返回 1**
  # ⇒ 只写 `while read` 会把**最后一行**整个丢掉（自证当场抓到：单行 TSV
  # 被判成「零检查项」）⇒ 这里补上尾行处理。
  while IFS=$'\t' read -r name c || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n_all=$((n_all + 1))
    case "$c" in
      SUCCESS | SKIPPED | NEUTRAL) ;;
      '')
        n_pending=$((n_pending + 1))
        pending_list="${pending_list}${pending_list:+, }${name}"
        ;;
      *)
        n_failed=$((n_failed + 1))
        failed_list="${failed_list}${failed_list:+, }${name}(${c})"
        ;;
    esac
  done

  if [ "$n_all" -eq 0 ]; then
    echo "零检查项 ⇒ 按就绪处理（与 trainctl 的 hasChecks=false 同义）"
    return 3
  fi
  if [ "$n_failed" -gt 0 ]; then
    echo "失败 ${n_failed}/${n_all}: ${failed_list}"
    return 1
  fi
  if [ "$n_pending" -gt 0 ]; then
    echo "进行中 ${n_pending}/${n_all}: ${pending_list}"
    return 2
  fi
  echo "全绿 ${n_all}/${n_all}"
  return 0
}

# ───────────────────────── 自证 ─────────────────────────

# selfcheck 用**合成 rollup**（不依赖网络）验证判定逻辑：
#   ① 重跑前的 FAILURE attempt 不得污染判定（取最新一次）
#   ② pending 不得被报成 failed
#   ③ 真失败必须被报成 failed
#   ④ 全绿 / 零检查项各归各位
selfcheck() {
  local fails=0

  # ① 同一检查两次 attempt：先失败后成功 ⇒ 按最新一次 ⇒ 全绿
  local j_retry='{"statusCheckRollup":[
	  {"workflowName":"CI","name":"test","conclusion":"FAILURE","startedAt":"2026-11-01T10:00:00Z","completedAt":"2026-11-01T10:05:00Z"},
	  {"workflowName":"CI","name":"test","conclusion":"SUCCESS","startedAt":"2026-11-01T11:00:00Z","completedAt":"2026-11-01T11:06:00Z"}]}'
  # 负对照：这份 fixture 里**确实**藏着 FAILURE（否则测不出重跑污染）
  case "$j_retry" in
    *FAILURE*) ;;
    *)
      log_error "fixture 失效：未含 FAILURE attempt"
      fails=$((fails + 1))
      ;;
  esac
  local t_retry v_retry rc_retry=0
  t_retry="$(printf '%s' "$j_retry" | latest_attempts)"
  case "$t_retry" in
    *FAILURE*)
      log_error "重跑前的 FAILURE attempt 仍被选中（应取最新一次）"
      fails=$((fails + 1))
      ;;
    *"CI/test	SUCCESS"*) ;;
    *)
      log_error "最新一次 attempt 未被选中：${t_retry:-<空>}"
      fails=$((fails + 1))
      ;;
  esac
  v_retry="$(printf '%s' "$t_retry" | verdict)" || rc_retry=$?
  if [ "$rc_retry" -ne 0 ]; then
    log_error "重跑后已绿却判成非绿（rc=${rc_retry}，${v_retry}）"
    fails=$((fails + 1))
  fi

  # ② pending ⇒ rc=2（在跑），**绝不能**是 1（失败）
  local j_pending='{"statusCheckRollup":[
	  {"workflowName":"CI","name":"gen-drift","conclusion":"SUCCESS","startedAt":"2026-11-01T10:00:00Z","completedAt":"2026-11-01T10:00:12Z"},
	  {"workflowName":"CI","name":"test","conclusion":null,"startedAt":"2026-11-01T11:00:00Z","completedAt":null}]}'
  local rc_pending=0
  printf '%s' "$j_pending" | latest_attempts | verdict >/dev/null || rc_pending=$?
  if [ "$rc_pending" -ne 2 ]; then
    log_error "pending 被判成 rc=${rc_pending}（应为 2=仍在跑，不是 1=失败）"
    fails=$((fails + 1))
  fi

  # ③ 真失败 ⇒ rc=1
  local j_fail='{"statusCheckRollup":[
	  {"workflowName":"CI","name":"test","conclusion":"FAILURE","startedAt":"2026-11-01T11:00:00Z","completedAt":"2026-11-01T11:06:00Z"}]}'
  local rc_fail=0
  printf '%s' "$j_fail" | latest_attempts | verdict >/dev/null || rc_fail=$?
  if [ "$rc_fail" -ne 1 ]; then
    log_error "真失败被判成 rc=${rc_fail}（应为 1）"
    fails=$((fails + 1))
  fi

  # ④ 全绿 ⇒ rc=0；零检查项 ⇒ rc=3（就绪）
  local j_green='{"statusCheckRollup":[
	  {"workflowName":"CI","name":"test","conclusion":"SUCCESS","startedAt":"2026-11-01T11:00:00Z","completedAt":"2026-11-01T11:06:00Z"}]}'
  local rc_green=0
  printf '%s' "$j_green" | latest_attempts | verdict >/dev/null || rc_green=$?
  if [ "$rc_green" -ne 0 ]; then
    log_error "全绿被判成 rc=${rc_green}（应为 0）"
    fails=$((fails + 1))
  fi
  local rc_empty=0
  printf '%s' '{"statusCheckRollup":[]}' | latest_attempts | verdict >/dev/null || rc_empty=$?
  if [ "$rc_empty" -ne 3 ]; then
    log_error "零检查项被判成 rc=${rc_empty}（应为 3=就绪）"
    fails=$((fails + 1))
  fi

  if [ "$fails" -eq 0 ]; then
    log_ok "selfcheck 通过（重跑不污染 / pending≠失败 / 失败可辨 / 全绿 / 零检查项）"
    return 0
  fi
  log_error "selfcheck 失败 ${fails} 项"
  return 1
}

# ───────────────────────── 主流程 ─────────────────────────

main() {
  local selfcheck_mode=0 repo="" pr="" timeout_s="" interval_s=""
  # 参数解析 ⇒ shellkit 的 cli_opt/cli_opts（选项语义、"--opt=value" 写法交给库）。
  # ⚠️ **退出码映射**：cli_opts 的用法错码是 2，本脚本的用法错码是 **3**
  #    （本脚本的 2 = 超时未达终态 ⇒ 两码不能混）⇒ 入口处把 2 映射回 3。
  # ⚠️ 输入面**收窄**一处：原手写解析在 "--timeout" 缺值时静默回落默认值
  #    （拼写错误被当成「没给」）⇒ 现在判用法错退 3。合法调用不受影响。
  cli_opt_init
  cli_opt selfcheck_mode --selfcheck
  cli_opt timeout_s --timeout "" 1
  cli_opt interval_s --interval "" 1
  cli_opts "$@" || {
    usage
    return 3
  }
  # 位置参数（owner/repo 与 pr）——cli_opts 把剩余位置参数留在 SK_OPTS_LEFT
  local pos=0 arg
  for arg in ${SK_OPTS_LEFT[@]+"${SK_OPTS_LEFT[@]}"}; do
    pos=$((pos + 1))
    case "$pos" in
      1) repo="$arg" ;;
      2) pr="$arg" ;;
      *)
        echo "多余参数: ${arg}" >&2
        usage
        return 3
        ;;
    esac
  done

  if [ "$selfcheck_mode" -eq 1 ]; then
    selfcheck
    return $?
  fi

  if [ "$pos" -ne 2 ]; then
    usage
    return 3
  fi

  [ -n "$timeout_s" ] || timeout_s="$DEFAULT_TIMEOUT"
  [ -n "$interval_s" ] || interval_s="$DEFAULT_INTERVAL"
  local tsec isec
  tsec="$(parse_duration "$timeout_s")" || {
    echo "非法 --timeout: ${timeout_s}" >&2
    return 3
  }
  isec="$(parse_duration "$interval_s")" || {
    echo "非法 --interval: ${interval_s}" >&2
    return 3
  }
  if ! command -v gh >/dev/null 2>&1; then
    echo "缺 gh CLI" >&2
    return 3
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "缺 jq" >&2
    return 3
  fi

  local start deadline
  start="$(date +%s)"
  deadline=$((start + tsec))
  local empty_rounds=0

  log_info "等 ${repo}#${pr} 的 checks 终态（超时 ${timeout_s}，间隔 ${interval_s}）"
  while :; do
    local raw rc=0
    raw="$(gh pr view "$pr" -R "$repo" --json statusCheckRollup 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      log_error "取数失败: ${raw}"
      return 3
    fi
    local tsv vstate vrc=0
    tsv="$(printf '%s' "$raw" | latest_attempts)" || {
      log_error "解析 statusCheckRollup 失败"
      return 3
    }
    vstate="$(printf '%s' "$tsv" | verdict)" || vrc=$?
    local now elapsed
    now="$(date +%s)"
    elapsed=$((now - start))
    log_info "[${elapsed}s] ${vstate}"

    case "$vrc" in
      0)
        log_ok "${repo}#${pr} 全绿"
        return 0
        ;;
      1)
        log_error "${repo}#${pr} 有检查失败"
        return 1
        ;;
      2) ;;
      3)
        empty_rounds=$((empty_rounds + 1))
        if [ "$empty_rounds" -ge "$EMPTY_ROUNDS_BEFORE_READY" ]; then
          log_ok "${repo}#${pr} 无检查项 ⇒ 按就绪处理"
          return 0
        fi
        ;;
    esac

    if [ "$now" -ge "$deadline" ]; then
      log_error "超时 ${timeout_s} 仍未达终态（**不是失败**）：${vstate}"
      return 2
    fi
    sleep "$isec"
  done
}

main "$@"
