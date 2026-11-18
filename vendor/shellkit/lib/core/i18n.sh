#!/usr/bin/env bash
#
# 国际化。msgid 一律英文，译文进 locale/<lang>/LC_MESSAGES/shellkit.po。
# 找不到 gettext 时降级为原样输出 msgid（即英文），不失败。
#
# 三个新旋钮（只加不改：不设它们时 _t 的输出与改动前逐字一致）：
#   SHELLKIT_I18N_DOMAIN  域名。默认 ${TEXTDOMAIN:-shellkit}
#   SHELLKIT_I18N_DIRS    冒号分隔的查找目录。默认 ${TEXTDOMAINDIR:-$SHELLKIT_HOME/locale}
#   SHELLKIT_LANG         语言目录名（zh_CN）。默认按 LC_ALL / LC_MESSAGES / LANG 取，取不到 en
#
# 纯 bash 兜底表：<dir>/<lang>/messages/<domain>.sh，由 po/messages.sh 生成并入库。
# gettext 查不到时用它出译文 —— 没有 gettext 的机器也能出中文。

if [ "${SHELLKIT_NO_GETTEXT:-0}" = "1" ]; then
  SK_GETTEXT=""
else
  SK_GETTEXT=$(command -v gettext 2>/dev/null) || SK_GETTEXT=""
fi
export SK_GETTEXT

# 已载入的纯 bash 兜底表（函数名，空格分隔）与它的配置签名。
# 签名变了就重载：兜底表必须按当前 (语言, 域, 目录) 惰性载入 ——
# bootstrap 之后才设 SHELLKIT_I18N_DOMAIN / SHELLKIT_I18N_DIRS 的用法必须生效。
_SK_I18N_TABLES=""
_SK_I18N_TABLES_KEY=""

# _sk_i18n_lang VARNAME —— 语言目录名写进 VARNAME
#
# 优先级：SHELLKIT_LANG → LC_ALL → LC_MESSAGES → LANG → en。
# zh_CN.UTF-8 → zh_CN；zh_CN.UTF-8@zh → zh_CN。
_sk_i18n_lang() {
  local __l="${SHELLKIT_LANG:-}"
  if [ -z "$__l" ]; then
    __l="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
  fi
  __l="${__l%%.*}"
  __l="${__l%%@*}"
  [ -n "$__l" ] || __l='en'
  printf -v "$1" '%s' "$__l"
}

# _sk_i18n_domain VARNAME —— 域名写进 VARNAME
_sk_i18n_domain() {
  printf -v "$1" '%s' "${SHELLKIT_I18N_DOMAIN:-${TEXTDOMAIN:-shellkit}}"
}

# _sk_i18n_dirs VARNAME —— 冒号分隔的查找目录写进 VARNAME
_sk_i18n_dirs() {
  printf -v "$1" '%s' "${SHELLKIT_I18N_DIRS:-${TEXTDOMAINDIR:-$SHELLKIT_HOME/locale}}"
}

# _sk_i18n_fn_suffix DOMAIN —— 域名 -> 函数名后缀
# 非 [a-z0-9_] 的字符一律换成 _（域名里的点、横杠之类不能进函数名）
_sk_i18n_fn_suffix() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_' '_'
}

# _sk_i18n_table_fn DOMAIN —— 兜底表的查表函数名
_sk_i18n_table_fn() {
  printf '%s' "_sk_msg_lookup_$(_sk_i18n_fn_suffix "$1")"
}

# _sk_i18n_gettext DOMAIN DIR MSG LANG —— 跑一次 gettext，域名与目录由调用方指定
#
# 只有显式设了 SHELLKIT_LANG 才把它注入给 gettext（LANGUAGE=...）：
# 没设时让 gettext 自己按 LANGUAGE / LC_ALL / LC_MESSAGES / LANG 选语言，
# 行为与改动前一致 —— gettext 的 LANGUAGE 优先级比 LC_ALL 高，
# 无条件覆盖会把 LC_ALL=zh_CN.UTF-8 LANGUAGE=en 的机器从英文变成中文。
_sk_i18n_gettext() {
  local __dom="$1" __dir="$2" __msg="$3" __lang="$4"
  if [ -n "${SHELLKIT_LANG:-}" ]; then
    case "$__msg" in
      -*) LANGUAGE="$__lang" TEXTDOMAIN="$__dom" TEXTDOMAINDIR="$__dir" "$SK_GETTEXT" -- "$__msg" ;;
      *) LANGUAGE="$__lang" TEXTDOMAIN="$__dom" TEXTDOMAINDIR="$__dir" "$SK_GETTEXT" "$__msg" ;;
    esac
  else
    case "$__msg" in
      -*) TEXTDOMAIN="$__dom" TEXTDOMAINDIR="$__dir" "$SK_GETTEXT" -- "$__msg" ;;
      *) TEXTDOMAIN="$__dom" TEXTDOMAINDIR="$__dir" "$SK_GETTEXT" "$__msg" ;;
    esac
  fi
}

