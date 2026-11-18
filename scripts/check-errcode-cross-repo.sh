#!/usr/bin/env bash
#
# 门禁：错误码跨仓对账（L2 层：跨版本前后端错误码语义）。
#
# 为什么有这道门禁（2026-11-14 生态技术评审 §六 L2 层缺口）：
#   错误码真相源是 contracts/errcode/errcode.go（手写 Go 常量表）。
#   消费方：core（返回错误信封）· frontend-core 的 ERRCODE_KEY_MAP ·
#   frontend-core 五门语言包的 errcode 块。
#   **三者的一致性此前纯属约定**：contracts 无「const ⇄ messages」自检；
#   frontend-core 的测试断言源头是**手抄**码表（实测手抄 66 条、真相源 67 条
#   ⇒ 已漏一条而无人发现）；「已发布码不得删 / 不得改语义 / 不得复用」这条
#   跨版本不变量**完全没有机器表达**。
#   ⇒ 本门禁把「三端集合必须相等」与「已发布码只增不减」做成机械断言。
#
# 断言（每条都必须能变红，判据即负对照）：
#   ① 契约基线同步：contracts/errcode/baseline.json == 当前 const 表，
#      且同号常量的**名字不变**（防码号被复用给另一种语义）；
#   ② 前端 ERRCODE_KEY_MAP 键集合 == 契约码集合，且值形如 errcode.<同码>；
#   ③ 五门语言 errcode 块键集合 == 契约码集合，文案非空；
#   ④ 单调性：baseline 里的码不得从契约消失。
#
# 检出形态（三态，与 check-platform-capabilities.sh 同口径）：
#   · 判定形态：frontend-core 与 contracts 同场 ⇒ 全量跑；
#   · 跳过形态：本地单仓检出（frontend-core 不在场）⇒ 打印**明确跳过原因**，
#     只跑契约侧自检——不让「没扫到」看起来像「扫过且通过」；
#   · CI 形态：加 --require-frontend ⇒ **缺仓即红**（与 check-docs-consistency.sh
#     的缺仓判红同口径）。
#
# 用法：bash scripts/check-errcode-cross-repo.sh [--selfcheck] [--require-frontend]
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

ROOT="${ERRCODE_GATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
REQUIRE=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    --require-frontend) REQUIRE=1 ;;
    *)
      log_info "用法: $0 [--selfcheck] [--require-frontend]"
      exit 2
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  log_error "✗ 没有 python3——门禁自身失效（解析与自证都靠它）"
  exit 1
fi

args=(validate --root "$ROOT")
if [ -n "${ERRCODE_GATE_CONTRACTS:-}" ]; then
  args+=(--contracts "$ERRCODE_GATE_CONTRACTS")
fi
if [ -n "${ERRCODE_GATE_FRONTEND:-}" ]; then
  args+=(--frontend "$ERRCODE_GATE_FRONTEND")
fi
if [ "$REQUIRE" -eq 1 ]; then
  args+=(--require-frontend)
fi

if [ "$SELFCHECK" -eq 1 ]; then
  log_info "── 错误码跨仓对账 selfcheck（4 组负对照）"
  exec python3 scripts/errcode_cross_repo.py selfcheck --root "$ROOT" \
    ${ERRCODE_GATE_CONTRACTS:+--contracts "$ERRCODE_GATE_CONTRACTS"} \
    ${ERRCODE_GATE_FRONTEND:+--frontend "$ERRCODE_GATE_FRONTEND"}
fi

log_info "── 错误码跨仓对账（契约 ⇄ 前端映射 ⇄ 五门语言 ⇄ 已发布基线）"
exec python3 scripts/errcode_cross_repo.py "${args[@]}"
