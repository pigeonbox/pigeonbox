#!/usr/bin/env bash
#
# HTTP 客户端：基于 curl 的通用请求 + JSON 解析。
#
# curl 经 run 执行（依赖 run 模块）：失败时打印的是脱敏后的命令行。
#
# 全库约定在这里同样成立：stdout 只给数据，日志一律 stderr；
# 出参用 printf -v 写全局变量，不去改调用方的局部变量。
#
# 退出码口径：
#   0  请求完成。HTTP 状态码不是错误：200 和 500 都返回 0，
#      业务自己看 SK_HTTP_CODE 决定怎么处理。
#   2  参数错（SK_USAGE）
#   3  缺前置条件（SK_PRECOND）：没有 curl，或者没有 jq/python3
#   4  网络层失败（SK_NET）：连不上、超时、DNS 解析失败
#   5  响应不是合法 JSON，或 JSON 路径取不到（SK_VERIFY）

# 最近一次 net_request 的结果；由 net_request 写入，调用方读取。
# shellcheck disable=SC2034
SK_HTTP_CODE=""
# shellcheck disable=SC2034
SK_HTTP_BODY=""
# shellcheck disable=SC2034
SK_HTTP_HEADERS=""

# 解析结果在 net_request 与 net_json 之间传递。
# 没有 nameref（基线是 bash 3.2），所以内部状态走下划线开头的全局变量。
_SK_HTTP_METHOD=""
_SK_HTTP_URL=""
_SK_HTTP_OUT=""
_SK_HTTP_PATH=""
_SK_HTTP_CURL_ARGS=()

# python3 侧的 JSON 取值脚本。
# 只用双引号字符串：这个脚本要塞进 bash 的单引号字符串里。
# 退出码：0 取到了，3 路径取不到，4 响应不是合法 JSON。
_SK_HTTP_PY_EXTRACT='
import json, sys

path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(4)

cur = doc
if path:
    for seg in path.split("."):
        if isinstance(cur, list):
            if not seg.isdigit():
                sys.exit(3)
            idx = int(seg)
            if idx >= len(cur):
                sys.exit(3)
            cur = cur[idx]
        elif isinstance(cur, dict):
            if seg not in cur:
                sys.exit(3)
            cur = cur[seg]
        else:
            sys.exit(3)

if cur is None:
    sys.exit(3)
if isinstance(cur, bool):
    sys.stdout.write("true" if cur else "false")
elif isinstance(cur, str):
    sys.stdout.write(cur)
elif isinstance(cur, (int, float)):
    sys.stdout.write(json.dumps(cur))
else:
    sys.stdout.write(json.dumps(cur, indent=2, ensure_ascii=False))
'

# python3 侧的资产匹配脚本：按正则挑第一个匹配的 browser_download_url。
# 退出码：0 找到并输出 URL；3 没有匹配（或正则非法）；4 响应不是合法 JSON。
_SK_HTTP_PY_ASSETS='
import json, re, sys

pat = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(4)
try:
    rx = re.compile(pat)
except Exception:
    sys.exit(3)
if isinstance(doc, dict):
    for a in (doc.get("assets") or []):
        if not isinstance(a, dict):
            continue
        url = a.get("browser_download_url")
        if isinstance(url, str) and rx.search(url):
            sys.stdout.write(url)
            sys.exit(0)
sys.exit(3)
'

# python3 侧的 JSON 合法性校验脚本；非 0 表示不是合法 JSON。
_SK_HTTP_PY_VALIDATE='
import json, sys

try:
    json.load(sys.stdin)
except Exception:
    sys.exit(4)
'

# _sk_http_json_tool —— 打印可用的 JSON 解析器（jq 优先，其次 python3）；都没有返回 1
_sk_http_json_tool() {
  if command -v jq >/dev/null 2>&1; then
    printf 'jq'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
    return 0
  fi
  return 1
}

