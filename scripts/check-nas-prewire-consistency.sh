#!/usr/bin/env bash
# 门禁：NAS 三端的「出厂预接线」核心脚本必须**字节一致**（hub#241）。
#
# 为什么这道门禁值得有（2026-11-01 实测背景）：
#   这份脚本承载**同一条安全相关的逻辑**：
#     · 建/复用一把专用 Box API Key（幂等，缺失才建）
#     · 明文落缓存（0600）
#     · 每次启动校验有效性（自愈：换库/撤销后重建）
#     · 写 p2pcweb 配置（**只更新非空字段**，不冲掉用户已配的 registry）
#     · 令牌走 X-P2PCWEB 头
#   ⇒ 漏改一端 ⇒ 该端的 Beam 预接线行为与另两端不一致；
#   ⇒ 而预接线失败是**优雅降级为「手填」旧行为**（失败不阻断启动）
#   ⇒ 症状是「这个平台的 Beam 配不上、另一个平台能配」⇒ 极难定位、极难归因。
#
# 判据：三份文件的 sha256 必须**逐字相同**（字节一致，不是文本 diff）。
#   任一端**缺失** ⇒ 同样判红（缺失 ≠ 字节一致）。
#   ⚠️ 这正是 2026-11-01 那轮真实踩到的坑的同源风险：
#   fnos/qnap/openwrt 三端的脚本**内容逐字节相同**、只有所在目录不同
#   （fnos/cmd/ · qpkg/shared/ · openwrt/）
#   ⇒ 任何「按目录名写死路径」的引用都会在另两端指错。
#
# 三种形态都要判对（AGENTS.md 教训：门禁自测若只覆盖一种形态，另一种就是盲区）：
#   ① **判定形态**：hub CI 把 NAS 各仓检出到同一 workspace ⇒ 三份文件都在 ⇒ 比对；
#   ② **跳过形态**：本地单仓 checkout ⇒ 三份都不在 ⇒ 打印**明确的跳过原因**后放行
#      （不能让「没扫到」看起来像「扫过且通过」）；
#   ③ **缺失形态**：只有部分仓在 ⇒ 判红（半截检出不是一致）。
#   ⚠️ **跳过形态也必须跑自证**（--selfcheck）：否则本地最常见的形态里，
#      「自证」这段代码压根没执行 ⇒ 本地跑绿了也证明不了什么（2026-11-01 自踩）。
#
# 用法：bash scripts/check-nas-prewire-consistency.sh [--selfcheck]
set -uo pipefail

ROOT="${NAS_PREWIRE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *) echo "用法: $0 [--selfcheck]"; exit 2 ;;
  esac
done

# 三端 → 脚本路径（相对 ROOT）
#   格式：<端名>|<workspace 内的仓目录>/<仓内路径>
#   ⚠️ hub CI 把每个仓检出到 workspace 的一个**子目录**里（fnos/ qnap/ openwrt/）
#      ⇒ 路径是「子目录 + 仓内路径」两段，别只写仓内路径。
ENDS="fnos|fnos/fnos/cmd/prewire_beam_box
qnap|qnap/qpkg/shared/prewire_beam_box
openwrt|openwrt/openwrt/prewire_beam_box"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf ''
  fi
}

TMP_ALL=$(mktemp)
SELF_TMP=""
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -f "$TMP_ALL"; [ -n "$SELF_TMP" ] && rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

present=0
missing=""
: > "$TMP_ALL"
for e in $ENDS; do
  name="${e%%|*}"
  path="${e#*|}"
  if [ -f "$path" ]; then
    s=$(sha_of "$path")
    if [ -z "$s" ]; then
      echo "✗ 找不到 sha256 工具（sha256sum / shasum）⇒ 门禁自身失效"
      exit 1
    fi
    present=$((present + 1))
    printf '%s\t%s\t%s\n' "$name" "$s" "$path" >> "$TMP_ALL"
  else
    missing="${missing}${name} "
  fi
done

# ── 判定（仅在「三端都在」时进行）──────────────────────────────────────
judge() {
  echo "→ 三端预接线脚本 sha256："
  while IFS="$(printf '\t')" read -r n s p; do
    [ -n "$n" ] || continue
    printf '  %-8s %s  %s\n' "$n" "$s" "$p"
  done < "$TMP_ALL"

  if [ -n "$missing" ]; then
    echo "✗ 以下端的脚本**缺失**（缺失 ≠ 字节一致）：${missing}"
    echo "  ⇒ 三端必须同时存在且内容一致；只到一端说明检出不全或脚本被改名。"
    return 1
  fi

  uniq_sha=$(cut -f2 "$TMP_ALL" | sort -u | wc -l | tr -d ' ')
  if [ "$uniq_sha" -ne 1 ]; then
    echo "✗ 三端预接线脚本**字节不一致**（改了一端漏了另一端？）——请同步全部三端。"
    echo "  具体是哪两端不同："
    awk -F"$(printf '\t')" '
      { sha[$1] = $2 }
      END {
        n = split("fnos qnap openwrt", a, " ")
        for (i = 1; i <= n; i++) {
          for (j = i + 1; j <= n; j++) {
            if ((a[i] in sha) && (a[j] in sha) && sha[a[i]] != sha[a[j]]) {
              printf "    %s ≠ %s\n", a[i], a[j]
            }
          }
        }
      }' "$TMP_ALL"
    return 1
  fi

  echo "✓ 三端预接线脚本字节一致（sha256=$(cut -f2 "$TMP_ALL" | head -1)）"
  return 0
}

