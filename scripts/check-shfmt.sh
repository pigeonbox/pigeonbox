#!/usr/bin/env bash
#
# 门禁：仓内全部**在库** shell 脚本必须 shfmt 干净（格式漂移即红）。
#
# 为什么有这道门禁（B2 遗留疑虑 1，Refs pigeonbox/pigeonbox#327）：
#   2026-11-11 B2 实测：改动前全仓脚本就不合 shfmt（smoke-full.sh 一处即 1216 行
#   diff），仓内既有风格是 2 空格/单行 case 的非 shfmt 形态，且**没有任何 shfmt
#   门禁**（CI 只跑 shellcheck）⇒ 格式基线持续漂移、review 里排版噪声淹没逻辑
#   diff。C3 批已做一次纯 shfmt 重排（零行为变化），本门禁防止回潮。
#
# 格式口径（C3 定，全仓统一）：shfmt -i 2 -ci
#   · -i 2：两空格缩进——贴合仓内既有 2 空格风格，把纯格式化的 diff 压到最小；
#   · -ci：case 分支缩进一级（shfmt 标准 switch-case 排版）。
#   shfmt 版本必须钉死（CI 用 go install mvdan.cc/sh/v3/cmd/shfmt@v3.14.1）：
#   不同 minor 的格式化输出可能有差异 ⇒ 浮动版本会让本门禁时红时绿。
#
# 扫描范围：git ls-files 里的 shell 脚本（*.sh 或首行 shebang 指向 sh/bash）。
#   · 「在库」= 本仓自己跟踪的文件；make setup 拉下的模块仓（gitignore 的兄弟
#     目录）各有各的 CI，不在本门禁射程内（否则本地拉齐一排仓就全乱了）。
#   · 扫到 0 个脚本 ⇒ 判红（门禁空转也算失败，与 check-no-bare-go.sh 同口径）。
#
# 用法：bash scripts/check-shfmt.sh [--selfcheck]
set -uo pipefail

# 扫描根目录可覆盖（自证模式要指向临时工作区）
ROOT="${SHFMT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

if ! command -v shfmt >/dev/null 2>&1; then
  echo "✗ 没有 shfmt——门禁自身失效（安装: brew install shfmt，或 go install mvdan.cc/sh/v3/cmd/shfmt@v3.14.1）"
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ $ROOT 不是 git 仓——无法界定「在库」脚本，门禁自身失效"
  exit 1
fi

# 在库 shell 脚本清单：*.sh 或首行 shebang 指向 sh/bash（含 sh/dash/ksh 变体）
collect_files() { # → stdout，每行一个仓内相对路径
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$f" in
      *.sh)
        printf '%s\n' "$f"
        continue
        ;;
    esac
    if head -n1 "$f" | grep -qE '^#![/a-z0-9 _.-]*(ba|da|k)?sh([[:space:]]|$)'; then
      printf '%s\n' "$f"
    fi
  done
}

files=()
while IFS= read -r f; do
  [ -n "$f" ] && files[${#files[@]}]="$f"
done < <(collect_files)

if [ "${#files[@]}" -eq 0 ]; then
  echo "✗ 扫到 0 个在库 shell 脚本——门禁自身失效（git ls-files 结构变了？）"
  exit 1
fi

# ── 判定：shfmt -l 列出格式漂移文件 ────────────────────────────────────────
shfmt_rc=0
drifted=$(shfmt -i 2 -ci -l "${files[@]}" 2>&1) || shfmt_rc=$?

if [ "$shfmt_rc" -ne 0 ]; then
  echo "✗ shfmt 解析失败（脚本语法坏了？）:"
  printf '%s\n' "$drifted" | sed 's/^/    /'
  exit 1
fi

if [ -n "$drifted" ]; then
  echo "✗ 以下文件未 shfmt 干净（修法: shfmt -i 2 -ci -w <文件>）:"
  printf '%s\n' "$drifted" | sed 's/^/    /'
  echo
  echo "  口径: shfmt -i 2 -ci（版本钉 v3.14.1，浮动版本会时红时绿）。"
  echo "  为何要紧: 格式漂移的 diff 会淹没 review 里的逻辑 diff；全仓一次纯格式化"
  echo "  重排（C3）就是为清这笔债，别让它再涨回来。"
  exit 1
fi

echo "✓ shfmt 检查通过（${#files[@]} 个在库 shell 脚本，shfmt -i 2 -ci）"

# ── 自证：注入格式漂移的文件 ⇒ 本门禁必须变红且点名文件 ────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  mkdir -p "$SELF_TMP/scripts"
  git -C "$SELF_TMP" init -q
  self_fail=0

  # 基线：格式干净 ⇒ 必须绿
  printf '#!/usr/bin/env bash\nif true; then\n  echo hi\nfi\n' >"$SELF_TMP/scripts/ok.sh"
  git -C "$SELF_TMP" add .
  if SHFMT_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shfmt.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：shfmt 干净 ⇒ 门禁绿"
  else
    echo "  ✗ 基线：shfmt 干净竟然判红 ⇒ 门禁本身坏了" >&2
    self_fail=1
  fi

  # 注入：4 空格缩进（shfmt -i 2 会挑出来）⇒ 必须红**且点名文件**
  printf '#!/usr/bin/env bash\nif true; then\n    echo hi\nfi\n' >"$SELF_TMP/scripts/bad.sh"
  git -C "$SELF_TMP" add .
  bad_rc=0
  bad_out=$(SHFMT_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shfmt.sh" 2>&1) || bad_rc=$?
  if [ "$bad_rc" -eq 0 ]; then
    echo "  ✗ 注入「格式漂移的文件」后门禁仍绿 ⇒ 断言无效" >&2
    self_fail=1
  elif printf '%s' "$bad_out" | grep -q 'bad.sh'; then
    echo "  ✓ 注入「格式漂移的文件」⇒ 门禁变红并点名 bad.sh（断言有牙齿）"
  else
    echo "  ✗ 判红但没点名文件 ⇒ 结论不可用" >&2
    self_fail=1
  fi

  # 移除注入后恢复绿（证明上面的红不是「本来就红」）
  rm -f "$SELF_TMP/scripts/bad.sh"
  if SHFMT_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shfmt.sh" >/dev/null 2>&1; then
    echo "  ✓ 移除注入后恢复绿"
  else
    echo "  ✗ 移除注入后仍红 ⇒ 门禁有误报" >&2
    self_fail=1
  fi

  # 空转守卫：一个在库 shell 脚本都没有 ⇒ 必须红（「没扫到」≠「扫过且通过」）
  rm -f "$SELF_TMP/scripts/ok.sh"
  if SHFMT_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-shfmt.sh" >/dev/null 2>&1; then
    echo "  ✗ 零覆盖时门禁仍绿 ⇒ 空转守卫无效" >&2
    self_fail=1
  else
    echo "  ✓ 零覆盖 ⇒ 门禁变红（空转守卫有牙齿）"
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：干净⇒绿、格式漂移⇒红点名、还原⇒绿、零覆盖⇒红 ⇒ 门禁有牙齿"
fi
OK=1
