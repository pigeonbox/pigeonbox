#!/usr/bin/env bash
# check-no-bare-go.sh — 跨仓「禁裸 go」门禁（AST 级）
#
# 背景（2026-10-27 实录）：裸 goroutine 的 panic **无人接** ⇒ 直接带走整个进程。
# PigeonBox 的四个平台仓（server 部署壳 + fnos/openwrt/qnap 原生包）都是**长驻**
# 进程 ⇒ 一个后台协程里的 nil 解引用就能把整站打挂。修法是 oekit/concurrency/async
# 的 GoSafe 家族（panic 收编 + 经全局 handler 上报，不静默）。
#
# 范围分工（避免与仓内自守重复）：
#   · **core / p2p**：各自仓内已有 `internal/convention` 的守卫（PR 期即拦）⇒ 不在此重复；
#   · **server / fnos / openwrt / qnap**：代码量小、尚无仓内守卫 ⇒ 由本门禁跨仓扫描。
#
# 放行项（每仓 1 处）：**主服务协程**（进程的存在意义就是它）⇒ panic 应带崩进程，
# 让 supervisor（容器 restart policy / procd / QNAP 脚本）重启它；改成 GoSafe 会让
# 错误永不投递到主流程 ⇒ 主流程挂死 ⇒「活着但不服务」比直接死掉更难诊断。
#
# 判定：AST 级（go/ast 的 *ast.GoStmt）——文本 grep 会把注释/字符串/`//go:xxx`
# 指令误判，也认不出 `go someFunc()` 这种非字面量形态。
#
# 覆盖口径（2026-11-11 pigeonbox#329）：**零覆盖/缺仓不判绿**。
# 此前仓不在位只 continue，扫了 0 个仓仍输出「✓ …覆盖 server/fnos/openwrt/qnap」
# 并 rc=0 —— 结论行宣称覆盖 4 个仓、实际覆盖 0 个（与 ci-health.sh「空转判红」
# 口径相反）。现在：SCOPE 期望清单里任一仓不在位 ⇒ 判红并**点名缺哪个**；
# 结论行只报**实际扫到**的仓。
#
# 用法: bash scripts/check-no-bare-go.sh [--selfcheck]
#   --selfcheck: 注入一处真实裸 go ⇒ 本门禁必须变红；移除后必须恢复绿；
#                并自证覆盖口径（全在位绿 / 缺仓红并点名 / 零覆盖红）。
# 退出码: 0 = 全部期望仓在位且无裸 go；1 = 有裸 go 或覆盖不可用（缺仓/零覆盖）。
set -uo pipefail

ROOT="${NO_BARE_GO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SCANNER="$ROOT/bin/nobarego"

# 扫描范围：仓目录 → 放行项（<相对路径>:<函数名>）
SCOPE=(
  "server|cmd/server/main.go:main"
  "fnos|cmd/fnos-adapter/main.go:main"
  "openwrt|cmd/pigeonbox/main.go:main"
  "qnap|cmd/pigeonbox/main.go:main"
)

build_scanner() {
  mkdir -p "$ROOT/bin"
  (cd "$ROOT/scripts" && GOWORK=off go build -o "$SCANNER" ./nobarego)
}

# 覆盖声明（结果行用）：只报**实际扫到**的仓。
SCAN_NAMES=""

scan_all() {
  bad=0
  scanned=0
  missing=""
  SCAN_NAMES=""
  for entry in "${SCOPE[@]}"; do
    repo="${entry%%|*}"
    allow="${entry##*|}"
    if [ ! -d "$ROOT/$repo" ]; then
      missing="$missing $repo"
      continue
    fi
    scanned=$((scanned + 1))
    SCAN_NAMES="$SCAN_NAMES $repo"
    if ! "$SCANNER" -root "$ROOT/$repo" -allow "$allow"; then
      echo "  ✗ ${repo} 有裸 go 语句（放行项：${allow}）"
      bad=1
    fi
  done
  if [ -n "$missing" ]; then
    # 缺仓 ⇒ 判红（pigeonbox#329）：期望清单来自 SCOPE（唯一事实源），缺哪个点名。
    # 零覆盖更是「判据不可用」——不许像旧实现那样输出覆盖 4 个仓的绿灯。
    if [ "$scanned" -eq 0 ]; then
      echo "✗ 扫了 0 个仓（缺：${missing}）⇒ 判据不可用，零覆盖不判绿（与 ci-health.sh 空转判红同口径）"
    else
      echo "✗ 覆盖不完整：已扫 ${scanned} 个（${SCAN_NAMES}），缺：${missing} ⇒ 判失败（缺仓必须点名补齐：检出这些仓到 ${ROOT}/ 再跑）"
    fi
    return 2
  fi
  echo "已扫 $scanned 个仓：$SCAN_NAMES"
  return $bad
}

build_scanner

if [ "${1:-}" = "--selfcheck" ]; then
  # 自证：注入一处真实缺陷 ⇒ 必须被判出；放行项登记的那一处 ⇒ 必须放行。
  # （直接验扫描器：临时仓里放一个裸 go，分别放在辅助函数与 main 里。）
  TMP="$(mktemp -d)"
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  mkdir -p "$TMP/server/cmd/server"

  cat >"$TMP/server/cmd/server/main.go" <<'GO'
package main

func main() {
	go helper()
}

