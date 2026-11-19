#!/usr/bin/env bash
#
# 门禁：真相源 vendor/shellkit/ 必须与 vendor/shellkit.pin 的钉版记录**逐字相符**。
#
# 为什么有这道门禁（2026-11-19 引入）：
#   真相源的内容来自上游**未发版的 main**（commit edaaefa…），而副本里的
#   VERSION 仍写 1.1.0（上游还没发新版本号）⇒ 有人在 hub 跑 `shellkit upgrade`
#   会把副本换成**已发布的 v1.1.0** ⇒ 真相源被**静默降级**：
#   lib/posix/（POSIX 子集）与 lib/core/{git,proc,vendor}.sh 全没了。
#   这种降级**看版本号发现不了**（降级前后都写着 1.1.0）⇒ 8 个平台仓的副本
#   跟着漂移，最后由一道「副本一致性」门禁在别的仓报错 —— 现场离病因很远。
#
#   ⇒ 这道门禁把「真相源 = 某个确定的 commit」变成可机判的事实。
#
# 判据（六条都要过）：
#   ① 钉版记录存在且六个键齐全（缺键 ⇒ 判据不可用，不是红）
#   ② vendor/shellkit/.shellkit-vendor-manifest 的 sha256 == 钉版记录里的
#      MANIFEST_SHA256（内容指纹：manifest 是上游自己的逐文件基线）
#   ③ vendor/shellkit/VERSION == 钉版记录里的 VERSION
#   ④ 实际文件数 == 钉版记录里的 FILE_COUNT
#   ⑤ 钉版点名的关键文件都在（lib/posix/… 等；缺一个即判红并点名）
#   ⑥ 真相源的每个文件与 manifest 里记的 sha256 逐字相符，且**没有 manifest
#      之外的文件**（生成物勿手改：真相源被手改过 ⇒ 判红并点名文件）
#
# ⚠️ **本门禁刻意不加载 shellkit**（与 check-action-pins.sh 等不同）：
#   它守的就是那套库 ⇒ 用被守的库来守自己，库坏了门禁跟着一起坏，
#   分不出「库坏了」还是「门禁坏了」。这里只用基础工具（sha256sum/shasum、
#   sed、find、diff），macOS 自带 bash 3.2 也能跑。
#   **别改成 source bootstrap** —— 理由记在这里了。
#
# 用法:
#   bash scripts/check-shellkit-pin.sh [--selfcheck] [--root <目录>]
#
# 退出码:
#   0 = 与钉版一致
#   5 = 与钉版不符（被降级/被手改/关键文件缺失）
#   1 = 判据不可用（钉版记录缺失或不可解析、缺 sha256 工具）
#   2 = 用法错
set -uo pipefail

# 扫描根目录可覆盖（自证模式要指向临时工作区）
ROOT="${SHELLKIT_PIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

SELFCHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --selfcheck)
      SELFCHECK=1
      shift
      ;;
    --root)
      # ⚠️ 缺值不许静默退化成「用默认根」：那会让自证跑到真的真相源上去。
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "--root 需要目录" >&2
        exit 2
      fi
      ROOT="$2"
      shift 2
      ;;
    *)
      echo "用法: $0 [--selfcheck] [--root <目录>]" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT" || exit 1

# ── 落点解析（与上游 lib/core/vendor.sh 同一优先级）────────────────────────
# 环境变量 SHELLKIT_VENDOR_DIR > 工程里的 .shellkit-vendor-dir > 默认 vendor/shellkit
VENDOR_DIR="${SHELLKIT_VENDOR_DIR:-}"
if [ -z "$VENDOR_DIR" ] && [ -r "$ROOT/.shellkit-vendor-dir" ]; then
  VENDOR_DIR="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/.shellkit-vendor-dir" | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
fi
[ -n "$VENDOR_DIR" ] || VENDOR_DIR="vendor/shellkit"

TRUTH="$ROOT/$VENDOR_DIR"
PIN="$ROOT/$VENDOR_DIR.pin"

