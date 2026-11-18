#!/usr/bin/env bash
#
# 清单注册表：扫描「每行 KEY=VALUE」的清单文件，提供字段查询、
# 平台可见性判定与依赖拓扑排序。
#
# 边界：这个模块不认识任何领域字段名。哪些 KEY 是「平台」「依赖」，
# 由调用方在调用时传进来（registry_visible NAME FIELD / registry_deps NAME FIELD）。
# 清单格式与 unix_script 的 .manifest 同构，因此那 78 个模块的清单零改动即可用。
#
# 全局变量：
#   _REGISTRY_ROOT     扫描根目录
#   _REGISTRY_ENTRIES  条目名，空格分隔
#   _REGISTRY_FILES    name=path 对，**每行一个**（路径里可能有空格，不能用空格分隔）
#   _REGISTRY_NAMES/_REGISTRY_PATHS/_REGISTRY_BLOBS  与上面同序的平行数组（3.2 无关联数组），
#     其中 BLOBS 存清单**全文**：扫描时一次读进内存，查询全走内存。
#
# ★ 为什么把全文读进内存（2026-11-12，unix_script 菜单实测）：
#   旧实现 registry_get 每次查询 fork 一个 awk，实测 **48ms/次**；
#   一个菜单要读几百次字段（每分类还要全表扫一遍）⇒ build_list 本机 21.7s、Pi 7s，
#   用户进一次菜单要干等半分钟到一分半。读文件用 bash 内建 $(<file)（不 fork），
#   查询用纯 bash 字符串循环 ⇒ 同语义、零 fork。

_REGISTRY_ROOT=""
_REGISTRY_ENTRIES=""
_REGISTRY_FILES=""
_REGISTRY_NAMES=()
_REGISTRY_PATHS=()
_REGISTRY_BLOBS=()

