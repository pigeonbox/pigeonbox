#!/usr/bin/env bash
#
# 门禁：错误码**跨版本**兼容断言（L2 层）。
#
# 为什么要有这道门禁（既有 check-errcode-cross-repo.sh 的缺口）：
#   既有门禁（PR #420）断言的是**当前**三端一致（契约 ⇄ 前端映射 ⇄ 五门语言
#   ⇄ 已发布基线）。但它**没有**覆盖「已发布的旧版前端（旧的 contracts 契约）
#   在新契约下是否仍可用」——这三条不变量此前完全没有机器表达：
#     ① 老前端在新契约下可用（老前端认识的码不得被删/改语义）
#     ② 码号不复用（同号常量名不得变——数字对得上、老前端却拿到新语义）
#     ③ 只增不减（旧版本有的码，新版本不能没有）
#
# 素材来源：**已发布版本清单** scripts/errcode-published-versions.json
#   · contracts 已发布 tag（清单 contracts.published_tags）⇒ 相邻两版对账；
#   · frontend-core 已发布 tgz（--frontend-pkg）⇒ 老前端 × 新契约；
#   · 另加 contracts 仓 git 历史（含未发布提交）对比当前码表。
#
# 四种结论（退出码即语义，别把「没判」当成「判过且通过」）：
#   0 = 判定通过（所有面都真判了且都过）
#   1 = 判定不通过（某条不变量被破）
#   3 = **判据不可用**（缺料 ⇒ 这一面没判）——**不打印「通过」**
#   2 = 门禁自身不可用（参数/形态不对）
#
# 用法：
#   bash scripts/check-errcode-cross-version.sh [--selfcheck] [--require-all]
#                             [--contracts <dir>] [--manifest <清单>]
#                             [--frontend-pkg <tgz|目录> ...]
set -uo pipefail

ROOT="${ERRCODE_XVER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
REQUIRE_ALL=0
CONTRACTS=""
MANIFEST=""
FRONTEND_PKGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --selfcheck) SELFCHECK=1 ;;
    --require-all) REQUIRE_ALL=1 ;;
    --contracts)
      shift
      CONTRACTS="${1:-}"
      ;;
    --manifest)
      shift
      MANIFEST="${1:-}"
      ;;
    --frontend-pkg)
      shift
      FRONTEND_PKGS+=("${1:-}")
      ;;
    *)
      echo "用法: $0 [--selfcheck] [--require-all] [--contracts <dir>] [--manifest <清单>] [--frontend-pkg <tgz|目录> ...]" >&2
      exit 2
      ;;
  esac
  shift
done

log() { printf '%s\n' "$*"; }
fail() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 ||
  fail "python3 不可用：门禁需要它（macOS/Linux 自带）"

# 已发布版本清单（默认在 scripts/ 下；缺了由解析器报「判据不可用」）
if [ -z "$MANIFEST" ]; then
  MANIFEST="$ROOT/scripts/errcode-published-versions.json"
fi

# contracts 仓路径：显式指定 > 常见检出位置。
#
# 检出形态（CI 与本地不同，探测顺序按「最近的优先」）：
#   ① --contracts 显式指定；
#   ② $ROOT/contracts（CI 里 checkout 到同级目录时的形态）；
#   ③ hub 同级的 contracts/（工作区形态：<workspace>/PigeonBox/contracts）；
#   ④ hub 仓的上两级再找 contracts/（worktree 形态）。
if [ -z "$CONTRACTS" ]; then
  for cand in "$ROOT/contracts" "$(cd "$ROOT/.." && pwd)/contracts" "$(cd "$ROOT/.." && pwd)/PigeonBox/contracts" "$(cd "$ROOT/../.." && pwd)/PigeonBox/contracts" "$(cd "$ROOT/../.." && pwd)/contracts"; do
    if [ -f "$cand/errcode/errcode.go" ]; then
      CONTRACTS="$cand"
      break
    fi
  done
fi
if [ -z "$CONTRACTS" ]; then
  if [ "$REQUIRE_ALL" -eq 1 ]; then
    fail "找不到 contracts 仓（--require-all ⇒ 缺料即红；用 --contracts 指定；CI 里会 checkout 到 $ROOT/contracts）"
  fi
  log "⚠ 找不到 contracts 仓 ⇒ **判据不可用**（未判定，不是「通过」）"
  log "  提示：用 --contracts <dir> 指定；CI 里会 checkout 到 $ROOT/contracts"
  exit 3
fi

if [ "$SELFCHECK" -eq 1 ]; then
  log "错误码跨版本断言自检（注入坏形态 ⇒ 必须判红；好形态 ⇒ 必须放行）"
  python3 scripts/errcode_cross_version.py selfcheck --root "$ROOT" --contracts "$CONTRACTS" ||
    fail "跨版本断言自检未通过：至少一种形态的判定与预期不符"
  exit 0
fi

ARGS=(validate --root "$ROOT" --contracts "$CONTRACTS" --manifest "$MANIFEST")
[ "$REQUIRE_ALL" -eq 1 ] && ARGS+=(--require-all)
for pkg in "${FRONTEND_PKGS[@]+"${FRONTEND_PKGS[@]}"}"; do
  ARGS+=(--frontend-pkg "$pkg")
done

RC=0
python3 scripts/errcode_cross_version.py "${ARGS[@]}" || RC=$?
case "$RC" in
  0)
    log "✓ 错误码跨版本兼容断言通过"
    exit 0
    ;;
  3)
    # 「读不到素材」不是「扫过且通过」——独立退出码 + 明确措辞。
    log "⚠ 错误码跨版本兼容断言：**判据不可用**（缺料 ⇒ 未判定，不是「通过」）"
    exit 3
    ;;
  *)
    fail "错误码跨版本兼容断言未通过"
    ;;
esac
