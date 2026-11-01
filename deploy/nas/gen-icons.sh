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
SRC="${1:?用法: gen-icons.sh <favicon.svg|--fetch> <输出目录>}"
OUT="${2:?缺少输出目录}"
TMP="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

if [ "$SRC" = "--fetch" ]; then
    SRC="$TMP/favicon.svg"
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/pigeonbox/frontend/main/public/favicon.svg" -o "$SRC"
fi
if ! command -v qlmanage >/dev/null || ! command -v sips >/dev/null; then
    echo "需要 macOS 的 qlmanage 与 sips(无跨平台渲染依赖,刻意不引 ImageMagick)" >&2
    exit 1
fi

qlmanage -t -s 256 -o "$TMP" "$SRC" >/dev/null
mv "$TMP/favicon.svg.png" "$TMP/icon-256.png"
sips -z 64 64 "$TMP/icon-256.png" --out "$TMP/icon-64.png" >/dev/null
sips -z 80 80 "$TMP/icon-256.png" --out "$TMP/icon-80.png" >/dev/null
sips -s format gif "$TMP/icon-256.png" --out "$TMP/qpkg_icon.gif" >/dev/null
sips -s format gif "$TMP/icon-80.png" --out "$TMP/qpkg_icon_80.gif" >/dev/null
cp "$TMP/qpkg_icon.gif" "$TMP/qpkg_icon_gray.gif"   # 置灰档:QTS 禁用态渲染,直接用同图

mkdir -p "$OUT"
cp "$TMP/icon-256.png" "$OUT/PACKAGE_ICON_256.PNG"
cp "$TMP/icon-64.png" "$OUT/PACKAGE_ICON.PNG"
cp "$TMP"/qpkg_icon*.gif "$OUT/"
echo "✓ 图标已生成 → $OUT(请手动放置到各仓对应位置: synology/spk/ 与 qnap/qpkg/icons/)"
OK=1