sha256_of() { # <文件> → sha256；两种工具都没有时返回 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# pin_get <键> → 取值（取不到返回空）
pin_get() {
  sed -n "s/^$1=//p" "$PIN" 2>/dev/null | head -n1
}

# ── 主体判定 ────────────────────────────────────────────────────────────────
run_check() { # → 0=一致 / 5=不符 / 1=判据不可用
  local fails=0 key
  local pin_version pin_ver pin_ref pin_commit pin_tag pin_date
  local pin_manifest pin_count pin_required

  if [ ! -d "$TRUTH" ]; then
    echo "✗ 真相源缺失：$TRUTH" >&2
    echo "  修法: 从上游检出跑 'bash shellkit vendor .'（落点=${VENDOR_DIR}）" >&2
    return 1
  fi
  if [ ! -r "$PIN" ]; then
    echo "✗ 钉版记录缺失：$PIN" >&2
    echo "  修法: 真相源升级时必须同时更新钉版记录（格式见 $PIN 的模板）" >&2
    return 1
  fi
  if ! sha256_of "$TRUTH/.shellkit-vendor-manifest" >/dev/null 2>&1; then
    echo "✗ 缺 sha256 工具（sha256sum / shasum）——门禁自身失效" >&2
    return 1
  fi

  # ① 六个键齐全
  pin_version="$(pin_get SHELLKIT_PIN_VERSION)"
  pin_ver="$(pin_get SHELLKIT_VERSION)"
  pin_ref="$(pin_get SHELLKIT_UPSTREAM_REF)"
  pin_commit="$(pin_get SHELLKIT_UPSTREAM_COMMIT)"
  pin_tag="$(pin_get SHELLKIT_UPSTREAM_TAG)"
  pin_date="$(pin_get SHELLKIT_VENDORED_AT)"
  pin_manifest="$(pin_get SHELLKIT_MANIFEST_SHA256)"
  pin_count="$(pin_get SHELLKIT_FILE_COUNT)"
  pin_required="$(pin_get SHELLKIT_REQUIRED_FILES)"

  for key in SHELLKIT_PIN_VERSION SHELLKIT_VERSION SHELLKIT_UPSTREAM_REF \
    SHELLKIT_UPSTREAM_COMMIT SHELLKIT_VENDORED_AT SHELLKIT_MANIFEST_SHA256 \
    SHELLKIT_FILE_COUNT SHELLKIT_REQUIRED_FILES; do
    if [ -z "$(pin_get "$key")" ]; then
      echo "✗ 钉版记录缺键：${key}（${PIN}）——判据不可用" >&2
      return 1
    fi
  done

  # 钉版记录自身的格式版本（本门禁只认 1；将来改格式时递增它，
  # 老门禁遇到新版本就明确说不认识，而不是按老格式硬解）
  if [ "$pin_version" != "1" ]; then
    echo "✗ 钉版记录格式版本不认识：SHELLKIT_PIN_VERSION=${pin_version}（本门禁只认 1）" >&2
    return 1
  fi

  # 上游 commit 必须是 40 位 hex（钉版记录的格式自检）
  case "$pin_commit" in
    '' | *[!0-9a-f]*)
      echo "✗ 钉版记录里的 SHELLKIT_UPSTREAM_COMMIT 不是 40 位 hex：$pin_commit" >&2
      return 1
      ;;
  esac
  if [ "${#pin_commit}" -ne 40 ]; then
    echo "✗ 钉版记录里的 SHELLKIT_UPSTREAM_COMMIT 长度应为 40（实得 ${#pin_commit}）" >&2
    return 1
  fi

  # ② manifest 指纹
  local actual_manifest
  actual_manifest="$(sha256_of "$TRUTH/.shellkit-vendor-manifest")"
  if [ "$actual_manifest" != "$pin_manifest" ]; then
    fails=$((fails + 1))
    echo "✗ 真相源内容指纹与钉版记录不符（**降级或换版**）："
    echo "    钉版记录：$pin_manifest"
    echo "    实际    ：$actual_manifest"
    echo "    钉在    ：${pin_ref}@${pin_commit}（${pin_date}）"
    echo "    修法: 要换真相源就按 $PIN 头的 ①–④ 步**显式升钉版**；"
    echo "          误跑 'shellkit upgrade' 会把未发版的上游降级成已发布版。"
  fi

  # ③ VERSION
  local actual_ver
  actual_ver="$(cat "$TRUTH/VERSION" 2>/dev/null || echo '')"
  if [ "$actual_ver" != "$pin_ver" ]; then
    fails=$((fails + 1))
    echo "✗ 副本版本号与钉版记录不符：实际=$actual_ver 钉版=$pin_ver"
  fi

  # ④ 文件数
  local actual_count
  actual_count="$(find "$TRUTH" -type f | wc -l | tr -d ' ')"
  if [ "$actual_count" != "$pin_count" ]; then
    fails=$((fails + 1))
    echo "✗ 真相源文件数与钉版记录不符：实际=$actual_count 钉版=$pin_count"
  fi

  # ⑤ 关键文件齐全
  local req
  for req in $pin_required; do
    if [ ! -f "$TRUTH/$req" ]; then
      fails=$((fails + 1))
      echo "✗ 关键文件缺失：${req}（${TRUTH} 下没有）"
    fi
  done

  # ⑥ 逐文件与 manifest 相符（生成物勿手改）
  local tmp_actual tmp_expect
  tmp_actual="$(mktemp)"
  tmp_expect="$(mktemp)"
  (
    cd "$TRUTH" && find . -type f -print
  ) | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#./}"
    [ "$rel" = ".shellkit-vendor-manifest" ] && continue
    printf '%s %s
' "$rel" "$(sha256_of "$TRUTH/$rel")"
  done >"$tmp_actual"
  # ⚠️ 上游 manifest 用 **TAB** 分隔（路径<SP>sha 的格式是我们自己算的，对不上）
  #   ⇒ 这里必须按 TAB 解析，再转成「路径 空格 sha」与实际清单对比。
  awk -F'\t' 'NF==2 {print $1 " " $2}' "$TRUTH/.shellkit-vendor-manifest" | LC_ALL=C sort >"$tmp_expect"
  if ! diff -u "$tmp_expect" "$tmp_actual" >/dev/null 2>&1; then
    fails=$((fails + 1))
    echo "✗ 真相源与 manifest 不符（**生成物被手改过**，或文件清单变了）："
    diff -u "$tmp_expect" "$tmp_actual" | sed -n '1,20p' | sed 's/^/    /'
  fi
  rm -f "$tmp_actual" "$tmp_expect"

  if [ "$fails" -ne 0 ]; then
    echo "  （共 $fails 条不符）"
    return 5
  fi

  echo "✓ 真相源与钉版一致：${pin_ref}@${pin_commit}（${pin_date}，${actual_count} 个文件）"
  if [ -z "$pin_tag" ]; then
    echo "  ! 注意：钉的是**未发版**的上游 commit（上游还没打 tag）⇒"
    echo "    副本 VERSION 仍是 ${pin_ver}，看起来像已发布版 —— 这正是本门禁存在的原因。"
  fi
  return 0
}

