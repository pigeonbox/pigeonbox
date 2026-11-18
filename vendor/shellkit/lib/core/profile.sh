#!/usr/bin/env bash
#
# profile 文件格式原语。
#
# 文件每行一条：`<模块名>` [key=value ...]   # 注释
# 解析结果用 TAB 分隔「模块名」与「逗号分隔的键值对」，方便 shell 逐行处理。
#
# 「导哪些模块、哪些键」「应用时怎么装」是领域逻辑，留给调用方；
# 这里只提供文件格式的读写与解析。

# profile_write FILE —— 创建/清空 profile 文件
# @exitcode 0 成功
# @exitcode 2 缺参数
# @exitcode 1 写不了
# @stability experimental
profile_write() {
  local __file="${1:-}"
  if [ -z "$__file" ]; then
    log_error "$(_t 'Usage'): profile_write FILE"
    return "$SK_USAGE"
  fi
  : >"$__file" || return 1
  return 0
}

# profile_append FILE MODULE [KEY=VALUE...] —— 追加一条
# @exitcode 0 成功
# @exitcode 2 缺参数
# @exitcode 1 写不了
# @stability experimental
profile_append() {
  local __file="${1:-}" __mod="${2:-}" __line
  if [ -z "$__file" ] || [ -z "$__mod" ]; then
    log_error "$(_t 'Usage'): profile_append FILE MODULE [KEY=VALUE...]"
    return "$SK_USAGE"
  fi
  shift 2
  __line="$__mod"
  if [ "$#" -gt 0 ]; then
    __line="$__line $*"
  fi
  printf '%s\n' "$__line" >>"$__file" || return 1
  return 0
}

# profile_parse FILE —— 解析 profile
# 输出：`<模块名>``<TAB>``<k=v,k=v>`（每行一个）
# 注释从**第一个 #** 起截断（与 unix_script 的 profile 解析同口径）。
# @exitcode 0 总是成功
# @stability experimental
profile_parse() {
  local __file="${1:-}" __line __content __mod __rest
  if [ -z "$__file" ] || [ ! -r "$__file" ]; then
    return 0
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    __content="${__line%%#*}"
    # 去掉首尾空白
    __content="${__content#"${__content%%[![:space:]]*}"}"
    __content="${__content%"${__content##*[![:space:]]}"}"
    [ -n "$__content" ] || continue
    __mod="${__content%%[[:space:]]*}"
    if [ "$__mod" = "$__content" ]; then
      __rest=''
    else
      __rest="${__content#"$__mod"}"
      # 去掉分隔用的空白
      __rest="${__rest#"${__rest%%[![:space:]]*}"}"
      __rest="${__rest%"${__rest##*[![:space:]]}"}"
      # 键值对之间用逗号分隔
      __rest="${__rest// /,}"
    fi
    printf '%s\t%s\n' "$__mod" "$__rest"
  done <"$__file"
  return 0
}

# profile_env MODULE_TAB_KV PREFIX —— 把键值对变成环境变量赋值（每行一个）
# @exitcode 0 总是成功
# @stability experimental
profile_env() {
  local __line="${1:-}" __prefix="${2:-}" __kv __item __k __v __tab
  # 分隔符：优先 TAB，没有就用空格（profile 文件本身是空格分隔的）
  __tab="$(printf '\t')"
  case "$__line" in
    *"$__tab"*) __kv="${__line#*"$__tab"}" ;;
    *)
      __kv="${__line#* }"
      [ "$__kv" = "$__line" ] && __kv=''
      ;;
  esac
  while IFS= read -r __item; do
    [ -n "$__item" ] || continue
    __k="${__item%%=*}"
    __v="${__item#*=}"
    [ "$__k" = "$__item" ] && continue
    printf '%s%s=%s\n' "$__prefix" "$__k" "$__v"
  done <<<"$(printf '%s' "$__kv" | tr ',' '\n')"
  return 0
}
