#!/usr/bin/env bash
#
# shellkit 修复脚本 —— 不依赖已安装的 ShellKit 库。
#
# 什么时候需要它：安装（install-self）或 vendor 同步在「旧目录已经移走、
# 新目录还没就位」的瞬间被中断（SIGKILL / 断电 / 磁盘满），装好的 shellkit
# 就此起不来：恢复逻辑写在 CLI 里，而 CLI 自己就是那个起不来的东西。
# 备份不一定丢 —— 缺的是一个不依赖 CLI 的恢复入口。
#
# 这个脚本自己什么依赖都不带：只用 bash 内建 + 常见的 POSIX 工具。
# 它把中断留下的 .old / .new 残骸收拾干净，让 shellkit 重新可用。
#
#   curl -fsSL https://raw.githubusercontent.com/yi-nology/shellkit/main/repair.sh | bash
#   ./repair.sh --prefix ~/.local
#   ./repair.sh --project ./my-app --check
#
# 退出码：0 修好了（或本来就没事）/ 1 修不好（得重装）/ 2 用法错
set -u

PROG=repair.sh
SK_OK=0
SK_ERR=1
SK_USAGE=2

PREFIX=""
PROJECTS=""
CHECK=0
FAILED=0

say() { printf '%s\n' "$*" >&2; }
ok() { printf '[ OK ] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local __msg=$1 __code=${2:-$SK_ERR}
  printf '[FAIL] %s\n' "$__msg" >&2
  exit "$__code"
}

usage() {
  printf 'Usage: %s [options]\n' "$PROG" >&2
  cat >&2 <<'EOF'

  --prefix DIR     修 PREFIX 下的已安装副本（PREFIX/share/shellkit）
  --project DIR    修某个工程里的 vendor 副本（可重复）
  --check          只报告，不动手
  -h, --help       显示本帮助

不给 --prefix 时：脚本先从自己的位置反推 PREFIX
（装好的副本长这样：PREFIX/share/shellkit/repair.sh），
反推不出来就试默认位置（/usr/local 与 ~/.local）。
EOF
}

# _complete DIR —— 这个目录是不是一份完整的、起得来的 shellkit 副本
#
# 只看 lib/bootstrap.sh 太宽：bootstrap 按 lib/modules.txt 的顺序 source
# lib/core/*.sh，缺了清单或任何模块它照样起不来 —— 那样的半份副本不能当
# 「完整」用，否则会把唯一的好备份删掉再宣布「已恢复可用」（issue #41）。
# 判据升级为「这份副本能不能真的跑起来」：
#   1) lib/bootstrap.sh 在
#   2) lib/modules.txt 在且可读
#   3) 清单里列出的每个模块 lib/core/<name>.sh 都在
#   4) VERSION 在且可读
#   5) CLI（副本根上的 shellkit）在且可执行
# 目标本身是符号链接也判不完整：跟着链接看内容，会把外面的东西当成本地的。
_complete() {
  local __d=${1:-} __line __mod __rc=0
  [ -n "$__d" ] || return 1
  [ -L "$__d" ] && return 1
  [ -f "$__d/lib/bootstrap.sh" ] || return 1
  [ -r "$__d/lib/modules.txt" ] || return 1
  [ -r "$__d/VERSION" ] || return 1
  [ -f "$__d/shellkit" ] && [ -x "$__d/shellkit" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line=${__line%%#*}
    case "$__line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    __mod=${__line%%[[:space:]]*}
    [ -n "$__mod" ] || continue
    if [ ! -f "$__d/lib/core/$__mod.sh" ]; then
      return 1
    fi
  done <"$__d/lib/modules.txt"
  return "$__rc"
}

# _slot_guard PATH —— 这个路径像不像一个可以动刀的 shellkit 槽位
#
# rm -rf 之前必须过这一关：路径拼错一次就是把用户整个家目录删掉。
# 认得的形状只有两种：<prefix>/share/shellkit 与 <project>/vendor/shellkit。
# .broken 是恢复状态机里「被挪开等验证的坏主副本」的暂存位，同属槽位。
_slot_guard() {
  case "${1:-}" in
    */share/shellkit | */share/shellkit.old | */share/shellkit.new | */share/shellkit.broken) return 0 ;;
    */vendor/shellkit | */vendor/.shellkit-old | */vendor/.shellkit-new | */vendor/.shellkit-broken) return 0 ;;
  esac
  return 1
}

