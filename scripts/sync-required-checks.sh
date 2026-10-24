#!/usr/bin/env bash
#
# 机械同步：把 hub CI 的 job 显示名写进 main 的分支保护 required checks。
#
# 为什么需要它（2026-10-24 实录）：
#   hub 曾是全生态**唯一**把 CI 漏在 required checks 之外的仓 ⇒ 直推 main
#   不受任何门禁约束。而 required contexts 必须与 CI 的 job 显示名**逐字一致**
#   （job 名含空格与中文 ⇒ 手拼 JSON 极易出错）⇒ 手工同步既慢又易错 ⇒
#   做成机械动作：改完 ci.yml 后跑一次本脚本（或触发 sync-required-checks
#   工作流）⇒ 保护规则与 CI 永远一致。
#
# 与 check-required-checks.sh 的分工：
#   · check-required-checks.sh —— **只读断言**（CI 里跑 ⇒ 防漂移）
#   · sync-required-checks.sh —— **写入同步**（人工/工作流触发 ⇒ 执行动作）
#
# 需要 admin 凭据（classic PAT 的 repo scope 或 fine-grained 的
# Administration:write）⇒ CI 里用 secrets.PB_BOT_TOKEN。
#
# 用法：bash scripts/sync-required-checks.sh [--repo pigeonbox/pigeonbox]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/ci-job-names.sh
. "$(dirname "$0")/ci-job-names.sh"

REPO="pigeonbox/pigeonbox"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    *) echo "用法: $0 [--repo owner/name]"; exit 2 ;;
  esac
done

WF=.github/workflows/ci.yml
if [ ! -f "$WF" ]; then
  echo "✗ 找不到 ${WF}——同步脚本自身失效"
  exit 1
fi

JOBS=$(ci_job_names "$WF")
if [ -z "$JOBS" ]; then
  echo "✗ 没解析出任何 CI job——同步脚本自身失效（ci.yml 结构变了？）"
  exit 1
fi

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$TOKEN" ]; then
  export GH_TOKEN="$TOKEN"
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "✗ 没有 gh CLI——同步脚本自身失效"
  exit 1
fi

# 构造 JSON：job 名含空格 ⇒ 必须逐个放进数组（jq -Rsc + split）。
TMP=$(mktemp)
printf '%s\n' "$JOBS" > "$TMP"
JSON=$(jq -Rsc '{required_status_checks:{strict:true,contexts:(split("\n")|map(select(length>0)))}}' < "$TMP")
rm -f "$TMP"

echo "→ 目标：${REPO} main"
echo "→ 要写入的 contexts:"
printf '%s\n' "$JOBS" | sed 's/^/    /'

echo "→ PATCH 分支保护…"
if gh api -X PATCH "repos/${REPO}/branches/main/protection" --input - <<EOF 2>&1 | tail -6
$JSON
EOF
then
  :
else
  echo "✗ PATCH 失败（需要 admin 凭据：本地用 gh 登录凭据，CI 用 secrets.PB_BOT_TOKEN）"
  exit 1
fi

NOW=$(gh api "repos/${REPO}/branches/main/protection" --jq '.required_status_checks.checks // [] | map(.context) | join(" | ")')
echo "→ 现在的 required checks: ${NOW}"

miss=0
TMP2=$(mktemp)
printf '%s\n' "$JOBS" > "$TMP2"
while IFS= read -r job; do
  [ -z "$job" ] && continue
  if ! printf '%s' "$NOW" | tr '|' '\n' | grep -Fxq "$job"; then
    echo "✗ 「${job}」仍不在 required checks 里"
    miss=1
  fi
done < "$TMP2"
rm -f "$TMP2"

if [ "$miss" -ne 0 ]; then
  echo "✗ 同步未生效"
  exit 1
fi
echo "✓ 已同步：CI 的每个 job 都在 required checks 里"
