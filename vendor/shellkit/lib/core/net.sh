#!/usr/bin/env bash
# 网络：下载（带校验与镜像回退）与就绪探测。

# net_sha256 FILE —— 文件的 sha256；两种工具都没有时返回 1
# @exitcode 0 成功（stdout 输出校验和）
# @exitcode 2 参数错
# @exitcode 1 算不出校验和
# @stability experimental
net_sha256() {
  _sk_need_args "$#" 1 "net_sha256 FILE" || return $?
  os_sha256 "$1"
}

# net_verify FILE SHA256 —— 校验文件的 sha256；对不上返回 SK_VERIFY(5)
# @exitcode 0 校验通过
# @exitcode 2 参数错
# @exitcode 5 校验和不匹配，或算不出校验和
# @stability experimental
net_verify() {
  local __file=${1:-} __expect=${2:-} __actual
  _sk_need_args "$#" 2 "net_verify FILE SHA256" || return $?
  if [ -z "$__expect" ]; then
    log_error "$(_t 'no checksum configured for'): $__file"
    return "$SK_VERIFY"
  fi
  __actual=$(net_sha256 "$__file") || {
    log_error "$(_t 'cannot compute checksum for'): $__file"
    return "$SK_VERIFY"
  }
  if [ "$__actual" != "$__expect" ]; then
    log_error "$(_t 'checksum mismatch for'): $__file"
    log_debug "expected=$__expect actual=$__actual"
    return "$SK_VERIFY"
  fi
  return 0
}

_sk_download_raw() {
  local __url=$1 __dest=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 900 -o "$__dest" "$__url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -t 2 -O "$__dest" "$__url"
  else
    log_error "$(_t 'curl or wget is required to download')"
    return "$SK_PRECOND"
  fi
}

# net_download URL DEST [SHA256] —— 下载并可选校验 sha256；已有本地缓存且校验通过就不重下
# @exitcode 0 下载成功（带 SHA256 时校验通过）
# @exitcode 2 参数错
# @exitcode 3 没有 curl 或 wget
# @exitcode 4 下载失败
# @exitcode 5 校验和不匹配
# @exitcode 1 写文件失败
# @stability experimental
net_download() {
  local __url=${1:-} __dest=${2:-} __expect=${3:-} __tmp __alt
  _sk_need_args "$#" 2 "net_download URL DEST [SHA256]" || return $?
  fs_ensure_dir "$(dirname "$__dest")" "" || return 1

  if [ -f "$__dest" ]; then
    if [ -z "$__expect" ]; then
      log_debug "$(_t 'using cached file'): $__dest"
      return 0
    fi
    if net_verify "$__dest" "$__expect" >/dev/null 2>&1; then
      log_debug "$(_t 'using cached file'): $__dest"
      return 0
    fi
    log_warn "$(_t 'cached file is invalid, re-downloading'): $__dest"
    rm -f "$__dest"
  fi

  log_info "$(_t 'downloading'): $__url"
  __tmp="$__dest.part.$$"
  rm -f "$__tmp"

  if ! _sk_download_raw "$__url" "$__tmp"; then
    if [ -n "${SHELLKIT_MIRROR_FROM:-}" ] && [ -n "${SHELLKIT_MIRROR_TO:-}" ]; then
      case "$__url" in
        "${SHELLKIT_MIRROR_FROM}"*)
          __alt="${SHELLKIT_MIRROR_TO}${__url#${SHELLKIT_MIRROR_FROM}}"
          log_warn "$(_t 'retrying via mirror'): $__alt"
          if ! _sk_download_raw "$__alt" "$__tmp"; then
            rm -f "$__tmp"
            log_error "$(_t 'download failed'): $__url"
            return "$SK_NET"
          fi
          ;;
        *)
          rm -f "$__tmp"
          log_error "$(_t 'download failed'): $__url"
          return "$SK_NET"
          ;;
      esac
    else
      rm -f "$__tmp"
      log_error "$(_t 'download failed'): $__url"
      return "$SK_NET"
    fi
  fi

  if [ -n "$__expect" ] && ! net_verify "$__tmp" "$__expect"; then
    rm -f "$__tmp"
    return "$SK_VERIFY"
  fi
  if ! mv -f "$__tmp" "$__dest"; then
    rm -f "$__tmp"
    return 1
  fi
  return 0
}

# net_wait_port HOST PORT [TIMEOUT] —— 等端口可连；超时返回 SK_NET(4)
# @exitcode 0 端口已就绪
# @exitcode 2 参数错
# @exitcode 4 超时仍未就绪
# @stability experimental
net_wait_port() {
  local __host=${1:-} __port=${2:-} __timeout=${3:-30} __i=0
  _sk_need_args "$#" 2 "net_wait_port HOST PORT [TIMEOUT]" || return $?
  while [ "$__i" -lt "$__timeout" ]; do
    # 只在子 shell 里开连接：exec 的重定向会落到调用方的 shell 上，
    # 以前那行 `exec 3>&- 2>/dev/null` 既关了别人的 fd 3，也把别人的 stderr 永久丢进 /dev/null。
    if (: <"/dev/tcp/$__host/$__port") 2>/dev/null; then
      return 0
    fi
    sleep 1
    __i=$((__i + 1))
  done
  return "$SK_NET"
}

