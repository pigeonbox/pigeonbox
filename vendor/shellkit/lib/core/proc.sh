#!/usr/bin/env bash
#
# 进程组 / 看门狗原语：后台引导、整组停止、带退避的自愈。
#
# 为什么单独一层：svc_* 是 systemd/launchd 的**服务单元**管理（写 unit 文件、
# 交给服务管理器拉起）；这一层是**裸进程** —— 设备侧启动脚本手写
# 「nohup ... & + pid 文件 + 探活循环」的那一层。两层语义不同，名字不能混：
# svc_start 已经被 systemd 语义占用了（改了它等于改掉既有调用方的行为）。
#
# 这一层要解决的三件事，每一件手写都踩过坑：
#   1. 后台引导：脱离终端（关掉终端不能把它带死）、记 pid 文件；
#   2. 整组停止：只 kill 主进程 ⇒ 子进程残留、端口还占着；
#   3. 看门狗自愈：探活失败与探活超时不分、重启风暴没有退避、僵尸 pid 文件没清。
#
# 进程组怎么来的：bash 的作业控制（set -m）让后台任务**自带进程组**，
# 组 id 就是它的 pid ⇒ 整组停止就是 kill -- -PGID。
# 不用 setsid：macOS 没有这个命令（util-linux 才有），而作业控制两个平台都有。
#
# 落点：pid 文件与日志放在 $SHELLKIT_PROC_DIR
# （默认 ${TMPDIR:-/tmp}/shellkit-proc-<uid>，权限 700）。/tmp 是共享目录 ⇒
# 名字必须先过校验，目录也不能是软链（软链会把 pid 文件写到别处去）。
#
# 边界：这一层依赖 bash 的作业控制（set -m）与 ps 的进程组字段，
# **不进 POSIX 子集**（设备侧那套 busybox ash 用不了）——
# 能力清单 lib/posix/capabilities.tsv 里逐条写着原因。

# _sk_proc_dir —— 运行时目录（pid 文件与日志都在这儿）
# @exitcode 0 成功（stdout 是目录）
# @exitcode 3 建不出来 / 是软链
_sk_proc_dir() {
  local __d="${SHELLKIT_PROC_DIR:-}"
  if [ -z "$__d" ]; then
    __d="${TMPDIR:-/tmp}/shellkit-proc-$(id -u 2>/dev/null || printf '0')"
  fi
  if [ -L "$__d" ]; then
    log_error "$(_t 'refusing to use a symlinked runtime directory'): $__d"
    return "$SK_PRECOND"
  fi
  if [ ! -d "$__d" ]; then
    mkdir -p "$__d" 2>/dev/null || {
      log_error "$(_t 'cannot create the runtime directory'): $__d"
      return "$SK_PRECOND"
    }
    chmod 700 "$__d" 2>/dev/null || true
  fi
  printf '%s' "$__d"
}

