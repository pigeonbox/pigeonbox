#!/usr/bin/env bash
# check-docs-consistency.sh — 文档与代码对账门禁（2026-10-26 审计新增）
#
# 背景：本项目有两份「代码是真相、文档靠人同步」的清单，历史上**没有任何门禁**
# ⇒ 漂移会一直积累（实测：环境变量文档漏了 1 个 PB_*；错误码对照表漏了 1 个码）。
# ⇒ 这里把两条对账做成机械检查，CI 必跑。
#
# 检查项：
#   ① docs-site/guide/error-codes.md 的码表 ⊇ contracts/errcode 的**全部常量码**
#      （只取 `Code* = NNNNN` 形式的常量；范围判定用的 10999/50000/59999 不算码）
#   ② docs/ENVIRONMENT_VARIABLES.md ⊇ core 启动引导里绑定的**全部 PB_* 变量**
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

# ── ① 错误码对照表 ⊇ errcode 常量 ───────────────────────────────────────────
ERRCODE_FILE="contracts/errcode/errcode.go"
ERRCODE_DOC="docs-site/guide/error-codes.md"
[ -f "$ERRCODE_FILE" ] || fail "找不到 $ERRCODE_FILE"
[ -f "$ERRCODE_DOC" ] || fail "找不到 $ERRCODE_DOC"

missing=""
# 只匹配常量声明行（`CodeXxx = 12345`），排除 if/return 里的范围字面量
# （while read 而非 for-in-$(...)：SC2013 —— 逐行读更稳，也不受 IFS 影响）
grep -oE '^\s*Code[A-Za-z0-9]+\s*=\s*[0-9]{5}' "$ERRCODE_FILE" \
  | grep -oE '[0-9]{5}' | sort -u > /tmp/.pb-errcode-codes.$$
while IFS= read -r code; do
  [ -n "$code" ] || continue
  grep -q "$code" "$ERRCODE_DOC" || missing="$missing $code"
done < /tmp/.pb-errcode-codes.$$
rm -f /tmp/.pb-errcode-codes.$$
if [ -n "$missing" ]; then
  fail "错误码对照表缺码（${ERRCODE_DOC}）:$missing —— 补表或说明该码已退役"
fi

# ── ② 环境变量文档 ⊇ core 绑定的 PB_* ───────────────────────────────────────
ENV_DOC="docs/ENVIRONMENT_VARIABLES.md"
BIND_FILE="core/bootstrap/config.go"
[ -f "$ENV_DOC" ] || fail "找不到 $ENV_DOC"
[ -f "$BIND_FILE" ] || fail "找不到 $BIND_FILE"

missing=""
for v in $(grep -oE '"PB_[A-Z0-9_]+"' "$BIND_FILE" | tr -d '"' | sort -u); do
  grep -q "$v" "$ENV_DOC" || missing="$missing $v"
done
if [ -n "$missing" ]; then
  fail "环境变量文档缺项（${ENV_DOC}）:$missing —— 补文档（绑定在 core 启动引导里）"
fi

echo "✓ 文档对账通过：错误码表与环境变量文档均覆盖代码中的全部条目"
