#!/usr/bin/env bash
#
# 门禁：hub 的 CI **必须挂在 main 的合并路径上**（分支保护 required checks）。
#
# 为什么有这道门禁（2026-10-24 实录）：
#   全生态 17 仓体检分支保护，发现 **hub 是唯一把 CI 漏在 required checks 之外
#   的仓**——main 的 required 只有 `Secret Scan (gitleaks)`，CI 的**七道门禁**
#   （trainctl vet/test / shellcheck / 变量名边界 / 部署模板一致性 / 全能力真机
#   冒烟 / action pin 完整性 / NAS 漂移门禁形态判别）**全不在合并路径上**。
#   ⇒ 直推 main 完全不受任何门禁约束（push 输出只会提示「Bypassed rule
#   violations」，人容易忽略）⇒ 门禁对最需要它的仓形同虚设。
#   对照：core/server/contracts/p2p/fnos/openwrt/qnap/synology/ugreen/
#   terramaster/desktop/frontend/frontend-core/charts **全部**把 CI 列进了
#   required checks ⇒ hub 是唯一的缺口。
#
# 本门禁自证：① 从 ci.yml 解析出**当前所有 job 名**（跟着 CI 改动自动走），
# ② 逐个断言它在分支保护的 required checks 里；③ 缺一即红并指出是哪个。
# ⇒ CI 改名/加 job 后若忘了同步分支保护，本门禁立刻报出来（而不是等某次
# 合并被莫名挡住、或某道门禁悄悄失去强制力）。
#
# 需要 admin 凭据读分支保护 API（普通 GITHUB_TOKEN 无权读）⇒
#   本地：gh CLI 自带凭据；CI：secrets.PB_BOT_TOKEN（org 机器人）。
#
# 用法：bash scripts/check-required-checks.sh [--repo pigeonbox/pigeonbox]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO="pigeonbox/pigeonbox"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    *) echo "用法: $0 [--repo owner/name]"; exit 2 ;;
  esac
done

WF=.github/workflows/ci.yml
if [ ! -f "$WF" ]; then
  echo "✗ 找不到 ${WF}——门禁自身失效"
  exit 1
fi

# ── ① 解析 CI 的 job 名 ───────────────────────────────────────────────
# job 名取 job 级 name；解析逻辑与 sync-required-checks.sh 共用
# scripts/ci-job-names.sh（避免两处实现漂移）。
# shellcheck source=scripts/ci-job-names.sh
. "$(dirname "$0")/ci-job-names.sh"
JOBS=$(ci_job_names "$WF")

if [ -z "$JOBS" ]; then
  echo "✗ 没解析出任何 CI job——门禁自身失效（ci.yml 结构变了？）"
  exit 1
fi

# ── ② 读分支保护的 required checks ────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
  echo "✗ 没有 gh CLI——门禁自身失效（读不到分支保护）"
  exit 1
fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$TOKEN" ]; then
  export GH_TOKEN="$TOKEN"
fi

PROT=$(gh api "repos/${REPO}/branches/main/protection" --jq '.required_status_checks.checks // [] | map(.context) | join("|")' 2>/dev/null || true)
if [ -z "$PROT" ]; then
  echo "✗ 读不到 ${REPO} main 的分支保护（无 admin 凭据，或未配置保护？）"
  echo "  本门禁需要 admin 权限读分支保护 API：本地用 gh 登录凭据，CI 用 secrets.PB_BOT_TOKEN"
  exit 1
fi

echo "→ ${REPO} main 的 required checks: ${PROT}"
echo "→ CI 声明的 job: $(printf '%s' "$JOBS" | tr '\n' ' ')"

# ── ③ 逐个断言 ────────────────────────────────────────────────────────
# 注意：管道会把 while 放进**子 shell** ⇒ 循环里的变量不外传 ⇒ 用重定向喂输入
# （同一个坑：本日另一个门禁脚本也踩过；标记文件方案曾让 miss 永远是 0 ⇒ 门禁
#  永远绿 ⇒ 形同虚设）。
miss=0
TMP_JOBS=$(mktemp)
printf '%s\n' "$JOBS" > "$TMP_JOBS"
while IFS= read -r job; do
  [ -z "$job" ] && continue
  if ! printf '%s' "$PROT" | tr '|' '\n' | grep -Fxq "$job"; then
    echo "✗ CI job「${job}」不在 required checks 里 ⇒ 它对合并没有强制力"
    miss=1
  fi
done < "$TMP_JOBS"
rm -f "$TMP_JOBS"

if [ "$miss" -ne 0 ]; then
  echo
  echo "修法（一次改完，别只改一半）:"
  echo "  gh api -X PATCH repos/${REPO}/branches/main/protection \\"
  echo "    -f 'required_status_checks[strict]=true' \\"
  echo "    -f 'required_status_checks[contexts][]=<job 名>' ..."
  echo "  （contexts 就是上面的 job 显示名；CI 改名/加 job 后要同步这里）"
  exit 1
fi

echo "✓ CI 的每个 job 都在 required checks 里（合并路径已强制）"