# _sk_proc_valid_name NAME —— 名字能不能当文件名的组成部分
#   名字会变成路径（<name>.pid）⇒ 带 / 或 .. 的名字能写到目录之外。
# @exitcode 0 合法；1 非法
_sk_proc_valid_name() {
  case "${1:-}" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# _sk_proc_alive PID —— 这个 pid 上还有活进程吗
#   僵尸不算活着：kill -0 对僵尸也成功（它还在进程表里），
#   而「僵尸 pid 文件没清」正是手写看门狗最常见的坑。
#
#   ps 报不出状态时（没装 procps 的精简容器）分不出僵尸与活进程
#   ⇒ 退化成 kill -0（判据变粗：僵尸会被当成活着，pid 文件不会自动清）。
#   这一层不进 POSIX 子集，但它服务的就是设备侧启动脚本 —— 那些机器上的
#   ps 常常只有 busybox 那点能力，所以这里**必须能退化**：不能因为
#   「查不到状态」就把所有进程判成死了（那等于这一层在设备侧完全不可用）。
#
#   取 ps 输出的**最后一行**：busybox 的 ps 不认 `stat=` 的表头抑制，
#   会先打一行表头（STAT）再打真状态 ⇒ 表头在前、状态在后。
#   取全部输出会把表头拼在状态前面（STATZ+）⇒ 僵尸就再也认不出来了
#   —— 而「僵尸 pid 文件清不掉」正是这一层要根治的坑（坑 3）。
# @exitcode 0 活着；1 没了
_sk_proc_alive() {
  local __pid="${1:-}" __st
  [ -n "$__pid" ] || return 1
  kill -0 "$__pid" 2>/dev/null || return 1
  __st=$(ps -o stat= -p "$__pid" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
  case "$__st" in
    Z*) return 1 ;;
  esac
  return 0
}

# _sk_proc_self_pgid —— 调用方自己所在的进程组
#   组杀之前必须先问这一句：目标那个组是不是**我们自己的组**？
#   是的话 kill -- -PGID 会把调用方一起杀掉 —— 静默自杀：
#   脚本被自己组的 SIGTERM 打死，退出码 143，看起来像「被信号停掉」，
#   实际上是我们自己动的手。
# @exitcode 0 成功（stdout 是 pgid）；1 取不到（ps 不支持 / 进程没了）
_sk_proc_self_pgid() {
  local __pgid
  __pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')
  [ -n "$__pgid" ] || return 1
  printf '%s' "$__pgid"
}

# _sk_proc_group_of PID —— 这个进程能不能「整组停」
#
#   判据只有这一处（别在别处再写一遍）：
#     目标自己就是组长（pgid == pid）**且**那个组不是调用方自己的组。
#   两条都满足才允许 kill -- -PGID。
#
#   stdout：pgid（可以整组停时）｜空串（不能整组停 ⇒ 只能只杀那个 pid）
# @exitcode 0 可以整组停（stdout 是 pgid）；1 不行
_sk_proc_group_of() {
  local __pid="${1:-}" __pgid __self
  [ -n "$__pid" ] || return 1
  __pgid=$(ps -o pgid= -p "$__pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$__pgid" ] || return 1
  [ "$__pgid" = "$__pid" ] || return 1
  __self=$(_sk_proc_self_pgid) || return 1
  [ -n "$__self" ] || return 1
  [ "$__pgid" != "$__self" ] || return 1
  printf '%s' "$__pgid"
  return 0
}

# _sk_proc_group_pids PGID —— 这个组里还有哪些 pid
#   ps 不支持这个输出格式时输出为空（调用方按「查不到」处理）。
#   不用 grep -q：命中即退会把上游 SIGPIPE 打死（坑 5）。
# @exitcode 0 总是成功（stdout 是 pid 列表，可能为空）
_sk_proc_group_pids() {
  local __pgid="${1:-}"
  [ -n "$__pgid" ] || return 0
  ps -A -o pid=,pgid= 2>/dev/null | awk -v g="$__pgid" '$2 == g { print $1 }' 2>/dev/null
  return 0
}

# _sk_proc_group_busy PGID —— 这个组里还有活着的进程吗（僵尸不算）
# @exitcode 0 还有；1 没有 / 查不到
_sk_proc_group_busy() {
  local __pgid="${1:-}" __pid
  [ -n "$__pgid" ] || return 1
  while IFS= read -r __pid; do
    [ -n "$__pid" ] || continue
    if _sk_proc_alive "$__pid"; then
      return 0
    fi
  done <<EOF
$(_sk_proc_group_pids "$__pgid")
EOF
  return 1
}

# _sk_proc_pid_file DIR NAME —— pid 文件路径
# @exitcode 0 总是成功（stdout 是路径）
_sk_proc_pid_file() {
  printf '%s/%s.pid' "${1:-}" "${2:-}"
}

# proc_start NAME COMMAND... —— 后台拉起一个进程组
#
# 脱离终端：nohup 忽略 SIGHUP + 标准输入接 /dev/null + 作业控制让它自带进程组。
# pid 文件：$DIR/NAME.pid（原子写）。日志：$DIR/NAME.log（**追加**，不截断 ——
# 截断会把上次的现场抹掉，出事时没得查）。
#
# @exitcode 0 成功（进程已拉起）
# @exitcode 2 用法错（名字非法 / 没有命令）
# @exitcode 3 前置条件不满足（已经在跑 / 运行目录不可用 / 命令不存在）
# @exitcode 1 拉起失败（命令自己起不来）
# @stability experimental
proc_start() {
  local __name="${1:-}" __dir __pidfile __logfile __pid __pgid __had_m=0
  _sk_need_args "$#" 2 "proc_start NAME COMMAND..." || return $?
  __name=$1
  shift
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  if ! require_cmd "${1:-}"; then
    return "$SK_PRECOND"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  __logfile="$__dir/$__name.log"
  # 路径边界守卫：pid 文件是 <name>.pid，名字已校验过（不含 / 与 ..）
  if ! _sk_fs_rel_safe "$__name.pid"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  if [ -L "$__pidfile" ]; then
    log_error "$(_t 'refusing to write through a symlink'): $__pidfile"
    return "$SK_PRECOND"
  fi
  # 已经在跑 ⇒ 不再拉第二份（两份进程抢同一个端口）
  if [ -f "$__pidfile" ]; then
    __pid=$(cat "$__pidfile" 2>/dev/null || true)
    if _sk_proc_alive "$__pid"; then
      log_error "$(_t 'the process is already running'): $__name ($__pid)"
      return "$SK_PRECOND"
    fi
    # 僵尸 pid 文件：清掉，否则下次 start 会误判「已经在跑」
    rm -f "$__pidfile" 2>/dev/null || true
  fi
  # 作业控制：后台任务自带进程组（组 id = 它的 pid）⇒ 整组停止才做得到
  case "$-" in
    *m*) __had_m=1 ;;
  esac
  set -m
  nohup "$@" >>"$__logfile" 2>&1 </dev/null &
  __pid=$!
  if [ "$__had_m" = "0" ]; then
    set +m
  fi
  # 组 id 必须是它自己 —— 不是的话整组停止会退化成只停主进程（子进程残留）
  __pgid=$(ps -o pgid= -p "$__pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$__pgid" ] || [ "$__pgid" != "$__pid" ]; then
    log_warn "$(_t 'the process group is unavailable; only the main process can be stopped'): $__name"
  fi
  if ! fs_atomic_write "$__pidfile" "$__pid
" 600; then
    kill "$__pid" 2>/dev/null || true
    return 1
  fi
  # 拉起来就退出（命令本身有问题：不存在、参数错、立刻崩）⇒ 明确报错
  sleep 0.3
  if ! _sk_proc_alive "$__pid"; then
    # 整组清掉：命令自己起来就崩，但它可能已经派生了子进程 ——
    # 只杀主进程会留下孤儿（端口还占着，正是这一层要根治的坑）
    __pgid=$(_sk_proc_group_of "$__pid") || __pgid=""
    if [ -n "$__pgid" ]; then
      kill -TERM -- "-$__pgid" 2>/dev/null || true
    else
      kill -TERM "$__pid" 2>/dev/null || true
    fi
    rm -f "$__pidfile" 2>/dev/null || true
    log_error "$(_t 'the process exited immediately'): $__name (see $__logfile)"
    return 1
  fi
  return 0
}

