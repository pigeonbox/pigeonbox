#!/usr/bin/env bash
# sync.sh「工作区根推导 + check --all 不误报」的自测（变异测试：判据失效必须红）。
#
# 为什么需要：2026-10-31 实测，`check --all` 的工作区根**少算一层 `..`**
# ⇒ 各 NAS 仓路径落到不存在的目录 ⇒ **误报 7 处漂移**；
# 而**单仓模式**（传绝对路径 --dir）是绿的 ⇒ 两种模式结果矛盾 ⇒ 极难发现。
#
# ⚠️ **自测必须跑真实脚本**：本测试搭一个临时工作区（真 git 仓 + 真物化文件），
#    执行**真的** `sync.sh check --all`，断言输出里**没有**「远端无该文件」。
#    若改成 grep 脚本源码或另写一份路径推导逻辑去测 ⇒ 真实脚本改了照样全绿
#    ⇒ 门禁是摆设（2026-10-31 已在 trainctl 侧踩过同款坑）。
#
# ⚠️ 临时工作区必须**真正建出三个 NAS 仓**（否则脚本找不到它们 ⇒ 误报是
#    「仓不存在」而非「路径推导错」⇒ 判据抓不到真正的缺陷）。
#
# 用法: bash deploy/nas/sync_selftest.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SH="$SCRIPT_DIR/sync.sh"
SYNC_SELFTEST="$SCRIPT_DIR/sync_selftest.sh"

fails=0
note_fail() { echo "  ✗ $1"; fails=$((fails + 1)); }
note_ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

# ── 搭临时工作区 ──────────────────────────────────────────────────────
# 布局（与真实工作区同构）：
#   <ws>/pigeonbox/deploy/nas/{sync.sh,sync_selftest.sh,compose.yml,env.example}
#   <ws>/{synology,ugreen,terramaster}/     ← 三个 NAS 仓（git 仓 + 物化文件）
WS="$TMP/ws"
HUB="$WS/pigeonbox"
mkdir -p "$HUB/deploy/nas"
cp "$SYNC_SH" "$SYNC_SELFTEST" "$HUB/deploy/nas/" 2>/dev/null || \
  cp "$SYNC_SH" "$HUB/deploy/nas/"
cp "$SCRIPT_DIR/compose.yml" "$SCRIPT_DIR/env.example" "$HUB/deploy/nas/"

for p in synology ugreen terramaster; do
  mkdir -p "$WS/$p"
  git -C "$WS/$p" init -q 2>/dev/null || true
  git -C "$WS/$p" config user.email t@t 2>/dev/null || true
  git -C "$WS/$p" config user.name t 2>/dev/null || true
done

# 用**真脚本的 sync 模式**物化（内容与模板一致 ⇒ check 才可能绿）
SYNC_TMP="$HUB/deploy/nas/sync.sh"
for p in synology ugreen terramaster; do
  bash "$SYNC_TMP" sync --platform "$p" --dir "$WS/$p" >/dev/null 2>&1 || true
done

# ── 判据 1：check --all 不得误报「远端无该文件」────────────────────────
echo "── 判据 1：check --all 不得误报「远端无该文件」"
OUT="$(cd "$HUB" && bash "$SYNC_TMP" check --all 2>&1)"
if echo "$OUT" | grep -q "远端无该文件"; then
  note_fail "check --all 误报「远端无该文件」——工作区根推导错误"
  echo "$OUT" | sed 's/^/        /' | head -10
else
  note_ok "check --all 未误报「远端无该文件」"
fi

# ── 判据 2：单仓模式与 --all 模式结论必须一致 ─────────────────────────
echo "── 判据 2：单仓模式绿（与 --all 同源）"
ONE="$(bash "$SYNC_TMP" check --platform synology --dir "$WS/synology" 2>&1)"
if echo "$ONE" | grep -q "共享资产与 hub 模板一致"; then
  note_ok "单仓模式绿"
else
  note_fail "单仓模式红：$(echo "$ONE" | tail -3 | tr '\n' ' ')"
fi

# ── 判据 3：从任意 cwd 跑 --all 结论不变（相对路径会踩 cwd）─────────────
echo "── 判据 3：从别的 cwd 跑 --all 不误报"
OUT2="$(cd /tmp && bash "$SYNC_TMP" check --all 2>&1)"
if echo "$OUT2" | grep -q "远端无该文件"; then
  note_fail "从别的 cwd 跑 --all 误报（路径相对 cwd 解析）"
else
  note_ok "从别的 cwd 跑 --all 不误报"
fi

if [ "$fails" -gt 0 ]; then
  echo
  echo "✗ $fails 条判据失效"
  exit 1
fi
echo
echo "✓ sync.sh 工作区根推导的判据全部有效"
OK=1
exit 0