# _rm PATH —— 删一个残骸目录（先过形状检查）
_rm() {
  local __p=${1:-}
  [ -n "$__p" ] || return 0
  if ! _slot_guard "$__p"; then
    warn "refusing to remove an unexpected path: $__p"
    FAILED=1
    return 1
  fi
  rm -rf "$__p" 2>/dev/null || {
    warn "failed to remove: $__p"
    FAILED=1
    return 1
  }
  return 0
}

# _repair LABEL MAIN OLD NEW BROKEN —— 收拾一个槽位
#
# 恢复状态机（issue #41）：关键一条是**在确认主副本真的可用之前，
# 不删唯一的完整备份** —— 先删后说会把「可恢复」变成「不可恢复」。
#
# BROKEN 是「被挪开等验证的坏主副本」的暂存位，槽位的形状决定它的名字：
# <prefix>/share/shellkit.broken 与 <project>/vendor/.shellkit-broken。
#
# 状态与动作：
#   1) 主副本完整           → 残骸（.old / .new / .broken）是垃圾，清掉
#   2) 主副本不完整、旧副本完整 → 旧副本挪回去；坏的主副本先挪到 BROKEN 暂存，
#                              挪完**验证通过**才清掉 —— 验证不过就把两份都放回原位
#   3) 两份都不完整          → 拒绝，明说「得重装」，**什么都不删**
#   4) 恢复中被打断          → 可重入：BROKEN 是固定名，重跑从中间态继续
_repair() {
  local __label=$1 __main=$2 __old=$3 __new=$4 __broken=$5
  local __main_ok=0 __old_ok=0

  if [ ! -e "$__main" ] && [ ! -e "$__old" ] && [ ! -e "$__new" ] && [ ! -e "$__broken" ]; then
    return 0
  fi
  if _complete "$__main"; then
    __main_ok=1
  fi
  if _complete "$__old"; then
    __old_ok=1
  fi

  if [ "$__main_ok" = "1" ]; then
    if [ -e "$__old" ]; then
      if [ "$CHECK" = "1" ]; then
        warn "$__label: a leftover old copy is there: $__old"
      else
        _rm "$__old" && ok "$__label: removed the leftover old copy"
      fi
    fi
    if [ -e "$__new" ]; then
      if [ "$CHECK" = "1" ]; then
        warn "$__label: a leftover staging directory is there: $__new"
      else
        _rm "$__new" && ok "$__label: removed the leftover staging directory"
      fi
    fi
    if [ -e "$__broken" ]; then
      # 上一次恢复留下的坏主副本：主副本已经验证完整，这份才是真垃圾
      if [ "$CHECK" = "1" ]; then
        warn "$__label: a leftover broken copy is there: $__broken"
      else
        _rm "$__broken" && ok "$__label: removed the leftover broken copy"
      fi
    fi
    return 0
  fi

  # 主副本不可用：只有旧副本能救它
  if [ "$__old_ok" = "1" ]; then
    if [ "$CHECK" = "1" ]; then
      warn "$__label: broken, but the old copy is complete — rerun without --check to restore"
      FAILED=1
      return 0
    fi
    # 坏的主副本先挪到固定暂存位，**不删**：旧副本挪回去之后要验证，
    # 验证不过就原样放回。中途被打断也安全 —— .broken 固定名，重跑能接上。
    if [ -e "$__main" ] || [ -L "$__main" ]; then
      _rm "$__broken" || return 1
      if ! mv "$__main" "$__broken"; then
        warn "$__label: failed to move the broken copy aside: $__main"
        FAILED=1
        return 1
      fi
    fi
    if ! mv "$__old" "$__main"; then
      warn "$__label: failed to move the old copy back: $__old"
      FAILED=1
      return 1
    fi
    if _complete "$__main"; then
      ok "$__label: restored from the old copy"
      # 验证通过，被挪开的坏主副本这时才真的是垃圾
      _rm "$__broken" || true
      if [ -e "$__new" ]; then
        _rm "$__new" || true
      fi
      return 0
    fi
    # 挪回去的旧副本验证不过（不该发生）：原样放回，两份都不动
    warn "$__label: the restored copy did not verify; putting both copies back"
    if ! mv "$__main" "$__old"; then
      warn "$__label: failed to put the old copy back: $__old"
      FAILED=1
      return 1
    fi
    if [ -e "$__broken" ] || [ -L "$__broken" ]; then
      if ! mv "$__broken" "$__main"; then
        warn "$__label: failed to put the broken copy back: $__main"
        FAILED=1
        return 1
      fi
    fi
    FAILED=1
    return 1
  fi

  # 两份都靠不住：什么都不删，明说「得重装」
  warn "$__label: nothing to restore from — reinstall shellkit"
  FAILED=1
  return 1
}

