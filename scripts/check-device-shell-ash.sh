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
# 用**带引号的 heredoc**承载：清单里有单引号，单引号字符串会被它截断 ⇒ 这里必须走 heredoc。
#
# ⚠️ **ANSI-C 引号（$'…'）不在本清单里**，改由下面的 AWK_ANSIC 引号状态机判。
#   2026-11-18 实录：用固定串 "$'" 匹配会**误报** —— synology spk/scripts/postinst:25
#   那行完全 POSIX 的代码 `grep -Eq '^/volume[^/]+/.+$'` 里的 "$'" 是**单引号闭合**
#   （正则以 $ 结尾、后面紧跟收尾引号），不是 ANSI-C 引号的开始
#   ⇒ 门禁把一段合规的设备侧脚本判红 ⇒ 这道门禁一上线就会把 CI 打红。
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
# ANSI-C 引号（$'…'）检测器：bash 专有，POSIX sh（busybox ash）不认。
#
# ⚠️ **为什么不能用固定串 "$'" 匹配**（2026-11-18 实录）：
#   synology spk/scripts/postinst:25 是一行完全 POSIX 的代码：
#       printf '%s' "$1" | grep -Eq '^/volume[^/]+/.+$'
#   其中的 "$'" 是**单引号闭合**（正则以 $ 结尾、后面紧跟收尾引号），
#   不是 ANSI-C 引号的开始 ⇒ 固定串匹配 ⇒ 误报 ⇒ 门禁变成「天天误报」。
# ⇒ 改用**引号状态机**：逐字符走一遍，维护「单引号里 / 双引号里 / 字符串外」，
#    **只有在字符串外**遇到 "$'" 才算 ANSI-C 引号。
#   · 单引号内 `\` 是**字面量**（POSIX 规则）⇒ 只有在字符串外才把 `\` 当转义；
#   · 双引号内的 "$'" 在 bash 与 POSIX sh 里**都不是** ANSI-C 引号（都按字面 $ 处理）⇒ 不判。
AWK_ANSIC="$(
  cat <<'EOFAWK'
{
  line = $0
  n = length(line)
  i = 1
  in_sq = 0
  in_dq = 0
  while (i <= n) {
    c = substr(line, i, 1)
    if (in_sq) {
      if (c == "'") in_sq = 0
      i++
      continue
    }
    if (in_dq) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") in_dq = 0
      i++
      continue
    }
    if (c == "\\") { i += 2; continue }
    if (c == "'") { in_sq = 1; i++; continue }
    if (c == "\"") { in_dq = 1; i++; continue }
    if (c == "$" && substr(line, i + 1, 1) == "'") {
      print NR ":" line
      i += 2
      in_sq = 1
      continue
    }
    i++
  }
}
EOFAWK
)"

# bashism_hits <文件> → stdout 是命中行（空 = 干净）
#
# 抽成函数的原因（2026-11-19）：POSIX 子集文件**自己也要上设备**
#   ⇒ 它必须过同一把尺子 ⇒ 判据不能只内嵌在「设备脚本」那一个循环里。
bashism_hits() {
  local _f="$1" _code_only _hits="" _hit _pat
  # ⚠️ 先把 POSIX 算术展开 '$((…))' 剥掉：它**不是** bashism，
  #    而 bash 的算术**命令**形态 '(( expr ))' 才是。
  #    两者都含 '(('，不剥就会把满地的计数语句判红（实测 17 个设备侧脚本里 4 处误报）。
  #    另注：'(( expr ))' 在 macOS 的 /bin/sh（=bash 兼容模式）下 'sh -n' **不报错**，
  #    在 Ubuntu(dash) 下才报 ⇒ 只靠 sh -n 判它会**跨平台不一致** ⇒ 这里用 grep 定死。
  # ⚠️ 两条都要：① **整行注释**（'#' 在行首也可能！）② 行尾注释。
  #   只用 's/[[:space:]]#.*$//' 的话，**行首的 '#'（第 0 列）注释剥不掉**
  #   ⇒ 上游 POSIX 子集的文件头（整段 '# ' 开头的说明里就写着
  #   「没有 [[ ]]、没有 mapfile、local -n …」这些词）会被判成 bashism
  #   ⇒ 2026-11-19 实录：POSIX 子集自己被判红。
  _code_only="$(LC_ALL=C sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' -e 's/[$]((//g' "$_f")"
  while IFS= read -r _pat; do
    [ -n "$_pat" ] || continue
    _hit="$(printf '%s\n' "$_code_only" | LC_ALL=C grep -Fn -e "$_pat" || true)"
    if [ -n "$_hit" ]; then
      _hits="$_hits$_hit
"
    fi
  done <<EOFPAT
$BASHISM_FIXED
EOFPAT
  # ANSI-C 引号（$'…'）：必须用引号状态机判（理由见 AWK_ANSIC 上方）
  #   ——固定串 "$'" 会把「单引号闭合」误判成 ANSI-C 引号（2026-11-18 实录）。
  _hit="$(printf '%s\n' "$_code_only" | LC_ALL=C awk "$AWK_ANSIC" 2>/dev/null || true)"
  if [ -n "$_hit" ]; then
    _hits="$_hits$_hit
"
  fi
  printf '%s' "$_hits"
}

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

    # ① 设备侧只准用 shellkit 的 **POSIX 子集**，bash 库一律不许
    #
    # ⚠ **允许 POSIX 子集**（2026-11-19，上游 #144 交付 lib/posix/）：
    #   `shellkit-posix.sh` 是纯 POSIX sh 语法 ⇒ busybox ash 能解析 ⇒ 设备侧可用。
    #   ⇒ 允许的**只有这一个文件**；其余 shellkit 产物（lib/、bootstrap.sh、CLI…）
    #     都是 bash 基线 ⇒ 带进设备 = 装机即挂。
    #   ⇒ 判据按**路径形态**判（不按「出现 shellkit 字样」判）：后者会把注释里
    #     提到 shellkit 的正常说明也判红。
    bad_refs=""
    for pat in vendor/shellkit third_party/shellkit shellkit/lib/ lib/bootstrap.sh lib/core/ shellkit/repair.sh; do
      hit="$(LC_ALL=C grep -Fn "$pat" "$f" || true)"
      if [ -n "$hit" ]; then
        bad_refs="$bad_refs$hit
