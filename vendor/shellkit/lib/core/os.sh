#!/usr/bin/env bash
# 平台与系统探测。所有 Darwin / Linux 差异只在这里出现。

_sk_os_detect() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) SK_OS=linux ;;
    Darwin*) SK_OS=darwin ;;
    *) SK_OS=other ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    arm64 | aarch64) SK_ARCH=aarch64 ;;
    x86_64 | amd64) SK_ARCH=x86_64 ;;
    *) SK_ARCH=other ;;
  esac
}

_sk_os_detect

# os_name —— linux | darwin | other
# @exitcode 0 总是成功（stdout 输出 darwin/linux）
# @stability experimental
os_name() { printf '%s\n' "$SK_OS"; }

# os_arch —— x86_64 | aarch64 | other
# @exitcode 0 总是成功（stdout 输出架构）
# @stability experimental
os_arch() { printf '%s\n' "$SK_ARCH"; }

# os_is_root —— 当前是否以 root 身份运行
# @exitcode 0 是 root
# @exitcode 1 不是 root
# @stability experimental
os_is_root() {
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    return 0
  fi
  return 1
}

# os_has_cmd CMD... —— 零参数返回 SK_USAGE（空真会让前置检查静默通过）
# @exitcode 0 命令都在
# @exitcode 1 有命令找不到
# @exitcode 2 没给参数
# @stability stable
os_has_cmd() {
  local __c
  _sk_need_args "$#" 1 "os_has_cmd CMD..." || return $?
  for __c in "$@"; do
    if ! command -v "$__c" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

_sk_pkg_mgr() {
  if [ -n "${SK_PKG_MGR:-}" ]; then
    printf '%s\n' "$SK_PKG_MGR"
    return 0
  fi
  local __m
  for __m in dnf yum apt-get zypper apk; do
    if command -v "$__m" >/dev/null 2>&1; then
      SK_PKG_MGR=$__m
      printf '%s\n' "$SK_PKG_MGR"
      return 0
    fi
  done
  return 1
}

# os_pkg_manager —— 本机的包管理器名（apt-get/yum/dnf/zypper/apk）；没有则返回 1
# @exitcode 0 找到了（stdout 输出包管理器名）
# @exitcode 1 找不到支持的包管理器
# @stability experimental
os_pkg_manager() { _sk_pkg_mgr; }

# os_pkg_update —— 刷新包索引；没有受支持的包管理器返回 SK_PRECOND(3)
# @exitcode 0 更新成功
# @exitcode 3 找不到支持的包管理器
# @exitcode 其他 包管理器自身的退出码
# @stability experimental
os_pkg_update() {
  local __mgr
  __mgr=$(_sk_pkg_mgr) || {
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  }
  case "$__mgr" in
    dnf) dnf -q -y makecache ;;
    yum) yum -q -y makecache ;;
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get -qq update ;;
    zypper) zypper -q --non-interactive refresh ;;
    apk) apk update -q ;;
  esac
}

# os_pkg_install PKG... —— 用本机包管理器装包；没有受支持的包管理器返回 SK_PRECOND(3)
# @exitcode 0 安装成功
# @exitcode 3 找不到支持的包管理器
# @exitcode 其他 包管理器自身的退出码
# @stability experimental
os_pkg_install() {
  local __mgr
  __mgr=$(_sk_pkg_mgr) || {
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  }
  case "$__mgr" in
    dnf) dnf -q -y install "$@" ;;
    yum) yum -q -y install "$@" ;;
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get -qq -y install "$@" ;;
    zypper) zypper -q --non-interactive install "$@" ;;
    apk) apk add -q "$@" ;;
  esac
}

