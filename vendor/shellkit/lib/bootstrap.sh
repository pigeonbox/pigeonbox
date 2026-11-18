#!/usr/bin/env bash
#
# shellkit 唯一入口。source 本文件即可获得全部核心函数。
#
# 全库强制约定：
#   1. stdout 只给数据，日志一律 stderr
#   2. 出参用 printf -v，函数不直接改调用方变量
#   3. 取值优先级：显式参数 > 环境变量 > 配置文件 > 默认值
#   4. 写文件必原子
#   5. 本库不改变调用方的 shell 选项，也不改变 cwd
#
# 加载哪些模块由 SHELLKIT_MODULES 决定（不设 = 全部模块）：
#   SHELLKIT_MODULES="log fs"   只加载这两个模块和它们的传递依赖
#   i18n 恒定加载（_t 是公共依赖）

SHELLKIT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
export SHELLKIT_HOME

SHELLKIT_DEBUG="${SHELLKIT_DEBUG:-0}"
SHELLKIT_COLOR="${SHELLKIT_COLOR:-auto}"
SHELLKIT_NONINTERACTIVE="${SHELLKIT_NONINTERACTIVE:-0}"
SHELLKIT_TMP_KEEP="${SHELLKIT_TMP_KEEP:-0}"
export SHELLKIT_DEBUG SHELLKIT_COLOR SHELLKIT_NONINTERACTIVE SHELLKIT_TMP_KEEP

# 最近一次 log_error 的内容，供调用方在退出前读取
# 跨模块读写的公开变量
# shellcheck disable=SC2034
SK_ERRMSG=""

SK_OK=0
SK_ERR=1
SK_USAGE=2
SK_PRECOND=3
SK_NET=4
SK_VERIFY=5
export SK_OK SK_ERR SK_USAGE SK_PRECOND SK_NET SK_VERIFY

export TEXTDOMAIN="${TEXTDOMAIN:-shellkit}"
export TEXTDOMAINDIR="${TEXTDOMAINDIR:-$SHELLKIT_HOME/locale}"

if [ -r "$SHELLKIT_HOME/VERSION" ]; then
  SK_VERSION=$(tr -d '[:space:]' <"$SHELLKIT_HOME/VERSION")
else
  SK_VERSION="dev"
fi
export SK_VERSION

# 模块清单来自 lib/modules.txt —— 顺序与依赖只有一处，不再两处各写一份。
#
# 清单是两列的：第一列模块名，第二列它依赖的模块（空格分隔，可省略，必须排在
# 它前面）。第二列是「直接依赖」，两处用它：
#   - 这里：SHELLKIT_MODULES 只加载用得上的模块（连同传递依赖的闭包）
#   - tools/check_module_order.sh：查依赖声明是否完整、顺序是否自洽
#
# 少写一个模块不是灾难：tools/check_module_order.sh 会查出来。
_sk_mod_names=()
_sk_mod_deps=()

