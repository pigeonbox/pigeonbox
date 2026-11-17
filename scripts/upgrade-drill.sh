#!/usr/bin/env bash
# 发布后升级演练：N-1 → N / N-2 → N 的**制品级**真升级（hub#660 · L7 升级层）。
#
# 为什么是「发布后」而不是 PR 门禁（母会话拍板）：
#   真装演练需要**当前车（N）的产物**，而 N 的产物在 N 的 PR/CI 阶段**还不存在**
#   （还没发版）⇒ 真装演练不可能当 PR 门禁 ⇒ 静态部分在
#   scripts/check-upgrade-matrix.sh，**真演练**在本脚本 + .github/workflows/upgrade-drill.yml
#   （release 事件 / cron / 手动，不挡合并）。
#
# 每一格演练做什么（每平台一条链）：
#   ① 下载 N-1（或 N-2）的**真实产物**（hub Release 资产），按当车 manifest 的
#      sha256 **逐字校验**（下载截断/串包当场暴露）；
#   ② 解包到**隔离目录**（不进真机路径，不碰任何真实数据）；
#   ③ 在隔离的数据目录里**植入业务数据**（一个 DB 文件 + 一个上传文件）；
#   ④ 走该平台**既有的升级钩子**（产物内自带：DSM preupgrade / QTS pkg_pre_install /
#      OpenWrt preupgrade_backup）⇒ 生成回滚点（快照）；
#   ⑤ 用 **N 的产物**覆盖升级（解包覆盖同一安装根）；
#   ⑥ 断言三条：
#      · 业务数据**逐字未变**（DB sha256 + 上传文件 sha256）；
#      · **版本号已更新为 N**（各平台自己的版本标记）；
#      · **回滚点存在且逐字等于升级前的库**（<db>.bak-<时间戳>）⇒ 可回滚。
#
# 覆盖矩阵（哪些平台真做了、哪些做不了）：
#   · synology —— 真做（spk 是普通 tar；preupgrade 支持 SYNOPKG_PKGVAR 覆盖 ⇒ 可隔离）
#   · qnap     —— 真做（qpkg 是「自解压壳 + tar 载荷」；package_routines 的
#                 pkg_pre_install 支持 FCB_GETCFG mock ⇒ 可隔离）
#   · openwrt  —— 真做（ipk 是 tar.gz{control,data}；preupgrade_backup 支持
#                 PB_PREUPGRADE_DB 覆盖 ⇒ 可隔离）
#   · fnos     —— **制品级**（fpk 是 tar.gz，可解包可换版）；但它的升级回调是
#                 fnOS 运行时二进制（cmd/upgrade_callback），无隔离入口 ⇒ 不跑钩子
#   · ugreen / terramaster —— **制品级**（zip 编排壳；数据在 docker 卷里，本来就
#                 不在制品内 ⇒ 换版天然不碰数据）
#   · desktop  —— **做不了**：产物是各 OS 的安装包（dmg/msi/exe/deb/rpm/AppImage），
#                 没有「解包即安装目录」的统一形态，且应用数据目录由操作系统托管
#                 ⇒ CI 里无法脚本化（详见 docs/upgrade-matrix.md）
#
# env 覆盖：
#   UPGRADE_DRILL_ROOT     hub 根
#   UPGRADE_DRILL_CACHE    产物缓存目录（默认 <hub>/.upgrade-drill-cache）
#   UPGRADE_DRILL_WORK     隔离工作目录（默认 <hub>/.upgrade-drill-work）
#   UPGRADE_DRILL_TRAIN    目标车号（默认：最后一辆已发货车次）
#   UPGRADE_DRILL_PLATFORMS 要演练的平台（默认 synology,qnap,openwrt,fnos,ugreen,terramaster）
#   UPGRADE_DRILL_NO_DOWNLOAD=1  只用缓存目录里已有的产物（离线复跑）
#
# 用法: bash scripts/upgrade-drill.sh [--train <版本>] [--platforms <列表>] [--selfcheck]
set -uo pipefail

ROOT="${UPGRADE_DRILL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

# 缓存与工作目录默认落在**仓库外**（不污染工作树 ⇒ 不用改 .gitignore）
DRILL_TMP="${TMPDIR:-/tmp}/pigeonbox-upgrade-drill"
CACHE="${UPGRADE_DRILL_CACHE:-$DRILL_TMP/cache}"
WORK="${UPGRADE_DRILL_WORK:-$DRILL_TMP/work}"
TARGET_TRAIN="${UPGRADE_DRILL_TRAIN:-}"
PLATFORMS="${UPGRADE_DRILL_PLATFORMS:-synology,qnap,openwrt,fnos,ugreen,terramaster}"
NO_DOWNLOAD="${UPGRADE_DRILL_NO_DOWNLOAD:-0}"

SELFCHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --selfcheck) SELFCHECK=1 ;;
    --train)
      shift
      TARGET_TRAIN="${1:-}"
      ;;
    --platforms)
      shift
      PLATFORMS="${1:-}"
      ;;
    *)
      echo "用法: $0 [--train <版本>] [--platforms <列表>] [--selfcheck]"
      exit 2
      ;;
  esac
  shift
done

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

fail_flag=0
drill_fail() {
  echo "  ✗ $1" >&2
  fail_flag=1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

# ── 产物计划（真相源 = 当车 manifest，历史车次从 git 历史读） ───────────────
plan_file() {
  # 注意：bash 的 local 同行赋值是「先展开后赋值」⇒ 同句里引用刚赋的变量会 unbound
  local train=$1
  local out="$TMP/plan-$train.json"
  if ! python3 scripts/upgrade_matrix.py plan --root "$ROOT" --train "$train" >"$out" 2>/dev/null; then
    echo "" >&2
    return 1
  fi
  echo "$out"
}

# pick_artifact <plan.json> <平台> <名字子串> → 输出 "url sha256 name"
pick_artifact() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import re
import sys

plan = json.load(open(sys.argv[1]))
plat = sys.argv[2]
pat = sys.argv[3]
cands = [a for a in plan.get("artifacts", [])
         if a.get("platform") == plat and a.get("kind") == "package"]
if pat:
    # 正则匹配（子串匹配会让「\\.ipk$」这类后缀模式永远失配 ⇒ 抓错产物）
    hit = [a for a in cands if re.search(pat, a.get("name", ""))]
    if hit:
        cands = hit
if not cands:
    sys.exit(1)
a = cands[0]
print(a.get("url", ""))
print(a.get("sha256", ""))
print(a.get("name", ""))
PY
}

# fetch_artifact <url> <sha256> <本地名> → 打印本地路径（校验 sha256）
fetch_artifact() {
  local url=$1
  local sha=$2
  local name=$3
  local key="${4:-$name}"
  # 缓存按**车次**分目录：fnos 的产物名恒为 pigeonbox.fpk ⇒ 跨车次撞名会互相覆盖
  local dest="$CACHE/$key/$name"
  # 目标目录必须先建（curl 直接写目标文件 ⇒ 目录不存在会 curl(56) 失败）
  mkdir -p "$CACHE/$key"
  if [ -f "$dest" ]; then
    if [ -z "$sha" ] || [ "$(sha256_of "$dest")" = "$sha" ]; then
      echo "$dest"
      return 0
    fi
    echo "  ! 缓存产物 sha256 与 manifest 不符（${name}）⇒ 重新下载" >&2
    rm -f "$dest"
  fi
  if [ "$NO_DOWNLOAD" = "1" ]; then
    echo "" >&2
    return 1
  fi
  echo "  ↓ 下载 $name" >&2
  # 下载走临时文件 + 原子改名（下载中断不留半个产物在缓存里 ⇒ 下次会重下）
  # --http1.1：本机到 github.com 的 HTTP/2 帧层会偶发报错（curl 16）
  # --retry-all-errors：把「连接被重置」这类瞬时错误也纳入重试
  rm -f "$dest.part"
  if ! curl -sSL --http1.1 --retry 5 --retry-all-errors --retry-delay 2 \
    --max-time 900 -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    echo "" >&2
    return 1
  fi
  mv -f "$dest.part" "$dest"
  if [ -n "$sha" ] && [ "$(sha256_of "$dest")" != "$sha" ]; then
    echo "  ✗ 产物 sha256 与 manifest 不符（${name}）——下载被截断或串包" >&2
    rm -f "$dest"
    echo "" >&2
    return 1
  fi
  echo "$dest"
}

# ── 各平台的解包 / 版本标记 / 升级钩子 ───────────────────────────────────
unpack_fnos() {
  tar -xzf "$1" -C "$2" 2>/dev/null
}
version_fnos() {
  sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "$1/manifest" 2>/dev/null | head -n 1
}

