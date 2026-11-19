#!/usr/bin/env bash
#
# 归档解包。tar / zip 的正确姿势固化在库里，不散落在各项目里。
#
# 为什么要有这一层（证据：真实运维工程里同一段代码手写了十几遍）：
#
#   1. **解压路径穿越**：tar 里的成员名可以是 `../../etc/passwd` 或 `/etc/passwd`。
#      直接 `tar -xzf` 会把文件写到目标目录之外 —— 而且**退出码是 0**，
#      日志里看不出来。这是真实存在的攻击面（解不可信归档）。
#   2. **软链逃逸**：归档里可以放一个指向目标目录之外的软链，再放一个经由它的
#      成员文件 ⇒ 同样写到目录外。
#   3. **管道半截**：`curl ... | tar -xz` 里 curl 中途失败时 tar 收到的是
#      **残缺的输入**，tar 可能报「unexpected EOF」，也可能**解压出一半**。
#      先落盘、校验通过再解，才是对的顺序。
#   4. **判据不一致**：一份工程解包后检查目标文件存在就当成功，另一份检查条数
#      —— 同一批包在不同工程里表现不一样。
#
# 这里的做法：先解到**暂存目录**，验完再**整体换**进目标目录；
# 每个成员路径都过穿越与软链检查；不信任归档里的任何路径。

# _sk_archive_kind FILE —— 打印归档类型：tar | tgz | tbz2 | txz | zip
#
# 不靠扩展名判（扩展名是归档作者写的，不是事实）；按**魔数**判：
# gzip 是 `1f8b`、bzip2 是 `425a68`、xz 是 `fd377a5858`、zip 是 `504b0304`；
# tar 家族是第 257 字节起的 `ustar`。
#
# 为什么还要「tar -tf 兜底」：老式 tar（v7，POSIX 之前）**没有 ustar 魔数**，
# 但它仍然是合法的 tar。只认魔数会把这类包判成「认不出格式」——
# 明明能解开却说不能，是功能缺陷。
#
# 为什么用 od 而不是 dd：dd 那一段里可能有 NUL 字节，bash 会在
# `$(...)` 里丢掉它并往 stderr 打一行 warning（污染日志）。
_sk_archive_kind() {
  local __f=${1:-} __magic=""
  [ -f "$__f" ] || return 1
  __magic=$(od -An -tx1 -N6 "$__f" 2>/dev/null | tr -d ' \n')
  case "$__magic" in
    1f8b*)
      printf 'tgz'
      return 0
      ;;
    425a68*)
      printf 'tbz2'
      return 0
      ;;
    fd377a585a*)
      printf 'txz'
      return 0
      ;;
    504b0304*)
      printf 'zip'
      return 0
      ;;
  esac
  # tar：第 257 字节起是 "ustar"。
  if [ "$(od -An -c -j257 -N5 "$__f" 2>/dev/null | tr -d ' \n')" = "ustar" ]; then
    printf 'tar'
    return 0
  fi
  # v7 老 tar 没有魔数：让 tar 自己认一下（tar 认不出来的就不是 tar）。
  if command -v tar >/dev/null 2>&1 && tar -tf "$__f" >/dev/null 2>&1; then
    printf 'tar'
    return 0
  fi
  return 1
}

# _sk_archive_members FILE KIND OUTFILE —— 把成员清单写进 OUTFILE
#
# 只用**列表**操作读成员名，不解压 —— 列表不写盘。
# zip 用 `unzip -Z1`，tar 家族用 `tar -tf`（tar 自己认压缩格式）。
#
# 清单落盘而不是走命令替换：命令替换会把尾随换行吃掉，也会让含空格的
# 文件名在后续分词里散架。落盘后逐行读，名字原样保留。
_sk_archive_members() {
  local __f=${1:-} __kind=${2:-} __out=${3:-}
  # 返回码分两种：3 = 缺工具（前置条件），5 = 包本身坏了（校验类）。
  # 「列不出成员」归 5 的理由与「解包失败」一样：重试同一个包永远不会成功。
  case "$__kind" in
    zip)
      command -v unzip >/dev/null 2>&1 || return "$SK_PRECOND"
      unzip -Z1 "$__f" >"$__out" 2>/dev/null || return "$SK_VERIFY"
      ;;
    *)
      command -v tar >/dev/null 2>&1 || return "$SK_PRECOND"
      tar -tf "$__f" >"$__out" 2>/dev/null || return "$SK_VERIFY"
      ;;
  esac
  [ -s "$__out" ] || return "$SK_VERIFY"
  return 0
}

