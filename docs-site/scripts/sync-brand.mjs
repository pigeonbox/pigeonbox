// 品牌资源同步（构建前自动跑，predocs:dev / predocs:build 钩子）。
//
// 站点不自持品牌图：真相源是 hub 仓 docs/brand/logo.svg（与应用内
// frontend-core/public/favicon.svg 同一份 sha256 = 同一张线稿信鸽图标）。
// 早前 docs-site/public/logo.svg 存的是旧版实心鸽子图，于是"首页图标与应用
// 图标不一致"——本脚本让站点每次构建都从真相源重新取，杜绝再次漂移。
//
// 产出：
//   public/logo.svg —— hero 大图（VitePress VPImage 直接引用）
//   public/icon.png —— 512×512 PNG（从 logo.svg 内嵌的 base64 PNG 抽出），
//                      供 favicon / apple-touch-icon / og:image 使用
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = resolve(here, '../../docs/brand/logo.svg')
const outDir = resolve(here, '../public')
const outSvg = resolve(outDir, 'logo.svg')
const outPng = resolve(outDir, 'icon.png')

if (!existsSync(src)) {
  // 构建期硬失败：不静默跳过（跳过 = 站点继续用旧图或空图，恰好是本次要根治的问题）
  console.error(`[sync-brand] 找不到品牌真相源：${src}`)
  console.error('[sync-brand] 期望路径：hub 仓 docs/brand/logo.svg（docs-site 的上级目录）')
  process.exit(1)
}

const svg = readFileSync(src, 'utf-8')
mkdirSync(outDir, { recursive: true })
writeFileSync(outSvg, svg)

const m = svg.match(/base64,([A-Za-z0-9+/=]+)/)
if (!m) {
  console.error('[sync-brand] logo.svg 内未找到内嵌 base64 PNG，跳过 icon.png 产出')
} else {
  writeFileSync(outPng, Buffer.from(m[1], 'base64'))
}

console.log(`[sync-brand] 已同步品牌图标：${src} → public/logo.svg, public/icon.png`)
