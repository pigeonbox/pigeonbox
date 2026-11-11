#!/bin/bash
# 拉齐/更新 PigeonBox 工作区的模块仓库(contracts/core/server/frontend/frontend-core/fnos/openwrt/p2p/kit
# + NAS 打包四仓 synology/qnap/ugreen/terramaster)。
#
# 语义（2026-11-02 加固）：
#   · 取数一律走 scripts/git-fetch-safe.sh（**有超时 + 有限重试**）⇒ 链路瞬断时
#     git 会挂住（ssh 层无进展 ⇒ git 不自行放弃）⇒ 裸命令会让整个 setup 无限等。
#   · **默认分支解析** origin/HEAD ⇒ 不硬编码（生态里 fnos 是 master 不是 main；
#     硬编码 main ⇒ "couldn't find remote ref main" ⇒ 取数失败却看着像网络问题）。
#   · 默认把各仓切到**默认分支**再快进（旧列车分支如 train/4.6.7-fix 是历史遗留，
#     留在上面会让本地联编用旧代码）；SETUP_KEEP_BRANCH=1 可保留当前分支。
#   · **脏仓守卫**：有未提交改动 ⇒ 不切分支、不拉取（可能是同机并行会话的工作）。
#   · 取数失败的仓**跳过并记账**，跑完统一报 ⇒ 不给「工作区就绪」的假结论。
#
# 退出码：0 = 全部拉齐；1 = 有仓未拉齐/被跳过（细节见末尾汇总）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KEEP_BRANCH="${SETUP_KEEP_BRANCH:-0}"
FAILED=""
SKIPPED=""

# default_branch_of <dir> <fallback>：解析该仓的默认分支（origin/HEAD）。
default_branch_of() {
  local dir="$1" fallback="$2" b
  b="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  printf '%s' "${b:-$fallback}"
}

# switch_to <dir> <branch>：切到目标分支；本地没有该分支则从 origin/<branch> 建。
# ⚠️ 只在**该分支不存在**时才用 -B（建分支）⇒ 绝不覆盖已有分支指针、
#    绝不丢本地提交。
switch_to() {
  local dir="$1" branch="$2"
  git -C "$dir" checkout -q "$branch" 2>/dev/null && return 0
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    return 1 # 分支存在但切不过去（多半是工作树脏）⇒ 保持当前分支
  fi
  git -C "$dir" checkout -q -B "$branch" "origin/$branch"
}

clone_or_update() {
  local repo="$1" dir="$2" fallback="$3"
  if [ ! -d "$dir/.git" ]; then
    echo "↓ 克隆 $repo → $dir"
    if bash scripts/git-fetch-safe.sh clone "https://github.com/pigeonbox/$repo.git" "$dir" "$fallback"; then
      return 0
    fi
    echo "  ✗ $repo 克隆失败/超时"
    FAILED="$FAILED $repo"
    return 0
  fi

  local branch dirty
  branch="$(default_branch_of "$dir" "$fallback")"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$dirty" -gt 0 ]; then
    echo "⟳ 更新 $dir"
    echo "  ⚠ 有 ${dirty} 处未提交改动 ⇒ **不切分支、不拉取**（可能是同机并行会话的工作）"
    SKIPPED="$SKIPPED $repo"
    return 0
  fi

  if [ "$KEEP_BRANCH" != "1" ] && [ "$(git -C "$dir" branch --show-current)" != "$branch" ]; then
    if switch_to "$dir" "$branch"; then
      echo "⟳ 更新 ${dir}（已切到 ${branch}）"
    else
      echo "⟳ 更新 ${dir}（切 ${branch} 失败 ⇒ 保持当前分支 $(git -C "$dir" branch --show-current)）"
    fi
  else
    echo "⟳ 更新 ${dir}（分支 $(git -C "$dir" branch --show-current)）"
  fi

  if bash scripts/git-fetch-safe.sh pull "$dir" "$branch"; then
    return 0
  fi
  echo "  ✗ $repo 取数失败/超时 ⇒ 跳过"
  FAILED="$FAILED $repo"
  return 0
}

clone_or_update contracts contracts main
clone_or_update core core main
clone_or_update server server main
clone_or_update frontend frontend main
clone_or_update frontend-core frontend-core main

# 飞牛 fnOS 应用适配层(go.work 已引用,默认拉取;SETUP_FNOS=0 可跳过,
# 但跳过后工作区内 go build 会因 go.work 缺目录而报错)
# 注: repo 2026-10-04 已由 pigeonbox-fnos 改名 fnos(旧 URL 自动重定向),本地目录已同步为 fnos
# ⚠️ fnos 的默认分支是 **master**（历史原因）⇒ 下面传 master 作 clone 兜底，
#    已存在的仓则一律用 origin/HEAD 解析出的默认分支（不靠这里的字面量）
if [ "${SETUP_FNOS:-1}" = "1" ]; then
  clone_or_update fnos fnos master
fi

# OpenWrt/iStoreOS 原生 ipk 适配层(go.work 已引用,默认拉取;SETUP_OPENWRT=0 可跳过)
if [ "${SETUP_OPENWRT:-1}" = "1" ]; then
  clone_or_update openwrt openwrt main
fi

# P2P 联邦注册中心(go.work 已引用,默认拉取;SETUP_P2P=0 可跳过)
if [ "${SETUP_P2P:-1}" = "1" ]; then
  clone_or_update p2p p2p main
fi

# kit 共享 Go 工具库 —— ⚠️ **已归档并入 oekit，且已退出 go.work**（2026-11-02 核实）
#   ⇒ 拉它只为保留历史 checkout；远端只读（archived），推送一律失败。
#   SETUP_KIT=0 可跳过（默认仍拉：只读仓的 fetch 是可用的）
if [ "${SETUP_KIT:-1}" = "1" ]; then
  clone_or_update kit kit main
fi

# NAS 打包四仓(纯打包无 Go,不进 go.work;SETUP_<名>=0 可跳过)
if [ "${SETUP_SYNOLOGY:-1}" = "1" ]; then
  clone_or_update synology synology main
fi
if [ "${SETUP_QNAP:-1}" = "1" ]; then
  clone_or_update qnap qnap main
fi
if [ "${SETUP_UGREEN:-1}" = "1" ]; then
  clone_or_update ugreen ugreen main
fi
if [ "${SETUP_TERRAMASTER:-1}" = "1" ]; then
  clone_or_update terramaster terramaster main
fi

# 目录清单用 glob 展开而非 ls（ls 的解析对含连字符/非字母数字的名字不稳）
echo "✓ 工作区就绪:$(for d in */; do printf '%s ' "${d%/}"; done)"

# 汇总：失败/跳过必须**看得见** ⇒ 不给「全部拉齐」的假结论
rc=0
if [ -n "$SKIPPED" ]; then
  echo "⚠ 跳过的仓(有未提交改动，未动):$SKIPPED" >&2
  rc=1
fi
if [ -n "$FAILED" ]; then
  echo "✗ 未拉齐的仓(取数失败/超时):$FAILED" >&2
  echo "  重试: bash scripts/git-fetch-safe.sh pull <dir> <branch>" >&2
  rc=1
fi
exit "$rc"
