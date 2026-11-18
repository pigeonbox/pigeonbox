#!/usr/bin/env bash
#
# 脚手架：模板变量、渲染、生成物清单、钩子。
#
# 这一层为什么存在：shellkit new 以前只能一次性把模板铺出来，交付之后就没有
# 办法跟着 shellkit 一起演进 —— 想升级只能删了重来，或者手工 diff。
# 有了清单（.shellkit-manifest）就能做增量更新：模板改了什么，
# 只更新没被你改过的文件；你改过的文件留着并告警。
#
# 模板变量：模板文件里写 {{KEY}}，值来自 template.config 的默认值、
# 命令行 --set KEY=VALUE、或交互提问。未声明的 {{KEY}} 原样保留。

# 模板变量表。格式是 KEY=VALUE 的多行文本；跨函数传状态用公开变量。
SK_SCAFFOLD_VARS=""

# manifest 解析出来的标量（公开变量，scaffold_manifest_read 之后可读）
SK_MANIFEST_VERSION=""
SK_MANIFEST_TEMPLATE_VERSION=""
SK_MANIFEST_NAME=""
SK_MANIFEST_COMMANDS=""
# 清单格式版本。2 = 基线可信（记的是模板基线）；1 或空 = 旧清单，
# 基线可能是「用户改过之后的内容」，升级时必须另作判断。
SK_MANIFEST_FORMAT=""

# _sk_scaffold_store_set KEY VALUE —— 在变量表里写一个键
_sk_scaffold_store_set() {
  local __key=$1 __value=$2 __out="" __line __rest="$SK_SCAFFOLD_VARS" __found=0
  # 值里不能有换行：变量装在一个「换行分隔」的容器里（SK_SCAFFOLD_VARS），
  # 值里的换行会被当成容器自己的分隔符 —— 值的后半截变成一行垃圾，
  # 渲染时整段被丢掉，**静默截断**。所以这里直接拒绝，不让它走到那一步。
  case "$__value" in
    *$'\n'*)
      log_error "$(_t 'the template variable value must not contain a newline'): $__key"
      return "$SK_USAGE"
      ;;
  esac
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    case "$__line" in
      "") continue ;;
      "${__key}="*)
        printf -v __out '%s%s=%s\n' "$__out" "$__key" "$__value"
        __found=1
        ;;
      *) printf -v __out '%s%s\n' "$__out" "$__line" ;;
    esac
  done
  if [ "$__found" -eq 0 ]; then
    printf -v __out '%s%s=%s\n' "$__out" "$__key" "$__value"
  fi
  SK_SCAFFOLD_VARS="$__out"
}

# _sk_scaffold_store_get KEY DEFAULT —— 读变量表里的一个键
_sk_scaffold_store_get() {
  local __key=$1 __default=$2 __line __rest="$SK_SCAFFOLD_VARS" __found=0
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    case "$__line" in
      "${__key}="*)
        printf '%s\n' "${__line#*=}"
        __found=1
        break
        ;;
    esac
  done
  if [ "$__found" -eq 0 ]; then
    printf '%s\n' "$__default"
  fi
  return 0
}

# scaffold_vars_set KEY VALUE —— 设一个模板变量
# @exitcode 0 设置成功
# @exitcode 2 变量名非法，或值里有换行（变量表一行一个，装不下多行值）
# @stability experimental
scaffold_vars_set() {
  local __key=${1:-} __value=${2:-}
  if ! validate_key "$__key"; then
    log_error "$(_t 'invalid template variable name'): $__key"
    return "$SK_USAGE"
  fi
  # 存储失败要往上带：写死 return 0 会把「值不合法」这类错误吃掉，
  # 调用方以为设好了，实际值根本没进去。
  _sk_scaffold_store_set "$__key" "$__value" || return $?
  return 0
}