# 读清单：第一列模块名，第二列直接依赖（空白分隔）
_sk_module_manifest() {
  local __f="$SHELLKIT_HOME/lib/modules.txt" __line __name __rest __w __deps
  [ -r "$__f" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%%#*}"
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    __name="${__line%%[[:space:]]*}"
    [ -n "$__name" ] || continue
    __rest="${__line#"$__name"}"
    __deps=""
    for __w in $__rest; do
      __deps="$__deps $__w"
    done
    _sk_mod_names[${#_sk_mod_names[@]}]="$__name"
    _sk_mod_deps[${#_sk_mod_deps[@]}]="${__deps# }"
  done <"$__f"
}

# 模块名 -> 序号。Bash 3.2 没有关联数组，模块又只有十几个，线性查找足够。
# 序号写进 $2 指定的变量（出参用 printf -v）。
_sk_mod_index() {
  local __i=0 __n
  for __n in ${_sk_mod_names[@]+"${_sk_mod_names[@]}"}; do
    if [ "$__n" = "$1" ]; then
      printf -v "$2" '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# 要加载的模块，顺序仍是 lib/modules.txt 的原始顺序，输出成一行空格分隔。
#
# SHELLKIT_MODULES 为空 -> 全部模块；不为空 -> 它指定的模块 + 传递依赖（闭包）。
# i18n 恒定加载：_t 是公共依赖。
_sk_mod_select() {
  local __reqs="" __sel=" " __pend="" __cur __deps __w __idx __i __n __out

  for __cur in ${SHELLKIT_MODULES:-}; do
    __reqs="$__reqs$__cur "
  done

  if [ -n "$__reqs" ]; then
    # 清单里没有的模块直接报错：宁可启动失败，也不要少加载一个模块
    for __cur in $__reqs; do
      if ! _sk_mod_index "$__cur" __idx; then
        printf 'shellkit: unknown module in SHELLKIT_MODULES: %s\n' "$__cur" >&2
        return "$SK_PRECOND"
      fi
      case "$__sel" in
        *" $__cur "*) ;;
        *)
          __sel="$__sel$__cur "
          __pend="$__pend$__cur "
          ;;
      esac
    done
  else
    # 全部模块：集合就是清单本身
    for __n in ${_sk_mod_names[@]+"${_sk_mod_names[@]}"}; do
      __sel="$__sel$__n "
    done
  fi

  # 清单里的依赖必须都存在（两种模式都查：写错依赖名要当场发现）
  __i=0
  for __n in ${_sk_mod_names[@]+"${_sk_mod_names[@]}"}; do
    __deps="${_sk_mod_deps[$__i]}"
    for __w in $__deps; do
      if ! _sk_mod_index "$__w" __idx; then
        printf 'shellkit: module %s depends on an unknown module: %s\n' "$__n" "$__w" >&2
        return "$SK_PRECOND"
      fi
    done
    __i=$((__i + 1))
  done

  # 传递闭包：把每个选中模块的依赖也拉进来
  while [ -n "$__pend" ]; do
    __cur="${__pend# }"
    __cur="${__cur%% *}"
    __pend="${__pend#* }"
    if ! _sk_mod_index "$__cur" __idx; then
      continue
    fi
    __deps="${_sk_mod_deps[$__idx]}"
    for __w in $__deps; do
      case "$__sel" in
        *" $__w "*) ;;
        *)
          __sel="$__sel$__w "
          __pend="$__pend$__w "
          ;;
      esac
    done
  done

  # i18n 恒定加载
  if _sk_mod_index i18n __idx; then
    case "$__sel" in
      *" i18n "*) ;;
      *) __sel="$__sel i18n " ;;
    esac
  fi

  __out=""
  for __n in ${_sk_mod_names[@]+"${_sk_mod_names[@]}"}; do
    case "$__sel" in
      *" $__n "*) __out="$__out $__n" ;;
    esac
  done
  printf '%s\n' "${__out# }"
}

if ! _sk_module_manifest; then
  printf 'shellkit: cannot read module list: %s\n' "$SHELLKIT_HOME/lib/modules.txt" >&2
  return 1 2>/dev/null || exit 1
fi

_sk_mod_selection=$(_sk_mod_select) || _sk_mod_rc=$?
_sk_mod_rc=${_sk_mod_rc:-0}
if [ "$_sk_mod_rc" -ne 0 ]; then
  unset _sk_mod_selection _sk_mod_names _sk_mod_deps
  unset -f _sk_module_manifest _sk_mod_index _sk_mod_select
  return "$_sk_mod_rc" 2>/dev/null || exit "$_sk_mod_rc"
fi

case "${SHELLKIT_DEBUG:-0}" in
  1 | true | yes | on)
    printf 'shellkit: debug: loading modules: %s\n' "$_sk_mod_selection" >&2
    ;;
esac

for _sk_module in $_sk_mod_selection; do
  if [ ! -f "$SHELLKIT_HOME/lib/core/${_sk_module}.sh" ]; then
    printf 'shellkit: module listed in modules.txt is missing: %s\n' "${_sk_module}" >&2
    unset _sk_mod_selection
    return 1 2>/dev/null || exit 1
  fi
  if ! . "$SHELLKIT_HOME/lib/core/${_sk_module}.sh"; then
    printf 'shellkit: failed to load module: %s\n' "${_sk_module}" >&2
    unset _sk_mod_selection
    return 1 2>/dev/null || exit 1
  fi
done
unset _sk_module _sk_mod_selection _sk_mod_rc _sk_mod_names _sk_mod_deps
unset -f _sk_module_manifest _sk_mod_index _sk_mod_select