# _sk_i18n_load_tables LANG DOMAIN DIRS —— 按当前配置载入纯 bash 兜底表
#
# 表文件：<dir>/<lang>/messages/<domain>.sh，里面定义 _sk_msg_lookup_<domain>。
# 目录列表是冒号分隔的，用 IFS 切开 —— 路径里带空格也不怕。
# 同一个 (语言, 域, 目录) 只载入一次：签名不变就直接返回。
_sk_i18n_load_tables() {
  local __lang="$1" __dom="$2" __dirs="$3"
  local __key __arr __dir __cand __fn __file
  local __cands=()

  __key="$__lang|$__dom|$__dirs"
  if [ "$__key" = "$_SK_I18N_TABLES_KEY" ]; then
    return 0
  fi
  _SK_I18N_TABLES=""
  _SK_I18N_TABLES_KEY="$__key"

  __cands[0]="$__dom"
  if [ "$__dom" != 'shellkit' ]; then
    __cands[1]='shellkit'
  fi

  IFS=':' read -r -a __arr <<<"$__dirs"
  for __dir in ${__arr[@]+"${__arr[@]}"}; do
    [ -n "$__dir" ] || continue
    for __cand in "${__cands[@]}"; do
      __fn="$(_sk_i18n_table_fn "$__cand")"
      case " $_SK_I18N_TABLES " in
        *" $__fn "*) continue ;;
      esac
      __file="$__dir/$__lang/messages/$__cand.sh"
      [ -r "$__file" ] || continue
      # shellcheck disable=SC1090
      . "$__file" || continue
      command -v "$__fn" >/dev/null 2>&1 || continue
      _SK_I18N_TABLES="${_SK_I18N_TABLES:+$_SK_I18N_TABLES }$__fn"
    done
  done
  return 0
}

# _sk_i18n_table_lookup MSG —— 在已载入的兜底表里查译文
# 查到：把译文打到 stdout 并返回 0；查不到：返回 1（不打印任何东西）
_sk_i18n_table_lookup() {
  local __msg="$1" __fn __out
  for __fn in ${_SK_I18N_TABLES:-}; do
    __out="$("$__fn" "$__msg")" || continue
    if [ -n "$__out" ]; then
      printf '%s' "$__out"
      return 0
    fi
  done
  return 1
}