func helper() {
	go func() { _ = 1 }()
}
GO
  if "$SCANNER" -root "$TMP/server" -allow "cmd/server/main.go:main" >/dev/null 2>&1; then
    echo "✗ 自证失败：辅助协程里的裸 go 未被判出 ⇒ 门禁空转" >&2
    exit 1
  fi
  echo "✓ 自证：辅助协程里的裸 go 被判红 ⇒ 门禁有牙齿"

  cat >"$TMP/server/cmd/server/main.go" <<'GO'
package main

func main() {
	go func() { _ = 1 }()
}
GO
  if ! "$SCANNER" -root "$TMP/server" -allow "cmd/server/main.go:main" >/dev/null 2>&1; then
    echo "✗ 自证失败：放行项（主服务协程）被误伤 ⇒ 门禁有误报" >&2
    exit 1
  fi
  echo "✓ 自证：放行项（主服务协程）被正确放行"

  # 放行项只允许 1 处：同一函数里再有一处裸 go ⇒ 仍判红（防白名单变成垃圾桶）
  cat >"$TMP/server/cmd/server/main.go" <<'GO'
package main

func main() {
	go func() { _ = 1 }()
	go func() { _ = 2 }()
}
GO
  if "$SCANNER" -root "$TMP/server" -allow "cmd/server/main.go:main" >/dev/null 2>&1; then
    echo "✗ 自证失败：放行项之外的第二处裸 go 未被判出 ⇒ 白名单成了垃圾桶" >&2
    exit 1
  fi
  echo "✓ 自证：放行项之外的第二处裸 go 仍被判红 ⇒ 白名单不失控"

  # ── 覆盖口径自证（pigeonbox#329）────────────────────────────────────────
  # 期望清单（SCOPE）逐仓对账：全在位 ⇒ 绿且结论行报实际扫到的仓；
  # 缺仓 ⇒ 红并点名；零覆盖 ⇒ 红并点名「扫了 0 个仓」。
  mk_cov_fixture() { # <root> <repo...>：造放行路径上的「干净」仓（无裸 go）
    _fx="$1"
    shift
    mkdir -p "$_fx/scripts/nobarego"
    cp "$ROOT/scripts/go.mod" "$ROOT/scripts/go.sum" "$_fx/scripts/"
    cp "$ROOT/scripts/nobarego/main.go" "$_fx/scripts/nobarego/"
    for _r in "$@"; do
      for entry in "${SCOPE[@]}"; do
        [ "${entry%%|*}" = "$_r" ] || continue
        _ap="${entry##*|}" # <相对路径>:<函数名>
        _ap="${_ap%%:*}"
        mkdir -p "$_fx/$_r/$(dirname "$_ap")"
        printf 'package main\n\nfunc main() {}\n' >"$_fx/$_r/$_ap"
      done
    done
  }
  ALL_REPOS=""
  for entry in "${SCOPE[@]}"; do ALL_REPOS="$ALL_REPOS ${entry%%|*}"; done

  # shellcheck disable=SC2086  # ALL_REPOS 是按空格分隔的仓清单，需要分词展开
  mk_cov_fixture "$TMP/cov-full" $ALL_REPOS
  out=$(NO_BARE_GO_ROOT="$TMP/cov-full" bash "$ROOT/scripts/check-no-bare-go.sh" 2>&1)
  rc=$?
  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '实际覆盖' &&
    printf '%s' "$out" | grep -q 'qnap'; then
    echo "✓ 覆盖自证①：期望清单全部在位 ⇒ 绿，且结论行报实际扫到的仓"
  else
    echo "✗ 覆盖自证①失败（rc=${rc}：${out}）" >&2
    exit 1
  fi

  mk_cov_fixture "$TMP/cov-missing" server fnos openwrt # 缺 qnap
  out=$(NO_BARE_GO_ROOT="$TMP/cov-missing" bash "$ROOT/scripts/check-no-bare-go.sh" 2>&1)
  rc=$?
  if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q 'qnap'; then
    echo "✓ 覆盖自证②：缺仓 ⇒ 判红并点名缺的仓（qnap）"
  else
    echo "✗ 覆盖自证②失败：缺仓未判红或未点名（rc=${rc}：${out}）" >&2
    exit 1
  fi

  mkdir -p "$TMP/cov-empty"
  out=$(NO_BARE_GO_ROOT="$TMP/cov-empty" bash "$ROOT/scripts/check-no-bare-go.sh" 2>&1)
  rc=$?
  if [ "$rc" != "0" ] && printf '%s' "$out" | grep -q '扫了 0 个仓'; then
    echo "✓ 覆盖自证③：零覆盖 ⇒ 判红并点名「扫了 0 个仓」（判据不可用不判绿）"
  else
    echo "✗ 覆盖自证③失败：零覆盖未判红（rc=${rc}：${out}）" >&2
    exit 1
  fi

  OK=1
  exit 0
fi

scan_all
scan_rc=$?
if [ "$scan_rc" -eq 0 ]; then
  # 结论行只报**实际扫到**的仓（缺仓/零覆盖已在 scan_all 判红，走不到这里）。
  echo "✓ 禁裸 go 检查通过（AST 级；实际覆盖：${SCAN_NAMES}；core 与 p2p 仓内自守）"
  OK=1
  exit 0
fi
if [ "$scan_rc" -eq 1 ]; then
  echo ""
  echo "修法：改用 async.GoSafe / async.GoSafeLabeled（panic 收编 + 全局 handler 上报）。"
  echo "      若确属「主服务协程」（进程的存在意义就是它，panic 应带崩进程让 supervisor 重启），"
  echo "      在 scripts/check-no-bare-go.sh 的 SCOPE 里登记放行项并写明理由。"
fi
exit 1
