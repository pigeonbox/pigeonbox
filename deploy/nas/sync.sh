#!/usr/bin/env bash
# shellcheck disable=SC2329  # 本文件的子命令由 cli_cmd 按**字符串名**派发（cli_cmd check "..." "cmd_check"）
#   ⇒ shellcheck 静态看不见这些 cmd_* 函数被调用 ⇒ 会报「函数从未被调用」。
#   ⇒ 逐个函数豁免太碎 ⇒ 在文件头一次性豁免（被点名的函数在仓内确有引用，见提交体逐条计数）。
# NAS 打包三仓共享资产同步器(真相源 = 本目录模板,三仓只是物化结果)。
# (qnap 已切原生 QPKG 进程模式,不再消费 compose/env 模板——2026-10-09)
#
# 覆盖文件(三仓完全同源,平台差异只有 compose 首行说明):
#   compose.yml → 平台头(#[__NAS_PLATFORM_HEADER__] 占位) + 模板本体
#   env.example → 逐字
#   ugreen 另有 compose.ghcr-mirror.yml = compose 的 ghcr.io→ghcr.nju.edu.cn 替换
#
# 用法:
#   sync.sh check  --platform <p> --dir <repo根>   校验单仓(适配器 CI 漂移门禁)
#   sync.sh check  --all [--root <工作区>]          校验三仓(--all 默认兄弟目录)
#   sync.sh sync   --platform <p> --dir <repo根>    物化单仓
#   sync.sh sync   --all [--root <工作区>]
#   sync.sh platforms                               列出支持平台
#
# 模板来源:本地同目录(工作区/hub 检出内) → gh api(实时;ref 可用 PB_NAS_TEMPLATE_REF
# 覆盖,列车 bump PR 窗口传 train/<v>)→ raw CDN 兜底(~5min 缓存,列车窗口内会读旧版)。
#
# ── shellkit 改造（2026-11-18）────────────────────────────────────────────
#   参数解析 ⇒ shellkit 的 CLI 框架（cli_cmd/cli_opt/cli_opts/cli_run）：
#     选项语义、--opt=value 写法、帮助生成、退出码归口都交给库，
#     本文件只留「NAS 资产怎么比对」这一件真事。
#   临时文件清理 ⇒ trap_push/trap_install（库负责保留退出码）。
#   日志 ⇒ log_*/die（stdout 只给数据，日志一律 stderr）。
#   **判定文案逐字保留**（"共享资产与 hub 模板一致" / "远端无该文件" …）：
#     deploy/nas/sync_selftest.sh 与 scripts/check-nas-sync-gate.sh 都按这些
#     文案做断言 ⇒ 改文案 = 改契约。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellkit：库跟着仓走（vendor/shellkit），不依赖本机装没装 shellkit。
#
# ⚠️ **fail-closed**：缺库就退 5（校验失败），**不**静默退回手写实现 ——
#   「看着跑通了、实际换了一套管道」是最贵的失败形态。
SK_BOOTSTRAP="$HUB_ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  echo "        （或从 shellkit 检出跑 'shellkit vendor .'）" >&2
  exit 5
fi
# shellcheck source=vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
# 库内消息走中文（与生态脚本的中文输出一致）；没装 gettext 也有纯 bash 兜底表。
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

# 程序名（CLI 框架生成 usage 时用）
SK_PROG="nas-sync"
export SK_PROG

TEMPLATE_REF="${PB_NAS_TEMPLATE_REF:-main}" # 模板 ref(列车窗口由调用方覆盖为 train/<v>)

platforms() { echo "synology ugreen terramaster"; }

# ── 工作区根探测（2026-10-01）────────────────────────────────────────
# ⚠️ **两种布局都真实存在**，固定推算层数必然在另一种布局下指错：
#   ① **嵌套**：NAS 仓在 hub 检出目录**内部**
#      · 本地 `make setup` 把模块仓拉到 hub 仓内（被 .gitignore）
#      · CI `git clone "$r"` 落在 $GITHUB_WORKSPACE 内 = hub 检出目录内
#   ② **兄弟**：NAS 仓与 hub 检出目录**平级**
# ⇒ 2026-10-31 的 #221 按 ② 把根改成 SCRIPT_DIR/../../.. ⇒ **弄坏了 ①**
#   ⇒ 4.6.6 终验在 CI 里报「7 处漂移」（NAS 仓全找不到 ⇒ actual_remote 取空）
#   ⇒ 而当时的 selftest 只搭了 ② ⇒ **门禁自证是假的**，缺陷隔一轮列车才暴露。
# ⇒ 正解：**探测**而非推算——在候选根里挑「其下确有 NAS 仓」的那个。
has_platform_repo() { # <root> → 0=该根下存在 NAS 仓
  local root="$1" p
  for p in $(platforms); do
    if [ -e "$root/$p/.git" ]; then return 0; fi
  done
  return 1
}