# scaffold_vars_get KEY [DEFAULT] —— 读一个模板变量；未设置时给默认值
# @exitcode 0 找到（stdout 输出值）
# @exitcode 1 没有这个变量
# @stability experimental
scaffold_vars_get() {
  local __key=${1:-} __default=${2:-}
  if ! validate_key "$__key"; then
    printf '%s\n' "$__default"
    return "$SK_USAGE"
  fi
  _sk_scaffold_store_get "$__key" "$__default"
}

# scaffold_vars_list —— 逐行输出 KEY=VALUE
# @exitcode 0 总是成功（stdout 逐行输出变量名）
# @stability experimental
scaffold_vars_list() {
  local __line __rest="$SK_SCAFFOLD_VARS"
  while [ -n "$__rest" ]; do
    __line=${__rest%%$'\n'*}
    if [ "$__line" = "$__rest" ]; then
      __rest=""
    else
      __rest=${__rest#*$'\n'}
    fi
    [ -n "$__line" ] && printf '%s\n' "$__line"
  done
  return 0
}

# scaffold_config_load FILE —— 从 template.config 载入模板变量
#
# 格式与 conf 模块一致：KEY=VALUE，# 开头是注释。
# 值为空是合法的（表示「这个变量默认没有值，生成时问用户」）。
# @exitcode 0 载入成功
# @exitcode 2 参数错
# @exitcode 3 找不到配置文件
# @stability experimental
scaffold_config_load() {
  local __file=${1:-} __line __key __value
  _sk_need_args "$#" 1 "scaffold_config_load FILE" || return $?
  if [ ! -f "$__file" ]; then
    log_error "$(_t 'template config not found'): $__file"
    return "$SK_PRECOND"
  fi
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '' | '#'*) continue ;;
    esac
    case "$__line" in
      *=*) ;;
      *)
        log_warn "$(_t 'skipped a malformed template variable'): $__line"
        continue
        ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    if ! validate_key "$__key"; then
      log_warn "$(_t 'skipped an invalid template variable name'): $__key"
      continue
    fi
    _sk_scaffold_store_set "$__key" "$__value"
  done <"$__file"
  return 0
}

