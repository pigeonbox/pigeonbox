#!/usr/bin/env bash
#
# 配置文件读写。KEY=VALUE 格式。
# 关键性质：conf_get 只往 stdout 输出值，因此可以安全地嵌进 $(...) 。
#
# 取值链（conf_get_any）：环境变量 > 配置层 > 配置文件 > 默认值。
#   配置层   内存键值表，由 conf_load_dotenv 写入。Bash 3.2 没有关联数组，
#             所以用平行数组 + 计数器（SK_CONF_KEYS / SK_CONF_VALUES / SK_CONF_N）。
#   配置文件 conf_init 指定的文件，按 SK_CONF_FORMAT 解析。
#
# 格式（SK_CONF_FORMAT）：
#   auto    默认。老形态 KEY=VALUE 逐字沿用历史取值（值原样保留，引号与行尾空白
#           都不动）；老形态之外的行按 dotenv 解析（export 前缀、引号等）。
#   env     严格 KEY=VALUE。dotenv 专有的行报错跳过。
#   dotenv  完整 dotenv 语义：export 前缀、成对引号剥离、未加引号的值去行尾空白。

SK_CONF_FILE=""
SK_CONF_FORMAT="auto"
SK_CONF_KEYS=()
SK_CONF_VALUES=()
SK_CONF_N=0

# _sk_conf_assign 的解析结果（_ 前缀 = 私有，不进文档）
_SK_CONF_PKEY=""
_SK_CONF_PVAL=""
_SK_CONF_DVAL=""

# _sk_conf_env_shape LINE —— 是否是严格形态的 KEY=VALUE（键合法且紧跟 '='）
_sk_conf_env_shape() {
  local __s=${1:-} __k
  case "$__s" in
    *=*) ;;
    *) return 1 ;;
  esac
  __k=${__s%%=*}
  validate_key "$__k" || return 1
  return 0
}

# _sk_conf_dotenv_value RAW —— dotenv 的值归一化；结果放在 _SK_CONF_DVAL
# 成对的单/双引号剥掉（引号里的内容原样保留，不解释转义）；
# 未加引号的值只去掉行尾空白，中间的空格保留。
_sk_conf_dotenv_value() {
  local __v=${1:-}
  __v="${__v%"${__v##*[![:space:]]}"}"
  case "$__v" in
    '"'*'"')
      if [ ${#__v} -ge 2 ]; then
        __v=${__v#?}
        __v=${__v%?}
      fi
      ;;
    "'"*"'")
      if [ ${#__v} -ge 2 ]; then
        __v=${__v#?}
        __v=${__v%?}
      fi
      ;;
  esac
  _SK_CONF_DVAL=$__v
  return 0
}

# _sk_conf_assign LINE FORMAT —— 解析一行赋值
# 返回 0：得到键值（写在 _SK_CONF_PKEY / _SK_CONF_PVAL）
# 返回 1：空行或注释行，静默跳过
# 返回 2：非法行，调用方负责告警
_sk_conf_assign() {
  local __line=${1:-} __fmt=${2:-auto} __body __key
  _SK_CONF_PKEY=""
  _SK_CONF_PVAL=""
  case "$__line" in
    '' | '#'*) return 1 ;;
  esac
  case "$__fmt" in
    env | dotenv | auto) ;;
    *) __fmt="auto" ;;
  esac
  # auto：老形态优先（值原样保留，逐字兼容历史行为），其余按 dotenv 解析
  if [ "$__fmt" = "auto" ]; then
    if _sk_conf_env_shape "$__line"; then
      _SK_CONF_PKEY=${__line%%=*}
      _SK_CONF_PVAL=${__line#*=}
      return 0
    fi
    __fmt="dotenv"
  fi
  __body="$__line"
  case "$__fmt" in
    env)
      if ! _sk_conf_env_shape "$__body"; then
        return 2
      fi
      _SK_CONF_PKEY=${__body%%=*}
      _SK_CONF_PVAL=${__body#*=}
      return 0
      ;;
    dotenv)
      # 去行首空白，再剥 export 前缀
      __body="${__body#"${__body%%[![:space:]]*}"}"
      case "$__body" in
        export[[:space:]]*)
          __body=${__body#export}
          __body="${__body#"${__body%%[![:space:]]*}"}"
          ;;
      esac
      case "$__body" in
        *=*) ;;
        *) return 2 ;;
      esac
      __key=${__body%%=*}
      if ! validate_key "$__key"; then
        return 2
      fi
      _sk_conf_dotenv_value "${__body#*=}"
      _SK_CONF_PKEY=$__key
      _SK_CONF_PVAL=$_SK_CONF_DVAL
      return 0
      ;;
  esac
  return 2
}

