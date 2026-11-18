#!/usr/bin/env bash
#
# man page 生成。
#
#   - 第 1 节（shellkit(1)）：命令总览，数据来自 CLI 注册表（cli_cmd 注册的那份）
#   - 第 3 节（shellkit-<模块>(3)）：库函数参考，数据来自 lib/core/*.sh 里
#     公开函数上方的注释块
#
# 两份数据都是仓库里已有的真相源：加一个命令、改一句函数说明，man 页自动跟着变。
# 不另维护一份清单 —— 另维护的那份一定会漂移。
#
# 页面文件名与惯例一致：第 1 节 shellkit.1，第 3 节 shellkit-<模块名>.3。

# _man_escape TEXT —— roff 转义
#   反斜杠要转（roff 里它是转义符）；行首的 . 与 ' 是控制行，要用 \& 断开。
#   连字符不转：roff 里 '-' 本来就正常显示，转成 \- 只会让页面变得不好 grep。
_man_escape() {
  local __s=${1:-}
  __s=${__s//\\/\\e}
  case "$__s" in
    .* | \'*) __s="\\&$__s" ;;
  esac
  printf '%s' "$__s"
}

# _man_version —— 库里记录的版本号
_man_version() {
  local __v=""
  if [ -r "$SHELLKIT_HOME/VERSION" ]; then
    __v=$(tr -d '[:space:]' <"$SHELLKIT_HOME/VERSION")
  fi
  printf '%s' "${__v:-unknown}"
}

# _man_date —— 页面日期
_man_date() {
  date '+%Y-%m-%d' 2>/dev/null || printf '%s' "unknown"
}

# man_modules —— 输出模块名，一行一个
# @exitcode 0 总是成功
# @stability experimental
man_modules() {
  local __list="$SHELLKIT_HOME/lib/modules.txt" __line __name
  [ -r "$__list" ] || return 0
  while IFS= read -r __line || [ -n "$__line" ]; do
    __line="${__line%%#*}"
    case "$__line" in
      '' | ' '*) continue ;;
    esac
    __name="${__line%%[[:space:]]*}"
    [ -n "$__name" ] || continue
    printf '%s\n' "$__name"
  done <"$__list"
  return 0
}

# _man_module_file MODULE —— 模块对应的源文件路径
_man_module_file() {
  local __mod=${1:-} __f
  for __f in "$SHELLKIT_HOME"/lib/core/*.sh; do
    [ -f "$__f" ] || continue
    if [ "${__f##*/}" = "$__mod.sh" ]; then
      printf '%s' "$__f"
      return 0
    fi
  done
  return 1
}

# _man_module_desc MODULE —— 模块头一行说明（文件顶部注释块）
#
# 只取文件头第一行非空说明，就是模块的一句话摘要 —— 和 shdoc 的首行即摘要
# 一个口径。文件头后面的段落是细则：全塞进 DESCRIPTION 会变成一堵文字墙，
# 反而把模块讲了什么淹没掉。
_man_module_desc() {
  local __mod=${1:-} __file __line __desc=""
  __file=$(_man_module_file "$__mod") || return 1
  while IFS= read -r __line || [ -n "$__line" ]; do
    case "$__line" in
      '#!'*) continue ;;
      '#'*) ;;
      *) break ;;
    esac
    __line="${__line#\#}"
    __line="${__line# }"
    [ -n "$__line" ] || continue
    __desc=$__line
    break
  done <"$__file"
  [ -n "$__desc" ] || return 1
  printf '%s' "$__desc"
  return 0
}

