#!/usr/bin/env python3
"""PigeonBox 品牌图标：换底色 + 全套派生资产重出（可复跑）。

真相源（两份必须同 sha256）：
  frontend-core/public/favicon.svg  —— 内嵌 512px PNG 的 SVG 包装（应用图标真相源）
  docs/brand/logo.svg               —— 同一份（文档站/README 引用）
白鸽贴片：
  frontend-core/public/pigeon-glyph.png —— 透明底纯白信鸽+信封，由
  frontend-core/scripts/gen-pigeon-glyph.py 从真相源解混生成（几何与真相源像素对位）

底色公式与站内运行时底座一致（frontend-core/src/styles/main.scss 的 .logo-icon/.logo）：
  linear-gradient(180deg, mix(accent, #fff 6%) 0%, mix(accent, #000 30%) 100%)
⇒ 同一 accent 下，静态图标底色与界面里的 logo 底座是同一套色，不漂移。
⚠️ 同一公式还有第三个消费方：运行时动态图标（frontend-core/src/utils/favicon.ts 的
   accentGradient）——管理台改主题色时浏览器标签图标/iOS 主屏图标跟着换色。
   改公式必须三处同改：TS 侧 accentGradient / SCSS 侧 .logo-icon / 本脚本 compose()。

派生件清单（全部由真相源 512px 直出，不经位图重采样链）：
  frontend-core/public/  favicon-16x16/32x32/48.png  favicon.ico  apple-touch-icon.png
  fnos/fnos/app/www/     同上（fnOS 包内静态目录）
  fnos/fnos/app/ui/images/icon_64.png icon_256.png
  desktop/src-tauri/icons/ icon.png(512) 128x128.png 128x128@2x.png(256) 32x32.png
                           icon.ico icon.icns apple-touch-icon.png(180)
  synology/spk/           PACKAGE_ICON.PNG(64) PACKAGE_ICON_256.PNG(256)
  qnap/qpkg/icons/        PigeonBox.gif(256) PigeonBox_80.gif(80) PigeonBox_gray.gif(256)

apple-touch-icon 全出血（无透明角）：iOS 自己裁圆角，透明角会渲染成黑块
（历史上的 generate_favicon.sh 用 svg.replace(' rx="116"') 做全出血，真相源换成
"内嵌 PNG 包装"后该替换已失配 ⇒ 透明角一直漏到产物里，本脚本一并修掉）。

用法：
  python3 scripts/gen-brand-icons.py --accent 0e9f6e   # 换底色并重出全套资产
  python3 scripts/gen-brand-icons.py                    # 只重出派生件（不改真相源底色）
"""
from __future__ import annotations

import argparse
import base64
import io
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent          # hub 仓根
WORKSPACE = ROOT.parent                                  # 多仓工作区根
FRONTEND_CORE = ROOT / "frontend-core"
DESKTOP = WORKSPACE / "desktop"

TRUTH_SVG = FRONTEND_CORE / "public" / "favicon.svg"
BRAND_SVG = ROOT / "docs" / "brand" / "logo.svg"
GLYPH_PNG = FRONTEND_CORE / "public" / "pigeon-glyph.png"

WHITE = (255, 255, 255)
BLACK = (0, 0, 0)


def parse_hex(raw: str) -> tuple[int, int, int]:
    h = raw.strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    if not re.fullmatch(r"[0-9a-fA-F]{6}", h):
        sys.exit(f"✗ 非法 accent：{raw}（须为 #RRGGBB）")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def mix(c: tuple[int, int, int], t: tuple[int, int, int], ratio: float):
    return tuple(round(c[i] + (t[i] - c[i]) * ratio) for i in range(3))  # type: ignore[return-value]


def load_truth_png() -> Image.Image:
    m = re.search(r"base64,([A-Za-z0-9+/=]+)", TRUTH_SVG.read_text())
    if not m:
        sys.exit(f"✗ {TRUTH_SVG} 内未找到内嵌 PNG")
    return Image.open(io.BytesIO(base64.b64decode(m.group(1)))).convert("RGBA")


def write_svg(path: Path, png: Image.Image) -> None:
    """按真相源原有文本结构回写（3 行：svg 头 / image 元素 / 闭合）。"""
    buf = io.BytesIO()
    png.save(buf, format="PNG", optimize=True)
    b64 = base64.b64encode(buf.getvalue()).decode()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"'
        ' viewBox="0 0 512 512">\n'
        f'  <image width="512" height="512" xlink:href="data:image/png;base64,{b64}"/>\n'
        '</svg>'
    )


def sync_mirrors(src_svg: Path) -> None:
    """把真相源 SVG 逐字节同步到各镜像位置（镜像必须与真相源同 sha256）。"""
    mirrors = (
        BRAND_SVG,                                              # hub 文档/README 引用
        ROOT / "fnos" / "fnos" / "app" / "www" / "favicon.svg",  # fnOS 包内静态目录
        WORKSPACE / "desktop" / "ui" / "favicon.svg",            # 桌面端设置页页头
    )
    for dst in mirrors:
        if dst.parent.exists() and dst.resolve() != src_svg.resolve():
            shutil.copyfile(src_svg, dst)