# _sk_http_jq_filter PATH —— 把点号路径翻译成 jq 过滤器（data.items.0.name -> .data.items[0].name）
_sk_http_jq_filter() {
  local __path=${1:-} __seg __out="" __esc
  local -a __segs=()
  IFS='.' read -r -a __segs <<<"${__path}"
  for __seg in ${__segs[@]+"${__segs[@]}"}; do
    case "$__seg" in
      '') continue ;;
      *[!0-9]*)
        case "$__seg" in
          *[!A-Za-z0-9_-]*)
            __esc=$(printf '%s' "$__seg" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
            __out="${__out}[\"${__esc}\"]"
            ;;
          *) __out="${__out}.${__seg}" ;;
        esac
        ;;
      *) __out="${__out}[${__seg}]" ;;
    esac
  done
  if [ -z "$__out" ]; then
    printf '.'
    return 0
  fi
  printf '%s' "$__out"
  return 0
}

# _sk_http_parse METHOD URL [OPTIONS...] —— 解析参数，结果写进 _SK_HTTP_* 全局。
# 抽出来是因为 net_request 与 net_json 的选项集合几乎一样，复制两遍迟早走偏。
_sk_http_parse() {
  local __method=${1:-} __url=${2:-} __opt __val __lower
  local __has_data=0 __has_json=0 __has_ct=0
  local __data="" __json="" __out="" __path=""
  local __timeout=30 __ctimeout=10
  local -a __hdrs=()

  if [ -z "$__url" ]; then
    log_error "$(_t 'URL is required')"
    return "$SK_USAGE"
  fi
  case "$__method" in
    '' | *[!A-Za-z]*)
      log_error "$(_t 'invalid HTTP method'): $__method"
      return "$SK_USAGE"
      ;;
  esac

  shift 2
  while [ $# -gt 0 ]; do
    __opt=$1
    shift
    case "$__opt" in
      --header)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --header"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __hdrs[${#__hdrs[@]}]="$__val"
        ;;
      --header=*)
        __hdrs[${#__hdrs[@]}]="${__opt#--header=}"
        ;;
      --data)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --data"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __data="$__val"
        __has_data=1
        ;;
      --data=*)
        __data="${__opt#--data=}"
        __has_data=1
        ;;
      --json)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --json"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __json="$__val"
        __has_json=1
        ;;
      --json=*)
        __json="${__opt#--json=}"
        __has_json=1
        ;;
      --timeout)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --timeout"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __timeout="$__val"
        ;;
      --timeout=*)
        __timeout="${__opt#--timeout=}"
        ;;
      --connect-timeout)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --connect-timeout"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __ctimeout="$__val"
        ;;
      --connect-timeout=*)
        __ctimeout="${__opt#--connect-timeout=}"
        ;;
      --output)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --output"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __out="$__val"
        ;;
      --output=*)
        __out="${__opt#--output=}"
        ;;
      --path)
        if [ $# -lt 1 ]; then
          log_error "$(_t 'missing value for option'): --path"
          return "$SK_USAGE"
        fi
        __val=$1
        shift
        __path="$__val"
        ;;
      --path=*)
        __path="${__opt#--path=}"
        ;;
      *)
        log_error "$(_t 'unknown option'): $__opt"
        return "$SK_USAGE"
        ;;
    esac
  done

  if [ "$__has_data" -eq 1 ] && [ "$__has_json" -eq 1 ]; then
    log_error "$(_t 'cannot use both --data and --json')"
    return "$SK_USAGE"
  fi

  case "$__timeout" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid timeout value'): $__timeout"
      return "$SK_USAGE"
      ;;
  esac
  case "$__ctimeout" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid timeout value'): $__ctimeout"
      return "$SK_USAGE"
      ;;
  esac

  _SK_HTTP_METHOD=$(printf '%s' "$__method" | tr '[:lower:]' '[:upper:]')
  _SK_HTTP_URL="$__url"
  _SK_HTTP_OUT="$__out"
  _SK_HTTP_PATH="$__path"

  _SK_HTTP_CURL_ARGS=()
  _SK_HTTP_CURL_ARGS[0]="-X"
  _SK_HTTP_CURL_ARGS[1]="$_SK_HTTP_METHOD"
  for __val in ${__hdrs[@]+"${__hdrs[@]}"}; do
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="-H"
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="$__val"
    __lower=$(printf '%s' "$__val" | tr '[:upper:]' '[:lower:]')
    case "$__lower" in
      content-type:*) __has_ct=1 ;;
    esac
  done
  if [ "$__has_json" -eq 1 ]; then
    if [ "$__has_ct" -eq 0 ]; then
      _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="-H"
      _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="Content-Type: application/json"
    fi
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="--data"
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="$__json"
  elif [ "$__has_data" -eq 1 ]; then
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="--data"
    _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="$__data"
  fi
  _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="--connect-timeout"
  _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="$__ctimeout"
  _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="--max-time"
  _SK_HTTP_CURL_ARGS[${#_SK_HTTP_CURL_ARGS[@]}]="$__timeout"
  return 0
}

# _sk_http_exec —— 真发一次请求，结果写进 SK_HTTP_CODE / SK_HTTP_BODY / SK_HTTP_HEADERS。
# 响应体与响应头先落临时文件再取，避免把二进制/多行内容塞进变量时踩坑。
_sk_http_exec() {
  local __body_file __head_file __code="" __rc __body="" __head=""
  if ! command -v curl >/dev/null 2>&1; then
    log_error "$(_t 'curl is required for HTTP requests')"
    return "$SK_PRECOND"
  fi
  # 先清空出参：请求失败时不该让调用方读到上一次的残留
  printf -v SK_HTTP_CODE '%s' ""
  printf -v SK_HTTP_BODY '%s' ""
  printf -v SK_HTTP_HEADERS '%s' ""

  __body_file=$(mktemp "${TMPDIR:-/tmp}/shellkit-http-body.XXXXXX") || return "$SK_ERR"
  __head_file=$(mktemp "${TMPDIR:-/tmp}/shellkit-http-head.XXXXXX") || {
    rm -f "$__body_file"
    return "$SK_ERR"
  }

  # 经 run 执行，不直接调 curl（SECURITY.md 偏差 7）：
  #   --always  不让 SHELLKIT_DRY_RUN 把请求「跳过」—— 那会让调用方读到空状态码；
  #   --no-die  成败在下面自己判，run 只负责执行与**脱敏后的**命令行。
  # 差别只在失败那一刻：多一行形如「command failed: curl … Authorization: ***」的
  # 日志，请求头里的令牌被 run 的脱敏挡住，而不是整条命令行要么不打印、要么原文照打。
  __code=$(run --always --no-die -- curl -sS ${_SK_HTTP_CURL_ARGS[@]+"${_SK_HTTP_CURL_ARGS[@]}"} -D "$__head_file" -o "$__body_file" -w '%{http_code}' "$_SK_HTTP_URL")
  __rc=$?

  if [ "$__rc" -ne 0 ]; then
    rm -f "$__body_file" "$__head_file"
    case "$__rc" in
      2 | 3)
        log_error "$(_t 'invalid URL'): $_SK_HTTP_URL"
        return "$SK_USAGE"
        ;;
      *)
        log_error "$(_t 'HTTP request failed'): $_SK_HTTP_METHOD $_SK_HTTP_URL"
        log_debug "curl exit=$__rc"
        return "$SK_NET"
        ;;
    esac
  fi

  __head=$(cat "$__head_file")
  if [ -n "$_SK_HTTP_OUT" ]; then
    if ! mv -f "$__body_file" "$_SK_HTTP_OUT"; then
      rm -f "$__body_file" "$__head_file"
      log_error "$(_t 'cannot write response body to file'): $_SK_HTTP_OUT"
      return "$SK_ERR"
    fi
  else
    __body=$(cat "$__body_file")
  fi
  rm -f "$__body_file" "$__head_file"

  printf -v SK_HTTP_CODE '%s' "$__code"
  printf -v SK_HTTP_BODY '%s' "$__body"
  printf -v SK_HTTP_HEADERS '%s' "$__head"
  return 0
}

