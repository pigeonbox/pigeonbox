#!/usr/bin/env bash
# check-docs-consistency.sh — 文档与代码对账门禁（2026-10-26 审计新增）
#
# 背景：本项目有两份「代码是真相、文档靠人同步」的清单，历史上**没有任何门禁**
# ⇒ 漂移会一直积累（实测：环境变量文档漏了 1 个 PB_*；错误码对照表漏了 1 个码）。
# ⇒ 这里把两条对账做成机械检查，CI 必跑。
#
# 检查项：
#   ① docs-site/guide/error-codes.md 的码表 ⊇ contracts/errcode 的**全部常量码**
#      （只取 `Code* = NNNNN` 形式的常量；范围判定用的 10999/50000/59999 不算码）
#   ①' **反向**：doc 里的 5 位码必须**存在于** errcode 常量（或显式标注「已退役」）
#      —— 此前只有单向包含 ⇒ 文档里多出一个已退役/不存在的码也不会被发现
#   ② docs/ENVIRONMENT_VARIABLES.md ⊇ core **全仓**绑定的 PB_* 变量
#      （此前绑定源写死 core/bootstrap/config.go ⇒ setup_gate.go / bootstrap.go /
#        database.go / routes_custom.go / conf/signingkey.go 里的绑定**没有机械保护**
#        —— 将来新增 PB_* 绑定并顺手删文档，门禁仍绿）
#   ③ docs-site/guide/cli.md 的 CLI 下载示例版本 == 当前列车号
#      （此前钉在 v3.3.15 ⇒ 照抄装到落后一整个**破坏性**列车的旧 CLI）
#
# 自检: `--selfcheck` 用**临时目录**跑三条注入故障（新增未文档化的 PB_ 绑定 /
#      文档里多一个不存在的码 / CLI 版本落后）⇒ 本门禁必须逐条变红。
#      不污染真实仓。
set -euo pipefail

ROOT="${DOCS_GATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

CONTRACTS="${DOCS_GATE_CONTRACTS:-$ROOT/contracts}"
CORE="${DOCS_GATE_CORE:-$ROOT/core}"
DOCS="${DOCS_GATE_DOCS:-$ROOT/docs}"
DOCSITE="${DOCS_GATE_DOCSITE:-$ROOT/docs-site}"
TRAIN_FILE="${DOCS_GATE_TRAIN:-$ROOT/release/train.yaml}"

# 非业务码的哨兵值(范围判定用的上界等)——它们不是错误码,不应被反向检查拦下。
NON_CODES="10999 50000 59999"

fail() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

# ── ① 错误码对照表 ⊇ errcode 常量 ───────────────────────────────────────────
ERRCODE_FILE="$CONTRACTS/errcode/errcode.go"
ERRCODE_DOC="$DOCSITE/guide/error-codes.md"
[ -f "$ERRCODE_FILE" ] || fail "找不到 $ERRCODE_FILE"
[ -f "$ERRCODE_DOC" ] || fail "找不到 $ERRCODE_DOC"

missing=""
# 只匹配常量声明行（`CodeXxx = 12345`），排除 if/return 里的范围字面量
# （while read 而非 for-in-$(...)：SC2013 —— 逐行读更稳，也不受 IFS 影响）
CONST_FILE="/tmp/.pb-errcode-consts.$$"
trap 'rm -f "$CONST_FILE"' EXIT
grep -oE '^\s*Code[A-Za-z0-9]+\s*=\s*[0-9]{5}' "$ERRCODE_FILE" \
  | grep -oE '[0-9]{5}' | sort -u > "$CONST_FILE"
while IFS= read -r code; do
  [ -n "$code" ] || continue
  grep -q "$code" "$ERRCODE_DOC" || missing="$missing $code"
done < "$CONST_FILE"
if [ -n "$missing" ]; then
  fail "错误码对照表缺码（${ERRCODE_DOC}）:$missing —— 补表或说明该码已退役"
fi

