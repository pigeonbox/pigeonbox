#!/usr/bin/env bash
# 错误与前置条件检查

# _sk_need_args HAVE NEED USAGE —— 参数不足时报用法错并返回 SK_USAGE。
# 不用 ${1:-} 兜底是刻意的：少传参数的函数往往「用空值也能跑完」，
# 静默跑完比当场报错难查得多。
_sk_need_args() {
  local __have=${1:-0} __need=${2:-0} __usage=${3:-}
  if [ "$__have" -ge "$__need" ]; then
    return 0
  fi
  log_error "$(_t 'Usage'): $__usage"
  return "$SK_USAGE"
}

# _sk_exit_code_ok VALUE —— 0..255 的十进制整数才是合法退出码
_sk_exit_code_ok() {
  local __v=${1:-}
  case "$__v" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$__v" -le 255 ]
}

# die CODE MSG... —— CODE 必须是 0-255；不合法按用法错误退出 2，而不是让 exit 截成 255
# @exitcode 0 不会返回（直接退出进程）
# @exitcode 2 退出码不是合法数字
# @stability experimental
die() {
  local __code=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if ! _sk_exit_code_ok "$__code"; then
    log_error "$(_t 'invalid exit code'): ${__code:-<empty>}"
    exit "$SK_USAGE"
  fi
  log_error "$*"
  exit "$__code"
}

# fail CODE MSG...  —— 不退出，只返回码；CODE 校验同 die
# @exitcode 0 不会返回（除非退出码是 0）
# @exitcode 2 退出码不是合法数字
# @exitcode 其他 按给定的退出码返回，不退出进程
# @stability stable
fail() {
  local __code=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if ! _sk_exit_code_ok "$__code"; then
    log_error "$(_t 'invalid exit code'): ${__code:-<empty>}"
    return "$SK_USAGE"
  fi
  log_error "$*"
  return "$__code"
}

# require_cmd CMD... —— 零参数返回 SK_USAGE（否则 `require_cmd "$EMPTY"` 会静默通过）
# @exitcode 0 命令都在
# @exitcode 2 没给参数
# @exitcode 3 有命令找不到
# @stability stable
require_cmd() {
  local __c
  _sk_need_args "$#" 1 "require_cmd CMD..." || return $?
  for __c in "$@"; do
    if ! command -v "$__c" >/dev/null 2>&1; then
      log_error "$(_t 'Required command not found'): $__c"
      return "$SK_PRECOND"
    fi
  done
  return 0
}

# require_root —— 必须是 root 运行；否则返回 SK_PRECOND(3)
# @exitcode 0 已经是 root
# @exitcode 3 不是 root
# @stability experimental
require_root() {
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    return 0
  fi
  log_error "$(_t 'This action must be run as root')"
  return "$SK_PRECOND"
}

# require_file PATH... —— 零参数返回 SK_USAGE
# @exitcode 0 文件都在
# @exitcode 2 没给参数
# @exitcode 3 有文件不存在
# @stability experimental
require_file() {
  local __f
  _sk_need_args "$#" 1 "require_file PATH..." || return $?
  for __f in "$@"; do
    if [ ! -e "$__f" ]; then
      log_error "$(_t 'Required file not found'): $__f"
      return "$SK_PRECOND"
    fi
  done
  return 0
}

# require_bash MAJOR [MINOR] —— 当前 bash 版本是否达标；不达标返回 SK_PRECOND(3)
# @exitcode 0 版本够新
# @exitcode 2 没给参数
# @exitcode 3 版本太老
# @stability experimental
require_bash() {
  local __need_major=${1:-3} __need_minor=${2:-0}
  local __major=${BASH_VERSINFO[0]:-0} __minor=${BASH_VERSINFO[1]:-0}
  if [ "$__major" -gt "$__need_major" ]; then
    return 0
  fi
  if [ "$__major" -eq "$__need_major" ] && [ "$__minor" -ge "$__need_minor" ]; then
    return 0
  fi
  log_error "$(_t 'Bash version is too old'): $__need_major.$__need_minor (found ${BASH_VERSION:-unknown})"
  return "$SK_PRECOND"
}