# _sk_archive_symlink_targets FILE KIND OUTFILE —— 列出归档里软链成员的目标
#
# 从 `tar -tvf` 的输出里取：软链行以 `l` 开头，目标在 ` -> ` 之后。
# 这个格式在 GNU tar 与 bsdtar 上都是稳定的（POSIX 之外的惯例，但两家一致）。
#
# 分隔符取**第一个没有被转义的** ` -> `：tar 的清单里，名字或目标里
# 字面的 ` -> ` 会被写成 `\ -> `（反斜杠转义），所以第一个没转义的
# 才是真正的分隔符。用贪婪的 sed 匹配会把「目标里含 -> 」的软链截断成
# 后半截 —— 截断后看起来无害，检查就失效了。
#
# 为什么 tar 的输出要先落盘再解析：`tar -tvf ... | sed ...` 的退出码取自
# 管道最后一段（sed 恒为 0）—— tar 自己失败时管道照样返回 0，
# 检查会**无声降级**成「这个包里没有软链」。
#
# zip 存软链的方式各工具不一（多数当普通文件），这一层不覆盖；
# zip 由解完之后的实际文件系统扫描兜底。
_sk_archive_symlink_targets() {
  local __f=${1:-} __kind=${2:-} __out=${3:-} __raw
  case "$__kind" in
    zip) return 1 ;;
    *)
      command -v tar >/dev/null 2>&1 || return 1
      __raw="${__out}.raw"
      tar -tvf "$__f" >"$__raw" 2>/dev/null || {
        rm -f "$__raw"
        return 1
      }
      awk '
        substr($0,1,1) != "l" { next }
        {
          n = length($0); idx = 0
          for (i = 1; i + 3 <= n; i++) {
            if (substr($0,i,4) == " -> " && !(i > 1 && substr($0,i-1,1) == "\\")) { idx = i; break }
          }
          if (idx == 0) next
          # 目标 = " -> " 之后的全部
          target = substr($0, idx + 4)
          # 成员名 = 「 -> 」之前的**最后一个字段**。GNU tar 与 bsdtar 的
          # 元数据字段数不同、日期写法也不同（bsdtar 对旧文件只打日期、不打
          # 时间）⇒ 从尾部取，两边都对。
          # 名字里带空格时会被截短 ⇒ 算出来的目录更浅 ⇒ 「..」更容易被判成
          # 逃逸 ⇒ 判定偏保守（宁可误拒，不可放过）。
          head = substr($0, 1, idx - 1)
          sub(/[ \t]+$/, "", head)
          nf = split(head, __f, /[ \t]+/)
          name = ""
          if (nf > 0) name = __f[nf]
          printf "%s\t%s\n", name, target
        }
      ' "$__raw" >"$__out" 2>/dev/null
      rm -f "$__raw"
      ;;
  esac
  return 0
}

