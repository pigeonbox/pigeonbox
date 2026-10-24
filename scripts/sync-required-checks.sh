#!/usr/bin/env bash
#
# 机械同步：把 hub CI 的 job 显示名写进 main 的**合并必需检查**。
#
# 为什么走 ruleset 而不是 legacy branch protection（2026-10-24 实测）：
#   PATCH /branches/main/protection 对本地 gh 凭据**返回 404**（即便该仓权限是
#   admin）⇒ classic PAT 与 gh 的 OAuth token 都不含「改分支保护」的权限；
#   而 POST /rulesets **可以** ⇒ 走 ruleset 的 required_status_checks 规则。
#   两条机制**并行且同时生效** ⇒ legacy 里的 Secret Scan 保留，CI 由 ruleset 兜住。
#
# 为什么需要机械同步：
#   required contexts 必须与 CI 的 job 显示名**逐字一致**，而 job 名含空格与中文
#   （"shell 变量名边界"、"部署模板一致性（反代体积上限）"…）⇒ 手拼必错。
#
# 与 check-required-checks.sh 的分工：
#   · check-required-checks.sh —— **只读断言**（CI 里跑 ⇒ 防漂移）
#   · sync-required-checks.sh —— **写入同步**（人工/工作流触发 ⇒ 执行动作）
#
# 用法：bash scripts/sync-required-checks.sh [--repo pigeonbox/pigeonbox]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/ci-job-names.sh
. "$(dirname "$0")/ci-job-names.sh"

REPO="pigeonbox/pigeonbox"
RULESET_NAME="ci-required"
BYPASS_LOGIN="${PB_BYPASS_LOGIN:-zy84338719}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --bypass) BYPASS_LOGIN="${2:-}"; shift 2 ;;
    *) echo "用法: $0 [--repo owner/name] [--bypass <登录名>]"; exit 2 ;;
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

# 构造 ruleset payload：contexts 逐个进数组（jq -Rsc，job 名含空格不能拼串）。
TMP=$(mktemp)
printf '%s\n' "$JOBS" > "$TMP"
CONTEXTS_JSON=$(jq -Rsc 'split("\n")|map(select(length>0))' < "$TMP")
rm -f "$TMP"

# bypass：列车编排器（org secret PB_BOT_TOKEN = 该用户的 PAT）推的**提交**也要
# 能进 main —— 它不走 PR、也没有 CI ⇒ 若不 bypass，会把整条列车卡死。
# 与既有纪律一致（legacy protection 的 enforce_admins=false ⇒ admin 可绕过）。
BYPASS_ID=$(gh api "users/${BYPASS_LOGIN}" --jq '.id' 2>/dev/null || true)
BYPASS_JSON='[]'
if [ -n "$BYPASS_ID" ]; then
  BYPASS_JSON=$(jq -n --argjson id "$BYPASS_ID" '[{actor_id: $id, actor_type: "User", bypass_mode: "always"}]')
fi

PAYLOAD=$(jq -n --arg name "$RULESET_NAME" --argjson ctx "$CONTEXTS_JSON" --argjson bypass "$BYPASS_JSON" '{
  name: $name,
  target: "branch",
  enforcement: "active",
  conditions: {ref_name: {include: ["refs/heads/main"], exclude: []}},
  bypass_actors: $bypass,
  rules: [
    {type: "required_status_checks", parameters: {
      # 注意：**不要带 integration_id: null** —— GitHub 的 ruleset API 拒收该字段
      # （带了就 422；不带即表示「非集成来源的检查」）。实测踩过。
      required_status_checks: ($ctx | map({context: .})),
      strict_required_status_checks_policy: true,
      do_not_enforce_on_create: false
    }}
  ]
}')

# payload 走**文件**传给 gh（实测 `--input -`（stdin）在 gh 上不生效 ⇒ 误判失败）
PAYLOAD_FILE=$(mktemp)
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

echo "→ 目标：${REPO} main"
echo "→ 要写入的 contexts:"
printf '%s\n' "$JOBS" | sed 's/^/    /'
echo "→ bypass：${BYPASS_LOGIN}(id=${BYPASS_ID:-无})（列车编排器推的提交不走 PR）"

RS_ID=$(gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name==\"${RULESET_NAME}\") | .id" 2>/dev/null | head -1)

if [ -z "$RS_ID" ]; then
  echo "→ ruleset「${RULESET_NAME}」不存在 ⇒ 新建"
  if ! gh api -X POST "repos/${REPO}/rulesets" --input "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "✗ 新建 ruleset 失败（需 admin 凭据）"
    rm -f "$PAYLOAD_FILE"
    exit 1
  fi
else
  echo "→ ruleset「${RULESET_NAME}」已存在（id=${RS_ID}）⇒ 更新"
  if ! gh api -X PUT "repos/${REPO}/rulesets/${RS_ID}" --input "$PAYLOAD_FILE" >/dev/null 2>&1; then
    echo "✗ 更新 ruleset 失败（需 admin 凭据）"
    rm -f "$PAYLOAD_FILE"
    exit 1
  fi
fi
rm -f "$PAYLOAD_FILE"

# 回读验证（两处都读：legacy 与 ruleset）
# shellcheck source=scripts/repo-required-contexts.sh
. "$(dirname "$0")/repo-required-contexts.sh"
NOW=$(repo_required_contexts "$REPO" || true)
echo "→ 回读合并必需检查: $(printf '%s' "$NOW" | tr '\n' ' ')"

miss=0
TMP2=$(mktemp)
printf '%s\n' "$JOBS" > "$TMP2"
while IFS= read -r job; do
  [ -z "$job" ] && continue
  if ! printf '%s' "$NOW" | grep -Fxq "$job"; then
    echo "✗ 「${job}」仍不在必需检查里"
    miss=1
  fi
done < "$TMP2"
rm -f "$TMP2"

if [ "$miss" -ne 0 ]; then
  echo "✗ 同步未生效"
  exit 1
fi
echo "✓ 已同步：CI 的每个 job 都在合并必需检查里"