unpack_synology() {
  tar -xf "$1" -C "$2" 2>/dev/null
  if [ -f "$2/package.tgz" ]; then
    tar -xzf "$2/package.tgz" -C "$3" 2>/dev/null
  fi
}
version_synology() {
  sed -n 's/^version="\(.*\)"/\1/p' "$1/INFO" 2>/dev/null | head -n 1
}

unpack_qnap() {
  local pkg=$1 root=$2 sl
  sl=$(head -c 20000 "$pkg" | strings | grep -o 'script_len=[0-9]*' | head -n 1 | cut -d= -f2)
  if [ -z "$sl" ]; then
    return 1
  fi
  dd if="$pkg" bs="$sl" skip=1 2>/dev/null | tar -xO 2>/dev/null | tar -xz -C "$root" 2>/dev/null
}
version_qnap() {
  sed -n 's/^QPKG_VER="\(.*\)"/\1/p' "$1/qpkg.cfg" 2>/dev/null | head -n 1
}

unpack_openwrt() {
  local ipk=$1 root=$2
  tar -xzf "$ipk" -C "$root" 2>/dev/null || return 1
  if [ -f "$root/data.tar.gz" ]; then
    tar -xzf "$root/data.tar.gz" -C "$3" 2>/dev/null
  fi
  # control.tar.gz 里是包元信息（Version 字段 = 版本标记）
  if [ -f "$root/control.tar.gz" ]; then
    mkdir -p "$root/control"
    tar -xzf "$root/control.tar.gz" -C "$root/control" 2>/dev/null
  fi
}
version_openwrt() {
  sed -n 's/^Version:[[:space:]]*//p' "$1/control/control" 2>/dev/null | head -n 1
}

unpack_zip() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$1" -d "$2" 2>/dev/null
  else
    return 1
  fi
}
version_zip() {
  local f
  f=$(find "$1" -maxdepth 3 -name 'env.example' 2>/dev/null | head -n 1)
  [ -n "$f" ] || return 1
  sed -n 's/^PB_IMAGE_TAG=//p' "$f" 2>/dev/null | head -n 1
}

# ── 升级钩子（各平台**既有**的升级脚本，不复刻逻辑） ─────────────────────
hook_synology() {
  local root=$1 pkgvar=$2
  [ -f "$root/scripts/preupgrade" ] || return 1
  SYNOPKG_PKGVAR="$pkgvar" sh "$root/scripts/preupgrade" >/dev/null 2>&1
}

hook_qnap() {
  local root=$1 pkgdir=$2 vol=$3
  [ -f "$root/package_routines" ] || return 1
  local mockdir="$TMP/qnap-mock"
  mkdir -p "$mockdir"
  # 注意：这里的 \${1:-} 必须带反斜杠——未加引号的 heredoc 会**在写文件时**
  # 就把 $1/$2 展开掉（展开成空 ⇒ mock 永远不回卷根 ⇒ 钩子跑不出快照）
  cat >"$mockdir/getcfg" <<MOCK
#!/bin/sh
if [ "\${1:-}" = "SHARE_DEF" ] && [ "\${2:-}" = "defVolMP" ]; then
  echo "$vol"
fi
MOCK
  cat >"$mockdir/write_log" <<MOCK
#!/bin/sh
echo "\$*" >>"$TMP/qnap-writelog"
MOCK
  chmod +x "$mockdir/getcfg" "$mockdir/write_log"
  FCB_GETCFG="$mockdir/getcfg" FCB_DEF_SHARE_INFO="$TMP/def_share.info" \
    FCB_WRITE_LOG="$mockdir/write_log" SYS_QPKG_DIR="$pkgdir" \
    sh -c '. "$1"; pkg_pre_install' _ "$root/package_routines" >/dev/null 2>&1
}

hook_openwrt() {
  local root=$1 db=$2
  local helper
  helper=$(find "$root" -path '*pigeonbox/preupgrade_backup' -type f 2>/dev/null | head -n 1)
  [ -n "$helper" ] || return 1
  PB_PREUPGRADE_DB="$db" PB_PREUPGRADE_MIN_FREE_KB=1 sh "$helper" >/dev/null 2>&1
}