# _sk_conf_dotenv_token VALUE —— 生成 dotenv 里能读回原值的写法
#
# 取值端只做两件事：剥最外层的一对引号、去行尾空白。所以「原样」不是总能用 ——
# 值本身带行尾空白、或首尾是同一个引号时，读回来就不是它了。
# 这里逐个候选试一遍，用取值端自己验算：读回来等于原值才算数。
_sk_conf_dotenv_token() {
  local __v=${1:-} __cand
  _sk_conf_dotenv_value "$__v"
  if [ "$_SK_CONF_DVAL" = "$__v" ]; then
    printf '%s' "$__v"
    return 0
  fi
  __cand="\"$__v\""
  _sk_conf_dotenv_value "$__cand"
  if [ "$_SK_CONF_DVAL" = "$__v" ]; then
    printf '%s' "$__cand"
    return 0
  fi
  __cand="'$__v'"
  _sk_conf_dotenv_value "$__cand"
  if [ "$_SK_CONF_DVAL" = "$__v" ]; then
    printf '%s' "$__cand"
    return 0
  fi
  printf '%s' "$__v"
  return 0
}

# _sk_conf_line_style LINE FORMAT —— 这行按哪种语义写回去：env 还是 dotenv
#
# auto 模式下逐行判断：老形态（KEY=VALUE，键合法）按 env 写，其余按 dotenv 写。
# env 写 = 值原样（取回来就是原值）；dotenv 写 = 值要能读回来（引号与空白按 dotenv 规则）。
_sk_conf_line_style() {
  local __line=${1:-} __fmt=${2:-auto}
  case "$__fmt" in
    env)
      printf 'env\n'
      return 0
      ;;
    dotenv)
      printf 'dotenv\n'
      return 0
      ;;
  esac
  if _sk_conf_env_shape "$__line"; then
    printf 'env\n'
  else
    printf 'dotenv\n'
  fi
  return 0
}

# _sk_conf_render_line LINE KEY VALUE FORMAT —— 把一行赋值改写成新值
#
# 保留原来的写法：export 前缀留着，引号风格留着（值里出现同一个引号就换成
# 能读回来的那种写法）。这样 conf_set 改一个 dotenv 文件，不会把它改成另一种风格。
# @exitcode 0 改写后的那一行写进 stdout 了
# @exitcode 1 写失败（磁盘满 / 配额超限）—— 调用方必须当失败处理，
#            否则半截内容会被改名成正式配置
_sk_conf_render_line() {
  local __line=${1:-} __key=${2:-} __value=${3:-} __fmt=${4:-auto}
  local __style __body __prefix="" __quote="" __raw
  __style=$(_sk_conf_line_style "$__line" "$__fmt")
  if [ "$__style" = "env" ]; then
    printf '%s=%s\n' "$__key" "$__value"
    return
  fi
  __body="$__line"
  __body="${__body#"${__body%%[![:space:]]*}"}"
  case "$__body" in
    export[[:space:]]*)
      __prefix="export "
      __body=${__body#export}
      __body="${__body#"${__body%%[![:space:]]*}"}"
      ;;
  esac
  __raw="${__body#*=}"
  case "$__raw" in
    '"'*'"') __quote='"' ;;
    "'"*"'") __quote="'" ;;
  esac
  if [ -n "$__quote" ]; then
    case "$__value" in
      *"$__quote"*) __quote="" ;;
    esac
  fi
  if [ -n "$__quote" ]; then
    printf '%s%s=%s%s%s\n' "$__prefix" "$__key" "$__quote" "$__value" "$__quote"
  else
    printf '%s%s=%s\n' "$__prefix" "$__key" "$(_sk_conf_dotenv_token "$__value")"
  fi
}

# _sk_conf_new_line KEY VALUE FORMAT —— 追加一个新键时该怎么写
#
# env 与 auto：原样写（KEY=VALUE），取回来就是原值。
# dotenv：值要能读回来，带行尾空白或首尾引号的值会被加上引号。
# @exitcode 0 新行写进 stdout 了
# @exitcode 1 写失败（磁盘满 / 配额超限）—— 同 _sk_conf_render_line
_sk_conf_new_line() {
  local __key=${1:-} __value=${2:-} __fmt=${3:-auto}
  case "$__fmt" in
    dotenv)
      printf '%s=%s\n' "$__key" "$(_sk_conf_dotenv_token "$__value")"
      ;;
    *)
      printf '%s=%s\n' "$__key" "$__value"
      ;;
  esac
}