workspace_root() { # → stdout(工作区根绝对路径)
  local cand d first=""
  # 顺序＝优先级：嵌套（hub 自身）优先，其次兄弟（hub 的父目录）。
  for cand in "$SCRIPT_DIR/../.." "$SCRIPT_DIR/../../.."; do
    d="$(cd "$cand" 2>/dev/null && pwd)" || continue
    [ -n "$first" ] || first="$d"
    if has_platform_repo "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  # 一个候选都没命中 ⇒ 回落**候选列表的第一个**。
  #   ⚠️ 硬编码回落某一层会把「探测顺序写错」**掩盖**成绿：
  #   变异实测（候选只剩 '../../..'）时，硬编码回落 '../..' 恰好指向 hub 自己
  #   ⇒ 嵌套布局照样绿 ⇒ selftest 判据**没有牙齿**。
  printf '%s\n' "${first:-$SCRIPT_DIR/../..}"
}

compose_path() {
  case "$1" in
    synology) echo "spk/package/compose.yml" ;;
    ugreen) echo "deploy/compose.yml" ;;
    terramaster) echo "deploy/compose.yml" ;;
    *) return 1 ;;
  esac
}
env_path() {
  case "$1" in
    synology) echo "spk/package/env.example" ;;
    ugreen) echo "deploy/env.example" ;;
    terramaster) echo "deploy/env.example" ;;
    *) return 1 ;;
  esac
}
compose_header() {
  case "$1" in
    synology) echo "# PigeonBox 群晖 DSM 部署编排(SPK 内置;.env 在 @appdata/包 var 目录)" ;;
    ugreen) echo "# PigeonBox 绿联 NAS(UGOS Pro)部署编排(Docker → 项目 → 创建 → 粘贴本文件)" ;;
    terramaster) echo "# PigeonBox 铁威马 TOS 部署编排(Docker Manager → 项目 → 添加 → 上传/粘贴本文件)" ;;
    *) return 1 ;;
  esac
}

# fetch() —— <模板文件名> → stdout(本地同目录优先;gh api 实时;raw CDN 兜底)
#
# ⚠️ **保持手写**（不换 net_download）：这里是**三段式**取数
#   （本地文件 → gh api 实时 → raw CDN 兜底），而 net_download 是
#   「主 URL + 镜像回退」两段式 ⇒ 直接换会**丢掉 gh api 这一段**
#   （列车 bump PR 窗口里 raw CDN 还在缓存上一版 ⇒ 假漂移）。
#   重试语义也不同（curl --retry 3 --connect-timeout 15）。
fetch() { # <模板文件名> → stdout(本地同目录优先;gh api 实时;raw CDN 兜底)
  if [ -f "$SCRIPT_DIR/$1" ]; then
    cat "$SCRIPT_DIR/$1"
    return
  fi
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    gh api "repos/pigeonbox/pigeonbox/contents/deploy/nas/$1?ref=$TEMPLATE_REF" --jq .content | base64 -d
    return
  fi
  curl -fsSL --retry 3 --connect-timeout 15 \
    "https://raw.githubusercontent.com/pigeonbox/pigeonbox/$TEMPLATE_REF/deploy/nas/$1"
}

# 渲染 compose(平台头替换占位首行)
render_compose() { # <platform> → stdout
  fetch compose.yml | awk -v h="$(compose_header "$1")" 'NR==1 { print h; next } { print }'
}

drift=0
TMPDIR_DIFF="$(mktemp)"
TMPDIR_ACTUAL_C="$(mktemp)"
TMPDIR_ACTUAL_E="$(mktemp)"
TMPDIR_ACTUAL_M="$(mktemp)"
# 清理栈：临时文件随退出回收（库负责保留退出码 ⇒ 失败时也是对的码）
# shellcheck disable=SC2016  # 单引号是**故意的**：$ 必须在求值时（trap 触发 / 生成文件内容）才展开
trap_push 'rm -f "$TMPDIR_DIFF" "$TMPDIR_ACTUAL_C" "$TMPDIR_ACTUAL_E" "$TMPDIR_ACTUAL_M"'
trap_install

