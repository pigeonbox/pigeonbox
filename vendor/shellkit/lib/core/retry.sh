#!/usr/bin/env bash
#
# 退避重试。默认不重试两类失败：
#   2 (SK_USAGE)  参数错，重试一万次还是错
#   5 (SK_VERIFY) 校验失败，重试只会浪费带宽
#
#   retry 5 curl -fsS -o out "$url"
#
# SHELLKIT_RETRY_DELAY / BACKOFF / MAX_DELAY / ON 控制节奏与可重试码。

# _sk_retry_allowed CODE
_sk_retry_allowed() {
  local __rc=$1 __list
  __list=${SHELLKIT_RETRY_ON:-}
  if [ -n "$__list" ]; then
    case " $__list " in
      *" $__rc "*) return 0 ;;
    esac
    return 1
  fi
  case "$__rc" in
    "$SK_USAGE" | "$SK_VERIFY") return 1 ;;
  esac
  return 0
}

# retry ATTEMPTS CMD... —— 失败退避重试；用法错与校验失败不重试
# @exitcode 0 最终成功
# @exitcode 2 参数错（次数不是正整数）
# @exitcode 其他 被重试命令自身的退出码（放弃重试时返回它）
# @stability stable
retry() {
  if [ "$#" -lt 2 ]; then
    log_error "$(_t 'usage: retry ATTEMPTS COMMAND...')"
    return "$SK_USAGE"
  fi
  local __attempts=$1
  shift
  case "$__attempts" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid retry count'): $__attempts"
      return "$SK_USAGE"
      ;;
  esac
  if [ "$__attempts" -lt 1 ]; then
    log_error "$(_t 'invalid retry count'): $__attempts"
    return "$SK_USAGE"
  fi

  local __delay __backoff __max __i=1 __rc=0 __next
  __max=$(_sk_uint SHELLKIT_RETRY_MAX_DELAY 30)
  __delay=$(_sk_uint SHELLKIT_RETRY_DELAY 1)
  __backoff=$(_sk_uint SHELLKIT_RETRY_BACKOFF 2)
  if [ "$__backoff" -lt 1 ]; then
    __backoff=1
  fi
  # 首个延迟也要夹：DELAY=100 / MAX=5 时以前第一次就白等 100 秒，
  # 「上限」看着生效、实际第一步没生效。
  if [ "$__delay" -gt "$__max" ]; then
    __delay=$__max
  fi

  while :; do
    __rc=0
    "$@" || __rc=$?
    if [ "$__rc" -eq 0 ]; then
      return 0
    fi
    if [ "$__i" -ge "$__attempts" ]; then
      break
    fi
    if ! _sk_retry_allowed "$__rc"; then
      return "$__rc"
    fi
    log_warn "$(_t 'attempt failed, retrying'): $__i/$__attempts (exit $__rc, next in ${__delay}s)"
    if [ "$__delay" -gt 0 ]; then
      sleep "$__delay"
    fi
    __next=$((__delay * __backoff))
    if [ "$__next" -gt "$__max" ]; then
      __next=$__max
    fi
    __delay=$__next
    __i=$((__i + 1))
  done

  log_error "$(_t 'giving up after retries'): $__attempts (exit $__rc)"
  return "$__rc"
}
