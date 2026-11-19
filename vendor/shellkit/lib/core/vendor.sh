#!/usr/bin/env bash
#
# 库副本（工程自带的 shellkit 副本）的落点解析。
#
# 为什么要有这个模块：落点原本硬编码成 <工程>/vendor/shellkit。Go 模块仓的仓根
# **不能**放 vendor/ 目录 —— Go ≥1.14 看到模块根下的 vendor/ 就切 vendor 模式，
# 缺 vendor/modules.txt 就报 inconsistent vendoring。于是副本改放 third_party/shellkit
# 之后，doctor 说「没有副本」、upgrade 反而在仓根造出一个新的 vendor/：
# 把一个 Go 仓悄悄弄坏（退出码还是 0，日志里看不出来）。
#
# 落点现在可配，优先级（高的赢）：
#   1. 环境变量 SHELLKIT_VENDOR_DIR
#   2. 工程配置文件 <工程>/.shellkit-vendor-dir（第一行有效内容）
#   3. 默认 vendor/shellkit
#
# 相对路径相对于**工程目录**解析；绝对路径必须落在工程目录之内。
# 越界的取值一律拒绝：名字会变成路径，带 .. 的取值能写到工程之外
# （坑 7：清单里的名字能变成路径，退出码还是 0，日志里看不出来）。
#
# 三处（doctor / upgrade / repair.sh）必须读**同一个**解析结果 —— 各写各的
# 路径字符串，迟早漂：装在一个地方、查在另一个地方，是最难查的那类 bug。
#
# ⚠️ 出参链路上的命名（坑 4）：printf -v 写的是「最近一层声明了该名字的作用域」。
# 本文件的出参名一律用 __vrel / __vabs 这类专属名字，
# 不碰 __out / __v / __val 这些保留名，也不与链路上的任何一层 local 同名。

# 默认落点与配置文件名：整个仓库里只有这一份定义
_SK_VENDOR_DIR_DEFAULT="vendor/shellkit"
_SK_VENDOR_DIR_FILE=".shellkit-vendor-dir"

# _sk_vendor_dir_trim VALUE OUTVAR —— 去掉首尾空白（bash 3.2 没有那种扩展写法）
# 出参用 printf -v，不改调用方的变量名。
# @exitcode 0 总是成功
_sk_vendor_dir_trim() {
  local __t="$1"
  __t="${__t#"${__t%%[![:space:]]*}"}"
  __t="${__t%"${__t##*[![:space:]]}"}"
  printf -v "$2" '%s' "$__t"
}

# _sk_vendor_dir_file_value FILE —— 读配置文件里的落点（第一行有效内容）
# @exitcode 0 总是成功（没读到就是空输出）
_sk_vendor_dir_file_value() {
  local __f="$1" __line __vtrim
  [ -n "$__f" ] && [ -r "$__f" ] || return 0
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%%#*}"
    _sk_vendor_dir_trim "$__line" __vtrim
    [ -n "$__vtrim" ] || continue
    printf '%s' "$__vtrim"
    return 0
  done <"$__f"
  return 0
}

# _sk_vendor_dir_source_now PROJECT_DIR —— 设置来自哪儿：env / file / default
# @exitcode 0 总是成功
_sk_vendor_dir_source_now() {
  local __proj="$1" __vsrc
  if [ -n "${SHELLKIT_VENDOR_DIR:-}" ]; then
    printf 'env'
    return 0
  fi
  __vsrc="$(_sk_vendor_dir_file_value "$__proj/$_SK_VENDOR_DIR_FILE")"
  if [ -n "$__vsrc" ]; then
    printf 'file'
    return 0
  fi
  printf 'default'
}

# _sk_vendor_dir_bad_path VALUE —— 这个取值会不会写到工程之外
# @exitcode 0 合法；1 非法
_sk_vendor_dir_bad_path() {
  local __b="$1"
  case "/$__b/" in
    */../*) return 1 ;;
  esac
  # 工程目录本身不能当落点：整份库副本铺到工程根上会把工程冲掉
  case "$__b" in
    . | ./ | '') return 1 ;;
  esac
  return 0
}

# _sk_vendor_dir_canon PATH —— 规范化成绝对路径（软链解析到最深的已存在祖先）
#   尾部还不存在也没关系（库副本落点通常还没建）。
#   为什么非要规范化：macOS 上 /var 是软链（真身 /private/var），
#   工程目录给的是 /var/folders/...，pwd -P 给的是 /private/var/folders/... ——
#   两边不规范化就比对，「落在工程内」会被误判成「越界」。
# @exitcode 0 成功（stdout 是规范化路径）；1 无法规范化
_sk_vendor_dir_canon() {
  local __p="$1" __suffix="" __dir __base
  case "$__p" in
    /*) ;;
    *) __p="$PWD/$__p" ;;
  esac
  __dir="${__p%/*}"
  [ -n "$__dir" ] || __dir="/"
  __base="${__p##*/}"
  while [ ! -d "$__dir" ]; do
    [ "$__dir" = "/" ] && break
    __suffix="$__base${__suffix:+/$__suffix}"
    __base="${__dir##*/}"
    __dir="${__dir%/*}"
    [ -n "$__dir" ] || __dir="/"
  done
  __dir="$(cd "$__dir" 2>/dev/null && pwd -P)" || return 1
  __dir="${__dir%/}"
  if [ -n "$__suffix" ]; then
    printf '%s/%s/%s' "$__dir" "$__suffix" "$__base"
  else
    printf '%s/%s' "$__dir" "$__base"
  fi
}