# _prefix_from_self —— 从脚本自己的位置反推 PREFIX
#
# 装好的副本长这样：PREFIX/share/shellkit/repair.sh；
# 被中断时旧副本还在：PREFIX/share/shellkit.old/repair.sh。
# 这条路径就是「只剩已安装副本、没有源码仓库」那台机器的入口。
_prefix_from_self() {
  local __self=${BASH_SOURCE[0]:-} __dir
  [ -n "$__self" ] || return 1
  __dir=$(cd -P "$(dirname "$__self")" 2>/dev/null && pwd) || return 1
  case "$__dir" in
    */share/shellkit | */share/shellkit.old | */share/shellkit.new)
      printf '%s' "${__dir%/share/shellkit*}"
      return 0
      ;;
  esac
  return 1
}

# _default_prefix —— 没有 --prefix 也没有自推位置时用哪儿
_default_prefix() {
  if [ -w /usr/local/bin ] || [ "$(id -u)" = "0" ]; then
    printf '%s' "/usr/local"
  else
    printf '%s/.local' "${HOME:-/tmp}"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      shift
      [ $# -ge 1 ] || die "--prefix needs an argument" "$SK_USAGE"
      PREFIX=$1
      ;;
    --prefix=*)
      PREFIX=${1#*=}
      ;;
    --project)
      shift
      [ $# -ge 1 ] || die "--project needs an argument" "$SK_USAGE"
      PROJECTS="${PROJECTS}${1}
"
      ;;
    --project=*)
      PROJECTS="${PROJECTS}${1#*=}
"
      ;;
    --check)
      CHECK=1
      ;;
    -h | --help)
      usage
      exit "$SK_OK"
      ;;
    *)
      die "unknown option: $1" "$SK_USAGE"
      ;;
  esac
  shift
done

if [ -z "$PREFIX" ]; then
  PREFIX=$(_prefix_from_self) || PREFIX=""
fi
if [ -z "$PREFIX" ]; then
  PREFIX=$(_default_prefix)
fi
PREFIX="${PREFIX%/}"

say "shellkit repair"
if [ "$CHECK" = "1" ]; then
  say "mode: check only (nothing will be changed)"
fi

# ---- 已安装的副本 ----
_repair "installed copy ($PREFIX)" \
  "$PREFIX/share/shellkit" "$PREFIX/share/shellkit.old" "$PREFIX/share/shellkit.new" \
  "$PREFIX/share/shellkit.broken"

# ---- 工程里的 vendor 副本 ----
while IFS= read -r __proj; do
  [ -n "$__proj" ] || continue
  _repair "vendored copy ($__proj)" \
    "$__proj/vendor/shellkit" "$__proj/vendor/.shellkit-old" "$__proj/vendor/.shellkit-new" \
    "$__proj/vendor/.shellkit-broken"
done <<EOF
$PROJECTS
EOF

if [ "$FAILED" != "0" ]; then
  die "some copies could not be restored — reinstall shellkit" "$SK_ERR"
fi

if _complete "$PREFIX/share/shellkit"; then
  ok "the installed copy is usable again: $PREFIX/bin/shellkit"
else
  say "no installed copy under $PREFIX — nothing to repair there"
fi
exit "$SK_OK"
