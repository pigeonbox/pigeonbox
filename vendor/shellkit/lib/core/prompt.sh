#!/usr/bin/env bash
#
# 交互式问答。
#   - 非交互（SHELLKIT_NONINTERACTIVE=1 或 stdin 不是 tty）：取默认值；没有默认值则失败，不静默返回空。
#   - 超时：read -t；Bash 3 与 Bash 4 的退出码差异在 _sk_read_line 内消化。
#   - 只有真正超时才回退默认值，EOF 视为错误。
#
# 出参链路上有个容易踩的坑：printf -v 写的是「最近一层声明了该名字的作用域」。
# 从公开入口（ask / ask_yn / ask_choice）到真正落笔的 printf -v，中间任何一层
# 只要声明了和目标变量同名的 local，内容就写回自己那层，调用方拿到的还是原值 ——
# 不报错、不崩，只是静默失效。
# 公开入口统一用 _sk_check_out_name 把这条链上的具名局部变量挡在门外；
# 私有函数之间互传不受影响（名字由我们自己保证不撞）。
# 曾经出过一次：读行的缓冲叫 __line，调用方恰好也拿 __line 当目标变量名，
# 于是 ask/ask_yn/ask_choice/confirm 永远回退默认值、用户输入被丢弃。

# _sk_read_line VAR [TIMEOUT]
#   0 = 读到内容；1 = EOF/被中断；2 = 超时
#   VAR 是「要写入的变量名」。缓冲必须用与 VAR 不同的名字：
#   同名时读到的内容写回自己这层，调用方拿不到。
_sk_read_line() {
  local __var=${1:-} __timeout=${2:-} __buf="" __rc=0 __start=0
  case "$__var" in
    __var | __timeout | __buf | __rc | __start) return "$SK_USAGE" ;;
  esac
  if [ -z "$__timeout" ] || [ "$__timeout" = "0" ]; then
    IFS= read -r __buf || __rc=$?
  else
    __start=$SECONDS
    IFS= read -r -t "$__timeout" __buf || __rc=$?
    if [ "$__rc" != "0" ]; then
      if [ "$__rc" -gt 128 ] 2>/dev/null; then
        __rc=2
      elif [ $((SECONDS - __start)) -ge "$__timeout" ]; then
        __rc=2
      fi
    fi
  fi
  printf -v "$__var" '%s' "$__buf"
  return "$__rc"
}

# _sk_ask_raw VAR RENDERED_PROMPT [DEFAULT] [TIMEOUT]
#   私有：VAR 名由调用方保证不与本函数及其下游的局部变量同名。
_sk_ask_raw() {
  local __var=${1:-} __msg=${2:-} __default=${3:-} __timeout=${4:-} __answer="" __rc=0
  if [ "${SHELLKIT_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    if [ -z "$__default" ]; then
      log_error "$(_t 'Non-interactive mode requires a default value'): $__msg"
      return "$SK_PRECOND"
    fi
    printf -v "$__var" '%s' "$__default"
    log_warn "$(_t 'Non-interactive, using default'): $__default"
    return 0
  fi
  printf '%s: ' "$__msg" >&2
  _sk_read_line __answer "$__timeout" || __rc=$?
  if [ "$__rc" = "2" ]; then
    if [ -z "$__default" ]; then
      log_error "$(_t 'Input timed out and no default is set'): $__msg"
      return "$SK_PRECOND"
    fi
    log_warn "$(_t 'Input timed out, using default'): $__default"
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  if [ "$__rc" != "0" ]; then
    log_error "$(_t 'Input closed unexpectedly')"
    return "$SK_ERR"
  fi
  if [ -z "$__answer" ]; then
    __answer=$__default
  fi
  printf -v "$__var" '%s' "$__answer"
  return 0
}

# _sk_ask_yn_raw VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 私有：y/n 判定，结果写进 VAR
_sk_ask_yn_raw() {
  local __var=${1:-} __prompt=${2:-} __default=${3:-y} __timeout=${4:-} __ans="" __tries=0 __msg __hint
  case "$__default" in
    y | Y | yes | YES) __hint="[Y/n]" ;;
    *) __hint="[y/N]" ;;
  esac
  __msg="$__prompt $__hint"
  while [ "$__tries" -lt 3 ]; do
    __tries=$((__tries + 1))
    _sk_ask_raw __ans "$__msg" "$__default" "$__timeout" || return $?
    __ans=$(printf '%s' "$__ans" | tr '[:upper:]' '[:lower:]')
    if [ -z "$__ans" ]; then
      __ans=$(printf '%s' "$__default" | tr '[:upper:]' '[:lower:]')
    fi
    case "$__ans" in
      y | yes)
        printf -v "$__var" '%s' "y"
        return 0
        ;;
      n | no)
        printf -v "$__var" '%s' "n"
        return 0
        ;;
    esac
    log_warn "$(_t 'please answer y or n')"
  done
  return "$SK_USAGE"
}

