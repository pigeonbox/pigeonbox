// changelog 页面结构门禁（构建前自动跑，predocs:dev / predocs:build 钩子）。
//
// 为什么需要它：changelog 页的正文是**生成物**（fetch-releases.mjs 从 GitHub
// Release body 渲染而来）。生成逻辑一旦退化，页面会静默变回噪音——
// 实弹：Release body 是自包含快照，同一份「自 3.0.0 起 / 自 4.0.0 起」的破坏性
// 变更清单被内联进每个列车 body，逐字搬运后同一份清单在页面上出现 14 次；
// GitHub 还给重复标题生成 `-1`/`-9` 后缀锚点 ⇒ 除首个副本外全是够不着的幽灵锚点。
//
// 这类退化**不会让构建变红**（VitePress 照常渲染出页面），所以必须机械拦：
//   ① 每个三级标题全文唯一（重复标题 ⇒ 幽灵锚点）
//   ② 每份破坏性变更清单全文只出现一次（去重失效的直接证据）
//   ③ 每张表格的行��数 == 表头列数（抓「代码段内未转义竖线把行拆列」——
//      实弹 trainctl 写 `code===0 || code===200` 未转义 ⇒ 线上该行的
//      「表现」「处理」两列直接丢失，关键指引读不到）
//   ④ 不含 Release 页专属口径（"本页即全生态二进制产物的统一出口"——
//      在文档站里"本页"指错了地方，且逐版重复）
//   ⑤ 不含 Vue 插值 `{{`（VitePress 会当 mustache 编译 ⇒ 整块内容消失）
//   ⑥ 版本流水表：列车号唯一、当前列车矩阵完整
//
// 用法：node scripts/check-changelog.mjs [待检文件]
//       默认检 .vitepress/generated/releases.md；传参用于负对照（故意造坏文件验证它会红）。
import { readFileSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const target = process.argv[2]
  ? resolve(process.cwd(), process.argv[2])
  : resolve(here, '../.vitepress/generated/releases.md')

if (!existsSync(target)) {
  console.error(`[check-changelog] 待检文件不存在：${target}`)
  process.exit(1)
}

const text = readFileSync(target, 'utf-8')
const errors = []

/** 抓取失败时写入的是占位片段（一行提示）——不是结构问题，跳过结构检查。 */
const isPlaceholder = text.trim().startsWith('> ⚠️ 发布说明抓取失败')
if (isPlaceholder) {
  console.log('[check-changelog] 当前是抓取失败占位片段，跳过结构检查')
  process.exit(0)
}

/** 表格行按**未转义**的 `|` 切列。 */
function splitRow(line) {
  const s = line.trim()
  const cells = []
  let cur = ''
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]
    if (ch === '\\' && s[i + 1] === '|') {
      cur += '\\|'
      i++
      continue
    }
    if (ch === '|') {
      cells.push(cur.trim())
      cur = ''
      continue
    }
    cur += ch
  }
  cells.push(cur.trim())
  if (cells[0] === '') cells.shift()
  if (cells.length && cells[cells.length - 1] === '') cells.pop()
  return cells
}

const lines = text.split('\n')

// ── ① 每个三级标题全文唯一 ─────────────────────────────────────
const h3 = lines.filter((l) => l.startsWith('### ')).map((l) => l.slice(4).trim())
const h3Count = new Map()
for (const h of h3) h3Count.set(h, (h3Count.get(h) || 0) + 1)
for (const [h, n] of h3Count) {
  if (n > 1) errors.push(`三级标题重复 ${n} 次：${h}（⇒ 线上会生成 -1/-2 后缀幽灵锚点）`)
}