# _sk_archive_member_safe REL —— 成员相对路径是否安全（能解到目标目录之内）
#
# 拒绝：
#   - 绝对路径（`/etc/passwd`）
#   - 含 `..` 的路径（`../x`、`a/../../x`）
#   - 末尾就是 `..`（`a/..` 解出来是目标目录本身）
#   - 空路径
#
# 与 fs 模块的 `_sk_fs_rel_safe` 同口径，但这里额外拒掉末尾的 `..`：
# `a/..` 不含 `/../` 子串，可它解出来就是目标目录本身。
_sk_archive_member_safe() {
  local __rel=${1:-}
  case "$__rel" in
    '' | /*) return 1 ;;
    .. | */..) return 1 ;;
  esac
  case "/$__rel/" in
    */../*) return 1 ;;
  esac
  return 0
}

# _sk_archive_resolve_rel DIR REL —— 词法解析软链目标，算出它落在归档根的哪
#
# DIR 是软链所在目录（相对归档根；根目录传空串），REL 是目标（相对路径）。
# 只做文本层面的 `.` 与 `..` 消解，不碰文件系统 ⇒ 悬空软链也能算准，
# 而且不会因为「目标不存在」而漏判。
#
# 目标走到归档根的外面时返回 1 —— 那就是逃逸。
#
# 为什么不用「拼字符串 + 前缀比较」：`DIR/REL` 只是字符串拼接，
# `a/b/../../etc` 仍然以 `a/b/` 开头 ⇒ 前缀比较会判成「在里面」。
# 必须是**解析之后**的落点才算数。
_sk_archive_resolve_rel() {
  local __dir=${1:-} __rel=${2:-} __stack="" __seg __rest
  # 逐段切分用参数展开（${x%%/*} 取第一段、${x#*/} 取剩下的），
  # **不靠 IFS 分词**：拼接展开（\$a/\$b）的分词结果对「前导分隔符」
  # 的处理并不可靠 —— 实测 bash 3.2 会把开头的 / 吞掉，首段直接粘上下一段，
  # 于是 ".." 少算一跳，逃逸的软链会被判成安全。
  __rest="/$__dir/$__rel"
  while [ -n "$__rest" ]; do
    case "$__rest" in
      */*)
        __seg=${__rest%%/*}
        __rest=${__rest#*/}
        ;;
      *)
        __seg=$__rest
        __rest=""
        ;;
    esac
    case "$__seg" in
      '' | '.') continue ;;
      '..')
        # 根目录之上 ⇒ 逃出归档
        if [ -z "$__stack" ]; then
          return 1
        fi
        __stack=${__stack%/*}
        ;;
      *) __stack="$__stack/$__seg" ;;
    esac
  done
  printf '%s' "${__stack#/}"
  return 0
}

# _sk_archive_merge DST SRC WINNER —— 把 SRC 的内容并进 DST
#
# WINNER=dst ⇒ 同名以 DST 为准（SRC 的同名项被丢弃）
# WINNER=src ⇒ 同名以 SRC 为准（DST 的同名项被替换）
#
# 目录对目录时递归下去比；类型不同（文件对目录）时按 WINNER 处理。
#
# 为什么不用一条 `mv`：BSD/GNU 的 mv 在「目标已有同名非空目录」时报
# `Directory not empty` 直接失败 —— 于是**前面几项已经搬进去了**，
# 目标目录停在新旧混合的状态，而整体却返回失败。
# 递归合并让「同名目录」不再是错误 —— 它是覆盖语义的一部分。
_sk_archive_merge() {
  local __dst=${1:-} __src=${2:-} __win=${3:-dst} __list __e __name
  [ -d "$__src" ] || return 0
  [ -d "$__dst" ] || return 1
  __list=$(mktemp "${TMPDIR:-/tmp}/shellkit-archive-merge.XXXXXX") || return 1
  find "$__src" -mindepth 1 -maxdepth 1 -print0 >"$__list" 2>/dev/null
  while IFS= read -r -d '' __e; do
    [ -n "$__e" ] || continue
    __name=${__e##*/}
    if [ ! -e "$__dst/$__name" ] && [ ! -L "$__dst/$__name" ]; then
      mv "$__e" "$__dst/" 2>/dev/null || {
        rm -f "$__list"
        return 1
      }
      continue
    fi
    if [ -d "$__e" ] && [ ! -L "$__e" ] && [ -d "$__dst/$__name" ] && [ ! -L "$__dst/$__name" ]; then
      _sk_archive_merge "$__dst/$__name" "$__e" "$__win" || {
        rm -f "$__list"
        return 1
      }
      continue
    fi
    # 同名且不是「目录对目录」⇒ 类型冲突（目录 ↔ 文件/软链）。
    # 覆盖语义下这会连带删掉一个目录里的内容 —— 说出来，不静默。
    if [ -d "$__e" ] && [ ! -d "$__dst/$__name" ]; then
      log_warn "$(_t 'a path with a different type existed at the destination'): $__dst/$__name"
    elif [ ! -d "$__e" ] && [ -d "$__dst/$__name" ]; then
      log_warn "$(_t 'a path with a different type existed at the destination'): $__dst/$__name"
    fi
    if [ "$__win" = "src" ]; then
      # 同名且类型不同 ⇒ 归档那份赢：先把旧的挪掉再搬新的
      case "$__name" in
        '.' | '..') continue ;;
      esac
      rm -rf "${__dst:?}/$__name" 2>/dev/null
      mv "$__e" "$__dst/" 2>/dev/null || {
        rm -f "$__list"
        return 1
      }
    fi
  done <"$__list"
  rm -f "$__list"
  return 0
}

# _sk_archive_missing_decompressor KIND —— 打印这个格式缺的解压器（空 = 没缺）
#
# 只有 GNU tar 才查：GNU tar 靠**外部程序**解压（gzip / bzip2 / xz），
# bsdtar 自带 liblzma / libbz2 ⇒ 系统里没有 xz 也不影响它解开。
# 判据是「缺了解压器」（3，前置条件）还是「包坏了」（5，校验失败）：
# 重试同一个包永远解不开，但换个环境能解开 —— 调用方该知道是哪种。
_sk_archive_missing_decompressor() {
  local __kind=${1:-} __need="" __tarver
  case "$__kind" in
    tgz) __need=gzip ;;
    tbz2) __need=bzip2 ;;
    txz) __need=xz ;;
    *) return 0 ;;
  esac
  __tarver=$(tar --version 2>/dev/null)
  case "$__tarver" in
    *"GNU tar"*) ;;
    *) return 0 ;;
  esac
  command -v "$__need" >/dev/null 2>&1 || printf '%s' "$__need"
  return 0
}

