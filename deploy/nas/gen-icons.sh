#!/usr/bin/env bash
# NAS 打包四仓品牌图标生成器(从 frontend 品牌图标派生各平台包图标)。
# 图标极少变动;本脚本主要作为再生成依据存档(macOS 专用:sips/qlmanage)。
#
# 产物:
#   PACKAGE_ICON_256.PNG   群晖 SPK PACKAGE_ICON_256.PNG / 绿联 UPK icon.png
#   PACKAGE_ICON.PNG       群晖 SPK 64x64(DSM7 规范)
#   qpkg_icon.gif/_80/_gray  威联通 QPKG 三档
#
# 用法: gen-icons.sh <frontend.svg 路径|--fetch> <输出目录>
set -euo pipefail

# ── shellkit（打包侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SK_BOOTSTRAP="$HUB_ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=../../vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

SRC="${1:?用法: gen-icons.sh <favicon.svg|--fetch> <输出目录>}"
OUT="${2:?缺少输出目录}"
TMP="$(mktemp -d)"
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原手写 trap 等价。
# ⚠️ 原手写 trap 的「成功哨兵」（OK≠1 ⇒ 没跑到结尾 ⇒ 判失败）：本脚本只有一条
#    成功路径（末尾一句成功日志后自然结束），失败出口都是显式非零 ⇒ 哨兵拆掉后
#    行为等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -rf "${TMP}"'
trap_install

if [ "$SRC" = "--fetch" ]; then
  SRC="$TMP/favicon.svg"
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/pigeonbox/frontend/main/public/favicon.svg" -o "$SRC"
fi
if ! command -v qlmanage >/dev/null || ! command -v sips >/dev/null; then
  log_error "需要 macOS 的 qlmanage 与 sips(无跨平台渲染依赖,刻意不引 ImageMagick)"
  exit 1
fi

qlmanage -t -s 256 -o "$TMP" "$SRC" >/dev/null
mv "$TMP/favicon.svg.png" "$TMP/icon-256.png"
sips -z 64 64 "$TMP/icon-256.png" --out "$TMP/icon-64.png" >/dev/null
sips -z 80 80 "$TMP/icon-256.png" --out "$TMP/icon-80.png" >/dev/null
sips -s format gif "$TMP/icon-256.png" --out "$TMP/qpkg_icon.gif" >/dev/null
sips -s format gif "$TMP/icon-80.png" --out "$TMP/qpkg_icon_80.gif" >/dev/null
cp "$TMP/qpkg_icon.gif" "$TMP/qpkg_icon_gray.gif" # 置灰档:QTS 禁用态渲染,直接用同图

mkdir -p "$OUT"
cp "$TMP/icon-256.png" "$OUT/PACKAGE_ICON_256.PNG"
cp "$TMP/icon-64.png" "$OUT/PACKAGE_ICON.PNG"
cp "$TMP"/qpkg_icon*.gif "$OUT/"
log_ok "图标已生成 → $OUT(请手动放置到各仓对应位置: synology/spk/ 与 qnap/qpkg/icons/)"
