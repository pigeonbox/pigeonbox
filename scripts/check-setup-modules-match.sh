#!/usr/bin/env bash
#
# 门禁：**go.work 的模块列表必须都能被 scripts/setup.sh 拉到**（工作区可构建性）。
#
# 为什么有这道门禁（2026-11-02 实录）：
#   `make setup` 是工作区「拉齐模块仓」的唯一入口（init-workspace.sh 的 [2/5] 走它）
#   ⇒ 若某个模块**进了 go.work 却没进 setup.sh**，新克隆的工作区就没有该目录
#   ⇒ `go build` 报 "directory prefix X does not contain modules listed in go.work"
#   ⇒ 而 **hub CI 发现不了**：CI 自己用 actions/checkout 检生态仓，**不走 setup.sh**
#   ⇒ 这类漂移只在开发者本地炸。
#   反向（setup.sh 拉了但不在 go.work，如已归档的 kit、纯打包的 NAS 四仓）是**允许的**
#   ⇒ 只列出提示，不判红。
#
# 用法：bash scripts/check-setup-modules-match.sh [--selfcheck]
set -uo pipefail

ROOT="${SETUP_MATCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
GO_WORK="$ROOT/go.work"
SETUP_SH="$ROOT/scripts/setup.sh"

# ───────────────────────── 取名单 ─────────────────────────

# go_work_modules：go.work 的 use 列表里的模块目录（去 ./ 前缀）。
go_work_modules() {
	awk '/^use \(/ {inuse=1; next} inuse && /^\)/ {inuse=0} inuse {gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) {sub(/^\.\//, "", $0); print $0}}' "$GO_WORK"
}

# setup_fetches：setup.sh 里 clone_or_update 的第二个参数（= 仓目录）。
setup_fetches() {
	grep -E '^[[:space:]]*clone_or_update[[:space:]]+' "$SETUP_SH" 2>/dev/null |
		awk '{print $3}'
}

# ───────────────────────── 判定 ─────────────────────────

check() {
	local missing="" extra=""
	local m f
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		found=0
		while IFS= read -r f; do
			[ "$f" = "$m" ] && found=1 && break
		done <<<"$(setup_fetches)"
		[ "$found" -eq 1 ] || missing="${missing} ${m}"
	done <<<"$(go_work_modules)"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		found=0
		while IFS= read -r m; do
			[ "$m" = "$f" ] && found=1 && break
		done <<<"$(go_work_modules)"
		[ "$found" -eq 1 ] || extra="${extra} ${f}"
	done <<<"$(setup_fetches)"

	if [ -n "$missing" ]; then
		echo "✗ go.work 里的模块未被 scripts/setup.sh 拉取:${missing}"
		echo "  ⇒ 新克隆的工作区缺这些目录 ⇒ go build 会报"
		echo "    \"directory prefix X does not contain modules listed in go.work\""
		echo "  ⇒ 修法: 在 scripts/setup.sh 的 clone_or_update 列表里补上"
		return 1
	fi
	echo "✓ go.work 的模块都能被 scripts/setup.sh 拉到"
	if [ -n "$extra" ]; then
		echo "  (提示) setup.sh 还拉了 go.work 之外的仓:${extra}（纯打包/前端/已归档，允许）"
	fi
	return 0
}

# ───────────────────────── 自证 ─────────────────────────

# selfcheck 用**合成 fixture**（不依赖真实仓）验证：
#   ① 模块都能拉到 ⇒ 绿
#   ② go.work 多一个模块而 setup.sh 没拉 ⇒ **必须红**
selfcheck() {
	local fails=0 tmp
	tmp="$(mktemp -d)"
	mkdir -p "$tmp/scripts"

	# ① 一致 ⇒ 绿
	cat >"$tmp/go.work" <<'EOF'
go 1.26.10

use (
	./alpha
	./beta
)
EOF
	cat >"$tmp/scripts/setup.sh" <<'EOF'
clone_or_update alpha alpha main
clone_or_update beta  beta  main
EOF
	local rc=0
	SETUP_MATCH_ROOT="$tmp" bash "$0" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "✗ 名单一致却判红（rc=${rc}）"
		fails=$((fails + 1))
	fi

	# ② go.work 有 gamma、setup.sh 没拉 ⇒ 必须红
	cat >"$tmp/go.work" <<'EOF'
go 1.26.10

use (
	./alpha
	./gamma
)
EOF
	rc=0
	SETUP_MATCH_ROOT="$tmp" bash "$0" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		echo "✗ 漏拉的模块未被检出（应判红）"
		fails=$((fails + 1))
	fi

	rm -rf "$tmp"
	if [ "$fails" -eq 0 ]; then
		echo "✓ selfcheck 通过（一致⇒绿 / 漏拉⇒红）"
		return 0
	fi
	echo "✗ selfcheck 失败 ${fails} 项"
	return 1
}

# ───────────────────────── 主流程 ─────────────────────────

if [ "${1:-}" = "--selfcheck" ]; then
	selfcheck
	exit $?
fi

[ -f "$GO_WORK" ] || {
	echo "找不到 go.work: $GO_WORK" >&2
	exit 1
}
[ -f "$SETUP_SH" ] || {
	echo "找不到 scripts/setup.sh: $SETUP_SH" >&2
	exit 1
}
check
