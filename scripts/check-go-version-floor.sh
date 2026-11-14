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
#   ④ 自证：两条变异**各自独立**跑内层并**分别断言**（2026-11-14 #372）——
#      ① go-version 改到地板之下（版本从**当前地板动态取**，并断言 sed 确实改到了
#         行）⇒ 必须点名「< go.work 地板」；
#      ② 去掉 GOTOOLCHAIN: auto ⇒ 必须点名「没显式 GOTOOLCHAIN」。
#      此前两条变异注入在同一次内层运行、只看**一个** RC ⇒ 抬版后变异一的硬编码
#      正则匹配不到任何行（什么都没注入），而变异二仍必然让内层判红 ⇒ 外层照样
#      打印「✓ 自证」⇒ **负对照无声丢失**（谎报）。
#
# 用法: bash scripts/check-go-version-floor.sh [--selfcheck]
#   --selfcheck:自证模式——两条变异各自独立注入并分别断言必红（#372）
set -uo pipefail

SELFTEST=0
case "${1:-}" in
  --selfcheck) SELFTEST=1 ;;
  "") : ;;
  *)
    echo "用法: $0 [--selfcheck]" >&2
    exit 1
    ;;
esac

ROOT="${CHECK_GO_VERSION_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

FAIL=0
ok() { echo "  ✓ $1"; }
bad() {
  echo "  ✗ $1"
  FAIL=$((FAIL + 1))
}

WORKFLOWS=".github/workflows"

# ── 地板：go.work 的 go 行 ────────────────────────────────────────────────
[ -f go.work ] || {
  echo "找不到 go.work"
  exit 1
}
FLOOR="$(awk '$1=="go" {print $2; exit}' go.work)"
[ -n "$FLOOR" ] || {
  echo "go.work 里没有 go 行"
  exit 1
}
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
  VALS="$(grep -oE 'go-version:[[:space:]]*"?[0-9]+\.[0-9]+(\.[0-9]+)?"?' "$wf" |
    grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
  [ -n "$VALS" ] || continue
  for v in $VALS; do
    FOUND=$((FOUND + 1))
    case "$v" in
      *.*.*) : ;;
      *)
        bad "$wf: go-version \"$v\" 是浮动写法(缺 patch)⇒ patch 不可知 ⇒ 随时可能低于地板 ${FLOOR}"
        continue
        ;;
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
  # ── 自证：两条变异**各自独立**跑内层、各自断言（#372）────────────────────
  TMP="$(mktemp -d)"
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

  # 每条变异都从**干净工作区**起跑 ⇒ 一条的注入不会影响另一条的结论。
  fresh_ws() {
    rm -rf "$TMP/.github"
    mkdir -p "$TMP/.github/workflows"
    cp go.work "$TMP/go.work"
    cp "$WORKFLOWS"/*.yml "$TMP/.github/workflows/" 2>/dev/null || true
  }
  run_inner() { # 结果写进 OUT / RC 两个变量，不打印
    RC=0
    OUT="$(CHECK_GO_VERSION_ROOT="$TMP" bash "$ROOT/scripts/check-go-version-floor.sh" 2>&1)" || RC=$?
  }

  # ── 变异一：go-version 改到地板之下 ⇒ 必须点名「< go.work 地板」──────────
  # 版本从**当前地板动态取**（地板减一档），不再硬编码 1.26——否则下一次 Go 升版
  # 后 sed 匹配不到任何行、什么都没注入，自证仍会因变异二而「通过」⇒ 谎报。
  # 另加两道前置断言：构造值必须真低于地板；sed 必须真改到行。
  fresh_ws
  LOWVER="$(awk -v f="$FLOOR" 'BEGIN{
      n = split(f, A, ".");
      if (A[3] + 0 > 0)      { A[3] = A[3] - 1 }
      else if (A[2] + 0 > 0) { A[2] = A[2] - 1; A[3] = 99 }
      else                   { A[1] = A[1] - 1; A[2] = 99; A[3] = 99 }
      printf "%d.%d.%d", A[1], A[2], A[3]
    }')"
  if ver_ge "$LOWVER" "$FLOOR"; then
    bad "自证①前置失败：构造的 ${LOWVER} 并未低于地板 ${FLOOR} ⇒ 变异一没有区分力"
  else
    M1=""
    for wf in "$TMP/.github/workflows"/*.yml; do
      [ -f "$wf" ] || continue
      if grep -qE 'go-version:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$wf"; then
        M1="$wf"
        break
      fi
    done
    if [ -z "$M1" ]; then
      bad "自证①前置失败：没扫到钉了精确 go-version 的 workflow ⇒ 变异一无处可注入"
    else
      cp "$M1" "$M1.orig"
      sed -i.bak -E 's/go-version:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/go-version: "'"$LOWVER"'"/g' "$M1"
      if cmp -s "$M1.orig" "$M1"; then
        bad "自证①前置失败：sed 没改到任何 go-version 行（${M1}）⇒ 变异一静默失效"
      else
        run_inner
        if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '< go\.work 地板'; then
          ok "自证①：go-version 改成 ${LOWVER}（< 地板 ${FLOOR}）⇒ 判红并点名地板（rc=${RC}）"
        else
          bad "自证①失败：版本改低后门禁没点名「< go.work 地板」⇒ 规则①空转"
          printf '%s\n' "$OUT" | sed 's/^/      /'
        fi
      fi
      rm -f "$M1.orig" "$M1.bak"
    fi
  fi

  # ── 变异二：去掉 GOTOOLCHAIN: auto ⇒ 必须点名「没显式 GOTOOLCHAIN」───────
  fresh_ws
  M2=""
  for wf in "$TMP/.github/workflows"/*.yml; do
    [ -f "$wf" ] || continue
    if grep -q 'actions/setup-go' "$wf" && grep -qE 'GOTOOLCHAIN:[[:space:]]*auto' "$wf"; then
      M2="$wf"
      break
    fi
  done
  if [ -z "$M2" ]; then
    bad "自证②前置失败：没扫到「setup-go + GOTOOLCHAIN: auto」的 workflow ⇒ 变异二无处可注入"
  else
    cp "$M2" "$M2.orig"
    sed -i.bak2 -e '/GOTOOLCHAIN:[[:space:]]*auto/d' "$M2"
    if cmp -s "$M2.orig" "$M2"; then
      bad "自证②前置失败：sed 没删掉任何 GOTOOLCHAIN: auto 行（${M2}）⇒ 变异二静默失效"
    else
      run_inner
      if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '没显式 GOTOOLCHAIN'; then
        ok "自证②：去掉 GOTOOLCHAIN: auto ⇒ 判红并点名（rc=${RC}）"
      else
        bad "自证②失败：去掉 GOTOOLCHAIN 后门禁没点名 ⇒ 规则③空转"
        printf '%s\n' "$OUT" | sed 's/^/      /'
      fi
    fi
    rm -f "$M2.orig" "$M2.bak2"
  fi

  if [ "$FAIL" -ne 0 ]; then
    echo "✗ Go 版本地板对账失败（${FAIL} 项）"
    exit 1
  fi
  echo "✓ Go 版本地板对账通过（含自证：两条变异各自独立、分别判红）"
  OK=1
  exit 0
fi

if [ "$FAIL" -ne 0 ]; then
  echo "✗ Go 版本地板对账失败（${FAIL} 项）"
  exit 1
fi
echo "✓ Go 版本地板对账通过（所有 go-version ≥ ${FLOOR} 且精确钉版 + GOTOOLCHAIN=auto）"
OK=1
