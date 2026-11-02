#!/bin/bash
# 拉齐/更新 PigeonBox 工作区的模块仓库(contracts/core/server/frontend/frontend-core/fnos/openwrt/p2p/kit
# + NAS 打包四仓 synology/qnap/ugreen/terramaster)。
# 幂等:已存在则 git pull --ff-only。
set -e
cd "$(dirname "$0")/.."

clone_or_update() {
  local repo=$1 dir=$2 branch=$3
  # ⚠️ 走 git-fetch-safe.sh（2026-11-02 实录）：裸 `git pull` / `git clone`
  # **无超时无重试** ⇒ 链路瞬断时 git 会挂住 ⇒ 整个 make setup 无限等。
  # helper 给每次操作加上限+重试，并把「超时」与「失败」分成两个退出码。
  if [ -d "$dir/.git" ]; then
    echo "⟳ 更新 $dir"
    bash scripts/git-fetch-safe.sh pull "$dir" "$branch"
  else
    echo "↓ 克隆 $repo → $dir"
    bash scripts/git-fetch-safe.sh clone "https://github.com/pigeonbox/$repo.git" "$dir" "$branch"
  fi
}

clone_or_update contracts contracts main
clone_or_update core        core        main
clone_or_update server      server      main
clone_or_update frontend    frontend    main
clone_or_update frontend-core frontend-core main

# 飞牛 fnOS 应用适配层(go.work 已引用,默认拉取;SETUP_FNOS=0 可跳过,
# 但跳过后工作区内 go build 会因 go.work 缺目录而报错)
# 注: repo 2026-10-04 已由 pigeonbox-fnos 改名 fnos(旧 URL 自动重定向),本地目录已同步为 fnos
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

# kit 共享 Go 工具库(go.work 已引用,默认拉取;SETUP_KIT=0 可跳过)
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
