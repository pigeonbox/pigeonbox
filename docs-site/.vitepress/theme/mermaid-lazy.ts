// Mermaid 组件的异步包装。
//
// vitepress-plugin-mermaid 默认把 Mermaid 组件**静态** import 进 VitePress 的
// app 入口 —— mermaid 核心（~400KB，含 dagre/cytoscape 布局引擎）因此进了主包，
// 每个页面都要下载它，哪怕整站只有一页有图。
//
// 这里用 Vite alias 把插件的组件 import 换成本包装：组件本体改为
// defineAsyncComponent 动态加载，只有真正渲染 Mermaid 图的页面才会拉这部分。
// 别名见 .vitepress/config.mts 的 vite.resolve.alias。
import { defineAsyncComponent } from 'vue'

export default defineAsyncComponent(() => import('@pb-mermaid-impl'))
