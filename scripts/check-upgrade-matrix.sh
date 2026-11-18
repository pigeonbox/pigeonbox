#!/usr/bin/env bash
# 门禁：N-1/N-2 制品级升级矩阵（静态部分）（hub#660 · L7 升级层）。
#
# 为什么有这道门禁（2026-11-18 生态技术评审，L7 升级层）：
#   生态此前只有「升级**失败**可恢复」的断言（scripts/check-upgrade-recoverability.sh
#   收编 qnap/synology/fnos 三端），**没有**「从上一车/上上车的真实制品装起来 →
#   升级到当前车 → 数据完整性对账」这条链的任何覆盖 ⇒ N-1→N 的制品级升级路径
#   在仓内是零覆盖的盲区（issue #660）。
#
# 为什么分两层（母会话拍板）：
#   真装演练需要**当前车的产物**，而当前车的产物在 PR/CI 阶段**还不存在**（还没发版）
#   ⇒ 真装演练不可能当 PR 门禁 ⇒ 拆成：
#     · 本脚本 = **PR 期静态矩阵**（产物存在性 + 钉版一致性 + 钉版单调性）；
#       纯元数据、快、稳，挂在既有 job 的一个 step 上（不新开 job ⇒ 不改
#       required checks 名单）。
#     · scripts/upgrade-drill.sh + .github/workflows/upgrade-drill.yml =
#       **发布后**的真升级演练（N-1→N / N-2→N），不挡合并。
#
# 判定内容（实现见 scripts/upgrade_matrix.py）：
#   ① 列车序列：N/N-1/N-2 从 release/train.yaml 的 **git 历史**解析
#      （历史台账不新建——历史提交里就是当时那车）；锚点 = 最后一辆 state=shipped 的车
#      （在途的 draft 车产物还没发布，以它为锚点必然假红）。
#   ② 产物存在性：每辆车的 release/manifest.json 必须声明 7 平台包 + server/frontend 镜像。
#   ③ 钉版一致：该车 train.yaml 声明的钉版 == **产物内嵌**的钉版
#      （fnos/qnap/openwrt 的 DEPS.env、synology/ugreen/terramaster 的镜像钉版、
#      desktop 的 VERSION），取自**平台仓的发布 tag**（= 当轮真实产物）。
#   ④ 钉版单调：N-2 ≤ N-1 ≤ N（不许倒退，也不许 N 比 N-1 老）。
#   ⑤ 远端产物存在性：hub Release 上 <plat>-v<X> / v<X> 是否真的存在。
#      远端**网络不可用**时降级为「未扫描（登记在案）」——「没扫到」≠「扫过且通过」；
#      真 404（产物不存在）仍然判红。
#
# env 覆盖（与 check-docs-consistency.sh 的 DOCS_GATE_* 同范式）：
#   UPGRADE_MATRIX_ROOT                 hub 根（默认：脚本所在仓根）
#   UPGRADE_MATRIX_PLATFORMS_ROOT       平台仓所在根（默认 = hub 根；desktop 另找 ../desktop）
#   UPGRADE_MATRIX_REMOTE               1=查远端 Release（默认 1）/ 0=不查
#   UPGRADE_MATRIX_REQUIRE_REMOTE       1=远端不可达也判红（默认 0=降级登记在案）
#   UPGRADE_MATRIX_REQUIRE_PLATFORM_REPOS  1=平台仓缺位即判红（默认 0=降级登记在案）
#   UPGRADE_MATRIX_REPO                 默认 pigeonbox/pigeonbox
#   UPGRADE_MATRIX_API_BASE             默认 https://api.github.com
#
# 用法: bash scripts/check-upgrade-matrix.sh [--selfcheck]
# ── shellkit（门禁侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SK_BOOTSTRAP="$HUB_ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=../vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

set -uo pipefail

ROOT="${UPGRADE_MATRIX_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      log_info "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

PY="python3 scripts/upgrade_matrix.py"
if ! command -v python3 >/dev/null 2>&1; then
  log_error "✗ 没有 python3——门禁自身失效（矩阵解析/判定都靠它）"
  exit 1
fi
if [ ! -f "scripts/upgrade_matrix.py" ]; then
  log_error "✗ 缺 scripts/upgrade_matrix.py——门禁自身失效"
  exit 1
fi

# 成功哨兵形态：EXIT trap 必须保留退出码（macOS bash 3.2 在因未定义变量退出时
# trap 入口的 $? 是 0 ⇒ 「脚本报了错、退出码却是 0」）。
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

if [ "$SELFCHECK" -eq 1 ]; then
  log_info "── 升级矩阵静态门禁 selfcheck（负对照）"
  $PY selfcheck --root "$ROOT"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    exit "$rc"
  fi
  # 成功哨兵：selfcheck 也要走「OK=1 才允许 exit 0」的同一口径
  OK=1
  exit 0
fi

PLATFORMS_ROOT="${UPGRADE_MATRIX_PLATFORMS_ROOT:-$ROOT}"
REMOTE="${UPGRADE_MATRIX_REMOTE:-1}"
REQUIRE_REMOTE="${UPGRADE_MATRIX_REQUIRE_REMOTE:-0}"
REQUIRE_PLATFORM_REPOS="${UPGRADE_MATRIX_REQUIRE_PLATFORM_REPOS:-0}"
REPO="${UPGRADE_MATRIX_REPO:-pigeonbox/pigeonbox}"
API_BASE="${UPGRADE_MATRIX_API_BASE:-https://api.github.com}"

ARGS=(check --root "$ROOT" --platforms-root "$PLATFORMS_ROOT"
  --repo "$REPO" --api-base "$API_BASE")
if [ "$REMOTE" = "0" ]; then
  ARGS+=(--no-remote)
fi
if [ "$REQUIRE_REMOTE" = "1" ]; then
  ARGS+=(--require-remote)
fi
if [ "$REQUIRE_PLATFORM_REPOS" = "1" ]; then
  ARGS+=(--require-platform-repos)
fi

$PY "${ARGS[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
OK=1
exit 0