# ── 一格演练：<平台> <旧包> <新包> <期望新版本> ───────────────────────────
drill_one() {
  local plat=$1 oldpkg=$2 newpkg=$3 want_ver=$4
  local w="$WORK/$plat"
  local install="$w/install"
  local data="$w/data"
  local unpack_old="$w/unpack-old"
  local unpack_new="$w/unpack-new"
  local db upload
  local db_before up_before db_after up_after snap ver hook_rc=0

  rm -rf "$w"
  mkdir -p "$install" "$unpack_old" "$unpack_new"

  # 数据目录必须落在**该平台真实的数据目录口径**上（否则断言是空转的：
  # 断言一个钩子根本碰不到的路径，永远「逐字未变」）。
  case "$plat" in
    synology)
      db="$data/var/data/fileCodeBox.db"
      upload="$data/var/data/uploads/sample.bin"
      ;;
    qnap)
      db="$data/vol/pigeonbox/data/fileCodeBox.db"
      upload="$data/vol/pigeonbox/data/uploads/sample.bin"
      ;;
    *)
      db="$data/fileCodeBox.db"
      upload="$data/uploads/sample.bin"
      ;;
  esac
  mkdir -p "$(dirname "$db")" "$(dirname "$upload")"
  printf 'PB-UPGRADE-DRILL-DB-%s\n' "$plat" >"$db"
  printf 'PB-UPGRADE-DRILL-UPLOAD-%s\n' "$plat" >"$upload"
  db_before="$(sha256_of "$db")"
  up_before="$(sha256_of "$upload")"

  case "$plat" in
    synology) unpack_synology "$oldpkg" "$unpack_old" "$install" ;;
    qnap) unpack_qnap "$oldpkg" "$unpack_old" ;;
    openwrt) unpack_openwrt "$oldpkg" "$unpack_old" "$install" ;;
    fnos) unpack_fnos "$oldpkg" "$unpack_old" ;;
    ugreen | terramaster) unpack_zip "$oldpkg" "$unpack_old" ;;
    *) return 1 ;;
  esac

  case "$plat" in
    synology)
      hook_synology "$unpack_old" "$data/var" >/dev/null 2>&1 || hook_rc=$?
      ;;
    qnap)
      mkdir -p "$install/www"
      printf 'old-installed-marker\n' >"$install/www/payload-marker.txt"
      hook_qnap "$unpack_old" "$install" "$data/vol" >/dev/null 2>&1 || hook_rc=$?
      ;;
    openwrt)
      hook_openwrt "$install" "$db" >/dev/null 2>&1 || hook_rc=$?
      ;;
    fnos | ugreen | terramaster)
      ;;
  esac

  case "$plat" in
    synology) unpack_synology "$newpkg" "$unpack_new" "$install" ;;
    qnap) unpack_qnap "$newpkg" "$unpack_new" ;;
    openwrt) unpack_openwrt "$newpkg" "$unpack_new" "$install" ;;
    fnos) unpack_fnos "$newpkg" "$unpack_new" ;;
    ugreen | terramaster) unpack_zip "$newpkg" "$unpack_new" ;;
  esac

  db_after="$(sha256_of "$db")"
  up_after="$(sha256_of "$upload")"
  if [ "$db_before" != "$db_after" ]; then
    drill_fail "${plat}：业务数据被改动（DB sha256 变了）"
    return 1
  fi
  if [ "$up_before" != "$up_after" ]; then
    drill_fail "${plat}：业务数据被改动（上传文件 sha256 变了）"
    return 1
  fi
  case "$plat" in
    synology) ver="$(version_synology "$unpack_new")" ;;
    qnap) ver="$(version_qnap "$unpack_new")" ;;
    openwrt) ver="$(version_openwrt "$unpack_new")" ;;
    fnos) ver="$(version_fnos "$unpack_new")" ;;
    ugreen | terramaster) ver="$(version_zip "$unpack_new")" ;;
  esac
  if [ -z "$ver" ]; then
    drill_fail "${plat}：取不到新产物的版本标记"
    return 1
  fi
  case "$ver" in
    "$want_ver"*) ;;
    *)
      drill_fail "${plat}：版本号未更新为 ${want_ver}（读到 '$ver'）"
      return 1
      ;;
  esac
  snap=$(find "$data" -name 'fileCodeBox.db.bak-*' -type f 2>/dev/null | head -n 1)
  if [ -n "$snap" ]; then
    if [ "$(sha256_of "$snap")" != "$db_before" ]; then
      drill_fail "${plat}：回滚点与升级前的库不一致（不可信回滚点）"
      return 1
    fi
    echo "  ✓ ${plat}：业务数据逐字未变 + 版本已更新为 $ver + 回滚点在位且逐字一致"
  else
    echo "  ✓ ${plat}：业务数据逐字未变 + 版本已更新为 ${ver}（未产出回滚点：升级钩子 rc=${hook_rc}；该平台无隔离可跑的钩子 ⇒ 无回滚点断言）"
  fi
  return 0
}