# _sk_ask_choice_raw VAR PROMPT CHOICES [DEFAULT] [TIMEOUT] —— 私有：多选一
_sk_ask_choice_raw() {
  local __var=${1:-} __prompt=${2:-} __choices=${3:-} __default=${4:-} __timeout=${5:-} __ans="" __tries=0 __msg
  if [ -n "$__default" ]; then
    case "|$__choices|" in
      *"|$__default|"*) ;;
      *)
        log_error "$(_t 'default value is not one of the choices'): $__default"
        return "$SK_USAGE"
        ;;
    esac
  fi
  __msg="$__prompt [$__choices]"
  if [ -n "$__default" ]; then
    __msg="$__msg ($(_t 'default'): $__default)"
  fi
  while [ "$__tries" -lt 3 ]; do
    __tries=$((__tries + 1))
    _sk_ask_raw __ans "$__msg" "$__default" "$__timeout" || return $?
    case "|$__ans|" in
      *"|$__ans|"*)
        printf -v "$__var" '%s' "$__ans"
        return 0
        ;;
    esac
    log_warn "$(_t 'invalid choice'): $__ans"
  done
  return "$SK_USAGE"
}

# ask VAR PROMPT [DEFAULT] [TIMEOUT] —— 问一个问题，把答案写进 VAR；超时或 EOF 回退默认值
#   VAR 不能用库内部出参链路上的局部变量名（见 _sk_check_out_name），否则会静默失效。
# @exitcode 0 拿到答案（超时或 EOF 时回退默认值）
# @exitcode 2 参数错（变量名非法或撞上内部保留名）
# @exitcode 3 非交互且没有默认值，或超时且没有默认值
# @exitcode 1 输入被意外关闭
# @stability stable
ask() {
  local __var=${1:-} __prompt=${2:-} __default=${3:-} __timeout=${4:-} __msg
  _sk_need_args "$#" 2 "ask VAR PROMPT [DEFAULT] [TIMEOUT]" || return $?
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  _sk_check_out_name "$__var" || return $?
  __msg=$__prompt
  if [ -n "$__default" ]; then
    __msg="$__msg [$(_t 'default'): $__default] "
  fi
  _sk_ask_raw "$__var" "$__msg" "$__default" "$__timeout"
}

# ask_yn VAR PROMPT [DEFAULT=y] [TIMEOUT] —— 结果写入 y 或 n
# @exitcode 0 拿到 y 或 n
# @exitcode 2 参数错（变量名非法、撞上内部保留名），或连续三次都不是 y/n
# @exitcode 3 非交互且没有默认值，或超时且没有默认值
# @exitcode 1 输入被意外关闭
# @stability stable
ask_yn() {
  local __var=${1:-} __prompt=${2:-} __default=${3:-y} __timeout=${4:-}
  _sk_need_args "$#" 2 "ask_yn VAR PROMPT [DEFAULT] [TIMEOUT]" || return $?
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  _sk_check_out_name "$__var" || return $?
  _sk_ask_yn_raw "$__var" "$__prompt" "$__default" "$__timeout"
}

# ask_choice VAR PROMPT "a|b|c" [DEFAULT] [TIMEOUT] —— 多选一；超时或 EOF 回退默认值
# @exitcode 0 拿到一个合法选项
# @exitcode 2 参数错（变量名非法、撞上内部保留名），或连续三次都不是合法选项
# @exitcode 3 非交互且没有默认值，或超时且没有默认值
# @exitcode 1 输入被意外关闭
# @stability stable
ask_choice() {
  local __var=${1:-} __prompt=${2:-} __choices=${3:-} __default=${4:-} __timeout=${5:-}
  _sk_need_args "$#" 3 "ask_choice VAR PROMPT 'a|b|c' [DEFAULT] [TIMEOUT]" || return $?
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  _sk_check_out_name "$__var" || return $?
  _sk_ask_choice_raw "$__var" "$__prompt" "$__choices" "$__default" "$__timeout"
}

# confirm PROMPT [DEFAULT=n] [TIMEOUT] —— 只返回码
# @exitcode 0 用户答 y
# @exitcode 1 用户答 n
# @exitcode 2 参数错，或连续三次都不是 y/n
# @exitcode 3 非交互且没有默认值，或超时且没有默认值
# @exitcode 1 输入被意外关闭
# @stability stable
confirm() {
  local __prompt=${1:-} __default=${2:-n} __timeout=${3:-} __confirm_ans=""
  _sk_need_args "$#" 1 "confirm PROMPT [DEFAULT] [TIMEOUT]" || return $?
  _sk_ask_yn_raw __confirm_ans "$__prompt" "$__default" "$__timeout" || return $?
  if [ "$__confirm_ans" = "y" ]; then
    return 0
  fi
  return 1
}
