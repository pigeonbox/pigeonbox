#!/bin/bash
# PigeonBox favicon / 品牌图标生成入口（2026-10-26 起为 gen-brand-icons.py 的薄封装）
#
# 历史上这里用 cairosvg 从一份「带 rx=116 圆角背景的矢量 SVG」直接渲染多尺寸 favicon。
# 真相源后来换成「内嵌 512px PNG 的 SVG 包装」，于是两件事同时失效：
#   ① svg.replace(' rx="116"') 匹配不到（SVG 里已无该属性）⇒ apple-touch-icon 的
#      全出血失效，iOS 裁圆角后透明角渲染成黑块；
#   ② 换底色必须改 PNG 里的渐变，矢量渲染帮不上忙。
# ⇒ 统一改走 scripts/gen-brand-icons.py：真相源 = frontend-core/public/favicon.svg，
#    白鸽贴片 = frontend-core/public/pigeon-glyph.png，底色公式与站内 logo 底座一致。
#
# 用法：
#   bash scripts/generate_favicon.sh                 # 只重出派生件（不改底色）
#   bash scripts/generate_favicon.sh --accent 0e9f6e # 换底色并重出全套资产
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/gen-brand-icons.py" "$@"
