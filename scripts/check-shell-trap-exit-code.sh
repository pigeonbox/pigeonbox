#!/bin/sh
# 门禁：EXIT trap 必须**保留脚本的退出码**。
#
# 为什么有这道门禁（2026-10-31 实测）：
#   macOS 的 bash 3.2：脚本因**未定义变量**退出时，EXIT trap 入口处的 `$?` 是 **0**
#   （不是失败码）⇒ trap 体最后一条命令成功 ⇒ **脚本最终退出码变成 0**
#   ⇒ 症状是「脚本报了错、退出码却是 0」
#   ⇒ **本地 `&&` 链假绿、CI（Linux/dash）才红**。
#
#   对**门禁脚本**尤其致命：门禁失败却报 exit 0 ⇒ **门禁形同虚设**
#   （本轮修的 33 个脚本里，17 个是门禁/校验脚本）。
#
#   ⚠️ `trap 'rc=$?; ...; exit $rc'` **修不了**（rc 本身就是 0）——
#   正确形态是**成功哨兵**：`OK=1` 标记「跑到了结尾」，
#   trap 里 rc≠0 ⇒ 原样保留；rc=0 且 OK≠1 ⇒ 没跑到结尾却没留失败码 ⇒ 判失败。
#
# 判据：`trap '<动作>' EXIT`（字面动作）⇒ 动作里必须同时有
#   ① 取当前状态：`$?` / `${?}`
#   ② 把状态交还：`exit $<变量>`
# 函数式 trap（`trap cleanup EXIT`）静态判不了 ⇒ 只**列出**不判红。
#
# 用法：bash scripts/check-shell-trap-exit-code.sh [--selfcheck]
set -uo pipefail

ROOT="${SHELL_TRAP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *) echo "用法: $0 [--selfcheck]"; exit 2 ;;
  esac
done

# 扫描范围（相对 ROOT；空格分隔的 glob 列表）
SCAN_GLOBS="scripts/*.sh
fnos/scripts/*.sh
qnap/scripts/*.sh
qnap/tests/*.sh
openwrt/scripts/*.sh
synology/scripts/*.sh
synology/tests/*.sh
ugreen/scripts/*.sh
terramaster/scripts/*.sh
deploy/nas/*.sh
core/scripts/*.sh
contracts/scripts/*.sh
p2p/scripts/*.sh"

TMP_ALL=$(mktemp)
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -f "$TMP_ALL"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

SCANNED=0
for g in $SCAN_GLOBS; do
  dir="${g%/*}"
  [ -d "$dir" ] || continue
  for f in $g; do
    [ -f "$f" ] || continue
    SCANNED=$((SCANNED + 1))
    # 一次 awk 抽出所有 EXIT trap：字面动作输出到 TSV；函数式用 @FUNC@ 前缀
    LC_ALL=C awk '
      /^[[:space:]]*trap / && /EXIT/ {
        line = $0
        if (match(line, /'"'"'[^'"'"']*'"'"'/)) {
          act = substr(line, RSTART + 1, RLENGTH - 2)
          print FILENAME ":" FNR "\t" act
        } else {
          print FILENAME ":" FNR "\t@FUNC@" line
        }
      }' "$f" 2>/dev/null >> "$TMP_ALL"
  done
done

if [ "$SCANNED" -eq 0 ]; then
  echo "✗ 一个脚本都没扫到——门禁自身失效（路径/glob 变了？）"
  exit 1
fi

total=$(grep -c '' "$TMP_ALL" 2>/dev/null || echo 0)
if [ "$total" -eq 0 ]; then
  echo "✗ 一个 EXIT trap 都没扫到——门禁自身失效（脚本里没有 trap ... EXIT？）"
  exit 1
fi

# 判定
bad_list=$(grep -v $'\t@FUNC@' "$TMP_ALL" 2>/dev/null | while IFS="$(printf '\t')" read -r loc act; do
  [ -n "$loc" ] || continue
  has_status=$(printf '%s' "$act" | grep -c '\$[?{]' || true)
  has_exit=$(printf '%s' "$act" | grep -cE 'exit[[:space:]]+"?\$\{?[A-Za-z_?]' || true)
  if [ "$has_status" -eq 0 ] || [ "$has_exit" -eq 0 ]; then
    printf '    %s\t%s\n' "$loc" "$act"
  fi
done)

func_list=$(grep $'\t@FUNC@' "$TMP_ALL" 2>/dev/null | sed 's/^/    /' || true)

echo "→ 扫到 ${total} 处 EXIT trap（${SCANNED} 个脚本）"

if [ -n "$bad_list" ]; then
  echo "✗ 以下 EXIT trap 不保留退出码（bash 3.2 下未定义变量失败会被报成 exit 0）:"
  printf '%s\n' "$bad_list"
  echo
  echo "  修法（成功哨兵）: 跑完的位置置 OK=1；trap 里写成"
  echo "    trap 'rc=\$?; <清理>; if [ \"\$rc\" -ne 0 ]; then exit \$rc; fi;"
  echo "          if [ \"\${OK:-0}\" != 1 ]; then exit 1; fi; exit 0' EXIT"
  echo "  ⚠️ 每个 exit 0 之前都要置 OK=1（只在末尾置一次会漏掉中间的出口）。"
  exit 1
fi

if [ -n "$func_list" ]; then
  echo "! 以下是**函数式** trap（静态判不了，人工确认其函数是否保留退出码）:"
  printf '%s\n' "$func_list"
fi

echo "✓ 所有字面 EXIT trap 都保留了退出码"

# ── 自证：注入一个不保留退出码的 trap ⇒ 本门禁必须变红 ────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  mkdir -p "$SELF_TMP/scripts"
  self_fail=0

  printf '#!/bin/sh\nset -eu\ntrap %s EXIT\necho hi\n' "'rm -rf \"\$TMPD\"'" \
    > "$SELF_TMP/scripts/bad.sh"
  if SHELL_TRAP_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shell-trap-exit-code.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「不保留退出码的 trap」后本门禁仍绿 ⇒ 判据无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「不保留退出码的 trap」⇒ 本门禁变红（判据有牙齿）"
  fi

  printf '#!/bin/sh\nset -eu\nOK=0\ntrap %s EXIT\necho hi\nOK=1\n' \
    "'rc=\$?; rm -rf \"\$TMPD\"; if [ \"\$rc\" -ne 0 ]; then exit \$rc; fi; if [ \"\${OK:-0}\" != 1 ]; then exit 1; fi; exit 0'" \
    > "$SELF_TMP/scripts/good.sh"
  if SHELL_TRAP_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shell-trap-exit-code.sh" >/dev/null 2>&1; then
    echo "  ✓ 注入合规 trap ⇒ 本门禁保持绿（无误报）"
  else
    echo "  ✗ 合规形态被误判为红 ⇒ 门禁误报" >&2
    self_fail=1
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：注入坏 trap ⇒ 本门禁变红、合规形态保持绿 ⇒ 门禁有牙齿"
fi
OK=1