# _registry_scan_one ROOT PATTERN —— 把一个根目录下的清单并进索引（**不重置**）
# @exitcode 0 总是成功
_registry_scan_one() {
  local __root="${1:-}" __pat="${2:-}" __f __dir __name
  [ -n "$__root" ] && [ -d "$__root" ] || return 0
  [ -n "$__pat" ] || return 0
  for __f in "$__root"/*/"$__pat"; do
    [ -f "$__f" ] || continue
    __dir="$(dirname "$__f")"
    __name="$(basename "$__dir")"
    registry_add "$__name" "$__f"
  done
  return 0
}

# registry_add NAME PATH —— 把一份清单文件登记进索引（条目名 = NAME）
# @brief 与 registry_scan 的区别：registry_scan 扫目录，registry_add 登记单份文件。
# @param NAME 条目名
# @param PATH 清单文件路径
# @exitcode 0 总是成功
# @stability stable
registry_add() {
  local __name=${1:-} __path=${2:-}
  [ -n "$__name" ] && [ -n "$__path" ] || return 0
  [ -f "$__path" ] || return 0
  case " $_REGISTRY_ENTRIES " in
    *" $__name "*) return 0 ;;
  esac
  if [ -z "$_REGISTRY_ENTRIES" ]; then
    _REGISTRY_ENTRIES="$__name"
  else
    _REGISTRY_ENTRIES="$_REGISTRY_ENTRIES $__name"
  fi
  if [ -z "$_REGISTRY_FILES" ]; then
    _REGISTRY_FILES="$__name=$__path"
  else
    printf -v _REGISTRY_FILES '%s\n%s' "$_REGISTRY_FILES" "$__name=$__path"
  fi
  # 全文进内存（bash 内建读，不 fork）；查询侧 registry_get 只认这份 blob。
  _REGISTRY_NAMES[${#_REGISTRY_NAMES[@]}]="$__name"
  _REGISTRY_PATHS[${#_REGISTRY_PATHS[@]}]="$__path"
  _REGISTRY_BLOBS[${#_REGISTRY_BLOBS[@]}]="$(<"$__path")"
  return 0
}

# registry_scan ROOT PATTERN —— 扫描清单文件并建立索引
# 条目名 = 清单文件所在目录名。PATTERN 是文件名模式（如 .manifest）。
# @exitcode 0 总是成功
# @stability stable
registry_scan() {
  local __root="${1:-}" __pat="${2:-}"
  _REGISTRY_ROOT="$__root"
  _REGISTRY_ENTRIES=""
  _REGISTRY_FILES=""
  _REGISTRY_NAMES=()
  _REGISTRY_PATHS=()
  _REGISTRY_BLOBS=()
  _registry_scan_one "$__root" "$__pat"
  return 0
}

# registry_scan_multi PATTERN ROOT... —— 扫描**多个**根目录的清单文件，建立一个索引
# @brief 与 registry_scan 的区别：registry_scan 每次调用都重建索引（一个工程一个根目录）；
# @brief 本函数一次扫多个根目录 —— 给「清单分散在多个目录」的工程用
# @brief （如 unix_script 的 `<分类>`/`<模块>`/.manifest 布局：每个分类目录各扫一次）。
# @param PATTERN 清单文件名模式（如 .manifest）
# @param ROOT 清单根目录，可给多个
# @exitcode 0 总是成功
# @stability experimental
registry_scan_multi() {
  local __pat="${1:-}" __root
  shift
  _REGISTRY_ROOT=""
  _REGISTRY_ENTRIES=""
  _REGISTRY_FILES=""
  _REGISTRY_NAMES=()
  _REGISTRY_PATHS=()
  _REGISTRY_BLOBS=()
  for __root in "$@"; do
    _registry_scan_one "$__root" "$__pat"
  done
  return 0
}

# _registry_file NAME —— 条目对应的清单文件路径
# @exitcode 0 找到，stdout 是路径
# @exitcode 1 没找到
_registry_file() {
  local __name="${1:-}" __pair
  while IFS= read -r __pair; do
    [ -n "$__pair" ] || continue
    case "$__pair" in
      "$__name="*)
        printf '%s' "${__pair#*=}"
        return 0
        ;;
    esac
  done <<<"$_REGISTRY_FILES"
  return 1
}

# registry_get NAME KEY —— 取字段值（未声明时为空）
# KEY 以**字面量**参与匹配：它是调用方传进来的字段名，不该有正则语义。
# 匹配语义与旧 awk 实现逐字一致：**行首**恰好 KEY= 的第一处，值去首尾空白。
# 实现走内存 blob（见文件头「为什么把全文读进内存」），全程不 fork 外部命令。
# @exitcode 0 总是成功（未声明时 stdout 为空）
# @stability stable
registry_get() {
  local __name="${1:-}" __key="${2:-}" __i=0 __n __blob="" __val="" __line
  [ -n "$__name" ] && [ -n "$__key" ] || return 0
  __n=${#_REGISTRY_NAMES[@]}
  while [ "$__i" -lt "$__n" ]; do
    if [ "${_REGISTRY_NAMES[$__i]}" = "$__name" ]; then
      __blob="${_REGISTRY_BLOBS[$__i]}"
      break
    fi
    __i=$((__i + 1))
  done
  [ -n "$__blob" ] || return 0
  # 取第一个行首 KEY= 的值：case 模式隐式全串匹配 ⇒ 等价 awk 的 index($0, k "=") == 1
  while IFS= read -r __line; do
    case "$__line" in
      "$__key"=*)
        __val="${__line#"$__key"=}"
        break
        ;;
    esac
  done <<<"$__blob"
  # 去掉首尾空白
  __val="${__val#"${__val%%[![:space:]]*}"}"
  __val="${__val%"${__val##*[![:space:]]}"}"
  printf '%s' "$__val"
  return 0
}

# registry_list —— 列出全部条目名（每行一个）
# @exitcode 0 总是成功
# @stability experimental
registry_list() {
  local __e
  while IFS= read -r __e; do
    [ -n "$__e" ] || continue
    printf '%s\n' "$__e"
  done <<<"$(printf '%s' "$_REGISTRY_ENTRIES" | tr ' ' '\n')"
  return 0
}

# registry_visible NAME FIELD —— 条目在当前平台是否可见
# 字段为空 ⇒ 未声明平台限制 ⇒ 可见。平台列表用逗号或空格分隔都行。
# @exitcode 0 可见
# @exitcode 1 不可见
# @stability stable
registry_visible() {
  local __name="${1:-}" __field="${2:-}" __plats __p __os
  __plats="$(registry_get "$__name" "$__field")"
  [ -n "$__plats" ] || return 0
  # $(os_name) 每次都 fork 子 shell：进程内缓存一次（OS 不会变；热路径每个模块都要问一遍）
  if [ -z "${_REGISTRY_OS:-}" ]; then
    _REGISTRY_OS="$(os_name)"
  fi
  __os="$_REGISTRY_OS"
  # 值域是 OS 名列表（逗号/空格分隔）：先逗号转空格再分词，与旧 tr 拆行等价；
  # 纯 bash 分词，不 fork tr。
  __plats="${__plats//,/ }"
  for __p in $__plats; do
    if [ "$__p" = "$__os" ]; then
      return 0
    fi
  done
  return 1
}

_REGISTRY_VISITED=""
_REGISTRY_RESULT=""
_REGISTRY_PATH=""

# _registry_deps_visit NAME FIELD —— 后序 DFS，环检测
# @exitcode 0 成功
# @exitcode 1 有环
_registry_deps_visit() {
  local __name="${1:-}" __field="${2:-}" __dep
  case " $_REGISTRY_PATH " in
    *" $__name "*)
      log_error "$(_t 'circular dependency detected'): ${_REGISTRY_PATH# } -> $__name"
      return 1
      ;;
  esac
  case " $_REGISTRY_VISITED " in
    *" $__name "*) return 0 ;;
  esac
  _REGISTRY_VISITED="$_REGISTRY_VISITED $__name"
  _REGISTRY_PATH="$_REGISTRY_PATH $__name"
  while IFS= read -r __dep; do
    [ -n "$__dep" ] || continue
    # 依赖必须在注册表里：缺失的依赖不是「一个普通节点」——
    # 把它混进排序结果，照着结果执行的安装顺序/任务编排就是错的（评审 P2）。
    case " $_REGISTRY_ENTRIES " in
      *" $__dep "*) ;;
      *)
        log_error "$(_t 'missing dependency'): $__name -> $__dep"
        return 1
        ;;
    esac
    if ! _registry_deps_visit "$__dep" "$__field"; then
      return 1
    fi
  done <<<"$(registry_get "$__name" "$__field" | tr ',' '\n' | tr ' ' '\n')"
  _REGISTRY_RESULT="$_REGISTRY_RESULT $__name"
  _REGISTRY_PATH="${_REGISTRY_PATH% "$__name"}"
  return 0
}

# registry_deps NAME FIELD —— 传递依赖（拓扑序，空格分隔，不含自身）
# @exitcode 0 成功
# @exitcode 1 有环
# @stability stable
registry_deps() {
  local __name="${1:-}" __field="${2:-}" __m __out=""
  _REGISTRY_VISITED=""
  _REGISTRY_RESULT=""
  _REGISTRY_PATH=""
  _registry_deps_visit "$__name" "$__field" || return 1
  for __m in $_REGISTRY_RESULT; do
    [ "$__m" = "$__name" ] && continue
    __out="$__out $__m"
  done
  printf '%s\n' "${__out# }"
  return 0
}

# registry_topo FIELD —— 全体拓扑序（空格分隔）
# @exitcode 0 成功
# @exitcode 1 有环
# @stability stable
registry_topo() {
  local __field="${1:-}" __m
  _REGISTRY_VISITED=""
  _REGISTRY_RESULT=""
  _REGISTRY_PATH=""
  for __m in $_REGISTRY_ENTRIES; do
    _registry_deps_visit "$__m" "$__field" || return 1
  done
  printf '%s\n' "${_REGISTRY_RESULT# }"
  return 0
}
