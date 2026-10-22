// PigeonBox 文档站自定义主题。
// 默认主题 + 站点级设计：品牌色对齐产品靛蓝、全站统一线性图标（PbIcon）、
// 能力清单单一真相源（PbFeatures）。
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import PbFeatures from './components/PbFeatures.vue'
import PbIcon from './components/PbIcon.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    // markdown 里直接用 <PbFeatures /> / <PbIcon name="..." />
    app.component('PbFeatures', PbFeatures)
    app.component('PbIcon', PbIcon)
  },
} satisfies Theme
