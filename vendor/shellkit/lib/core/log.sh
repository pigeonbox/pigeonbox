#!/usr/bin/env bash
#
# 日志。全部写 stderr —— 这是全库最重要的约定：
# stdout 只留给数据，所以 v=$(conf_get KEY) 永远不会混进 [INFO]。
#
# 三个可选开关，全部只加不改：不设时的行为与从前逐字一致。
#
#   SHELLKIT_LOG_LEVEL   debug|info|warn|error，默认 info。低于该级别的消息不输出；
#                        log_ok 与 log_section 算 info 级。比较时大小写不敏感。
#   SHELLKIT_LOG_FORMAT  text|json，默认 text。json 模式一条消息一行紧凑 JSON：
#                        {"ts":"2026-11-09T12:34:56+08:00","level":"INFO","msg":"..."}
#   SHELLKIT_LOG_FILE    非空时把日志同时追加到该文件（文件不存在就创建）。

_sk_color_on() {
  case "${SHELLKIT_COLOR:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    *) [ -t 2 ] ;;
  esac
}

if _sk_color_on; then
  SK_COLOR_ON=1
else
  SK_COLOR_ON=0
fi

# _sk_log_threshold OUTVAR —— 把 SHELLKIT_LOG_LEVEL 折成能比大小的数值
# debug=10 info=20 warn=30 error=40。没设或认不出来一律按 info（20）。
_sk_log_threshold() {
  local __outvar=$1
  case "${SHELLKIT_LOG_LEVEL:-}" in
    [dD][eE][bB][uU][gG]) printf -v "$__outvar" '%s' 10 ;;
    [iI][nN][fF][oO]) printf -v "$__outvar" '%s' 20 ;;
    [wW][aA][rR][nN]) printf -v "$__outvar" '%s' 30 ;;
    [eE][rR][rR][oO][rR]) printf -v "$__outvar" '%s' 40 ;;
    *) printf -v "$__outvar" '%s' 20 ;;
  esac
}

# _sk_log_enabled RANK —— 这条消息现在要不要输出
# debug 有个例外：SHELLKIT_DEBUG=1 单独就能打开（老行为），跟级别无关。
_sk_log_enabled() {
  local __rank=$1 __thr
  _sk_log_threshold __thr
  if [ "$__rank" -ge "$__thr" ]; then
    return 0
  fi
  if [ "$__rank" = "10" ] && [ "${SHELLKIT_DEBUG:-0}" = "1" ]; then
    return 0
  fi
  return 1
}

