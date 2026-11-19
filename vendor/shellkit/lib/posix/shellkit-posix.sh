#!/bin/sh
#
# shellkit 的 POSIX 子集：设备侧（busybox ash / dash / POSIX sh）能用的一小撮。
#
# 为什么单独一份：主库的基线是 Bash 3.2+，内部用了数组等 bash 专有语法
# （mapfile / printf -v / 大写展开 / local -n ...），在 busybox ash 上**根本解析不了**
# —— 不是「运行报错」，是「脚本起不来」。
#
# 设备侧脚本（NAS 的 start/stop、OpenWrt 的 init 脚本）是「装机即执行」的：
# 改坏的现场装不了 shellkit 补救 ⇒ 那边的脚本必须是**最保守**的那一份。
# 这一份就是那份保守实现：宁可少给能力，也不给一个在 ash 上会炸的函数。
#
# 这一份的规矩（tools/check_posix.sh 逐条查）：
#   - 只用 POSIX sh 语法：没有数组、没有 [[ ]]、没有 local、没有 printf -v、
#     没有大写展开、没有 mapfile、没有 += ；
#   - 没有 source（POSIX 用 .）；
#   - 函数里的自变量用**专属变量名**（没有 local，名字会串到别的函数里）。
#
# 入口统一：设备侧脚本是 #!/bin/sh，用 . 引这份库：
#
#     . /opt/pioneer/lib/shellkit-posix.sh
#     log_info "starting"
#     retry 3 my_command --flag
#
# 能用哪些函数：看同目录的 capabilities.tsv；运行时也能问：
#
#     if posix_capable net_download; then ... fi

# ---- 日志（stdout 只给数据，日志一律 stderr）----

# _sk_posix_log_rank LEVEL —— 级别序号（数字大 = 更严重）
_sk_posix_log_rank() {
  case "${1:-info}" in
    debug) printf '10' ;;
    info) printf '20' ;;
    ok) printf '20' ;;
    warn) printf '30' ;;
    error) printf '40' ;;
    *) printf '20' ;;
  esac
}

# _sk_posix_should_log LEVEL —— 这个级别要不要打印
_sk_posix_should_log() {
  _sp_want=$(_sk_posix_log_rank "${1:-info}")
  _sp_have=$(_sk_posix_log_rank "${SHELLKIT_LOG_LEVEL:-info}")
  [ "$_sp_want" -ge "$_sp_have" ]
}

# _sk_posix_log LEVEL MESSAGE —— 打一行日志
_sk_posix_log() {
  printf '[%s] %s\n' "${1:-INFO}" "${2:-}" >&2
}

# log_info MESSAGE —— 普通信息
log_info() {
  _sk_posix_should_log info || return 0
  _sk_posix_log INFO "${1:-}"
}

# log_ok MESSAGE —— 成功
log_ok() {
  _sk_posix_should_log info || return 0
  _sk_posix_log OK "${1:-}"
}

# log_warn MESSAGE —— 警告
log_warn() {
  _sk_posix_should_log warn || return 0
  _sk_posix_log WARN "${1:-}"
}

# log_error MESSAGE —— 错误
log_error() {
  _sk_posix_should_log error || return 0
  _sk_posix_log ERROR "${1:-}"
}

# log_debug MESSAGE —— 调试信息（默认级别 info ⇒ 不打印）
log_debug() {
  _sk_posix_should_log debug || return 0
  _sk_posix_log DEBUG "${1:-}"
}

# log_section TITLE —— 小节标题
log_section() {
  printf '\n== %s ==\n' "${1:-}" >&2
}

# ---- 失败与前置条件 ----

# fail MESSAGE [CODE] —— 报错并返回（不退出）
fail() {
  _sp_fail_code=1
  if [ "$#" -ge 2 ]; then
    _sp_fail_code=$2
  fi
  log_error "${1:-}"
  return "$_sp_fail_code"
}

# die MESSAGE [CODE] —— 报错并退出
die() {
  _sp_die_code=1
  if [ "$#" -ge 2 ]; then
    _sp_die_code=$2
  fi
  log_error "${1:-}"
  exit "$_sp_die_code"
}

# ---- 清理栈 ----

_SK_POSIX_TRAP_CMDS=""

# trap_push COMMAND —— 登记一条退出时要执行的命令（后进先出）
trap_push() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _SK_POSIX_TRAP_CMDS="$1
$_SK_POSIX_TRAP_CMDS"
  return 0
}

# _sk_posix_trap_run —— 退出时的清理（保留原退出码）
_sk_posix_trap_run() {
  _sp_trap_status=$?
  trap - 0 1 2 15
  if [ -n "$_SK_POSIX_TRAP_CMDS" ]; then
    eval "$_SK_POSIX_TRAP_CMDS"
  fi
  exit "$_sp_trap_status"
}

# trap_install —— 装上退出/信号清理
trap_install() {
  trap '_sk_posix_trap_run' 0 1 2 15
  return 0
}

# ---- 重试 ----

