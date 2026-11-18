#!/usr/bin/env bash
#
# 单实例锁。macOS 没有 flock，所以用 mkdir 的原子性 —— Linux 上同样适用。
#
#   lock_acquire deploy 30 || exit $?
#   ... 干活 ...
#   lock_release deploy
#
# 获取成功即进清理栈，所以忘记 release 也不会留下死锁。
# lock_acquire 会调用 trap_install（幂等）—— 这是唯一一处库主动改变信号行为的地方：
# 拿不到「退出时自动释放」的保证，锁就不该被拿走。

_SK_LOCKS=()
_SK_LOCK_HOOKED=0

# _sk_lock_name_ok NAME —— 只允许安全字符，杜绝路径穿越
_sk_lock_name_ok() {
  case "${1:-}" in
    '' | . | .. | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

_sk_lock_path() {
  printf '%s/shellkit-%s.lock\n' "${SHELLKIT_LOCK_DIR:-${TMPDIR:-/tmp}}" "$1"
}

_sk_lock_mtime() {
  local __p=$1
  if stat -f '%m' "$__p" >/dev/null 2>&1; then
    stat -f '%m' "$__p"
  else
    stat -c '%Y' "$__p"
  fi
}

_sk_lock_pid_alive() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null
}

# _sk_lock_is_stale DIR —— 0 表示可以回收
# 规则：持有者进程已消失即可回收；pid 文件缺失/不可读时按目录年龄判 ——
# 宽限期取 SHELLKIT_LOCK_STALE，未设置时用 5 秒（刚 mkdir 还没写 pid 的瞬间不能被抢）。
# 活着的持有者绝不按年龄回收 —— 那等于把正在干活的进程的锁抢走。
_sk_lock_is_stale() {
  local __dir=$1 __pid __stale __now __mt
  __stale=$(_sk_uint SHELLKIT_LOCK_STALE 0)
  __pid=$(cat "$__dir/pid" 2>/dev/null || true)
  if [ -n "$__pid" ]; then
    if _sk_lock_pid_alive "$__pid"; then
      return 1
    fi
    log_debug "lock holder $__pid is gone"
    return 0
  fi
  # 「目录在、pid 不在」不是合法的持有态：mkdir 与写 pid 之间被 SIGKILL / 断电 /
  # OOM 打断就长这样。以前默认 0 = 永不回收，于是一次非正常退出就让这个锁名永久不可用，
  # 报错还说是「另一个实例在跑」，用户只能去查一个不存在的进程。
  if [ "$__stale" -le 0 ]; then
    __stale=5
  fi
  __mt=$(_sk_lock_mtime "$__dir" 2>/dev/null || printf '0')
  case "$__mt" in
    '' | *[!0-9]*) return 1 ;;
  esac
  __now=$(date +%s)
  if [ $((__now - __mt)) -gt "$__stale" ]; then
    log_debug "lock dir older than ${__stale}s and has no pid"
    return 0
  fi
  return 1
}

_sk_lock_try() {
  local __dir=$1
  if ! mkdir "$__dir" 2>/dev/null; then
    return 1
  fi
  if ! printf '%s\n' "$$" >"$__dir/pid" 2>/dev/null; then
    rmdir "$__dir" 2>/dev/null || true
    return 1
  fi
  return 0
}