# _sk_log_is_json —— 输出格式是不是 json
_sk_log_is_json() {
  case "${SHELLKIT_LOG_FORMAT:-}" in
    [jJ][sS][oO][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

# _sk_log_timestamp OUTVAR —— 本地时间 ISO8601，带时区偏移（+08:00）
# %z 在 macOS 与 Linux 上都给 +0800，这里补上中间的冒号。
_sk_log_timestamp() {
  local __outvar=$1 __raw __len __tail
  __raw=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null) || __raw=''
  if [ -z "$__raw" ]; then
    printf -v "$__outvar" '%s' ''
    return 0
  fi
  __len=${#__raw}
  if [ "$__len" -ge 5 ]; then
    __tail=${__raw:$((__len - 5)):5}
    case "$__tail" in
      [+-][0-9][0-9][0-9][0-9])
        printf -v "$__outvar" '%s' "${__raw:0:$((__len - 5))}${__tail:0:3}:${__tail:3:2}"
        return 0
        ;;
    esac
  fi
  printf -v "$__outvar" '%s' "$__raw"
}

# _sk_json_escape OUTVAR STR —— 把 STR 变成可以放进 JSON 字符串的内容
# 转义 \ " \b \f \n \r \t；剩下的控制字符转成 \u00XX。
# UTF-8 多字节原样保留（JSON 允许直接写非 ASCII）。
_sk_json_escape() {
  local __outvar=$1 __s=$2 __rest __c __code
  __s=${__s//\\/\\\\}
  __s=${__s//\"/\\\"}
  __s=${__s//$'\b'/\\b}
  __s=${__s//$'\f'/\\f}
  __s=${__s//$'\n'/\\n}
  __s=${__s//$'\r'/\\r}
  __s=${__s//$'\t'/\\t}
  case "$__s" in
    *[[:cntrl:]]*)
      __rest=$__s
      __s=''
      while [ -n "$__rest" ]; do
        __c=${__rest:0:1}
        __rest=${__rest:1}
        case "$__c" in
          [[:cntrl:]])
            printf -v __code '%d' "'$__c"
            printf -v __code '\\u%04x' "$__code"
            __s="${__s}${__code}"
            ;;
          *) __s="${__s}${__c}" ;;
        esac
      done
      ;;
  esac
  printf -v "$__outvar" '%s' "$__s"
}

# _sk_log_json_line OUTVAR LEVEL MSG —— 拼出一行紧凑 JSON
# 一条日志一行：msg 里的换行已经转义过，不会把这一行打断。
_sk_log_json_line() {
  local __outvar=$1 __level=$2 __msg=$3 __esc __ts
  _sk_json_escape __esc "$__msg"
  _sk_log_timestamp __ts
  printf -v "$__outvar" '%s' "{\"ts\":\"$__ts\",\"level\":\"$__level\",\"msg\":\"$__esc\"}"
}

# _sk_log_file_error PATH —— 日志文件打不开时只在 stderr 报一次
# 同一个路径只报一次，免得刷屏；之后继续往 stderr 写，只是不再写文件。
# 报错走 _t（用户可见文案），但不走 log_error —— 那会再写一次文件，成环。
_sk_log_file_error() {
  local __path=$1
  case "${SK_LOG_FILE_ERRORS:-}" in
    *"
${__path}
"*) return 0 ;;
  esac
  SK_LOG_FILE_ERRORS="${SK_LOG_FILE_ERRORS:-}
${__path}"
  if _sk_log_is_json; then
    __err_line=""
    _sk_log_json_line __err_line ERROR "$(_t 'no write permission'): ${__path}"
    printf '%s\n' "$__err_line" >&2
  else
    printf '[ERROR] %s: %s\n' "$(_t 'no write permission')" "$__path" >&2
  fi
  return 0
}

# _sk_log_file_write LINE —— 把一行追加到 SHELLKIT_LOG_FILE
# 语义：SHELLKIT_LOG_FILE 为空就什么都不做；文件不存在就创建；
# 父目录不存在或没有写权限时只报错，不抛异常、不改退出码 —— 日志写不进去
# 不该让调用方的脚本崩掉。
_sk_log_file_write() {
  local __line=$1 __file=${SHELLKIT_LOG_FILE:-}
  [ -n "$__file" ] || return 0
  if ! printf '%s\n' "$__line" 2>/dev/null >>"$__file"; then
    _sk_log_file_error "$__file"
  fi
  return 0
}

# _sk_log LEVEL RANK MSG... —— 所有 log_* 的共同出口
# LEVEL 是 JSON 里的 level 字段（INFO/OK/WARN/ERROR/DEBUG）；
# RANK 是比较级别用的数值（10/20/30/40）。
_sk_log() {
  local __level=$1 __rank=$2
  shift 2
  local __msg="$*" __label __color __line

  if ! _sk_log_enabled "$__rank"; then
    return 0
  fi

  if _sk_log_is_json; then
    _sk_log_json_line __line "$__level" "$__msg"
    printf '%s\n' "$__line" >&2
    _sk_log_file_write "$__line"
    return 0
  fi

  case "$__level" in
    OK)
      __label=' OK '
      __color='1;32'
      ;;
    WARN)
      __label=WARN
      __color='1;33'
      ;;
    ERROR)
      __label=ERROR
      __color='1;31'
      ;;
    DEBUG)
      __label=DEBUG
      __color='1;36'
      ;;
    *)
      __label=INFO
      __color=''
      ;;
  esac
  if [ "${SK_COLOR_ON:-0}" = "1" ] && [ -n "$__color" ]; then
    printf '\033[%sm[%s]\033[0m %s\n' "$__color" "$__label" "$__msg" >&2
  else
    printf '[%s] %s\n' "$__label" "$__msg" >&2
  fi
  # 写进文件的是不带颜色的纯文本行
  _sk_log_file_write "[${__label}] ${__msg}"
  return 0
}

# log_info MSG... —— 普通信息
# @exitcode 0 总是成功（级别不够时什么都不输出）
# @stability experimental
log_info() { _sk_log INFO 20 "$@"; }