# _sk_archive_tail_nonzero FILE KIND —— 打印 tar 流末尾 1024 字节里的非零字节数
#
# 0 = tar 的结尾标记齐全（末尾两块 512 字节的零）；非 0 = 流在中途断了，
# 或者尾部有别的数据。
#
# 压缩格式要先解压才看得到 tar 流的尾巴 —— 多一遍解压，换的是
# 「结论与 tar 的实现无关」。
_sk_archive_tail_nonzero() {
  local __f=${1:-} __kind=${2:-}
  case "$__kind" in
    tar)
      tail -c 1024 "$__f" 2>/dev/null | tr -d '\000' | wc -c | tr -d ' '
      ;;
    tgz)
      gzip -dc "$__f" 2>/dev/null | tail -c 1024 | tr -d '\000' | wc -c | tr -d ' '
      ;;
    tbz2)
      bzip2 -dc "$__f" 2>/dev/null | tail -c 1024 | tr -d '\000' | wc -c | tr -d ' '
      ;;
    txz)
      xz -dc "$__f" 2>/dev/null | tail -c 1024 | tr -d '\000' | wc -c | tr -d ' '
      ;;
    *)
      printf '0'
      ;;
  esac
}

# _sk_archive_is_truncated FILE KIND —— 包缺 tar 结尾标记时返回 0（是截断的）
#
# 为什么必须自己查，不能只看 tar 的退出码：**GNU tar 读到 EOF 就当
# 「归档到此为止」，照样退出 0** —— 于是一个被截断的包会被当成
# 「只有前几个成员的包」静默解开 ⇒ 半份内容被装上，而调用方拿到的是成功。
# bsdtar 恰好更严（同一个包在 macOS 上会红），但「同一份代码在不同 tar
# 实现上给出不同结论」本身就是缺陷 —— 判据必须与实现无关。
#
# zip 不走这条路：它的中央目录在尾部，unzip 自己就会报错。
# 压缩格式且解压器不在 ⇒ 查不了 ⇒ 只能指望 tar 自己严格（见
# _sk_archive_missing_decompressor）。
_sk_archive_is_truncated() {
  local __f=${1:-} __kind=${2:-} __n
  [ -n "$__f" ] || return 1
  case "$__kind" in
    tar) ;;
    tgz)
      command -v gzip >/dev/null 2>&1 || return 1
      ;;
    tbz2)
      command -v bzip2 >/dev/null 2>&1 || return 1
      ;;
    txz)
      command -v xz >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  __n=$(_sk_archive_tail_nonzero "$__f" "$__kind")
  [ "$__n" = "0" ] && return 1
  return 0
}

# archive_list ARCHIVE —— 打印归档里的成员清单（相对路径，每行一个）
#
# 只读不解：不写盘、不建目录。用来「先看看包里有什么」再决定解不解。
#
# @exitcode 0 列出成功
# @exitcode 2 参数错
# @exitcode 3 归档不存在、格式认不出，或缺 tar/unzip
# @exitcode 5 归档列不出成员（包本身坏了）
# @stability experimental
archive_list() {
  local __f=${1:-} __kind __tmp __rc=0
  _sk_need_args "$#" 1 "archive_list ARCHIVE" || return $?
  if [ ! -f "$__f" ]; then
    log_error "$(_t 'archive not found'): $__f"
    return "$SK_PRECOND"
  fi
  __kind=$(_sk_archive_kind "$__f") || {
    log_error "$(_t 'cannot recognize the archive format'): $__f"
    return "$SK_PRECOND"
  }
  __tmp=$(mktemp "${TMPDIR:-/tmp}/shellkit-archive-list.XXXXXX") || {
    log_error "$(_t 'cannot create a temporary file')"
    return "$SK_PRECOND"
  }
  _sk_archive_members "$__f" "$__kind" "$__tmp"
  __rc=$?
  if [ "$__rc" -ne 0 ]; then
    rm -f "$__tmp"
    __missing=$(_sk_archive_missing_decompressor "$__kind")
    if [ -n "$__missing" ]; then
      log_error "$(_t 'the decompressor for this archive format is not available'): $__missing"
      return "$SK_PRECOND"
    fi
    log_error "$(_t 'cannot list the archive'): $__f"
    return "$__rc"
  fi
  if _sk_archive_is_truncated "$__f" "$__kind"; then
    rm -f "$__tmp"
    log_error "$(_t 'the archive is truncated or has trailing data'): $__f"
    return "$SK_VERIFY"
  fi
  cat "$__tmp"
  rm -f "$__tmp"
  return 0
}

