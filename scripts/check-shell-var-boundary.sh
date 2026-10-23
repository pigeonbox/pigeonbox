#!/bin/sh
# 门禁：shell 脚本里 **变量名后紧跟非 ASCII 字符**（全角括号/冒号/汉字等）
# ⇒ bash/ash 把非 ASCII 当标识符字符 ⇒ 变量名被吞成 "VAR（…" ⇒
#   - 带 set -u：脚本当场炸 "VAR（: unbound variable"（错误信息莫明其妙）
#   - 不带 set -u：静默取到**空值**（更坏：拼出错的路径/URL）
#
# 实录（2026-10-24）：冒烟脚本 `"…（used=${S20A_USED}）"` ⇒ 全角右括号紧跟变量名
# ⇒ 变量名变成 "S20A_USED）" ⇒ 脚本在第 527 行炸；运维脚本里的 `${TAG}（` 同类。
# 这一类 shellcheck **不会报**（语法合法，只是变量名不对）⇒ 只能机械拦。
#
# 判据：`$VAR` 后紧跟 [^\x00-\x7F] ⇒ 报错（`${VAR}` 显式花括号写法不误报）。
# 用法：bash scripts/check-shell-var-boundary.sh
set -eu
cd "$(dirname "$0")/.."

BAD=0
for f in scripts/*.sh; do
    [ -f "$f" ] || continue
    # 逐行找「$变量 + 非 ASCII 字节」；排除 ${VAR} 显式写法
    HITS=$(grep -nE '\$[A-Za-z_][A-Za-z_0-9]*[^ -~]' "$f" | grep -vE '\$\{' || true)
    if [ -n "$HITS" ]; then
        BAD=1
        echo "✗ ${f}：变量名后紧跟非 ASCII 字符（bash 会把它并进变量名）:"
        printf '%s\n' "$HITS" | sed 's/^/    /'
    fi
done

if [ "$BAD" -ne 0 ]; then
    echo ""
    echo "修法：把变量写成 \${VAR}（显式花括号），或让非 ASCII 字符与变量名之间隔开。"
    exit 1
fi
echo "✓ shell 变量名边界检查通过（scripts/*.sh）"