# _sk_http_json_extract BODY PATH —— 从 JSON 文本里取点号路径的值，打印到 stdout。
# 取不到路径返回 SK_VERIFY(5)。
_sk_http_json_extract() {
  local __body=${1:-} __path=${2:-} __tool __filter __out="" __rc
  __tool=$(_sk_http_json_tool) || {
    log_error "$(_t 'jq or python3 is required to parse JSON')"
    return "$SK_PRECOND"
  }
  if [ "$__tool" = "jq" ]; then
    __filter=$(_sk_http_jq_filter "$__path")
    __out=$(printf '%s' "$__body" | jq -r "$__filter" 2>/dev/null)
    __rc=$?
    if [ "$__rc" -ne 0 ]; then
      log_error "$(_t 'invalid JSON response')"
      return "$SK_VERIFY"
    fi
    # jq 取不到路径时输出 null；值本身就是 null 也按取不到处理
    if [ "$__out" = "null" ]; then
      log_error "$(_t 'JSON path not found'): $__path"
      return "$SK_VERIFY"
    fi
  else
    __out=$(printf '%s' "$__body" | python3 -c "$_SK_HTTP_PY_EXTRACT" "$__path" 2>/dev/null)
    __rc=$?
    case "$__rc" in
      0) : ;;
      3)
        log_error "$(_t 'JSON path not found'): $__path"
        return "$SK_VERIFY"
        ;;
      *)
        log_error "$(_t 'invalid JSON response')"
        return "$SK_VERIFY"
        ;;
    esac
  fi
  printf '%s\n' "$__out"
  return 0
}

