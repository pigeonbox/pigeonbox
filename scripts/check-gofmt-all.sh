#!/usr/bin/env bash
#
# 门禁：所有 Go 模块的 .go 文件必须 gofmt 干净（格式漂移即红）。
#
# 为什么有这道门禁（2026-10-24 实录）：
#   core 仓的 CI 从 3.3.9 起一直红——红在我自己那个 commit 带进的**两个未 gofmt
#   的文件**（一个末尾多空行、一个 Go 1.19+ doc comment 缩进）。表面格式问题
#   ⇒ core 的 Gofmt 步红 ⇒ 该 job 是**串行步骤链** ⇒ 后面 Vet / Test(race) /
#   Govulncheck / Lint / **架构棘轮守卫** 全部 skipped ⇒ core 仓真正的门禁
#   **一行断言都没跑过**，两个架构违规就这么进了 main 并活了两列车。
#
#   各 Go 仓的 CI 都有 gofmt 步，但：
#   ① **CI 只在合并路径上才拦**（而 hub 这种直推路径连 CI 都不在 required 里）；
#   ② 本地提交前没有任何拦截 ⇒ 格式漂移能一路走到 CI 才被发现。
#   ⇒ 本门禁挂在**本地提交前**（make lint）：漂移当场拦住，不进远端。
#
# 扫描范围：contracts / core / server / fnos / openwrt / qnap / p2p 七个 Go 模块
# （与 go.work 的 use 列表一致）+ **release/trainctl**（发布编排器，独立 go
# module，**不在 go.work 里**⇒ 此前这道门禁扫不到它 ⇒ 编排器里的格式漂移
# 无人拦；2026-10-27 改造列车时实测到 4 个未格式化文件）。
# 缺失的模块跳过（未拉齐时不误报）。
#
# 用法：bash scripts/check-gofmt-all.sh
set -uo pipefail
# 扫描根目录与模块清单可覆盖（自证模式要指向临时工作区）
ROOT="${GOFMT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

MODULES="${GOFMT_MODULES:-contracts core server fnos openwrt qnap p2p}"
# 独立 module（不在 go.work）：同样要 gofmt 干净
EXTRA_DIRS="${GOFMT_EXTRA_DIRS:-release/trainctl}"

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *) echo "用法: $0 [--selfcheck]"; exit 2 ;;
  esac
done

if ! command -v gofmt >/dev/null 2>&1; then
  echo "✗ 没有 gofmt（Go 未装？）——门禁自身失效"
  exit 1
fi

scanned=0
drifted=""
for m in $MODULES $EXTRA_DIRS; do
  [ -d "$m" ] || continue
  scanned=$((scanned + 1))
  out=$(gofmt -l "$m" 2>/dev/null || true)
  if [ -n "$out" ]; then
    drifted="${drifted}${out}"$'\n'
  fi
done

if [ "$scanned" -eq 0 ]; then
  echo "✗ 一个 Go 模块都没扫到——门禁自身失效（先跑 make setup 拉齐模块？）"
  exit 1
fi

if [ -n "$drifted" ]; then
  echo "✗ 以下文件未 gofmt 干净（修法: gofmt -w <文件>）:"
  printf '%s' "$drifted" | sed 's/^/    /'
  echo
  echo "  为何要紧: 格式漂移会让 CI 的 gofmt 步先红 ⇒ 同一 job 里后面的"
  echo "  架构棘轮/单测/race/lint **全被 skip** ⇒ 那些门禁等于没跑"
  echo "  （core 仓 2026-10-24 实录：两个架构违规因此活了两个发版列车）。"
  exit 1
fi

echo "✓ gofmt 检查通过（${scanned} 个 Go 模块）"

# ── 自证：注入未 gofmt 的文件 ⇒ 本门禁必须变红 ───────────────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  trap 'rm -rf "$SELF_TMP"' EXIT
  mkdir -p "$SELF_TMP/fakemod"
  self_fail=0

  # 基线：格式干净 ⇒ 必须绿
  printf 'package fake\n\nfunc F() {}\n' > "$SELF_TMP/fakemod/ok.go"
  if GOFMT_ROOT="$SELF_TMP" GOFMT_MODULES="fakemod" GOFMT_EXTRA_DIRS="" \
      bash "$ROOT/scripts/check-gofmt-all.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：gofmt 干净 ⇒ 门禁绿"
  else
    echo "  ✗ 基线：gofmt 干净竟然判红 ⇒ 门禁本身坏了" >&2
    self_fail=1
  fi

  # 注入：末尾多一个空行（gofmt 会挑出来）⇒ 必须红
  printf 'package fake\n\nfunc F() {}\n\n' > "$SELF_TMP/fakemod/bad.go"
  if GOFMT_ROOT="$SELF_TMP" GOFMT_MODULES="fakemod" GOFMT_EXTRA_DIRS="" \
      bash "$ROOT/scripts/check-gofmt-all.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「未 gofmt 的文件」后门禁仍绿 ⇒ 断言无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「未 gofmt 的文件」⇒ 门禁变红（断言有牙齿）"
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：注入未 gofmt 的文件 ⇒ 本门禁变红 ⇒ 门禁有牙齿"
fi
