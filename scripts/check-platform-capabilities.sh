#!/usr/bin/env bash
#
# 门禁：跨平台 Capability Contract 与兼容矩阵（pigeonbox/pigeonbox#365）。
#
# 为什么有这道门禁（2026-11-14 生态技术评审 §五.4）：
#   六个适配仓（fnos/qnap/openwrt/synology/ugreen/terramaster）此前**没有任何
#   统一的能力声明**——「这个平台支持什么」散落在各仓 README 与打包脚本里靠人记
#   ⇒ 新增部署面靠口头传承，回归只能靠真机踩坑（NAS 预接线四问题、pb 缺失静默
#   降级都属此类）。本门禁把声明钉成机器可读契约 + **可执行判据**：
#
#   ① 结构：capability_fields 与六平台 capabilities **双向全覆盖**；
#      每字段必有 acceptance（允许的判据类型）；每条 true/false 必有 probe+evidence；
#      unknown 必有 todo（不许「填不了」却不说怎么办）；
#   ② 实测：平台仓在场时逐条执行 probe（file/grep/absent/nogrep），
#      **声明值与实测不符 ⇒ 红**（issue 验收的第一条）；
#   ③ 矩阵：docs/platform-compatibility-matrix.md 必须 == 由声明重新生成的结果
#      （issue 验收的第二条：矩阵由生成/对账产出，不手工双维护）；
#   ④ selfcheck：删字段/坏判据/unknown 无 todo/实测不符/矩阵漂移 ⇒ 必红。
#
# 检出形态（三态，与 check-nas-prewire-consistency.sh 同口径）：
#   · 判定形态：CI 把六仓检出到 workspace/<name> ⇒ 结构 + 实测全跑；
#   · 跳过形态：本地单仓检出 ⇒ 六仓不在场 ⇒ 打印明确跳过原因，只跑结构 + 矩阵对账
#     （不能让「没扫到」看起来像「扫过且通过」）；
#   · 可用 CAP_PLATFORMS_ROOT 指向已拉齐的模块仓目录（如 hub 主检出）做全量实测。
#
# 用法：bash scripts/check-platform-capabilities.sh [--selfcheck]
set -uo pipefail

ROOT="${CAP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

PY="python3 scripts/platform_capabilities.py"
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ 没有 python3——门禁自身失效（契约解析/实测都靠它）"
  exit 1
fi

# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; if [ "$rc" -ne 0 ]; then exit $rc; fi; exit 0' EXIT

if [ "$SELFCHECK" -eq 1 ]; then
  echo "── 能力契约 selfcheck（负对照）"
  $PY selfcheck --root "$ROOT"
  exit $?
fi

echo "── 能力契约结构校验 + 判据实测（root=${ROOT}）"
# 平台仓检出根：CAP_PLATFORMS_ROOT 可指向已拉齐的模块仓（默认 = hub 根，
# CI 形态即检出到 workspace/<name>）。
PROOT="${CAP_PLATFORMS_ROOT:-$ROOT}"
$PY validate --root "$ROOT" --platforms-root "$PROOT" || exit 1

echo "── 兼容矩阵对账（生成物 == 生成结果）"
MATRIX="docs/platform-compatibility-matrix.md"
if [ ! -f "$MATRIX" ]; then
  echo "✗ 缺 ${MATRIX}——先跑 scripts/gen-platform-matrix.sh 生成"
  exit 1
fi
GEN=$(mktemp)
trap 'rc=$?; rm -f "$GEN"; if [ "$rc" -ne 0 ]; then exit $rc; fi; exit 0' EXIT
$PY matrix --root "$ROOT" >"$GEN" || exit 1
if ! diff -u "$MATRIX" "$GEN" >/dev/null 2>&1; then
  echo "✗ $MATRIX 与由声明重新生成的结果不一致（矩阵漂移）："
  diff -u "$MATRIX" "$GEN" | head -40
  echo "  修法：bash scripts/gen-platform-matrix.sh 重新生成后提交"
  exit 1
fi
echo "  ✓ 矩阵与声明一致"
echo "✓ 能力契约门禁通过"
