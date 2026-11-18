#!/usr/bin/env bash
#
# 跨仓质量指标生成器：输出 Markdown 指标表（stdout 或 --out 文件）。
#
# 背景（Refs pigeonbox/pigeonbox#366）：看板回答「有什么」，本脚本回答
# 「有多少、卡在哪、验到哪」。能从 gh API 拉的自动算，拉不到的在输出里
# 留口径说明占位（不编数）。
#
# 三项指标（对应 issue 的三个问题）：
#   ① 按分类/仓的 open 缺陷分布 —— 可拉：gh issue list + board-lib 判定
#   ② 跨仓阻塞关系 —— 可拉：open issue 正文里的 repo#num 跨仓引用
#   ③ 真机验证覆盖率 —— 可拉：hub#240 正文的勾选框/⏳ 行（引 hub#240）
#   ④ 按列车号归档缺陷数 —— **拉不到**（全生态无 milestone、无 train label），
#      输出口径说明与建议约定，不编数
#
# 用法：
#   bash scripts/metrics.sh              # 打印 Markdown 到 stdout
#   bash scripts/metrics.sh --out docs/METRICS.draft.md   # 写文件
#   bash scripts/metrics.sh --dry-run    # 与默认相同（只读；语义上强调不写库）
#
# 频率：随看板同步（board-sync.sh）一起跑，或发车前跑一次。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── shellkit（指标侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
SK_BOOTSTRAP="$ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

# shellcheck source=scripts/board-lib.sh
. "$ROOT/scripts/board-lib.sh"

OWNER="pigeonbox"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      shift
      OUT="${1:-}"
      [ -n "$OUT" ] || {
        echo "--out 缺值" >&2
        exit 2
      }
      ;;
    --dry-run) : ;;
    *)
      echo "用法: $0 [--out <文件>] [--dry-run]" >&2
      exit 2
      ;;
  esac
  shift
done

# 输出先进缓冲（set -e 下任一步失败则整体失败，不留半截文件）
BUF=$(mktemp)
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原手写 trap 等价。
# ⚠️ 原脚本在 `mv "$BUF" "$OUT"` 之后用 `trap - EXIT` 摘掉 trap（别把目标文件删了）；
#    换成清理栈后不必摘：清理动作是 `rm -f "$BUF"`，而 BUF 已被 mv 走 ⇒ 该路径
#    已不存在 ⇒ rm -f 是空操作 ⇒ 目标文件不会被删。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -f "${BUF}"'
trap_install
# emit 写的是**指标表本体**（stdout 的产物）⇒ 不走日志流。
emit() { printf "%s\n" "$*" >>"$BUF"; }

NOW=$(date -u "+%Y-%m-%d %H:%M UTC")

emit "# 跨仓质量指标（自动生成）"
emit ""
emit "> 生成：bash scripts/metrics.sh @ ${NOW}；判定口径见 scripts/board-lib.sh，"
emit "> 指标定义与维护约定见 [docs/METRICS.md](METRICS.md)。数字随生成刷新，"
emit "> 口径正文不随生成变。"
emit ""

# ── ① 分类 × 仓 分布 ──
emit "## ① open issue 分布（分类 × 仓）"
emit ""
emitted_header=0
SUM_TOTAL=0
for repo in $PB_BOARD_REPOS; do
  json=$(gh issue list -R "$OWNER/$repo" --state open --limit 200 \
    --json number,title,labels 2>/dev/null) || continue
  [ "$(printf "%s" "$json" | jq length)" = 0 ] && continue
  if [ "$emitted_header" = 0 ]; then
    emit "| 仓 | Security | Correctness | Reliability | Platform | Product | Community | UNMAPPED | 合计 |"
    emit "|---|---|---|---|---|---|---|---|---|"
    emitted_header=1
  fi
  c_sec=0
  c_cor=0
  c_rel=0
  c_pla=0
  c_pro=0
  c_com=0
  c_unm=0
  while IFS=$'\t' read -r title labels; do
    [ -n "$title" ] || continue
    case "$(pb_classify_category "$title" "$labels")" in
      Security) c_sec=$((c_sec + 1)) ;;
      Correctness) c_cor=$((c_cor + 1)) ;;
      Reliability) c_rel=$((c_rel + 1)) ;;
      Platform) c_pla=$((c_pla + 1)) ;;
      Product) c_pro=$((c_pro + 1)) ;;
      Community) c_com=$((c_com + 1)) ;;
      *) c_unm=$((c_unm + 1)) ;;
    esac
  done < <(printf "%s" "$json" | jq -r '.[] | [.title, ([.labels[].name]|join(","))] | @tsv')
  row_total=$((c_sec + c_cor + c_rel + c_pla + c_pro + c_com + c_unm))
  SUM_TOTAL=$((SUM_TOTAL + row_total))
  emit "| $repo | $c_sec | $c_cor | $c_rel | $c_pla | $c_pro | $c_com | $c_unm | $row_total |"
