# pigeonbox-docs

PigeonBox 文档站（VitePress 1.x，中文站点）。

**内容真相源是 hub 仓库的 `../docs/` 目录。** 本站大多数内容页通过 VitePress 的 `<!--@include: -->` 指令原样引入 `../docs/*.md`：hub 文档更新后，站点内容自动同步，本目录不需要跟改；本目录只维护站点壳（首页 / 导航 / 侧边栏 / 少量手写页）。

## 本地预览

```bash
cd docs-site
npm install
npm run docs:dev      # 开发服务器, 默认 http://localhost:5173
```

## 构建与产物预览

```bash
npm run docs:build    # 构建产物输出到 .vitepress/dist/
npm run docs:preview  # 本地预览构建产物
```

## 目录结构

```
docs-site/
├── .vitepress/config.mts   # 站点配置: lang/title/nav/sidebar/搜索/死链策略
├── .vitepress/theme/       # 自定义主题(默认主题 + 品牌色 + 统一图标 + 能力组件)
│   ├── index.ts                # 主题入口: 注册 PbFeatures / PbIcon 全局组件
│   ├── icons.ts                # 线性图标集(24×24, stroke 1.75, currentColor)——全站图标唯一来源
│   ├── style.css               # 品牌色变量(--vp-c-brand-*) + markdown 内自定义块样式(.pb- 前缀)
│   ├── components/
│   │   ├── PbIcon.vue          # 图标渲染器
│   │   └── PbFeatures.vue      # 能力卡片组(3 列, 悬停浮起)
│   └── data/features.ts        # 能力清单单一真相源(标题/说明/图标), 首页与介绍页共用
├── index.md                # 首页(layout: home 手写: hero + 导航卡, 路由 /)
├── about.md                # 站点介绍(layout: home 手写: hero + 能力网格 + 流程/部署/截图/生态, 路由 /about)
├── guide/                  # 使用指南
│   ├── getting-started.md      # 快速开始(手写, 事实以 hub README + docs/DEPLOY-COMPOSE.md 为准)
│   ├── usage.md                # 使用说明(手写, 2026-10-14 对码 v1.22.0 列车)
│   ├── deploy-docker.md        # @include ../docs/DEPLOY-COMPOSE.md
│   ├── deploy-nas.md           # @include ../docs/DEPLOY-NAS.md
│   ├── deploy-kubernetes.md    # 手写(事实以 charts 仓库 README 为准)
│   ├── environment.md          # @include ../docs/ENVIRONMENT_VARIABLES.md
│   ├── upgrade.md              # 手写页:通用升级清单+版本要点(新→旧);v0.3 历史叙事 @include ../docs/v0.3-upgrade-notes.md 收进折叠附录
│   └── error-codes.md          # 手写页:全量错误码对照表(对照 contracts/errcode/errcode.go + core pkg/errors 维护)
└── reference/              # 架构 / API / 设计文档
    ├── architecture.md         # @include ../docs/architecture.md
    ├── api-tokens.md           # @include ../docs/API-TOKENS.md
    ├── mcp.md                  # @include ../docs/MCP-README.md
    └── design/                 # @include ../docs/design/*.md (4 篇)
```

## 首页与介绍页的分工

| 页面 | 形态 | 回答的问题 |
|---|---|---|
| `/`（`index.md`） | hero + 三组导航卡（我要部署 / 我要用 / 我要接入） | "文档在哪儿" |
| `/about`（`about.md`） | hero + 能力网格 + 三步流程 + 部署形态表 + 界面截图 + FAQ + 生态仓库 | "PigeonBox 是什么" |

两页共用 `.vitepress/theme/data/features.ts` 的能力清单（`<PbFeatures />`），不各写一版。

## 如何加新页面

两种方式：

1. **引用现有 hub 文档（`../docs/` 已有对应内容时，推荐）**：新建一个只有 frontmatter 的 stub 页，用 include 引入，例如 `guide/foo.md`：

   ```md
   ---
   title: 页面标题
   ---
   <!--@include: ../../docs/xxx.md-->
   ```

   include 路径相对于 stub 页自身（`guide/`、`reference/` 下是 `../../docs/`）。

2. **手写页（`../docs/` 没有对应内容时）**：直接在 `guide/` 或 `reference/` 下写 markdown，注意事实要与 hub 仓库代码/文档一致。

无论哪种方式，都要把新页面登记进 `.vitepress/config.mts` 的 `nav` / `sidebar`（不加导航也能通过直链访问，但难以被发现）。

## 注意事项

- **死链策略**：`config.mts` 的 `ignoreDeadLinks` 只按正则放行两类被引入的 hub 文档内部相对链接（`../README.md`、`ENVIRONMENT_VARIABLES.md`——它们在 GitHub 仓库内有效，但无法映射为本站路由）。不要扩大放行范围，手写页与站内链接的死链仍会让 `docs:build` 失败。
- `../docs/` 下的 markdown 是真相源，改内容去那边改；本目录的 stub 页只承载 frontmatter 与 include 指令，不要在 stub 页里手写正文（会被下次对照真相源时当成偏差）。
- `docs/design/` 与 `docs/superpowers/` 中的带日期文件属内部设计/计划存档，站点以"架构与设计"分组只读引用；新增设计文档后如需对外，按方式 1 加 stub 页即可。
- **站点介绍页（`about.md`）与首页（`index.md`）**都用 `layout: home`（VitePress 官网式 hero + 正文容器），正文里的自定义块（步骤条 / 截图 / 链接组 / CTA）样式收在 `.vitepress/theme/style.css` 的 `.pb-` 前缀作用域内；正文图片走 `public/screenshots/` 绝对路径。
- **图标只有一处**：全站图标定义在 `.vitepress/theme/icons.ts`（24×24 线性、stroke 1.75、currentColor），能力文案在 `.vitepress/theme/data/features.ts`。新增能力时改这两个文件，不要在 markdown 里另画一套，也不要用 emoji（emoji 是此前"AI 味"的来源）。
- **markdown 里的裸 HTML 样式要提权**：`.vp-doc a` 的特异性 (0,1,1) 高于类选择器 (0,1,0)，自定义按钮/卡片链接必须写成 `.vp-doc a.pb-btn` / `.vp-doc a.pb-link`，否则会被正文链接样式盖掉（颜色与下划线都会被夺走）。
- **本地预览后改样式要重启 preview**：`vitepress preview` 在启动时快照 `dist/` 资源清单，重新 `docs:build` 后新哈希的 CSS/JS 会 404——开发期建议用 `npm run docs:dev`（热更新），或每次 build 后重启 preview。
