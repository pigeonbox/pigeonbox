#!/usr/bin/env bash
#
# 子命令框架。只做五件事：注册、分发、help 生成、选项解析、退出码。
# 新增命令 = 新建一个文件 + 一行 cli_cmd，不需要改分发器。

SK_CLI_NAMES=()
SK_CLI_DESCS=()
SK_CLI_USAGES=()
SK_CLI_GROUPS=()
SK_CLI_GROUP_TITLE=""

# cli_group TITLE —— 后续注册的命令归入该分组
# @exitcode 0 成功
# @exitcode 2 分组名非法
# @stability experimental
cli_group() {
  SK_CLI_GROUP_TITLE=${1:-}
}

# _sk_is_cmd_name NAME —— 子命令名允许短横，因此不能复用变量名校验
_sk_is_cmd_name() {
  case "${1:-}" in
    '' | [0-9]* | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# cli_cmd NAME DESC [USAGE] —— 注册一个子命令；要写在命令文件末尾
# @exitcode 0 注册成功
# @exitcode 2 命令名非法或与已有命令重名
# @stability experimental
cli_cmd() {
  local __name=${1:-} __desc=${2:-} __usage=${3:-}
  if ! _sk_is_cmd_name "$__name"; then
    log_error "$(_t 'invalid command name'): $__name"
    return "$SK_USAGE"
  fi
  if cli_has "$__name"; then
    log_error "$(_t 'duplicate command'): $__name"
    return "$SK_USAGE"
  fi
  SK_CLI_NAMES[${#SK_CLI_NAMES[@]}]="$__name"
  SK_CLI_DESCS[${#SK_CLI_DESCS[@]}]="$__desc"
  SK_CLI_USAGES[${#SK_CLI_USAGES[@]}]="$__usage"
  SK_CLI_GROUPS[${#SK_CLI_GROUPS[@]}]="$SK_CLI_GROUP_TITLE"
  return 0
}

# cli_has NAME —— 该命令是否已注册
# @exitcode 0 有这个命令
# @exitcode 1 没有
# @stability experimental
cli_has() {
  local __n=${1:-} __x
  if [ "${#SK_CLI_NAMES[@]}" -eq 0 ]; then
    return 1
  fi
  for __x in "${SK_CLI_NAMES[@]}"; do
    if [ "$__x" = "$__n" ]; then
      return 0
    fi
  done
  return 1
}

# _sk_cmd_fn NAME —— install-self 对应 cmd_install_self
_sk_cmd_fn() { printf 'cmd_%s' "$(printf '%s' "${1:-}" | tr '-' '_')"; }

# cli_usage_cmd NAME —— 打印单个子命令的用法行
# @exitcode 0 总是成功（把用法打到 stdout）
# @stability experimental
cli_usage_cmd() {
  local __name=${1:-} __i=0 __prog
  __prog=${SK_PROG:-$(basename "$0")}
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    if [ "${SK_CLI_NAMES[$__i]}" = "$__name" ]; then
      if [ -n "${SK_CLI_USAGES[$__i]}" ]; then
        printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "${SK_CLI_USAGES[$__i]}"
      else
        printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "$__name"
      fi
      return 0
    fi
    __i=$((__i + 1))
  done
  printf '%s: %s %s\n' "$(_t 'Usage')" "$__prog" "$__name"
  return 0
}

# cli_usage_global —— 打印总用法：命令按分组，选项固定五条
# @exitcode 0 总是成功（把用法打到 stdout）
# @stability experimental
cli_usage_global() {
  local __i=0 __max=8 __len __grp="" __prog
  __prog=${SK_PROG:-$(basename "$0")}
  printf '%s: %s [<options>] <command> [<args>]\n' "$(_t 'Usage')" "$__prog"
  printf '\n%s:\n' "$(_t 'Commands')"
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __len=${#SK_CLI_NAMES[$__i]}
    if [ "$__len" -gt "$__max" ]; then
      __max=$__len
    fi
    __i=$((__i + 1))
  done
  __i=0
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    if [ "${SK_CLI_GROUPS[$__i]}" != "$__grp" ]; then
      __grp=${SK_CLI_GROUPS[$__i]}
      if [ -n "$__grp" ]; then
        printf '\n  [%s]\n' "$__grp"
      fi
    fi
    printf '  %-*s  %s\n' "$__max" "${SK_CLI_NAMES[$__i]}" "${SK_CLI_DESCS[$__i]}"
    __i=$((__i + 1))
  done
  printf '\n%s:\n' "$(_t 'Options')"
  printf '  %-*s  %s\n' 16 "-h, --help" "$(_t 'show this help')"
  printf '  %-*s  %s\n' 16 "-V, --version" "$(_t 'show version')"
  printf '  %-*s  %s\n' 16 "--verbose" "$(_t 'enable debug output')"
  printf '  %-*s  %s\n' 16 "--no-color" "$(_t 'disable colored output')"
  printf '  %-*s  %s\n' 16 "-y, --yes" "$(_t 'non-interactive, use defaults')"
  return 0
}

# _sk_cli_opts_of USAGE —— 从 usage 字符串提取选项，空格分隔输出
#
# usage 是命令选项的唯一真相源（cli_cmd 第三参）—— 补全不再另立一份选项
# 清单：新加 cli_cmd 或改 usage，补全自动跟上（模块清单曾经两处各写一份、
# 迟早漂移的教训在这里同样适用）。
#
# 逐个剥 [ ... ] 组、组内取第一个词：不能按空格分词再匹配 ——
# [--dir DIR] 这种「选项 + 占位符」会被拆成 [--dir 与 DIR] 两个残词，
# 一个都匹配不上（doctor 的 --dir 就这么丢过）。
# 只收 - 开头的组：[bash|zsh] 这类位置参数不是选项；
# [--name NAME] 取 --name —— NAME 是占位符，进了补全就是污染。
# @exitcode 0 总是成功（没有选项时输出空串）
_sk_cli_opts_of() {
  local __rest=${1:-} __grp __out=""
  while :; do
    case "$__rest" in
      *\[*\]*)
        __rest=${__rest#*\[}
        __grp=${__rest%%\]*}
        __rest=${__rest#*\]}
        __grp=${__grp%% *}
        case "$__grp" in
          --?* | -?) __out="${__out} $__grp" ;;
        esac
        ;;
      *) break ;;
    esac
  done
  printf '%s' "${__out# }"
}

# cli_completion_script [bash|zsh] —— 生成补全脚本
#
# 子命令名取自注册表，所以新加一个 cli_cmd，补全里自动就有了 ——
# 不用像别的框架那样单独维护一份命令列表。
# 程序名取 SK_PROG（生成出来的工程可以在自己的入口里设成自己的名字）。
# @exitcode 0 成功（stdout 输出补全脚本）
# @exitcode 2 不认识的 shell
# @stability experimental
cli_completion_script() {
  local __shell=${1:-bash} __i=0 __words="" __name __prog=${SK_PROG:-shellkit}
  local __cases="" __opts=""
  case "$__shell" in
    bash | zsh) ;;
    *)
      log_error "$(_t 'unsupported shell for completion'): $__shell"
      return "$SK_USAGE"
      ;;
  esac
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __name=${SK_CLI_NAMES[$__i]}
    __words="$__words $__name"
    __i=$((__i + 1))
  done
  # 命令级选项：生成时从各命令的 usage 提取，case 分支静态展开进补全脚本，
  # 运行时零解析开销。bash 与 zsh 的数组语法不同，case 分支两套格式。
  __i=0
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __name=${SK_CLI_NAMES[$__i]}
    __opts=$(_sk_cli_opts_of "${SK_CLI_USAGES[$__i]}")
    __cases="${__cases}    $__name) __opts=\"$__opts\" ;;"$'\n'
    __i=$((__i + 1))
  done
  if [ "$__shell" = "bash" ]; then
    cat <<EOF
# $__prog completion for bash
# 由 cli_completion_script 生成；新增子命令或改 usage 后重新生成即可。
# 下面的美元符号在源码里是转义过的：heredoc 不转义就会在生成时把数组和命令替换掉。
_${__prog}_completions() {
  local __cur __cmd __opts=""
  __cur="\${COMP_WORDS[COMP_CWORD]}"
  # 第一层补命令名；第二层起补该命令 usage 里的选项（只补 - 开头的词，
  # 位置参数不补 —— bash 3.2 没有 compopt，回落不了文件补全）。
  if [ "\$COMP_CWORD" -le 1 ]; then
    COMPREPLY=(\$(compgen -W "$__words" -- "\$__cur"))
    return 0
  fi
  __cmd="\${COMP_WORDS[1]}"
  case "\$__cmd" in
${__cases}  esac
  case "\$__cur" in
    -*) COMPREPLY=(\$(compgen -W "\$__opts --help" -- "\$__cur")) ;;
    *) COMPREPLY=() ;;
  esac
  return 0
}
complete -F _${__prog}_completions $__prog
EOF
  else
    __i=0
    __cases=""
    while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
      __name=${SK_CLI_NAMES[$__i]}
      __opts=$(_sk_cli_opts_of "${SK_CLI_USAGES[$__i]}")
      # zsh 侧 case 分支是数组赋值（与 bash 的字符串赋值分开生成）
      __cases="${__cases}    $__name) __opts=( $__opts ) ;;"$'\n'
      __i=$((__i + 1))
    done
    cat <<EOF
#compdef $__prog
# $__prog completion for zsh
# 由 cli_completion_script 生成；新增子命令或改 usage 后重新生成即可。
_${__prog}() {
  local -a __commands __opts
  __commands=($__words)
  if (( CURRENT == 2 )); then
    _describe 'command' __commands
    return
  fi
  __opts=()
  case "\${words[2]}" in
${__cases}  esac
  __opts+=(--help)
  _describe 'option' __opts
}
compdef _${__prog} $__prog
EOF
  fi
  return 0
}

_sk_suggest() {
  local __n=${1:-} __x __i=0 __hit=""
  while [ "$__i" -lt "${#SK_CLI_NAMES[@]}" ]; do
    __x=${SK_CLI_NAMES[$__i]}
    case "$__x" in
      "$__n"*)
        if [ -z "$__hit" ]; then
          __hit=$__x
        fi
        ;;
    esac
    __i=$((__i + 1))
  done
  if [ -n "$__hit" ]; then
    printf '%s: %s\n' "$(_t 'Did you mean')" "$__hit" >&2
  fi
  return 0
}

# cli_run ARGS... —— 分发入口：吃全局选项后按名字找同名 cmd_ 前缀的函数
# @exitcode 0 命令成功
# @exitcode 2 用法错（没有命令、选项不认识、命令不存在）
# @exitcode 1 命令有 handler 但没实现
# @exitcode 其他 命令自身的退出码
# @stability stable
cli_run() {
  local __name="" __fn="" __rc=0 __depth=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        cli_usage_global
        return 0
        ;;
      -V | --version)
        printf '%s\n' "${SK_VERSION:-dev}"
        return 0
        ;;
      --verbose)
        SHELLKIT_DEBUG=1
        export SHELLKIT_DEBUG
        shift
        ;;
      --no-color)
        SHELLKIT_COLOR=never
        # 由 lib/core/log.sh 的输出函数读取
        # shellcheck disable=SC2034
        SK_COLOR_ON=0
        export SHELLKIT_COLOR
        shift
        ;;
      -y | --yes)
        SHELLKIT_NONINTERACTIVE=1
        export SHELLKIT_NONINTERACTIVE
        shift
        ;;
      --)
        shift
        break
        ;;
      --?*)
        log_error "$(_t 'unknown option'): $1"
        cli_usage_global
        return "$SK_USAGE"
        ;;
      -?*)
        log_error "$(_t 'unknown option'): $1"
        cli_usage_global
        return "$SK_USAGE"
        ;;
      *)
        break
        ;;
    esac
  done

  if [ "$#" -eq 0 ]; then
    cli_usage_global
    return "$SK_USAGE"
  fi

  __name=$1
  shift
  if ! cli_has "$__name"; then
    log_error "$(_t 'no such command'): $__name"
    _sk_suggest "$__name"
    cli_usage_global
    return "$SK_USAGE"
  fi
  __fn=$(_sk_cmd_fn "$__name")
  if ! declare -F "$__fn" >/dev/null 2>&1; then
    log_error "$(_t 'command has no handler'): $__fn"
    return "$SK_ERR"
  fi

  # log_error 已经把消息写进 stderr 并记进 SK_ERRMSG，这里不需要再"补印"一次
  # 错误上下文栈（issue #63）：命令失败时嵌套调用不会逐层 pop，
  # 栈里会留下帧 —— 而 pop 是 LIFO 的，留下的帧会让下一次 pop 弹错层，
  # 后面的报错会带上上一条命令的操作名。这里按「进来时的深度」统一收干净：
  # 栈是诊断用的瞬时状态，命令结束就必须回到进入时的样子。
  # 错误消息在命令返回前就已经印完，回收不会丢掉任何一条。
  __depth=$(_sk_err_ctx_depth)
  __rc=0
  "$__fn" "$@" || __rc=$?
  _sk_err_ctx_unwind "$__depth" || true
  return "$__rc"
}