# os_sed_i ARGS... —— 就地编辑；Darwin 的 sed 必须给个备份后缀
# @exitcode 0 成功
# @exitcode 其他 sed 自身的退出码
# @stability experimental
os_sed_i() {
  if [ "$SK_OS" = "darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# os_md5 FILE —— 文件的 md5；两种工具都没有时返回 1
# @exitcode 0 成功（stdout 输出校验和）
# @exitcode 2 没给参数
# @exitcode 1 没有 md5sum 也没有 md5
# @stability experimental
os_md5() {
  local __f=${1:-} __out=""
  _sk_need_args "$#" 1 "os_md5 FILE" || return $?
  if command -v md5sum >/dev/null 2>&1; then
    __out=$(md5sum "$__f") || __out=""
  elif command -v md5 >/dev/null 2>&1; then
    __out=$(md5 -q "$__f") || __out=""
  else
    return 1
  fi
  # 摘要是输出的第一个字段，后面跟的是文件名。
  # 不接管道是为了少一次 fork：这两个函数在升级热路径上每个文件要调两三次，
  # 一次 fork 就是几十毫秒（本机实测），管道那一次纯属白扔。
  #
  # 输出与旧写法逐字节一致：成功是「摘要\n」，文件读不到时 stdout 全空、
  # 退出码仍是 0（旧写法里是 awk 的退出码）。
  __out=${__out%% *}
  if [ -z "$__out" ]; then
    return 0
  fi
  printf '%s\n' "$__out"
  return 0
}

# os_sha256 FILE —— 文件的 sha256；两种工具都没有时返回 1
# @exitcode 0 成功（stdout 输出校验和）
# @exitcode 2 没给参数
# @exitcode 1 没有 sha256sum 也没有 shasum
# @stability experimental
os_sha256() {
  local __f=${1:-} __out=""
  _sk_need_args "$#" 1 "os_sha256 FILE" || return $?
  if command -v sha256sum >/dev/null 2>&1; then
    __out=$(sha256sum "$__f") || __out=""
  elif command -v shasum >/dev/null 2>&1; then
    __out=$(shasum -a 256 "$__f") || __out=""
  else
    return 1
  fi
  # 同 os_md5：摘要在第一个字段，后面跟文件名；不接管道，少一次 fork。
  # 输出与旧写法逐字节一致（成功「摘要\n」，读不到时 stdout 全空、退出码 0）。
  __out=${__out%% *}
  if [ -z "$__out" ]; then
    return 0
  fi
  printf '%s\n' "$__out"
  return 0
}

# ---------------------------------------------------------------------------
# 发行版与桌面环境检测
#
# 这几个函数是 unix_script 的 detect_distro / detect_desktop 的下沉版本，
# 输出必须与原实现逐字一致（设计文档：门面转发与原实现「逐字等价」）：
#   - 字段读取：剥引号；找不到键 / 文件不可读 => stdout 空、退出码 0
#   - 族判定：三段式（包管理器实测 -> ID_LIKE 词表 -> ID 词表）
#   - 桌面判定：所有线索拼成一个串，再按桌面类型优先级匹配
#
# 与原实现的两处刻意差异（都不改变可观察结果）：
#   1. KEY 用 awk 的 -v 传（当字符串，不当代码）—— 原实现把 KEY 拼进 sed 正则，是个注入面。
#   2. 桌面线索里的 kwin_x11 仍按原样进串：它的名字里没有 plasma/kde，单独不构成线索
#      （真实 KDE 会话必然带 plasmashell / startplasma-x11）。
#
# 麒麟（kylin）刻意不进 ID 硬表：服务器版是 RHEL 系、桌面版是 Ubuntu 系，
# 硬编码任一族都会误判一半 —— 它靠 ID_LIKE 判定。
# ---------------------------------------------------------------------------

# _sk_os_lower TEXT —— 转小写（bash 3.2 没有 ${v^^}）
_sk_os_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# os_release_field KEY [FILE] —— 读 os-release 风格文件的字段值
# @param KEY 字段名（ID / ID_LIKE / PRETTY_NAME / NAME ...）
# @param FILE 文件路径；缺省依次尝试 /etc/os-release、/usr/lib/os-release
# @exitcode 0 总是成功（读不到时 stdout 为空）
# @exitcode 2 KEY 为空
# @stability experimental
os_release_field() {
  local __key=${1:-} __file=${2:-} __f __v
  _sk_need_args "$#" 1 "os_release_field KEY [FILE]" || return $?
  if [ -z "$__key" ]; then
    log_error "$(_t 'Usage'): os_release_field KEY [FILE]"
    return "$SK_USAGE"
  fi
  if [ -z "$__file" ]; then
    for __f in /etc/os-release /usr/lib/os-release; do
      if [ -r "$__f" ]; then
        __file="$__f"
        break
      fi
    done
  fi
  if [ -z "$__file" ] || [ ! -r "$__file" ]; then
    return 0
  fi
  # 只认行首的 KEY= 这一种写法；KEY 用 awk 的 -v 传（当字符串，不当代码）
  __v=$(awk -v k="$__key" 'index($0, k "=") == 1 && !f { print substr($0, length(k) + 2); f = 1 }' "$__file" 2>/dev/null) || __v=""
  [ -n "$__v" ] || return 0
  # 剥引号：前导一个、末尾一个，各自独立；剩下的中间若还带引号 => 整体不匹配（返回空）
  case "$__v" in
    \"*) __v="${__v#\"}" ;;
    \'*) __v="${__v#\'}" ;;
  esac
  case "$__v" in
    *\") __v="${__v%\"}" ;;
    *\') __v="${__v%\'}" ;;
  esac
  case "$__v" in
    *\"* | *\'*) __v='' ;;
  esac
  printf '%s' "$__v"
  return 0
}

# os_distro_id [FILE] —— 小写的发行版 ID
# @param FILE os-release 文件路径；缺省读本机的
# @exitcode 0 总是成功（读不到时 stdout 为空）
# @stability experimental
os_distro_id() {
  local __id
  __id=$(os_release_field ID "${1:-}") || __id=""
  _sk_os_lower "$__id"
  return 0
}

# os_distro_name [FILE] —— 发行版显示名（PRETTY_NAME，空则回退 NAME）
# @param FILE os-release 文件路径；缺省读本机的
# @exitcode 0 总是成功（读不到时 stdout 为空）
# @stability experimental
os_distro_name() {
  local __v
  __v=$(os_release_field PRETTY_NAME "${1:-}") || __v=""
  if [ -z "$__v" ]; then
    __v=$(os_release_field NAME "${1:-}") || __v=""
  fi
  printf '%s' "$__v"
  return 0
}

# os_distro_family [FILE] —— 发行版族：debian|rhel|suse|arch|alpine|unknown
# 判定顺序：包管理器实测 -> ID_LIKE 词表 -> ID 词表
# @param FILE os-release 文件路径；缺省走主机模式（先按包管理器实测）
# @exitcode 0 总是成功（判不出时输出 unknown）
# @stability experimental
os_distro_family() {
  local __file=${1:-} __id __like __fam
  # 主机模式先按包管理器实测；给了文件就只看这个文件，不许混入本机包管理器
  if [ -z "$__file" ]; then
    __fam=$(_sk_os_pkg_family) || __fam=""
    if [ -n "$__fam" ]; then
      printf '%s' "$__fam"
      return 0
    fi
  fi
  # 族判定 ②：ID_LIKE 词表（麒麟靠它区分服务器版 / 桌面版）
  __like=$(_sk_os_lower "$(os_release_field ID_LIKE "$__file")") || __like=""
  case "$__like" in
    *debian* | *ubuntu* | *mint*)
      printf '%s' 'debian'
      return 0
      ;;
    *rhel* | *fedora* | *centos* | *euler* | *anolis* | *amzn*)
      printf '%s' 'rhel'
      return 0
      ;;
    *suse*)
      printf '%s' 'suse'
      return 0
      ;;
    *arch* | *manjaro*)
      printf '%s' 'arch'
      return 0
      ;;
    *alpine*)
      printf '%s' 'alpine'
      return 0
      ;;
  esac
  # 族判定 ③：ID 词表兜底。kylin 刻意不入表 —— 服务器版基于 RHEL 系、桌面版基于 Ubuntu 系，
  # 硬编码任何一个族都会误判一半场景，交由 ①实测 / ②ID_LIKE 决定
  __id=$(_sk_os_lower "$(os_release_field ID "$__file")") || __id=""
  case "$__id" in
    debian | ubuntu | deepin | openkylin | uos | linuxmint | kali)
      printf '%s' 'debian'
      return 0
      ;;
    centos | rhel | rocky | almalinux | fedora | amzn | ol | openeuler | anolis)
      printf '%s' 'rhel'
      return 0
      ;;
    opensuse* | sles)
      printf '%s' 'suse'
      return 0
      ;;
    arch | manjaro)
      printf '%s' 'arch'
      return 0
      ;;
    alpine)
      printf '%s' 'alpine'
      return 0
      ;;
  esac
  printf '%s' 'unknown'
  return 0
}