# _sk_conf_layer_set KEY VALUE —— 写配置层；同键覆盖
_sk_conf_layer_set() {
  local __key=${1:-} __val=${2:-} __i=0
  while [ "$__i" -lt "$SK_CONF_N" ]; do
    if [ "${SK_CONF_KEYS[$__i]}" = "$__key" ]; then
      SK_CONF_VALUES[$__i]=$__val
      return 0
    fi
    __i=$((__i + 1))
  done
  SK_CONF_KEYS[$SK_CONF_N]=$__key
  SK_CONF_VALUES[$SK_CONF_N]=$__val
  SK_CONF_N=$((SK_CONF_N + 1))
  return 0
}

# _sk_conf_layer_get KEY —— 找到则输出值并返回 0；没有返回 1
_sk_conf_layer_get() {
  local __key=${1:-} __i=0
  while [ "$__i" -lt "$SK_CONF_N" ]; do
    if [ "${SK_CONF_KEYS[$__i]}" = "$__key" ]; then
      printf '%s\n' "${SK_CONF_VALUES[$__i]}"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# _sk_conf_layer_has KEY —— 配置层里有没有这个键
_sk_conf_layer_has() {
  local __key=${1:-} __i=0
  while [ "$__i" -lt "$SK_CONF_N" ]; do
    if [ "${SK_CONF_KEYS[$__i]}" = "$__key" ]; then
      return 0
    fi
    __i=$((__i + 1))
  done
  return 1
}

# _sk_conf_layer_del KEY —— 从配置层删键；没有也算成功
_sk_conf_layer_del() {
  local __key=${1:-} __i=0 __j=0
  while [ "$__i" -lt "$SK_CONF_N" ]; do
    if [ "${SK_CONF_KEYS[$__i]}" = "$__key" ]; then
      while [ "$__j" -lt $((SK_CONF_N - 1)) ]; do
        SK_CONF_KEYS[$__j]=${SK_CONF_KEYS[$((__j + 1))]}
        SK_CONF_VALUES[$__j]=${SK_CONF_VALUES[$((__j + 1))]}
        __j=$((__j + 1))
      done
      SK_CONF_N=$((SK_CONF_N - 1))
      unset "SK_CONF_KEYS[$SK_CONF_N]" "SK_CONF_VALUES[$SK_CONF_N]"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

# conf_init FILE [--format env|dotenv] —— 载入配置文件；文件不存在不报错（当成空配置）
# --format 决定文件怎么解析：auto（默认，老行为 + 容忍 dotenv 写法）、
# env（严格 KEY=VALUE）、dotenv（完整 dotenv 语义）。
# 严格格式（env / dotenv）下不合规的行会在载入时报警并跳过。
# @exitcode 0 成功（文件不存在当成空配置）
# @exitcode 2 参数错（没给路径或格式不认识）
# @stability stable
conf_init() {
  local __file="" __format="auto" __seen=0 __line __lineno=0 __rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        if [ $# -lt 2 ]; then
          log_error "$(_t 'Usage'): conf_init FILE [--format env|dotenv]"
          return "$SK_USAGE"
        fi
        __format=$2
        shift 2
        ;;
      --format=*)
        __format=${1#--format=}
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        log_error "$(_t 'Usage'): conf_init FILE [--format env|dotenv]"
        return "$SK_USAGE"
        ;;
      *)
        if [ "$__seen" -eq 1 ]; then
          log_error "$(_t 'Usage'): conf_init FILE [--format env|dotenv]"
          return "$SK_USAGE"
        fi
        __file=$1
        __seen=1
        shift
        ;;
    esac
  done
  if ! validate_not_empty "$__file"; then
    log_error "$(_t 'configuration file path is required')"
    return "$SK_USAGE"
  fi
  case "$__format" in
    auto | env | dotenv) ;;
    *)
      log_error "$(_t 'invalid configuration format'): $__format"
      return "$SK_USAGE"
      ;;
  esac
  SK_CONF_FILE=$__file
  SK_CONF_FORMAT=$__format
  export SK_CONF_FILE
  # 严格格式：载入时就把不合规的行指出来，别等取值时才发现
  if [ "$__format" != "auto" ] && [ -f "$__file" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      __lineno=$((__lineno + 1))
      case "$__line" in
        '' | '#'*) continue ;;
      esac
      _sk_conf_assign "$__line" "$__format"
      __rc=$?
      if [ "$__rc" -eq 2 ]; then
        if [ "$__format" = "env" ]; then
          log_warn "$(_t 'skipping invalid configuration line'): $__file:$__lineno"
        else
          log_warn "$(_t 'skipping invalid dotenv line'): $__file:$__lineno"
        fi
      fi
    done <"$__file"
  fi
  return 0
}

