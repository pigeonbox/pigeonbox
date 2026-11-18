#!/usr/bin/env bash
#
# 版本比较。纯 bash 实现，不依赖 GNU sort -V（macOS 的 BSD sort 行为有差异）。
#
# 口径：只认「数字与点」组成的版本号（去前导 v/V）。
# 非法输入返回 2（用法错）、不输出比较结果 —— 「没法比较」不许伪装成「相等」：
# 旧契约对非法输入返回 0，导致 ver_eq "invalid" "1.0" 判真，
# 「无法比较」与「版本相等」混为一谈（评审 P2）。布尔谓词照样判否（非 0）。
#
# 分段比较：缺段当 0 ⇒ 1.0 与 1.0.0 判等。sort -V 会认为 1.0 < 1.0.0，
# 这里按分段语义走（设计文档选定「纯 bash 分段比较」）。

# _sk_ver_valid V —— 版本串是否合法
#
# 形态：MAJOR.MINOR.PATCH[-PRE]（去前导 v/V 之后判断）。
#   - 核心只允许数字与点，且以数字开头；
#   - 预发布后缀以 `-` 开头，标识符用点分隔，只允许字母、数字与点；
#     不允许空后缀、空标识符（`1.0.0-` / `1.0.0-rc..1` 都非法）。
# @exitcode 0 合法
# @exitcode 1 不合法
_sk_ver_valid() {
  local __v=${1:-} __core='' __pre=''
  case "$__v" in
    '' | *[!0-9A-Za-z.-]*) return 1 ;;
  esac
  case "$__v" in
    [0-9]*) ;;
    *) return 1 ;;
  esac
  case "$__v" in
    *-*)
      __core=${__v%%-*}
      __pre=${__v#*-}
      # 后缀单独校验：非空、无空标识符、无首尾点
      # 字符集已由上面那道 case 保证（含 '-' 在内只允许 0-9A-Za-z.），
      # 这里只需要挡「空后缀 / 首尾点 / 空标识符」这些形状问题。
      case "$__pre" in
        '' | .* | *. | *..*) return 1 ;;
      esac
      ;;
    *) __core=$__v ;;
  esac
  case "$__core" in
    '' | *[!0-9.]*) return 1 ;;
  esac
  case "$__core" in
    [0-9]*) return 0 ;;
  esac
  return 1
}

# _sk_ver_pre_cmp A B —— 两个预发布串比较（调用方保证都非空且合法）
# 口径按 semver：点分段；数字段按数值比，数字段 < 非数字段，
# 非数字段按 C locale 字节序比；前缀相同则段数多者大。
_sk_ver_pre_cmp() {
  local __a=${1:-} __b=${2:-} __x __y
  while [ -n "$__a" ] || [ -n "$__b" ]; do
    case "$__a" in
      *.*)
        __x=${__a%%.*}
        __a=${__a#*.}
        ;;
      *)
        __x=$__a
        __a=''
        ;;
    esac
    case "$__b" in
      *.*)
        __y=${__b%%.*}
        __b=${__b#*.}
        ;;
      *)
        __y=$__b
        __b=''
        ;;
    esac
    if [ -z "$__x" ] && [ -n "$__y" ]; then
      printf '%s' '-1'
      return 0
    fi
    if [ -n "$__x" ] && [ -z "$__y" ]; then
      printf '%s' '1'
      return 0
    fi
    [ -n "$__x" ] || {
      printf '%s' '0'
      return 0
    }
    case "$__x" in
      *[!0-9]*)
        case "$__y" in
          *[!0-9]*)
            if [ "$__x" = "$__y" ]; then
              :
            elif [ "$__x" \< "$__y" ]; then
              printf '%s' '-1'
              return 0
            else
              printf '%s' '1'
              return 0
            fi
            ;;
          *)
            printf '%s' '1'
            return 0
            ;;
        esac
        ;;
      *)
        case "$__y" in
          *[!0-9]*)
            printf '%s' '-1'
            return 0
            ;;
          *)
            if [ "$((10#$__x))" -lt "$((10#$__y))" ]; then
              printf '%s' '-1'
              return 0
            fi
            if [ "$((10#$__x))" -gt "$((10#$__y))" ]; then
              printf '%s' '1'
              return 0
            fi
            ;;
        esac
        ;;
    esac
  done
  printf '%s' '0'
}