# _sk_http_json_validate BODY —— 确认响应体是合法 JSON；不是就返回 SK_VERIFY(5)
_sk_http_json_validate() {
  local __body=${1:-} __tool __rc
  __tool=$(_sk_http_json_tool) || {
    log_error "$(_t 'jq or python3 is required to parse JSON')"
    return "$SK_PRECOND"
  }
  if [ "$__tool" = "jq" ]; then
    printf '%s' "$__body" | jq . >/dev/null 2>&1
  else
    printf '%s' "$__body" | python3 -c "$_SK_HTTP_PY_VALIDATE" >/dev/null 2>&1
  fi
  __rc=$?
  if [ "$__rc" -ne 0 ]; then
    log_error "$(_t 'invalid JSON response')"
    return "$SK_VERIFY"
  fi
  return 0
}

# net_request METHOD URL [--header 'K: V']... [--data STR] [--json STR] [--timeout SEC] [--connect-timeout SEC] [--output FILE] —— 发一个 HTTP 请求。
# @brief METHOD 不区分大小写；请求完成返回 0，状态码不算错误。
# @param METHOD HTTP 方法（GET/POST/...）
# @param URL 目标地址
# @param --header 'K: V' 请求头，可重复
# @param --data STR 请求体
# @param --json STR 请求体；自动补 Content-Type: application/json
# @param --timeout SEC 总超时，默认 30
# @param --connect-timeout SEC 连接超时，默认 10
# @param --output FILE 响应体写文件而不是放进 SK_HTTP_BODY
# @exitcode 0 请求完成（状态码看 SK_HTTP_CODE）
# @exitcode 2 参数错
# @exitcode 3 没有 curl
# @exitcode 4 网络层失败（连不上、超时、DNS 失败）
# @see net_json
# @stability experimental
net_request() {
  _sk_need_args "$#" 2 "net_request METHOD URL [--header 'K: V'] [--data STR] [--json STR] [--timeout SEC] [--connect-timeout SEC] [--output FILE]" || return $?
  _sk_http_parse "$@" || return $?
  if [ -n "$_SK_HTTP_PATH" ]; then
    log_error "$(_t 'unknown option'): --path"
    return "$SK_USAGE"
  fi
  _sk_http_exec || return $?
  return 0
}

# net_json METHOD URL [--header 'K: V']... [--data STR] [--json STR] [--path KEY] —— 发请求并把响应体当 JSON 解析，结果打印到 stdout。
# @brief 有 jq 用 jq，有 python3 用 python3，都没有返回 SK_PRECOND(3)。
# @param --path KEY 点号路径（data.items.0.name）；不给就输出整个 JSON 文本
# @exitcode 0 取到了值
# @exitcode 2 参数错
# @exitcode 3 没有 jq 也没有 python3
# @exitcode 4 网络层失败
# @exitcode 5 响应不是合法 JSON，或路径取不到
# @see net_request
# @stability experimental
net_json() {
  _sk_need_args "$#" 2 "net_json METHOD URL [--header 'K: V'] [--data STR] [--json STR] [--path KEY]" || return $?
  # 先查解析器：连解析器都没有，就不该把请求发出去
  if ! _sk_http_json_tool >/dev/null; then
    log_error "$(_t 'jq or python3 is required to parse JSON')"
    return "$SK_PRECOND"
  fi
  _sk_http_parse "$@" || return $?
  if [ -n "$_SK_HTTP_OUT" ]; then
    log_error "$(_t 'unknown option'): --output"
    return "$SK_USAGE"
  fi
  _sk_http_exec || return $?
  if [ -n "$_SK_HTTP_PATH" ]; then
    _sk_http_json_extract "$SK_HTTP_BODY" "$_SK_HTTP_PATH" || return $?
  else
    _sk_http_json_validate "$SK_HTTP_BODY" || return $?
    printf '%s\n' "$SK_HTTP_BODY"
  fi
  return 0
}