# conf_file —— 当前生效的配置文件路径；未初始化时为空
# @exitcode 0 总是成功（stdout 输出当前配置文件路径）
# @stability stable
conf_file() { printf '%s\n' "${SK_CONF_FILE:-}"; }

# conf_format —— 当前生效的配置格式（auto|env|dotenv）
# @exitcode 0 总是成功（stdout 输出当前解析格式）
# @stability stable
conf_format() { printf '%s\n' "${SK_CONF_FORMAT:-auto}"; }

# conf_get KEY [DEFAULT] —— 只输出值；未初始化或无文件时返回默认值
# 取值顺序：配置层 > 配置文件。键存在但值为空时返回空串，不回落默认值。
# @exitcode 0 成功（stdout 输出值；没配过就输出默认值）
# @exitcode 2 键名非法
# @stability stable
conf_get() {
  local __key=${1:-} __default=${2:-} __file=${SK_CONF_FILE:-} __line __value="" __found=0 __rc
  if ! validate_key "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  __value=$(_sk_conf_layer_get "$__key")
  __rc=$?
  if [ "$__rc" -eq 0 ]; then
    printf '%s\n' "$__value"
    return 0
  fi
  if [ -n "$__file" ] && [ -f "$__file" ]; then
    while IFS= read -r __line || [ -n "$__line" ]; do
      case "$__line" in
        '' | '#'*) continue ;;
      esac
      _sk_conf_assign "$__line" "${SK_CONF_FORMAT:-auto}"
      if [ "$?" -eq 0 ] && [ "$_SK_CONF_PKEY" = "$__key" ]; then
        __value=$_SK_CONF_PVAL
        __found=1
      fi
    done <"$__file"
  fi
  # 键存在但值为空时保留空串：把空值当成"没配过"会让显式置空退回默认值
  if [ "$__found" -eq 0 ]; then
    __value=$__default
  fi
  printf '%s\n' "$__value"
  return 0
}

# conf_has KEY —— 返回码 0/1
# @exitcode 0 键存在
# @exitcode 1 键不存在
# @exitcode 2 键名非法
# @stability stable
conf_has() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  if _sk_conf_layer_has "$__key"; then
    return 0
  fi
  if [ -z "$__file" ] || [ ! -f "$__file" ]; then
    return 1
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    _sk_conf_assign "$__line" "${SK_CONF_FORMAT:-auto}"
    if [ "$?" -eq 0 ] && [ "$_SK_CONF_PKEY" = "$__key" ]; then
      return 0
    fi
  done <"$__file"
  return 1
}

# conf_get_any KEY [DEFAULT] —— 环境变量 > 配置层 > 配置文件 > 默认值
# @exitcode 0 成功（stdout 输出值：环境变量 > 配置层 > 配置文件 > 默认值）
# @exitcode 2 键名非法
# @stability stable
conf_get_any() {
  local __key=${1:-} __default=${2:-} __env=""
  if ! _sk_is_name "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  eval "__env=\${$__key-}"
  if [ -n "$__env" ]; then
    printf '%s\n' "$__env"
    return 0
  fi
  conf_get "$__key" "$__default"
}