# os_desktop_env —— 桌面环境：ukui|dde|gnome|kde|xfce|mate|cinnamon|lxqt|budgie|none
# 判定口径与 unix_script 的 detect_desktop 逐字等价：所有线索拼成一个串，
# 再按桌面类型优先级匹配（ukui > dde > kde > gnome > xfce > mate > cinnamon > lxqt > budgie）
# @exitcode 0 总是成功（没有线索时输出 none）
# @stability experimental
os_desktop_env() {
  local __clues='' __v __b
  # 三个线索环境变量（XDG_CURRENT_DESKTOP 可能是冒号分隔的列表）
  for __v in "${XDG_CURRENT_DESKTOP:-}" "${XDG_SESSION_DESKTOP:-}" "${DESKTOP_SESSION:-}"; do
    [ -n "$__v" ] || continue
    __clues="$__clues $(_sk_os_lower "$__v")"
  done
  # 会话二进制也算线索
  for __b in ukui-session kwin_x11 startdde dde-desktop gnome-session gnome-shell \
    plasmashell startplasma-x11 xfce4-session mate-session cinnamon-session lxsession; do
    command -v "$__b" >/dev/null 2>&1 || continue
    __clues="$__clues $__b"
  done
  case "$__clues" in
    *ukui*) printf '%s' 'ukui' ;;
    *dde* | *deepin*) printf '%s' 'dde' ;;
    *plasma* | *kde*) printf '%s' 'kde' ;;
    *gnome*) printf '%s' 'gnome' ;;
    *xfce*) printf '%s' 'xfce' ;;
    *mate*) printf '%s' 'mate' ;;
    *cinnamon*) printf '%s' 'cinnamon' ;;
    *lxqt* | *lxsession*) printf '%s' 'lxqt' ;;
    *budgie*) printf '%s' 'budgie' ;;
    *) printf '%s' 'none' ;;
  esac
  return 0
}

