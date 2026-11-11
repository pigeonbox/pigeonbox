#!/usr/bin/env bash
# CI 健康巡检：把「默认分支红了没人管」变成一个**会自动开/关的 issue**。
#
# 为什么需要（2026-11-07 盘点实录）：
#   · charts「Lint and Test Charts」自 2026-11-03 起**连续 10 次**失败——chart 的
#     kind 真机部署验证事实上停摆 5 天；同期「Release Charts」一直绿，更没人会去看。
#   · 文档站「Deploy Docs Site」自 2026-11-07 起**连续 8 次**失败——站点停在旧内容上。
#   两者都只在 push / repository_dispatch 时触发，没人盯就永远看不见。
#
# 判据（为什么不「红一次就报」）：
#   · 只看**默认分支**；每个工作流只看最近一次运行；queued/in_progress/cancelled 不算红
#   · 报的条件 = 最近一次是 failure **且**（连续失败 ≥ 2 次 **或** 红灯已超 24h）
#     ⇒ 单次抖动不吵人（生态里有已知 flaky），但「红了没人管」必然被抓住
#   · 全绿之后本脚本自己关单——别手工关，关了下次还是红
#   · **巡检自身空转也算失败**（一个仓/工作流都没扫到 ⇒ 直接红），绝不静默通过
#
# 用法：bash scripts/ci-health.sh [--dry-run] [--org pigeonbox] [--repo owner/name]
set -uo pipefail

ORG="pigeonbox"
ISSUE_REPO="pigeonbox/pigeonbox"
ISSUE_TITLE="[CI 健康] 默认分支有红"
DRY_RUN=0
STALE_HOURS=24
STREAK_MIN=2
# 自测用：用本地 JSON 夹具替代 `gh run list`（只允许配 --dry-run，绝不会碰真实 issue）。
FIXTURE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --org)
      ORG="${2:-}"
      shift 2
      ;;
    --repo)
      ISSUE_REPO="${2:-}"
      shift 2
      ;;
    --fixture)
      FIXTURE="${2:-}"
      DRY_RUN=1
      shift 2
      ;;
    *)
      echo "用法: $0 [--dry-run] [--org pigeonbox] [--repo owner/name] [--fixture runs.json]"
      exit 2
      ;;
  esac
done

if [ -n "${FIXTURE}" ] && [ ! -f "${FIXTURE}" ]; then
  echo "✗ 夹具不存在：${FIXTURE}"
  exit 1
fi

command -v gh >/dev/null 2>&1 || {
  echo "✗ 没有 gh CLI——巡检自身失效"
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "✗ 没有 jq——巡检自身失效"
  exit 1
}

NOW=$(date -u +%s)
STALE_BEFORE=$((NOW - STALE_HOURS * 3600))

# 每个工作流只看默认分支最近一次运行，并从最近往回数「连续失败」次数。
# 输入：gh run list --json 的数组；输出：TSV「工作流 / 连续失败次数 / 最近失败时间 / URL」。
# shellcheck disable=SC2016  # 这是 jq 程序，$x 要原样交给 jq，不能让 shell 展开
JQ_STREAK='
  def streak:
    reduce .[] as $x ({n: 0, stop: false};
      if .stop then .
      elif $x.conclusion == "failure" then .n += 1
      else .stop = true end) | .n;
  group_by(.workflowName)
  # ⚠️ 同一秒可能有多条运行（实测 desktop 的 Dependabot Updates 在 2026-11-05T03:54:02Z
  # 同时产生 success 与 failure 两条）⇒ 只按 createdAt 排序时 tie 的顺序不确定，
  # 会把已经开始绿的工作流误判成红。tie 里让「非 failure」排在前面（reverse 后 = 更近）。
  | map(sort_by([.createdAt, (if .conclusion == "failure" then 0 else 1 end)]) | reverse)
  | map({ wf: .[0].workflowName, latest: .[0], streak: streak })
  | map(select(.latest.conclusion == "failure"))
  | .[]
  | [ .wf, (.streak | tostring), .latest.createdAt, .latest.url ] | @tsv
'

# gh 给的 ISO8601（2026-11-07T05:22:15Z）→ epoch；GNU/BSD 两套 date 都试。
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

TMP=$(mktemp)
# 成功哨兵形态（仓内统一口径，见 scripts/check-shell-trap-exit-code.sh）：
# trap 必须**保留退出码**，且「跑完没有显式置 OK=1」也要判失败——否则 bash 3.2 下
# 未定义变量之类的运行期失败会被 EXIT trap 悄悄变成 exit 0（假绿）。
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -f "${TMP}"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

repos=$(gh repo list "${ORG}" --limit 300 --json name,isArchived,defaultBranchRef \
  --jq '.[] | select(.isArchived | not) | .name + " " + (.defaultBranchRef.name // "main")') || {
  echo "✗ 取不到 ${ORG} 的仓清单——巡检自身失效"
  exit 1
}