done
emit ""
emit "合计 **$SUM_TOTAL** 条 open issue。"
emit ""

# ── ② 跨仓阻塞关系 ──
emit "## ② 跨仓阻塞关系（open issue 正文里的跨仓引用）"
emit ""
emit "引用形如 repo#num 指向**另一仓**的 issue/PR。"
emit ""
emitted_2=0
for repo in $PB_BOARD_REPOS; do
  json=$(gh issue list -R "$OWNER/$repo" --state open --limit 200 \
    --json number,title,body 2>/dev/null) || continue
  [ "$(printf "%s" "$json" | jq length)" = 0 ] && continue
  while IFS=$'\t' read -r num title refs; do
    [ -n "$refs" ] || continue
    for ref in $(printf "%s" "$refs" | tr "," " "); do
      ref_repo="${ref%%#*}"
      [ "$ref_repo" = "$repo" ] && continue
      # 只认生态内仓（正文会引 istore-repo 等外站，不算跨仓阻塞）
      case " $PB_BOARD_REPOS " in
        *" $ref_repo "*) : ;;
        *) continue ;;
      esac
      if [ "$emitted_2" = 0 ]; then
        emit "| 引用方 | 被引方 | 引用方标题 |"
        emit "|---|---|---|"
        emitted_2=1
      fi
      emit "| $repo#$num | $ref | $title |"
    done
  done < <(printf "%s" "$json" | jq -r --arg self "$repo" '
    .[] |
    ([.body // "" | scan("[a-z][a-z0-9-]*#[0-9]+")] | unique |
     map(select(startswith($self + "#") | not)) | join(",")) as $refs |
    [.number, .title, $refs] | @tsv')
done
[ "$emitted_2" = 1 ] || emit "_本轮无跨仓引用（或拉取失败）。_"
emit ""

# ── ③ 真机验证覆盖率（hub#240）──
emit "## ③ 真机验证覆盖率（真相源 [hub#240](https://github.com/pigeonbox/pigeonbox/issues/240)）"
emit ""
b240=$(gh issue view 240 -R "$OWNER/pigeonbox" --json body --jq .body 2>/dev/null || true)
if [ -n "$b240" ]; then
  done_n=$(printf "%s" "$b240" | grep -cE "^- \[x\]" || true)
  open_n=$(printf "%s" "$b240" | grep -cE "^- \[ \]" || true)
  paid=$(printf "%s" "$b240" | grep -c "✅" || true)
  pending=$(printf "%s" "$b240" | grep -c "⏳" || true)
  total=$((done_n + open_n))
  if [ "$total" -gt 0 ]; then
    pct=$((done_n * 100 / total))
    emit "- 销账条件勾选：**$done_n/$total**（$pct%）已完成"
  fi
  emit "- 正文 ✅ 标记 $paid 处 / ⏳ 待办 $pending 处"
  emit "- 平台真机明细逐条以 #240 表格为准（本表只给汇总，避免两处维护）"
else
  emit "_hub#240 拉取失败（网络/权限），本轮跳过。_"
fi
emit ""

# ── ④ 按列车号归档缺陷数：拉不到 → 口径说明 ──
emit "## ④ 按列车号归档缺陷数（暂不可自动）"
emit ""
emit "**拉不到的原因**：全生态 issue 无 milestone、无列车 label，gh API 没有任何"
emit "字段能把缺陷归到列车号；按关单时间倒推列车窗口会把 hotfix/补车算错。"
emit ""
emit "**口径（人工/待约定）**：发车后在本节贴当趟车的缺陷清账——来源是列车 bump"
emit "PR 的 Fixes 列表与 make train-verify 输出；等生态开始给 issue 打"
emit "train/<列车号> label 或 milestone 后，本节可改为自动拉取。"
emit ""

# ── 输出 ──
if [ -n "$OUT" ]; then
  mv "$BUF" "$OUT"
  log_info "已写 $OUT"
else
  # ⚠️ **stdout 契约**：指标表本体是本脚本的**产物**（调用方直接消费/落盘）
  #    ⇒ 保持在 stdout，不进日志流。
  cat "$BUF"
fi
