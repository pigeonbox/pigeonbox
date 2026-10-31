#!/usr/bin/env bash
#
# 门禁：所有 workflow 里的 action pin 必须是「40 位小写 hex 的合法 commit」，
# 且同一个 action 在本仓内不得出现互相矛盾的 pin。
#
# 为什么有这道门禁（2026-10-23 实录）：
#   本仓 ci.yml 里 5 处 `actions/checkout` 有 4 处写成
#   `3d3c42e5aac5ba805825da76410c181273ba90b1`（v7，正确），1 处写成
#   `3d3d42e5aac5ba805825da76410c181273ba90b1`（第 5 位 c→d，**打错一位**）。
#   后果不是「CI 抓到了 bug」，而是**那道门禁自己根本没启动**：
#   GitHub 在解析 action 阶段就报 `unable to find version <sha>`，
#   该 job 从未跑过一行断言 ⇒ 空转的绿/红都无从谈起。
#   而它从 3.3.13 加入起就一直是空转 ⇒ 整整两个发版列车，CI 显示的
#   「红」被当成环境问题忽略了。
#
#   教训有两层：
#   ① **pin 打错一位是人眼错误** ⇒ 必须有机械校验，不能靠 review 时眼力。
#   ② **门禁必须能自证「我跑过了」** ⇒ 本脚本开头就打印扫到多少个 pin，
#      扫不到任何 pin 直接判红（门禁自身空转也算失败）。
#
# 用法：
#   bash scripts/check-action-pins.sh            # 本地一致性 + 格式（零网络）
#   bash scripts/check-action-pins.sh --remote   # 额外调 GitHub API 逐个验 commit 存在
#   bash scripts/check-action-pins.sh --selfcheck  # 自证：注入坏 pin ⇒ 本门禁必须变红
#
# --remote 需要 token（GH_TOKEN 或 GITHUB_TOKEN）；拿不到就明确报错退出，
# 绝不「静默降级为通过」——否则又是一次假绿。
#
# 兼容：POSIX sh + 基础工具（不用关联数组/大小写展开，macOS 自带 bash 3.2 也能跑）。
set -uo pipefail

# 扫描根目录可覆盖（自证模式要指向临时工作区）
ROOT="${ACTION_PINS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

REMOTE=0
SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --remote) REMOTE=1 ;;
    --selfcheck) SELFCHECK=1 ;;
    *) echo "用法: $0 [--remote] [--selfcheck]"; exit 2 ;;
  esac
done

WF_DIR=.github/workflows
if [ ! -d "$WF_DIR" ]; then
  echo "✗ 没找到 ${WF_DIR}——门禁自身失效（工作流目录改名了？）"
  exit 1
fi

# 抓所有 uses: <owner/repo>@<ref>，跳过本地 action（./...）与 docker:// 镜像。
uses_lines=$(grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[^[:space:]#]+' \
  "$WF_DIR" 2>/dev/null | sed -E 's/^uses:[[:space:]]*//' | sort -u || true)

if [ -z "$uses_lines" ]; then
  echo "✗ 没扫到任何 action pin——门禁自身失效（工作流里没有 uses: ？）"
  exit 1
fi

total=$(printf '%s\n' "$uses_lines" | wc -l | tr -d ' ')
refs=$(grep -rhoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[^[:space:]#]+' \
  "$WF_DIR" 2>/dev/null | wc -l | tr -d ' ')
echo "→ 扫到 ${refs} 处 action 引用，去重后 ${total} 个 pin（${WF_DIR}）"

fail=0

# ── 断言一：每个 pin 必须是 40 位小写 hex ───────────────────────────────
# 仓内规矩是「钉 commit SHA 不用 tag」（tag 可被移动，SHA 不可）。
bad_format=$(printf '%s\n' "$uses_lines" | grep -vE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$' || true)
if [ -n "$bad_format" ]; then
  echo "✗ 以下 pin 不是 40 位小写 hex commit（仓内统一钉 SHA，不用 tag/短 SHA）:"
  printf '%s\n' "$bad_format" | sed 's/^/    /'
  fail=1
fi

# ── 断言二：同一个 action 在本仓内不得出现互相矛盾的 pin ───────────────
# 本仓惯例：所有 checkout 钉同一个版本 ⇒ 允许「刻意升级」但不允许
# 「手滑打错一位」（那正是 2026-10-23 的事故形态）。
conflict=$(printf '%s\n' "$uses_lines" |
  awk -F@ '{print $1}' | sort | uniq -c | awk '$1 > 1 {print $2}' | while read -r action; do
    [ -z "$action" ] && continue
    shas=$(printf '%s\n' "$uses_lines" | grep "^${action}@" | cut -d@ -f2 | sort -u | tr '\n' ' ')
    n=$(printf '%s\n' "$shas" | wc -w | tr -d ' ')
    if [ "$n" -gt 1 ]; then
      echo "    $action → $shas"
    fi
  done)
if [ -n "$conflict" ]; then
  echo "✗ 同一个 action 钉了互相矛盾的 SHA（打错一位的典型形态）:"
  printf '%s\n' "$conflict"
  fail=1
fi

# ── 断言三（--remote）：每个 pin 必须真是 GitHub 上的 commit ─────────────
# 只有「一致且格式对」挡不住「全仓一致地打错」；这一步用 API 兜底。
if [ "$REMOTE" -eq 1 ]; then
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ]; then
    echo "✗ --remote 需要 token（设 GH_TOKEN 或 GITHUB_TOKEN）——不做静默降级"
    exit 1
  fi
  bad_remote=0
  # 注意：管道会把 while 放进子 shell ⇒ 变量不外传 ⇒ 用重定向喂输入。
  tmp=$(mktemp)
  printf '%s\n' "$uses_lines" > "$tmp"
  while IFS= read -r pin; do
    [ -z "$pin" ] && continue
    repo="${pin%@*}"
    sha="${pin#*@}"
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/commits/$sha" 2>/dev/null || echo 000)
    case "$code" in
      200) : ;;
      404|422)
        # 422 = SHA 格式合法但 GitHub 查不到该 commit（GitHub 对部分不存在 SHA 的口径）
        echo "✗ ${repo}@${sha} 不是合法 commit（GitHub API ${code}）——pin 打错了？"
        bad_remote=1
        ;;
      *)
        echo "✗ $repo@$sha 校验失败：GitHub API HTTP ${code}（限流或网络）"
        bad_remote=1
        ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [ "$bad_remote" -ne 0 ]; then
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "口径（勿再改错）:"
  echo "  · action 必须钉 40 位小写 hex commit SHA（tag 可被移动，SHA 不可）"
  echo "  · 同一 action 在本仓内只能有一个 SHA；升级时**一处不漏地同步**全部引用"
  echo "  · pin 打错一位 ⇒ GitHub 解析阶段就失败 ⇒ 门禁从未启动（空转）"
  exit 1