# ── 自证：本地构造假制品 ⇒ 好形态放行 / 坏形态判红 ───────────────────────
selfcheck() {
  local rc=0 base="$TMP/sc" plat=synology
  mkdir -p "$base"

  mk_fake_spk() {
    local dir=$1 ver=$2 mode=$3
    mkdir -p "$dir/scripts"
    printf 'package="pigeonbox"\nversion="%s"\narch="noarch"\n' "$ver" >"$dir/INFO"
    printf 'fake payload %s\n' "$ver" >"$dir/payload.txt"
    tar -czf "$dir/package.tgz" -C "$dir" payload.txt
    rm -f "$dir/payload.txt"
    if [ "$mode" = "evil" ]; then
      cat >"$dir/scripts/preupgrade" <<'HOOK'
#!/bin/sh
set -u
PKGVAR="${SYNOPKG_PKGVAR:-/var/packages/pigeonbox/var}"
DB="${PKGVAR}/data/fileCodeBox.db"
: > "$DB"
echo "preupgrade: 已快照业务库(其实是破坏)" >&2
exit 0
HOOK
    else
      cat >"$dir/scripts/preupgrade" <<'HOOK'
#!/bin/sh
set -u
PKGVAR="${SYNOPKG_PKGVAR:-/var/packages/pigeonbox/var}"
DB="${PKGVAR}/data/fileCodeBox.db"
[ -s "$DB" ] || exit 0
BAK="${DB}.bak-20260101-000000"
if ! cp "$DB" "$BAK" 2>/dev/null; then
    echo "preupgrade: 备份业务库失败,已中止升级" >&2
    exit 1
fi
echo "preupgrade: 已快照业务库 -> $BAK"
exit 0
HOOK
    fi
    chmod +x "$dir/scripts/preupgrade"
    (cd "$dir" && tar -cf "$dir.fpk" INFO package.tgz scripts)
  }

  mk_fake_spk "$base/good-old" "1.0.0" good
  mk_fake_spk "$base/good-new" "2.0.0" good
  # 坏形态放在**旧包**上：升级时跑的是旧包的 preupgrade（DSM/QTS 语义）
  # ⇒ 旧包的钩子破坏数据必须被演练抓住
  mk_fake_spk "$base/evil-old" "1.0.0" evil
  mk_fake_spk "$base/evil-new" "2.0.0" good

  WORK="$base/work"
  if drill_one "$plat" "$base/good-old.fpk" "$base/good-new.fpk" "2.0.0"; then
    echo "  ✓ 自证①：好形态（钩子只做快照）⇒ 演练放行"
  else
    echo "  ✗ 自证①：好形态却判红 ⇒ 演练断言不可信"
    rc=1
  fi
  if drill_one "$plat" "$base/evil-old.fpk" "$base/evil-new.fpk" "2.0.0"; then
    echo "  ✗ 自证②：坏形态（升级钩子破坏业务数据）⇒ 演练仍放行"
    rc=1
  else
    echo "  ✓ 自证②：坏形态（升级钩子破坏业务数据）⇒ 演练判红"
  fi
  return "$rc"
}

if [ "$SELFCHECK" -eq 1 ]; then
  echo "── 升级演练 selfcheck（本地假制品替身）"
  if selfcheck; then
    echo "✓ 升级演练自证通过（好形态放行 / 坏形态判红）"
    OK=1
    exit 0
  fi
  echo "✗ 升级演练自证失败"
  exit 1
fi

# ── 正式演练 ──────────────────────────────────────────────────────────────
if [ -z "$TARGET_TRAIN" ]; then
  TARGET_TRAIN=$(python3 scripts/upgrade_matrix.py plan --root "$ROOT" 2>/dev/null |
    sed -n 's/.*"train": "\([^"]*\)".*/\1/p' | head -n 1)
fi
if [ -z "$TARGET_TRAIN" ]; then
  echo "✗ 解析不出目标车号（--train 或 UPGRADE_DRILL_TRAIN）"
  exit 1
fi
echo "── 发布后升级演练（目标车 N=${TARGET_TRAIN}）"
PLAN_N="$(plan_file "$TARGET_TRAIN")"
if [ -z "$PLAN_N" ]; then
  echo "✗ 取不到 $TARGET_TRAIN 的产物计划（manifest 缺失？）"
  exit 1
