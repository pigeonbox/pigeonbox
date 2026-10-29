// 版本发布说明数据抓取（构建前自动跑，predocs:dev / predocs:build 钩子）。
//
// 真相源 = hub 仓 pigeonbox/pigeonbox 的 **v* Release**（发布列车快照 notes）。
// 仓内 CHANGELOG.md 只记工作区级变更且更新滞后，因此站点发布说明以 Release 为准。
//
// ⚠️ 这里做的是**站点视图渲染**，不是逐字搬运 Release body。
//
// 为什么不能逐字搬：Release body 是「自包含快照」——trainctl/notes.go 按列车号
// 主版本条件渲染，把「自 3.0.0 起」「自 4.0.0 起」这两份**版本不变**的破坏性变更
// 清单内联进**每一个**列车的 body（同一份 6~7 行清单逐字出现 14 次）。
// 逐字搬进页面 = 同一份清单读 14 遍，页面被撑成噪音；GitHub 还会给重复标题生成
// `-1`/`-9`/`-10` 后缀锚点 ⇒ 除第一个副本外全是够不着的幽灵锚点。
//
// 所以站点侧解析 body 并重排为「时间轴视图」：
//   · 版本不变的破坏性变更清单 → **提取一次**，置顶成独立章节
//   · 组件矩阵 → 只给**当前列车**（历史列车全同构，只有版本号在变）
//   · 历史列车 → 压成一张流水表（只留真正在变的：p2p 与底层四件套）
//
// 产出：docs-site/.vitepress/generated/releases.md（markdown 片段）
//   —— 由 changelog.md 用 @include 引入，VitePress 直接渲染成正式文档。
//
// 抓不到不阻断构建：写一个占位片段（页面提示去 GitHub Releases 看），
// 否则 GitHub API 抖一下就会把整站发布卡住。
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const here = dirname(fileURLToPath(import.meta.url))
const outFile = resolve(here, '../.vitepress/generated/releases.md')
const REPO = 'pigeonbox/pigeonbox'
const API = `https://api.github.com/repos/${REPO}/releases?per_page=100`

/**
 * 取 token：CI 用 GITHUB_TOKEN（部署工作流注入 org 的 PB_BOT_TOKEN），
 * 本地回落 gh CLI 登录态。匿名请求共享 IP 很容易撞 60 次/小时的限流（403）。
 */
function resolveToken() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN
  try {
    return execFileSync('gh', ['auth', 'token'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return ''
  }
}

/** 生态列车快照 tag：v<major>.<minor>.<patch>（排除 desktop-v / fnos-v 等组件 tag） */
const isTrainRelease = (tag) => /^v\d+\.\d+\.\d+$/.test(tag)

/** Release body 本身就是 markdown（trainctl 生成），直接注入即可；
 *  只挡掉会二次触发的 include 指令。 */
function mdSafe(text) {
  return text
    .replace(/<!--\s*@include:/g, '<!-- @include&#58;')
    // Vue 插值：VitePress 把 markdown 编译成 Vue 模板，正文里的 `{{` 会被
    // 当成 mustache 表达式 ⇒ 运行时编译报错、整块内容消失。转义成实体保原样显示。
    .replace(/\{\{/g, '&#123;&#123;')
}

/** 表格行按**未转义**的 `|` 切列（`\|` 属于单元格内容，不是分隔符）。 */
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

/**
 * 表格行里，**代码段内部**的 `|` 必须转义，否则会把一行拆成多列。
 *
 * 实弹：trainctl 早期写 `code===0 || code===200`（未转义）⇒ 线上该行被拆成
 * 「表现」/「处理」两列直接丢失，"集成方请继续只认 0" 这条关键指引在页面上
 * 根本读不到（GitHub 渲染同样坏）。已在 trainctl 源头修掉；这里是给**已发布的
 * 历史 body** 兜底。
 */
function escapePipesInCodeSpans(line) {
  let out = ''
  let inCode = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (ch === '`') {
      inCode = !inCode
      out += ch
      continue
    }
    if (ch === '|' && inCode && line[i - 1] !== '\\') {
      out += '\\|'
      continue
    }
    out += ch
  }
  return out
}

/** 表格行内的代码段竖线补转义（非表格行原样返回）。 */
function fixRowPipes(line) {
  if (!line.trim().startsWith('|')) return line
  return escapePipesInCodeSpans(line)
}

/** 把 Release body 拆成「前言块」+「若干 ### 小节」。 */
function splitBody(body) {
  const preamble = []
  const sections = []
  let cur = null
  for (const ln of body.split('\n')) {
    if (ln.startsWith('### ')) {
      cur = { heading: ln.slice(4).trim(), lines: [] }
      sections.push(cur)
    } else if (cur) {
      cur.lines.push(ln)
    } else {
      preamble.push(ln)
    }
  }
  return { preamble, sections }
}

/** 从前言块里摘出组件矩阵（表头 + 数据行）。 */
function parseMatrix(preamble) {
  const start = preamble.findIndex((l) => l.trim().startsWith('|'))
  if (start < 0) return null
  // 表头下一行必须是分隔行（|---|---|）才认这是张表
  const sep = preamble[start + 1] || ''
  if (!/^\s*\|[\s:|-]+\|\s*$/.test(sep)) return null
  const rows = []
  for (let i = start + 2; i < preamble.length; i++) {
    const l = preamble[i]
    if (!l.trim().startsWith('|')) break
    rows.push(fixRowPipes(l))
  }
  return { header: preamble[start], rows }
}

/** 从前言块里摘出「底层: core X · contracts Y · frontend-core Z · chart W」那行。 */
function parseBottom(preamble) {
  const line = preamble.find((l) => l.trim().startsWith('底层:'))
  if (!line) return null
  const libs = {}
  const libPart = line.slice(line.indexOf('底层:') + 3).split('。全部源码仓')[0]
  for (const seg of libPart.split('·')) {
    const m = seg.trim().match(/^([\w.-]+)\s+(v?[\w.+-]+)$/)
    if (m) libs[m[1]] = m[2]
  }
  const repos = (line.split('全部源码仓:')[1] || '').trim().replace(/。$/, '')
  return { libs, repos }
}

/** 「⚠️ 破坏性变更（N.0.0 起）……」= 版本不变清单 ⇒ 提到页首只渲染一次。 */
const isInvariantHeading = (h) => /^⚠️\s*破坏性变更（/.test(h)

/** Release 页专属口径（"本页即……"）——在文档站里"本页"指错了地方，且逐版重复。 */
const RELEASE_PAGE_BOILERPLATE = '本页即全生态二进制产物的统一出口'

/** 列车号比较（vX.Y.Z 语义化）。 */
function compareTags(a, b) {
  const pa = a.replace(/^v/, '').split('.').map(Number)
  const pb = b.replace(/^v/, '').split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0)
  }
  return 0
}