# os_is_desktop —— 当前是否在桌面环境
# @exitcode 0 在桌面环境
# @exitcode 1 不在桌面环境
# @stability experimental
os_is_desktop() {
  local __env
  __env=$(os_desktop_env) || __env='none'
  if [ -z "$__env" ] || [ "$__env" = 'none' ]; then
    return 1
  fi
  return 0
}

# _sk_os_pkg_family —— 按包管理器实测发行版族；没有支持的包管理器返回 1
_sk_os_pkg_family() {
  local __m
  for __m in apt-get dnf yum zypper pacman apk; do
    command -v "$__m" >/dev/null 2>&1 || continue
    case "$__m" in
      apt-get) printf '%s' 'debian' ;;
      dnf | yum) printf '%s' 'rhel' ;;
      zypper) printf '%s' 'suse' ;;
      pacman) printf '%s' 'arch' ;;
      apk) printf '%s' 'alpine' ;;
    esac
    return 0
  done
  return 1
}
# ---------------------------------------------------------------------------
# 提权包管理与 sudo 就绪
#
# 既有 os_pkg_install / os_pkg_update 语义一字不动（不提权、不认 pacman/brew）。
# 下面这几个是**新入口**，供 unix_script 的 pkg_install / pkg_update / pkg_remove /
# pkg_installed 转发过来 —— 传给包管理器的参数与 unix_script 现有实现逐字一致。
#
# 包管理器识别另起一套（含 pacman/brew），不复用 _sk_pkg_mgr：
#   _sk_pkg_mgr 是既有函数的依赖，改它会连带改 os_pkg_install / os_pkg_update 的
#   行为 —— 那两个函数没有 pacman 分支，认成 pacman 时会静默什么都不做还返回 0。
#
# dry-run 走 run --no-die：SHELLKIT_DRY_RUN=1 时只打印不执行，失败返回包管理器的
# 退出码（不 die）—— 与 unix_script 的 pkg_* 返回码口径一致。
# ---------------------------------------------------------------------------