# _sk_sed_repl_escape VAR TEXT —— 把转义后的文本写进变量 VAR
#
# 顺序要紧：先转义反斜杠，再转义 & 与分隔符 |。
#
# 出参形式（printf -v）而不是 "$(...)"：渲染每个模板文件都要对每个变量调一次，
# 一次命令替换就是一次 fork（本机 ~80ms）—— 8 个文件 × 6 个变量就是 48 次 fork，
# 光这一项就把 shellkit new 拖到 6~8 秒。
_sk_sed_repl_escape() {
  local __var=${1:-} __s=${2:-}
  _sk_need_args "$#" 2 "_sk_sed_repl_escape VAR TEXT" || return $?
  if ! _sk_is_name "$__var"; then
    log_error "$(_t 'invalid variable name'): $__var"
    return "$SK_USAGE"
  fi
  _sk_check_out_name "$__var" || return $?
  __s=${__s//\\/\\\\}
  __s=${__s//&/\\&}
  __s=${__s//|/\\|}
  printf -v "$__var" '%s' "$__s"
  return 0
}

# scaffold_render SRC DST —— 用当前模板变量渲染文件
#
# 未声明的 {{KEY}} 原样保留（这样模板里的示例占位符不会被误伤）。
# 返回非 0 表示没写出来，调用方必须判。
# @exitcode 0 渲染成功（stdout 输出渲染后的文本）
# @exitcode 2 参数错
# @exitcode 1 渲染失败
# @stability experimental
scaffold_render() {
  local __src=${1:-} __dst=${2:-} __rc=0 __line __key __value __esc
  local __args=()
  _sk_need_args "$#" 2 "scaffold_render SRC DST" || return $?
  if [ ! -f "$__src" ]; then
    log_error "$(_t 'template is missing'): $__src"
    return 1
  fi
  # 替换规则直接交给 sed 的 -e，不再落临时脚本文件 ——
  # 落文件要 mktemp 再 rm，渲染每个文件就多两次 fork。
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      *=*) ;;
      *) continue ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    _sk_sed_repl_escape __esc "$__value" || __rc=1
    [ "$__rc" -eq 0 ] || continue
    __args[${#__args[@]}]="-e"
    __args[${#__args[@]}]="s|{{$__key}}|$__esc|g"
  done <<EOF
$SK_SCAFFOLD_VARS
EOF
  if [ "$__rc" -ne 0 ]; then
    return 1
  fi
  if ! sed ${__args[@]+"${__args[@]}"} "$__src" >"$__dst"; then
    return 1
  fi
  return 0
}

# scaffold_manifest_write DIR NAME COMDS TEMPLATE_VERSION [FILELIST]
#
# 写 DIR/.shellkit-manifest。FILELIST 是换行分隔的相对路径（模板自有的文件），
# 每个文件记一个 sha256 —— 升级时靠它判断「这个文件用户动过没有」。
#
# 记的是**基线**：上次成功应用的模板内容的指纹。生成工程时文件刚由模板渲染出来，
# 当前内容 == 模板内容，两者一样，所以这里直接取当前文件的 sha256。
# 升级时的基线由 scaffold_manifest_write_baselines 推进 ——
# 跳过的文件基线不动，否则下一次升级就会把用户的修改当成「没动过」而覆盖掉。
# @exitcode 0 清单写好
# @exitcode 2 参数错
# @exitcode 1 写文件失败
# @stability experimental
scaffold_manifest_write() {
  local __dir=${1:-} __name=${2:-} __cmds=${3:-} __tver=${4:-} __files=${5:-}
  _sk_need_args "$#" 4 "scaffold_manifest_write DIR NAME COMDS TEMPLATE_VERSION [FILELIST]" || return $?
  _sk_scaffold_manifest_emit "$__dir" "$__name" "$__cmds" "$__tver" "$__files" "" "current"
}

# scaffold_manifest_write_baselines DIR NAME COMDS TEMPLATE_VERSION FILELIST BASELINES
#
# 与 scaffold_manifest_write 写同一个格式的清单，但基线由调用方给：
# BASELINES 是换行分隔的「相对路径=指纹」，指纹可以为空（表示没有指纹）。
# BASELINES 里没提到的文件，基线记为空。
#
# 为什么要有这个入口：升级时「用户改过、被跳过的文件」不能把基线推进到用户
# 的内容上 —— 推进了下一次升级就会覆盖掉用户的修改。只有真正成功应用了
# 模板的文件才能推进基线。
# @exitcode 0 清单写好
# @exitcode 2 参数错
# @exitcode 1 写文件失败
# @stability experimental
scaffold_manifest_write_baselines() {
  local __dir=${1:-} __name=${2:-} __cmds=${3:-} __tver=${4:-} __files=${5:-} __baselines=${6:-}
  _sk_need_args "$#" 6 "scaffold_manifest_write_baselines DIR NAME COMDS TEMPLATE_VERSION FILELIST BASELINES" || return $?
  _sk_scaffold_manifest_emit "$__dir" "$__name" "$__cmds" "$__tver" "$__files" "$__baselines" "given"
}

# _sk_scaffold_manifest_emit DIR NAME CMDS TVER FILES BASELINES MODE
#
# 清单落盘的实际实现。MODE = current 时基线取文件当前内容的 sha256；
# MODE = given 时基线从 BASELINES（换行分隔的「路径=指纹」）里取。
# @exitcode 0 清单写好
# @exitcode 1 写文件失败
_sk_scaffold_manifest_emit() {
  local __dir=$1 __name=$2 __cmds=$3 __tver=$4 __files=$5 __baselines=$6 __mode=$7
  local __out="$__dir/.shellkit-manifest" __tmp __line __rel __sum __bl __blrel __blsum
  fs_ensure_dir "$__dir" 755 || return 1
  __tmp=$(mktemp "$__out.tmp.XXXXXX") || return 1
  {
    printf '# shellkit manifest v1\n'
    printf '# 生成时的模板版本与文件指纹。shellkit upgrade 用它判断哪些文件能安全覆盖。\n'
    printf 'manifest_version=2\n'
    printf 'version=%s\n' "${SK_VERSION:-dev}"
    printf 'template_version=%s\n' "$__tver"
    printf 'name=%s\n' "$__name"
    printf 'commands=%s\n' "$__cmds"
    while IFS= read -r __line || [ -n "$__line" ]; do
      [ -n "$__line" ] || continue
      printf '@var %s\n' "$__line"
    done <<EOF
$SK_SCAFFOLD_VARS
EOF
    while IFS= read -r __rel || [ -n "$__rel" ]; do
      [ -n "$__rel" ] || continue
      __sum=""
      if [ "$__mode" = "given" ]; then
        while IFS= read -r __bl || [ -n "$__bl" ]; do
          [ -n "$__bl" ] || continue
          case "$__bl" in
            *=*)
              __blrel=${__bl%%=*}
              __blsum=${__bl#*=}
              ;;
            *) continue ;;
          esac
          if [ "$__blrel" = "$__rel" ]; then
            __sum=$__blsum
            break
          fi
        done <<<"$__baselines"
      elif [ -f "$__dir/$__rel" ]; then
        __sum=$(os_sha256 "$__dir/$__rel" 2>/dev/null) || __sum=""
      fi
      printf '@file %s %s\n' "$__rel" "$__sum"
    done <<<"$__files"
  } >"$__tmp" || {
    rm -f "$__tmp"
    return 1
  }
  if ! mv -f "$__tmp" "$__out"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# scaffold_manifest_read DIR —— 读 DIR/.shellkit-manifest
#
# 标量进 SK_MANIFEST_* 公开变量，@var 条目进模板变量表。
# @exitcode 0 清单读到了
# @exitcode 3 这里不是 shellkit 生成的工程
# @stability experimental
scaffold_manifest_read() {
  local __dir=${1:-} __file __line __rest
  _sk_need_args "$#" 1 "scaffold_manifest_read DIR" || return $?
  __file="$__dir/.shellkit-manifest"
  if [ ! -f "$__file" ]; then
    log_error "$(_t 'no shellkit manifest in'): $__dir"
    return "$SK_PRECOND"
  fi
  SK_MANIFEST_VERSION=""
  SK_MANIFEST_TEMPLATE_VERSION=""
  SK_MANIFEST_NAME=""
  SK_MANIFEST_COMMANDS=""
  SK_MANIFEST_FORMAT=""
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '') continue ;;
      '#'*) continue ;;
      '@var '*)
        __rest=${__line#@var }
        case "$__rest" in
          *=*) _sk_scaffold_store_set "${__rest%%=*}" "${__rest#*=}" ;;
        esac
        continue
        ;;
      '@file '*) continue ;;
      *=*)
        __rest=${__line#*=}
        case "$__line" in
          version=*) SK_MANIFEST_VERSION="$__rest" ;;
          template_version=*) SK_MANIFEST_TEMPLATE_VERSION="$__rest" ;;
          name=*) SK_MANIFEST_NAME="$__rest" ;;
          commands=*) SK_MANIFEST_COMMANDS="$__rest" ;;
          manifest_version=*) SK_MANIFEST_FORMAT="$__rest" ;;
        esac
        continue
        ;;
    esac
  done <"$__file"
  return 0
}

