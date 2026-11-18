#!/usr/bin/env bash
#
# 门禁：设备侧脚本（跑在 NAS 上、随包装进系统目录）必须保持 **POSIX sh / busybox ash** 形态。
#
# 为什么有这道门禁（2026-11-18 生态引入 shellkit 的直接产物）：
#   引入 shellkit 之后，最大的诱惑是把 bash 库带进设备侧脚本 ——
#   但设备侧的执行环境是 **busybox ash**（群晖 DSM / 威联通 QTS / OpenWrt），
#   而 shellkit 的基线是 **bash 3.2+**（内部用数组 + bash 专有语法）
#   ⇒ 带进去 = 设备上当场崩，而且现场装不了 shellkit 补救。
#   偏偏设备侧脚本就是生态「启动脚本」的主体（QPKG 的 start/stop、SPK 的
#   pre/postinst、OpenWrt 的 procd init）⇒ 一旦改坏，**装机即挂**。
#
# 判据（三条）：
#   ① 设备侧脚本**一律不得引用 shellkit**（vendor/shellkit、lib/bootstrap.sh）
#      ⇒ 「把 bash 库带进设备」这条路径在制度上被堵死。
#   ② shebang 是 '#!/bin/sh'（或等价 ash 解释器）的设备侧脚本，必须能被 'sh -n' 解析
#      ⇒ POSIX 语法；大部分 bashism 在这一步就暴露。
#   ③ 同一批脚本不得含 'sh -n' 抓不到的运行时 bashism（数组、=~、大小写转换、
#      ANSI-C 引号、source、local -n…）⇒ 补这一刀。
#
# 范围：设备侧脚本在**平台仓**里（qnap / synology / openwrt），在 hub 工作区里是
#   被 gitignore 的独立 git 仓 ⇒ 不在位时**跳过并告警**（不硬失败），
#   与 check-shell-var-boundary.sh 同口径。
#
# 用法: bash scripts/check-device-shell-ash.sh [--selfcheck]
set -uo pipefail

ROOT="${SHELL_DEVICE_SH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

