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
# 判据：`$VAR` 后紧跟**非 ASCII 字节** ⇒ 报错（`${VAR}` 显式花括号写法不误报）。
#
# ⚠️ 2026-10-26 审计 P2 两处修法：
#   ① **扫描范围扩到 NAS 各仓**：此前只扫 hub 的 `scripts/*.sh`
#      ⇒ NAS 仓的运维脚本（fnos/qnap/openwrt/synology/ugreen/terramaster）
#      不在射程内 ⇒ 下一份 NAS 脚本里出现「变量名后紧跟全角括号」时本门禁全绿，
#        而真机脚本当场炸或静默拼错路径。
#      各 NAS 仓在 hub 工作区里是**独立 git 仓**（被 gitignore）⇒
#      不在位时**跳过并告警**（不硬失败）；hub CI 里用 checkout 把它们检出到
#      同一 workspace ⇒ 射程自动覆盖。
#   ② 判据里的 `[^ -~]` 改成**显式非 ASCII 区间**（原写法把 TAB 也算非 ASCII
#      ⇒ 理论上会误报）：用 awk 的八进制区间 `[^\040-\176]`（可打印 ASCII 的补集）
#      —— `grep -P` 在 macOS/BSD grep 上不存在、`[[:ascii:]]` 也不被支持，
#      故用 awk（POSIX 可靠）。
#
# 用法: bash scripts/check-shell-var-boundary.sh [--selfcheck]
#   --selfcheck:自证模式——注入「变量名后紧跟全角括号」⇒ 本门禁必须变红
set -eu

ROOT="${SHELL_VAR_BOUNDARY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# 扫描范围（相对 ROOT；空格分隔的 glob 列表）
SCAN_GLOBS="scripts/*.sh
fnos/scripts/*.sh
fnos/fnos/cmd/*
qnap/qpkg/shared/*.sh
qnap/scripts/*.sh
openwrt/scripts/*.sh
openwrt/openwrt/pigeonbox.*
synology/scripts/*.sh
ugreen/scripts/*.sh
terramaster/scripts/*.sh"

# 排除清单（已知命中但**不在打包链路** ⇒ 不误伤）
is_excluded() {
    case "$1" in
        legacy/* | */legacy/*) return 0 ;;
        core/scripts/gen-router.sh) return 0 ;;
        skills/* | */skills/*) return 0 ;;
    esac
    return 1
}

BAD=0
SCANNED=0
SKIPPED_ROOTS=""

for g in $SCAN_GLOBS; do
    dir="${g%/*}"
    [ -d "$dir" ] || {
        case "$dir" in
            scripts) : ;;
            *) SKIPPED_ROOTS="$SKIPPED_ROOTS $dir" ;;
        esac
        continue
    }
    for f in $g; do
        [ -f "$f" ] || continue
        is_excluded "$f" && continue
        SCANNED=$((SCANNED + 1))
        # 逐行找「$变量 + 非 ASCII 字节」（`${VAR}` 显式写法不匹配：$ 后面是 {）
        HITS=$(LC_ALL=C awk '/\$[A-Za-z_][A-Za-z_0-9]*[^\040-\176]/ {
            print FILENAME ":" FNR ":" $0
        }' "$f")
        if [ -n "$HITS" ]; then
            BAD=1
            echo "✗ ${f}：变量名后紧跟非 ASCII 字符（bash 会把它并进变量名）:"
            printf '%s\n' "$HITS" | sed 's/^/    /'
        fi
    done
done

if [ -n "$SKIPPED_ROOTS" ]; then
    echo "! 跳过（目录不在位，hub CI 单仓 checkout 时 NAS 仓不在 workspace）:$SKIPPED_ROOTS"
fi
echo "  （共扫 $SCANNED 个脚本）"

if [ "$BAD" -ne 0 ]; then
    echo ""
    echo "修法：把变量写成 \${VAR}（显式花括号），或让非 ASCII 字符与变量名之间隔开。"
    exit 1
fi

# ── 自证：注入「变量名后紧跟全角括号」⇒ 本门禁必须变红 ──────────────────────
if [ "${1:-}" = "--selfcheck" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/scripts" "$TMP/openwrt/openwrt" "$TMP/fnos/scripts"
    : > "$TMP/scripts/ok.sh"
    : > "$TMP/openwrt/openwrt/pigeonbox.init"
    : > "$TMP/fnos/scripts/ok.sh"
    # 注入一处真实缺陷（$VAR 后紧跟全角括号）
    # 注入一处真实缺陷：变量名后紧跟全角左括号（U+FF08）。
    # 用 printf 的八进制转义拼出来,免得**本脚本自身**含有那个字面量
    # （否则本门禁会把自己判红）。
    FW_OPEN=$(printf '\357\274\210')
    # shellcheck disable=SC2016  # 单引号里的 $VAR 是**要注入的坏例子**,不该被展开
    printf 'echo "坏例子=$VAR%s单位）"\n' "$FW_OPEN" > "$TMP/openwrt/openwrt/pigeonbox.init"
    if SHELL_VAR_BOUNDARY_ROOT="$TMP" sh "$ROOT/scripts/check-shell-var-boundary.sh" >/dev/null 2>&1; then
        echo "✗ 自证失败：注入「变量名后紧跟全角括号」后本门禁仍绿 ⇒ 门禁空转" >&2
        exit 1
    fi
    echo "✓ 自证：注入「变量名后紧跟全角括号」后本门禁变红 ⇒ 门禁有牙齿"
    # 去掉注入后必须恢复绿
    : > "$TMP/openwrt/openwrt/pigeonbox.init"
    if SHELL_VAR_BOUNDARY_ROOT="$TMP" sh "$ROOT/scripts/check-shell-var-boundary.sh" >/dev/null 2>&1; then
        echo "✓ 自证：移除注入后本门禁恢复绿"
    else
        echo "✗ 自证失败：移除注入后仍红 ⇒ 门禁有误报" >&2
        exit 1
    fi
fi

echo "✓ shell 变量名边界检查通过（hub scripts + NAS 各仓运维脚本）"