# scaffold_manifest_get KEY —— 读 manifest 里的一个标量
# @exitcode 0 找到（stdout 输出值）
# @exitcode 1 清单里没有这个键
# @stability experimental
scaffold_manifest_get() {
  local __key=${1:-}
  case "$__key" in
    version) printf '%s\n' "$SK_MANIFEST_VERSION" ;;
    template_version) printf '%s\n' "$SK_MANIFEST_TEMPLATE_VERSION" ;;
    name) printf '%s\n' "$SK_MANIFEST_NAME" ;;
    commands) printf '%s\n' "$SK_MANIFEST_COMMANDS" ;;
    manifest_version) printf '%s\n' "$SK_MANIFEST_FORMAT" ;;
    *)
      log_error "$(_t 'unknown manifest key'): $__key"
      return "$SK_USAGE"
      ;;
  esac
  return 0
}

# scaffold_manifest_list_files —— 逐行输出模板自有的文件（相对路径）
# @exitcode 0 总是成功（stdout 逐行输出清单里的文件）
# @stability experimental
scaffold_manifest_list_files() {
  local __dir=${1:-} __file __line __rel
  _sk_need_args "$#" 1 "scaffold_manifest_list_files DIR" || return $?
  __file="$__dir/.shellkit-manifest"
  [ -f "$__file" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '@file '*)
        __rel=${__line#@file }
        printf '%s\n' "${__rel%% *}"
        ;;
    esac
  done <"$__file"
  return 0
}

# scaffold_manifest_file_sum DIR RELPATH —— 读 manifest 里记的某个文件的 sha256
# @exitcode 0 成功（stdout 输出校验和）
# @exitcode 1 算不出校验和
# @stability experimental
scaffold_manifest_file_sum() {
  local __dir=${1:-} __rel=${2:-} __file __line
  _sk_need_args "$#" 2 "scaffold_manifest_file_sum DIR RELPATH" || return $?
  __file="$__dir/.shellkit-manifest"
  [ -f "$__file" ] || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      "@file $__rel "*)
        printf '%s\n' "${__line#@file $__rel }"
        return 0
        ;;
    esac
  done <"$__file"
  return 1
}