# net_wait_http URL [TIMEOUT] —— 等 HTTP 可用；超时返回 SK_NET(4)
# @exitcode 0 HTTP 已就绪
# @exitcode 2 参数错
# @exitcode 3 没有 curl
# @exitcode 4 超时仍未就绪
# @stability experimental
net_wait_http() {
  local __url=${1:-} __timeout=${2:-30} __i=0
  _sk_need_args "$#" 1 "net_wait_http URL [TIMEOUT]" || return $?
  if ! command -v curl >/dev/null 2>&1; then
    log_error "$(_t 'curl is required for HTTP probing')"
    return "$SK_PRECOND"
  fi
  while [ "$__i" -lt "$__timeout" ]; do
    if curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 "$__url" 2>/dev/null; then
      return 0
    fi
    sleep 1
    __i=$((__i + 1))
  done
  return "$SK_NET"
}

# ---------------------------------------------------------------------------
# 版本检查与升级提示（issue #67）
# ---------------------------------------------------------------------------
# _sk_update_hint_cache —— 版本检查缓存的路径；拿不到家目录时返回 1
#
# 缓存记两件事：上次检查的时间、上次查到的最新版本（查不到就留空）。
# 时间是关键：联网失败也记时间，这样没网的机器一周最多被卡一次超时，
# 而不是每次调用都白等一遍。
_sk_update_hint_cache() {
  local __root=${XDG_CACHE_HOME:-}
  [ -n "$__root" ] || __root=${HOME:-}/.cache
  [ -n "${HOME:-}${XDG_CACHE_HOME:-}" ] || return 1
  printf '%s' "$__root/shellkit/version-check"
}

# _sk_update_hint —— 有新版本就给一条提示；其余情况一律不出声
#
# issue #67 的三条纪律：
#   1. 「是不是交互式终端」由调用方判（shellkit 的分发处），本函数只判
#      「值不值得提示」—— 这样逻辑能被直接调用来测，不用伪造 tty。
#   2. 缓存七天有效：缓存新鲜就不联网，联网是例外而不是常态。
#   3. 联网失败静默返回 —— 无网的机器不能因为一条提示而报错或卡住。
# 只给**装出来的副本**提示：git 检出的那份跑 update 会去装到 /usr/local，
# 对它说「跑 shellkit update」是误导（原单说的是「已装副本」）。
# @exitcode 0 总是成功 —— 提示绝不能影响被调用命令的退出码
_sk_update_hint() {
  local __prefix=${1:-} __cur __cache __now __epoch="" __latest="" __line=""
  local __check=1 __age=0
  # PREFIX 是调用方判定好的「已装副本」前缀；空 = 不是已装副本，不出声。
  # 判定留在 CLI 侧：前缀怎么来是安装布局的事，不是网络层的事 ——
  # 挪进库里的话，库自己没有判断安装布局的依据。
  [ -n "$__prefix" ] || return 0
  if [ -n "${SHELLKIT_NO_UPDATE_HINT:-}" ]; then
    return 0
  fi
  __cur=${SK_VERSION:-}
  [ -n "$__cur" ] || return 0
  __cache=$(_sk_update_hint_cache) || return 0
  __now=$(date +%s 2>/dev/null) || return 0
  if [ -f "$__cache" ]; then
    IFS=$'\t' read -r __epoch __latest <"$__cache" || true
    case "$__epoch" in
      '' | *[!0-9]*) __epoch=0 ;;
    esac
    __age=$((__now - __epoch))
    # 时钟回拨时按 0 算：宁可多查一次，也不把缓存当成永远新鲜
    [ "$__age" -ge 0 ] || __age=0
    if [ "$__age" -lt 604800 ]; then
      __check=0
    fi
  fi
  if [ "$__check" -eq 1 ]; then
    # 5 秒总超时 / 3 秒连超时：这条提示不配让任何人在屏幕前等
    __latest=$(net_json GET "${SHELLKIT_RELEASE_API:-}" --path tag_name \
      --timeout 5 --connect-timeout 3 2>/dev/null) || __latest=""
    __latest=${__latest#v}
    case "$__latest" in
      '' | *[!0-9.]*) __latest="" ;;
    esac
    printf -v __line '%s\t%s' "$__now" "$__latest"
    # 路径边界（坑 8 同类）：目标或它的父目录是软链就不写 ——
    # fs_atomic_write 换掉的是软链本身（那条安全），但**父目录**是软链时
    # fs_ensure_dir 会顺着它把缓存写到别处去。宁可不缓存，也不写错地方。
    if [ -L "$__cache" ] || [ -L "$(dirname "$__cache")" ]; then
      return 0
    fi
    # 失败也写缓存（最新版本留空）：否则没网的机器每次调用都重试一遍超时
    fs_atomic_write "$__cache" "$__line" 600 || true
  fi
  [ -n "$__latest" ] || return 0
  ver_gt "$__latest" "$__cur" || return 0
  log_info "$(_t 'a newer version is available'): $__latest ($(_t 'run shellkit update'))"
  return 0
}