if [ "$SELFCHECK" -eq 0 ]; then
  run_check
  exit $?
fi

# ── 自证：注入各类破坏 ⇒ 本门禁必须变红且点名；干净 ⇒ 绿 ──────────────────
SELF_TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

mkdir -p "$SELF_TMP/vendor"
cp -R "$ROOT/vendor/shellkit" "$SELF_TMP/vendor/shellkit"
cp "$PIN" "$SELF_TMP/$VENDOR_DIR.pin"
self_fail=0

# 基线：忠实复制 ⇒ 必须绿
if SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" >/dev/null 2>&1; then
  echo "  ✓ 基线：忠实复制 ⇒ 门禁绿"
else
  echo "  ✗ 基线：忠实复制竟然判红 ⇒ 门禁本身坏了" >&2
  self_fail=1
fi

# 注入①：手改真相源里的一个文件 ⇒ 必须红**且点名该文件**
printf '\n# 注入的手改\n' >>"$SELF_TMP/vendor/shellkit/lib/core/git.sh"
rc=0
out="$(SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ✗ 注入「手改真相源文件」后门禁仍绿 ⇒ 断言无效" >&2
  self_fail=1
elif printf '%s' "$out" | grep -q 'lib/core/git.sh'; then
  echo "  ✓ 注入「手改真相源文件」⇒ 门禁变红并点名 lib/core/git.sh（断言有牙齿）"
