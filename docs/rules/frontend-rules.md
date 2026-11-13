# 前端规则（frontend-rules）

> 单源：AGENTS.md 重构（2026-11-13，spec 附录 A#15/#16、附录 B L820-849·L883·L884）。
> **动前端 UI 前读**；窄屏守卫真相源 `frontend-core/src/views/*/__tests__/narrowScreen.spec.ts`。

## 组件级改动必须看渲染（纪律）

**API 全绿 ≠ 页面正确**：组件/交互改动一律用浏览器看真实渲染——只跑接口/单测会全部
漏掉（实录：hash 路由同记录换参数不重取数 ⇒ A 的内容挂在 B 的地址下；取件码被标成
「分享码」）。**自检矩阵必须含宽度维度**：桌面 / 窄屏(390 设备模拟) / 中屏(768) 三档
（补窄屏档时一眼看出管理台配置页输入框宽度为 0）。⚠️ Chrome **窗口**最小宽约 500px
⇒ resize 到 390 不生效，**窄屏必须用 DevTools 设备尺寸模拟**。
探针栈配方与三坑见工作区 `docs/topics/workspace.md`。

## 响应式与断点

- **折叠屏不是「一种窄屏」，是一段连续宽度区间**：内屏 690~900px + 平板竖屏 834 +
  小窗分屏 ⇒ 与手机同型放不下 ⇒ 断点提到 **1024px**（侧栏抽屉化同档）。
  **判据：表格总列宽 vs 视口宽**——放不下就换形态，与「设备是不是手机」无关。
- **断点分档**：≤600 手机单列 / 600~1024 卡片网格 `repeat(auto-fill, minmax(280px, 1fr))`
  （280 不是 320：700px 视口内容区 626px ⇒ 320×2 放不下）/ >1024 表格形态。
- **移动端/折叠屏一律 `100vh` + `100dvh` 双声明**（先 vh 后 dvh）：地址栏收起/折叠
  展开时 100vh 不变 ⇒ 底部被裁。
- **安全区三件套**：viewport 必须带 `viewport-fit=cover`（缺它 iOS 把 safe-area 恒 0）；
  定义 `--safe-*` 变量落顶栏/底栏/左右内缩（border-box 下不补高度会被挤扁）；
  **变体覆盖也要带安全区**（实测 `.top-nav--home` 基础规则后覆盖 padding 抹掉 safe-top
  ⇒ 首页顶栏压刘海下；判据=页面覆盖变量后量 `getComputedStyle`，比截图可靠）。

## 表格与列宽（实测公式）

- **列宽 ≥ 按钮数×52 + 24**（52=文字按钮 48+间距 4；带图标 +12）。
- **列宽按「最长文案」定，通常是英文**：切 en-US 实测每个操作列按钮总宽
  （克隆真实按钮改文案 → `getBoundingClientRect` 量）。⚠️ EP 2.13 尺寸类是
  `el-button--small`，不是 `is-small`。实测表（span+24）：admin/files 312→320、
  announcements 240→260、users 284→300、local-files 341→360、user/shares 375→380、
  dashboard 258→280。
- **两个条件缺一不可**：只加宽不禁折行仍折行；只禁折行（`nowrap-actions`）宽度不够
  变溢出裁切。操作列禁折行样式已提全局 `styles/main.scss`。
- **表头判据**：换行不产生 scrollWidth 溢出 ⇒ 只查 `scrollWidth > clientWidth` 会漏判，
  **必须同时看行数**（表头高/line-height > 1）。
- **表格加列会加剧窄屏裁切**：改表格后量总宽（`table.getBoundingClientRect().width` vs
  容器 `clientWidth`；截图会被缩放，**图宽 ≠ 视口宽**）。
- **el-table 的 fixed 列是 sticky 不是副本**：真实类名 `el-table-fixed-column--right`；
  暗色透明底 ⇒ fixed 单元格要补**不透明**底色（半透明用 `background-image` 叠不透明层）；
  hover 规则特异度要压过既有规则（选 `.el-table__cell`），算双方特异度别赌 `!important`。

## CSS 工作流

- **先注入验证再落仓**：生产页注入候选 CSS → 量 computed → 截图 → 落仓 → **撤注入做
  负对照**（比提交→发版→部署往返快一个数量级）。
- `<style scoped>` 是**普通 CSS 不是 SCSS**：注释必须 `/* */`，写 `//` build 失败。
- **样式补丁会被自身规则压住（特异度）**：改样式前在真实页面量 `getComputedStyle`
  并算双方特异度。
- **列宽类修复的工作流**同上：DOM 实测（按钮 y 坐标同排、scrollWidth vs clientWidth）
  优于读代码猜（`min-width` 列会被拉伸、固定列不参与滚动条计算）。

## 路由与其他

- **vue-router `next({ ...to })` 会带着 `name` 重新解析**（name 优先于 path ⇒ 永远落回
  原路由）：管理台直达/刷新 404、从首页点进去正常。按 **path** 重解析：
  `next({ path: to.path, query: to.query, hash: to.hash, replace: true })`。
- **端到端加密的浏览器约束**：`crypto.subtle` 只在安全上下文可用 ⇒ `http://IP:port`
  下 E2E 用不了；开关处 `e2eSupported(scope)` 拦（`utils/e2e.ts`，纯函数可单测），
  **别无条件给开关**（否则用户填完表点发送才吃 toast、分享根本没建）。
  分享页取数触发键 = 分享码 + 解密密钥（`shareRouteKey.ts`）——只改 `?key=` 也要重取数。

## 无头复验（浏览器 MCP 挂了也能验）

用本机 Chrome + CDP 直连自建通道（Node ≥21 全局 WebSocket）：`--headless=new
--remote-debugging-port` → `/json/list` → `Network.setCookie`/`Page.navigate`/
`Runtime.evaluate`/`Page.captureScreenshot`；量 computed/getBoundingClientRect/
scrollWidth 比截图可断言。换语言必须 `Page.reload`（i18n 模块初始化时读 `app-locale`）。
具体配方与免密细节见工作区 `docs/topics/workspace.md`。