# 设备侧脚本清单（相对 ROOT；路径在**平台仓**里）
DEVICE_GLOBS="qnap/qpkg/shared/*
synology/spk/scripts/*
openwrt/openwrt/pigeonbox.*
openwrt/openwrt/preupgrade_backup
openwrt/openwrt/prewire_beam_box"

# bashism 固定串清单（用 grep -F：不需要正则，也就没有反斜杠转义的坑）。
# 注释行在比对前被剥掉 ⇒ 注释里出现这些词不会误报。
# 用**带引号的 heredoc**承载：清单里有单引号（$'…' 的 ANSI-C 引号），
# 单引号字符串会被它截断 ⇒ 这里必须走 heredoc。
BASHISM_FIXED="$(
  cat <<'EOFPAT'
[[
((
local -n
declare -A
declare -a
mapfile
readarray
=~
&&>
&>
$'
source 
shopt
pushd
popd
coproc
select 
let 
^}
,,
${!'
EOFPAT
)"

SCANNED=0
BAD=0
SKIPPED_ROOTS=""
COVERED_ROOTS=""

for g in $DEVICE_GLOBS; do
  dir="${g%/*}"
  if [ ! -d "$dir" ]; then
    case "$dir" in
      qnap | synology | openwrt) SKIPPED_ROOTS="$SKIPPED_ROOTS $dir" ;;
    esac
    continue
  fi
  case " $COVERED_ROOTS " in
    *" $dir "*) : ;;
    *) COVERED_ROOTS="$COVERED_ROOTS $dir" ;;
  esac
  for f in $g; do
    [ -f "$f" ] || continue
    SCANNED=$((SCANNED + 1))

    # ① 设备侧不得引用 shellkit
    #    （落点两个都要认：真相源 hub 的 vendor/shellkit；消费仓的 third_party/shellkit）
    if LC_ALL=C grep -Fq -e 'vendor/shellkit' -e 'third_party/shellkit' -e 'shellkit/lib/bootstrap.sh' "$f"; then
      BAD=1
      echo "✗ ${f}：设备侧脚本引用了 shellkit（vendor/shellkit / third_party/shellkit）——设备是 busybox ash，装不了 bash 库"
      LC_ALL=C grep -Fn -e 'vendor/shellkit' -e 'third_party/shellkit' -e 'shellkit/lib/bootstrap.sh' "$f" | sed 's/^/    /'
      continue
    fi

    shebang="$(head -n1 "$f")"
    case "$shebang" in
      *bash*)
        # bash 类设备侧脚本（QTS/OpenWrt 的 prewire_beam_box）：只受判据①约束
        continue
        ;;
    esac

    # ② POSIX 语法：必须能被 sh -n 解析
    if ! sh -n "$f" 2>/dev/null; then
      BAD=1
      echo "✗ ${f}：不是 POSIX 语法（sh -n 解析失败）——设备侧执行环境是 busybox ash"
      sh -n "$f" 2>&1 | sed 's/^/    /'
      continue
    fi

    # ③ bashism 扫描（剥注释后比对）
    #
    # ⚠️ 先把 POSIX 算术展开 '$((…))' 剥掉：它**不是** bashism，
    #    而 bash 的算术**命令**形态 '(( expr ))' 才是。
    #    两者都含 '(('，不剥就会把满地的计数语句判红（实测 17 个设备侧脚本里 4 处误报）。
    #    另注：'(( expr ))' 在 macOS 的 /bin/sh（=bash 兼容模式）下 'sh -n' **不报错**，
    #    在 Ubuntu(dash) 下才报 ⇒ 只靠 sh -n 判它会**跨平台不一致** ⇒ 这里用 grep 定死。
    code_only="$(LC_ALL=C sed -e 's/[[:space:]]#.*$//' -e 's/[$]((//g' "$f")"
    hits=""
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      hit="$(printf '%s\n' "$code_only" | LC_ALL=C grep -Fn -e "$pat" || true)"
      if [ -n "$hit" ]; then
        hits="$hits$hit
"
      fi
    done <<EOFPAT
$BASHISM_FIXED
EOFPAT
    if [ -n "$hits" ]; then
      BAD=1
      echo "✗ ${f}：含 bashism（设备侧是 busybox ash，跑不了）:"
      printf '%s' "$hits" | sed 's/^/    /'
    fi
  done
done

if [ -n "$SKIPPED_ROOTS" ]; then
  echo "! 跳过（平台仓不在位，hub CI 单仓 checkout 时不在 workspace）:$SKIPPED_ROOTS"
fi
echo "  （共扫 $SCANNED 个设备侧脚本；实测覆盖目录：${COVERED_ROOTS:- 无}）"

# 零覆盖不判绿（「没扫到」≠「扫过且通过」，与 #329 同口径）。
# ⚠️ 自证模式除外：自证要在**临时目录**里造样本，主扫必然扫不到东西 ⇒ 提前退出会
#   让自证永远跑不到 ⇒ 断言形同虚设。
if [ "$SCANNED" -eq 0 ] && [ "$SELFCHECK" -eq 0 ]; then
  if [ -n "$COVERED_ROOTS" ]; then
    echo "✗ 平台仓在位却一个设备侧脚本都没扫到 ⇒ 判据不可用（零覆盖不判绿）" >&2
    exit 1
  fi
  # ⚠️ **零覆盖的口径**：平台仓**不在位** ⇒ 本检出是单仓检出，没有设备侧脚本
  #   可扫 ⇒ 明确提示后跳过（绿）；「在位却扫不到」才是判据失效（红）。
  #   CI 侧不靠这道门禁兜底：CI 的 job 会**显式断言**各平台仓已检出。
  echo "! 跳过：平台仓不在位（本检出是单仓检出，没有设备侧脚本可扫）"
  exit 0
fi

if [ "$BAD" -ne 0 ] && [ "$SELFCHECK" -eq 0 ]; then
  echo ""
  echo "  修法: 设备侧脚本保持 POSIX sh（用 [ ] 不用 [[ ]]、不用数组、不用 source）；"
  echo "        需要 bash 的逻辑放到 CI 侧的 scripts/ 里做，别放进包。"
  exit 1
fi

# ── 自证：注入 bashism ⇒ 本门禁必须变红；干净 ⇒ 绿；零覆盖 ⇒ 红 ────────────
if [ "$SELFCHECK" -eq 1 ]; then
  TMP="$(mktemp -d)"
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  mkdir -p "$TMP/qnap/qpkg/shared" "$TMP/openwrt/openwrt"

  printf '%s\n' '#!/bin/sh' 'if [ -n "$x" ]; then' '  echo ok' 'fi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  printf '%s\n' '#!/bin/sh /etc/rc.common' 'start_service() {' '  echo start' '}' >"$TMP/openwrt/openwrt/pigeonbox.init"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：POSIX 干净 ⇒ 门禁绿"
  else
    echo "  ✗ 基线：POSIX 干净竟然判红 ⇒ 门禁本身坏了" >&2
    exit 1
  fi

  printf '%s\n' '#!/bin/sh' 'if [[ -n "$x" ]]; then' '  echo ok' 'fi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「bashism」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「bashism（[[ ]]）」⇒ 门禁变红（断言有牙齿）"

  printf '%s\n' '#!/bin/sh' '. /opt/app/third_party/shellkit/lib/bootstrap.sh' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「设备侧引用 shellkit」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「设备侧引用 shellkit」⇒ 门禁变红（断言有牙齿）"

  printf '%s\n' '#!/bin/sh' 'if [ -n "$x" ]; then' '  echo ok' 'fi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✓ 移除注入后恢复绿"
  else
    echo "  ✗ 移除注入后仍红 ⇒ 门禁有误报" >&2
    exit 1
  fi

  # ① 零覆盖（单仓检出）⇒ 明确提示跳过，而不是静默绿
  TMP0="$(mktemp -d)"
  out0="$(SHELL_DEVICE_SH_ROOT="$TMP0" bash "$ROOT/scripts/check-device-shell-ash.sh" 2>&1)" && rc0=0 || rc0=$?
  if [ "$rc0" -ne 0 ]; then
    echo "  ✗ 零覆盖（单仓检出）却判红 ⇒ 口径错了：没有可扫对象应当**明确跳过**" >&2
    rm -rf "$TMP0"
    exit 1
  fi
  if printf '%s' "$out0" | grep -q '跳过'; then
    echo "  ✓ 零覆盖（单仓检出）⇒ 明确提示跳过（不是静默绿）"
  else
    echo "  ✗ 零覆盖时没有给出跳过提示 ⇒ 结论不可用" >&2
    rm -rf "$TMP0"
    exit 1
  fi
  rm -rf "$TMP0"

  # ② 平台仓**在位**却一个设备侧脚本都扫不到 ⇒ 必须判红（判据空转）
  TMP1="$(mktemp -d)"
  mkdir -p "$TMP1/qnap/qpkg/shared"
  if SHELL_DEVICE_SH_ROOT="$TMP1" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 平台仓在位却零覆盖仍绿 ⇒ 判据空转" >&2
    rm -rf "$TMP1"
    exit 1
  fi
  rm -rf "$TMP1"
  echo "  ✓ 平台仓在位但零覆盖 ⇒ 门禁变红（断言有牙齿）"
fi

echo "✓ 设备侧脚本保持 POSIX/ash 形态（实测覆盖：${COVERED_ROOTS:- 无}；共扫 $SCANNED 个脚本）"
OK=1
