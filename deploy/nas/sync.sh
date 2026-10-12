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
    if diff -u "$2" "$3" > "$TMPDIR_DIFF"; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1:与模板不一致"
        sed -n '1,20p' "$TMPDIR_DIFF"
        drift=$((drift + 1))
    fi
}
TMPDIR_DIFF="$(mktemp)"
trap 'rm -f "$TMPDIR_DIFF"' EXIT

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

    render_compose "$platform" > "$TMPDIR_DIFF.expect.c"
    cp "$TMPDIR_DIFF.expect.c" "$TMPDIR_DIFF.expect"
    check_file "compose($cpath)" "$TMPDIR_DIFF.expect" "$root/$cpath"
    fetch env.example > "$TMPDIR_DIFF.expect.e"
    cp "$TMPDIR_DIFF.expect.e" "$TMPDIR_DIFF.expect"
    check_file "env($epath)" "$TMPDIR_DIFF.expect" "$root/$epath"
    if [ "$platform" = "ugreen" ]; then
        sed 's|ghcr\.io/|ghcr.nju.edu.cn/|g' "$TMPDIR_DIFF.expect.c" > "$TMPDIR_DIFF.expect.m"
        cp "$TMPDIR_DIFF.expect.m" "$TMPDIR_DIFF.expect"
        check_file "compose 加速版(deploy/compose.ghcr-mirror.yml)" "$TMPDIR_DIFF.expect" "$root/deploy/compose.ghcr-mirror.yml"
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
