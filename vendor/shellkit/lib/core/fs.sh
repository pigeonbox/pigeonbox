#!/usr/bin/env bash
# 文件系统工具。写入一律原子，幂等操作已正确时零改动。

SK_TMPDIR=""

# _sk_fs_dry_run ACTION TARGET —— 「只演练不落盘」模式下的统一出口
#
# 为什么需要它：SHELLKIT_DRY_RUN=1 只覆盖 run（跑命令）与 svc（服务写类动作）
# —— 这两处是「跑一条命令」，干跑就是不打这条命令。
# 但 fs / config 这层是「直接改文件」，干跑意味着**一个字节都不写**。
# 以前没有这层，于是 SHELLKIT_DRY_RUN=1 跑一个改配置的脚本，
# 配置照样被改掉了 —— 演练变成了「照做一遍」。
#
# 为什么用独立的开关 SHELLKIT_DRY_RUN_FILES 而不是复用 SHELLKIT_DRY_RUN：
# SHELLKIT_DRY_RUN 已经是 1.0 之前的兼容承诺面（run / svc 吃它），
# 让它突然开始拦 fs / conf 的写 ⇒ 既有脚本在 dry-run 下会**从「照做」变成
# 「不做」** —— 那是改变既有结果，按 COMPATIBILITY.md 要走 minor + 迁移表，
# 而且会让「演练」悄悄变成「跳过」，比原来的陷阱更危险。
# 独立开关是 opt-in：默认行为一个字节都不变。
#
# 干跑时打印一行到 stderr（stdout 仍然只给数据），并返回 0 ——
# 「跳过」不是错误，调用方的成功路径不该因此变红。
#
# 返回 1 表示「不在干跑模式」，调用方继续正常执行。
#
# @exitcode 0 不在干跑模式（调用方继续做事）
# @exitcode 1 在干跑模式（已打印计划，什么都没做）
_sk_fs_dry_run() {
  local __action=${1:-} __target=${2:-}
  if [ "${SHELLKIT_DRY_RUN_FILES:-0}" != "1" ]; then
    return 1
  fi
  printf '[dry-run] %s %s
' "$__action" "$__target" >&2
  return 0
}

# fs_ensure_dir DIR [MODE] —— 幂等建目录；给了 MODE 就 chmod
# @exitcode 0 目录已存在或建好
# @exitcode 2 没给参数
# @exitcode 1 mkdir 失败
# @stability stable
fs_ensure_dir() {
  local __dir=${1:-} __mode=${2:-}
  _sk_need_args "$#" 1 "fs_ensure_dir DIR [MODE]" || return $?
  if _sk_fs_dry_run "mkdir" "$__dir"; then
    return 0
  fi
  if [ ! -d "$__dir" ]; then
    mkdir -p "$__dir" || return 1
  fi
  if [ -n "$__mode" ]; then
    chmod "$__mode" "$__dir" 2>/dev/null || true
  fi
  return 0
}

# fs_atomic_write FILE CONTENT [MODE] —— 原子写文件；默认权限 600，父目录不存在会先建
# @exitcode 0 写成功（临时文件 + rename）
# @exitcode 2 没给参数
# @exitcode 1 建目录、落临时文件或改名失败
#
# 权限：MODE 给什么就是什么（默认 600），**覆盖已有文件也照样改**。
# 与 fs_atomic_copy 的分工：那个不传 MODE 时保留目标原权限，这个总是按 MODE 写 ——
# 「写内容」的场景（清单、配置）要的就是「权限是定死的」，不然改一次配置就把
# 权限改了。
# @stability stable
fs_atomic_write() {
  local __file=${1:-} __content=${2:-} __mode=${3:-600} __dir __tmp
  _sk_need_args "$#" 2 "fs_atomic_write FILE CONTENT [MODE]" || return $?
  if _sk_fs_dry_run "write" "$__file"; then
    return 0
  fi
  __dir=$(dirname "$__file")
  fs_ensure_dir "$__dir" "" || return 1
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if ! printf '%s' "$__content" >"$__tmp"; then
    rm -f "$__tmp"
    return 1
  fi
  chmod "$__mode" "$__tmp" 2>/dev/null || true
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# _sk_fs_mode FILE —— 文件的权限位（八进制，如 644）；取不到就返回 1
_sk_fs_mode() {
  local __f=${1:-} __m=""
  if [ -z "$__f" ]; then
    return 1
  fi
  if ! __m=$(stat -f '%Lp' "$__f" 2>/dev/null); then
    if ! __m=$(stat -c '%a' "$__f" 2>/dev/null); then
      return 1
    fi
  fi
  # stat 的输出不是八进制就当没取到（GNU 的 stat -f 认不出 BSD 的格式串时
  # 会报错，但某些实现会吐别的东西出来 —— 别把垃圾当权限用）
  case "$__m" in
    '' | *[!0-7]*) return 1 ;;
  esac
  printf '%s' "$__m"
  return 0
}

