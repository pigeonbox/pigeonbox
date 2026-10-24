#!/usr/bin/env bash
#
# 共享：解析 GitHub Actions workflow 的 job 显示名（每行一个）。
#
# 存在原因：hub 的门禁需要「CI 的 job 名」与「分支保护的 required contexts」
# 两边对齐，而 job 名**含空格与中文**（如 "shell 变量名边界"）⇒ 必须逐行传递，
# 不能用空格拼接（拼了会被 shell 拆成多个词 ⇒ PATCH 出一堆不存在的 context）。
#
# 用法：source scripts/ci-job-names.sh; ci_job_names .github/workflows/ci.yml
#
# 解析要点：**不要用 awk 的 getline**（它会消耗下一行 ⇒ 行序错位 ⇒ 漏掉中间的
# job —— 本函数第一版就是这么漏掉一个 job 的）。用不消耗行的状态机。
ci_job_names() { # <workflow 文件> → stdout：job 显示名，每行一个
  local wf="$1"
  awk '
    /^jobs:/ { injobs=1; next }
    injobs && /^  [A-Za-z0-9_-]+:/ {
      id=$1; sub(/:$/,"",id); pending=1; next
    }
    injobs && pending && /^    name:/ {
      n=$0; sub(/^    name: /,"",n); gsub(/^"|"$/,"",n); print n; pending=0; next
    }
    injobs && pending { print id; pending=0 }
  ' "$wf" | sed 's/[[:space:]]*$//' | grep -v '^$'
}