else
  echo "  ✗ 判红但没点名文件 ⇒ 结论不可用" >&2
  self_fail=1
fi
# 从真相源重新取一份干净的（**不碰真实工作树**：门禁脚本不该改用户的仓）
cp "$ROOT/vendor/shellkit/lib/core/git.sh" "$SELF_TMP/vendor/shellkit/lib/core/git.sh"

# 注入②：把 VERSION 改成旧版（模拟 'shellkit upgrade' 静默降级）⇒ 必须红
printf '1.0.0\n' >"$SELF_TMP/vendor/shellkit/VERSION"
rc=0
out="$(SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ✗ 注入「版本降级」后门禁仍绿 ⇒ 断言无效" >&2
  self_fail=1
elif printf '%s' "$out" | grep -q '版本号与钉版记录不符'; then
  echo "  ✓ 注入「版本降级」⇒ 门禁变红并点名版本号不符（断言有牙齿）"
else
  echo "  ✗ 判红但没点名降级 ⇒ 结论不可用" >&2
  self_fail=1
fi
cp "$ROOT/vendor/shellkit/VERSION" "$SELF_TMP/vendor/shellkit/VERSION"

# 注入③：删掉 POSIX 子集（未发版上游带来的新能力）⇒ 必须红且点名
rm -f "$SELF_TMP/vendor/shellkit/lib/posix/shellkit-posix.sh"
rc=0
out="$(SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ✗ 注入「删掉 POSIX 子集」后门禁仍绿 ⇒ 断言无效" >&2
  self_fail=1
elif printf '%s' "$out" | grep -q 'lib/posix/shellkit-posix.sh'; then
  echo "  ✓ 注入「删掉 POSIX 子集」⇒ 门禁变红并点名该文件（断言有牙齿）"
else
  echo "  ✗ 判红但没点名缺失文件 ⇒ 结论不可用" >&2
  self_fail=1
fi

# 还原后恢复绿（证明上面的红不是「本来就红」）
cp "$ROOT/vendor/shellkit/lib/posix/shellkit-posix.sh" "$SELF_TMP/vendor/shellkit/lib/posix/shellkit-posix.sh"
if SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" >/dev/null 2>&1; then
  echo "  ✓ 还原注入后恢复绿"
else
  echo "  ✗ 还原注入后仍红 ⇒ 门禁有误报" >&2
  self_fail=1
fi

# 空转守卫：钉版记录不在位 ⇒ 必须红（「没得比」≠「比过了」）
rm -f "$SELF_TMP/vendor/shellkit.pin"
if SHELLKIT_PIN_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shellkit-pin.sh" >/dev/null 2>&1; then
  echo "  ✗ 钉版记录缺失时门禁仍绿 ⇒ 空转守卫无效" >&2
  self_fail=1
else
  echo "  ✓ 钉版记录缺失 ⇒ 门禁变红（空转守卫有牙齿）"
fi

if [ "$self_fail" -ne 0 ]; then
  echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
  exit 1
fi
echo "✓ 自证：干净⇒绿、手改⇒红点名、降级⇒红点名、缺文件⇒红点名、还原⇒绿、缺钉版⇒红 ⇒ 门禁有牙齿"
OK=1