# ── ①' 反向：doc 里的 5 位码必须在 errcode 常量里（或显式标注「已退役」）────
# 此前只有单向包含 ⇒ 文档里多出一个**已退役/根本不存在**的码也没人发现。
stale=""
while IFS= read -r code; do
  [ -n "$code" ] || continue
  grep -qx "$code" "$CONST_FILE" && continue
  case " $NON_CODES " in *" $code "*) continue ;; esac
  # 显式标注「已退役」的允许保留（退役码留在文档里做历史说明）
  if grep -E "$code" "$ERRCODE_DOC" | grep -qE '已退役|历史(遗留|保留)|已废弃'; then
    continue
  fi
  stale="$stale $code"
done < <(grep -oE '\b[0-9]{5}\b' "$ERRCODE_DOC" | sort -u)
if [ -n "$stale" ]; then
  fail "错误码对照表里有**不存在于 errcode 常量**的码（${ERRCODE_DOC}）:$stale —— 删除或显式标注「已退役」"
fi

# ── ② 环境变量文档 ⊇ core 全仓绑定的 PB_* ───────────────────────────────────
ENV_DOC="$DOCS/ENVIRONMENT_VARIABLES.md"
[ -f "$ENV_DOC" ] || fail "找不到 $ENV_DOC"
[ -d "$CORE" ] || fail "找不到 core 目录（${CORE}）"

# 绑定源 = **core 全仓**扫描（排除 _test.go），不再写死单个文件。
# 漏网的文件（2026-10-26 审计实录）：core/bootstrap/{setup_gate,bootstrap,database,
# routes_custom}.go 与 core/conf/signingkey.go —— 它们的 PB_* 绑定此前**没有任何
# 机械保护**（新增绑定并顺手删文档 ⇒ 门禁仍绿）。
missing=""
for v in $(grep -rnE '"PB_[A-Z0-9_]+"' "$CORE" --include='*.go' 2>/dev/null \
             | grep -v '_test\.go:' \
             | grep -oE '"PB_[A-Z0-9_]+"' | tr -d '"' | sort -u); do
  grep -q "$v" "$ENV_DOC" || missing="$missing $v"
done
if [ -n "$missing" ]; then
  fail "环境变量文档缺项（${ENV_DOC}）:$missing —— 补文档（绑定在 core 里，扫描范围=core 全仓）"
fi

# ── ③ CLI 下载示例的版本 == 当前列车号 ─────────────────────────────────────
CLI_DOC="$DOCSITE/guide/cli.md"
if [ -f "$CLI_DOC" ]; then
  TRAIN=""
  if [ -f "$TRAIN_FILE" ]; then
    TRAIN="$(awk '/^train:/ {print $2; exit}' "$TRAIN_FILE")"
  fi
  if [ -n "$TRAIN" ]; then
    bad_ver=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      for v in $(printf '%s' "$line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true); do
        [ "$v" = "v${TRAIN}" ] && continue
        # 历史说明（首发版本/历史遗留）允许出现，但必须在同一行**标注清楚**
        case "$line" in
          *已退役*|*历史*|*首发*|*起发布*|*旧版*) continue ;;
        esac
        bad_ver="$bad_ver $v"
      done
    done < "$CLI_DOC"
    if [ -n "$bad_ver" ]; then
      fail "CLI 文档里的版本号${bad_ver} 不是当前列车号 v${TRAIN}（也不是显式标注的历史说明）—— 更新 ${CLI_DOC}"
    fi
    # 下载示例必须真的用当前列车号
    if ! grep -q "releases/download/v${TRAIN}/" "$CLI_DOC"; then
      fail "CLI 下载示例没有用当前列车号 v${TRAIN}（${CLI_DOC}）—— 照抄会装到旧列车（旧列车含破坏性变更）"
    fi
  else
    echo "! 跳过 CLI 版本对账（读不到列车号：${TRAIN_FILE}）"
  fi
fi

echo "✓ 文档对账通过：错误码表双向一致、环境变量文档覆盖 core 全仓绑定、CLI 版本对齐当前列车"