_sk_lock_forget() {
  local __name=$1 __i=0 __x
  local -a __keep=()
  while [ "$__i" -lt "${#_SK_LOCKS[@]}" ]; do
    __x=${_SK_LOCKS[$__i]}
    if [ "$__x" != "$__name" ]; then
      __keep[${#__keep[@]}]=$__x
    fi
    __i=$((__i + 1))
  done
  _SK_LOCKS=(${__keep[@]+"${__keep[@]}"})
  return 0
}

_sk_lock_cleanup_all() {
  local __i=${#_SK_LOCKS[@]} __name __dir __pid
  while [ "$__i" -gt 0 ]; do
    __i=$((__i - 1))
    __name=${_SK_LOCKS[$__i]}
    _SK_LOCKS[$__i]=""
    if [ -z "$__name" ]; then
      continue
    fi
    __dir=$(_sk_lock_path "$__name")
    __pid=$(cat "$__dir/pid" 2>/dev/null || true)
    if [ "$__pid" = "$$" ]; then
      rm -rf "$__dir"
      log_debug "released lock on exit: $__name"
    fi
  done
  _SK_LOCKS=()
  return 0
}

_sk_lock_hook() {
  # 不用标志位：标志位会被子 shell 继承，而子 shell 里的 trap 已经被重置，
  # 于是「以为挂钩了、其实没挂」。改成看清理栈里是否真的已有这个动作。
  if ! _sk_trap_has '_sk_lock_cleanup_all'; then
    trap_push '_sk_lock_cleanup_all'
  fi
  trap_install
  return 0
}

# lock_acquire NAME [WAIT_SEC] —— 0 成功；SK_PRECOND 被占用/超时；SK_USAGE 名字非法
# @exitcode 0 拿到锁（并挂进清理栈）
# @exitcode 2 锁名非法
# @exitcode 3 别人正持有（超时或僵锁）
# @stability stable
lock_acquire() {
  local __name=${1:-} __wait=${2:-0} __dir __i=0 __stale_tries=0
  if ! _sk_lock_name_ok "$__name"; then
    log_error "$(_t 'invalid lock name'): $__name"
    return "$SK_USAGE"
  fi
  case "$__wait" in
    '' | *[!0-9]*) __wait=0 ;;
  esac
  __dir=$(_sk_lock_path "$__name")

  while :; do
    if _sk_lock_try "$__dir"; then
      _SK_LOCKS[${#_SK_LOCKS[@]}]="$__name"
      # 只有真的拿到锁才挂钩：失败时既不该装 trap，也不该往调用方的清理栈里塞动作
      _sk_lock_hook
      log_debug "lock acquired: $__name (pid $$)"
      return 0
    fi
    if [ "$__stale_tries" -lt 3 ] && _sk_lock_is_stale "$__dir"; then
      __stale_tries=$((__stale_tries + 1))
      log_warn "$(_t 'removing stale lock'): $__name"
      rm -rf "$__dir"
      continue
    fi
    if [ "$__i" -ge "$__wait" ]; then
      log_error "$(_t 'another instance is running'): $__name ($__dir)"
      return "$SK_PRECOND"
    fi
    sleep 1
    __i=$((__i + 1))
  done
}

# lock_release NAME —— 只释放自己持有的锁
# @exitcode 0 释放成功（或本来就没锁）
# @exitcode 2 锁名非法
# @exitcode 3 锁被别的进程持有
# @stability stable
lock_release() {
  local __name=${1:-} __dir __pid
  if ! _sk_lock_name_ok "$__name"; then
    log_error "$(_t 'invalid lock name'): $__name"
    return "$SK_USAGE"
  fi
  __dir=$(_sk_lock_path "$__name")
  if [ ! -d "$__dir" ]; then
    return 0
  fi
  __pid=$(cat "$__dir/pid" 2>/dev/null || true)
  if [ "$__pid" != "$$" ]; then
    log_error "$(_t 'lock is held by another process'): $__name (pid ${__pid:-?})"
    return "$SK_PRECOND"
  fi
  rm -rf "$__dir"
  _sk_lock_forget "$__name"
  return 0
}

# lock_held NAME —— 返回码判断是否被占；被占时 stdout 输出持有者 pid
# @exitcode 0 锁着
# @exitcode 1 没锁
# @exitcode 2 锁名非法
# @stability stable
lock_held() {
  local __name=${1:-} __dir __pid
  if ! _sk_lock_name_ok "$__name"; then
    return "$SK_USAGE"
  fi
  __dir=$(_sk_lock_path "$__name")
  if [ ! -d "$__dir" ]; then
    return 1
  fi
  __pid=$(cat "$__dir/pid" 2>/dev/null || true)
  printf '%s\n' "${__pid:-}"
  return 0
}