"
      fi
    done
    if [ -n "$bad_refs" ]; then
      BAD=1
      echo "✗ ${f}：设备侧脚本引用了 shellkit 的**非 POSIX 部分**——设备是 busybox ash，装不了 bash 库"
      printf '%s' "$bad_refs" | sed 's/^/    /'
      continue
    fi

    # ①b 引用了 POSIX 子集 ⇒ 仓内必须**带着这份文件**
    #    （否则打包不会带上它 ⇒ 装机即挂，而门禁本该在装机前拦住）。
    #    落点：脚本同目录的 shellkit-posix.sh，或同目录 lib/ 下的。
    if LC_ALL=C grep -Fq 'shellkit-posix.sh' "$f"; then
      sk_lib=""
      for cand in "$(dirname "$f")/shellkit-posix.sh" "$(dirname "$f")/lib/shellkit-posix.sh"; do
        if [ -f "$cand" ]; then
          sk_lib="$cand"
          break
        fi
      done
      if [ -z "$sk_lib" ]; then
        BAD=1
        echo "✗ ${f}：引用了 shellkit POSIX 子集，但仓内**没有**这份文件（脚本同目录 / 同目录 lib/ 都没有）"
        echo "    ⇒ 打包不会带上它 ⇒ 装机即挂。修法: 把 shellkit 的 lib/posix/shellkit-posix.sh 复制到设备脚本同目录"
        continue
      fi
      # POSIX 子集自己也要 ash 干净（它要上设备！）⇒ 与设备脚本同一把尺子
      if ! sh -n "$sk_lib" 2>/dev/null; then
        BAD=1
        echo "✗ ${sk_lib}：POSIX 子集自己都不是 POSIX 语法（sh -n 解析失败）"
        continue
      fi
      lib_hits="$(bashism_hits "$sk_lib")"
      if [ -n "$lib_hits" ]; then
        BAD=1
        echo "✗ ${sk_lib}：POSIX 子集里含 bashism（它要上设备！）:"
        printf '%s' "$lib_hits" | sed 's/^/    /'
      fi
    fi

    shebang="$(head -n1 "$f")"
    case "$shebang" in
      *bash*)
        # ⚠ **不再豁免**（2026-11-19）：此前 bash shebang 的设备侧脚本
        #   （QTS/OpenWrt 的 prewire_beam_box）**只受判据①约束** ⇒ 判据②③根本
        #   没跑 ⇒ openwrt#215 / qnap#204 记的「出厂预接线在真机静默空跑」
        #   （busybox ash 上 pipefail = Illegal option）从这道门禁溜了过去。
        #   ⇒ 现在 bash shebang 直接判红：设备是 busybox ash，装不了 bash 库。
        BAD=1
        echo "✗ ${f}：设备侧脚本是 bash shebang（${shebang}）——设备是 busybox ash，装不了 bash 库"
        echo "    修法: 改 #!/bin/sh 并去掉 pipefail 等 bash 专有选项（openwrt#215 / qnap#204）"
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

    # ③ bashism 扫描（剥注释后比对）—— 判据实现见 bashism_hits()
    hits="$(bashism_hits "$f")"
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

  # shellcheck disable=SC2016  # 单引号是**故意的**：$ 必须在求值时（trap 触发 / 生成文件内容）才展开
  printf '%s\n' '#!/bin/sh' 'if [ -n "$x" ]; then' '  echo ok' 'fi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  printf '%s\n' '#!/bin/sh /etc/rc.common' 'start_service() {' '  echo start' '}' >"$TMP/openwrt/openwrt/pigeonbox.init"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：POSIX 干净 ⇒ 门禁绿"
  else
    echo "  ✗ 基线：POSIX 干净竟然判红 ⇒ 门禁本身坏了" >&2
    exit 1
  fi

  # shellcheck disable=SC2016  # 单引号是**故意的**：$ 必须在求值时（trap 触发 / 生成文件内容）才展开
  printf '%s\n' '#!/bin/sh' 'if [[ -n "$x" ]]; then' '  echo ok' 'fi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「bashism」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「bashism（[[ ]]）」⇒ 门禁变红（断言有牙齿）"
  # ANSI-C 引号（$'…'）：**真用法**必须判红（bash 专有，POSIX sh 不认）。
  cat >"$TMP/qnap/qpkg/shared/pigeonbox.sh" <<'EOS'
