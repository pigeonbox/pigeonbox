#!/usr/bin/env bash
#
# 建板：创建/补齐公开项目看板「PigeonBox 质量看板」的项目与两个单选字段（Category / Triage）。
# 看板本体：https://github.com/orgs/pigeonbox/projects/1（与 pigeonbox/.github 的
# scripts/sync-board.py 同一真相源：项目名/字段名/三态取值必须两边一致）。
#
# 背景（Refs pigeonbox/pigeonbox#366）：token 缺 project scope 时本脚本会在
# 第一步就给出可复制的手动步骤——CI/维护者任一方拿到带 `project` scope 的
# token 后重跑本脚本即可幂等补齐（已存在的项目/字段自动跳过）。
#
# 用法：
#   bash scripts/board-setup.sh --dry-run   # 只打印将执行的命令（默认门禁口径）
#   bash scripts/board-setup.sh             # 真跑（需 gh token 含 project scope）
#
# 幂等性：按标题找项目；按字段名找字段。重复执行不产生副本。
# 字段选项与 scripts/board-lib.sh 的 PB_BOARD_CATEGORIES / PB_BOARD_STATUSES 同源，
# 改值必须两处一起改。
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
# shellcheck source=vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

# shellcheck source=scripts/board-lib.sh
. "$ROOT/scripts/board-lib.sh"

OWNER="pigeonbox"
TITLE="PigeonBox 质量看板"
DRY_RUN=0

# 参数解析 ⇒ shellkit 的 cli_opt/cli_opts。
# ⚠️ 退出码不变：cli_opts 的用法错码 2 = 本脚本的用法错码（2）。
cli_opt_init
cli_opt DRY_RUN --dry-run
if ! cli_opts "$@"; then
  echo "用法: $0 [--dry-run]" >&2
  exit 2
fi

# run <描述> <命令...>：dry-run 只打印，真跑才执行
run() {
  local desc="$1"
  shift
  if [ "$DRY_RUN" = 1 ]; then
    log_info "[dry-run] $desc: $*"
    return 0
  fi
  log_info "[run] $desc"
  "$@"
}

need_scope() {
  # project scope 探测：读项目列表是只读最小面，缺 scope 时 gh 报固定文案
  if ! gh project list --owner "$OWNER" --format json >/dev/null 2>&1; then
    cat >&2 <<EOF
[阻塞] gh token 缺 project scope，无法建板。

手动建板步骤（拿到带 project scope 的 token 后也可重跑本脚本自动完成）：
  1. gh auth refresh -s project            # 交互式补 scope（或换 PAT）
  2. gh project create --owner $OWNER --title "$TITLE"
  3. gh project field-create <项目号> --owner $OWNER --name Category \
       --data-type SINGLE_SELECT --single-select-options "${PB_BOARD_CATEGORIES// /,}"
  4. gh project field-create <项目号> --owner $OWNER --name Status \
       --data-type SINGLE_SELECT --single-select-options "${PB_BOARD_STATUSES// /,}"
  5. bash scripts/board-sync.sh --dry-run   # 预览归档；去掉 --dry-run 真跑
EOF
    exit 3
  fi
}

# dry-run 只打印命令，不做任何 gh 调用（无 project scope 也能预演）
if [ "$DRY_RUN" = 0 ]; then
  need_scope
fi

# ① 项目（按标题幂等）
PROJECT_URL=""
if [ "$DRY_RUN" = 0 ]; then
  PROJECT_URL=$(gh project list --owner "$OWNER" --format json \
    --jq ".items[] | select(.title==\"$TITLE\") | .url" | head -1)
fi
PROJECT_NUMBER=""
if [ -n "$PROJECT_URL" ]; then
  log_info "[skip] 项目已存在: $PROJECT_URL"
  PROJECT_NUMBER="${PROJECT_URL##*/}"
else
  if [ "$DRY_RUN" = 1 ]; then
    run "建项目" gh project create --owner "$OWNER" --title "$TITLE"
  else
    PROJECT_URL=$(gh project create --owner "$OWNER" --title "$TITLE" --format json --jq .url)
    PROJECT_NUMBER="${PROJECT_URL##*/}"
    log_ok "[ok] 已建项目: $PROJECT_URL"
  fi
fi

# dry-run 首跑时项目还不存在，后续字段步骤只打印占位
[ -n "$PROJECT_NUMBER" ] || PROJECT_NUMBER="<项目号>"

# ② 字段（按名幂等）
field_exists() { # <字段名>
  local name="$1"
  gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json \
    --jq ".fields[] | select(.name==\"$name\") | .name" 2>/dev/null | grep -q .
}

ensure_field() { # <字段名> <选项,逗号分隔>
  local name="$1" opts="$2"
  if field_exists "$name"; then
    log_info "[skip] 字段已存在: $name"
    return 0
  fi
  run "建字段 $name" gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" \
    --name "$name" --data-type SINGLE_SELECT --single-select-options "$opts"
}

ensure_field "Category" "${PB_BOARD_CATEGORIES// /,}"
ensure_field "Triage" "${PB_BOARD_STATUSES// /,}"

log_info "完成。看板: ${PROJECT_URL:-（dry-run 未创建，真跑后输出 URL）}"
log_info "下一步: bash scripts/board-sync.sh --dry-run 预览归档"
