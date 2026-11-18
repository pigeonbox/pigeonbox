#!/usr/bin/env bash
#
# 门禁：全生态的 shellkit vendor 副本必须与 hub 的真相源**逐字节一致**。
#
# 为什么有这道门禁（2026-11-18 引入 shellkit 时落地）：
#   vendor/shellkit/ 是**上游镜像**（生成物，勿手改），真相源只有一处 = hub 的
#   vendor/shellkit/。生态里有 8 个仓要带这份副本（7 个平台仓 + charts）
#   ⇒ 副本之间必然出现漂移：某个仓忘了同步、或有人顺手改了 vendor 里的文件。
#   漂移的后果不是「不好看」，而是**行为分叉**：同一个 shellkit 版本在两个仓里
#   行为不同 ⇒ 排障时拿到的是不可复现的现场。
#   ⇒ 这道门禁把「全生态同版本」变成可机判的事实。
#
# 判据：
#   ① 每个目标仓的 third_party/shellkit 必须存在（缺失 ⇒ 判红「未引入」）
#   ② 文件清单必须逐字相同（多一个少一个都算漂移）
#   ③ 每个文件的 sha256 必须相同（含 .shellkit-vendor-manifest —— 它是
#      上游的所有权基线，无时间戳，逐字可比）
#
# ⚠️ **为什么消费仓的副本不叫 vendor/**：
#   Go ≥1.14 看到**模块根**下有 vendor/ 目录就默认切 vendor 模式 ⇒ 依赖解析报
#   "inconsistent vendoring"（实测：fnos/openwrt/qnap/p2p 四个 Go 模块仓
#   直接 `go build ./...` 就红）⇒ 副本一律放 third_party/shellkit，
#   与 Go 的 vendor 语义彻底分开。真相源仍在 hub 的 vendor/shellkit
#   （hub 是 go.work 工作区，仓根有 vendor/ 目录**不会**触发 vendor 模式，
#   已在 go1.27 上实测）。
#
# 零覆盖的口径：平台仓**不在位**（单仓检出）⇒ 明确提示后跳过；「在位却没有副本」
#   ⇒ 判红。CI 侧不靠这道门禁兜底：CI 的 job 会**显式断言**各平台仓已检出。
#
# 退出码:
#   0 = 全生态一致（或单仓检出时明确跳过）
#   5 = 有漂移 / 未引入（校验失败，与 shellkit 的 SK_VERIFY 同义）
#   1 = 判据不可用（平台仓在位却扫不到任何目标）
#
# 用法: bash scripts/check-shellkit-vendor.sh [--selfcheck] [--workspace <平台仓所在目录>]
set -uo pipefail

ROOT="${SHELLKIT_VENDOR_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

# 平台仓所在的**工作区根**（可覆盖）。
# 默认 = ROOT 自身：CI 里 hub 检出目录就是工作区根（平台仓被 checkout 进同一目录 = 嵌套布局）。
# 本地在 hub 的 worktree 里跑时，嵌套的平台仓不在 worktree 内 ⇒ 用 --workspace 指到真正的检出目录。
WORKSPACE="${SHELLKIT_VENDOR_WORKSPACE:-$ROOT}"

SELFCHECK=0
# ⚠️ 用 while 而不是 'for arg in "$@"': 后者迭代的是**原始**参数列表，
#    循环体里的 shift 不影响它 ⇒ --workspace 的**值**会被当成下一个参数再判一次
#    ⇒ 直接踩进 '*)' 分支打印用法并退 2。
while [ $# -gt 0 ]; do
  case "$1" in
    --selfcheck)
      SELFCHECK=1
      shift
      ;;
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    *)
      echo "用法: $0 [--selfcheck] [--workspace <平台仓所在目录>]"
      exit 2
      ;;
  esac
done

# 真相源 = hub 自己的 vendor/shellkit（上游 CLI 的原生落点）
TRUTH="$ROOT/vendor/shellkit"

# 消费仓的副本路径：**一律 third_party/shellkit**（理由见文件头）
REPO_VENDOR_PATH="third_party/shellkit"

