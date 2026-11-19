#!/usr/bin/env bash
#
# 退避重试。默认不重试两类失败：
#   2 (SK_USAGE)  参数错，重试一万次还是错
#   5 (SK_VERIFY) 校验失败，重试只会浪费带宽
#
#   retry 5 curl -fsS -o out "$url"
#
# SHELLKIT_RETRY_DELAY / BACKOFF / MAX_DELAY / ON 控制节奏与可重试码。
#
# ---------------------------------------------------------------
# 超时与失败是两回事（issue #145）
# ---------------------------------------------------------------
# 「超时」= 链路抖 ⇒ 重试通常就好，脚本应把它单独报出来，由调用方决定要不要再试；
# 「失败」= 仓库错 / 权限错 / 证书错 ⇒ 重试多少次都没用，必须**叫人**。
# 两者压成同一个非零退出码，调用方就分不出「再试一次」与「得找人」。
#
# 判定口径：被重试命令的退出码等于 SHELLKIT_RETRY_TIMEOUT_CODE（默认 124，
# 与 GNU timeout(1) 一致）就算**超时**；其余非零码都是**失败**。
#
#   retry 3 timeout 30 git fetch    # 超时 ⇒ 最后一次退出码 124
#   rc=$?
#   if [ "$(retry_classify "$rc")" = timeout ]; then retry_again; else call_human; fi
#
# retry 自身**仍返回被重试命令的退出码**（这一条没变）；分类另有三条出口：
#   retry_classify CODE  把任意退出码分类成 success / timeout / failure
#   retry_last_class     上一次 retry 的分类（没跑过 retry 时是 none）
#   retry_last_rc        上一次 retry 里被重试命令最后的退出码
#
# 哪些码值得重试由 SHELLKIT_RETRY_ON 控制（列出即只重试这些）：
#   SHELLKIT_RETRY_ON=124   只重试超时；认证/权限类失败立即放弃
# 不设时是「除 SK_USAGE / SK_VERIFY 外都重试」。
#
# ⚠️ retry_last_* 读的是 retry **在当前 shell 里**留下的结果：
# `v=$(retry 3 cmd)` 这种命令替换里 retry 跑在子 shell ⇒ 结果传不回来。
# 那种写法请改用 retry_classify "$rc"（拿退出码现分类）。

# 上一次 retry 的结果（当前 shell 里的全局变量；没跑过 retry 时是空）
# shellcheck disable=SC2034
SK_RETRY_LAST_RC=""
# shellcheck disable=SC2034
SK_RETRY_LAST_CLASS=""

# _sk_retry_timeout_code —— 当前生效的「超时码」
#   环境变量写错（非数字）时回落到默认值，不让一次笔误把分类全带歪。
# @exitcode 0 总是成功（stdout 是超时码）
_sk_retry_timeout_code() {
  local __c=${SHELLKIT_RETRY_TIMEOUT_CODE:-124}
  case "$__c" in
    '' | *[!0-9]*) __c=124 ;;
  esac
  printf '%s' "$__c"
}

# _sk_retry_class RC —— 分类：success / timeout / failure
# @exitcode 0 总是成功（stdout 是分类名）
_sk_retry_class() {
  local __rc=${1:-} __timeout
  __timeout=$(_sk_retry_timeout_code)
  case "$__rc" in
    0) printf 'success' ;;
    "$__timeout") printf 'timeout' ;;
    *) printf 'failure' ;;
  esac
}

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

  local __delay __backoff __max __i=1 __rc=0 __next __class
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
    SK_RETRY_LAST_RC=$__rc
    if [ "$__rc" -eq 0 ]; then
      SK_RETRY_LAST_CLASS=success
      return 0
    fi
    __class=$(_sk_retry_class "$__rc")
    SK_RETRY_LAST_CLASS=$__class
    if [ "$__i" -ge "$__attempts" ]; then
      break
    fi
    if ! _sk_retry_allowed "$__rc"; then
      return "$__rc"
    fi
    if [ "$__class" = 'timeout' ]; then
      log_warn "$(_t 'attempt timed out, retrying'): $__i/$__attempts (exit $__rc, next in ${__delay}s)"
    else
      log_warn "$(_t 'attempt failed, retrying'): $__i/$__attempts (exit $__rc, next in ${__delay}s)"
    fi
    if [ "$__delay" -gt 0 ]; then
      sleep "$__delay"
    fi
    __next=$(($__delay * $__backoff))
    if [ "$__next" -gt "$__max" ]; then
      __next=$__max
    fi
    __delay=$__next
    __i=$(($__i + 1))
  done

  if [ "$__class" = 'timeout' ]; then
    log_error "$(_t 'giving up after retries (timed out)'): $__attempts (exit $__rc)"
  else
    log_error "$(_t 'giving up after retries'): $__attempts (exit $__rc)"
  fi
  return "$__rc"
}

# retry_classify CODE —— 把退出码分类成 success / timeout / failure
#   超时码由 SHELLKIT_RETRY_TIMEOUT_CODE 决定（默认 124）。
# @exitcode 0 分类成功（stdout 是 success / timeout / failure）
# @exitcode 2 CODE 不是数字
# @stability experimental
retry_classify() {
  local __rc=${1:-}
  case "$__rc" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid exit code'): $__rc"
      return "$SK_USAGE"
      ;;
  esac
  _sk_retry_class "$__rc"
}

# retry_last_class —— 上一次 retry 的结果分类（success / timeout / failure）
#   没跑过 retry 时是 none。
# @exitcode 0 总是成功（stdout 是分类名）
# @stability experimental
retry_last_class() {
  printf '%s' "${SK_RETRY_LAST_CLASS:-none}"
}

# retry_last_rc —— 上一次 retry 里被重试命令最后的退出码
#   没跑过 retry 时是 none。
# @exitcode 0 总是成功（stdout 是退出码）
# @stability experimental
retry_last_rc() {
  printf '%s' "${SK_RETRY_LAST_RC:-none}"
}