# conf_load_dotenv FILE —— 把 dotenv 文件的键值载入配置层
#
# 解析规则：空行与 '#' 开头的行忽略；允许行首 export 前缀；键必须是合法变量名；
# 成对的单/双引号剥掉（引号内内容原样保留，不解释转义）；未加引号的值去行尾空白、
# 保留中间空格；KEY= 是"键存在且值为空"；同一文件里后出现的键覆盖先出现的。
#
# 取舍：只进配置层，不 export 到调用方的环境变量 —— 环境变量优先级最高，
# 往里塞东西会盖掉调用方自己的设置。确实要导出时用 conf_source。
#
# 非法行跳过并告警，不整体失败。文件不存在返回 SK_PRECOND。
# @exitcode 0 载入成功（非法行跳过并告警）
# @exitcode 2 没给路径
# @exitcode 3 文件不存在
# @stability stable
conf_load_dotenv() {
  local __file=${1:-} __line __lineno=0 __rc
  if ! validate_not_empty "$__file"; then
    log_error "$(_t 'configuration file path is required')"
    return "$SK_USAGE"
  fi
  if [ ! -f "$__file" ] || [ ! -r "$__file" ]; then
    log_error "$(_t 'Required file not found'): $__file"
    return "$SK_PRECOND"
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    __lineno=$((__lineno + 1))
    _sk_conf_assign "$__line" dotenv
    __rc=$?
    case "$__rc" in
      0) _sk_conf_layer_set "$_SK_CONF_PKEY" "$_SK_CONF_PVAL" ;;
      1) ;;
      2)
        log_warn "$(_t 'skipping invalid dotenv line'): $__file:$__lineno"
        ;;
    esac
  done <"$__file"
  return 0
}

# conf_source FILE —— 把 dotenv 文件的键导出为环境变量（供子进程继承）
# 与 conf_load_dotenv 的区别：这里明确要 export，所以只导环境变量，不进配置层。
# @exitcode 0 导出成功（键进环境变量）
# @exitcode 2 没给路径
# @exitcode 3 文件不存在
# @stability stable
conf_source() {
  local __file=${1:-} __line __lineno=0 __rc
  if ! validate_not_empty "$__file"; then
    log_error "$(_t 'configuration file path is required')"
    return "$SK_USAGE"
  fi
  if [ ! -f "$__file" ] || [ ! -r "$__file" ]; then
    log_error "$(_t 'Required file not found'): $__file"
    return "$SK_PRECOND"
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    __lineno=$((__lineno + 1))
    _sk_conf_assign "$__line" dotenv
    __rc=$?
    case "$__rc" in
      0)
        export "${_SK_CONF_PKEY}=${_SK_CONF_PVAL}"
        ;;
      1) ;;
      2)
        log_warn "$(_t 'skipping invalid dotenv line'): $__file:$__lineno"
        ;;
    esac
  done <"$__file"
  return 0
}

# conf_set KEY VALUE —— 校验 + 值未变则跳过 + 原子写 + 600
# @exitcode 0 写成功（值没变就不写盘）
# @exitcode 2 键名非法或值含换行
# @exitcode 3 还没 conf_init
# @exitcode 1 写文件失败
# @stability stable
conf_set() {
  local __key=${1:-} __value=${2:-} __file=${SK_CONF_FILE:-} __line __tmp __origin __replaced=0 __werr=0
  local __fmt=${SK_CONF_FORMAT:-auto}
  if ! validate_key "$__key"; then
    log_error "$(_t 'invalid configuration key'): $__key"
    return "$SK_USAGE"
  fi
  if ! validate_single_line "$__value"; then
    log_error "$(_t 'configuration value must be a single line'): $__key"
    return "$SK_USAGE"
  fi
  if [ -z "$__file" ]; then
    log_error "$(_t 'configuration file is not initialized')"
    return "$SK_PRECOND"
  fi
  # 守卫放在校验与前置条件之后：干跑也不该把「用法错」或「没初始化」吞成成功
  if _sk_fs_dry_run "conf-set" "$__key"; then
    return 0
  fi
  __origin=$(conf_get "$__key")
  if conf_has "$__key" && [ "$__value" = "$__origin" ]; then
    return 0
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if [ -f "$__file" ]; then
    # 找行用取值端同一套规则：export 前缀、引号、格式语义都认。
    # 只按 "KEY=" 开头去匹配，dotenv 文件里的 export KEY=... 会被漏掉 ——
    # 删不掉、也改不掉，下次读取又把旧值拿回来。
    while IFS= read -r __line || [ -n "$__line" ]; do
      if _sk_conf_assign "$__line" "$__fmt" && [ "$_SK_CONF_PKEY" = "$__key" ]; then
        if [ "$__replaced" -eq 0 ]; then
          _sk_conf_render_line "$__line" "$__key" "$__value" "$__fmt" || __werr=1
          __replaced=1
        fi
        continue
      fi
      printf '%s\n' "$__line" || __werr=1
    done <"$__file" >"$__tmp"
  fi
  if [ "$__replaced" -eq 0 ]; then
    _sk_conf_new_line "$__key" "$__value" "$__fmt" >>"$__tmp" || __werr=1
  fi
  # 写不完（磁盘满 / 配额超限）时 mv 会把半截临时文件换上去：调用方拿到 0，
  # 配置已经损坏。所以先判写失败 —— 失败就丢掉临时文件，原文件一个字节都不动。
  if [ "$__werr" -ne 0 ]; then
    rm -f "$__tmp"
    log_error "$(_t 'failed to write the file'): $__file"
    return 1
  fi
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  # 配置层里的同名键会盖住文件，写完要同步，否则读到的是旧值
  if _sk_conf_layer_has "$__key"; then
    _sk_conf_layer_set "$__key" "$__value"
  fi
  return 0
}

