# 品牌色与图标（brand）

> 单源：AGENTS.md 重构（2026-11-13，spec 附录 A#15，原 L381-433）。
> **换色/换图标前读**；品牌板历史快照在 hub `docs/brand-sheet-*.png`。

**品牌主色 = 科技蓝 `#1677ff`**（Ant Design 蓝；此前青竹 `#0e9f6e`、靛蓝 `#5e6ad2`
均已降为「主题预设」之一）。管理台主题预设可切 7 色，缺省即科技蓝。
（为什么不是墨黑：全站唯一主色=去色，近黑只适合点睛——实测结论，墨黑保留为预设。）

1. **真相源只有一份**：`PigeonBox/frontend-core/public/favicon.svg`（内嵌 512px PNG 的
   SVG 包装）+ 白鸽贴片 `public/pigeon-glyph.png`（`scripts/gen-pigeon-glyph.py` 生成）。
   ⇒ 镜像必须与真相源**同 sha256**：`docs/brand/logo.svg`、fnos/desktop 的 favicon。
   文档站不持有副本（`docs-site/scripts/sync-brand.mjs` 构建时重生成）。
2. **换色/重出资产走生成器**：`python3 PigeonBox/scripts/gen-brand-icons.py --accent 1677ff`
   （不带参数=只重出派生件）。一次出齐 frontend-core/fnos/desktop/synology/qnap 的
   favicon 套装、桌面 icns/ico、NAS 包图标。`scripts/generate_favicon.sh` 只是薄封装。
3. **底色公式三处同源**：`mix(主色,#fff 6%) → mix(主色,#000 30%)` ——静态图标底色
   （gen 脚本）/ 界面 logo 底座（main.scss）/ 运行时动态图标（utils/favicon.ts）。
   **改公式必须三处同改**（`accentTokens.spec.ts` 机械守卫钉住）。
4. **主题色联动标签图标/iOS 主屏图标**：白鸽贴片 + 按 accent 现算渐变底 → canvas 出
   PNG data URI，管理台保存即热生效；静态 favicon 是烘焙死的，只改 CSS 会
   「界面绛红、标签墨黑」。桌面/NAS 安装图标仍是打包期静态产物。
5. **暗色主色有对比度地板**（`utils/accent.ts` 的 `darkBase`）：固定提亮 30% 对灰阶
   accent 不够（墨黑在 #0a0a0a 底只有 2.2:1）⇒ 不足 4.5:1 继续提亮；
   `theme-init.js` 首帧必须同公式（否则首帧跳色）；暗色主色属浅色系，
   **实底按钮用深字**。
6. **别手算色阶**：JS `Math.round` 与 Python `round` 半值行为不同（66.5 → 67 vs 66）
   ⇒ 手算必漂；用 `vite-node` 跑真实公式打印权威值。改色只改一处 ⇒ 守卫变红。
7. **统计卡徽标是固定语义色板**（紫 #7c3aed / 青绿 #0d9488 / 琥珀 #d97706），
   **不随主色派生**（历史「主色色相偏移」在灰阶/同族主色下会把四色构图搞崩）。
8. **趋势图系列色是固定对比色对**（上传靛蓝/下载青绿），不跟主色；暗色各提亮一档。
9. **apple-touch-icon 必须全出血**（无透明角）：iOS 自裁圆角，透明角渲染成黑块。
10. **品牌板**：`gen-brand-icons.py --brand-sheet <path>` 出多尺寸展示图；
    纸张底色按主色亮度自适应。