#!/bin/sh
x=$'\n'
echo "$x"
EOS
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「ANSI-C 引号」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「ANSI-C 引号（$'…'）」⇒ 门禁变红（断言有牙齿）"

  # ⚠️ **反向对照（误报防护）**：「$'」出现在**单引号闭合**处（正则以 $ 结尾）时
  #   **不得**判红 —— 这正是 2026-11-18 误报的现场（synology spk/scripts/postinst:25）。
  cat >"$TMP/qnap/qpkg/shared/pigeonbox.sh" <<'EOS'
#!/bin/sh
valid_data_dir() {
  case "$1" in
    */../*|*/..|../*|..) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^/volume[^/]+/.+$'
}
EOS
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✓ 「$'」出现在单引号闭合处 ⇒ 不误报（反向对照通过）"
  else
    echo "  ✗ 「$'」出现在单引号闭合处被判红 ⇒ 门禁误报（2026-11-18 实录的坑）" >&2
    exit 1
  fi

  printf '%s\n' '#!/bin/sh' '. /opt/app/third_party/shellkit/lib/bootstrap.sh' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「设备侧引用 shellkit」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「设备侧引用 shellkit」⇒ 门禁变红（断言有牙齿）"

  # 注入「bash shebang 的设备侧脚本」⇒ 必须判红
  #   2026-11-19：此前 bash shebang 被**豁免**判据②③ ⇒ openwrt#215 / qnap#204
  #   记的「出厂预接线在真机静默空跑」（busybox ash 上 pipefail = Illegal option）
  #   从这道门禁溜了过去 ⇒ 现在 bash shebang 直接判红。
  printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' 'echo hi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「bash shebang」后门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 注入「bash shebang」⇒ 门禁变红（断言有牙齿）"

  # 反向对照：引用 **POSIX 子集** 是**允许**的（上游 #144 交付的 ash 兼容子集）
  #   ⇒ 不得误报。样本仓里要**带着**那份文件（否则触发判据①b，见下）。
  printf '%s\n' '#!/bin/sh' '. /usr/lib/pigeonbox/shellkit-posix.sh' 'echo hi' >"$TMP/qnap/qpkg/shared/pigeonbox.sh"
  if [ -r "$ROOT/vendor/shellkit/lib/posix/shellkit-posix.sh" ]; then
    cp "$ROOT/vendor/shellkit/lib/posix/shellkit-posix.sh" "$TMP/qnap/qpkg/shared/shellkit-posix.sh"
  fi
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✓ 引用 POSIX 子集（且仓内带着它）⇒ 不误报（反向对照通过）"
  else
    echo "  ✗ 引用 POSIX 子集被判红 ⇒ 门禁误报（POSIX 子集是设备侧合法依赖）" >&2
    exit 1
  fi

  # 引用 POSIX 子集但**仓内没有**那份文件 ⇒ 判红
  #   （打包不会带上它 ⇒ 装机即挂，而门禁本该在装机前拦住）
  rm -f "$TMP/qnap/qpkg/shared/shellkit-posix.sh"
  if SHELL_DEVICE_SH_ROOT="$TMP" bash "$ROOT/scripts/check-device-shell-ash.sh" >/dev/null 2>&1; then
    echo "  ✗ 引用 POSIX 子集却仓内缺那份文件时门禁仍绿 ⇒ 断言无效" >&2
    exit 1
  fi
  echo "  ✓ 引用 POSIX 子集但仓内缺那份文件 ⇒ 门禁变红（断言有牙齿）"

  # shellcheck disable=SC2016  # 单引号是**故意的**：$ 必须在求值时（trap 触发 / 生成文件内容）才展开
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