# _man_scan MODULE —— 扫出模块里的公开函数与它们的注释
#   输出记录，每行一条，字段用制表符分隔：
#     FUNC<TAB>名字<TAB>签名行<TAB>说明
#     PARAM<TAB>序号<TAB>说明
#     EXIT<TAB>返回码<TAB>说明
#     SEE<TAB>内容
_man_scan() {
  local __mod=${1:-} __file
  __file=$(_man_module_file "$__mod") || return 1

  local __lines=() __line __i=0 __n __j __c __name __blk=() __k
  local __tags=() __syn __desc __tag
  while IFS= read -r __line || [ -n "$__line" ]; do
    __lines[${#__lines[@]}]="$__line"
  done <"$__file"
  __n=${#__lines[@]}

  while [ "$__i" -lt "$__n" ]; do
    __line=${__lines[$__i]}
    case "$__line" in
      [A-Za-z_]*"()"*)
        __name=${__line%%[ (]*}
        case "$__name" in
          _*)
            __i=$((__i + 1))
            continue
            ;;
        esac
        # 往上收集紧邻的注释块（中间有空行就等于没有说明）
        __blk=()
        __j=$((__i - 1))
        while [ "$__j" -ge 0 ]; do
          __c=${__lines[$__j]}
          case "$__c" in
            '#'*) __blk[${#__blk[@]}]="$__c" ;;
            *) break ;;
          esac
          __j=$((__j - 1))
        done
        __syn=""
        __desc=""
        __tags=()
        __k=${#__blk[@]}
        while [ "$__k" -gt 0 ]; do
          __k=$((__k - 1))
          __c=${__blk[$__k]}
          __c=${__c#\#}
          __c=${__c# }
          case "$__c" in
            '') continue ;;
            '@param'*)
              __tag=${__c#@param}
              __tag=${__tag# }
              __tag=${__tag# }
              __tags[${#__tags[@]}]="PARAM	${__tag%%[[:space:]]*}	${__tag#*[[:space:]]}"
              continue
              ;;
            '@exitcode'*)
              __tag=${__c#@exitcode}
              __tag=${__tag# }
              __tags[${#__tags[@]}]="EXIT	${__tag%%[[:space:]]*}	${__tag#*[[:space:]]}"
              continue
              ;;
            '@see'*)
              __tag=${__c#@see}
              __tag=${__tag# }
              __tags[${#__tags[@]}]="SEE	$__tag"
              continue
              ;;
            '@example'*)
              continue
              ;;
          esac
          if [ -z "$__syn" ]; then
            # 首行是「签名 —— 说明」：签名进 .B，说明单独一行
            case "$__c" in
              *'——'*)
                __syn=${__c%%——*}
                __desc=${__c#*——}
                # 两边都可能有空格，去掉
                __syn=${__syn%"${__syn##*[![:space:]]}"}
                __desc=${__desc#"${__desc%%[![:space:]]*}"}
                ;;
              *)
                __syn=$__c
                __desc=""
                ;;
            esac
          fi
        done
        printf 'FUNC\t%s\t%s\t%s\n' "$__name" "$__syn" "$__desc"
        for __tag in ${__tags[@]+"${__tags[@]}"}; do
          printf '%s\n' "$__tag"
        done
        __i=$((__i + 1))
        ;;
      *)
        __i=$((__i + 1))
        ;;
    esac
  done
  return 0
}

# man_page —— 输出 shellkit(1) 的 roff 正文
# @exitcode 0 总是成功
# @stability experimental
man_page() {
  local __ver __date __i=0 __name __desc __usage __grp="" __last="" __n __m
  __ver=$(_man_version)
  __date=$(_man_date)
  printf '.TH SHELLKIT 1 "%s" "shellkit %s" "shellkit manual"\n' "$__date" "$__ver"
  printf '.SH NAME\n'
  printf 'shellkit \\- Bash library and project scaffolding generator\n'
  printf '.SH SYNOPSIS\n'
  printf '.B shellkit\n'
  printf '.RI [ options ]\n'
  printf '.I command\n'
  printf '.RI [ args ]\n'
  printf '.SH DESCRIPTION\n'
  printf 'shellkit is a Bash library and a scaffolding generator. It ships logging,\n'
  printf 'configuration, downloads with checksum verification, retries, single-instance\n'
  printf 'locks, an interactive prompt layer, a CLI framework and i18n -- all on the\n'
  printf 'Bash 3.2 baseline that ships with macOS.\n'
  printf '.SH COMMANDS\n'
  __n=${#SK_CLI_NAMES[@]}
  while [ "$__i" -lt "$__n" ]; do
    __name=${SK_CLI_NAMES[$__i]}
    __desc=${SK_CLI_DESCS[$__i]}
    __usage=${SK_CLI_USAGES[$__i]}
    __grp=${SK_CLI_GROUPS[$__i]}
    if [ "$__grp" != "$__last" ]; then
      __last=$__grp
      if [ -n "$__grp" ]; then
        printf '.SS %s\n' "$(_man_escape "$__grp")"
      fi
    fi
    printf '.TP\n'
    printf '.B %s\n' "$(_man_escape "$__name")"
    if [ -n "$__usage" ] && [ "$__usage" != "$__name" ]; then
      printf '%s\n' "$(_man_escape "$__usage")"
    fi
    if [ -n "$__desc" ]; then
      printf '%s\n' "$(_man_escape "$__desc")"
    fi
    __i=$((__i + 1))
  done
  printf '.SH OPTIONS\n'
  printf '.TP\n.B \\-h, \\-\\-help\nshow this help\n'
  printf '.TP\n.B \\-V, \\-\\-version\nshow version\n'
  printf '.TP\n.B \\-\\-verbose\nenable debug output\n'
  printf '.TP\n.B \\-\\-no-color\ndisable colored output\n'
  printf '.TP\n.B \\-y, \\-\\-yes\nnon-interactive, use defaults\n'
  printf '.SH EXIT CODES\n'
  printf '.TP\n.B 0\nsuccess\n'
  printf '.TP\n.B 1\ngeneral error\n'
  printf '.TP\n.B 2\nusage error (wrong arguments)\n'
  printf '.TP\n.B 3\nprecondition not met (missing command, not root, no default for a prompt)\n'
  printf '.TP\n.B 4\nnetwork failure\n'
  printf '.TP\n.B 5\nverification failed (checksum mismatch, docs out of sync with sources)\n'
  printf '.SH SEE ALSO\n'
  printf '.BR shellkit (1)\n'
  for __m in $(man_modules); do
    printf '.BR shellkit\\-%s (3)\n' "$__m"
  done
  return 0
}

# _man_has_module NAME —— 这个模块在清单里吗
#
# 为什么不用 `man_modules | grep -qx "$name"`：grep -q 命中就退出，管道上游
# （man_modules）还在往里写，会被 SIGPIPE 打死（退出码 141）。平时看不出来，
# 但调用方开了 `set -o pipefail` 时整条管道按 141 判失败 —— 「模块存在」被
# 误判成「模块不存在」，而且是竞态：同一台机器有时绿有时红，CI 上必炸。
# 这里逐个比对，不用管道。
_man_has_module() {
  local __want=${1:-} __m
  for __m in $(man_modules); do
    if [ "$__m" = "$__want" ]; then
      return 0
    fi
  done
  return 1
}

# man_module_page MODULE —— 输出某模块第 3 节的 roff 正文
# @exitcode 0 成功
# @exitcode 2 模块名不合法或模块不存在
# @stability experimental
man_module_page() {
  local __mod=${1:-}
  case "$__mod" in
    '' | *[!A-Za-z0-9_-]*) return "$SK_USAGE" ;;
  esac
  _man_has_module "$__mod" || return "$SK_USAGE"
  local __ver __date __desc __line __kind __rest __fname __syn __dsc
  __ver=$(_man_version)
  __date=$(_man_date)
  printf '.TH SHELLKIT-%s 3 "%s" "shellkit %s" "shellkit manual"\n' \
    "$(printf '%s' "$__mod" | tr '[:lower:]' '[:upper:]')" "$__date" "$__ver"
  printf '.SH NAME\n'
  printf 'shellkit-%s \\- %s module of the shellkit library\n' \
    "$__mod" "$(_man_escape "$__mod")"
  printf '.SH DESCRIPTION\n'
  __desc=$(_man_module_desc "$__mod" || printf '%s' "$__mod")
  printf '%s\n' "$(_man_escape "$__desc")"
  printf '.SH FUNCTIONS\n'
  while IFS= read -r __line; do
    __kind=${__line%%$'\t'*}
    __rest=${__line#*$'\t'}
    case "$__kind" in
      FUNC)
        __fname=${__rest%%$'\t'*}
        __rest=${__rest#*$'\t'}
        __syn=${__rest%%$'\t'*}
        __dsc=${__rest#*$'\t'}
        printf '.TP\n'
        printf '.B %s\n' "$(_man_escape "$__fname")"
        [ -n "$__syn" ] && printf '%s\n' "$(_man_escape "$__syn")"
        [ -n "$__dsc" ] && printf '%s\n' "$(_man_escape "$__dsc")"
        ;;
      PARAM)
        printf '.RS 4\n'
        printf '.B %s\n' "$(_man_escape "${__rest%%$'\t'*}")"
        printf '%s\n' "$(_man_escape "${__rest#*$'\t'}")"
        printf '.RE\n'
        ;;
      EXIT)
        printf '.RS 4\n'
        printf '.B EXIT %s\n' "$(_man_escape "${__rest%%$'\t'*}")"
        printf '%s\n' "$(_man_escape "${__rest#*$'\t'}")"
        printf '.RE\n'
        ;;
      SEE)
        printf '.RS 4\n'
        printf 'See also: %s\n' "$(_man_escape "$__rest")"
        printf '.RE\n'
        ;;
    esac
  done < <(_man_scan "$__mod")
  return 0
}

# man_write_all DIR —— 把所有页面写进 DIR
# @exitcode 0 全部写成功
# @exitcode 3 目录不存在或不可写
# @stability experimental
man_write_all() {
  local __dir=${1:-}
  if [ -z "$__dir" ] || [ ! -d "$__dir" ] || [ ! -w "$__dir" ]; then
    return "$SK_PRECOND"
  fi
  if ! man_page >"$__dir/shellkit.1" 2>/dev/null; then
    return "$SK_PRECOND"
  fi
  local __mod
  for __mod in $(man_modules); do
    if ! man_module_page "$__mod" >"$__dir/shellkit-$__mod.3" 2>/dev/null; then
      return "$SK_PRECOND"
    fi
  done
  return 0
}

# man_count_functions —— 公开函数总数
# @exitcode 0 总是成功
# @stability experimental
man_count_functions() {
  local __mod __n=0 __line __kind
  for __mod in $(man_modules); do
    while IFS= read -r __line; do
      __kind=${__line%%$'\t'*}
      [ "$__kind" = "FUNC" ] || continue
      __n=$((__n + 1))
    done < <(_man_scan "$__mod")
  done
  printf '%s' "$__n"
  return 0
}
