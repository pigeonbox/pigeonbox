#!/usr/bin/env bash
# 形态：迁移中途失败注入（hub#660 · L7 升级层 · 升级矩阵的一格）。
#
# 为什么要有这一格（2026-11-18 生态技术评审，L7 升级层）：
#   升级矩阵里最危险的一格不是「升级成功」，而是「升级**中途**失败」——
#   数据搬迁/快照写到一半失败时，旧版本必须**仍可启动**、业务数据必须**无损**、
#   失败必须**可见**、且**不留半份快照**（半份快照比没快照更坏：它看起来像回滚点，
#   实际是残缺的，真回滚时会把用户数据搞坏）。
#   此前生态只有「备份失败 ⇒ 中止」的断言（各平台仓自己的测试），
#   **没有一处**把这四件事放在同一处机械判定 ⇒ 本形态在 hub 侧补上。
#
# 本脚本**跑各平台真实的升级钩子**（不是复刻逻辑），用注入的 cp 失败模拟
# 「迁移/快照写一半失败」，逐端判定：
#   · qnap     —— qpkg/package_routines 的 pkg_pre_install（中止型：失败即中止升级）
#   · synology —— spk/scripts/preupgrade（中止型：失败即中止升级）
#   · openwrt  —— openwrt/preupgrade_backup（**best-effort 型**：失败**不得**中止
#                  安装——它跑在新文件已就位之后，abort 只会把服务留在停机状态；
#                  但必须响亮报错 + 不留残缺快照）
#
# 判定项（每端四条 + 退出码语义）：
#   ① 失败可见      —— 钩子输出/日志里有明确失败信息
#   ② 数据无损      —— 业务库 sha256 逐字未变
#   ③ 不留半份快照  —— 失败路径不得留下 <db>.bak-* 之类的残缺快照
#   ④ 旧版本仍可启动 —— 已装内容（安装目录里的产物标记）逐字未变
#                      （中止型平台：中止发生在覆盖已装内容之前 ⇒ 旧安装原封不动）
#   ＋ 退出码语义（中止型必须非 0；best-effort 型必须 0）
#
# 检出形态（三态，与 check-upgrade-recoverability.sh 同口径）：
#   · 判定形态：平台仓在位（hub CI 把 qnap/synology/openwrt 检出到同一 workspace）⇒ 逐端跑；
#   · 跳过形态：平台仓不在位 ⇒ 打印**明确的跳过原因**后放行（没扫到 ≠ 扫过且通过）；
#   · 负对照：--selfcheck 注入 4 类坏钩子（不中止/留半份快照/破坏源库/失败却中止）
#              ⇒ 逐条必须判红。
#
# env 覆盖：
#   UPGRADE_MIGRATION_ROOT          平台仓所在根（默认 = 本仓根）
#   UPGRADE_MIGRATION_ONLY          只跑某一端（qnap|synology|openwrt），供自证/排障
#   UPGRADE_MIGRATION_QNAP_HOOK     覆盖 qnap 钩子路径
#   UPGRADE_MIGRATION_SYNOLOGY_HOOK 覆盖 synology 钩子路径
#   UPGRADE_MIGRATION_OPENWRT_HOOK  覆盖 openwrt 钩子路径
#
# 用法: bash scripts/check-upgrade-migration-failure.sh [--selfcheck]
set -uo pipefail

HUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT_ROOT="${UPGRADE_MIGRATION_ROOT:-$HUB_ROOT}"
ONLY="${UPGRADE_MIGRATION_ONLY:-}"

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

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

fail_flag=0
skipped=0
attempted=0
passed=0

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

# 注入的 cp 失败桩：模拟「数据搬迁/快照写一半失败」
make_cp_stub() {
  mkdir -p "$TMP/stubbin"
  cat >"$TMP/stubbin/cp" <<'STUB'
#!/bin/sh
echo "cp: 注入的迁移失败（模拟数据搬迁/快照写一半失败）" >&2
exit 1
STUB
  chmod +x "$TMP/stubbin/cp"
}