# net_escape_json TEXT —— 把任意文本转义成合法的 JSON 字符串字面量（含双引号），打印到 stdout。
# @brief 优先 jq，其次 python3；都没有时走内置降级路径。
# @param TEXT 原始文本
# @exitcode 0 转义成功
# @see net_json
# @stability experimental
net_escape_json() {
  local __text=${1:-} __out="" __rc
  if command -v jq >/dev/null 2>&1; then
    __out=$(printf '%s' "$__text" | jq -Rn --arg s "$__text" '$s' 2>/dev/null)
    __rc=$?
    if [ "$__rc" -eq 0 ] && [ -n "$__out" ]; then
      printf '%s\n' "$__out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    __out=$(printf '%s' "$__text" | python3 -c 'import json, sys
sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null)
    __rc=$?
    if [ "$__rc" -eq 0 ] && [ -n "$__out" ]; then
      printf '%s\n' "$__out"
      return 0
    fi
  fi
  # 降级路径：没有 jq 也没有 python3 时，只转义反斜杠、双引号与控制字符。
  # 换句话说输出对 JSON 是合法的（非 ASCII 字符按 UTF-8 原样保留），
  # 但不保证与 jq/python3 的转义结果逐字相同。
  _sk_http_escape_fallback "$__text"
  return 0
}

# _sk_http_escape_fallback TEXT —— 没有 jq/python3 时的保守转义实现
_sk_http_escape_fallback() {
  local __in=${1:-} __out="" __i=0 __len=${#1} __c __code
  while [ "$__i" -lt "$__len" ]; do
    __c=${__in:$__i:1}
    case "$__c" in
      '\') __out="${__out}\\\\" ;;
      '"') __out="${__out}\\\"" ;;
      $'\n') __out="${__out}\\n" ;;
      $'\t') __out="${__out}\\t" ;;
      $'\r') __out="${__out}\\r" ;;
      *)
        printf -v __code '%d' "'$__c"
        if [ "$__code" -ge 0 ] && [ "$__code" -lt 32 ]; then
          printf -v __out '%s\\u%04x' "$__out" "$__code"
        else
          __out="${__out}${__c}"
        fi
        ;;
    esac
    __i=$((__i + 1))
  done
  printf '"%s"\n' "$__out"
  return 0
}

# ---------------------------------------------------------------------------
# GitHub release 查询
#
# 为什么不直接用 net_json：release 的资产列表要按正则挑（jq 的 test / grep -E），
# 而 net_json 只能按点号路径取值 —— 在数组里挑元素它做不到。
# 所以这里用 net_request 取原文，再在本地解析。
# ---------------------------------------------------------------------------