# proc_stop NAME —— 停掉整个进程组
#
# 只 kill 主进程 ⇒ 子进程残留、端口还占着 —— 这是手写最常见的坑。
# 这里先给整组 TERM，留收尾的时间；还在就 KILL 整组。
#
# 「整组停」有两条硬约束（判据在 _sk_proc_group_of，只此一处）：
#   目标得自己就是组长，且那个组不是**我们自己的组** ——
#   否则 kill -- -PGID 会把调用方一起杀掉（静默自杀，退出码 143）。
#   满足不了就退化成只杀那个 pid（宁可留子进程，也不能自杀）。
#
# @exitcode 0 已停（或本来就没在跑）
# @exitcode 2 用法错
# @exitcode 3 停不掉（TERM 与 KILL 之后还在）
# @stability experimental
proc_stop() {
  local __name="${1:-}" __dir __pidfile __pid __pgid __i=0 __alive=0
  _sk_need_args "$#" 1 "proc_stop NAME" || return $?
  __name=$1
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  # 没有 pid 文件 ⇒ 没在跑（停一个没跑的东西是成功，不是错误）
  [ -f "$__pidfile" ] || return 0
  __pid=$(cat "$__pidfile" 2>/dev/null || true)
  if ! _sk_proc_alive "$__pid"; then
    rm -f "$__pidfile" 2>/dev/null || true
    return 0
  fi
  __pgid=$(_sk_proc_group_of "$__pid") || __pgid=""
  if [ -n "$__pgid" ]; then
    kill -TERM -- "-$__pgid" 2>/dev/null || kill -TERM "$__pid" 2>/dev/null || true
  else
    kill -TERM "$__pid" 2>/dev/null || true
  fi
  # 等它收尾（最多 10 秒）：主进程没了还不够 —— 组里可能还有子进程在跑
  while [ "$__i" -lt 100 ]; do
    __alive=0
    _sk_proc_alive "$__pid" && __alive=1
    if [ "$__alive" = "0" ] && [ -n "$__pgid" ] && _sk_proc_group_busy "$__pgid"; then
      __alive=1
    fi
    [ "$__alive" = "0" ] && break
    sleep 0.1
    __i=$((__i + 1))
  done
  __alive=0
  _sk_proc_alive "$__pid" && __alive=1
  if [ "$__alive" = "0" ] && [ -n "$__pgid" ] && _sk_proc_group_busy "$__pgid"; then
    __alive=1
  fi
  if [ "$__alive" = "1" ]; then
    if [ -n "$__pgid" ]; then
      kill -KILL -- "-$__pgid" 2>/dev/null || kill -KILL "$__pid" 2>/dev/null || true
    else
      kill -KILL "$__pid" 2>/dev/null || true
    fi
    # KILL 之后再看一眼：还在就如实报停不掉（退出码 3），别假装成功
    __i=0
    while [ "$__i" -lt 20 ]; do
      __alive=0
      _sk_proc_alive "$__pid" && __alive=1
      if [ "$__alive" = "0" ] && [ -n "$__pgid" ] && _sk_proc_group_busy "$__pgid"; then
        __alive=1
      fi
      [ "$__alive" = "0" ] && break
      sleep 0.1
      __i=$((__i + 1))
    done
    if [ "$__alive" = "1" ]; then
      log_error "$(_t 'cannot stop the process'): $__name ($__pid)"
      return "$SK_PRECOND"
    fi
  fi
  rm -f "$__pidfile" 2>/dev/null || true
  return 0
}