def compose(accent: tuple[int, int, int], glyph: Image.Image, shape: Image.Image | None) -> Image.Image:
    """渐变底 × 可选圆角遮罩 + 白鸽贴片。

    shape=None ⇒ 全出血（apple-touch-icon 用，iOS 自行裁圆角）。
    """
    size = glyph.size
    top = mix(accent, WHITE, 0.06)
    bot = mix(accent, BLACK, 0.30)
    bg = Image.new("RGBA", size)
    bp = bg.load()
    for y in range(size[1]):
        t = y / (size[1] - 1)
        c = mix(top, bot, t)
        for x in range(size[0]):
            bp[x, y] = (*c, 255)
    if shape is not None:
        bg.putalpha(shape)
    return Image.alpha_composite(bg, glyph)


def write_brand_sheet(path: Path, master: Image.Image, glyph: Image.Image,
                      accent: tuple[int, int, int] = (24, 24, 27)) -> None:
    """品牌板：排一版多尺寸 logo + 一版灰阶变体（沿用 2026-10-09 品牌板版式）。

    灰阶变体 = 同一白鸽贴片 + 中性灰渐变底（禁用态/浅底场景示意）。
    纸张底色按主色亮度自适应：近黑主色（墨黑）用浅底，否则深底上的近黑图标
    几乎看不见（2026-10-26 换墨黑后实测）。
    """
    def lum(c: tuple[int, int, int]) -> float:
        f = lambda v: (v / 255) / 12.92 if v / 255 <= 0.03928 else (((v / 255) + 0.055) / 1.055) ** 2.4
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])

    dark_sheet = lum(accent) >= 0.25
    W, H = 1180, 640
    canvas = Image.new("RGBA", (W, H), (18, 30, 43, 255) if dark_sheet else (242, 243, 245, 255))

    gray_accent = (107, 107, 110)
    gray = compose(gray_accent, glyph, master.getchannel("A"))

    def place(im: Image.Image, size: int, xy: tuple[int, int]) -> None:
        canvas.alpha_composite(im.resize((size, size), Image.LANCZOS), xy)

    place(master, 512, (85, 62))
    place(master, 256, (640, 45))
    place(master, 128, (700, 310))
    place(master, 64, (740, 440))
    place(gray, 256, (855, 45))
    place(gray, 128, (920, 310))
    place(gray, 64, (975, 440))

    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(path, optimize=True)


def write_ico(path: Path, images: list[Image.Image]) -> None:
    """PNG 压缩条目的 ICO（Vista+ 全支持），每档由矢量/真相源直出。"""
    blobs = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG", optimize=True)
        blobs.append(buf.getvalue())
    ico = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    for im, b in zip(images, blobs):
        w, h = im.size
        ico += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(b), offset)
        offset += len(b)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(ico + b"".join(blobs))


