// include 链路门禁（构建前自动跑，predocs:dev / predocs:build 钩子）。
//
// 为什么需要它：VitePress 的 <!--@include: ../../docs/xxx.md--> 在目标文件
// 不存在时**不报错**，页面照常生成，只是正文为空——构建是绿的，线上是空页。
// 实弹：docs-site/reference/design/ 下 4 个 stub 的 include 路径少写了一级
// （../../ 应为 ../../../），四页正文全空，而 docs:build 一路绿灯。
//
// 本脚本按 stub 文件自身目录解析每个 @include 目标，存在即通过，缺失即构建失败。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { dirname, resolve, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const siteRoot = resolve(here, '..')

/** 递归收集站点内所有 markdown（排除 node_modules / 构建产物 / 贡献者 README） */
function collectMarkdown(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.vitepress' || name === 'dist') continue
    const full = resolve(dir, name)
    const st = statSync(full)
    if (st.isDirectory()) {
      collectMarkdown(full, out)
    } else if (name.endsWith('.md') && name !== 'README.md') {
      out.push(full)
    }
  }
  return out
}

const broken = []
let checked = 0

for (const file of collectMarkdown(siteRoot)) {
  const text = readFileSync(file, 'utf-8')
  for (const m of text.matchAll(/@include:\s*(\S+)/g)) {
    const raw = m[1].replace(/-->$/, '').trim()
    checked++
    // include 路径相对于**引用它的那个 md 文件**自身目录
    const target = resolve(dirname(file), raw)
    if (!existsSync(target)) {
      broken.push({ file: relative(siteRoot, file), raw, resolved: relative(siteRoot, target) })
    }
  }
}

if (broken.length) {
  console.error('[check-includes] 发现断链的 @include（会导致页面正文为空且构建不报错）：')
  for (const b of broken) {
    console.error(`  ${b.file}  ->  ${b.raw}  (解析为 ${b.resolved})`)
  }
  console.error('[check-includes] 提示：include 路径相对 stub 文件自身目录，层级每深一级要多一个 ../')
  process.exit(1)
}

console.log(`[check-includes] ${checked} 条 @include 全部命中目标文件`)