# ── 判定：四件事 + 退出码语义 ─────────────────────────────────────────────
judge() {
  local plat=$1 sem=$2 rc=$3 out=$4 db_before=$5 db_after=$6 snaps=$7 mk_before=$8 mk_after=$9
  local bad=""

  case "$plat" in
    qnap) echo "$out" | grep -q "Installation Abort" || bad="$bad 失败不可见" ;;
    synology) echo "$out" | grep -q "备份业务库失败" || bad="$bad 失败不可见" ;;
    openwrt) echo "$out" | grep -q "快照失败" || bad="$bad 失败不可见" ;;
  esac
  if [ -z "$db_before" ] || [ "$db_before" != "$db_after" ]; then
    bad="$bad 业务数据被改动"
  fi
  if [ "$snaps" -ne 0 ]; then
    bad="$bad 留下半份快照($snaps 份)"
  fi
  if [ -z "$mk_before" ] || [ "$mk_before" != "$mk_after" ]; then
    bad="$bad 已装内容被改动"
  fi
  if [ "$sem" = "abort" ]; then
    if [ "$rc" -eq 0 ]; then
      bad="$bad 失败却放行(应中止升级)"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      bad="$bad 失败却中止安装(best-effort 不得 abort)"
    fi
  fi

  if [ -n "$bad" ]; then
    echo "  ✗ $plat：迁移中途失败形态不成立 ——$bad"
    echo "      钩子输出：$(echo "$out" | tr '\n' ' ' | cut -c1-200)"
    fail_flag=1
    return 1
  fi
  if [ "$sem" = "abort" ]; then
    echo "  ✓ $plat：迁移中途失败⇒失败可见 + 数据无损 + 不留半份快照 + 旧版本仍可启动（中止升级，退出码 $rc）"
  else
    echo "  ✓ $plat：迁移中途失败⇒失败可见 + 数据无损 + 不留半份快照 + 旧版本仍可启动（best-effort：升级继续，退出码 $rc）"
  fi
  passed=$((passed + 1))
  return 0
}