/** 单个 Release body → 结构化数据。 */
function parseRelease(r) {
  const body = mdSafe(r.body || '')
  const { preamble, sections } = splitBody(body)
  const matrix = parseMatrix(preamble)
  const bottom = parseBottom(preamble)

  const invariants = []
  const extras = []
  for (const s of sections) {
    // 小节里的表格行同样要补竖线转义（trainctl 早期写的 `code===0 || code===200`
    // 未转义 ⇒ 整行被拆列，「表现」「处理」两列内容直接丢失）
    const text = [`### ${s.heading}`, ...s.lines.map(fixRowPipes)].join('\n').trim()
    if (isInvariantHeading(s.heading)) {
      invariants.push({ heading: s.heading, text })
    } else {
      extras.push(text)
    }
  }
  // 前言里除「列车引导句 / 组件矩阵 / 底层行」之外的内容 = 该版特有说明
  const extraPreamble = preamble.filter((l) => {
    const t = l.trim()
    if (!t) return false
    if (t.startsWith('**PigeonBox ') && t.includes('生态列车')) return false
    if (t.startsWith('|')) return false
    if (t.startsWith('底层:')) return false
    return true
  })

  return {
    tag: r.tag_name,
    name: r.name || r.tag_name,
    date: (r.published_at || '').slice(0, 10),
    url: r.html_url,
    matrix,
    bottom,
    invariants,
    extras: [...extraPreamble, ...extras].filter((x) => x && x.trim()),
  }
}

/** 组件矩阵行 → [{组件, 版本, 产物}]。 */
function matrixRows(rel) {
  if (!rel.matrix) return []
  return rel.matrix.rows
    .map((l) => splitRow(l))
    .filter((c) => c.length >= 2)
    .map((c) => ({ component: c[0], version: c[1], artifact: c[2] || '' }))
}

/** 流水表「组件差异」列：只列与列车号不一致的组件（其余组件版本号 = 列车号）。 */
function deviations(rel) {
  const tag = rel.tag.replace(/^v/, '')
  const out = []
  for (const row of matrixRows(rel)) {
    const v = row.version.replace(/^v/, '')
    if (v === tag) continue
    if (row.component === 'desktop' && v === `desktop-v${tag}`) continue
    // p2p 行的产物列额外带「NAS 三端随带 <ref>」——那个 ref 才是 NAS 实际带的
    // 版本，可能与 p2p 库版本不同（例：v4.0.6 p2p v0.9.3 但 NAS 随带 v0.9.2），
    // 对 NAS 用户是真信息，不能丢。
    const m = row.artifact.match(/NAS 三端随带\s+(\S+)/)
    out.push(m ? `${row.component} ${row.version}（NAS 随带 ${m[1]}）` : `${row.component} ${row.version}`)
  }
  return out
}

