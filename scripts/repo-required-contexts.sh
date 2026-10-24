#!/usr/bin/env bash
#
# 共享：读某个仓 main 分支上「合并必需通过」的检查名（每行一个）。
#
# ⚠️ **两条并行路径都要读**（2026-10-24 踩坑）：
#   GitHub 上「哪些检查是合并必需」有两套机制，且**同时生效**：
#   ① legacy branch protection：GET /branches/main/protection
#   ② repository ruleset：GET /rulesets/{id}（**概要接口 GET /rulesets 不含
#      rules 详情** ⇒ 必须逐个按 id 取详情，否则读到空 ⇒ 门禁对着一侧断言）
#   只读 ① 会漏看 ② ⇒ 门禁可能对着空的一侧断言（而真正的约束在另一侧）。
#
# 用法：source scripts/repo-required-contexts.sh
#       repo_required_contexts pigeonbox/pigeonbox
repo_required_contexts() { # <owner/name> → stdout：检查名，每行一个
  local repo="$1" out="" id ctx

  # ① legacy branch protection
  ctx=$(gh api "repos/${repo}/branches/main/protection" \
        --jq '.required_status_checks.checks // [] | map(.context) | join("|")' 2>/dev/null || true)
  [ -n "$ctx" ] && out="${ctx}"

  # ② ruleset（逐个取详情）
  for id in $(gh api "repos/${repo}/rulesets" --jq '.[].id' 2>/dev/null); do
    ctx=$(gh api "repos/${repo}/rulesets/${id}" \
          --jq '[.rules[]? | select(.type=="required_status_checks") | .parameters.required_status_checks[]?.context] | join("|")' 2>/dev/null || true)
    [ -n "$ctx" ] && out="${out}${out:+|}${ctx}"
  done

  printf '%s' "$out" | tr '|' '\n' | grep -v '^$'
}
