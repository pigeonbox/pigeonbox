#!/usr/bin/env bash
# 校验器。统一行为：通过返回 0，失败返回 1 并把原因写入 SK_VALIDATE_ERR。

# 调用方读取最近一次校验失败原因
# shellcheck disable=SC2034
SK_VALIDATE_ERR=""

_sk_vfail() {
  SK_VALIDATE_ERR="${1:-}"
  return 1
}

# validate_not_empty VALUE —— 非空校验；失败原因写进 SK_VALIDATE_ERR
# @exitcode 0 非空
# @exitcode 1 为空（失败原因写进 SK_VALIDATE_ERR）
# @stability experimental
validate_not_empty() {
  if [ -n "${1:-}" ]; then
    return 0
  fi
  _sk_vfail "$(_t 'value must not be empty')"
}

# validate_single_line VALUE —— 单行文本；配置项的值不允许带换行 —— 配置文件的值不允许换行
# @exitcode 0 单行
# @exitcode 1 含换行
# @stability experimental
validate_single_line() {
  case "${1:-}" in
    *$'\n'* | *$'\r'*)
      _sk_vfail "$(_t 'value must be a single line')"
      return 1
      ;;
  esac
  return 0
}

# validate_key VALUE —— 合法配置键名
# @exitcode 0 键名合法
# @exitcode 1 键名不合法
# @stability experimental
validate_key() {
  case "${1:-}" in
    [A-Za-z_]*) ;;
    *)
      _sk_vfail "$(_t 'invalid configuration key'): ${1:-}"
      return 1
      ;;
  esac
  case "${1:-}" in
    *[!A-Za-z0-9_]*)
      _sk_vfail "$(_t 'invalid configuration key'): ${1:-}"
      return 1
      ;;
  esac
  return 0
}

# validate_port VALUE —— 1-65535 的端口号
# @exitcode 0 端口合法
# @exitcode 1 端口不合法
# @stability experimental
validate_port() {
  local __v="${1:-}"
  case "$__v" in
    '' | *[!0-9]*)
      _sk_vfail "$(_t 'port must be a number'): $__v"
      return 1
      ;;
  esac
  if [ "$__v" -ge 1 ] && [ "$__v" -le 65535 ]; then
    return 0
  fi
  _sk_vfail "$(_t 'port out of range'): $__v"
}

# validate_ip VALUE —— 四段十进制，每段 0-255，且不接受前导零（010 会被当成八进制）
# @exitcode 0 IP 合法
# @exitcode 1 IP 不合法
# @stability stable
validate_ip() {
  local __v="${1:-}"
  local __o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  if [[ "$__v" =~ ^$__o\.$__o\.$__o\.$__o$ ]]; then
    return 0
  fi
  _sk_vfail "$(_t 'invalid IPv4 address'): $__v"
}

# validate_version VALUE —— x.y.z 或 v1.2.3 形式的版本号
# @exitcode 0 版本号合法
# @exitcode 1 版本号不合法
# @stability experimental
validate_version() {
  local __v="${1:-}"
  if [[ "$__v" =~ ^v?[0-9]+(\.[0-9]+){0,2}([-.+][0-9A-Za-z.-]+)?$ ]]; then
    return 0
  fi
  _sk_vfail "$(_t 'invalid version'): $__v"
}

# validate_abs_path VALUE —— 绝对路径
# @exitcode 0 是绝对路径
# @exitcode 1 不是绝对路径
# @stability experimental
validate_abs_path() {
  case "${1:-}" in
    /*) return 0 ;;
  esac
  _sk_vfail "$(_t 'path must be absolute'): ${1:-}"
}

# validate_url VALUE —— http/https URL
# @exitcode 0 是 URL
# @exitcode 1 不是 URL
# @stability experimental
validate_url() {
  local __v="${1:-}"
  if [[ "$__v" =~ ^https?://[^[:space:]]+$ ]]; then
    return 0
  fi
  _sk_vfail "$(_t 'invalid URL'): $__v"
}

# validate_enum VALUE "a|b|c" —— 取值必须在给定集合内
# @exitcode 0 在枚举里
# @exitcode 1 不在枚举里
# @stability experimental
validate_enum() {
  local __v="${1:-}" __choices="${2:-}"
  case "|$__choices|" in
    *"|$__v|"*) return 0 ;;
  esac
  _sk_vfail "$(_t 'value not in allowed set'): $__v ($__choices)"
}