# 目标仓清单（带 shell 脚本、需要 shellkit 的仓）。
# ⚠️ 与 scripts/vendor-shellkit.sh 的清单必须一致（同一份真相的两种用法）。
TARGET_REPOS="fnos openwrt qnap synology ugreen terramaster p2p charts"

sha256_of() { # <文件> → sha256；两种工具都没有时返回 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# manifest_of <vendor目录> → "相对路径 sha256" 逐行（stdout，LC_ALL=C 排序）
manifest_of() { # <vendor目录>
  local base="$1" f rel
  [ -d "$base" ] || return 1
  (cd "$base" && find . -type f -print) | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#./}"
    printf '%s %s\n' "$rel" "$(sha256_of "$base/$f")"
  done
}

# find_repo <仓名> → 打印仓根路径；找不到返回 1
#
# ⚠️ **探测**而不是推算层数：两种布局都真实存在 ——
#   ① 嵌套：平台仓在 hub 检出目录**内部**（本地 make setup 拉进来的，被 gitignore）
#   ② 兄弟：平台仓与 hub 检出目录**平级**
#   固定推算层数必然在另一种布局下指错（2026-10-31 #221 的实录）。
find_repo() { # <仓名>
  local name="$1" cand base
  for base in "$ROOT" "$WORKSPACE" "$ROOT/.." "$WORKSPACE/.."; do
    cand="$base/$name"
    if [ -d "$cand/.git" ]; then
      (cd "$cand" && pwd -P)
      return 0
    fi
  done
  return 1
}

run_check() { # → 0=一致/跳过 / 5=有漂移 / 1=判据不可用
  local name repo drift=0 checked=0 repo_manifest
  local truth_manifest

  if [ ! -d "$TRUTH" ]; then
    echo "✗ 真相源缺失：$TRUTH" >&2
    echo "  修法: 从 shellkit 检出跑 'shellkit vendor .'（见 docs/specs/2026-11-18-shellkit-adoption-design.md §3）" >&2
    return 5
  fi
  truth_manifest="$(mktemp)"
  if ! manifest_of "$TRUTH" >"$truth_manifest"; then
    rm -f "$truth_manifest"
    echo "✗ 真相源的清单算不出来（缺 sha256 工具？）" >&2
    return 5
  fi

  for name in $TARGET_REPOS; do
    repo="$(find_repo "$name")" || continue
    checked=$((checked + 1))
    if [ ! -d "$repo/$REPO_VENDOR_PATH" ]; then
      drift=$((drift + 1))
      echo "✗ ${name}：未引入 ${REPO_VENDOR_PATH}（${repo}）"
      echo "    修法: bash scripts/vendor-shellkit.sh sync --repo ${name}"
      continue
    fi
    repo_manifest="$(mktemp)"
    manifest_of "$repo/$REPO_VENDOR_PATH" >"$repo_manifest"
    if diff -u "$truth_manifest" "$repo_manifest" >/dev/null 2>&1; then
      echo "✓ ${name}：副本与真相源一致（$(wc -l <"$truth_manifest" | tr -d ' ') 个文件）"
    else
      drift=$((drift + 1))
      echo "✗ ${name}：副本与真相源**不一致**（${repo}/${REPO_VENDOR_PATH}）"
      diff -u "$truth_manifest" "$repo_manifest" | sed -n '1,20p' | sed 's/^/    /'
      echo "    修法: bash scripts/vendor-shellkit.sh sync --repo ${name}"
    fi
    rm -f "$repo_manifest"
  done
  rm -f "$truth_manifest"

  if [ "$checked" -eq 0 ]; then
    # ⚠️ **零覆盖的口径**：平台仓**不在位** ⇒ 本检出是单仓检出，没有可比对的
    #   对象 ⇒ 明确提示后跳过（绿），而不是把「没东西可比」报成红。
    #   「平台仓在位却没有副本」是另一回事（上面已判红「未引入」）。
    #   CI 侧不靠这道门禁兜底：CI 的 job 会**显式断言**各平台仓已检出
    #   （checkout 失败 ⇒ job 直接红，不会走到「跳过」这条路）。
    echo "! 跳过：目标平台仓一个都不在位（本检出是单仓检出，无可比对对象）"
    return 0
  fi
  echo "  （共扫 $checked 个仓；漂移 $drift 个）"
  if [ "$drift" -ne 0 ]; then
    return 5
  fi
  return 0
}

if [ "$SELFCHECK" -eq 0 ]; then
  run_check
  exit $?
fi

# ── 自证：注入漂移 ⇒ 必须变红且点名；一致 ⇒ 绿；零覆盖 ⇒ 明确跳过 ──────────
TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

mkdir -p "$TMP/vendor/shellkit/lib" "$TMP/fnos/.git" "$TMP/fnos/third_party/shellkit/lib"
printf '%s\n' '1.0.0' >"$TMP/vendor/shellkit/VERSION"
printf '%s\n' 'bootstrap' >"$TMP/vendor/shellkit/lib/bootstrap.sh"
printf '%s\n' '1.0.0' >"$TMP/fnos/third_party/shellkit/VERSION"
printf '%s\n' 'bootstrap' >"$TMP/fnos/third_party/shellkit/lib/bootstrap.sh"

if SHELLKIT_VENDOR_ROOT="$TMP" bash "$ROOT/scripts/check-shellkit-vendor.sh" >/dev/null 2>&1; then
  echo "  ✓ 基线：副本一致 ⇒ 门禁绿"
else
  echo "  ✗ 基线：副本一致竟然判红 ⇒ 门禁本身坏了" >&2
  exit 1
fi

printf '%s\n' 'tampered' >"$TMP/fnos/third_party/shellkit/lib/bootstrap.sh"
out="$(SHELLKIT_VENDOR_ROOT="$TMP" bash "$ROOT/scripts/check-shellkit-vendor.sh" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  ✗ 注入「内容漂移」后门禁仍绿 ⇒ 断言无效" >&2
  exit 1
fi
if printf '%s' "$out" | grep -q 'bootstrap.sh'; then
  echo "  ✓ 注入「内容漂移」⇒ 门禁变红并点名 bootstrap.sh（断言有牙齿）"
else
  echo "  ✗ 判红但没点名文件 ⇒ 结论不可用" >&2
  exit 1
fi

rm -f "$TMP/fnos/third_party/shellkit/lib/bootstrap.sh"
if SHELLKIT_VENDOR_ROOT="$TMP" bash "$ROOT/scripts/check-shellkit-vendor.sh" >/dev/null 2>&1; then
  echo "  ✗ 注入「少一个文件」后门禁仍绿 ⇒ 断言无效" >&2
  exit 1
fi
echo "  ✓ 注入「少一个文件」⇒ 门禁变红（断言有牙齿）"

rm -rf "$TMP/fnos/third_party"
if SHELLKIT_VENDOR_ROOT="$TMP" bash "$ROOT/scripts/check-shellkit-vendor.sh" >/dev/null 2>&1; then
  echo "  ✗ 注入「未引入副本」后门禁仍绿 ⇒ 断言无效" >&2
  exit 1
fi
echo "  ✓ 注入「未引入副本」⇒ 门禁变红（断言有牙齿）"

rm -rf "$TMP/fnos"
out0="$(SHELLKIT_VENDOR_ROOT="$TMP" bash "$ROOT/scripts/check-shellkit-vendor.sh" 2>&1)" && rc0=0 || rc0=$?
if [ "$rc0" -ne 0 ]; then
  echo "  ✗ 零覆盖（单仓检出）却判红 ⇒ 口径错了：没有可比对象应当**明确跳过**" >&2
  exit 1
fi
if printf '%s' "$out0" | grep -q '跳过'; then
  echo "  ✓ 零覆盖（单仓检出）⇒ 明确提示跳过（不是静默绿）"
else
  echo "  ✗ 零覆盖时没有给出跳过提示 ⇒ 结论不可用" >&2
  exit 1
fi

echo "✓ 自证：一致⇒绿、内容漂移⇒红点名、少文件⇒红、未引入⇒红、零覆盖⇒明确跳过 ⇒ 门禁有牙齿"
OK=1