checked=0
wf_seen=0
reds=""
while read -r repo branch; do
  [ -n "${repo}" ] || continue
  [ -n "${branch}" ] || branch=main
  checked=$((checked + 1))
  if [ -n "${FIXTURE}" ]; then
    cp "${FIXTURE}" "${TMP}"
  elif ! gh run list --repo "${ORG}/${repo}" --branch "${branch}" --limit 80 \
    --json workflowName,conclusion,createdAt,url >"${TMP}" 2>/dev/null; then
    echo "  · ${repo}: 拉不到运行记录（私有/无 Actions/权限不足）⇒ 记为未知，不参与判定"
    continue
  fi
  n=$(jq -r 'group_by(.workflowName) | length' "${TMP}" 2>/dev/null || echo 0)
  wf_seen=$((wf_seen + n))
  rows=$(jq -r "${JQ_STREAK}" "${TMP}" 2>/dev/null || true)
  [ -n "${rows}" ] || continue
  while IFS="$(printf '\t')" read -r wf streak when url; do
    [ -n "${wf}" ] || continue
    reason=""
    if [ "${streak}" -ge "${STREAK_MIN}" ] 2>/dev/null; then
      reason="连续 ${streak} 次失败"
    fi
    ts=$(to_epoch "${when}")
    if [ "${ts}" -gt 0 ] && [ "${ts}" -le "${STALE_BEFORE}" ]; then
      if [ -n "${reason}" ]; then
        reason="${reason}；且已超 ${STALE_HOURS}h 无人处理"
      else
        reason="已超 ${STALE_HOURS}h 无人处理"
      fi
    fi
    [ -n "${reason}" ] || continue # 单次抖动且刚红 ⇒ 这次不吵
    reds="${reds}| \`${repo}\` | ${wf} | ${when} | ${reason} | [运行](${url}) |
"
  done <<ROWS
${rows}
ROWS
done <<REPOS
${repos}
REPOS

echo "巡检 ${checked} 个仓 / ${wf_seen} 个工作流"

if [ "${wf_seen}" -eq 0 ]; then
  echo "✗ 一个工作流都没扫到——巡检自身空转（org/仓清单/权限有问题）⇒ 判失败"
  exit 1
fi

open_issue() {
  gh issue list --repo "${ISSUE_REPO}" --state open --limit 100 --json number,title \
    --jq ".[] | select(.title == \"${ISSUE_TITLE}\") | .number" 2>/dev/null | head -1
}

if [ -z "${reds}" ]; then
  num=$(open_issue || true)
  if [ -n "${num:-}" ]; then
    if [ "${DRY_RUN}" = 1 ]; then
      echo "[dry-run] 全绿 ⇒ 会关闭已开的 issue #${num}"
    else
      gh issue comment "${num}" --repo "${ISSUE_REPO}" \
        --body "全部默认分支已恢复绿（巡检 ${checked} 个仓 / ${wf_seen} 个工作流）⇒ 自动关单。" >/dev/null
      gh issue close "${num}" --repo "${ISSUE_REPO}" >/dev/null
      echo "✓ 全绿 ⇒ 已关闭 issue #${num}"
    fi
  fi
  echo "✓ 全绿，无需开单"
  OK=1
  exit 0
fi

body="巡检时间：$(date -u '+%Y-%m-%d %H:%M UTC')，巡检 ${checked} 个仓 / ${wf_seen} 个工作流。

| 仓库 | 工作流 | 最近失败 | 判据 | 运行 |
|---|---|---|---|---|
${reds}
口径：只看**默认分支**，每个工作流只看最近一次运行（queued/in_progress/cancelled 不算红）。
报的条件 = 最近一次 failure **且**（连续失败 ≥ ${STREAK_MIN} 次 **或** 红灯已超 ${STALE_HOURS}h）
⇒ 单次抖动不吵人，但「红了没人管」必然被抓住。

发车在途时短暂红是正常的：先看该运行是否属于进行中的列车，别急着改代码。

本 issue 会在全部恢复绿之后由巡检**自动关闭**——不要手工关（关了下次还是红）。"

num=$(open_issue || true)
if [ "${DRY_RUN}" = 1 ]; then
  echo "[dry-run] 巡检 ${checked} 个仓，以下红灯会被写进 issue："
  printf '%b' "${reds}"
  if [ -n "${num:-}" ]; then echo "[dry-run] 会更新已有 issue #${num}"; else echo "[dry-run] 会新建 issue：${ISSUE_TITLE}"; fi
  OK=1
  exit 0
fi

if [ -n "${num:-}" ]; then
  gh issue edit "${num}" --repo "${ISSUE_REPO}" --body "${body}" >/dev/null
  echo "✗ 有红 ⇒ 已更新 issue #${num}"
else
  gh issue create --repo "${ISSUE_REPO}" --title "${ISSUE_TITLE}" --body "${body}" >/dev/null
  echo "✗ 有红 ⇒ 已开新 issue"
fi
OK=1
exit 0