# log_ok MSG... —— 成功；单独用 " OK " 是为了和四字母级别对齐
# @exitcode 0 总是成功（级别不够时什么都不输出）
# @stability experimental
log_ok() { _sk_log OK 20 "$@"; }

# log_warn MSG... —— 警告，不中断
# @exitcode 0 总是成功（级别不够时什么都不输出）
# @stability experimental
log_warn() { _sk_log WARN 30 "$@"; }

# ---------------------------------------------------------------------------
# 错误上下文：路径信息与操作栈（issue #63）
#
# 失败信息要回答三个问题：哪一步失败了、当时的输入是什么、当时的文件在哪。
# 只说「哪一步」不够 —— 用户真正要看到的是「哪个文件、绝对路径、指向哪里」。
#
# 两块能力：
#   1. 路径上下文（_sk_err_path_info）：绝对路径 + 软链指向
#   2. 操作栈（_sk_err_ctx_push）：模块之间传「当前在做什么」，出错时组装成一条链
#
# 纯内部能力，不新增公开 API。既有错误文案不推翻 —— 上下文是**追加**的：
# 上下文栈为空时，log_error（以及走它的 die / fail）的输出与以前逐字相同。
# ---------------------------------------------------------------------------

# 上下文栈：操作名与参数各一个平行数组（bash 3.2 没有关联数组）
_SK_ERR_CTX_OPS=()
_SK_ERR_CTX_PARAMS=()

# _sk_secret_key_name KEY —— 键名看起来是不是敏感字段
#
# 判断的是「键名」，不是值：值什么样都行，键名像敏感字段就该遮。
# 常见写法：--password、--api-key、API_TOKEN=...、DB_PASSWORD=...
#
# 为什么住在 log 而不是 run：log 比 run 先加载（run 依赖 log），反向不行 ——
# 而错误上下文的脱敏要用它，log 用不到 run。
# run.sh 里的 _sk_run_secret_key 现在是它的壳（那个名字已有调用方，不改）。
_sk_secret_key_name() {
  local __k=${1:-} __l
  __l=$(printf '%s' "$__k" | tr 'A-Z' 'a-z')
  case "$__l" in
    *password* | *passwd* | *secret* | *token* | *apikey* | *api[_-]key* | \
      *access[_-]key* | *private[_-]key* | *credential* | *authorization*)
      return 0
      ;;
  esac
  # 以 key 结尾的（X-Api-Key、X-Custom-Key）：分隔符是词边界，
  # 否则 monkey 这种普通词也会被当成敏感字段 —— 过度脱敏会让日志失去排障价值。
  case "$__l" in
    key | *[-_.]key) return 0 ;;
  esac
  return 1
}

# _sk_err_redact_param PARAM —— 一条 KEY=VALUE 参数；敏感键名的值遮成 ***
#
# 上下文里的参数是「当时的输入」，而输入里常常混着口令 ——
# 错误上下文会进日志、进工单、进 issue，所以脱敏是默认行为而不是可选项。
_sk_err_redact_param() {
  local __p=${1:-} __k="" __v=""
  [ -n "$__p" ] || return 0
  case "$__p" in
    *=*)
      __k=${__p%%=*}
      __v=${__p#*=}
      ;;
    *)
      printf '%s' "$__p"
      return 0
      ;;
  esac
  if _sk_secret_key_name "$__k"; then
    printf '%s=***' "$__k"
  else
    printf '%s' "$__p"
  fi
}