# scaffold_run_hook FILE PROJECT_DIR —— 跑一个模板钩子
#
# 钩子是模板目录里的可执行脚本（template.hooks.d/pre、template.hooks.d/post）。
# 环境变量里会带上：SHELLKIT_PROJECT_DIR / SHELLKIT_PROJECT_NAME /
# SHELLKIT_PROJECT_COMMANDS / SHELLKIT_TEMPLATE_VERSION，以及每个模板变量。
# 钩子不存在就跳过；不可执行就跳过并告警（不因为钩子没设执行位就让生成失败）。
# @exitcode 0 钩子成功（或没有钩子）
# @exitcode 2 参数错
# @exitcode 1 钩子执行失败
# @stability experimental
scaffold_run_hook() {
  local __file=${1:-} __dir=${2:-} __line __key __value
  _sk_need_args "$#" 2 "scaffold_run_hook FILE PROJECT_DIR" || return $?
  if [ ! -f "$__file" ]; then
    return 0
  fi
  if [ ! -x "$__file" ]; then
    log_warn "$(_t 'hook is not executable, skipped'): $__file"
    return 0
  fi
  SHELLKIT_PROJECT_DIR="$__dir"
  export SHELLKIT_PROJECT_DIR
  # 钩子约定的几个变量：项目名、命令清单、模板版本
  SHELLKIT_PROJECT_NAME=$(_sk_scaffold_store_get PROJECT_NAME "")
  SHELLKIT_PROJECT_COMMANDS=$(_sk_scaffold_store_get PROJECT_COMMANDS "")
  SHELLKIT_TEMPLATE_VERSION=$(_sk_scaffold_store_get TEMPLATE_VERSION "")
  export SHELLKIT_PROJECT_NAME SHELLKIT_PROJECT_COMMANDS SHELLKIT_TEMPLATE_VERSION
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      *=*) ;;
      *) continue ;;
    esac
    __key=${__line%%=*}
    __value=${__line#*=}
    case "$__key" in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    export "$__key=$__value"
  done <<EOF
$SK_SCAFFOLD_VARS
EOF
  if ! "$__file"; then
    log_error "$(_t 'hook failed'): $__file"
    return "$SK_ERR"
  fi
  return 0
}