# _sk_pkg_mgr_full —— 完整包管理器识别（含 pacman/brew）
#   顺序与 unix_script 的 detect_pkg_manager 一致：
#   apt-get > dnf > yum > zypper > pacman > apk > brew
#   可用 SK_PKG_MGR_FULL 覆盖（测试与特殊环境用）。
# @exitcode 0 找到包管理器
# @exitcode 1 没有找到
_sk_pkg_mgr_full() {
  if [ -n "${SK_PKG_MGR_FULL:-}" ]; then
    printf '%s\n' "${SK_PKG_MGR_FULL}"
    return 0
  fi
  local __m
  for __m in apt-get dnf yum zypper pacman apk brew; do
    command -v "$__m" >/dev/null 2>&1 || continue
    printf '%s\n' "$__m"
    return 0
  done
  return 1
}

# os_pkg_manager_full —— 本机包管理器名（含 pacman/brew）
#   既有 os_pkg_manager 不认 pacman/brew，这是另一套口径（unix_script 的
#   detect_pkg_manager 认这两个）—— 两套并存，不改既有函数。
# @exitcode 0 找到包管理器，stdout 是包管理器名
# @exitcode 1 没有找到受支持的包管理器
# @stability experimental
os_pkg_manager_full() {
  _sk_pkg_mgr_full
}

# _sk_sudo_prefix —— 需要提权时的 sudo 前缀；已是 root 则为空
#   用 id -u 而不是 $EUID：EUID 在 bash 里是只读变量，测不了「非 root」这条路。
_sk_sudo_prefix() {
  if [ "$(id -u 2>/dev/null)" = '0' ]; then
    printf '%s' ''
  else
    printf '%s' 'sudo'
  fi
}

# os_sudo_ready —— 确保 sudo 可用（不要求已经是 root）
#   已是 root 直接放行；否则先试免密（sudo -n true），不行则提示输入一次（sudo -v）。
# @exitcode 0 sudo 可用
# @exitcode 3 拿不到 sudo 权限
# @stability experimental
os_sudo_ready() {
  if [ "$(id -u 2>/dev/null)" = '0' ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    log_error "$(_t 'sudo is not available')"
    return "$SK_PRECOND"
  fi
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  log_info "$(_t 'This action needs sudo, please enter your password')"
  if sudo -v; then
    return 0
  fi
  log_error "$(_t 'Cannot obtain sudo permission')"
  return "$SK_PRECOND"
}

# _sk_pkg_exec MGR CMD... —— 按需提权执行包管理器命令
#   brew 不提权（它本来就装在用户目录里）；已是 root 直跑；其余走 sudo。
#   dry-run 与失败处理都交给 run。
_sk_pkg_exec() {
  local __mgr=${1:-}
  shift
  if [ "$__mgr" = 'brew' ] || [ "$(id -u 2>/dev/null)" = '0' ]; then
    run --no-die "$@"
  else
    run --no-die sudo "$@"
  fi
  return $?
}

# os_pkg_install_root PKG... —— 提权安装（root 直跑，否则 sudo）
# @exitcode 0 安装成功
# @exitcode 2 没给包名
# @exitcode 3 没有受支持的包管理器
# @exitcode 其他 包管理器自身的退出码
# @stability experimental
os_pkg_install_root() {
  local __mgr
  local -a __cmd
  _sk_need_args "$#" 1 "os_pkg_install_root PKG..." || return $?
  __mgr=$(_sk_pkg_mgr_full) || __mgr=''
  if [ -z "$__mgr" ]; then
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  fi
  case "$__mgr" in
    # DEBIAN_FRONTEND=noninteractive：容器/极简镜像里 tzdata 会弹 debconf 交互，
    # 无 TTY 时可能挂死（CI 与脚本场景必须避免）
    apt-get) __cmd=(env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@") ;;
    dnf) __cmd=(dnf install -y "$@") ;;
    yum) __cmd=(yum install -y "$@") ;;
    zypper) __cmd=(zypper --non-interactive install "$@") ;;
    pacman) __cmd=(pacman -S --noconfirm --needed "$@") ;;
    apk) __cmd=(apk add --no-cache "$@") ;;
    brew) __cmd=(brew install "$@") ;;
    *)
      log_error "$(_t 'Unsupported package manager'): $__mgr"
      return "$SK_PRECOND"
      ;;
  esac
  _sk_pkg_exec "$__mgr" "${__cmd[@]}"
}