// ── ② 每份破坏性变更清单全文只出现一次 ───────────────────────────
const invariantBlocks = []
{
  let cur = null
  for (const ln of lines) {
    if (ln.startsWith('### ')) {
      if (cur) invariantBlocks.push(cur)
      cur = { heading: ln.slice(4).trim(), body: [ln] }
    } else if (cur) {
      cur.body.push(ln)
    }
  }
  if (cur) invariantBlocks.push(cur)
}
for (const blk of invariantBlocks) {
  if (!/^⚠️\s*破坏性变更（/.test(blk.heading)) continue
  const blockText = blk.body.join('\n').trim()
  if (!blockText) continue
  // 块正文在全文出现的次数 = 该清单被渲染了几次
  let occurrences = 0
  let idx = text.indexOf(blockText)
  while (idx !== -1) {
    occurrences++
    idx = text.indexOf(blockText, idx + 1)
  }
  if (occurrences > 1) {
    errors.push(`破坏性变更清单被渲染了 ${occurrences} 次（应恰好 1 次）：${blk.heading}`)
  }
}

// ── ③ 表格行列数 == 表头列数 ─────────────────────────────────────
{
  let i = 0
  while (i < lines.length) {
    if (!lines[i].trim().startsWith('|')) {
      i++
      continue
    }
    const header = lines[i]
    const headerCols = splitRow(header).length
    let j = i + 1
    let bad = 0
    let firstBad = ''
    for (; j < lines.length && lines[j].trim().startsWith('|'); j++) {
      const cols = splitRow(lines[j]).length
      if (cols !== headerCols) {
        bad++
        if (!firstBad) firstBad = lines[j]
      }
    }
    if (bad) {
      errors.push(
        `表格列数不一致：表头 ${headerCols} 列，${bad} 行列数不同。` +
          `首行：${firstBad.slice(0, 120)}` +
          `（多半是单元格内容里的竖线未转义，把整行拆成了多列——内容会丢）`,
      )
    }
    i = j
  }
}

// ── ④ 不含 Release 页专属口径 ─────────────────────────────────────
if (text.includes('本页即全生态二进制产物的统一出口')) {
  errors.push('含 Release 页专属口径「本页即全生态二进制产物的统一出口」——在文档站里"本页"指错地方，且逐版重复')
}

// ── ⑤ 不含 Vue 插值 ──────────────────────────────────────────────
if (text.includes('{{')) {
  errors.push('含 `{{`——VitePress 会当 Vue mustache 插值编译 ⇒ 该内容块渲染即消失')
}

// ── ⑥ 三大章节各恰好一次 + 流水表自洽 ────────────────────────────
for (const sec of ['## 当前列车', '## 破坏性变更', '## 版本流水']) {
  const n = lines.filter((l) => l.trim().startsWith(sec)).length
  if (n !== 1) errors.push(`章节「${sec}」出现 ${n} 次（应恰好 1 次）`)
}
{
  const tags = lines
    .map((l) => (l.match(/^\|\s*(v\d+\.\d+\.\d+)\s*\|/) || [])[1])
    .filter(Boolean)
  if (!tags.length) {
    errors.push('版本流水表里没有解析到任何列车行')
  }
  const dup = tags.filter((t, i) => tags.indexOf(t) !== i)
  if (dup.length) {
    errors.push(`版本流水表列车号重复：${[...new Set(dup)].join(', ')}`)
  }
  // 当前列车必须带完整组件矩阵（8+ 行），否则说明矩阵解析失灵
  const matrixRows = lines.filter((l) => /^\|\s*(server \/ frontend|desktop|fnos|openwrt|qnap|p2p|synology|ugreen|terramaster)\s*\|/.test(l.trim()))
  if (matrixRows.length < 8) {
    errors.push(`当前列车的组件矩阵只有 ${matrixRows.length} 行（应 ≥ 8）——矩阵解析可能失灵`)
  }
}

if (errors.length) {
  console.error('[check-changelog] changelog 结构退化：')
  for (const e of errors) console.error(`  - ${e}`)
  process.exit(1)
}

console.log(
  `[check-changelog] 结构门禁通过（${invariantBlocks.filter((b) => /^⚠️/.test(b.heading)).length} 份破坏性变更清单各出现 1 次，无重复标题，无拆列表格）`,
)