function render(releases) {
  const parsed = releases.map(parseRelease)
  parsed.sort((a, b) => compareTags(b.tag, a.tag) || (a.date < b.date ? 1 : -1))

  const latest = parsed[0]
  const out = []

  out.push('<!-- 本文件由 scripts/fetch-releases.mjs 生成，勿手改；改发布说明请改 Release 内容 -->')
  out.push('')

  // ── 当前列车 ──────────────────────────────────────────────
  if (latest) {
    out.push(`## 当前列车 · ${latest.name} · ${latest.date}`)
    out.push('')
    out.push(`[在 GitHub 上查看该版本 Release ↗](${latest.url})`)
    out.push('')
    if (latest.matrix) {
      out.push(latest.matrix.header)
      out.push('|---|---|---|')
      for (const row of latest.matrix.rows) out.push(row)
      out.push('')
    }
    if (latest.bottom) {
      const libText = Object.entries(latest.bottom.libs)
        .map(([k, v]) => `${k} ${v}`)
        .join(' · ')
      if (libText) out.push(`底层：${libText}`)
      if (latest.bottom.repos) out.push(`全部源码仓：${latest.bottom.repos}`)
      out.push('')
    }
  }

  // ── 破坏性变更（版本不变清单，每份只出现一次）────────────────
  const invariantBlocks = []
  const seen = new Map()
  let dropped = 0
  for (const rel of parsed) {
    for (const inv of rel.invariants) {
      if (seen.has(inv.heading)) {
        dropped++
        continue
      }
      seen.set(inv.heading, { ...inv, since: rel.tag })
      invariantBlocks.push(seen.get(inv.heading))
    }
  }
  out.push('## 破坏性变更')
  out.push('')
  if (invariantBlocks.length) {
    out.push('下列清单按**生效起点**列出：某版本引入后，后续所有版本持续有效——升级到 ≥ 标注版本即适用，与你用哪个补丁版无关。')
    out.push('')
    for (const blk of invariantBlocks) {
      out.push(blk.text)
      out.push('')
    }
  } else {
    out.push('暂无破坏性变更。')
    out.push('')
  }

  // ── 版本流水 ──────────────────────────────────────────────
  out.push('## 版本流水')
  out.push('')
  out.push('| 列车 | 日期 | 组件差异 | 底层（core · contracts · frontend-core · chart） | Release |')
  out.push('|---|---|---|---|---|')
  for (const rel of parsed) {
    const dev = deviations(rel)
    const libs = rel.bottom ? rel.bottom.libs : {}
    const libText = ['core', 'contracts', 'frontend-core', 'chart']
      .map((k) => libs[k])
      .filter(Boolean)
      .join(' · ')
    out.push(
      `| ${rel.tag} | ${rel.date} | ${dev.length ? dev.join('、') : '—'} | ${libText || '—'} | [Release ↗](${rel.url}) |`,
    )
  }
  out.push('')
  out.push('「组件差异」列只列出与列车号不一致的组件；其余组件（server/frontend、desktop、NAS 六平台）版本号即列车号。')
  out.push('')

  // ── 补充说明（个别列车 body 里的特有内容，目前为空）────────────
  const withExtras = parsed.filter((rel) => rel.extras.length)
  if (withExtras.length) {
    out.push('## 补充说明')
    out.push('')
    for (const rel of withExtras) {
      out.push(`### ${rel.name} · ${rel.date}`)
      out.push('')
      out.push(rel.extras.join('\n'))
      out.push('')
    }
  }

  console.log(
    `[fetch-releases] ${parsed.length} 条列车 → ${invariantBlocks.length} 份破坏性变更清单（合并掉 ${dropped} 次重复）`,
  )
  return out.join('\n')
}

async function main() {
  mkdirSync(dirname(outFile), { recursive: true })

  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'pigeonbox-docs-site',
  }
  // 带 token 才能绕开匿名限流（共享 IP 很容易 403）
  const token = resolveToken()
  if (token) headers.Authorization = `Bearer ${token}`

  let releases = []
  try {
    const res = await fetch(API, { headers })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const all = await res.json()
    releases = all.filter((r) => isTrainRelease(r.tag_name) && !r.draft)
  } catch (e) {
    console.warn(`[fetch-releases] 抓取失败（${e.message}），写入占位片段，构建继续`)
    writeFileSync(
      outFile,
      '> ⚠️ 发布说明抓取失败，请直接查看 [GitHub Releases](https://github.com/pigeonbox/pigeonbox/releases)。\n',
      'utf-8',
    )
    return
  }

  writeFileSync(outFile, render(releases) + '\n', 'utf-8')
}

await main()