count_snaps() {
  local dir=$1 n=0 f
  for f in "$dir"/*.bak-* "$dir"/*.bak-half "$dir"/*.tmp "$dir"/*.part; do
    [ -e "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

hook_path() {
  case "$1" in
    qnap) echo "${UPGRADE_MIGRATION_QNAP_HOOK:-$PLAT_ROOT/qnap/qpkg/package_routines}" ;;
    synology) echo "${UPGRADE_MIGRATION_SYNOLOGY_HOOK:-$PLAT_ROOT/synology/spk/scripts/preupgrade}" ;;
    openwrt) echo "${UPGRADE_MIGRATION_OPENWRT_HOOK:-$PLAT_ROOT/openwrt/openwrt/preupgrade_backup}" ;;
    *) echo "" ;;
  esac
}

# ── qnap：pkg_pre_install（中止型） ───────────────────────────────────────
run_qnap() {
  local hook=$1 iso="$TMP/qnap"
  mkdir -p "$iso/pkg/www" "$iso/vol/pigeonbox/data" "$iso/bin"
  printf 'PB-MIGRATION-FAILURE-FIXTURE-DB\n' >"$iso/vol/pigeonbox/data/fileCodeBox.db"
  printf 'installed-payload-marker\n' >"$iso/pkg/www/payload-marker.txt"
  local db="$iso/vol/pigeonbox/data/fileCodeBox.db"
  local mk="$iso/pkg/www/payload-marker.txt"

  cat >"$iso/bin/getcfg" <<'MOCK'
#!/bin/sh
# mock getcfg：只回 defVolMP（其余键回空）
if [ "${1:-}" = "SHARE_DEF" ] && [ "${2:-}" = "defVolMP" ]; then
  echo "$MOCK_VOL"
fi
MOCK
  cat >"$iso/bin/write_log" <<'MOCK'
#!/bin/sh
echo "$*" >>"$MOCK_LOG"
MOCK
  chmod +x "$iso/bin/getcfg" "$iso/bin/write_log"

  local db_before mk_before out rc=0
  db_before="$(sha256_of "$db")"
  mk_before="$(sha256_of "$mk")"
  out=$(PATH="$TMP/stubbin:$PATH" MOCK_VOL="$iso/vol" MOCK_LOG="$iso/write.log" \
    FCB_GETCFG="$iso/bin/getcfg" FCB_DEF_SHARE_INFO="$iso/def_share.info" \
    FCB_WRITE_LOG="$iso/bin/write_log" SYS_QPKG_DIR="$iso/pkg" \
    sh -c '. "$1"; pkg_pre_install' _ "$hook" 2>&1) || rc=$?

  local db_after mk_after
  db_after="$(sha256_of "$db")"
  mk_after="$(sha256_of "$mk")"
  judge qnap abort "$rc" "$out" "$db_before" "$db_after" \
    "$(count_snaps "$iso/vol/pigeonbox/data")" "$mk_before" "$mk_after"
}

# ── synology：preupgrade（中止型） ───────────────────────────────────────
run_synology() {
  local hook=$1 iso="$TMP/synology"
  mkdir -p "$iso/var/data" "$iso/pkg"
  printf 'PB-MIGRATION-FAILURE-FIXTURE-DB\n' >"$iso/var/data/fileCodeBox.db"
  printf 'installed-payload-marker\n' >"$iso/pkg/payload-marker.txt"
  local db="$iso/var/data/fileCodeBox.db"
  local mk="$iso/pkg/payload-marker.txt"

  local db_before mk_before out rc=0
  db_before="$(sha256_of "$db")"
  mk_before="$(sha256_of "$mk")"
  out=$(PATH="$TMP/stubbin:$PATH" SYNOPKG_PKGVAR="$iso/var" \
    sh "$hook" 2>&1) || rc=$?

  local db_after mk_after
  db_after="$(sha256_of "$db")"
  mk_after="$(sha256_of "$mk")"
  judge synology abort "$rc" "$out" "$db_before" "$db_after" \
    "$(count_snaps "$iso/var/data")" "$mk_before" "$mk_after"
}

# ── openwrt：preupgrade_backup（best-effort 型） ──────────────────────────
run_openwrt() {
  local hook=$1 iso="$TMP/openwrt"
  mkdir -p "$iso/data" "$iso/pkg"
  printf 'PB-MIGRATION-FAILURE-FIXTURE-DB\n' >"$iso/data/fileCodeBox.db"
  printf 'installed-payload-marker\n' >"$iso/pkg/payload-marker.txt"
  local db="$iso/data/fileCodeBox.db"
  local mk="$iso/pkg/payload-marker.txt"

  local db_before mk_before out rc=0
  db_before="$(sha256_of "$db")"
  mk_before="$(sha256_of "$mk")"
  # MIN_FREE_KB=1：绕开空间守卫（那是另一格），本形态只注入「写失败」
  out=$(PATH="$TMP/stubbin:$PATH" PB_PREUPGRADE_DB="$db" PB_PREUPGRADE_MIN_FREE_KB=1 \
    sh "$hook" 2>&1) || rc=$?

  local db_after mk_after
  db_after="$(sha256_of "$db")"
  mk_after="$(sha256_of "$mk")"
  judge openwrt best-effort "$rc" "$out" "$db_before" "$db_after" \
    "$(count_snaps "$iso/data")" "$mk_before" "$mk_after"
}

run_platform() {
  local plat=$1 hook
  hook="$(hook_path "$plat")"
  if [ -z "$hook" ] || [ ! -f "$hook" ]; then
    echo "  ⏳ $plat：升级钩子不在位（$hook）⇒ 本端未覆盖（登记在案）"
    skipped=$((skipped + 1))
    return 0
  fi
  case "$plat" in
    qnap) run_qnap "$hook" ;;
    synology) run_synology "$hook" ;;
    openwrt) run_openwrt "$hook" ;;
  esac
  # attempted 记「跑过」（无论成败）——跳过的端不得把**跑失败的端**掩成「跳过形态」
  attempted=$((attempted + 1))
}

# ── 自证：注入坏钩子 ⇒ 必须判红 ──────────────────────────────────────────
mutate() {
  awk "$3" "$1" >"$2"
}

selfcheck() {
  local rc=0 plat hook src dst
  for plat in qnap synology openwrt; do
    hook="$(hook_path "$plat")"
    if [ -z "$hook" ] || [ ! -f "$hook" ]; then
      echo "  ⏳ 自证：$plat 钩子不在位（$hook）⇒ 该端负对照跳过"
      continue
    fi
    src="$TMP/mut-$plat-orig"
    cp "$hook" "$src"
    case "$plat" in
      qnap)
        dst="$TMP/mut-$plat-noabort"
        mutate "$src" "$dst" '/安装中止/ {blk=1}
blk && /exit 1/ {sub(/exit 1/, "exit 0"); blk=0}
{print}'
        if UPGRADE_MIGRATION_QNAP_HOOK="$dst" UPGRADE_MIGRATION_ONLY=qnap \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时不中止升级 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时不中止升级 ⇒ 判红"
        fi
        dst="$TMP/mut-$plat-halfsnap"
        mutate "$src" "$dst" '{print}
/安装中止/ && !done {print "            touch \"\${_db.bak-half\""; done=1}'
        if UPGRADE_MIGRATION_QNAP_HOOK="$dst" UPGRADE_MIGRATION_ONLY=qnap \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时留下半份快照 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时留下半份快照 ⇒ 判红"
        fi
        dst="$TMP/mut-$plat-clobber"
        mutate "$src" "$dst" '{print}
/安装中止/ && !done {print "            : > \"\${_db\""; done=1}'
        if UPGRADE_MIGRATION_QNAP_HOOK="$dst" UPGRADE_MIGRATION_ONLY=qnap \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时破坏源库 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时破坏源库 ⇒ 判红"
        fi
        ;;
      synology)
        dst="$TMP/mut-$plat-noabort"
        mutate "$src" "$dst" '/备份业务库失败/ {blk=1}
blk && /exit 1/ {sub(/exit 1/, "exit 0"); blk=0}
{print}'
        if UPGRADE_MIGRATION_SYNOLOGY_HOOK="$dst" UPGRADE_MIGRATION_ONLY=synology \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时不中止升级 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时不中止升级 ⇒ 判红"
        fi
        dst="$TMP/mut-$plat-halfsnap"
        mutate "$src" "$dst" '{print}
/备份业务库失败/ && !done {print "    touch \"\$BAK\""; done=1}'
        if UPGRADE_MIGRATION_SYNOLOGY_HOOK="$dst" UPGRADE_MIGRATION_ONLY=synology \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时留下半份快照 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时留下半份快照 ⇒ 判红"
        fi
        dst="$TMP/mut-$plat-clobber"
        mutate "$src" "$dst" '{print}
/备份业务库失败/ && !done {print "    : > \"\$DB\""; done=1}'
        if UPGRADE_MIGRATION_SYNOLOGY_HOOK="$dst" UPGRADE_MIGRATION_ONLY=synology \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时破坏源库 ⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时破坏源库 ⇒ 判红"
        fi
        ;;
      openwrt)
        dst="$TMP/mut-$plat-abort"
        mutate "$src" "$dst" '/快照失败/ {blk=1}
blk && /exit 0/ {sub(/exit 0/, "exit 1"); blk=0}
{print}'
        if UPGRADE_MIGRATION_OPENWRT_HOOK="$dst" UPGRADE_MIGRATION_ONLY=openwrt \
          bash "$0" >/dev/null 2>&1; then
          echo "  ✗ 自证：$plat 失败时中止安装（best-effort 不得 abort）⇒ 门禁仍绿"
          rc=1
        else
          echo "  ✓ 自证：$plat 失败时中止安装（best-effort 不得 abort）⇒ 判红"
        fi
        ;;
    esac
  done
  return "$rc"
}

if [ "$SELFCHECK" -eq 1 ]; then
  echo "── 迁移中途失败形态 selfcheck（负对照）"
  make_cp_stub
  if selfcheck; then
    echo "✓ 迁移中途失败形态自证通过（坏钩子逐条判红）"
    OK=1
    exit 0
  fi
  echo "✗ 迁移中途失败形态自证失败"
  exit 1
fi

make_cp_stub
echo "── 迁移中途失败注入（跑各平台真实升级钩子；cp 失败=数据搬迁/快照写一半失败）"
for plat in qnap synology openwrt; do
  if [ -n "$ONLY" ] && [ "$ONLY" != "$plat" ]; then
    continue
  fi
  run_platform "$plat"
done

if [ "$attempted" -eq 0 ]; then
  echo "跳过形态：平台仓不在位（$PLAT_ROOT）⇒ 本形态未覆盖（登记在案；没扫到 ≠ 扫过且通过）"
  OK=1
  exit 0
fi
if [ "$fail_flag" -ne 0 ]; then
  echo "✗ 迁移中途失败形态：至少一端不成立（跑过 $attempted 端，通过 $passed 端）"
  exit 1
fi
if [ "$skipped" -ne 0 ]; then
  echo "✓ 迁移中途失败形态：已跑端全部通过（$skipped 端未覆盖，见上方 ⏳ 行）"
else
  echo "✓ 迁移中途失败形态：各端全部通过（$passed 端）"
fi
OK=1
exit 0