check_file() { # <说明> <期望内容文件> <实际文件>
  if [ ! -f "$3" ]; then
    log_error "$1:缺 $3"
    drift=$((drift + 1))
    return
  fi
  if [ ! -s "$3" ]; then
    log_error "$1:远端无该文件(或为空)"
    drift=$((drift + 1))
    return
  fi
  if diff -u "$2" "$3" >"$TMPDIR_DIFF"; then
    log_ok "$1"
  else
    log_error "$1:与模板不一致"
    sed -n '1,20p' "$TMPDIR_DIFF"
    drift=$((drift + 1))
  fi
}

do_platform() { # <action: check|sync> <platform> <repo根>
  local action="$1" platform="$2" root="$3"
  local cpath epath
  cpath="$(compose_path "$platform")"
  epath="$(env_path "$platform")"
  log_section "$platform($root)"

  if [ "$action" = "sync" ]; then
    mkdir -p "$(dirname "$root/$cpath")"
    render_compose "$platform" >"$root/$cpath"
    fetch env.example >"$root/$epath"
    if [ "$platform" = "ugreen" ]; then
      render_compose "$platform" | sed 's|ghcr\.io/|ghcr.nju.edu.cn/|g' >"$root/deploy/compose.ghcr-mirror.yml"
    fi
    log_ok "已物化 compose/env$([ "$platform" = "ugreen" ] && echo ' + ghcr 加速版')"
    return
  fi

  # check 模式的"实际"取自**远端**，但取**哪个远端分支**很关键（2026-10-24 修）。
  #
  # 此前写死取 origin/<仓默认分支>(main)：那在「本地检出落后 origin/main」时是对的
  # （避免陈旧工作树误报），但**列车窗口必假漂移**——
  #   CI 的 push 事件检出的是**列车分支**(train/<v>)，内容已是**本车**新版本；
  #   而 origin/main 还是**上一车**版本 ⇒ 拿新内容比旧版本 ⇒ 必然报「与模板不一致」
  #   ⇒ 阻断 auto-merge ⇒ **整条列车卡在 draft**（2026-10-24 实录：3.3.15 的
  #   ugreen/terramaster/synology 三个物化 PR 全部假红，advance 干等）。
  #   此前"有时绿有时红"纯属**运气**：取决于 hub 同列车分支是否已推、raw CDN
  #   5min 缓存里是哪个版本 —— 不可复现、不可靠。
  #
  # 现在的规则（两侧统一为远端）：
  #   · 检出是**分支** ⇒ 取 origin/<当前分支>（本地落后时更准；CI 列车分支检出时
  #     取到本车新版本 ⇒ 假漂移消失）；该远端分支不存在 ⇒ 退回工作树。
  #   · 检出是**游离 HEAD**（CI 的 pull_request 检出 = PR 的 merge 提交）⇒ 用工作树
  #     （工作树就是 PR 内容；此时读 origin/main 会读到上一车 ⇒ 同样差一版）。
  actual_remote() { # <repo根> <相对路径> → 打印"实际"侧内容
    local head_ref
    head_ref="$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [ -n "$head_ref" ]; then
      if git -C "$1" rev-parse -q --verify "origin/$head_ref" >/dev/null 2>&1; then
        git -C "$1" show "origin/$head_ref:$2" 2>/dev/null && return 0
      fi
    fi
    cat "$1/$2" 2>/dev/null || true
  }
  # fetch 当前检出分支的远端版本（游离 HEAD 无分支可取 ⇒ 跳过）。
  BR="$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [ -n "$BR" ]; then
    git -C "$root" fetch -q origin "$BR" 2>/dev/null || true
  fi

  render_compose "$platform" >"$TMPDIR_DIFF.expect.c"
  cp "$TMPDIR_DIFF.expect.c" "$TMPDIR_DIFF.expect"
  actual_remote "$root" "$cpath" >"$TMPDIR_ACTUAL_C"
  check_file "compose($cpath)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_C"
  fetch env.example >"$TMPDIR_DIFF.expect.e"
  cp "$TMPDIR_DIFF.expect.e" "$TMPDIR_DIFF.expect"
  actual_remote "$root" "$epath" >"$TMPDIR_ACTUAL_E"
  check_file "env($epath)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_E"
  if [ "$platform" = "ugreen" ]; then
    sed 's|ghcr\.io/|ghcr.nju.edu.cn/|g' "$TMPDIR_DIFF.expect.c" >"$TMPDIR_DIFF.expect.m"
    cp "$TMPDIR_DIFF.expect.m" "$TMPDIR_DIFF.expect"
    actual_remote "$root" "deploy/compose.ghcr-mirror.yml" >"$TMPDIR_ACTUAL_M"
    check_file "compose 加速版(deploy/compose.ghcr-mirror.yml)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_M"
  fi
}