# _sk_ver_field V N —— 取第 N 段（0 起）；不足的段当 0
# @exitcode 0 总是成功（stdout 是该段）
_sk_ver_field() {
  local __v=${1:-} __n=${2:-0} __i=0 __part
  while [ "$__i" -le "$__n" ]; do
    case "$__v" in
      *.*)
        __part=${__v%%.*}
        __v=${__v#*.}
        ;;
      *)
        __part=$__v
        __v=''
        ;;
    esac
    if [ "$__i" -eq "$__n" ]; then
      [ -n "$__part" ] || __part=0
      printf '%s' "$__part"
      return 0
    fi
    if [ -z "$__v" ]; then
      printf '%s' '0'
      return 0
    fi
    __i=$((__i + 1))
  done
  printf '%s' '0'
  return 0
}

# ver_cmp A B —— 比较两个版本号
# @exitcode 0 比较完成（stdout 输出 -1 / 0 / 1：A<B / A=B / A>B）
# @exitcode 2 有版本串非法或缺参数（stdout 空）
# @stability stable
ver_cmp() {
  local __a=${1:-} __b=${2:-} __i=0 __x __y __pre_a __pre_b __core_a __core_b
  __a=${__a#v}
  __a=${__a#V}
  __b=${__b#v}
  __b=${__b#V}
  if ! _sk_ver_valid "$__a" || ! _sk_ver_valid "$__b"; then
    return "$SK_USAGE"
  fi
  __core_a=${__a%%-*}
  __core_b=${__b%%-*}
  __pre_a=''
  __pre_b=''
  case "$__a" in *-*) __pre_a=${__a#*-} ;; esac
  case "$__b" in *-*) __pre_b=${__b#*-} ;; esac
  __a=$__core_a
  __b=$__core_b
  while [ "$__i" -lt 32 ]; do
    __x=$(_sk_ver_field "$__a" "$__i")
    __y=$(_sk_ver_field "$__b" "$__i")
    if [ "$__x" -lt "$__y" ]; then
      printf '%s' '-1'
      return 0
    fi
    if [ "$__x" -gt "$__y" ]; then
      printf '%s' '1'
      return 0
    fi
    __i=$((__i + 1))
  done
  # 核心相等，接着比预发布（semver 口径：正式版 > 同核心的预发布）
  if [ -z "$__pre_a" ] && [ -z "$__pre_b" ]; then
    printf '%s' '0'
    return 0
  fi
  if [ -z "$__pre_a" ]; then
    printf '%s' '1'
    return 0
  fi
  if [ -z "$__pre_b" ]; then
    printf '%s' '-1'
    return 0
  fi
  printf '%s' "$(_sk_ver_pre_cmp "$__pre_a" "$__pre_b")"
  return 0
}

# ver_gt A B —— A 是否比 B 新
# @exitcode 0 A > B
# @exitcode 1 不是
# @exitcode 2 有版本串非法或缺参数（没法比较）
# @stability stable
ver_gt() {
  local __r=""
  __r=$(ver_cmp "${1:-}" "${2:-}") || return $?
  [ "$__r" = '1' ]
}

# ver_lt A B —— A 是否比 B 旧
# @exitcode 0 A < B
# @exitcode 1 不是
# @exitcode 2 有版本串非法或缺参数（没法比较）
# @stability stable
ver_lt() {
  local __r=""
  __r=$(ver_cmp "${1:-}" "${2:-}") || return $?
  [ "$__r" = '-1' ]
}

# ver_eq A B —— 两个版本是否相等
# @exitcode 0 相等
# @exitcode 1 不等
# @exitcode 2 有版本串非法或缺参数（没法比较，不许当成相等）
# @stability stable
ver_eq() {
  local __r=""
  __r=$(ver_cmp "${1:-}" "${2:-}") || return $?
  [ "$__r" = '0' ]
}
