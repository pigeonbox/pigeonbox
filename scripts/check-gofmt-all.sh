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
# （与 go.work 的 use 列表一致）。缺失的模块跳过（未拉齐时不误报）。
#
# 用法：bash scripts/check-gofmt-all.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODULES="contracts core server fnos openwrt qnap p2p"

if ! command -v gofmt >/dev/null 2>&1; then
  echo "✗ 没有 gofmt（Go 未装？）——门禁自身失效"
  exit 1
fi

scanned=0
drifted=""
for m in $MODULES; do
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
