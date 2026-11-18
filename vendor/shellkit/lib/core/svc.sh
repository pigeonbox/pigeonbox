#!/usr/bin/env bash
#
# 服务管理：systemd（Linux）。
#
# 写类动作（start/stop/enable/...）在 SHELLKIT_DRY_RUN=1 时只打印不执行；
# 只读动作（is_active/is_enabled）直跑，不套 dry-run —— 它们是判定，不是副作用。
#
# 退出码口径：0 成功 / 1 用法错之外的判定结果 / 2 用法错 / 3 当前平台不支持 /
# 4 服务管理器自身失败。
#
# macOS 上 svc_platform 报 launchd，但**动作动词只有 systemd 一套** ——
# launchd 的等价动词要的是 plist 路径或 label，与本模块「一个 UNIT」的单参签名
# 不是一回事（unix_script 的 service_start/service_stop 走的是双参签名，
# 留在 unix_script 侧）。所以 macOS 上写类动作一律返回 3。

# svc_platform —— 当前平台的服务管理器
#   可用 SK_SVC_PLATFORM 覆盖（测试与特殊环境用）。
# @exitcode 0 总是成功（stdout 输出 systemd|launchd|none）
# @stability experimental
svc_platform() {
  if [ -n "${SK_SVC_PLATFORM:-}" ]; then
    printf '%s\n' "${SK_SVC_PLATFORM}"
    return 0
  fi
  case "$(os_name)" in
    linux) printf '%s\n' 'systemd' ;;
    darwin) printf '%s\n' 'launchd' ;;
    *) printf '%s\n' 'none' ;;
  esac
}

# _sk_svc_need_unit ACTION UNIT —— 校验 unit 参数
# @exitcode 0 参数没问题
# @exitcode 2 unit 为空
_sk_svc_need_unit() {
  local __action=${1:-} __unit=${2:-}
  if [ -z "$__unit" ]; then
    log_error "$(_t 'Usage'): svc_$__action UNIT"
    return "$SK_USAGE"
  fi
  return 0
}

# _sk_svc_need_systemd —— 确认当前平台是 systemd
# @exitcode 0 是 systemd
# @exitcode 3 当前平台没有 systemd
_sk_svc_need_systemd() {
  local __p
  __p=$(svc_platform)
  if [ "$__p" != 'systemd' ]; then
    log_error "$(_t 'This action requires systemd'): $__p"
    return "$SK_PRECOND"
  fi
  return 0
}

# _sk_svc_do ACTION UNIT... —— 执行 systemd 动作；失败统一报 4
# @exitcode 0 成功
# @exitcode 4 服务管理器自身失败
_sk_svc_do() {
  local __rc=0
  run --no-die systemctl "$@" || __rc=$?
  if [ "$__rc" -ne 0 ]; then
    return 4
  fi
  return 0
}

# svc_start UNIT —— 启动服务
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_start() {
  _sk_svc_need_unit start "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do start "$@"
}

# svc_stop UNIT —— 停止服务
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_stop() {
  _sk_svc_need_unit stop "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do stop "$@"
}

# svc_restart UNIT —— 重启服务
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_restart() {
  _sk_svc_need_unit restart "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do restart "$@"
}

# svc_reload UNIT —— 重载服务配置
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_reload() {
  _sk_svc_need_unit reload "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do reload "$@"
}

# svc_enable UNIT —— 开机自启
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_enable() {
  _sk_svc_need_unit enable "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do enable "$@"
}

# svc_disable UNIT —— 取消开机自启
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_disable() {
  _sk_svc_need_unit disable "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do disable "$@"
}

# svc_enable_now UNIT —— 开机自启并立即启动
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_enable_now() {
  _sk_svc_need_unit enable-now "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do enable --now "$@"
}

# svc_disable_now UNIT —— 取消开机自启并立即停止
# @exitcode 0 成功
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_disable_now() {
  _sk_svc_need_unit disable-now "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  _sk_svc_do disable --now "$@"
}

# svc_is_active UNIT —— 服务是否在跑（只读，不套 dry-run）
# @exitcode 0 在跑
# @exitcode 1 没在跑
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @stability experimental
svc_is_active() {
  _sk_svc_need_unit is-active "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  systemctl is-active --quiet "$@" 2>/dev/null
}

# svc_is_enabled UNIT —— 服务是否开机自启（只读，不套 dry-run）
# @exitcode 0 是
# @exitcode 1 不是
# @exitcode 2 缺 unit
# @exitcode 3 当前平台没有 systemd
# @stability experimental
svc_is_enabled() {
  _sk_svc_need_unit is-enabled "${1:-}" || return $?
  _sk_svc_need_systemd || return $?
  systemctl is-enabled --quiet "$@" 2>/dev/null
}

# svc_daemon_reload —— 让 systemd 重新读 unit 文件
# @exitcode 0 成功
# @exitcode 3 当前平台没有 systemd
# @exitcode 4 systemd 自身失败
# @stability experimental
svc_daemon_reload() {
  _sk_svc_need_systemd || return $?
  _sk_svc_do daemon-reload
}

# svc_install_unit NAME —— 从 stdin 读 unit 内容写入系统目录并 daemon-reload
# NAME 必须是单个合法文件名（字母数字与 :_.@+-）：它会被拼进
# /etc/systemd/system/ 后面，带路径组件就能写到那个目录之外。
# root 下直接写、不套 sudo（极简容器里常有 root 但没有 sudo）。
# @exitcode 0 成功
# @exitcode 2 缺 unit 名或名字带路径组件
# @exitcode 3 当前平台没有 systemd、拿不到 sudo
# @exitcode 4 写入或 daemon-reload 失败
# @stability experimental
svc_install_unit() {
  local __unit="${1:-}" __target __rc=0
  if [ -z "$__unit" ]; then
    log_error "$(_t 'Usage'): svc_install_unit NAME"
    return "$SK_USAGE"
  fi
  # UNIT 必须是单个合法文件名：它会被拼进 /etc/systemd/system/ 后面，
  # 带 ../ 或 / 就能把 unit 文件写到那个目录之外 —— 而且是用 root 权限写。
  case "$__unit" in
    */* | *..* | .* | *[!A-Za-z0-9@:_.+-]*)
      log_error "$(_t 'invalid unit name'): $__unit"
      return "$SK_USAGE"
      ;;
  esac
  _sk_svc_need_systemd || return $?
  __target="/etc/systemd/system/$__unit"
  if [ "${SHELLKIT_DRY_RUN:-0}" = '1' ]; then
    # dry-run 下没人读 stdin —— 排空它，别让写 unit 的上游收到 SIGPIPE。
    # stdin 是终端时不排空（会挂住）。
    if [ ! -t 0 ]; then
      cat >/dev/null
    fi
  else
    os_sudo_ready || return $?
  fi
  # root 就别再套 sudo：极简容器里常有 root 但没有 sudo 命令，
  # 明明有权限却因为找不到 sudo 而失败。
  if [ "$(id -u 2>/dev/null)" = '0' ]; then
    run --no-die tee "$__target" >/dev/null || __rc=$?
  else
    run --no-die sudo tee "$__target" >/dev/null || __rc=$?
  fi
  if [ "$__rc" -ne 0 ]; then
    return 4
  fi
  svc_daemon_reload
}