# os_pkg_remove_root PKG... —— 提权卸载
# @exitcode 0 卸载成功
# @exitcode 2 没给包名
# @exitcode 3 没有受支持的包管理器
# @exitcode 其他 包管理器自身的退出码
# @stability experimental
os_pkg_remove_root() {
  local __mgr
  local -a __cmd
  _sk_need_args "$#" 1 "os_pkg_remove_root PKG..." || return $?
  __mgr=$(_sk_pkg_mgr_full) || __mgr=''
  if [ -z "$__mgr" ]; then
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  fi
  case "$__mgr" in
    apt-get) __cmd=(env DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$@") ;;
    dnf) __cmd=(dnf remove -y "$@") ;;
    yum) __cmd=(yum remove -y "$@") ;;
    zypper) __cmd=(zypper --non-interactive remove "$@") ;;
    pacman) __cmd=(pacman -Rns --noconfirm "$@") ;;
    apk) __cmd=(apk del "$@") ;;
    brew) __cmd=(brew uninstall "$@") ;;
    *)
      log_error "$(_t 'Unsupported package manager'): $__mgr"
      return "$SK_PRECOND"
      ;;
  esac
  _sk_pkg_exec "$__mgr" "${__cmd[@]}"
}

# os_pkg_update_root —— 提权刷新包索引
# @exitcode 0 成功
# @exitcode 3 没有受支持的包管理器
# @exitcode 其他 包管理器自身的退出码
# @stability experimental
os_pkg_update_root() {
  local __mgr
  local -a __cmd
  __mgr=$(_sk_pkg_mgr_full) || __mgr=''
  if [ -z "$__mgr" ]; then
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  fi
  case "$__mgr" in
    apt-get) __cmd=(apt-get update -y) ;;
    dnf) __cmd=(dnf makecache) ;;
    yum) __cmd=(yum makecache) ;;
    zypper) __cmd=(zypper --non-interactive refresh) ;;
    pacman) __cmd=(pacman -Sy) ;;
    apk) __cmd=(apk update) ;;
    brew) __cmd=(brew update) ;;
    *)
      log_error "$(_t 'Unsupported package manager'): $__mgr"
      return "$SK_PRECOND"
      ;;
  esac
  _sk_pkg_exec "$__mgr" "${__cmd[@]}"
}

# os_pkg_installed PKG —— 包是否已安装（不需要提权）
# @exitcode 0 已安装
# @exitcode 1 未安装
# @exitcode 2 没给包名
# @exitcode 3 没有受支持的包管理器
# @stability experimental
os_pkg_installed() {
  local __mgr __pkg
  _sk_need_args "$#" 1 "os_pkg_installed PKG" || return $?
  __pkg=$1
  __mgr=$(_sk_pkg_mgr_full) || __mgr=''
  if [ -z "$__mgr" ]; then
    log_error "$(_t 'no supported package manager found')"
    return "$SK_PRECOND"
  fi
  case "$__mgr" in
    apt-get) dpkg -s "$__pkg" >/dev/null 2>&1 ;;
    dnf | yum) rpm -q "$__pkg" >/dev/null 2>&1 ;;
    zypper) rpm -q "$__pkg" >/dev/null 2>&1 ;;
    pacman) pacman -Qi "$__pkg" >/dev/null 2>&1 ;;
    apk) apk info -e "$__pkg" >/dev/null 2>&1 ;;
    brew) brew list "$__pkg" >/dev/null 2>&1 ;;
    *)
      log_error "$(_t 'Unsupported package manager'): $__mgr"
      return "$SK_PRECOND"
      ;;
  esac
}