if [ "$present" -eq 0 ]; then
  echo "! 跳过：NAS 各仓不在本 workspace（缺 ${missing}）⇒ 本门禁在此形态下无法判定"
  echo "  （hub CI 会把 fnos/qnap/openwrt 检出到同一 workspace ⇒ 那里走判定路径）"
else
  judge || exit 1
fi

# ── 自证：证明这条断言**有牙齿**（改一端 ⇒ 必须判红）────────────────────
# ⚠️ 自证要驱动**脚本自己**（"$0" + 注入的 ROOT），不是另写一份副本的逻辑。
# ⚠️ 自证在**跳过形态下也要跑**（否则本地形态永远证明不了什么）。
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  self_fail=0

  make_fakes() {
    # $1=假 workspace 根，$2=三端共同内容
    mkdir -p "$1/fnos/fnos/cmd" "$1/qnap/qpkg/shared" "$1/openwrt/openwrt"
    printf '%s' "$2" > "$1/fnos/fnos/cmd/prewire_beam_box"
    printf '%s' "$2" > "$1/qnap/qpkg/shared/prewire_beam_box"
    printf '%s' "$2" > "$1/openwrt/openwrt/prewire_beam_box"
  }

  # 用例 ①：三端一致 ⇒ 绿（无误报）
  WS_OK="$SELF_TMP/ok"
  mkdir -p "$WS_OK"
  make_fakes "$WS_OK" "#!/bin/sh
# prewire_beam_box（假内容，仅用于门禁自证）
echo prewire
"
  if NAS_PREWIRE_ROOT="$WS_OK" bash "$ROOT/scripts/check-nas-prewire-consistency.sh" >/dev/null 2>&1; then
    echo "  ✓ 三端一致 ⇒ 本门禁保持绿（无误报）"
  else
    echo "  ✗ 三端一致被判红 ⇒ 门禁误报" >&2
    self_fail=1
  fi

  # 用例 ②：改一端（openwrt）⇒ 必须判红，**且要点名是哪两端不同**
  WS_BAD="$SELF_TMP/bad"
  mkdir -p "$WS_BAD"
  make_fakes "$WS_BAD" "#!/bin/sh
echo prewire
"
  printf '%s' "#!/bin/sh
echo prewire-changed
" > "$WS_BAD/openwrt/openwrt/prewire_beam_box"
  bad_out=$(NAS_PREWIRE_ROOT="$WS_BAD" bash "$ROOT/scripts/check-nas-prewire-consistency.sh" 2>&1)
  bad_rc=$?
  if [ "$bad_rc" -eq 0 ]; then
    echo "  ✗ 改了一端后本门禁仍绿 ⇒ 判据无效" >&2
    self_fail=1
  else
    echo "  ✓ 改一端 ⇒ 本门禁变红（判据有牙齿）"
  fi
  # ⚠️ 断言只验「信息」，不验「排版」：配对顺序是 i<j（fnos≠openwrt），
  #    写成「openwrt ≠ fnos」这种固定顺序 ⇒ 断言与实现耦合 ⇒ 改个顺序就假红。
  if printf '%s' "$bad_out" | grep -Eq '(fnos.*openwrt)|(openwrt.*fnos)' \
     && printf '%s' "$bad_out" | grep -Eq '(qnap.*openwrt)|(openwrt.*qnap)'; then
    echo "  ✓ 判红时点出了是哪两端不同（fnos×openwrt / qnap×openwrt，与顺序无关）"
  else
    echo "  ✗ 判红但没点名是哪两端不同 ⇒ 结论不可用" >&2
    self_fail=1
  fi

  # 用例 ③：缺一端 ⇒ 判红（半截检出不是一致）
  WS_MISS="$SELF_TMP/miss"
  mkdir -p "$WS_MISS"
  make_fakes "$WS_MISS" "#!/bin/sh
echo prewire
"
  rm -f "$WS_MISS/qnap/qpkg/shared/prewire_beam_box"
  if NAS_PREWIRE_ROOT="$WS_MISS" bash "$ROOT/scripts/check-nas-prewire-consistency.sh" >/dev/null 2>&1; then
    echo "  ✗ 缺一端时本门禁仍绿 ⇒ 判据无效" >&2
    self_fail=1
  else
    echo "  ✓ 缺一端 ⇒ 本门禁变红（缺失 ≠ 一致）"
  fi

  # 用例 ④：一个仓都不在 ⇒ 走「跳过」形态（本地单仓 checkout）⇒ 放行但打印原因
  WS_NONE="$SELF_TMP/none"
  mkdir -p "$WS_NONE"
  none_out=$(NAS_PREWIRE_ROOT="$WS_NONE" bash "$ROOT/scripts/check-nas-prewire-consistency.sh" 2>&1)
  none_rc=$?
  if [ "$none_rc" -ne 0 ]; then
    echo "  ✗ 一个仓都不在时本门禁判红 ⇒ 跳过形态没实现（本地会误报）" >&2
    self_fail=1
  elif printf '%s' "$none_out" | grep -q '跳过'; then
    echo "  ✓ 一个仓都不在 ⇒ 明确打印「跳过」并放行（本地形态不误报）"
  else
    echo "  ✗ 跳过形态没有打印原因 ⇒ 「没扫到」会看起来像「扫过且通过」" >&2
    self_fail=1
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：一致⇒绿、改一端⇒红、缺一端⇒红、无仓⇒跳过 ⇒ 判据有牙齿"
fi

OK=1