def write_icns(path: Path, master: Image.Image) -> None:
    """iconutil（macOS）从 iconset 出 icns；缺 iconutil 时跳过并告警。"""
    if not shutil.which("iconutil"):
        print("  ! 缺 iconutil，跳过 icon.icns")
        return
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "icon.iconset"
        iconset.mkdir()
        base = master.convert("RGBA")
        # iconutil 只认这 10 个文件名（@2x 的像素宽高为本体 ×2），多一个少一个都报错
        for px in (16, 32, 128, 256, 512):
            base.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{px}x{px}.png")
            base.resize((px * 2, px * 2), Image.LANCZOS).save(iconset / f"icon_{px}x{px}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(path)], check=True)


def to_gif(src: Path, dst: Path) -> None:
    """GIF 导出：优先 sips（保留透明角，与历史产物同链路）。"""
    if shutil.which("sips"):
        subprocess.run(["sips", "-s", "format", "gif", str(src), "--out", str(dst)],
                       check=True, stdout=subprocess.DEVNULL)
        return
    Image.open(src).convert("RGBA").convert("P", palette=Image.ADAPTIVE, colors=255).save(dst)


def main() -> None:
    ap = argparse.ArgumentParser(description="PigeonBox 品牌图标换色与派生")
    ap.add_argument("--accent", default=None,
                    help="品牌主色（#RRGGBB）；缺省则只重出派生件，不改真相源底色")
    ap.add_argument("--derive-only", action="store_true", help="只重出派生件，不改真相源底色")
    ap.add_argument("--brand-sheet", default=None,
                    help="另出一张品牌板 PNG（多尺寸 logo + 灰阶变体），给到路径")
    args = ap.parse_args()

    # 换色必须显式给 --accent：否则默认只派生，避免误把改过底的真相源刷回默认色
    derive_only = args.derive_only or args.accent is None

    if not TRUTH_SVG.exists():
        sys.exit(f"✗ 找不到真相源 {TRUTH_SVG}")
    if not GLYPH_PNG.exists():
        sys.exit(f"✗ 找不到白鸽贴片 {GLYPH_PNG}（先跑 frontend-core/scripts/gen-pigeon-glyph.py）")

    accent = parse_hex(args.accent) if args.accent else parse_hex("#0e9f6e")  # 缺省=品牌默认青竹
    master = load_truth_png()
    glyph = Image.open(GLYPH_PNG).convert("RGBA")
    if master.size != glyph.size:
        sys.exit(f"✗ 真相源 {master.size} 与贴片 {glyph.size} 尺寸不一致，几何假设失效")

    if not derive_only:
        shape = master.getchannel("A")            # 圆角方形遮罩（真相源 alpha）
        new_master = compose(accent, glyph, shape)
        write_svg(TRUTH_SVG, new_master)
        master = new_master
        print(f"✓ 真相源已换底色 → #{args.accent.lstrip('#')}")
    sync_mirrors(TRUTH_SVG)

    # ---- 派生件 ----
    plain = master                                   # 圆角（透明角）
    bleed = _bleed_from(master, glyph) if derive_only else compose(accent, glyph, None)

    def png(im: Image.Image, size: int) -> Image.Image:
        return im.resize((size, size), Image.LANCZOS)

    # frontend-core/public + fnos/www：同一套 favicon 产物
    for pub in (FRONTEND_CORE / "public", ROOT / "fnos" / "fnos" / "app" / "www"):
        if not pub.exists():
            continue
        png(plain, 16).save(pub / "favicon-16x16.png", optimize=True)
        png(plain, 32).save(pub / "favicon-32x32.png", optimize=True)
        png(plain, 48).save(pub / "favicon-48.png", optimize=True)
        png(bleed, 180).save(pub / "apple-touch-icon.png", optimize=True)
        write_ico(pub / "favicon.ico", [png(plain, 16), png(plain, 32), png(plain, 48)])

    # fnOS 包图标
    ui_img = ROOT / "fnos" / "fnos" / "app" / "ui" / "images"
    if ui_img.exists():
        png(plain, 64).save(ui_img / "icon_64.png", optimize=True)
        png(plain, 256).save(ui_img / "icon_256.png", optimize=True)

    # 桌面端（Tauri）
    if DESKTOP.exists():
        icons = DESKTOP / "src-tauri" / "icons"
        if icons.exists():
            plain.save(icons / "icon.png", optimize=True)
            png(plain, 128).save(icons / "128x128.png", optimize=True)
            png(plain, 256).save(icons / "128x128@2x.png", optimize=True)
            png(plain, 32).save(icons / "32x32.png", optimize=True)
            png(bleed, 180).save(icons / "apple-touch-icon.png", optimize=True)
            write_ico(icons / "icon.ico", [png(plain, s) for s in (16, 24, 32, 48, 64, 128, 256)])
            write_icns(icons / "icon.icns", plain)

    # 群晖 SPK
    spk = ROOT / "synology" / "spk"
    if spk.exists():
        png(plain, 64).save(spk / "PACKAGE_ICON.PNG", optimize=True)
        png(plain, 256).save(spk / "PACKAGE_ICON_256.PNG", optimize=True)

    # 威联通 QPKG（GIF）
    qpkg = ROOT / "qnap" / "qpkg" / "icons"
    if qpkg.exists():
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            png(plain, 256).save(tmp / "i256.png", optimize=True)
            png(plain, 80).save(tmp / "i80.png", optimize=True)
            to_gif(tmp / "i256.png", qpkg / "PigeonBox.gif")
            to_gif(tmp / "i80.png", qpkg / "PigeonBox_80.gif")
            shutil.copy(qpkg / "PigeonBox.gif", qpkg / "PigeonBox_gray.gif")  # QTS 禁用态：同图

    print("✓ 派生件已重出（frontend-core / fnos / desktop / synology / qnap）")

    if args.brand_sheet:
        write_brand_sheet(Path(args.brand_sheet).expanduser(), master, glyph, accent)
        print(f"✓ 品牌板已出 → {args.brand_sheet}")


def _bleed_from(master: Image.Image, glyph: Image.Image) -> Image.Image:
    """只派生模式下，由当前真相源还原全出血版（保留其渐变，不重算 accent）。"""
    px = master.load()
    rows = []
    for y in range(master.size[1]):
        vals = [px[x, y] for x in range(master.size[0]) if px[x, y][3] > 250]
        if vals:
            rows.append(tuple(sum(v[i] for v in vals) / len(vals) for i in range(3)))
    top, bot = rows[0], rows[-1]
    bg = Image.new("RGBA", master.size)
    bp = bg.load()
    for y in range(master.size[1]):
        t = y / (master.size[1] - 1)
        c = mix(top, bot, t)  # type: ignore[arg-type]
        for x in range(master.size[0]):
            bp[x, y] = (*c, 255)
    return Image.alpha_composite(bg, glyph)


if __name__ == "__main__":
    main()