fi

OLD_TRAIN_LIST=$(
  python3 - "$ROOT" <<'PY'
import subprocess
import sys

root = sys.argv[1]
out = subprocess.run(["git", "log", "--format=%H", "--", "release/train.yaml",
                      "release/manifest.json"], cwd=root,
                     stdout=subprocess.PIPE, check=False).stdout.decode()
seen = {}
for commit in [c for c in out.split() if c]:
    text = subprocess.run(["git", "show", "%s:release/train.yaml" % commit], cwd=root,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          check=False).stdout.decode("utf-8", "replace")
    num = ""
    state = ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("train:"):
            num = line.split(":", 1)[1].strip()
        if line.startswith("state:"):
            state = line.split(":", 1)[1].strip()
    if num and num not in seen:
        seen[num] = state
ships = [n for n, s in seen.items() if s == "shipped"]
print(" ".join(ships[:3]))
PY
)
OLD1=$(echo "$OLD_TRAIN_LIST" | awk '{print $2}')
OLD2=$(echo "$OLD_TRAIN_LIST" | awk '{print $3}')
if [ -z "$OLD1" ]; then
  echo "✗ 取不到 N-1 车次（已发货车次不足 2 辆）"
  exit 1
fi

echo "  矩阵：N=${TARGET_TRAIN}（当前车） / N-1=$OLD1 / N-2=${OLD2:-（无）}"

for span_train in "$OLD1" "$OLD2"; do
  [ -n "$span_train" ] || continue
  PLAN_OLD="$(plan_file "$span_train")"
  if [ -z "$PLAN_OLD" ]; then
    echo "✗ 取不到 $span_train 的产物计划"
    exit 1
  fi
  echo "── 演练 $span_train → $TARGET_TRAIN"
  for plat in $(echo "$PLATFORMS" | tr ',' ' '); do
    case "$plat" in
      synology) pat='\.spk$' ;;
      qnap) pat='\.qpkg$' ;;
      openwrt) pat='\.ipk$' ;;
      fnos) pat='\.fpk$' ;;
      ugreen | terramaster) pat='\.zip$' ;;
      desktop)
        echo "  ⏳ desktop：产物是各 OS 安装包（dmg/msi/exe/deb/rpm），没有「解包即安装目录」的统一形态，且应用数据目录由操作系统托管 ⇒ 本演练不做"
        continue
        ;;
      *)
        echo "  ⏳ ${plat}：未知平台 ⇒ 跳过"
        continue
        ;;
    esac
    pick_out="$(pick_artifact "$PLAN_OLD" "$plat" "$pat" || true)"
    url="$(echo "$pick_out" | sed -n 1p)"
    sha="$(echo "$pick_out" | sed -n 2p)"
    name="$(echo "$pick_out" | sed -n 3p)"
    if [ -z "$url" ]; then
      echo "  ⏳ ${plat}：$span_train 的 manifest 里没有匹配产物（${pat}）⇒ 跳过"
      continue
    fi
    pick_out_new="$(pick_artifact "$PLAN_N" "$plat" "$pat" || true)"
    url_new="$(echo "$pick_out_new" | sed -n 1p)"
    sha_new="$(echo "$pick_out_new" | sed -n 2p)"
    name_new="$(echo "$pick_out_new" | sed -n 3p)"
    if [ -z "$url_new" ]; then
      echo "  ⏳ ${plat}：$TARGET_TRAIN 的 manifest 里没有匹配产物 ⇒ 跳过"
      continue
    fi
    old_file="$(fetch_artifact "$url" "$sha" "$name" "$span_train")"
    if [ -z "$old_file" ]; then
      drill_fail "$plat/${span_train}：旧产物下载失败"
      continue
    fi
    new_file="$(fetch_artifact "$url_new" "$sha_new" "$name_new" "$TARGET_TRAIN")"
    if [ -z "$new_file" ]; then
      drill_fail "$plat/${span_train}：新产物下载失败"
      continue
    fi
    drill_one "$plat" "$old_file" "$new_file" "$TARGET_TRAIN" || true
  done
done

if [ "$fail_flag" -ne 0 ]; then
  echo "✗ 发布后升级演练：至少一格不成立"
  exit 1
fi
echo "✓ 发布后升级演练全部通过"
OK=1
exit 0