# fs_atomic_copy SRC DST [MODE] —— 按字节把 SRC 复制到 DST；写法是原子的
#
# 与 fs_atomic_write 的分工：那个吃的是「内容」，命令替换会吃掉文件末尾的换行，
# 搬模板文件会变形；这个直接搬文件，逐字节一致。
#
# 为什么不用 cp：cp -f 先 truncate 目标再写 —— 写到一半被打断（断电、磁盘满、
# 进程被杀）留下的是**半截文件**，既不是旧内容也不是新内容；而且 cp 会跟随
# **目标**的符号链接写穿，把内容写到别处去（链接本身纹丝不动，退出码还是 0）。
# 这里改成「写同目录的临时文件 → rename 过去」：rename 是原子的，失败要么
# 什么都没发生、要么整体换成新内容；它替换的是符号链接**本身**，
# 不会顺着链接写到别处。
#
# 权限：给了 MODE 就用它；不给时，目标是既有的普通文件就保留它的权限，
# 否则用源的权限（目标是符号链接时按源走 —— 这里替换的是链接本身）。
# 副作用：进程被中途杀掉时，目标目录里可能留下一个 `<DST>.tmp.XXXXXX` 的残留。
# @exitcode 0 复制成功
# @exitcode 2 参数错
# @exitcode 1 源不存在、建目录、落临时文件或改名失败
# @stability stable
fs_atomic_copy() {
  local __src=${1:-} __dst=${2:-} __mode=${3:-} __dir __tmp __perm=""
  _sk_need_args "$#" 2 "fs_atomic_copy SRC DST [MODE]" || return $?
  if [ ! -f "$__src" ]; then
    log_error "$(_t 'source file does not exist'): $__src"
    return 1
  fi
  # 守卫放在前置条件之后：干跑只该短路「写盘」，不该短路「判对错」
  if _sk_fs_dry_run "copy" "$__src -> $__dst"; then
    return 0
  fi
  __dir=$(dirname "$__dst")
  fs_ensure_dir "$__dir" "" || return 1
  if [ -n "$__mode" ]; then
    __perm="$__mode"
  elif [ -e "$__dst" ] && [ ! -L "$__dst" ]; then
    # 目标是既有普通文件：保留它现在的权限（cp 的老行为就是这样）。
    # 目标是符号链接时不看它的权限 —— 链接自己的权限位恒是 755，没意义；
    # 而且这里替换的是链接本身，权限该跟源走。
    __perm=$(_sk_fs_mode "$__dst") || __perm=""
  else
    __perm=$(_sk_fs_mode "$__src") || __perm=""
  fi
  __tmp=$(mktemp "$__dst.tmp.XXXXXX") || return 1
  if ! cp -f "$__src" "$__tmp"; then
    rm -f "$__tmp"
    return 1
  fi
  if [ -n "$__perm" ]; then
    chmod "$__perm" "$__tmp" 2>/dev/null || true
  fi
  if ! mv -f "$__tmp" "$__dst"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_backup FILE [KEEP] —— 产出 FILE.bak.YYYYmmddHHMMSS，按名升序保留最新 KEEP 份
#
# 备份文件本身也是「同目录临时文件 + rename」写出来的：中途被打断时要么没有
# 这份备份、要么是一份完整可用的，不会留下半截内容去顶掉完好的旧备份。
# @exitcode 0 备份成功（或文件本来就不存在）
# @exitcode 2 参数错（保留份数不是正整数）
# @exitcode 1 备份失败
# @stability stable
fs_backup() {
  local __file=${1:-} __keep=${2:-3} __stamp __bak __tmp __x __i=0 __total __seq=0
  local -a __list=()
  _sk_need_args "$#" 1 "fs_backup FILE [KEEP]" || return $?
  if _sk_fs_dry_run "backup" "$__file"; then
    return 0
  fi
  case "$__keep" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid keep count'): $__keep"
      return "$SK_USAGE"
      ;;
  esac
  if [ ! -f "$__file" ]; then
    return 0
  fi
  __stamp=$(date +%Y%m%d%H%M%S)
  # 名字必须唯一：同一秒里备份两次，第二次会覆盖第一次刚建的备份（等于丢一份）。
  # 加 pid 与序号后缀；前缀仍是定长时间戳，所以「按名升序 == 时间序」的轮转前提不变。
  __bak="$__file.bak.$__stamp.$$"
  while [ -e "$__bak" ]; do
    __seq=$((__seq + 1))
    __bak="$__file.bak.$__stamp.$$-$__seq"
  done
  # 落盘用「同目录临时文件 + rename」（坑 9），不直接 cp 到最终名字：
  # cp 先建目标再往里写，写到一半被打断（断电、磁盘满、进程被杀）留下的是
  # **半截备份** —— 既不是旧内容也不是新内容，而下面的轮转还会把它当成一份
  # 合格的备份计数，把真正完好的旧备份挤掉（一次失败带走两份历史）。
  # cp -p 的语义保留：权限与时间戳跟着源，备份要能原样还原。
  __tmp=$(mktemp "$__bak.tmp.XXXXXX") || return 1
  if ! cp -p "$__file" "$__tmp"; then
    rm -f "$__tmp"
    return 1
  fi
  if ! mv -f "$__tmp" "$__bak"; then
    rm -f "$__tmp"
    return 1
  fi
  for __x in "$__file".bak.*; do
    # 原子写的临时文件不是备份：名字也以 .bak. 开头，混进轮转就会顶掉一份真备份。
    # 只认「以 .tmp.<6 位随机串> 结尾」这一种形态 —— 文件名自己带 .tmp. 的备份
    # （x.tmp.conf.bak.<时间戳>.<pid>）不会被误伤。
    case "$__x" in
      *.tmp.??????) continue ;;
    esac
    if [ -e "$__x" ]; then
      __list[${#__list[@]}]=$__x
    fi
  done
  __total=${#__list[@]}
  if [ "$__total" -gt "$__keep" ]; then
    while [ "$__i" -lt $((__total - __keep)) ]; do
      rm -f "${__list[$__i]}"
      __i=$((__i + 1))
    done
  fi
  return 0
}

# _sk_fs_rel_safe REL —— 这个相对路径能不能安全地写进声明根之内
#
# 两个不变量：不是绝对路径，且不含 .. 路径组件。
# 清单 / 配置里读出来的名字会被拼进根路径 —— 名字里带 ../ 就能把文件写到根之外。
# 库里只有这一份实现：shellkit 的升级路径也调它（CLI 不再持有私有副本）。
_sk_fs_rel_safe() {
  local __rel=${1:-}
  case "$__rel" in
    '' | /*) return 1 ;;
  esac
  case "/$__rel/" in
    */../*) return 1 ;;
  esac
  return 0
}

# _sk_fs_in_dir BASE TARGET —— TARGET 是否落在 BASE 之内
#
# BASE 必须是解析过的绝对路径（pwd -P）：中间目录的符号链接也要解析，
# 工程里有个 tests/ 指向工程外，那不是「工程内的路径」。目标所在的目录
# 还不存在时，向上找到第一个存在的祖先再判。
# 库里只有这一份实现：shellkit 的升级路径也调它（CLI 不再持有私有副本）。
_sk_fs_in_dir() {
  local __base=${1:-} __tgt=${2:-} __dir __parent
  if [ -z "$__base" ] || [ -z "$__tgt" ]; then
    return 1
  fi
  __dir=$(dirname "$__tgt")
  while [ ! -d "$__dir" ]; do
    __parent=$(dirname "$__dir")
    if [ "$__parent" = "$__dir" ]; then
      return 1
    fi
    __dir=$__parent
  done
  __parent=$(cd "$__dir" 2>/dev/null && pwd -P) || return 1
  case "$__parent" in
    "$__base") return 0 ;;
    "$__base"/*) return 0 ;;
  esac
  return 1
}

# _sk_fs_no_symlink_below BASE REL —— REL 相对 BASE 的每一级已存在目录都不许是符号链接
#
# BASE 必须是解析过的真实目录（pwd -P）。REL 逐级向下走：哪一级已经存在，
# 它就必须是个真目录 —— 是符号链接或普通文件都不行。
# 哪一级还不存在就停：剩下的层级由调用方创建，落在真实目录之内，越不了界。
#
# 为什么「指向根之内」的符号链接也拒绝：我们分不清它是不是用户故意放的
# （有人用软链共享配置、软链到 dotfiles 仓）。不可信一律拒绝 —— 与
# 「目标是软链就放过它」的既有策略一致，不做「看起来安全就放行」的判断。
# @exitcode 0 每一级都已存在的都是真目录（或还没建，安全）
# @exitcode 1 BASE 不是目录，或途中有符号链接 / 普通文件挡路
_sk_fs_no_symlink_below() {
  local __base=${1:-} __rel=${2:-} __rest __part __dir
  if [ -z "$__base" ] || [ -z "$__rel" ] || [ ! -d "$__base" ]; then
    return 1
  fi
  __dir=$__base
  __rest=$__rel
  while [ -n "$__rest" ]; do
    __part=${__rest%%/*}
    if [ "$__rest" = "$__part" ]; then
      __rest=""
    else
      __rest=${__rest#*/}
    fi
    __dir="$__dir/$__part"
    if [ -L "$__dir" ]; then
      return 1
    fi
    if [ -e "$__dir" ]; then
      [ -d "$__dir" ] || return 1
    else
      break
    fi
  done
  return 0
}

# 所有权清单的 schema 版本（issue #78）
#
# 措辞与工程清单（.shellkit-manifest 的 manifest_version=2）保持一致 ——
# 同一个仓库里同一件事只该有一种写法。没有版本行的老清单按 v1 处理：
# 条目语义与版本化之前逐字节一致。
_SK_OWN_MANIFEST_VERSION=1

# _sk_fs_own_read FILE —— 读一份所有权清单（首行 manifest_version，其后 rel TAB sum）
#
# 读进 _SK_OWN_RELS[] 与 _SK_OWN_SUMS[] 两个平行数组。文件不存在是正常态
# （还没装过），返回 0、数组为空；格式不对的行跳过并告警 —— 清单损坏不该
# 把卸载卡死，但也不能静默：用户得知道「清单不完整，可能有东西删不掉」。
#
# 版本规则（issue #78）：
#   - 没有版本行 ⇒ v1（版本化之前的老清单，条目语义与今天完全一致）；
#   - 版本 ≤ 本构建支持的最高版 ⇒ 照常读（当前只支持 v1）；
#   - 版本更高 / 读不懂 ⇒ **告警并整份拒读**（数组留空，返回 0）——
#     宁可让调用方走「没有清单」的退化判据，也绝不按猜出来的格式去删文件。
#     返回 0 是刻意的：调用方都不带 `||`，返回非零会在 set -e 下打死整个 CLI。
_sk_fs_own_read() {
  local __file=${1:-} __line __rel __sum __bad=0 __ver=1
  _SK_OWN_RELS=()
  _SK_OWN_SUMS=()
  [ -n "$__file" ] || return 1
  [ -f "$__file" ] || return 0
  # 第一行单独读（bash 内建 read，不 fork）：它是版本行还是条目，决定了
  # 整份清单能不能按当前格式解释。
  __line=""
  IFS= read -r __line <"$__file" || true
  case "$__line" in
    manifest_version=*)
      __ver=${__line#manifest_version=}
      case "$__ver" in
        '' | *[!0-9]*)
          log_warn "$(_t 'the ownership manifest version is unreadable; entries were ignored'): $__file ($__line)"
          return 0
          ;;
      esac
      if [ "$__ver" -gt "$_SK_OWN_MANIFEST_VERSION" ]; then
        log_warn "$(_t 'the ownership manifest version is newer than this build understands; entries were ignored'): $__file (v$__ver > v$_SK_OWN_MANIFEST_VERSION)"
        return 0
      fi
      ;;
  esac
  while IFS=$'\t' read -r __rel __sum || [ -n "$__rel" ]; do
    [ -n "$__rel" ] || continue
    # 版本行没有 TAB，不参与条目解析，也不该被记成「损坏」
    case "$__rel" in
      manifest_version=*) continue ;;
    esac
    if [ -z "$__sum" ]; then
      __bad=$((__bad + 1))
      continue
    fi
    _SK_OWN_RELS[${#_SK_OWN_RELS[@]}]=$__rel
    _SK_OWN_SUMS[${#_SK_OWN_SUMS[@]}]=$__sum
  done <"$__file"
  if [ "$__bad" -gt 0 ]; then
    log_warn "$(_t 'the ownership manifest is damaged; entries were ignored'): $__file ($__bad)"
  fi
  return 0
}

# _sk_fs_own_sum REL —— 在已读入的所有权清单里查 REL 的基线指纹；没有就输出空
_sk_fs_own_sum() {
  local __rel=${1:-} __i=0
  [ -n "$__rel" ] || return 0
  while [ "$__i" -lt "${#_SK_OWN_RELS[@]}" ]; do
    if [ "${_SK_OWN_RELS[$__i]}" = "$__rel" ]; then
      printf '%s' "${_SK_OWN_SUMS[$__i]}"
      return 0
    fi
    __i=$((__i + 1))
  done
  return 0
}

# _sk_fs_own_render RELS... —— 把两个平行数组渲染成清单文本（rel TAB sum 每行一条）
# 数组来自 _SK_OWN_RELS / _SK_OWN_SUMS，调用方改完数组后调它拿文本，自己落盘。
_sk_fs_own_render() {
  local __i=0
  # 首行写 schema 版本（issue #78）。三个写入点（_sk_own_sync、skill install、
  # skill uninstall 重写）都经由这里，调用方零改动。
  # 已知的跨版本噪音：v0.18.0 及更早的 _sk_fs_own_read 不认这一行，会把它记成
  # 1 条「损坏」并告警 —— 条目与删除决策不受影响（见 docs/MIGRATING.md）。
  printf 'manifest_version=%s\n' "$_SK_OWN_MANIFEST_VERSION"
  while [ "$__i" -lt "${#_SK_OWN_RELS[@]}" ]; do
    printf '%s\t%s\n' "${_SK_OWN_RELS[$__i]}" "${_SK_OWN_SUMS[$__i]}"
    __i=$((__i + 1))
  done
  return 0
}

# _sk_fs_new_tmp FILE —— 在同目录建临时文件；FILE 存在时连权限一起复制过来
_sk_fs_new_tmp() {
  local __file=$1 __tmp
  __tmp=$(mktemp "$__file.tmp.XXXXXX") || return 1
  if [ -f "$__file" ]; then
    if ! cp -p "$__file" "$__tmp"; then
      rm -f "$__tmp"
      return 1
    fi
  fi
  printf '%s\n' "$__tmp"
  return 0
}

# _sk_fs_has_newline TEXT
_sk_fs_has_newline() {
  if [ "$(printf '%s' "$1" | wc -l)" -ne 0 ]; then
    return 0
  fi
  return 1
}

# fs_ensure_line FILE LINE —— 整行精确匹配；不存在才追加。幂等。
# @exitcode 0 文件已含该行或已写入
# @exitcode 2 参数错（行为空或含换行）
# @exitcode 1 写文件失败
# @stability stable
fs_ensure_line() {
  local __file=${1:-} __line=${2:-} __tmp
  _sk_need_args "$#" 1 "fs_ensure_line FILE LINE" || return $?
  if _sk_fs_dry_run "ensure-line" "$__file"; then
    return 0
  fi
  if [ -z "$__line" ]; then
    log_error "$(_t 'line must not be empty')"
    return "$SK_USAGE"
  fi
  if _sk_fs_has_newline "$__line"; then
    log_error "$(_t 'line must not contain a newline')"
    return "$SK_USAGE"
  fi
  if [ -f "$__file" ]; then
    # 用 ENVIRON 传值：awk -v 会对赋值做转义（\t -> TAB），含反斜杠的行就再也匹配不上自己
    if WANT=$__line awk '$0 == ENVIRON["WANT"] { found = 1 } END { exit found ? 0 : 1 }' "$__file"; then
      return 0
    fi
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(_sk_fs_new_tmp "$__file") || return 1
  if [ -f "$__file" ] && [ -n "$(tail -c 1 "$__file" 2>/dev/null)" ]; then
    printf '\n' >>"$__tmp" || {
      rm -f "$__tmp"
      return 1
    }
  fi
  printf '%s\n' "$__line" >>"$__tmp" || {
    rm -f "$__tmp"
    return 1
  }
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_ensure_block FILE BEGIN END CONTENT —— 标记块内内容整体替换；没有就追加。幂等。
# @exitcode 0 区块已存在或已写入
# @exitcode 2 参数错（区块标识非法）
# @exitcode 1 写文件失败
# @stability stable
fs_ensure_block() {
  local __file=${1:-} __begin=${2:-} __end=${3:-} __content=${4:-}
  local __tmp __cf __src
  _sk_need_args "$#" 3 "fs_ensure_block FILE BEGIN END [CONTENT]" || return $?
  if _sk_fs_dry_run "ensure-block" "$__file"; then
    return 0
  fi
  if [ -z "$__begin" ] || [ -z "$__end" ]; then
    log_error "$(_t 'block markers must not be empty')"
    return "$SK_USAGE"
  fi
  if [ "$__begin" = "$__end" ]; then
    log_error "$(_t 'block markers must differ')"
    return "$SK_USAGE"
  fi
  if _sk_fs_has_newline "$__begin$__end"; then
    log_error "$(_t 'block markers must be single lines')"
    return "$SK_USAGE"
  fi
  fs_ensure_dir "$(dirname "$__file")" "" || return 1
  __tmp=$(_sk_fs_new_tmp "$__file") || return 1
  __cf=$(mktemp "$__file.content.XXXXXX") || {
    rm -f "$__tmp"
    return 1
  }
  if ! printf '%s' "$__content" >"$__cf"; then
    rm -f "$__tmp" "$__cf"
    return 1
  fi
  if [ -f "$__file" ]; then
    __src=$__file
  else
    __src=/dev/null
  fi

  # 标记同样走 ENVIRON：awk -v 会把 \t 之类转义掉，标记就再也匹配不上文件里的原样文本
  if ! B=$__begin E=$__end awk -v cf="$__cf" '
    function emit(   line) {
      if (!emitted && cf != "") {
        while ((getline line < cf) > 0) print line
        close(cf)
        emitted = 1
      }
    }
    BEGIN { inblk = 0; seen = 0; emitted = 0; b = ENVIRON["B"]; e = ENVIRON["E"] }
    !inblk && !seen && $0 == b { inblk = 1; seen = 1; print; next }
    inblk {
      if ($0 == e) { emit(); print e; inblk = 0 }
      next
    }
    { print }
    END {
      if (inblk) { emit(); print e }
      if (!seen) { print b; emit(); print e }
    }
  ' "$__src" >"$__tmp"; then
    rm -f "$__tmp" "$__cf"
    return 1
  fi
  rm -f "$__cf"

  if [ -f "$__file" ] && cmp -s "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 0
  fi
  if ! mv -f "$__tmp" "$__file"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# fs_ensure_symlink TARGET LINK —— 已是正确链接则不动；否者替换（绝不覆盖普通文件）
# @exitcode 0 软链已就位
# @exitcode 2 参数错
# @exitcode 1 建链失败
# @stability stable
fs_ensure_symlink() {
  local __target=${1:-} __link=${2:-} __cur
  _sk_need_args "$#" 2 "fs_ensure_symlink TARGET LINK" || return $?
  if [ -z "$__target" ] || [ -z "$__link" ]; then
    log_error "$(_t 'fs_ensure_symlink requires TARGET and LINK')"
    return "$SK_USAGE"
  fi
  # 守卫放在参数校验之后：干跑也不该把「用法错」吞成成功
  if _sk_fs_dry_run "symlink" "$__target -> $__link"; then
    return 0
  fi
  fs_ensure_dir "$(dirname "$__link")" "" || return 1
  if [ -L "$__link" ]; then
    __cur=$(readlink "$__link" 2>/dev/null || true)
    if [ "$__cur" = "$__target" ]; then
      return 0
    fi
    rm -f "$__link" || return 1
  elif [ -e "$__link" ]; then
    log_error "$(_t 'refusing to replace a non-symlink'): $__link"
    return "$SK_ERR"
  fi
  if ! ln -s "$__target" "$__link"; then
    return 1
  fi
  return 0
}

_sk_tmp_cleanup() {
  if [ -n "${SK_TMPDIR:-}" ] && [ -d "$SK_TMPDIR" ] && [ "${SHELLKIT_TMP_KEEP:-0}" != "1" ]; then
    rm -rf "$SK_TMPDIR"
  fi
  return 0
}

_sk_tmp_base() {
  local __base=${TMPDIR:-/tmp}
  printf '%s\n' "${__base%/}"
}

# fs_tmpdir —— 确保临时目录存在并输出路径。
# 目录名按 UID+进程号确定，因此同一进程内的 $(...) 子 shell 拿到的是同一个目录；
# 它不注册 trap，外部有 EXIT 需求请用 fs_tmp_init。
# @exitcode 0 成功（stdout 输出临时目录路径）
# @exitcode 1 建不了临时目录
# @stability stable
fs_tmpdir() {
  local __base __dir
  if [ -n "${SK_TMPDIR:-}" ] && [ -d "$SK_TMPDIR" ]; then
    printf '%s\n' "$SK_TMPDIR"
    return 0
  fi
  __base=$(_sk_tmp_base)
  __dir="$__base/shellkit-${UID:-0}-$$"
  if [ -L "$__dir" ]; then
    log_error "$(_t 'refusing to use a symlinked temporary directory'): $__dir"
    return "$SK_ERR"
  fi
  if [ ! -d "$__dir" ]; then
    (umask 077 && mkdir -p "$__dir") || return 1
  fi
  SK_TMPDIR=$__dir
  export SK_TMPDIR
  printf '%s\n' "$SK_TMPDIR"
}

# fs_tmp_init —— 在当前 shell 初始化临时目录，并把清理动作推进清理栈。
# 与 0.1.0 的差别：以前「调用方已有 EXIT trap 就放弃清理」，现在改为入栈，
# 与调用方自己的 trap 共存（trap_install 会链式保留已有 EXIT trap）。
# @exitcode 0 成功（初始化当前工程的临时目录）
# @exitcode 1 建不了临时目录
# @stability stable
fs_tmp_init() {
  if ! fs_tmpdir >/dev/null; then
    return 1
  fi
  trap_push '_sk_tmp_cleanup'
  trap_install
  return 0
}