# ── 自检：用临时目录跑三条注入故障，验证本门禁确实会红 ──────────────────────
if [ "${1:-}" = "--selfcheck" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"; rm -f "$CONST_FILE"' EXIT
  mkdir -p "$TMP/contracts/errcode" "$TMP/core/bootstrap" "$TMP/docs" "$TMP/docs-site/guide" "$TMP/release"
  cp "$ERRCODE_FILE" "$TMP/contracts/errcode/errcode.go"
  cp "$ENV_DOC" "$TMP/docs/ENVIRONMENT_VARIABLES.md"
  cp "$ERRCODE_DOC" "$TMP/docs-site/guide/error-codes.md"
  cp "$CLI_DOC" "$TMP/docs-site/guide/cli.md"
  cp "$TRAIN_FILE" "$TMP/release/train.yaml"
  printf 'package bootstrap\n\n// 自检夹具：模拟一个新增的 PB_ 绑定\nconst probe = "PB_FAKE_GATE_PROBE"\n' \
    > "$TMP/core/bootstrap/probe.go"

  run_gate() { # <根目录>
    DOCS_GATE_ROOT="$1" DOCS_GATE_CONTRACTS="$1/contracts" DOCS_GATE_CORE="$1/core" \
    DOCS_GATE_DOCS="$1/docs" DOCS_GATE_DOCSITE="$1/docs-site" DOCS_GATE_TRAIN="$1/release/train.yaml" \
    bash "$ROOT/scripts/check-docs-consistency.sh" >/dev/null 2>&1
    echo $?
  }

  # ① 基线：夹具里的 PB_FAKE_GATE_PROBE 没进文档 ⇒ 必须红
  rc=$(run_gate "$TMP")
  if [ "$rc" != "0" ]; then
    echo "  ✓ 自检①：新增未文档化的 PB_ 绑定 ⇒ 门禁变红（rc=${rc}）"
  else
    echo "  ✗ 自检①：新增未文档化的 PB_ 绑定 ⇒ 门禁仍绿 ⇒ 门禁空转" >&2
    exit 1
  fi
  # ② 补进文档 ⇒ 必须绿（证明①的红是因为这条缺失，而不是别的）
  printf '\n<!-- PB_FAKE_GATE_PROBE -->\n' >> "$TMP/docs/ENVIRONMENT_VARIABLES.md"
  rc=$(run_gate "$TMP")
  if [ "$rc" = "0" ]; then
    echo "  ✓ 自检②：补进文档后 ⇒ 门禁变绿（rc=${rc}）"
  else
    echo "  ✗ 自检②：补进文档后仍红 ⇒ ① 的红另有原因，门禁不可信" >&2
    exit 1
  fi
  # ③ 文档里多一个不存在的码 ⇒ 必须红
  printf '\n| 99999 | 自检注入的不存在码 |\n' >> "$TMP/docs-site/guide/error-codes.md"
  rc=$(run_gate "$TMP")
  if [ "$rc" != "0" ]; then
    echo "  ✓ 自检③：文档里多一个不存在的码 ⇒ 门禁变红（rc=${rc}）"
  else
    echo "  ✗ 自检③：文档里多一个不存在的码 ⇒ 门禁仍绿 ⇒ 反向检查缺失" >&2
    exit 1
  fi
  # ④ 撤掉注入的码，并把 CLI 版本改回旧列车 ⇒ 必须红
  git checkout -- "$TMP/docs-site/guide/error-codes.md" 2>/dev/null || \
    sed -i.bak '/99999/d' "$TMP/docs-site/guide/error-codes.md"
  sed -i.bak 's#releases/download/v[0-9.]*/#releases/download/v3.3.15/#' "$TMP/docs-site/guide/cli.md"
  rc=$(run_gate "$TMP")
  if [ "$rc" != "0" ]; then
    echo "  ✓ 自检④：CLI 版本落后于当前列车 ⇒ 门禁变红（rc=${rc}）"
  else
    echo "  ✗ 自检④：CLI 版本落后 ⇒ 门禁仍绿 ⇒ 版本对账缺失" >&2
    exit 1
  fi
  echo "✓ 文档对账门禁自检通过（三条注入故障都能让门禁变红）"
fi