# proc_is_running NAME —— 探活
#
# 僵尸 pid 文件会被清掉：文件还在、进程早没了 —— 手写看门狗最常见的另一种坑
#（探活永远失败，但没人清理，重启就一直起不来）。
#
# @exitcode 0 在跑
# @exitcode 1 没在跑（僵尸 pid 文件会被清掉）
# @exitcode 2 用法错
# @exitcode 3 运行目录不可用
# @stability experimental
proc_is_running() {
  local __name="${1:-}" __dir __pidfile __pid
  _sk_need_args "$#" 1 "proc_is_running NAME" || return $?
  __name=$1
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  __dir=$(_sk_proc_dir) || return $?
  __pidfile=$(_sk_proc_pid_file "$__dir" "$__name")
  [ -f "$__pidfile" ] || return 1
  __pid=$(cat "$__pidfile" 2>/dev/null || true)
  if _sk_proc_alive "$__pid"; then
    return 0
  fi
  rm -f "$__pidfile" 2>/dev/null || true
  return 1
}

# proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND...
#
# 看门狗：进程挂了拉起来，带退避。
#
# 退避：连续失败时按 1→2→4… 翻倍（上限 --max-backoff）——
# 没有退避的重启是**风暴**：进程起来就崩 ⇒ 无限循环重启，把机器打满。
# 进程连续活过几个周期 ⇒ 退避归零（不是一直用最大退避）。
#
# --max-restarts N：连续 N 次拉起失败就放弃并返回非 0（0 = 不限）。
# 无人值守设备上「放弃了」必须有人看得见，所以放弃时是**非 0 退出**。
#
# @exitcode 0 被信号停掉（正常退出）
# @exitcode 2 用法错
# @exitcode 1 放弃（连续拉起失败超过上限）
# @stability experimental
proc_watchdog() {
  local __interval=5 __maxbackoff=60 __maxrestarts=0 __name __dir __pid
  local __backoff=1 __consec=0 __up=0 __rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)
        shift
        __interval="${1:-}"
        ;;
      --max-backoff)
        shift
        __maxbackoff="${1:-}"
        ;;
      --max-restarts)
        shift
        __maxrestarts="${1:-}"
        ;;
      -h | --help)
        printf '%s\n' "$(_t 'Usage'): proc_watchdog [--interval SEC] [--max-backoff SEC] [--max-restarts N] NAME COMMAND..."
        return 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  _sk_need_args "$#" 2 "proc_watchdog [options] NAME COMMAND..." || return $?
  __name=$1
  shift
  if ! _sk_proc_valid_name "$__name"; then
    log_error "$(_t 'invalid process name'): $__name"
    return "$SK_USAGE"
  fi
  case "$__interval" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid interval'): $__interval"
      return "$SK_USAGE"
      ;;
  esac
  case "$__maxbackoff" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid backoff'): $__maxbackoff"
      return "$SK_USAGE"
      ;;
  esac
  case "$__maxrestarts" in
    '' | *[!0-9]*)
      log_error "$(_t 'invalid restart limit'): $__maxrestarts"
      return "$SK_USAGE"
      ;;
  esac
  # 0 秒间隔是热循环（100% CPU），0 秒退避是重启风暴 —— 两个都不接受
  if [ "$__interval" -lt 1 ]; then
    log_error "$(_t 'invalid interval'): $__interval"
    return "$SK_USAGE"
  fi
  if [ "$__maxbackoff" -lt 1 ]; then
    log_error "$(_t 'invalid backoff'): $__maxbackoff"
    return "$SK_USAGE"
  fi
  # 被停时把子进程也带走 —— 留下一个孤儿占着端口，比不停更糟
  trap_push "proc_stop '$__name'" || true
  trap_install || true
  while :; do
    if ! proc_is_running "$__name"; then
      if [ "$__consec" -gt 0 ]; then
        # 退避要看得见：没有退避的重启是风暴，运维要能看出「在等」
        log_info "$(_t 'waiting before the next restart'): $__backoff s"
        sleep "$__backoff"
      fi
      if proc_start "$__name" "$@"; then
        __up=0
      else
        # 失败计数只加一次（下面那个「没在跑」的分支统一加）——
        # 两处都加会把一次失败算成两次，--max-restarts 的上限就少了一半
        log_error "$(_t 'the watchdog could not start the process'): $__name"
      fi
    fi
    sleep "$__interval"
    if proc_is_running "$__name"; then
      __up=$((__up + 1))
      if [ "$__up" -ge 3 ]; then
        # 连续活过三个周期 ⇒ 之前那次挂掉是偶发，退避归零
        __backoff=1
        __consec=0
      fi
    else
      __backoff=$((__backoff * 2))
      if [ "$__backoff" -gt "$__maxbackoff" ]; then
        __backoff=$__maxbackoff
      fi
      __consec=$((__consec + 1))
    fi
    if [ "$__maxrestarts" -gt 0 ] && [ "$__consec" -ge "$__maxrestarts" ]; then
      log_error "$(_t 'the watchdog gave up after too many failed restarts'): $__name"
      __rc=1
      break
    fi
  done
  proc_stop "$__name" || true
  return "$__rc"
}