# run_action <action> <platform> <dir> <all> <root> —— check|sync 的共同主体
run_action() {
  local action="$1" platform="$2" dir="$3" all="$4" root="$5"
  local p

  if [ "$all" = "1" ]; then
    # ⚠️ **工作区根必须「探测」而不是「推算层数」**（2026-10-01 实录修）：
    #   两种布局都真实存在：
    #     ① **嵌套**——NAS 仓在 hub 检出目录**内部**：本地 `make setup` 把模块仓拉到
    #        hub 仓内（被 gitignore）；CI `git clone "$r"` 落在 $GITHUB_WORKSPACE 内
    #     ② **兄弟**——NAS 仓与 hub 检出目录平级。
    #   2026-10-31 #221 按 ② 把根改成 SCRIPT_DIR/../../.. ⇒ **弄坏了 ①**
    #   ⇒ 4.6.6 终验在 CI 里报「7 处漂移」；而当时的 selftest 只搭了 ②
    #   ⇒ **门禁自证是假的**，缺陷隔一轮列车才暴露。
    #
    #   优先级：--root 显式 > PB_NAS_WORKSPACE_ROOT 环境 > 探测。
    if [ -n "$root" ]; then
      root="$(cd "$root" && pwd)"
    elif [ -n "${PB_NAS_WORKSPACE_ROOT:-}" ]; then
      root="$(cd "$PB_NAS_WORKSPACE_ROOT" && pwd)"
    else
      root="$(workspace_root)"
    fi
    for p in $(platforms); do
      do_platform "$action" "$p" "$root/$p"
    done
  else
    [ -n "$platform" ] && [ -n "$dir" ] || {
      log_error "单仓模式需 --platform 与 --dir"
      return 1
    }
    case " $(platforms) " in
      *" $platform "*) ;;
      *)
        log_error "未知平台: $platform"
        return 1
        ;;
    esac
    do_platform "$action" "$platform" "$dir"
  fi

  if [ "$action" = "check" ]; then
    if [ "$drift" -eq 0 ]; then
      log_ok "共享资产与 hub 模板一致"
      return 0
    fi
    log_error "${drift} 处漂移:在 hub 工作区执行 bash deploy/nas/sync.sh sync --all,或单仓 bash deploy/nas/sync.sh sync --platform <p> --dir <repo>"
    return 1
  fi
  return 0
}

# ── CLI 框架：三个子命令 ──────────────────────────────────────────────
# ⚠️ 退出码沿用**本脚本历史口径**：用法错 = 1（不是 shellkit 的 2）——
#   调用方（make nas-check / CI / selftest）都只看非零，不区分 1 与 2；
#   但对外契约不因引入库而改变 ⇒ 在入口把 2 映射回 1。
# ⚠️ cli_opt 的签名是 **VAR LONG [SHORT] [TAKES_ARG]** —— 第三个位置是**短选项**，
#    不是「要不要吃值」⇒ 吃值的选项要写成 cli_opt VAR --long "" 1
#    （写成 cli_opt VAR --long 1 会被当成「短选项是 1」而报错）。
cmd_check() {
  local platform="" dir="" all=0 root=""
  cli_opt_init
  cli_opt platform --platform "" 1
  cli_opt dir --dir "" 1
  cli_opt all --all
  cli_opt root --root "" 1
  cli_opts "$@" || return $?
  run_action check "$platform" "$dir" "$all" "$root"
}

cmd_sync() {
  local platform="" dir="" all=0 root=""
  cli_opt_init
  cli_opt platform --platform "" 1
  cli_opt dir --dir "" 1
  cli_opt all --all
  cli_opt root --root "" 1
  cli_opts "$@" || return $?
  run_action sync "$platform" "$dir" "$all" "$root"
}

cmd_platforms() {
  platforms
  return 0
}

cli_group "NAS 打包资产"
cli_cmd check "校验三仓共享资产是否与 hub 模板一致" "check [--platform <p> --dir <仓根> | --all [--root <工作区根>]]"
cli_cmd sync "把 hub 模板物化到 NAS 打包三仓" "sync [--platform <p> --dir <仓根> | --all [--root <工作区根>]]"
cli_cmd platforms "列出支持平台" "platforms"

cli_run "$@"
rc=$?
# 用法错（shellkit 的 2）→ 沿用本脚本历史口径 1
if [ "$rc" -eq 2 ]; then
  rc=1
fi
exit "$rc"
