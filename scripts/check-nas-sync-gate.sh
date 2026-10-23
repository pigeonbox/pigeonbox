#!/usr/bin/env bash
#
# 门禁：NAS 模板漂移门禁（deploy/nas/sync.sh check）的结论**不得依赖检出形态**。
#
# 为什么有这道门禁（2026-10-24 实录）：
#   `sync.sh check` 的「实际」侧此前写死取 origin/<仓默认分支>(main)。可 CI 的
#   **push 事件检出的是列车分支**(train/<v>)，内容已是**本车**新版本，而
#   origin/main 还是**上一车**版本 ⇒ 拿新内容比旧版本 ⇒ **必然**假漂移。
#   ⇒ ugreen/terramaster/synology 三个物化 PR 的漂移门禁全红 ⇒ auto-merge 被
#   阻断 ⇒ **整条 3.3.15 列车卡在 draft**（advance 干等，tag 打不出去）。
#   ⇒ 且「有时绿有时红」纯靠运气（hub 同列车分支是否已推 / raw CDN 5min 缓存
#   里是哪个版本）⇒ 不可复现、不可靠。
#
#   根因是**判定逻辑把检出形态当成了内容版本**。修法：取 origin/<当前检出分支>。
#   而这类「同一内容、不同检出形态 ⇒ 不同结论」的缺陷，**只有把两种形态都跑一遍
#   并要求结论一致**才能机械拦住 ⇒ 本门禁就是那个判别测试。
#
# 本门禁自足（不需要真实 NAS 仓）：现场造一个「被测仓」+ 一个 bare origin，
# 把 hub 模板物化进去，然后用三种形态跑 check：
#   ① 分支检出（CI 的 push 事件形态）⇒ 必须**绿**
#   ② 游离 HEAD（CI 的 pull_request 检出形态）⇒ 必须**绿**
#   ③ 真漂移（把内容改成旧版并推到 origin）⇒ 必须**红**（防「门禁变哑」）
#
# 关键：被测仓必须**同时有** main（旧内容）与 train/*（新内容）两个分支 ——
#   否则「当前检出分支」与「仓默认分支」是同一个 ⇒ 新旧判定逻辑结论一致 ⇒
#   门禁测不出差别（形同虚设）。这正是真实场景：列车分支已物化到本车新版，
#   而 main 还停在上一车。
#
# 用法：bash scripts/check-nas-sync-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SYNC="deploy/nas/sync.sh"
if [ ! -f "$SYNC" ]; then
  echo "✗ 找不到 ${SYNC}——门禁自身失效（物化脚本改名/移动了？）"
  exit 1
fi
if [ ! -f deploy/nas/compose.yml ]; then
  echo "✗ 找不到 deploy/nas/compose.yml——门禁自身失效（模板不在了？）"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ORIGIN="$TMP/origin.git"
PLAT="$TMP/platform"
git init -q --bare "$ORIGIN"
git init -q -b main "$PLAT"
git -C "$PLAT" remote add origin "$ORIGIN"

# 用 hub 模板物化出「正确内容」（与真实 NAS 仓物化结果同源同形）。
bash "$SYNC" sync --platform ugreen --dir "$PLAT" >/dev/null 2>&1 || {
  echo "✗ 物化失败——门禁自身失效"
  bash "$SYNC" sync --platform ugreen --dir "$PLAT" 2>&1 | tail -5
  exit 1
}

commit_push() { # <说明> <分支>
  git -C "$PLAT" add -A
  git -C "$PLAT" -c user.email=gate@local -c user.name=gate commit -q -m "$1"
  git -C "$PLAT" push -q origin HEAD:"refs/heads/$2"
}

# 改版本号为「旧版」标记。**不用 sed -i**：其参数在 GNU sed（Linux CI）与
# BSD sed（macOS 本地）不兼容（-i '' vs -i）⇒ 这里用重定向，跨平台一致。
mark_old() { # <文件>
  _tmp="$1.gate.tmp"
  sed 's/PB_IMAGE_TAG:-[0-9.]*/PB_IMAGE_TAG:-0.0.0/g' "$1" > "$_tmp"
  mv "$_tmp" "$1"
}

# train/test = 本车新内容（物化结果）。
git -C "$PLAT" checkout -q -b train/test
commit_push "train/test: 物化结果（本车新版）" train/test

# main = **上一车**的旧内容（模拟 main 还停在上一版）。
# 检出 train/test 时：读 origin/main ⇒ 旧内容 ⇒ 假漂移；读 origin/train/test ⇒ 新内容 ⇒ 绿。
git -C "$PLAT" checkout -q --orphan main
git -C "$PLAT" rm -q -rf --cached . 2>/dev/null || true
mark_old "$PLAT/deploy/compose.yml"
commit_push "main: 上一车旧内容" main

check() { # <说明> → 0=绿 1=红
  if bash "$SYNC" check --platform ugreen --dir "$PLAT" >"$TMP/out" 2>&1; then
    echo "  ✓ $1 ⇒ 绿"
    return 0
  fi
  echo "  ✗ $1 ⇒ 红"
  sed -n '1,12p' "$TMP/out" | sed 's/^/      /'
  return 1
}

fail=0

echo "→ 检出形态判别（同一份正确内容，不同检出形态 ⇒ 结论必须一致）"

# ① 分支检出 = CI 的 push 事件形态（actions/checkout 对 push 事件建本地分支）。
git -C "$PLAT" checkout -q train/test
check "分支检出（CI push 事件形态）" || fail=1

# ② 游离 HEAD = CI 的 pull_request 检出形态（检出 PR 的 merge 提交）。
git -C "$PLAT" checkout -q --detach HEAD
check "游离 HEAD（CI pull_request 形态）" || fail=1

# ③ 真漂移必须仍被抓住（防「为了绿而把门禁改哑」）。
git -C "$PLAT" checkout -q train/test
mark_old "$PLAT/deploy/compose.yml"
commit_push "test: 真漂移" train/test
if check "真漂移（内容确实旧了）"; then
  echo "✗ 真漂移竟然报绿——门禁被改哑了"
  fail=1
else
  echo "  （真漂移被正确抓住 ⇒ 门禁没被改哑）"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "口径（勿再改错）:"
  echo "  · check 的「实际」侧 = **当前检出分支**的远端版本；游离 HEAD ⇒ 工作树"
  echo "  · 「期望」侧 = hub 同列车分支的模板（train/<v>）"
  echo "  · 两种检出形态对**同一份内容**必须给出**同一结论**"
  exit 1
fi

echo "✓ NAS 漂移门禁的结论与检出形态无关（分支/游离 HEAD 一致，真漂移仍被抓）"
