import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { resolve } from 'node:path'

// PigeonBox 文档站。
// 内容真相源: hub 仓库 docs/ 目录(本目录的 ../docs)。内容页通过 VitePress 的
// <!--@include: --> 指令原样引入 hub 文档, hub 侧更新后站点内容自动同步;
// 本目录只维护站点壳(首页/导航/侧边栏)与少量手写页, 详见 docs-site/README.md。
//
// withMermaid: 架构总览等 hub 文档里的 Mermaid 图在 GitHub 上原生渲染, 但
// VitePress 1.x 无内置 Mermaid 支持——此前站内一律退化成代码块(图源裸奔)。
// 插件把 ```mermaid 围栏转成客户端渲染组件, 并随明暗主题切换重绘。

export default withMermaid(
  defineConfig({
    lang: 'zh-CN',
    title: 'PigeonBox 文档',
    description:
      'PigeonBox(文件快递柜) — 匿名口令分享文本/文件的开源自托管平台: 多用户、API Token、多存储后端(S3/WebDAV/云厂商)、Kubernetes/Helm、MCP AI 集成。',

    // 把 Mermaid 组件从主包拆出去：插件默认静态 import 它 → mermaid 核心
    // (~400KB，含布局引擎)进了主包，每页都白下载。改为异步组件后只有含图
    // 页面才拉。'@pb-mermaid-impl' 指向插件真实组件（绝对路径，绕开 exports map）。
    // 注意用 process.cwd()（= docs-site 根）而非 import.meta.url——配置会被编译到
    // .vitepress/.temp/ 下，import.meta.url 指向的是那份临时文件。
    vite: {
      resolve: {
        alias: {
          'vitepress-plugin-mermaid/Mermaid.vue': resolve(process.cwd(), '.vitepress/theme/mermaid-lazy.ts'),
          '@pb-mermaid-impl': resolve(process.cwd(), 'node_modules/vitepress-plugin-mermaid/dist/Mermaid.vue'),
        },
      },
    },

    // VitePress 默认把页面依赖的 chunk 全部 modulepreload（含 mermaid 那个
    // ~680KB 的动态 import）——首页也会白预取它。shouldPreload 是 VitePress
    // 预留的过滤器（不设=全量预取），这里把 mermaid 摘出去：只有渲染图的页面
    // 才按需下载，其余页面不白付这份带宽。
    shouldPreload: (link: string) => !/mermaid/i.test(link),

    // shouldPreload 只是把 mermaid 从 preload 降级到 prefetch（空闲时仍会下）。
    // 再在最终 HTML 上把这条 prefetch 彻底摘掉 —— 非含图页面就真的一字节都不付；
    // 含图页面靠组件的动态 import 按需拉（行为不变）。
    // 注意用 transformHtml（最终 HTML 字符串）而不是 transformHead：后者的返回值
    // 是与原 head **合并**（mergeHead），过滤不掉原有条目。
    transformHtml: (html) => html.replace(/<link rel="prefetch" href="[^"]*[Mm]ermaid[^"]*">\s*/g, ''),

    // 本目录的 README.md 是贡献者文档, 不是站点内容, 排除出路由
    srcExclude: ['README.md'],

    // 站点图标/分享图:与应用同一份品牌图(构建时由 scripts/sync-brand.mjs 从
    // hub docs/brand/logo.svg 同步到 public/ —— 真相源只有一份, 站点与应用图标
    // 不会各持一份而漂移)。
    head: [
      ['link', { rel: 'icon', type: 'image/svg+xml', href: '/logo.svg' }],
      ['link', { rel: 'alternate icon', type: 'image/png', href: '/icon.png' }],
      ['link', { rel: 'apple-touch-icon', href: '/icon.png' }],
      ['meta', { property: 'og:image', content: '/icon.png' }],
      // 消除无样式闪烁(FOUC)：VitePress 把 CSS 标成 rel="preload stylesheet"，
      // 真正生效要等 Vite 的 modulepreload polyfill 在 JS 里把它翻成 stylesheet
      // ——那要等主包(700KB, mermaid 在里面)下载并执行完, 首屏会先闪一段裸 HTML,
      // 用户看着像"页面坏了"。样式表本来就在并行下载, 这里在 head 里就地翻好,
      // 下载到达即生效, 不等 JS。
      ['script', {}, `document.querySelectorAll('link[rel="preload stylesheet"]').forEach(function(l){l.rel='stylesheet'})`],
    ],

    // Mermaid 图配色:跟随品牌青竹(暗色模式由插件自动切 'dark' 主题)
    mermaid: {
      theme: 'base',
      themeVariables: {
        primaryColor: '#e7f5f1',
        primaryTextColor: '#1a1a1a',
        primaryBorderColor: '#0b7f58',
        secondaryColor: '#f5f6f8',
        tertiaryColor: '#fafafa',
        lineColor: '#8a8a8a',
        fontFamily: 'ui-sans-serif, system-ui, -apple-system, sans-serif',
      },
      // useMaxWidth=true：图自适应列宽缩放，**不出现横向右滑**（用户明确要求）。
      // 代价是超宽图被缩小后字偏小 —— 靠放宽该页版心（pageClass pb-wide-doc）缓解。
      // 注意: useMaxWidth 由**图表类型级**配置读取(渲染器取 conf.flowchart /
      // conf.sequence), 顶层同名键不生效, 故按类型分别设置。
      //
      // htmlLabels=false：标签改用 SVG <text> 而非 foreignObject+HTML。站点正文
      // 字体比 mermaid 的估算宽 → 标签多折一行 → foreignObject 按估算高度裁掉
      // 尾巴（文字"压折"）。SVG 文本不裁剪，且宽度按实际字体量出。
      flowchart: { useMaxWidth: true, htmlLabels: false },
      graph: { useMaxWidth: true, htmlLabels: false },
      sequence: { useMaxWidth: true, htmlLabels: false },
    },

  // 被引入的 hub docs/*.md 内部含有指向仓库根/同目录的相对链接
  // (architecture.md 的 ../README.md、DEPLOY-COMPOSE.md 的 ENVIRONMENT_VARIABLES.md),
  // 它们在 GitHub 仓库内有效, 但无法映射为本站路由。仅放行这两类死链(注意
  // VitePress 对链接做规范化: 去掉 .md 后缀、补 ./ 前缀, 正则同时覆盖两种形式),
  // 不使用 ignoreDeadLinks: true —— 手写页与站内链接仍受死链检查约束。
  ignoreDeadLinks: [
    /^(\.\/|\.\.\/)*README(\.md)?($|#)/,
    /^(\.\/|\.\.\/)*ENVIRONMENT_VARIABLES(\.md)?($|#)/
  ],

  themeConfig: {
    siteTitle: 'PigeonBox',

    nav: [
      {
        text: '指南',
        items: [
          { text: '快速开始', link: '/guide/getting-started' },
          { text: '使用说明', link: '/guide/usage' },
          { text: '官方 CLI（pb）', link: '/guide/cli' },
          { text: '部署 Docker', link: '/guide/deploy-docker' },
          { text: '部署 NAS（六平台）', link: '/guide/deploy-nas' },
          { text: '部署 Kubernetes', link: '/guide/deploy-kubernetes' },
          { text: '环境变量', link: '/guide/environment' },
          { text: '升级指南', link: '/guide/upgrade' }
        ]
      },
      { text: '站点介绍', link: '/about' },
      { text: '版本发布说明', link: '/changelog' },
      { text: '架构', link: '/reference/architecture' },
      {
        text: 'API',
        items: [
          { text: 'API Token', link: '/reference/api-tokens' },
          { text: '错误码对照表', link: '/guide/error-codes' },
          { text: 'MCP 集成', link: '/reference/mcp' }
        ]
      },
      { text: 'PigeonBeam', link: '/guide/pigeonbeam' }
    ],

    sidebar: [
      {
        text: '关于',
        items: [
          { text: '站点介绍', link: '/about' },
          { text: '版本发布说明', link: '/changelog' }
        ]
      },
      {
        text: '指南',
        items: [
          { text: '快速开始', link: '/guide/getting-started' },
          { text: '使用说明', link: '/guide/usage' },
          { text: '官方 CLI（pb）', link: '/guide/cli' },
          { text: '部署 Docker Compose', link: '/guide/deploy-docker' },
          { text: '部署 NAS（六平台）', link: '/guide/deploy-nas' },
          { text: '部署 Kubernetes (Helm)', link: '/guide/deploy-kubernetes' },
          { text: '环境变量参考', link: '/guide/environment' },
          { text: '升级指南', link: '/guide/upgrade' }
        ]
      },
      {
        text: 'PigeonBeam（信鸽直传）',
        items: [
          { text: '设备直传独立应用', link: '/guide/pigeonbeam' }
        ]
      },
      {
        text: '架构与集成',
        items: [
          { text: '架构总览', link: '/reference/architecture' },
          { text: 'API Token 指南', link: '/reference/api-tokens' },
          { text: '错误码对照表', link: '/guide/error-codes' },
          { text: 'MCP 集成', link: '/reference/mcp' }
        ]
      }
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/pigeonbox' }],

    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '未找到相关结果',
            resetButtonTitle: '清除查询条件',
            displayDetails: '显示详细列表',
            hideDetails: '隐藏详细列表',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭'
            }
          }
        }
      }
    },

    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    // docs-site 内页面尚未提交 git 时无历史, 显式关闭"最后更新时间"避免噪音
    lastUpdated: false,
    darkModeSwitchLabel: '主题',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    sidebarMenuLabel: '菜单',
    returnToTopLabel: '回到顶部',
    footer: {
      message: 'PigeonBox — 文件快递柜, 开源匿名口令分享平台',
      copyright: '© 2026 pigeonbox org'
    }
  }
  })
)