# retry ATTEMPTS COMMAND... —— 失败重试
#
# 用法错（退出码 2）不重试 —— 重试一个用法错只是把同一个错误重复几遍。
retry() {
  if [ "$#" -lt 2 ]; then
    log_error "usage: retry ATTEMPTS COMMAND..."
    return 2
  fi
  _sp_retry_n=$1
  shift
  case "$_sp_retry_n" in
    '' | *[!0-9]*)
      log_error "invalid retry count: $_sp_retry_n"
      return 2
      ;;
  esac
  if [ "$_sp_retry_n" -lt 1 ]; then
    log_error "invalid retry count: $_sp_retry_n"
    return 2
  fi
  _sp_retry_i=0
  while [ "$_sp_retry_i" -lt "$_sp_retry_n" ]; do
    "$@"
    _sp_retry_rc=$?
    if [ "$_sp_retry_rc" -eq 0 ]; then
      return 0
    fi
    if [ "$_sp_retry_rc" -eq 2 ]; then
      return "$_sp_retry_rc"
    fi
    _sp_retry_i=$((_sp_retry_i + 1))
    if [ "$_sp_retry_i" -ge "$_sp_retry_n" ]; then
      log_error "giving up after retries: $_sp_retry_n (exit $_sp_retry_rc)"
      return "$_sp_retry_rc"
    fi
    log_warn "attempt failed, retrying: $_sp_retry_i/$_sp_retry_n (exit $_sp_retry_rc)"
    sleep "${SHELLKIT_RETRY_DELAY:-1}"
  done
  return 1
}

# ---- 文件与目录 ----

# fs_ensure_dir DIR [MODE] —— 建目录（已存在就算成功）
fs_ensure_dir() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if [ -d "$1" ]; then
    return 0
  fi
  mkdir -p "$1" || return 1
  if [ "$#" -ge 2 ] && [ -n "$2" ]; then
    chmod "$2" "$1" || return 1
  fi
  return 0
}

# fs_ensure_file FILE [CONTENT] —— 写文件（不存在才写）
fs_ensure_file() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if [ -f "$1" ]; then
    return 0
  fi
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" >"$1" || return 1
  else
    : >"$1" || return 1
  fi
  return 0
}

# ---- 下载与校验 ----

# net_sha256 FILE —— 算 sha256（stdout 是摘要）
net_sha256() {
  if [ "$#" -lt 1 ]; then
    return 2
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f1
  else
    return 1
  fi
}

# net_verify FILE SHA256 —— 校验（5 = 不一致）
net_verify() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  _sp_v_sum=$(net_sha256 "$1") || {
    log_error "cannot compute checksum for: $1"
    return 5
  }
  if [ "$_sp_v_sum" = "$2" ]; then
    return 0
  fi
  log_error "checksum mismatch for: $1"
  return 5
}

# net_download URL DEST [SHA256] —— 下载（可选校验）
net_download() {
  if [ "$#" -lt 2 ]; then
    log_error "usage: net_download URL DEST [SHA256]"
    return 2
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1" || return 1
  else
    log_error "curl or wget is required to download"
    return 3
  fi
  if [ "$#" -ge 3 ] && [ -n "$3" ]; then
    net_verify "$2" "$3" || return $?
  fi
  return 0
}

# ---- 配置（环境变量 > 配置文件 > 默认值）----

_SK_POSIX_CONF=""

# conf_init FILE —— 指定配置文件
conf_init() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _SK_POSIX_CONF=$1
  return 0
}

# _sk_posix_valid_name NAME —— 合法的变量名吗（eval 之前必须查）
_sk_posix_valid_name() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# conf_get_any KEY DEFAULT —— 取配置值
conf_get_any() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  if ! _sk_posix_valid_name "$1"; then
    printf '%s\n' "$2"
    return 2
  fi
  # 环境变量优先。用 printenv 而不是 eval 间接引用：POSIX 没有 ${!var}，
  # eval 那一套既能注入又过不了 shellcheck 的 sh 方言；printenv 是标准命令，
  # 键名查过了，取不到就是取不到（不报错，落到配置文件与默认值）。
  _sp_c_env=$(printenv "$1" 2>/dev/null || true)
  if [ -n "$_sp_c_env" ]; then
    printf '%s\n' "$_sp_c_env"
    return 0
  fi
  if [ -n "$_SK_POSIX_CONF" ] && [ -r "$_SK_POSIX_CONF" ]; then
    while IFS= read -r _sp_c_line || [ -n "$_sp_c_line" ]; do
      case "$_sp_c_line" in
        "$1="*)
          printf '%s\n' "${_sp_c_line#*=}"
          return 0
          ;;
      esac
    done <"$_SK_POSIX_CONF"
  fi
  printf '%s\n' "$2"
  return 0
}

# ---- 版本比较（纯 POSIX 分段比较）----

