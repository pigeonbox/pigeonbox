#!/usr/bin/env bash
# sync.sh「工作区根探测 + check --all 不误报」的自测（变异测试：判据失效必须红）。
#
# ⚠️ **必须覆盖两种真实布局**（2026-11-01 实录踩坑）：
#   ① **嵌套**：<ws>/pigeonbox/{deploy/nas/…, synology, ugreen, terramaster}
#      ← 本地 `make setup` 与 CI `git clone "$r"` 的**真实布局**（NAS 仓在 hub 检出目录内）
#   ② **兄弟**：<ws>/{pigeonbox/deploy/nas/…, synology, ugreen, terramaster}
#      ← 2026-10-31 #221 假设的布局
#   2026-10-31 的 selftest **只搭了 ②** ⇒ 门禁自证是假的 ⇒ ① 的缺陷
#   （4.6.6 终验在 CI 里误报 7 处漂移）**隔了整整一轮列车才暴露**。
#
# ⚠️ **自测必须跑真实脚本**：本测试搭临时工作区（真 git 仓 + 真物化文件），
#    执行**真的** `sync.sh check --all`，断言输出。
#    若改成 grep 脚本源码或另写一份路径推导逻辑去测 ⇒ 真实脚本改了照样全绿
#    ⇒ 门禁是摆设（2026-10-31 已在 trainctl 侧踩过同款坑）。
#
# 用法: bash deploy/nas/sync_selftest.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SH="$SCRIPT_DIR/sync.sh"

fails=0
note_fail() { echo "  ✗ $1"; fails=$((fails + 1)); }
note_ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

PLATFORMS=(synology ugreen terramaster)

# 搭一个工作区：$1=ws 根  $2=布局(nest|sib)
make_ws() {
    local ws="$1" mode="$2"
    local hub="$ws/pigeonbox" p dst
    mkdir -p "$hub/deploy/nas"
    cp "$SYNC_SH" "$hub/deploy/nas/sync.sh"
    cp "$SCRIPT_DIR/compose.yml" "$SCRIPT_DIR/env.example" "$hub/deploy/nas/"
    for p in "${PLATFORMS[@]}"; do
        if [ "$mode" = "nest" ]; then dst="$hub/$p"; else dst="$ws/$p"; fi
        mkdir -p "$dst"
        git -C "$dst" init -q 2>/dev/null || true
        git -C "$dst" config user.email t@t 2>/dev/null || true
        git -C "$dst" config user.name t 2>/dev/null || true
    done
    # 用**真脚本的 sync 模式**物化（内容与模板一致 ⇒ check 才可能绿）
    for p in "${PLATFORMS[@]}"; do
        if [ "$mode" = "nest" ]; then dst="$hub/$p"; else dst="$ws/$p"; fi
        bash "$hub/deploy/nas/sync.sh" sync --platform "$p" --dir "$dst" >/dev/null 2>&1 || true
    done
}

WS_NEST="$TMP/nest/ws"
WS_SIB="$TMP/sib/ws"
make_ws "$WS_NEST" nest
make_ws "$WS_SIB" sib

check_green() { # <描述> <ws> → 0=check --all 绿且无「远端无该文件」
    local desc="$1" ws="$2" out
    out="$(cd "$ws/pigeonbox" && bash "$ws/pigeonbox/deploy/nas/sync.sh" check --all 2>&1)"
    if echo "$out" | grep -q "远端无该文件"; then
        note_fail "${desc}：误报「远端无该文件」——工作区根探测错误"
        echo "$out" | sed 's/^/        /' | head -10
        return 1
    fi
    if ! echo "$out" | grep -q "共享资产与 hub 模板一致"; then
        note_fail "${desc}：结论不是「一致」——$(echo "$out" | tail -3 | tr '\n' ' ')"
        return 1
    fi
    note_ok "$desc"
    return 0
}

# ── 判据 1：嵌套布局（真实布局）必须绿 ────────────────────────────────
echo "── 判据 1：嵌套布局（NAS 仓在 hub 检出目录内）check --all 必须绿"
check_green "嵌套布局" "$WS_NEST"

# ── 判据 2：兄弟布局也必须绿 ────────────────────────────────────────
echo "── 判据 2：兄弟布局 check --all 必须绿"
check_green "兄弟布局" "$WS_SIB"

# ── 判据 3（负对照）：root 指到「无 NAS 仓」的目录 ⇒ 必须报漂移 ────────
#   这一条保证「绿」不是因为「什么都没检查」：
#   若脚本在该场景下仍报「一致」⇒ 检查根本没生效（假绿）。
#   顺带钉住旧实现用的根（hub 的父目录）在嵌套布局下**是错的**。
echo "── 判据 3（负对照）：root 指到无 NAS 仓处必须报漂移"
OUT3="$(cd "$WS_NEST/pigeonbox" && PB_NAS_WORKSPACE_ROOT="$WS_NEST" bash "$WS_NEST/pigeonbox/deploy/nas/sync.sh" check --all 2>&1)"
if echo "$OUT3" | grep -q "远端无该文件"; then
    note_ok "root 指错时报出漂移（检查真的在跑）"
else
    note_fail "root 指错时仍报「一致」⇒ 检查是假绿：$(echo "$OUT3" | tail -3 | tr '\n' ' ')"
fi

# ── 判据 4：单仓模式与 --all 模式结论必须一致 ────────────────────────
echo "── 判据 4：单仓模式绿（与 --all 同源）"
ONE="$(bash "$WS_NEST/pigeonbox/deploy/nas/sync.sh" check --platform synology --dir "$WS_NEST/pigeonbox/synology" 2>&1)"
if echo "$ONE" | grep -q "共享资产与 hub 模板一致"; then
    note_ok "单仓模式绿"
else
    note_fail "单仓模式红：$(echo "$ONE" | tail -3 | tr '\n' ' ')"
fi

# ── 判据 5：从任意 cwd 跑 --all 结论不变（相对路径会踩 cwd）──────────
echo "── 判据 5：从别的 cwd 跑 --all 结论不变"
OUT5="$(cd /tmp && bash "$WS_NEST/pigeonbox/deploy/nas/sync.sh" check --all 2>&1)"
if echo "$OUT5" | grep -q "共享资产与 hub 模板一致"; then
    note_ok "换 cwd 结论不变"
else
    note_fail "换 cwd 后结论变了：$(echo "$OUT5" | tail -3 | tr '\n' ' ')"
fi

if [ "$fails" -gt 0 ]; then
    echo
    echo "✗ $fails 条判据失效"
    exit 1
fi
echo
echo "✓ sync.sh 工作区根探测的判据全部有效"
OK=1
exit 0