# ---------- 子命令选项解析 ----------
# 用法：
#   cli_opt_init
#   cli_opt VAR --long [-s] [takes_arg]
#   cli_opts "$@"
# 之后 VAR 为值（布尔为 1 或空），SK_OPTS_LEFT 为剩余位置参数。

SK_OPT_VARS=()
SK_OPT_LONGS=()
SK_OPT_SHORTS=()
SK_OPT_ARGS=()
SK_OPTS_LEFT=()

# cli_opt_init —— 清空选项注册表。不接受参数；变量默认值请自己先赋好
# @exitcode 0 总是成功（清空上一轮的选项状态）
# @stability experimental
cli_opt_init() {
  SK_OPT_VARS=()
  SK_OPT_LONGS=()
  SK_OPT_SHORTS=()
  SK_OPT_ARGS=()
  SK_OPTS_LEFT=()
  return 0
}

# cli_opt VAR LONG [SHORT] [TAKES_ARG] —— 注册一个选项；第四个参数为 1 表示这个选项要吃值
#   VAR 是「选项值要写进的变量名」，不能用库保留名（__ / _sk_ 前缀）。
# @exitcode 0 注册成功
# @exitcode 2 选项名非法，或变量名用了库保留名
# @stability stable
cli_opt() {
  local __var=${1:-} __long=${2:-} __short=${3:-} __arg=${4:-0}
  _sk_need_args "$#" 2 "cli_opt VAR LONG [SHORT] [TAKES_ARG]" || return $?
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  _sk_check_out_name "$__var" || return $?
  case "$__long" in
    --?*) ;;
    *)
      log_error "$(_t 'long option must start with --'): $__long"
      return "$SK_USAGE"
      ;;
  esac
  if [ -n "$__short" ]; then
    case "$__short" in
      -?) ;;
      *)
        log_error "$(_t 'short option must be a single dash and one letter'): $__short"
        return "$SK_USAGE"
        ;;
    esac
  fi
  # 重名注册必须当场拒绝：否则解析会静默只命中最后一个，另一个永远读不到
  if [ -n "$(_sk_opt_idx_long "$__long")" ]; then
    log_error "$(_t 'duplicate option'): $__long"
    return "$SK_USAGE"
  fi
  if [ -n "$__short" ] && [ -n "$(_sk_opt_idx_short "$__short")" ]; then
    log_error "$(_t 'duplicate option'): $__short"
    return "$SK_USAGE"
  fi
  SK_OPT_VARS[${#SK_OPT_VARS[@]}]="$__var"
  SK_OPT_LONGS[${#SK_OPT_LONGS[@]}]="$__long"
  SK_OPT_SHORTS[${#SK_OPT_SHORTS[@]}]="$__short"
  SK_OPT_ARGS[${#SK_OPT_ARGS[@]}]="$__arg"
  # 只在该变量尚未定义时初始化，保留调用方设好的默认值
  eval "if [ -z \"\${$__var+x}\" ]; then $__var=\"\"; fi"
  return 0
}

_sk_opt_idx_long() {
  local __want=${1:-} __i=0
  while [ "$__i" -lt "${#SK_OPT_LONGS[@]}" ]; do
    if [ "${SK_OPT_LONGS[$__i]}" = "$__want" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

_sk_opt_idx_short() {
  local __want=${1:-} __i=0
  while [ "$__i" -lt "${#SK_OPT_SHORTS[@]}" ]; do
    if [ "${SK_OPT_SHORTS[$__i]}" = "$__want" ]; then
      printf '%s' "$__i"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

_sk_opt_set() {
  # 目标变量名放在 __opt_var：这个名字不能和调用方注册的变量名撞上，
  # 否则选项值会写进自己这层、调用方永远读不到（模板里的 --target 就踩过这个）。
  local __idx=${1:-} __val=${2:-} __opt_var
  if [ -z "$__idx" ]; then
    return "$SK_USAGE"
  fi
  __opt_var=${SK_OPT_VARS[$__idx]}
  printf -v "$__opt_var" '%s' "$__val"
  return 0
}

# cli_opts ARGS... —— 按 cli_opt 注册的规则解析子命令选项；剩余位置参数进 SK_OPTS_LEFT
# @exitcode 0 解析成功（剩余位置参数在 SK_OPTS_LEFT）
# @exitcode 2 选项不认识或缺值
# @stability stable
cli_opts() {
  local __idx="" __opt=""
  SK_OPTS_LEFT=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --)
        shift
        while [ "$#" -gt 0 ]; do
          SK_OPTS_LEFT[${#SK_OPTS_LEFT[@]}]="$1"
          shift
        done
        break
        ;;
      --*=*)
        __idx=$(_sk_opt_idx_long "${1%%=*}")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): ${1%%=*}"
          return "$SK_USAGE"
        fi
        # 布尔选项带 = 一律拒绝：把 "garbage" 塞进变量比直接报错难查得多
        if [ "${SK_OPT_ARGS[$__idx]}" != "1" ]; then
          log_error "$(_t 'option does not take a value'): ${1%%=*}"
          return "$SK_USAGE"
        fi
        _sk_opt_set "$__idx" "${1#*=}" || return $?
        shift
        ;;
      --?*)
        __opt=$1
        __idx=$(_sk_opt_idx_long "$__opt")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): $1"
          return "$SK_USAGE"
        fi
        if [ "${SK_OPT_ARGS[$__idx]}" = "1" ]; then
          shift
          if [ "$#" -eq 0 ]; then
            log_error "$(_t 'option requires a value'): $__opt"
            return "$SK_USAGE"
          fi
          _sk_opt_set "$__idx" "$1" || return $?
        else
          _sk_opt_set "$__idx" "1" || return $?
        fi
        shift
        ;;
      -?*)
        __opt=$1
        __idx=$(_sk_opt_idx_short "$__opt")
        if [ -z "$__idx" ]; then
          log_error "$(_t 'unknown option'): $1"
          return "$SK_USAGE"
        fi
        if [ "${SK_OPT_ARGS[$__idx]}" = "1" ]; then
          shift
          if [ "$#" -eq 0 ]; then
            log_error "$(_t 'option requires a value'): $__opt"
            return "$SK_USAGE"
          fi
          _sk_opt_set "$__idx" "$1" || return $?
        else
          _sk_opt_set "$__idx" "1" || return $?
        fi
        shift
        ;;
      *)
        SK_OPTS_LEFT[${#SK_OPTS_LEFT[@]}]="$1"
        shift
        ;;
    esac
  done
  return 0
}