# _t MSG
#
# gettext 把以 - 开头的参数当选项，所以 msgid 以短横开头时（像
# '--set expects KEY=VALUE'）必须在前面加一个 -- 让它停止解析选项。
# 只有真的要传短横开头时才加：多加会让 gettext 把 -- 当成 msgid 本身。
#
# 查找顺序：
#   1. 三个新旋钮都没设 —— 走原来那条路，输出与改动前逐字一致
#      （gettext 在与不在两种情形都是）。
#   2. 设了旋钮：先查纯 bash 兜底表 <dir>/<lang>/messages/<domain>.sh。
#      表是 locale 无关的 —— gettext 在 C/POSIX locale 下会忽略 LANGUAGE，
#      光靠它选不出语言，表才是「指定了语言就一定出译文」的那条路。
#   3. 表里没有：按目录顺序找 <dir>/<lang>/LC_MESSAGES/<domain>.mo，
#      域名找不到再退到 shellkit 域；SHELLKIT_LANG 设了就注入给 gettext。
#   4. 还是没有：原样输出 msgid。
#
# @exitcode 0 总是成功（找不到译文时原样输出 msgid）
_t() {
  local __msg="${1:-}" __dom __dirs __lang __arr __dir __cand __out
  local __cands=()

  _sk_i18n_domain __dom
  _sk_i18n_dirs __dirs

  # 默认配置：域名、目录、语言都没被改过 —— 走老路，一个字节都不变。
  if [ -z "${SHELLKIT_LANG:-}" ] &&
    [ "$__dom" = "${TEXTDOMAIN:-shellkit}" ] &&
    [ "$__dirs" = "${TEXTDOMAINDIR:-$SHELLKIT_HOME/locale}" ]; then
    if [ -n "${SK_GETTEXT:-}" ]; then
      # 纯 C/POSIX locale 下 gettext 不查译文（POSIX 规定 C 下忽略 LANGUAGE，
      # GNU gettext 对 C/POSIX 直接返回 msgid）—— fork 它只为拿回同一个字符串：
      # cli_new / cli_upgrade 各有 39 次这种无效 fork（实测 39 次 126ms，
      # 占 new 耗时两成）。提前原样返回与「fork 后拿回 msgid」逐字等价。
      # 只认完整值 C/POSIX：C.UTF-8 会读 LANGUAGE、可能真有译文，不在此列；
      # 判定用 gettext 读的同一组变量（LC_ALL > LC_MESSAGES > LANG），
      # 且只在标准单 msgid 形态（$# = 1）下短路 —— 多参数走原路，行为不变。
      case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
        C | POSIX)
          if [ "$#" -eq 1 ]; then
            printf '%s' "$__msg"
            return 0
          fi
          ;;
      esac
      case "$__msg" in
        -*) "$SK_GETTEXT" -- "$@" ;;
        *) "$SK_GETTEXT" "$@" ;;
      esac
      return $?
    fi
    printf '%s' "$__msg"
    return 0
  fi

  _sk_i18n_lang __lang

  __cands[0]="$__dom"
  if [ "$__dom" != 'shellkit' ]; then
    __cands[1]='shellkit'
  fi

  # 纯 bash 兜底表：locale 无关，指定了语言就一定查得到
  _sk_i18n_load_tables "$__lang" "$__dom" "$__dirs"
  if _sk_i18n_table_lookup "$__msg"; then
    return 0
  fi

  # gettext 分支：按目录顺序找 .mo
  if [ -n "${SK_GETTEXT:-}" ]; then
    IFS=':' read -r -a __arr <<<"$__dirs"
    for __dir in ${__arr[@]+"${__arr[@]}"}; do
      [ -n "$__dir" ] || continue
      for __cand in "${__cands[@]}"; do
        __out="$(_sk_i18n_gettext "$__cand" "$__dir" "$__msg" "$__lang")"
        # gettext 找不到译文时会把 msgid 原样打出来，退出码仍然是 0 ——
        # 所以只能拿输出跟 msgid 比，不能拿退出码判。
        if [ "$__out" != "$__msg" ]; then
          printf '%s' "$__out"
          return 0
        fi
      done
    done
  fi

  printf '%s' "$__msg"
  return 0
}

# _tn SINGULAR PLURAL N
# @exitcode 0 总是成功（n=1 用单数，其余用复数）
_tn() {
  if [ "${3:-0}" = "1" ]; then
    _t "$1"
    return 0
  fi
  # 复数文案也必须经过 gettext，否则 .po 里写了的译文永远用不上
  _t "${2:-}"
}

# _tf MSGID [ARG...]
#
# 译文当 printf 格式串用：先查译文，再把译文里的 %s/%d 等占位符按参数填上。
#
# 为什么要有它：直接写 printf "$(_t 'foo %s')" "$x" 会被 shellcheck 判成
# SC2059（格式串是变量）—— 而这正是 gettext 的标准用法，格式串来自译文，
# 不是用户输入。集中到这一个函数里，SC2059 只出现一次，且能被标注清楚。
#
# 占位符个数必须与参数个数一致：填不上时 printf 会把多余的参数原样追加、
# 或把 %s 打成空串。译文侧的占位符一致性由 msgfmt --check 保证
# （xgettext 需要给带占位符的 msgid 打 sh-printf-format 标记）。
#
# 用法：
#   error "$(_tf 'unknown action: %s' "$action")"
#
# @exitcode 0 总是成功（占位符填不上时 printf 报错但仍返回 0 的行为被兜住）
_tf() {
  local __msg="${1:-}" __fmt
  shift 2>/dev/null || true
  __fmt="$(_t "$__msg")"
  # shellcheck disable=SC2059  # 格式串来自译文（gettext 的标准用法），不是用户输入
  printf "$__fmt" "$@" 2>/dev/null || printf '%s' "$__fmt"
}