# archive_extract ARCHIVE DEST [EXPECTED_SHA256] —— 安全解包
#
# 解到 DEST（不存在就建）。流程：
#
#   1. 校验魔数，认出格式；
#   2. 可选：先核对 sha256（给了就必须对上，对不上一个字节都不解）；
#   3. 查成员名的路径穿越 —— 归档里带穿越路径时**连解都不解**；
#   4. 查归档里声明的软链 —— 绝对目标**连解都不解**；
#   5. 解到**暂存目录**（不是直接解到 DEST）；
#   6. 扫解出来的文件系统，软链兜底再查一遍（这一遍是权威判据）；
#   7. 全通过才**整体换**进 DEST。
#
# 解之前还要查一件事：**结尾标记**。tar 流末尾必须有两块 512 字节的零，
# 缺了就是被截断了。GNU tar 读到 EOF 就当「归档到此为止」、照样退出 0 ⇒
# 截断的包会被静默解成「只有前几个成员的包」⇒ 半份内容被装上，而调用方
# 拿到的是成功。查结尾标记 ⇒ 结论与 tar 的实现无关（bsdtar 更严、GNU tar
# 更松，同一份包在两边给出不同答案本身就是缺陷）。
#
# 为什么先解到暂存目录：tar 解到一半失败（磁盘满、成员损坏）时，
# 直接解到目标目录会留下**半份内容** —— 而调用方看到的是「目录存在了」。
# 半份内容比没有更危险：脚本会接着往下跑，读到截断的二进制。
#
# 为什么第 7 步是「整体换」而不是「逐项搬」：逐项搬在中途失败时，
# 目标目录会停在新旧混合的状态（前面几项已经进去了）。整体换是两次
# rename —— 目标目录要么是旧的、要么是新的，不会混。
#
# 覆盖语义：包里有的路径以包为准；包里没有的旧文件保留。
#
# 目标目录是软链或不是目录时一律拒绝（不顺着软链写，也不覆盖普通文件）。
#
# 已知边界：解包只保证「**包里的东西**逃不出去」，不保证「目标目录本来
# 就干净」—— 调用方自己放在目标目录里的软链是它自己的数据，覆盖安装
# 后会原样保留（指向归档之外也照样保留）。要清就自己先清一遍。
#
# 目标目录是只读（555）时：新内容照常装上去，目录权限也照原样保留；
# 但**旧文件搬不回去**（那个目录不可写）⇒ 退 5 并把旧目录的位置报出来。
# root 不受权限限制 ⇒ 那种环境里旧文件能搬回去 ⇒ 退 0。
#
# 进程被强杀可能留下两处残留，都能安全处理：
#   - `<目标目录的父目录>/.shellkit-extract.XXXXXX`：暂存目录（可能半份）；
#   - `<目标目录的父目录>/.shellkit-old.XXXXXX`：换上去的瞬间被挪开的旧目录
#     —— 这一处是**旧目标目录本身**，目标目录此刻可能整个不存在，
#     把它改名搬回去即可恢复。
#   - `<目标目录>/.shellkit-stage.XXXXXX`：父目录不可写时的降级暂存目录
#     —— 它落在**目标目录里面**，强杀后残留会出现在用户的安装目录里。
#
# @exitcode 0 解包成功
# @exitcode 2 参数错
# @exitcode 3 归档不存在、格式认不出，缺 tar/unzip，或目标目录不可用
# @exitcode 5 校验和不匹配，成员列不出来，归档里有不安全路径 / 软链，解包失败，
#             旧内容没搬回去，或目标目录权限没能还原
# @stability experimental
archive_extract() {
  local __f=${1:-} __dest=${2:-} __expect=${3:-} __kind __work="" __meta __stage __old
  local __list __targets __links __bad __rel __link __target __member __dir __parent __mode __missing
  local __atomic=1 __rc=0 __dry=0 __restore_failed=0 __perm_failed=0
  _sk_need_args "$#" 2 "archive_extract ARCHIVE DEST [SHA256]" || return $?

  if [ ! -f "$__f" ]; then
    log_error "$(_t 'archive not found'): $__f"
    return "$SK_PRECOND"
  fi

  # 校验先于一切：对不上就一个字节都不解
  if [ -n "$__expect" ]; then
    if ! net_verify "$__f" "$__expect" >/dev/null 2>&1; then
      log_error "$(_t 'the checksum does not match'): $__f"
      return "$SK_VERIFY"
    fi
  fi

  __kind=$(_sk_archive_kind "$__f") || {
    log_error "$(_t 'cannot recognize the archive format'): $__f"
    return "$SK_PRECOND"
  }

  # 目标目录：软链与非目录一律拒绝
  if [ -L "$__dest" ]; then
    log_error "$(_t 'the destination is a symlink'): $__dest"
    return "$SK_PRECOND"
  fi
  if [ -e "$__dest" ] && [ ! -d "$__dest" ]; then
    log_error "$(_t 'the destination is not a directory'): $__dest"
    return "$SK_PRECOND"
  fi

  # 演练：一个字节都不写。守卫放在目标校验之后（干跑也不该把「目标不可用」
  # 吞成成功），但**返回点**在安全检查之后 —— 干跑也要把「这个包安不安全」
  # 判出来：演练说安全、真跑被拒，演练就失去了意义。
  __dry=0
  if _sk_fs_dry_run "extract" "$__f -> $__dest"; then
    __dry=1
  fi

  # 记下旧目录的权限：整体换上去之后要还原（暂存目录是 0700 的）
  __mode=""
  if [ -d "$__dest" ]; then
    __mode=$(stat -c '%a' "$__dest" 2>/dev/null) || __mode=""
    if [ -z "$__mode" ]; then
      __mode=$(stat -f '%Lp' "$__dest" 2>/dev/null) || __mode=""
    fi
  fi
  [ -n "$__mode" ] || __mode="755"

  # 去掉尾部斜杠：dirname "dest/" 返回 "."，暂存目录会落到当前目录而不是 dest 旁边
  while [ -n "$__dest" ] && [ "${__dest%/}" != "$__dest" ]; do
    __dest=${__dest%/}
  done
  __parent=$(dirname "$__dest")

  # 清单文件放在暂存目录之外：搬内容时不能被一起搬走。
  __meta=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-archive-meta.XXXXXX") || {
    log_error "$(_t 'cannot create a temporary directory')"
    return "$SK_PRECOND"
  }
  __list="$__meta/members"
  __targets="$__meta/targets"
  __links="$__meta/links"
  __bad="$__meta/bad"

  # 第一遍：查成员名的路径穿越（在解之前 —— 有穿越就不解）
  _sk_archive_members "$__f" "$__kind" "$__list"
  __rc=$?
  if [ "$__rc" -ne 0 ]; then
    rm -rf "$__meta"
    __missing=$(_sk_archive_missing_decompressor "$__kind")
    if [ -n "$__missing" ]; then
      log_error "$(_t 'the decompressor for this archive format is not available'): $__missing"
      return "$SK_PRECOND"
    fi
    log_error "$(_t 'cannot list the archive'): $__f"
    return "$__rc"
  fi
  # 结尾标记必须齐全：GNU tar 读到 EOF 就当归档结束、照样退出 0 ⇒
  # 截断的包会被静默解成「只有前几个成员」⇒ 半份内容被装上而调用方拿到成功
  if _sk_archive_is_truncated "$__f" "$__kind"; then
    rm -rf "$__meta"
    log_error "$(_t 'the archive is truncated or has trailing data'): $__f"
    return "$SK_VERIFY"
  fi
  : >"$__bad"
  while IFS= read -r __rel; do
    [ -n "$__rel" ] || continue
    # 目录成员通常以 / 结尾，去掉再判
    __rel=${__rel%/}
    [ -n "$__rel" ] || continue
    if ! _sk_archive_member_safe "$__rel"; then
      printf '%s\n' "$__rel" >>"$__bad"
    fi
  done <"$__list"
  if [ -s "$__bad" ]; then
    # 明细先打出来，再清理：$__bad 就在 $__meta 里，先删就永远打不出来
    log_error "$(_t 'the archive contains unsafe paths and was not extracted'): $__f"
    while IFS= read -r __rel; do
      log_error "  $__rel"
    done <"$__bad"
    rm -rf "$__meta"
    return "$SK_VERIFY"
  fi

  # 第二遍：查归档里声明的软链目标（仍在解之前）
  # 绝对目标一律拒绝 —— 归档里的绝对软链不可能落在归档之内。
  _sk_archive_symlink_targets "$__f" "$__kind" "$__targets" 2>/dev/null || true
  : >"$__bad"
  if [ -s "$__targets" ]; then
    while IFS=$'\t' read -r __member __target; do
      [ -n "$__target" ] || continue
      case "$__target" in
        /*)
          # 绝对目标：归档里的绝对软链不可能落在归档之内
          printf '%s\n' "${__member:-$__target}" >>"$__bad"
          continue
          ;;
      esac
      # 相对目标：按**它自己所在目录**做词法解析（与第三遍同一口径）。
      # 解析后落在归档根之外 ⇒ 逃逸 ⇒ 解之前就拒。
      # 成员名解析不出来（tar 的输出形状变了）⇒ 跳过，交给第三遍兜底：
      # 这一遍是**加一层**，误拒比漏放更糟。
      [ -n "$__member" ] || continue
      __dir=${__member%/*}
      [ "$__dir" = "$__member" ] && __dir=""
      if ! _sk_archive_resolve_rel "$__dir" "$__target" >/dev/null 2>&1; then
        printf '%s\n' "$__member" >>"$__bad"
      fi
    done <"$__targets"
  fi
  if [ -s "$__bad" ]; then
    # 明细先打出来，再清理（$__bad 在 $__meta 里）
    log_error "$(_t 'the archive contains unsafe symlinks and was not extracted'): $__f"
    while IFS= read -r __rel; do
      log_error "  $__rel"
    done <"$__bad"
    rm -rf "$__meta"
    return "$SK_VERIFY"
  fi

  # 演练到这里收尾：安全检查都过了（不安全的包在干跑下同样被拒），
  # 目标目录一个字节都没动 —— 连暂存目录都没建过。
  if [ "$__dry" = "1" ]; then
    rm -rf "$__meta"
    return 0
  fi

  # 建父目录与暂存目录：优先放在 DEST 的同级（同文件系统 ⇒ 最后是 rename
  # 而不是跨设备复制）
  fs_ensure_dir "$__parent" "" >/dev/null 2>&1 || true
  __work=$(mktemp -d "$__parent/.shellkit-extract.XXXXXX" 2>/dev/null) || __work=""
  if [ -z "$__work" ]; then
    # 父目录不可写 ⇒ 退化为就地合并（同样的语义，但不保证原子）
    __atomic=0
    if [ -d "$__dest" ]; then
      __work=$(mktemp -d "$__dest/.shellkit-stage.XXXXXX" 2>/dev/null) || __work=""
    fi
    if [ -z "$__work" ]; then
      __work=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-extract.XXXXXX") || {
        rm -rf "$__meta"
        log_error "$(_t 'cannot create a temporary directory')"
        return "$SK_PRECOND"
      }
    fi
  fi

  # 解到暂存目录
  case "$__kind" in
    zip)
      command -v unzip >/dev/null 2>&1 || {
        rm -rf "$__work" "$__meta"
        log_error "$(_t 'unzip is required to extract zip archives')"
        return "$SK_PRECOND"
      }
      unzip -q "$__f" -d "$__work" >/dev/null 2>&1 || __rc=$?
      ;;
    tar) tar -xf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$? ;;
    tgz) tar -xzf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$? ;;
    tbz2) tar -xjf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$? ;;
    txz) tar -xJf "$__f" -C "$__work" >/dev/null 2>&1 || __rc=$? ;;
    *)
      rm -rf "$__work" "$__meta"
      log_error "$(_t 'cannot recognize the archive format'): $__f"
      return "$SK_PRECOND"
      ;;
  esac
  if [ "$__rc" -ne 0 ]; then
    # 解包失败归成 **5（校验失败）**而不是 4（网络失败）：
    # 失败原因是「这个包不可信或不可用」，重试同一个包永远不会成功，
    # 而 4 会让调用方以为「重试有用」。
    rm -rf "$__work" "$__meta"
    log_error "$(_t 'cannot extract the archive'): $__f"
    return "$SK_VERIFY"
  fi
  # 权限**不**在解完之后就套到暂存目录上。暂存目录必须保持可写直到
  # rename 完成：**macOS 上重命名一个不可写的目录会失败**（内核要改写目录里
  # 的 ".." 条目）⇒ 源目录是 555 时两次 rename 里有一次必然失败 ⇒ 退化成
  # 就地合并 ⇒ 而就地合并写不进只读目录 ⇒ 好包被判成坏包（退 5）。
  # 目标目录的权限在**换上去之后**再套（见下面的 swap 段）。

  # 第三遍：扫解出来的文件系统，软链兜底再查一遍
  # （清单里说不清的情况：zip 里的软链、或实现自己改了名字的）
  # 这一遍是**权威判据**：每个软链按它自己所在目录解析目标，
  # 解析后落在暂存目录之外就是逃逸。
  : >"$__bad"
  find "$__work" -type l -print0 >"$__links" 2>/dev/null
  while IFS= read -r -d '' __link; do
    [ -n "$__link" ] || continue
    __rel=${__link#"$__work"/}
    __target=$(readlink "$__link" 2>/dev/null) || continue
    case "$__target" in
      /*)
        printf '%s\n' "$__rel" >>"$__bad"
        continue
        ;;
    esac
    __dir=${__rel%/*}
    [ "$__dir" = "$__rel" ] && __dir=""
    if ! _sk_archive_resolve_rel "$__dir" "$__target" >/dev/null 2>&1; then
      printf '%s\n' "$__rel" >>"$__bad"
    fi
  done <"$__links"
  if [ -s "$__bad" ]; then
    # 明细先打出来，再清理（$__bad 在 $__meta 里）
    log_error "$(_t 'the extracted files contain a symlink that escapes the destination'): $__f"
    while IFS= read -r __rel; do
      log_error "  $__rel"
    done <"$__bad"
    rm -rf "$__work" "$__meta"
    return "$SK_VERIFY"
  fi

  # 换进目标目录
  if [ "$__atomic" = "1" ]; then
    # 旧目录先整体挪开，再把暂存目录换到那个名字上 —— 两次 rename。
    __old=""
    if [ -d "$__dest" ]; then
      __old=$(mktemp -d "$__parent/.shellkit-old.XXXXXX" 2>/dev/null) || __old=""
      if [ -n "$__old" ]; then
        rmdir "$__old" 2>/dev/null
        # 搬走之前临时给旧目录加 u+w：**macOS 上重命名一个不可写的目录会失败**
        # （内核要改写目录里的 ".." 条目）⇒ 目标目录是 555 时旧目录搬不走 ⇒
        # 只能退化成就地合并 ⇒ 而就地合并写不进只读目录 ⇒ 好包被判成坏包。
        # 权限在下面改回原样（无论旧目录是被删掉、被搬回去，还是被留在原地）。
        chmod u+w "$__dest" 2>/dev/null || true
        mv "$__dest" "$__old" 2>/dev/null || {
          chmod "$__mode" "$__dest" 2>/dev/null || true
          __old=""
        }
      fi
      if [ -z "$__old" ]; then
        # 挪不开旧目录 ⇒ 退化为就地合并
        __atomic=0
      fi
    fi
    if [ "$__atomic" = "1" ]; then
      if ! mv "$__work" "$__dest" 2>/dev/null; then
        # 换不上去 ⇒ 旧目录放回去，目标目录保持原样
        if [ -n "$__old" ]; then
          if mv "$__old" "$__dest" 2>/dev/null; then
            # 放回去了 ⇒ 把权限改回原样（我们刚才临时加了 u+w）
            chmod "$__mode" "$__dest" 2>/dev/null || true
            rm -rf "$__old"
          else
            # 旧目录放不回去 ⇒ **绝对不能删**（那是用户的数据）：
            # 留在原地并把位置报出来，让人自己捡回去。
            log_error "$(_t 'the old destination could not be restored, it is left at'): $__old"
            chmod "$__mode" "$__old" 2>/dev/null || true
          fi
        fi
        rm -rf "$__work" "$__meta"
        log_error "$(_t 'cannot move the extracted files into the destination'): $__dest"
        return "$SK_VERIFY"
      fi
      __work=""
      # 换上去之后再套权限：rename 已经完成（暂存目录全程保持可写），
      # 而目标路径此刻就是我们的 ⇒ 权限可以照原样还原。
      # 还原不了就是「装出来的目录权限不对」⇒ 说出来，别当成装好了。
      if ! chmod "$__mode" "$__dest" 2>/dev/null; then
        log_error "$(_t 'the destination permissions could not be restored'): $__dest"
        __perm_failed=1
      fi
      # 旧目录里目标没有的路径搬回去（包里有的以包为准）
      if [ -n "$__old" ]; then
        # 不吞 stderr：类型冲突的告警要从这里冒出去（吞掉就成了静默覆盖）
        if _sk_archive_merge "$__dest" "$__old" "dst"; then
          rm -rf "$__old"
        else
          # 合并失败 ⇒ **不能删** __old：里面是还没搬回去的旧文件，
          # 删了就永久没了。留在原地并把位置报出来，让人自己捡回去。
          # 也不能报成功：调用方按退出码判断 ⇒ 报 0 就是「装好了」，
          # 而目标目录里其实缺了旧文件（半份安装被当成完整安装）。
          log_error "$(_t 'the old destination could not be restored, it is left at'): $__old"
          # 旧目录被留在原地 ⇒ 把它的权限改回原样（我们搬它之前临时加了 u+w）
          chmod "$__mode" "$__old" 2>/dev/null || true
          __restore_failed=1
        fi
      fi
    fi
  fi

  if [ "$__atomic" = "0" ]; then
    # 就地合并：包里有的以包为准，包里没有的旧文件保留
    if ! fs_ensure_dir "$__dest" ""; then
      rm -rf "$__work" "$__meta"
      log_error "$(_t 'cannot create the destination directory'): $__dest"
      return "$SK_PRECOND"
    fi
    if ! _sk_archive_merge "$__dest" "$__work" "src"; then
      rm -rf "$__work" "$__meta"
      log_error "$(_t 'cannot move the extracted files into the destination'): $__dest"
      return "$SK_VERIFY"
    fi
    rm -rf "$__work"
  fi

  rm -rf "$__meta"
  # 旧内容没搬回去 ⇒ 退 5（与降级路径的合并失败同一口径）：
  # 「返回码就是接口的一部分」—— 失败却报成功，调用方无从分辨。
  if [ "$__restore_failed" = "1" ]; then
    return "$SK_VERIFY"
  fi
  # 权限没还原 ⇒ 装出来的目录权限不对 ⇒ 不能报成功
  if [ "$__perm_failed" = "1" ]; then
    return "$SK_VERIFY"
  fi
  return 0
}
