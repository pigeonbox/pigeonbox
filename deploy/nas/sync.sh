#!/usr/bin/env bash
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
set -euo pipefail

TEMPLATE_REF="${PB_NAS_TEMPLATE_REF:-main}" # 模板 ref(列车窗口由调用方覆盖为 train/<v>)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

platforms() { echo "synology ugreen terramaster"; }

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
check_file() { # <说明> <期望内容文件> <实际文件>
    if [ ! -f "$3" ]; then
        echo "  ✗ $1:缺 $3"
        drift=$((drift + 1))
        return
    fi
    if [ ! -s "$3" ]; then
        echo "  ✗ $1:远端无该文件(或为空)"
        drift=$((drift + 1))
        return
    fi
    if diff -u "$2" "$3" > "$TMPDIR_DIFF"; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1:与模板不一致"
        sed -n '1,20p' "$TMPDIR_DIFF"
        drift=$((drift + 1))
    fi
}
TMPDIR_DIFF="$(mktemp)"
TMPDIR_ACTUAL_C="$(mktemp)"; TMPDIR_ACTUAL_E="$(mktemp)"; TMPDIR_ACTUAL_M="$(mktemp)"
trap 'rm -f "$TMPDIR_DIFF" "$TMPDIR_ACTUAL_C" "$TMPDIR_ACTUAL_E" "$TMPDIR_ACTUAL_M"' EXIT

do_platform() { # <action: check|sync> <platform> <repo根>
    local action="$1" platform="$2" root="$3"
    local cpath epath
    cpath="$(compose_path "$platform")"
    epath="$(env_path "$platform")"
    echo "── $platform($root)"

    if [ "$action" = "sync" ]; then
        mkdir -p "$(dirname "$root/$cpath")"
        render_compose "$platform" > "$root/$cpath"
        fetch env.example > "$root/$epath"
        if [ "$platform" = "ugreen" ]; then
            render_compose "$platform" | sed 's|ghcr\.io/|ghcr.nju.edu.cn/|g' > "$root/deploy/compose.ghcr-mirror.yml"
        fi
        echo "  ✓ 已物化 compose/env$( [ "$platform" = "ugreen" ] && echo ' + ghcr 加速版' )"
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

    render_compose "$platform" > "$TMPDIR_DIFF.expect.c"
    cp "$TMPDIR_DIFF.expect.c" "$TMPDIR_DIFF.expect"
    actual_remote "$root" "$cpath" > "$TMPDIR_ACTUAL_C"
    check_file "compose($cpath)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_C"
    fetch env.example > "$TMPDIR_DIFF.expect.e"
    cp "$TMPDIR_DIFF.expect.e" "$TMPDIR_DIFF.expect"
    actual_remote "$root" "$epath" > "$TMPDIR_ACTUAL_E"
    check_file "env($epath)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_E"
    if [ "$platform" = "ugreen" ]; then
        sed 's|ghcr\.io/|ghcr.nju.edu.cn/|g' "$TMPDIR_DIFF.expect.c" > "$TMPDIR_DIFF.expect.m"
        cp "$TMPDIR_DIFF.expect.m" "$TMPDIR_DIFF.expect"
        actual_remote "$root" "deploy/compose.ghcr-mirror.yml" > "$TMPDIR_ACTUAL_M"
        check_file "compose 加速版(deploy/compose.ghcr-mirror.yml)" "$TMPDIR_DIFF.expect" "$TMPDIR_ACTUAL_M"
    fi
}

main() {
    [ $# -ge 1 ] || { sed -n '2,25p' "$0"; exit 1; }
    local action="$1"
    shift
    case "$action" in
        platforms) platforms; return 0 ;;
        check | sync) ;;
        *)
            echo "未知动作: $action(支持 check|sync|platforms)" >&2
            exit 1
            ;;
    esac

    local platform="" dir="" all=0 root=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --platform)
                platform="$2"
                shift 2
                ;;
            --dir)
                dir="$2"
                shift 2
                ;;
            --all)
                all=1
                shift
                ;;
            --root)
                root="$2"
                shift 2
                ;;
            *)
                echo "未知参数: $1" >&2
                exit 1
                ;;
        esac
    done

    if [ "$all" = "1" ]; then
        root="${root:-$SCRIPT_DIR/../..}"
        local p
        for p in $(platforms); do
            do_platform "$action" "$p" "$root/$p"
        done
    else
        [ -n "$platform" ] && [ -n "$dir" ] || { echo "单仓模式需 --platform 与 --dir" >&2; exit 1; }
        case " $(platforms) " in
            *" $platform "*) ;;
            *) echo "未知平台: $platform" >&2; exit 1 ;;
        esac
        do_platform "$action" "$platform" "$dir"
    fi

    if [ "$action" = "check" ]; then
        if [ "$drift" -eq 0 ]; then
            echo "✓ 共享资产与 hub 模板一致"
        else
            echo "✗ ${drift} 处漂移:在 hub 工作区执行 bash deploy/nas/sync.sh sync --all,或单仓 bash deploy/nas/sync.sh sync --platform <p> --dir <repo>"
            exit 1
        fi
    fi
}

main "$@"