# ver_cmp A B —— -1 / 0 / 1
ver_cmp() {
  if [ "$#" -lt 2 ]; then
    return 2
  fi
  _sp_vc_a=$(printf '%s\n' "$1" | tr '.' ' ')
  _sp_vc_b=$(printf '%s\n' "$2" | tr '.' ' ')
  _sp_vc_i=1
  while [ "$_sp_vc_i" -le 20 ]; do
    _sp_vc_x=$(printf '%s\n' "$_sp_vc_a" | cut -d ' ' -f"$_sp_vc_i")
    _sp_vc_y=$(printf '%s\n' "$_sp_vc_b" | cut -d ' ' -f"$_sp_vc_i")
    [ -n "$_sp_vc_x" ] || _sp_vc_x=0
    [ -n "$_sp_vc_y" ] || _sp_vc_y=0
    case "$_sp_vc_x" in
      *[!0-9]*)
        return 2
        ;;
    esac
    case "$_sp_vc_y" in
      *[!0-9]*)
        return 2
        ;;
    esac
    if [ "$_sp_vc_x" -gt "$_sp_vc_y" ]; then
      printf '%s\n' 1
      return 0
    fi
    if [ "$_sp_vc_x" -lt "$_sp_vc_y" ]; then
      printf '%s\n' -1
      return 0
    fi
    _sp_vc_i=$((_sp_vc_i + 1))
  done
  printf '%s\n' 0
  return 0
}

# ver_gt A B —— A > B 吗
ver_gt() {
  _sp_vg=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_vg" = "1" ]
}

# ver_lt A B —— A < B 吗
ver_lt() {
  _sp_vl=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_vl" = "-1" ]
}

# ver_eq A B —— A == B 吗
ver_eq() {
  _sp_ve=$(ver_cmp "$1" "$2") || return $?
  [ "$_sp_ve" = "0" ]
}

# ---- 单实例锁 ----

# _sk_posix_lock_path NAME —— 锁的路径
_sk_posix_lock_path() {
  printf '%s/shellkit-%s.lock\n' "${SHELLKIT_LOCK_DIR:-${TMPDIR:-/tmp}}" "${1:-}"
}

# lock_acquire NAME [TIMEOUT] —— 拿锁（拿到即进清理栈）
lock_acquire() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    log_error "invalid lock name"
    return 2
  fi
  case "$1" in
    . | .. | *[!A-Za-z0-9_.-]*)
      log_error "invalid lock name: $1"
      return 2
      ;;
  esac
  _sp_lk_path=$(_sk_posix_lock_path "$1")
  _sp_lk_wait=0
  if [ "$#" -ge 2 ]; then
    _sp_lk_wait=$2
  fi
  _sp_lk_tries=0
  while :; do
    if mkdir "$_sp_lk_path" 2>/dev/null; then
      printf '%s\n' "$$" >"$_sp_lk_path/pid" 2>/dev/null || true
      trap_push "lock_release $1"
      trap_install
      return 0
    fi
    _sp_lk_pid=$(cat "$_sp_lk_path/pid" 2>/dev/null || true)
    if [ -n "$_sp_lk_pid" ] && kill -0 "$_sp_lk_pid" 2>/dev/null; then
      log_error "another instance is running: $1 ($_sp_lk_pid)"
      return 1
    fi
    # 僵尸锁：持有者已经没了 ⇒ 回收
    rm -rf "$_sp_lk_path" 2>/dev/null || true
    _sp_lk_tries=$((_sp_lk_tries + 1))
    if [ "$_sp_lk_wait" -gt 0 ] && [ "$_sp_lk_tries" -ge "$_sp_lk_wait" ]; then
      log_error "another instance is running: $1"
      return 1
    fi
    sleep 1
  done
}

# lock_release NAME —— 放锁
lock_release() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  _sp_lr_path=$(_sk_posix_lock_path "$1")
  rm -rf "$_sp_lr_path" 2>/dev/null || true
  return 0
}

# ---- 机器可读状态 ----

# status_is_machine —— 现在是机器模式吗
status_is_machine() {
  [ "${SHELLKIT_STATUS_MODE:-human}" = "machine" ]
}

# status_state_valid STATE —— 状态码合法吗
status_state_valid() {
  case "${1:-}" in
    not_installed | installed | installed:running | installed:stopped | configured | not_configured | n/a)
      return 0
      ;;
  esac
  return 1
}

# status_emit STATE HUMAN_MSG —— 输出状态
status_emit() {
  if [ "$#" -lt 1 ]; then
    return 2
  fi
  if status_is_machine; then
    printf 'STATE=%s\n' "$1"
  else
    printf '%s\n' "${2:-$1}"
  fi
  return 0
}

# status_version VERSION —— 机器模式下输出 VERSION 行
status_version() {
  if status_is_machine; then
    printf 'VERSION=%s\n' "${1:-}"
  fi
  return 0
}

# status_extra KEY=VALUE —— 机器模式下输出 EXTRA 行
status_extra() {
  if status_is_machine; then
    printf 'EXTRA=%s\n' "${1:-}"
  fi
  return 0
}

# ---- 能力查询 ----

# posix_capable NAME —— 这个函数在 POSIX 子集里能用吗
#
# 设备侧脚本据此判断「这条能不能用」，而不是靠试 —— 试出来的失败往往是
# 「装上就挂」，而现场装不了 shellkit 补救。
posix_capable() {
  if [ "$#" -lt 1 ] || [ -z "$1" ]; then
    return 2
  fi
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