# _sk_err_ctx_push OP [KEY=VALUE ...] —— 压一层「当前在做什么」
#
# OP 是**已经本地化过**的操作名（调用方传 $(...) 的结果）。
# 参数是 KEY=VALUE 形式；键名像敏感字段时值自动遮成 ***。
#
# 为什么用栈而不是单个变量：一次调用链有多层 ——「升级工程」里面会「同步 vendor」，
# 底层失败时顶层要能说清楚「这是在升级工程时同步 vendor 失败」。
_sk_err_ctx_push() {
  local __op=${1:-} __p __params=""
  if [ "$#" -gt 0 ]; then
    shift
  fi
  for __p in "$@"; do
    [ -n "$__p" ] || continue
    if [ -n "$__params" ]; then
      __params="$__params $(_sk_err_redact_param "$__p")"
    else
      __params=$(_sk_err_redact_param "$__p")
    fi
  done
  _SK_ERR_CTX_OPS[${#_SK_ERR_CTX_OPS[@]}]="$__op"
  _SK_ERR_CTX_PARAMS[${#_SK_ERR_CTX_PARAMS[@]}]="$__params"
  return 0
}

# _sk_err_ctx_pop —— 弹掉栈顶那层；栈空时返回 1
_sk_err_ctx_pop() {
  local __n=${#_SK_ERR_CTX_OPS[@]} __i=0 __last=0
  local __ops=() __params=()
  [ "$__n" -gt 0 ] || return 1
  __last=$((__n - 1))
  while [ "$__i" -lt "$__n" ]; do
    if [ "$__i" -ne "$__last" ]; then
      __ops[${#__ops[@]}]="${_SK_ERR_CTX_OPS[$__i]}"
      __params[${#__params[@]}]="${_SK_ERR_CTX_PARAMS[$__i]}"
    fi
    __i=$((__i + 1))
  done
  _SK_ERR_CTX_OPS=(${__ops[@]+"${__ops[@]}"})
  _SK_ERR_CTX_PARAMS=(${__params[@]+"${__params[@]}"})
  return 0
}

# _sk_err_ctx_depth —— 当前栈深
#
# 分发层用它记住「命令进来时栈有多深」，命令结束时把栈收到这个深度。
_sk_err_ctx_depth() {
  printf '%s' "${#_SK_ERR_CTX_OPS[@]}"
}

# _sk_err_ctx_unwind DEPTH —— 把栈截回 DEPTH 层；已经比它浅就什么都不做
#
# 为什么光有 pop 不够：嵌套调用失败时各个 return 不会逐层 pop
# （cmd_upgrade 就会在 _sk_vendor_install 失败后继续写清单），
# 栈里会留下面包屑 —— 而 pop 是 LIFO 的，留下的帧会让下一次 pop 弹错层，
# 后面的报错会带上一条命令的操作名。
# 栈是诊断用的瞬时状态，命令结束就必须回到进入时的样子；
# 由分发层统一回收，就不会依赖每个失败路径都记得 pop。
# 与 _sk_err_ctx_pop 同构（循环 + ${arr[@]+...} 守卫），避开 bash 3.2 空数组展开。
_sk_err_ctx_unwind() {
  # ${1-} 而不是 ${1:-0}：DEPTH 是必填的。空串是调用方的 bug，
  # 当成 0 会让它静默清空整条栈 —— 那正是这条判据要挡的「悄悄把现场抹掉」。
  local __keep=${1-} __n=${#_SK_ERR_CTX_OPS[@]} __i=0
  local __ops=() __params=()
  case "$__keep" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$__n" -le "$__keep" ] && return 0
  while [ "$__i" -lt "$__keep" ]; do
    __ops[${#__ops[@]}]="${_SK_ERR_CTX_OPS[$__i]}"
    __params[${#__params[@]}]="${_SK_ERR_CTX_PARAMS[$__i]}"
    __i=$((__i + 1))
  done
  _SK_ERR_CTX_OPS=(${__ops[@]+"${__ops[@]}"})
  _SK_ERR_CTX_PARAMS=(${__params[@]+"${__params[@]}"})
  return 0
}

# _sk_err_ctx_render —— 把上下文栈渲染成一行；栈空时是空串
#
# 形如：syncing (dir=/path/to/project) > upgrading (dir=/path/to/project)
_sk_err_ctx_render() {
  local __i=0 __n=${#_SK_ERR_CTX_OPS[@]} __out="" __op __params
  while [ "$__i" -lt "$__n" ]; do
    __op=${_SK_ERR_CTX_OPS[$__i]}
    __params=${_SK_ERR_CTX_PARAMS[$__i]}
    if [ -n "$__op" ]; then
      if [ -n "$__params" ]; then
        __out="$__out${__out:+ > }$__op ($__params)"
      else
        __out="$__out${__out:+ > }$__op"
      fi
    fi
    __i=$((__i + 1))
  done
  printf '%s' "$__out"
}

# _sk_err_ctx_suffix —— 上下文的可打印后缀；栈空时是空串
#
# 空栈时为空串是硬要求：既有错误文案不推翻（issue #63 的约束），
# 所有没压上下文的调用点，输出与以前逐字相同。
_sk_err_ctx_suffix() {
  local __txt
  __txt=$(_sk_err_ctx_render)
  [ -n "$__txt" ] || return 0
  printf ' [context: %s]' "$__txt"
}

# _sk_err_abs_path PATH —— 绝对路径
#
# 叶子不存在时按父目录解析 —— 待生成的目录（工程目录、prefix）
# 往往还不存在，这时整条路径没法 pwd，但父目录总是存在的。
_sk_err_abs_path() {
  local __p=${1:-} __dir="" __base=""
  [ -n "$__p" ] || return 0
  # 现成的目录直接 cd 过去取真实路径 —— 这一条同时解决 "." 与 ".."：
  # 按「父目录 + basename」拼的话，basename(".") 是 "."，拼出来会多个 "/."。
  # 软链不算：软链的路径本身就是身份，解析成目标就看不见这个软链了。
  if [ -d "$__p" ] && [ ! -L "$__p" ]; then
    printf '%s' "$(cd "$__p" 2>/dev/null && pwd -P)"
    return 0
  fi
  __base=${__p##*/}
  __dir=${__p%/*}
  [ "$__dir" = "$__p" ] && __dir="."
  if [ -d "$__dir" ]; then
    printf '%s/%s' "$(cd "$__dir" 2>/dev/null && pwd -P)" "$__base"
  else
    printf '%s' "$__p"
  fi
}

# _sk_err_path_info PATH —— 路径上下文：绝对路径 + 软链指向
#
# 输出形如：path=/abs/file symlink=/abs/target
# 软链指向用 readlink 的结果；相对指向按链接所在目录解析成绝对路径 ——
# 原样打印相对指向对排障没用（相对于谁？）。
_sk_err_path_info() {
  local __p=${1:-} __abs="" __link="" __tgt="" __dir=""
  [ -n "$__p" ] || return 0
  __abs=$(_sk_err_abs_path "$__p")
  printf 'path=%s' "$__abs"
  if [ -L "$__p" ]; then
    __link=$(readlink "$__p" 2>/dev/null) || __link=""
    if [ -n "$__link" ]; then
      __dir=${__abs%/*}
      case "$__link" in
        /*) __tgt="$__link" ;;
        *) __tgt="$__dir/$__link" ;;
      esac
      printf ' symlink=%s' "$__tgt"
    fi
  fi
  return 0
}

# log_error MSG... —— 输出错误（stderr），并把最后一条错误记进 SK_ERRMSG
# @exitcode 0 总是成功；同时把消息记进 SK_ERRMSG
# @stability experimental
log_error() {
  local __msg="$*"
  # 错误上下文（issue #63）：栈空时输出与以前逐字相同；
  # 栈非空时把「当前在做什么」接在消息后面 ——
  # 底层失败时，顶层输出要能看出这是在装 skill 还是在升级工程。
  if [ "${#_SK_ERR_CTX_OPS[@]}" -gt 0 ]; then
    __msg="$__msg$(_sk_err_ctx_suffix)"
  fi
  # 公开变量：供调用方在退出前读取最后一条错误
  # shellcheck disable=SC2034
  SK_ERRMSG="$__msg"
  _sk_log ERROR 40 "$__msg"
}

# log_debug MSG... —— 仅在 SHELLKIT_DEBUG=1 或 SHELLKIT_LOG_LEVEL=debug 时输出
# @exitcode 0 总是成功（要 SHELLKIT_DEBUG=1 或 SHELLKIT_LOG_LEVEL=debug 才输出）
# @stability experimental
log_debug() { _sk_log DEBUG 10 "$@"; }

# log_section TITLE —— 分段标题，带前导空行
# json 模式下什么都不输出：JSON 行是给采集器消费的，标题没有 level 语义，
# 混进去会破坏「一行一条记录」的约定。文本模式保持原样。
# @exitcode 0 总是成功（json 模式下不输出）
# @stability experimental
log_section() {
  if _sk_log_is_json; then
    return 0
  fi
  if ! _sk_log_enabled 20; then
    return 0
  fi
  if [ "${SK_COLOR_ON:-0}" = "1" ]; then
    printf '\n\033[1;33m==> %s\033[0m\n' "$*" >&2
  else
    printf '\n==> %s\n' "$*" >&2
  fi
  _sk_log_file_write "==> $*"
  return 0
}
