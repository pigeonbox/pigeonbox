#!/usr/bin/env bash
#
# 把 hub 的 vendor/shellkit（真相源）**物化**到各平台仓的 third_party/shellkit。
#
# 为什么要有这个物化器（2026-11-18 引入 shellkit 时落地）：
#   shellkit 的副本是**上游镜像**（生成物，勿手改），真相源只有一处 = hub 的
#   vendor/shellkit/；各平台仓的副本由本脚本铺过去，**逐仓分别提 PR**
#   （与 deploy/nas/sync.sh 把 hub 模板物化到 NAS 三仓是同一套纪律：
#   真相源一处、其余是物化结果、有漂移门禁兜底）。
#
# ⚠️ **为什么消费仓放 third_party/shellkit 而不是 vendor/shellkit**：
#   Go ≥1.14 看到**模块根**下有 vendor/ 目录就默认切 vendor 模式 ⇒ 依赖解析报
#   "inconsistent vendoring"（实测：fnos/openwrt/qnap/p2p 四个 Go 模块仓
#   `go build ./...` 直接红）⇒ 副本改放 third_party/，与 Go 的 vendor 语义分开。
#
# 用法:
#   bash scripts/vendor-shellkit.sh sync   [--repo <仓名>|--all] [--root <工作区根>] [--workspace <平台仓所在目录>]
#   bash scripts/vendor-shellkit.sh status [--repo <仓名>|--all] [--root <工作区根>] [--workspace <平台仓所在目录>]
#
# ⚠️ **--all 是显式别名**：不带 --repo 本来就是全量（TARGET_REPOS 里在位的仓），
#   但 Makefile 的 vendor-sync 目标与生态各脚本的 fail-closed 提示都写的是 `sync --all`
#   ⇒ 没有这个 flag 时，那两处都退 2（用法错）⇒ 目标形同虚设。
#
# 退出码: 0 = 全部一致/已同步；5 = 有仓漂移（status 时）；2 = 用法错
set -uo pipefail

ROOT="${SHELLKIT_VENDOR_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

# 真相源 = hub 自己的 vendor/shellkit
TRUTH="$ROOT/vendor/shellkit"

# 平台仓所在的**工作区根**（可覆盖；默认 = ROOT 自身，CI 里即嵌套布局）。
WORKSPACE="${SHELLKIT_VENDOR_WORKSPACE:-$ROOT}"

# 消费仓的副本路径：**一律 third_party/shellkit**（理由见文件头）
REPO_VENDOR_PATH="third_party/shellkit"

# 目标仓清单 —— ⚠️ 与 scripts/check-shellkit-vendor.sh 的清单必须一致。
TARGET_REPOS="fnos openwrt qnap synology ugreen terramaster p2p charts"

usage() {
  cat >&2 <<'EOF'
用法:
  bash scripts/vendor-shellkit.sh sync   [--repo <仓名>|--all] [--root <工作区根>] [--workspace <平台仓所在目录>]
  bash scripts/vendor-shellkit.sh status [--repo <仓名>|--all] [--root <工作区根>] [--workspace <平台仓所在目录>]
EOF
}

# find_repo <仓名> → 打印仓根路径；找不到返回 1
#
# ⚠️ **探测**而不是推算层数：嵌套（平台仓在 hub 检出目录内部）与兄弟（与 hub 平级）
#   两种布局都真实存在 ⇒ 固定层数必然在另一种布局下指错。
find_repo() { # <仓名>
  local name="$1" cand base
  for base in "$ROOT" "$WORKSPACE" "$ROOT/.." "$WORKSPACE/.."; do
    cand="$base/$name"
    if [ -d "$cand/.git" ]; then
      (cd "$cand" && pwd -P)
      return 0
    fi
  done
  return 1
}

copy_vendor() { # <源 vendor 目录> <目标 vendor 目录>
  local src="$1" dst="$2"
  mkdir -p "$dst" || return 1
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/" || return 1
  else
    rm -rf "$dst" || return 1
    mkdir -p "$dst" || return 1
    cp -R "$src/." "$dst/" || return 1
  fi
  return 0
}

action=""
only_repo=""
all_flag=0
root_override=""
workspace_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    sync | status)
      action="$1"
      shift
      ;;
    --repo)
      # ⚠️ 缺值时**不许**静默退化成「全量」：$2 为空 + shift 2 失败 ⇒ only_repo 空
      #   ⇒ 直接跑成「同步所有仓」⇒ 一个手滑的 `sync --repo` 会动到全部平台仓。
      #   ⇒ 显式判缺值退 2（fail-closed）。
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--repo 需要仓名（取值见 TARGET_REPOS）" >&2
        usage
        exit 2
      fi
      only_repo="$2"
      shift 2
      ;;
    --all)
      all_flag=1
      shift
      ;;
    --root)
      root_override="$2"
      shift 2
      ;;
    --workspace)
      workspace_override="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$action" ] || {
  usage
  exit 2
}

# --all 与 --repo 互斥（--all = 全量 = 不带 --repo 的默认行为）。
if [ "$all_flag" -eq 1 ] && [ -n "$only_repo" ]; then
  echo "--all 与 --repo 互斥" >&2
  usage
  exit 2
fi

if [ -n "$root_override" ]; then
  ROOT="$(cd "$root_override" && pwd -P)" || exit 2
  TRUTH="$ROOT/vendor/shellkit"
  WORKSPACE="$ROOT"
fi
if [ -n "$workspace_override" ]; then
  WORKSPACE="$(cd "$workspace_override" && pwd -P)" || exit 2
fi

if [ ! -d "$TRUTH" ]; then
  echo "✗ 真相源缺失：$TRUTH" >&2
  echo "  修法: 从 shellkit 检出跑 'shellkit vendor .'（见 docs/specs/2026-11-18-shellkit-adoption-design.md §3）" >&2
  exit 5
fi

repos="$TARGET_REPOS"
[ -n "$only_repo" ] && repos="$only_repo"

drift=0
synced=0
for name in $repos; do
  repo="$(find_repo "$name")" || {
    echo "! 跳过 ${name}（不在位）"
    continue
  }
  dst="$repo/$REPO_VENDOR_PATH"
  case "$action" in
    sync)
      if copy_vendor "$TRUTH" "$dst"; then
        echo "✓ ${name}：已物化 ${REPO_VENDOR_PATH}（$(cat "$dst/VERSION" 2>/dev/null || echo '?'))"
        synced=$((synced + 1))
      else
        echo "✗ ${name}：物化失败" >&2
        drift=$((drift + 1))
      fi
      ;;
    status)
      if diff -r -q "$TRUTH" "$dst" >/dev/null 2>&1; then
        echo "✓ ${name}：一致（$(cat "$dst/VERSION" 2>/dev/null || echo '?'))"
      else
        echo "✗ ${name}：与真相源不一致"
        drift=$((drift + 1))
      fi
      ;;
  esac
done

if [ "$action" = "sync" ]; then
  echo "  （已物化 $synced 个仓；改动落在各仓的工作树里 ⇒ 逐仓分别提 PR）"
  [ "$drift" -eq 0 ] || exit 5
  exit 0
fi

[ "$drift" -eq 0 ] || exit 5
exit 0