# _sk_http_github_body REPO —— 取最新 release 的 JSON 原文；失败返回非 0
_sk_http_github_body() {
  local __repo=${1:-} __token
  local -a __hdrs=()
  __token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  if [ -n "$__token" ]; then
    __hdrs[${#__hdrs[@]}]="--header"
    __hdrs[${#__hdrs[@]}]="Authorization: Bearer $__token"
  fi
  net_request GET "https://api.github.com/repos/${__repo}/releases/latest" \
    ${__hdrs[@]+"${__hdrs[@]}"} --timeout 30 --connect-timeout 10 || return $?
  case "$SK_HTTP_CODE" in
    200) ;;
    *)
      log_debug "GitHub release query failed: HTTP $SK_HTTP_CODE"
      return "$SK_NET"
      ;;
  esac
  printf '%s' "$SK_HTTP_BODY"
  return 0
}

# _sk_http_github_tag BODY —— 从 release JSON 里取 tag_name；取不到返回 1
_sk_http_github_tag() {
  local __body=${1:-} __out=""
  if command -v jq >/dev/null 2>&1; then
    __out=$(printf '%s' "$__body" | jq -r '.tag_name // empty' 2>/dev/null) || __out=""
  elif command -v python3 >/dev/null 2>&1; then
    __out=$(printf '%s' "$__body" | python3 -c "$_SK_HTTP_PY_EXTRACT" tag_name 2>/dev/null) || __out=""
  else
    # 没有解析器时的降级路径：直接在文本里扫字段。
    # 不能用 head —— 命中即退会把上游 SIGPIPE 打死（141）。
    __out=$(printf '%s\n' "$__body" | grep '"tag_name"' | sed -n '1p' |
      sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/') || __out=""
  fi
  [ -n "$__out" ] || return 1
  printf '%s' "$__out"
  return 0
}

# _sk_http_github_asset BODY PATTERN —— 第一个匹配的资产下载地址；没有匹配返回 1
_sk_http_github_asset() {
  local __body=${1:-} __pat=${2:-} __out=""
  if command -v jq >/dev/null 2>&1; then
    __out=$(printf '%s' "$__body" | jq -r --arg p "$__pat" \
      '.assets[]?.browser_download_url | select(test($p))' 2>/dev/null) || __out=""
  elif command -v python3 >/dev/null 2>&1; then
    __out=$(printf '%s' "$__body" | python3 -c "$_SK_HTTP_PY_ASSETS" "$__pat" 2>/dev/null) || __out=""
  else
    # 没有 jq 也没有 python3 时的兜底。GitHub 返回的 JSON 是**一行**、装着好几个
    # 资产，直接 grep|sed 会踩两个坑：贪婪的 .* 抓到的是**最后一个** URL
    # （要 x86_64 却给 arm64），而且匹配到的可能是别的字段。
    # 所以先按逗号拆成一条条资产，再逐条取 URL，最后只留第一条匹配的。
    __out=$(printf '%s' "$__body" | tr ',' '\n' |
      grep -E -- "$__pat" |
      sed -n -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' |
      sed -n '1p') || __out=""
  fi
  [ -n "$__out" ] || return 1
  printf '%s' "$__out" | sed -n '1p'
  return 0
}

# http_github_latest_tag REPO —— 最新 release 的 tag（去掉 v/V 前缀）
# @brief 查询失败时输出空串并返回 0 —— 调用方把它当「没有新版本」处理。
# @param REPO 形如 owner/repo
# @exitcode 0 完成（stdout 输出 tag；查不到时为空串）
# @exitcode 2 缺参数
# @stability experimental
http_github_latest_tag() {
  local __repo=${1:-} __body __tag
  if [ -z "$__repo" ]; then
    log_error "$(_t 'Usage'): http_github_latest_tag REPO"
    return "$SK_USAGE"
  fi
  __body=$(_sk_http_github_body "$__repo") || return 0
  __tag=$(_sk_http_github_tag "$__body") || return 0
  __tag=${__tag#v}
  __tag=${__tag#V}
  printf '%s' "$__tag"
  return 0
}

# http_github_release_asset REPO PATTERN —— 匹配资产的下载地址
# @brief PATTERN 是正则（匹配 browser_download_url）；没有匹配时输出空串并返回 0。
# @param REPO 形如 owner/repo
# @param PATTERN 匹配 browser_download_url 的正则
# @exitcode 0 完成（stdout 输出 URL；没有匹配时为空串）
# @exitcode 2 缺参数
# @stability experimental
http_github_release_asset() {
  local __repo=${1:-} __pat=${2:-} __body __url
  if [ -z "$__repo" ] || [ -z "$__pat" ]; then
    log_error "$(_t 'Usage'): http_github_release_asset REPO PATTERN"
    return "$SK_USAGE"
  fi
  __body=$(_sk_http_github_body "$__repo") || return 0
  __url=$(_sk_http_github_asset "$__body" "$__pat") || return 0
  printf '%s' "$__url"
  return 0
}
