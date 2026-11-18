#!/usr/bin/env bash
#
# 机器可读的状态契约。
#
# 双轨输出：
#   人类模式（默认）—— 打印人类可读的文案（带颜色/emoji，向后兼容既有脚本）；
#   机器模式（SHELLKIT_STATUS_MODE=machine）—— 打印规范字段行：
#       STATE=<状态码>
#       VERSION=<版本>      可选
#       EXTRA=<key=value>  可选
#
# 规范状态码有限集：not_installed / installed / installed:running / installed:stopped /
#                   configured / not_configured / n/a
#
# unix_script 侧保留 UXS_STATUS_MODE 兼容读取 —— 门面负责把它映射到
# SHELLKIT_STATUS_MODE；这里不认 unix_script 的变量名（通用库不该知道调用方的旋钮）。

# _sk_status_is_machine —— 是否机器模式
# @exitcode 0 机器模式
# @exitcode 1 人类模式
_sk_status_is_machine() {
  [ "${SHELLKIT_STATUS_MODE:-human}" = 'machine' ]
}

# status_is_machine —— 机器模式返回 0，人类模式返回 1
# @exitcode 0 机器模式
# @exitcode 1 人类模式
# @stability experimental
status_is_machine() {
  _sk_status_is_machine
}

# status_state_valid STATE —— 状态码是否在有限集里
# @exitcode 0 合法
# @exitcode 1 非法
# @stability experimental
status_state_valid() {
  case "${1:-}" in
    not_installed | installed | installed:running | installed:stopped | configured | not_configured | n/a)
      return 0
      ;;
  esac
  return 1
}

# status_emit STATE HUMAN_MSG —— 输出状态
#   人类模式用 printf %b：文案里的颜色是 ESC[... 这样的**字面转义序列**，
#   用 %s 会原样打印 —— 颜色会变成一堆反斜杠文本。
# @exitcode 0 总是成功
# @stability experimental
status_emit() {
  local __state=${1:-} __human=${2:-}
  if _sk_status_is_machine; then
    printf 'STATE=%s\n' "$__state"
  else
    printf '%b\n' "$__human"
  fi
  return 0
}

# status_version VERSION —— 机器模式下输出 VERSION 行（人类模式不重复输出）
# @exitcode 0 总是成功
# @stability experimental
status_version() {
  if _sk_status_is_machine; then
    printf 'VERSION=%s\n' "${1:-}"
  fi
  return 0
}

# status_extra KEY=VALUE —— 机器模式下输出 EXTRA 行（人类模式不重复输出）
# @exitcode 0 总是成功
# @stability experimental
status_extra() {
  if _sk_status_is_machine; then
    printf 'EXTRA=%s\n' "${1:-}"
  fi
  return 0
}
