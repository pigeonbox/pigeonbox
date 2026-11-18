#!/usr/bin/env bash
#
# 看板归档同步：把全生态 open issue 按分类/状态加入公开看板并回填字段。
#
# 背景（Refs pigeonbox/pigeonbox#366）：多仓生态单仓 issue 数不能代表质量，
# 需要统一公开视图。本脚本是**增量同步器**——CI 可只跑 --dry-run 做对账，
# 维护者定期真跑归档。
#
# 用法：
#   bash scripts/board-sync.sh --dry-run   # 只读：列出全部 open issue 的分类判定（默认门禁口径）
#   bash scripts/board-sync.sh             # 真跑：item-add + 回填 Category/Triage（需 project scope）
#   bash scripts/board-sync.sh --dry-run --repo core   # 只看一个仓
#
# 幂等性：item-add 对已在板上的 issue 会报错——脚本先 item-list 取已有 URL 集合，
# 已在板的跳过（重复执行不炸、不重复）。字段回填用 item-edit，已设值会被覆盖为
# 最新判定——这正是增量同步语义（标题前缀改了就该跟着改）。
#
# 分类判定见 scripts/board-lib.sh（单一真相源）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── shellkit（看板侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
SK_BOOTSTRAP="$ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=../vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

# shellcheck source=scripts/board-lib.sh
. "$ROOT/scripts/board-lib.sh"

OWNER="pigeonbox"
TITLE="PigeonBox Ecosystem"
DRY_RUN=0
ONLY_REPO=""

# 参数解析 ⇒ shellkit 的 cli_opt/cli_opts。
# ⚠️ 退出码不变：cli_opts 的用法错码 2 = 本脚本的用法错码（2）。
cli_opt_init
cli_opt DRY_RUN --dry-run
cli_opt ONLY_REPO --repo "" 1
if ! cli_opts "$@"; then
  echo "用法: $0 [--dry-run] [--repo <名>]" >&2
  exit 2
fi

# ── 取板（真跑必需；dry-run 不发 project 请求，便于无 scope 环境跑对账）──
PROJECT_NUMBER=""
FIELD_CAT_ID=""
FIELD_ST_ID=""

if [ "$DRY_RUN" = 0 ]; then
  PROJECT_URL=$(gh project list --owner "$OWNER" --format json \
    --jq ".items[] | select(.title==\"$TITLE\") | .url" | head -1)
  if [ -z "$PROJECT_URL" ]; then
    log_error "[阻塞] 看板不存在，先跑 bash scripts/board-setup.sh"
    exit 3
  fi
  PROJECT_NUMBER="${PROJECT_URL##*/}"
  FIELD_CAT_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name==\"Category\") | .id")
  FIELD_ST_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name==\"Triage\") | .id")
  if [ -z "$FIELD_CAT_ID" ] || [ -z "$FIELD_ST_ID" ]; then
    log_error "[阻塞] Category/Triage 字段缺失，先跑 bash scripts/board-setup.sh"
    exit 3
  fi

  # 已在板的 issue URL 集合（幂等跳过）
  ON_BOARD=$(gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".items[] | select(.content.url!=null) | .content.url")
  # 字段选项名 → option id（回填单选要用 option id，不是名字）
  CAT_OPTS=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name==\"Category\") | .options[] | \"\(.name)=\(.id)\"")
  ST_OPTS=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name==\"Triage\") | .options[] | \"\(.name)=\(.id)\"")
else
  ON_BOARD=""
  CAT_OPTS=""
  ST_OPTS=""
fi

opt_id() { # <选项表 "名=id"逐行> <名> → option id
  printf "%s\n" "$1" | awk -F= -v n="$2" "$1==n{print $2; exit}"
}

# ── 拉全生态 open issue ──
if [ -n "$ONLY_REPO" ]; then
  REPOS="$ONLY_REPO"
else
  REPOS="$PB_BOARD_REPOS"
fi

TOTAL=0
ADDED=0
SKIPPED=0
UNMAPPED=0

for repo in $REPOS; do
  json=$(gh issue list -R "$OWNER/$repo" --state open --limit 200 \
    --json number,title,labels,url 2>/dev/null) || {
    log_warn "$repo 拉取失败，跳过"
    continue
  }
  count=$(printf "%s" "$json" | jq "length")
  [ "$count" = 0 ] && continue

  while IFS=$'\t' read -r num title labels url; do
    [ -n "$num" ] || continue
    TOTAL=$((TOTAL + 1))
    cat=$(pb_classify_category "$title" "$labels")
    st=$(pb_classify_status "$title" "$labels")
    if [ "$cat" = UNMAPPED ]; then
      UNMAPPED=$((UNMAPPED + 1))
      echo "[UNMAPPED] $repo#$num $title"
    fi

    if [ "$DRY_RUN" = 1 ]; then
      printf "%-24s %-13s %-8s %s\n" "$repo#$num" "$cat" "$st" "$title"
      continue
    fi

    if printf "%s\n" "$ON_BOARD" | grep -qxF "$url"; then
      SKIPPED=$((SKIPPED + 1))
      # 已在板：仍回填字段（标题改了分类要跟着走）
    else
      gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$url" >/dev/null
      ADDED=$((ADDED + 1))
    fi

    # 回填两字段（item-id 从板上按 URL 反查）
    item_id=$(gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
      --jq ".items[] | select(.content.url==\"$url\") | .id" | head -1)
    if [ -n "$item_id" ]; then
      cid=$(opt_id "$CAT_OPTS" "$cat")
      sid=$(opt_id "$ST_OPTS" "$st")
      [ -n "$cid" ] && gh project item-edit --project-id "$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json --jq .id)" \
        --item-id "$item_id" --field-id "$FIELD_CAT_ID" --single-select-option-id "$cid" >/dev/null
      [ -n "$sid" ] && gh project item-edit --project-id "$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json --jq .id)" \
        --item-id "$item_id" --field-id "$FIELD_ST_ID" --single-select-option-id "$sid" >/dev/null
    fi
  done < <(printf "%s" "$json" | jq -r '.[] | [.number, .title, ([.labels[].name]|join(",")), .url] | @tsv')
done

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "dry-run 完共 ${TOTAL} 条（UNMAPPED ${UNMAPPED}）——UNMAPPED 需在 board-lib.sh 补规则"
  [ "$UNMAPPED" = 0 ] || exit 1
else
  echo "同步完成：新增 ${ADDED}，已在板 ${SKIPPED}，共处理 ${TOTAL}（UNMAPPED ${UNMAPPED}）"
  [ "$UNMAPPED" = 0 ] || {
    log_error "存在 UNMAPPED，字段未回填，请补 board-lib.sh 规则"
    exit 1
  }
fi
