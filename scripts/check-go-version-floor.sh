#!/usr/bin/env bash
# 门禁：workflow 里声明的 go-version 必须 **≥ go.work 的 go 地板**（patch 级）。
#
# 缺陷实录（2026-10-26 实测，dependabot PR 分支的失败日志）：
#   hub 的「全能力真机冒烟」job 报
#     go: ../go.work requires go >= 1.26.10 (running go 1.26.9; GOTOOLCHAIN=local)
#   ⇒ BUILD FAILED ⇒ job 红 ⇒ **真机冒烟（发版门禁）在任何 PR 上都可能直接死在
#     构建阶段,一条断言都没跑到** ⇒ 门禁变成噪声;列车验证(train-verify 用同一套
#     浮动版本)也跟着红 ⇒ 发版被卡住且原因难定位。
#   根因：workflow 用的是**浮动**的 `go-version: "1.26"` ⇒ runner 实际拿到的
#   patch 版本与 go.work 的 `go 1.26.10` 地板不保证一致;setup-go **v7 会强制**
#   GOTOOLCHAIN=local ⇒ Go 不能自动拉取缺的那一档 ⇒ 直接构建失败。
#
# 本门禁：
#   ① 扫全部 .github/workflows/*.yml 的 `go-version:` 声明 ⇒ 每一处的 patch
#      版本必须 ≥ go.work 的 go 地板（1.26.10 ⇒ 1.26.9 判红）;
#   ② go-version 必须是**精确版本**(带 patch)——浮动写法("1.26")判红
#      (浮动 ⇒ patch 不可知 ⇒ 随时可能低于地板);
#   ③ 每个用到 setup-go 的 job 必须显式声明 GOTOOLCHAIN: auto
#      (覆盖 setup-go v7 强制的 local ⇒ 地板再抬时能自动拉取而不是构建失败);
#   ④ 自证：把某个 workflow 的版本改成 1.26.9 ⇒ 本门禁必须变红。
#
# 用法: bash scripts/check-go-version-floor.sh [--selfcheck]
#   --selfcheck:自证模式——把某处 go-version 改低 ⇒ 本门禁必须变红
set -uo pipefail

SELFTEST=0
case "${1:-}" in
  --selfcheck) SELFTEST=1 ;;
  "") : ;;
  *) echo "用法: $0 [--selfcheck]" >&2; exit 1 ;;
esac

ROOT="${CHECK_GO_VERSION_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

FAIL=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORKFLOWS=".github/workflows"

# ── 地板：go.work 的 go 行 ────────────────────────────────────────────────
[ -f go.work ] || { echo "找不到 go.work"; exit 1; }
FLOOR="$(awk '$1=="go" {print $2; exit}' go.work)"
[ -n "$FLOOR" ] || { echo "go.work 里没有 go 行"; exit 1; }
FLOOR_MAJOR="${FLOOR%%.*}"
FLOOR_REST="${FLOOR#*.}"
FLOOR_MINOR="${FLOOR_REST%%.*}"
FLOOR_PATCH="${FLOOR_REST#*.}"
echo "go.work 地板: ${FLOOR} (major=${FLOOR_MAJOR} minor=${FLOOR_MINOR} patch=${FLOOR_PATCH})"

# 版本比较:返回 0 表示 a >= b（按 major.minor.patch 三段比,缺段当 0）
ver_ge() { # <a> <b>
  [ "$(awk -v a="$1" -v b="$2" 'BEGIN{
        na=split(a,A,"."); nb=split(b,B,".");
        r=1;
        for (i=1; i<=3; i++) {
          x=(i<=na?A[i]:0)+0; y=(i<=nb?B[i]:0)+0;
          if (x>y) { r=1; break }
          if (x<y) { r=0; break }
        }
        print r;
      }')" = "1" ]
}

# ── ① ② go-version 必须精确且 ≥ 地板 ──────────────────────────────────────
FOUND=0
for wf in "$WORKFLOWS"/*.yml "$WORKFLOWS"/*.yaml; do
  [ -f "$wf" ] || continue
  # 取该文件里所有 go-version 的值
  VALS="$(grep -oE 'go-version:[[:space:]]*"?[0-9]+\.[0-9]+(\.[0-9]+)?"?' "$wf" \
    | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
  [ -n "$VALS" ] || continue
  for v in $VALS; do
    FOUND=$((FOUND + 1))
    case "$v" in
      *.*.*) : ;;
      *) bad "$wf: go-version \"$v\" 是浮动写法(缺 patch)⇒ patch 不可知 ⇒ 随时可能低于地板 ${FLOOR}"; continue ;;
    esac
    if ver_ge "$v" "$FLOOR"; then
      ok "$wf: go-version $v ≥ 地板 ${FLOOR}"
    else
      bad "$wf: go-version $v < go.work 地板 ${FLOOR} ⇒ 构建会报 'requires go >= ${FLOOR}'"
    fi
  done
done
if [ "$FOUND" -eq 0 ]; then
  bad "没扫到任何 go-version 声明——门禁自身失效(workflow 结构变了?)"
fi

# ── ③ 用 setup-go 的 job 必须显式 GOTOOLCHAIN: auto ───────────────────────
for wf in "$WORKFLOWS"/*.yml "$WORKFLOWS"/*.yaml; do
  [ -f "$wf" ] || continue
  grep -q 'actions/setup-go' "$wf" || continue
  if grep -qE 'GOTOOLCHAIN:[[:space:]]*auto' "$wf"; then
    ok "$wf: 显式 GOTOOLCHAIN=auto(覆盖 setup-go v7 强制的 local)"
  else
    bad "$wf: 用了 setup-go 但没显式 GOTOOLCHAIN: auto ⇒ 地板再抬时构建失败(而非自动拉取)"
  fi
done

echo
if [ "$SELFTEST" = "1" ]; then
  # ── 自证：把某处 go-version 改低 ⇒ 本门禁必须变红 ─────────────────────────
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/.github/workflows"
  cp go.work "$TMP/go.work"
  cp "$WORKFLOWS"/*.yml "$TMP/.github/workflows/" 2>/dev/null || true
  # 变异一：把 ci.yml 的 1.26.10 改成 1.26.9（低于地板）
  sed -i.bak 's/go-version: "1\.26\.10"/go-version: "1.26.9"/' "$TMP/.github/workflows/ci.yml"
  # 变异二：把 release.yml 的 GOTOOLCHAIN: auto 去掉
  sed -i.bak2 '/GOTOOLCHAIN: auto/d' "$TMP/.github/workflows/release.yml"
  OUT="$(CHECK_GO_VERSION_ROOT="$TMP" bash "$ROOT/scripts/check-go-version-floor.sh" 2>&1)"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    ok "自证：版本改低(1.26.9) + 去掉 GOTOOLCHAIN 后本门禁变红（rc=${RC}）"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  else
    bad "自证失败：把 go-version 改低后本门禁仍绿 ⇒ 门禁空转"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  fi
  if [ "$FAIL" -ne 0 ]; then
    echo "✗ Go 版本地板对账失败（${FAIL} 项）"
    exit 1
  fi
  echo "✓ Go 版本地板对账通过（含自证：变异必然变红）"
  exit 0
fi

if [ "$FAIL" -ne 0 ]; then
  echo "✗ Go 版本地板对账失败（${FAIL} 项）"
  exit 1
fi
echo "✓ Go 版本地板对账通过（所有 go-version ≥ ${FLOOR} 且精确钉版 + GOTOOLCHAIN=auto）"