fi

if [ "$REMOTE" -eq 1 ]; then
  echo "✓ action pin 全部合法（${refs} 处引用 / ${total} 个 pin，格式+一致性，且已通过 GitHub API 校验）"
else
  echo "✓ action pin 全部合法（${refs} 处引用 / ${total} 个 pin，格式+一致性；未做远端 commit 校验，加 --remote 可开）"
fi

# ── 自证：注入坏 pin ⇒ 本门禁必须变红；注入好 pin ⇒ 必须保持绿 ────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  trap 'rm -rf "$SELF_TMP"' EXIT
  mkdir -p "$SELF_TMP/.github/workflows"

  self_fail=0

  # 基线：合法 pin ⇒ 必须绿
  cat > "$SELF_TMP/.github/workflows/ok.yml" <<'YML'
name: ok
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YML
  if ACTION_PINS_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：合法 pin ⇒ 门禁绿"
  else
    echo "  ✗ 基线：合法 pin 竟然判红 ⇒ 门禁本身坏了" >&2
    self_fail=1
  fi

  # 注入一：pin 用 tag 而非 40 位 SHA ⇒ 必须红（断言一）
  cat > "$SELF_TMP/.github/workflows/bad-format.yml" <<'YML'
name: bad
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YML
  if ACTION_PINS_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「pin 用 tag」后门禁仍绿 ⇒ 断言一无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「pin 用 tag」⇒ 门禁变红（断言一有牙齿）"
  fi
  rm -f "$SELF_TMP/.github/workflows/bad-format.yml"

  # 注入二：同一个 action 钉两个不同 SHA ⇒ 必须红（断言二）
  cat > "$SELF_TMP/.github/workflows/conflict.yml" <<'YML'
name: conflict
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
  b:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3d42e5aac5ba805825da76410c181273ba90b1
YML
  if ACTION_PINS_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「同一 action 钉两个 SHA」后门禁仍绿 ⇒ 断言二无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「同一 action 钉两个 SHA」⇒ 门禁变红（断言二有牙齿）"
  fi
  rm -f "$SELF_TMP/.github/workflows/conflict.yml"

  # 注入三：工作流里一个 uses: 都没有 ⇒ 必须红（「门禁自身失效」守卫）
  # ⚠️ 必须**另起一个空目录**：否则同目录里 ok.yml 的合法 pin 仍会被扫到
  #    ⇒ 扫到 pin ⇒ 判绿 ⇒ 测的不是「空转守卫」而是「正常路径」。
  SELF_TMP2=$(mktemp -d)
  mkdir -p "$SELF_TMP2/.github/workflows"
  cat > "$SELF_TMP2/.github/workflows/empty.yml" <<'YML'
name: empty
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YML
  if ACTION_PINS_ROOT="$SELF_TMP2" bash "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「零个 pin」后门禁仍绿 ⇒ 空转守卫无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「零个 pin」⇒ 门禁变红（空转守卫有牙齿）"
  fi
  rm -rf "$SELF_TMP2"

  # 去掉注入后必须恢复绿（证明上面的红不是「本来就红」）
  if ACTION_PINS_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-action-pins.sh" >/dev/null 2>&1; then
    echo "  ✓ 移除注入后恢复绿"
  else
    echo "  ✗ 移除注入后仍红 ⇒ 门禁有误报" >&2
    self_fail=1
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：注入坏 pin ⇒ 本门禁变红、移除后恢复绿 ⇒ 门禁有牙齿"
fi