# conf_unset KEY —— 删掉一个键；幂等，键不存在也算成功
# @exitcode 0 删成功（或本来就没有这个键）
# @exitcode 2 键名非法
# @exitcode 1 写文件失败
# @stability stable
conf_unset() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line __tmp __werr=0
  local __fmt=${SK_CONF_FORMAT:-auto}
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  # 守卫放在校验之后：干跑也不该把「用法错」吞成成功
  if _sk_fs_dry_run "conf-unset" "$__key"; then
    return 0
  fi
  if ! conf_has "$__key"; then
    return 0
  fi
  if [ -z "$__file" ]; then
    _sk_conf_layer_del "$__key"
    return 0
  fi
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  # 与取值端同规则地认键：export KEY=... 也算这个键
  while IFS= read -r __line || [ -n "$__line" ]; do
    if _sk_conf_assign "$__line" "$__fmt" && [ "$_SK_CONF_PKEY" = "$__key" ]; then
      continue
    fi
    printf '%s\n' "$__line" || __werr=1
  done <"$__file" >"$__tmp"
  # 同 conf_set：半截临时文件不许改名成正式配置
  if [ "$__werr" -ne 0 ]; then
    rm -f "$__tmp"
    log_error "$(_t 'failed to write the file'): $__file"
    return 1
  fi
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  _sk_conf_layer_del "$__key"
  return 0
}

# conf_disable KEY —— 把 KEY=VALUE 改成注释行，保留原值
# @exitcode 0 注释掉成功（或本来就没有这个键）
# @exitcode 2 键名非法
# @exitcode 1 写文件失败
# @stability stable
conf_disable() {
  local __key=${1:-} __file=${SK_CONF_FILE:-} __line __tmp __werr=0
  local __fmt=${SK_CONF_FORMAT:-auto}
  if ! validate_key "$__key"; then
    return "$SK_USAGE"
  fi
  # 守卫放在校验之后：干跑也不该把「用法错」吞成成功
  if _sk_fs_dry_run "conf-disable" "$__key"; then
    return 0
  fi
  if ! conf_has "$__key"; then
    return 0
  fi
  if [ -z "$__file" ]; then
    _sk_conf_layer_del "$__key"
    return 0
  fi
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    if _sk_conf_assign "$__line" "$__fmt" && [ "$_SK_CONF_PKEY" = "$__key" ]; then
      printf '# %s\n' "$__line" || __werr=1
      continue
    fi
    printf '%s\n' "$__line" || __werr=1
  done <"$__file" >"$__tmp"
  # 同 conf_set：半截临时文件不许改名成正式配置
  if [ "$__werr" -ne 0 ]; then
    rm -f "$__tmp"
    log_error "$(_t 'failed to write the file'): $__file"
    return 1
  fi
  chmod 600 "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  _sk_conf_layer_del "$__key"
  return 0
}

# conf_keys —— 逐行输出键名（配置层的键在前，文件里的键在后，不重复）
# @exitcode 0 总是成功（stdout 逐行输出键名）
# @stability stable
conf_keys() {
  local __file=${SK_CONF_FILE:-} __line __i=0
  while [ "$__i" -lt "$SK_CONF_N" ]; do
    printf '%s\n' "${SK_CONF_KEYS[$__i]}"
    __i=$((__i + 1))
  done
  if [ -z "$__file" ] || [ ! -f "$__file" ]; then
    return 0
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    _sk_conf_assign "$__line" "${SK_CONF_FORMAT:-auto}"
    if [ "$?" -eq 0 ] && [ -n "$_SK_CONF_PKEY" ] && ! _sk_conf_layer_has "$_SK_CONF_PKEY"; then
      printf '%s\n' "$_SK_CONF_PKEY"
    fi
  done <"$__file"
  return 0
}
