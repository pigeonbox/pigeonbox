// 版本发布说明数据抓取（构建前自动跑，predocs:dev / predocs:build 钩子）。
//
// 真相源 = hub 仓 pigeonbox/pigeonbox 的 **v* Release**（发布列车 v2 编排器
// release/trainctl 生成的生态快照 notes：组件矩阵 + 破坏性变更清单）。
// 仓内 CHANGELOG.md 只记工作区级变更且更新滞后，因此站点发布说明以 Release 为准。
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
  return text.replace(/<!--\s*@include:/g, '<!-- @include&#58;')
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
    releases = all
      .filter((r) => isTrainRelease(r.tag_name) && !r.draft)
      .sort((a, b) => new Date(b.published_at) - new Date(a.published_at))
  } catch (e) {
    console.warn(`[fetch-releases] 抓取失败（${e.message}），写入占位片段，构建继续`)
    writeFileSync(
      outFile,
      '> ⚠️ 发布说明抓取失败，请直接查看 [GitHub Releases](https://github.com/pigeonbox/pigeonbox/releases)。\n',
      'utf-8',
    )
    return
  }

  const parts = []
  for (const r of releases) {
    const date = (r.published_at || '').slice(0, 10)
    const body = (r.body || '').trim()
    parts.push(`## ${r.name || r.tag_name} · ${date}`)
    parts.push('')
    parts.push(`<a href="${r.html_url}" target="_blank" rel="noreferrer">在 GitHub 上查看该版本 Release ↗</a>`)
    parts.push('')
    if (body) {
      parts.push(mdSafe(body))
      parts.push('')
    }
  }

  writeFileSync(
    outFile,
    `<!-- 本文件由 scripts/fetch-releases.mjs 生成，勿手改；改发布说明请改 Release 内容 -->\n\n${parts.join('\n')}`,
    'utf-8',
  )
  console.log(`[fetch-releases] 已写入 ${releases.length} 条列车发布说明 → .vitepress/generated/releases.md`)
}

await main()