# _sk_vendor_dir_resolve PROJECT_DIR OUTVAR —— 解析落点（相对工程目录的取值）
#   越界与非法取值直接报错返回 3 —— 落错地方比不落更糟。
#
#   ⚠️ 本层的 local 名（__proj / __raw / __pabs）不能与调用方传进来的
#   出参名同名，否则 printf -v 会写回自己这一层，调用方拿到的还是空（坑 4）。
# @exitcode 0 成功（出参 OUTVAR 是落点取值）
# @exitcode 3 工程目录不存在，或落点越出工程目录
_sk_vendor_dir_resolve() {
  local __proj="$1" __raw __pabs __craw
  [ -n "$__proj" ] || __proj="$(pwd)"
  if [ ! -d "$__proj" ]; then
    log_error "$(_t 'target directory does not exist'): $__proj"
    return "$SK_PRECOND"
  fi
  __raw="${SHELLKIT_VENDOR_DIR:-}"
  if [ -z "$__raw" ]; then
    __raw="$(_sk_vendor_dir_file_value "$__proj/$_SK_VENDOR_DIR_FILE")"
  fi
  [ -n "$__raw" ] || __raw="$_SK_VENDOR_DIR_DEFAULT"
  if ! _sk_vendor_dir_bad_path "$__raw"; then
    log_error "$(_t 'the vendor directory must be inside the project directory'): $__raw"
    return "$SK_PRECOND"
  fi
  case "$__raw" in
    /*)
      # 绝对路径必须落在工程目录之内
      __pabs="$(cd "$__proj" 2>/dev/null && pwd -P)" || {
        log_error "$(_t 'target directory does not exist'): $__proj"
        return "$SK_PRECOND"
      }
      __craw="$(_sk_vendor_dir_canon "$__raw")" || __craw="$__raw"
      case "$__craw" in
        "$__pabs"/*) ;;
        *)
          log_error "$(_t 'the vendor directory must be inside the project directory'): $__raw"
          return "$SK_PRECOND"
          ;;
      esac
      ;;
  esac
  printf -v "$2" '%s' "$__raw"
  return 0
}

# vendor_dir_rel PROJECT_DIR —— 库副本相对工程目录的路径（配置值原样）
#   默认是 vendor/shellkit；配了 SHELLKIT_VENDOR_DIR 或 .shellkit-vendor-dir
#   就是那个值。
# @exitcode 0 成功（stdout 是相对路径）
# @exitcode 3 工程目录不存在，或落点越出工程目录
# @stability experimental
vendor_dir_rel() {
  local __proj="${1:-}" __vrel
  [ -n "$__proj" ] || __proj="$(pwd)"
  # 出参名不能与被调函数内部的 local 撞名（printf -v 只写最近一层作用域：坑 4）
  _sk_vendor_dir_resolve "$__proj" __vrel || return $?
  printf '%s' "$__vrel"
}

# vendor_dir PROJECT_DIR —— 库副本在工程里的绝对路径
# @exitcode 0 成功（stdout 是绝对路径）
# @exitcode 3 工程目录不存在，或落点越出工程目录
# @stability experimental
vendor_dir() {
  local __proj="${1:-}" __vrel __vabs
  [ -n "$__proj" ] || __proj="$(pwd)"
  _sk_vendor_dir_resolve "$__proj" __vrel || return $?
  case "$__vrel" in
    /*) __vabs="$__vrel" ;;
    *)
      __vabs="$(cd "$__proj" 2>/dev/null && pwd -P)" || __vabs="$__proj"
      __vabs="$__vabs/$__vrel"
      ;;
  esac
  printf '%s' "$__vabs"
}

# vendor_dir_source PROJECT_DIR —— 落点设置是从哪儿来的
#   用来把「为什么落在这个地方」讲清楚，而不是让人猜。
# @exitcode 0 总是成功（stdout 是 env / file / default）
# @stability experimental
vendor_dir_source() {
  local __proj="${1:-}"
  [ -n "$__proj" ] || __proj="$(pwd)"
  _sk_vendor_dir_source_now "$__proj"
}

# vendor_dir_detect PROJECT_DIR —— 工程里「别处」的库副本
#   扫一层子目录，找形如 <子目录>/shellkit 的库副本（里面要有 lib/bootstrap.sh）。
#   解析出来的落点本身不算 —— 这里找的是「落点之外的那一份」。
# @exitcode 0 找到了（stdout 是相对工程目录的路径）
# @exitcode 1 没找到
# @stability experimental
vendor_dir_detect() {
  local __proj="${1:-}" __rel __abs __resolved __cand
  [ -n "$__proj" ] || __proj="$(pwd)"
  [ -d "$__proj" ] || return 1
  __resolved="$(vendor_dir "$__proj" 2>/dev/null)" || __resolved=""
  [ -n "$__resolved" ] && __resolved="$(_sk_vendor_dir_canon "$__resolved")" || __resolved=""
  for __cand in "$__proj"/*/shellkit "$__proj"/shellkit; do
    [ -f "$__cand/lib/bootstrap.sh" ] || continue
    __abs="$(cd "$__cand" 2>/dev/null && pwd -P)" || continue
    __abs="$(_sk_vendor_dir_canon "$__abs")" || continue
    if [ -n "$__resolved" ] && [ "$__abs" = "$__resolved" ]; then
      continue
    fi
    __rel="${__cand#"$__proj"/}"
    printf '%s' "$__rel"
    return 0
  done
  return 1
}
