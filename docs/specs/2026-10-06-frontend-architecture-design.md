# FilesCodeBox 前端架构分层与组件化设计

- 日期：2026-10-06
- 状态：**待拍板**（本文档为设计稿，未动任何代码）
- 范围：`FilesCodeBox/frontend/`（Vue 3.5 + TS + Vite 7 + Element Plus 2.13 按需 + Pinia 3 + vue-i18n 9 + hash 路由 + axios）
- 原则：**行为不变、零新依赖、渐进迁移、每步可独立提交与回滚**

---

## 1. 现状盘点（全部有代码实证）

代码量约 16,100 行 / 40+ 视图与组件。api 层按域拆分且零 Vue 依赖（健康），问题集中在**组件层与编排层**：

| # | 症状 | 证据 |
|---|---|---|
| 1 | 胖组件/胖视图 | `FileUpload.vue` 909 行；`admin/Files.vue` 808；`home/index.vue` 782；`admin/Dashboard.vue` 766；`user/Dashboard.vue` 698；`share/View.vue` 652 |
| 2 | `formatFileSize` 重复定义 **12 处** | FileUpload / PresignUploadDialog / share/View / user/Dashboard / admin{Files,Users,Storage,Dashboard,Maintenance,Moderation,LocalFiles,TransferLogs}（其中 share/View 还是另一个签名变体） |
| 3 | 过期/密码/自定义码/E2E 设置表单重复 **6 处** | FileUpload、TextShare、PresignUploadDialog、admin/Files、admin/LocalFiles、user/Requests |
| 4 | 顶部导航两套实现 | `home/index.vue` 内联一份 + `layouts/AppLayout.vue` 一份；用户下拉菜单在 home / AppLayout（admin/index 另有壳） |
| 5 | 菜单数据在 AppLayout 内重复两份 | 桌面侧栏与移动抽屉各写一遍 6 个 menu-item |
| 6 | 表格+分页模式重复 **9 页** | 9 个页面各自维护 loading/page/pageSize/total/fetch 样板 |
| 7 | 原生 XHR 绕过 axios 拦截器 **4 处** | FileUpload（内联直传）、PresignUploadDialog、api/multifile.ts、api/request.ts——CSRF 头手补、错误归一化缺失、401 会话刷新对上传通道完全不生效 |
| 8 | `setInterval` 轮询回传结果 | FileUpload L339 用 200ms 轮询 `item.status` 等 PresignUploadDialog 完成（`_result` 挂 hack） |
| 9 | 统一错误处理基本未推广 | `useErrorHandler` 仅 2 个文件使用；35 个文件直接 `ElMessage`（错误无 trace_id、无 i18n 翻译）；且 handleError 内部 ElMessage 兼容通道会造成**双 toast** |
| 10 | i18n 漏网 | TextShare.vue 大量硬编码中文（"请输入要分享的文本内容..."、"立即分享"等），en-US 下露中文 |
| 11 | 测试薄弱 | 仅 3 个纯函数 spec（api/presign、utils/accent、utils/api-interceptor）；composable 0、组件 0 |
| 12 | 全局拖拽/粘贴监听内联在 FileUpload | 4 个 window 监听器手写挂载/卸载，无法复用（desktop/其他页面用不上） |

---

## 2. 目标分层与依赖规则

四层单向依赖，**只允许向下 import，禁止反向**（可用 ESLint import 规则或 review 约定，不新增工具链）：

```
┌─────────────────────────────────────────────┐
│ views/          页面装配：路由级组件，拉数据+布局+跳转      │
├─────────────────────────────────────────────┤
│ layouts/ + components/   布局壳与组件（业务/共享分层见 §4）  │
├─────────────────────────────────────────────┤
│ composables/    领域编排：上传管线、表格查询、设置表单状态机   │
├─────────────────────────────────────────────┤
│ stores/         跨页共享状态（Pinia）                      │
├─────────────────────────────────────────────┤
│ api/            端点封装（纯 TS，零 Vue/Pinia 依赖——现状已达标）│
├─────────────────────────────────────────────┤
│ utils/ + types/ 纯函数与类型（零依赖）                      │
└─────────────────────────────────────────────┘
```

各层细则：

| 层 | 允许 import | 禁止 | 说明 |
|---|---|---|---|
| `api/` | types、utils、`api/_xhr` | vue、pinia、组件、store | 每个后端域一个文件；成功码归一化（0/200）只在 `utils/request` 与 `api/_xhr` 两处发生 |
| `utils/` | types | 一切上层 | 纯函数；`clipboard.ts` 这类无状态浏览器 API 封装可留 |
| `stores/` | api、utils | 组件 | 只放**跨页面**状态；页面私有状态留在 composables（config/locale/theme/user 四个维持不变） |
| `composables/` | stores、api、utils | 组件、模板 | 一个领域一个文件；输入参数化、返回 refs+方法；允许 window 事件监听（如 useFileDrop）但禁 DOM 选择器 |
| `components/` | composables、stores、api、utils | views | 共享组件不直接发请求（数据经 props/调用方），自治组件（如 NotifyBell 自拉通知）须在文件头注释声明数据依赖 |
| `views/` | 全部 | — | 只做装配：组合组件 + 调 composable + 路由跳转；单文件软上限 **~400 行**，超限即拆 |

---

## 3. 目标目录结构

```
src/
├─ api/
│  ├─ _xhr.ts                # 【新】XHR 封装：CSRF 头/进度/abort/超时/错误归一化（与 axios 错误格式一致）
│  ├─ share.ts               # 增 uploadFile()（从 FileUpload 内联 XHR 收编）
│  ├─ multifile.ts           # multiDirect 改走 _xhr；chunk/multiBind 逻辑不变
│  └─ ...（现状 13 个域文件不动）
├─ config/
│  └─ menu.ts                # 【新】导航菜单单一数据源（用户侧 6 项；管理侧后续可入）
├─ types/                    # 不变
├─ utils/
│  ├─ format.ts              # 【新】formatFileSize/formatDate/formatDuration（消灭 12 处重复）
│  ├─ clipboard.ts           # 已有，保持
│  └─ ...（request/e2e/sanitize/accent/api-interceptor 不动）
├─ composables/
│  ├─ useShareSettings.ts    # 【新】分享设置表单模型 + 校验 + payload 归一化
│  ├─ useUploadQueue.ts      # 【新】上传队列状态机 + 通道决策 + 进度均摊 + abort
│  ├─ useUploadPlan.ts       # 【新】通道决策纯函数 pickUploadPlan（可单测）
│  ├─ useFileDrop.ts         # 【新】window 拖拽+粘贴监听 → onFiles 回调 + isDragging
│  ├─ useTableQuery.ts       # 【新】loading/page/pageSize/total/search/reload
│  ├─ useClipboardAction.ts  # 【新】复制 + 成功/失败 toast
│  ├─ usePolling.ts          # 【新】定时轮询（挂载启动/卸载清理/页面隐藏暂停）
│  ├─ useErrorHandler.ts     # 已有，W3 推广
│  └─ useTheme.ts            # 已有
├─ components/
│  ├─ layout/
│  │  ├─ TopNav.vue          # 【新】顶部导航（props.variant: 'home'|'app'；slot: nav-extra）
│  │  └─ UserMenu.vue        # 【新】头像+下拉（items 注入）
│  ├─ share/
│  │  ├─ ShareSettingsForm.vue  # 【新】过期/密码/自定义码/E2E 表单（props 控制分段显隐）
│  │  └─ ShareResultDialog.vue  # 【新】分享成功三选一弹窗（码/URL/二维码 + E2E 提示）
│  ├─ upload/
│  │  ├─ FileUpload.vue      # 瘦身至 ~200 行（只装配）
│  │  ├─ FileItemRow.vue     # 【新】单文件行（图标/名/大小/进度/状态/操作）
│  │  └─ PresignUploadDialog.vue  # Promise 化改造
│  ├─ data/
│  │  ├─ PageHeader.vue      # 【新】h2+desc 页头（8+ 页面同款）
│  │  ├─ StatusTag.vue       # 【新】分享状态 tag（文本/文件/多文件/回收站）
│  │  └─ ExpireText.vue      # 【新】过期时间展示（永久/已过期着色/格式化）
│  ├─ ErrorToast/LocaleSwitcher/ThemeSwitcher/NotifyBell/NotifyBanner/TrendChart  # 不动
│  └─ components.d.ts        # unplugin 自动生成，勿手改
├─ layouts/AppLayout.vue     # 菜单改循环渲染 menu.ts（消灭双份）
└─ views/                    # 全部只装配，超 400 行按 §7 映射表拆
```

组件引入约定：**自有组件一律显式 import**（unplugin-vue-components 仅解析 Element Plus，维持现状，不给自有组件开自动导入——来源清晰、可 grep）。

---

## 4. 组件体系：四类 + 命名约定

| 类别 | 位置 | 判定标准 | 例子 |
|---|---|---|---|
| 布局组件 | `layouts/`、`components/layout/` | 承载导航/骨架，不含业务语义 | AppLayout、TopNav、UserMenu |
| 共享业务组件 | `components/{share,upload,data}/` | ≥2 个页面要用、含业务语义 | ShareSettingsForm、ShareResultDialog、ExpireText |
| 页面私有组件 | `views/<域>/components/` | 只有一个页面用（现暂无，出现即建此目录） | — |
| 基础展示 | Element Plus 直接用 | 不二次包装 EP 组件（防升级漂移），组合而非包装 | — |

命名：组件多词 PascalCase；composable `useXxx`；一个文件一个组件/composable；props 用 `defineProps<{...}>()` 类型式；事件用 `defineEmits<{...}>()` 元组式（现状已如此，延续）。

---

## 5. 核心复用单元细化

### 5.1 `utils/format.ts`

```ts
export function formatFileSize(bytes: number): string          // 12 处定义收敛于此
export function formatDate(raw: string | number | Date): string // 各页散落的本地化时间
export function formatDuration(seconds: number): string
```

`share/View.vue` 的 `formatFileSize(raw: number | string)` 变体：string 入参先 `Number()` 归一后复用同一实现。替换为机械操作，12 个 commit 可分文件逐个替换。

### 5.2 `composables/useShareSettings.ts`（消灭 6 处表单重复的状态半边）

```ts
export interface ShareSettings {
  expire_value: number
  expire_style: 'minute' | 'hour' | 'day' | 'week' | 'month' | 'year' | 'forever'
  require_auth: boolean
  password: string
  e2e: boolean
  custom_code: string
}

export function useShareSettings(initial?: Partial<ShareSettings>) {
  // 返回：
  settings: ShareSettings          // reactive
  validate(): boolean              // require_auth→password 必填；custom_code 仅登录可见/可填
  toPayload(): Record<string, string>  // 归一化为 API 字段（FormData 与 JSON 共用）
  reset(): void
}
```

`ShareSettingsForm.vue` props：`{ settings, showCustomCode?: 'auto'|boolean, showE2e?: boolean, compact?: boolean }`。`'auto'`=登录才显示自定义码（现状语义内聚于此）。
**注意**：6 个消费方语义有差异（admin/Files 仅改期、PresignUploadDialog 偏展示），迁移时逐一核对，props 覆盖不了的允许暂留局部实现——不强求一次归一。

### 5.3 上传管线（最重的一块，见 §6）

### 5.4 `composables/useTableQuery.ts`（消灭 9 页样板）

```ts
export function useTableQuery<T>(
  fetcher: (p: { page: number; page_size: number } & Record<string, unknown>) => Promise<{ items: T[]; total: number }>,
  opts?: { defaultPageSize?: number }   // 默认 20，对齐现状
) {
  // 返回：list / total / page / pageSize / loading / search
  //       reload(page?) / onPageChange()（绑 el-pagination 两个事件）
}
```

只收编"分页+loading+reload"公共部分；每页的 tab 筛选、批量选择、行操作留在页面内。**不做**统一 ProTable 组件——各页列差异太大，包装组件只会变成 props 地狱。

### 5.5 其余小件

- `useClipboardAction()`：`copy(text, successKey?, errorKey?)`——10 个文件各自包 toast 的复制逻辑收敛。
- `usePolling(fn, ms)`：NotifyBell(60s)、user/Notifications、admin/Dashboard 三处 setInterval 收口；onMounted 启动、onBeforeUnmount 清理、`document.hidden` 时暂停。
- `useFileDrop({ onFiles })`：FileUpload 的 4 个 window 监听（dragover/dragleave/drop/paste）+ isDragging 收编，desktop 或其他上传入口可直接复用。

---

## 6. 上传管线重构

### 6.1 通道决策抽为纯函数（可单测）

```ts
// composables/useUploadPlan.ts
export type UploadChannel = 'direct' | 'presign' | 'multi-direct' | 'multi-chunk'
export interface UploadPlanInput {
  count: number; totalBytes: number; maxFileBytes: number
  bodyCap: number; presignThreshold: number
}
export function pickUploadPlan(input: UploadPlanInput): UploadChannel
```

判定规则**与现行为完全一致**（钉死，防回归）：

1. 单文件 > presignThreshold(100MB) → `presign`
2. 多文件 且 总体积 ≤ bodyCap 且 每文件 ≤ bodyCap → `multi-direct`
3. 多文件 其余 → `multi-chunk`（逐文件 chunk，不 complete，最后 multi-bind 一次）
4. 其余（单文件小） → `direct`

bodyCap 取 `max(uploadSize − 1MB, 0) || 8MB`（现逻辑保留）；E2E 开启时任何文件 > 100MB 直接拒绝（现逻辑保留）。

### 6.2 `composables/useUploadQueue.ts`（状态机 + 编排）

```ts
export interface UploadTask {
  id: string
  file: File        // 原始文件（展示用）
  payload: File     // 实际上传内容（E2E 密文；未加密 === file）
  status: 'pending' | 'encrypting' | 'uploading' | 'binding' | 'success' | 'error' | 'cancelled'
  progress: number  // 0–100
  error?: string
}

export function useUploadQueue(opts: {
  settings: ShareSettings                 // useShareSettings 的产物
  bodyCap?: () => number                  // 默认读 configStore.uploadSize
  presignThreshold?: number               // 默认 100MB（测试可调小）
  chunkSize?: number                      // 默认 5MB
}): {
  tasks: Ref<UploadTask[]>
  addFiles(files: File[] | FileList): void
  remove(id: string): void
  start(): Promise<UploadOutcome | null>  // E2E 预加密 → pickUploadPlan → 执行 → emit 结果
  cancel(id?: string): void               // AbortController 统一取消（含 multi）
  dispose(): void                         // 组件卸载时 abort 全部
}
```

要点：
- **multi-direct 聚合进度按字节均摊到各任务行**——现 FileUpload L507-524 的逻辑原样搬入。
- `multi-chunk` 通道维持逐文件顺序上传 + 每片 SHA-256 期望哈希 + 422 重传 ≤2 次（api/multifile.ts 现实现不动，仅 XHR 部分换 `_xhr`）。
- FileUpload.vue 退化为装配：`useFileDrop` + `useShareSettings` + `useUploadQueue` + `ShareSettingsForm` + `FileItemRow` 列表 + `ShareResultDialog`。
- **emit 契约不变**：`success: [{ code, share_url, full_share_url, qr_code_data, e2e_key? }]`，home/index.vue 零改动。

### 6.3 PresignUploadDialog：轮询改 Promise

```ts
// 组件 expose：
defineExpose({ open: (file: File, opts: ShareSettings) => Promise<PresignCompleteData> })
```

内部管理 visible，success/failed 时 resolve/reject。FileUpload 删除 200ms `setInterval` 轮询与 `_result` 挂载 hack（§1#8）。

### 6.4 XHR 收口 `api/_xhr.ts`

```ts
export function xhrRequest<T>(opts: {
  url: string
  method?: string                      // 默认 POST
  form?: FormData
  onProgress?: (loaded: number, total: number) => void
  signal?: AbortSignal
  timeout?: number
}): Promise<T>
```

内置：`X-Requested-With` 头（对齐 axios 拦截器）、JSON 解析 + 成功码归一化（0/200）、错误归一化为 `{ code, message }`（与 utils/request.ts 拦截器产物同形）。消费方 4 处：FileUpload 内联直传（收编为 `api/share.ts#uploadFile`）、PresignUploadDialog、multifile.ts multiDirect、api/request.ts。

---

## 7. 胖文件拆解映射表

| 现文件（行数） | 拆出 | 剩余职责 / 预期行数 |
|---|---|---|
| FileUpload.vue (909) | useUploadQueue / useShareSettings / useFileDrop / pickUploadPlan / ShareSettingsForm / FileItemRow / share.uploadFile | 装配 ~200 |
| home/index.vue (782) | TopNav + UserMenu + ShareResultDialog | hero + 场景 tab + 功能 tabs + footer ~350 |
| admin/Files.vue (808) | useTableQuery + ShareSettingsForm(改期段) + ExpireText + format | ~400 |
| admin/Dashboard.vue (766) | usePolling + StatCard（若 user/Dashboard 同款则共享）+ format | ~300 |
| user/Dashboard.vue (698) | 同上 + useClipboardAction | ~300 |
| share/View.vue (652) | format / ExpireText（取件编排本就内聚，不强拆） | ~500 |
| AppLayout.vue (327) | menu.ts 数据源 + UserMenu | 桌面/移动循环渲染同一数组，~250 |

---

## 8. 错误处理与 i18n 规范

**错误**（W3）：
1. 确认 `ErrorToast` 为全局唯一 toast 通道后，`useErrorHandler.handleError` 去除 ElMessage 兼容双弹（§1#9）；未挂 ErrorToast 的路由补挂。
2. 35 个文件裸 `ElMessage.error` 逐页替换为 `handleError(e)`（带 trace_id + errcode→i18n）；**成功类**提示保留 ElMessage（成功无需 trace 通道）。
3. 业务 401 白名单（取件/下载端点）逻辑已在 axios 拦截器，上传通道经 `_xhr` 收口后同样绕开会话刷新——行为对齐，写入 `_xhr` 注释。

**i18n**：
- TextShare.vue 硬编码中文全部 key 化（W1 修复）；新增共享组件一律 `t()`，key 按域前缀（`share.settings.*`、`share.result.*`）。
- zh-CN / en-US 同步补 key，PR 内两文件同 commit。

---

## 9. 测试策略

vitest 已配（`npm run test`）。原则：**composable/纯函数测试为门禁，组件测试可选**（不一次引入 @vue/test-utils，W4 再议）。

| 必写 | 覆盖 |
|---|---|
| utils/format.spec | formatFileSize 边界（0/负/KB/GB）、formatDate |
| useUploadPlan.spec | 决策树 4 分支 + 边界（=bodyCap、=threshold、E2E 超限拒绝） |
| useUploadQueue.spec | mock api 层：单传/多传/分片绑定/进度均摊/cancel 中途中断/E2E 预加密顺序 |
| useShareSettings.spec | validate 规则、toPayload 归一化 |
| useTableQuery.spec | reload 竞态（慢请求后到不覆盖新页）、分页参数 |
| api/_xhr.spec | code 归一化/abort/progress 回调 |

验收命令：`npm run typecheck && npm run test`。

---

## 10. 迁移波次（每 commit 独立可回滚）

**W1 — 纯去重，零行为变化（先行，风险最低）**
1. `utils/format.ts` + 12 处替换（可按文件拆多 commit）
2. `config/menu.ts` + AppLayout 双份菜单收敛 + `UserMenu` 抽出（home/AppLayout 复用）
3. `ShareSettingsForm` + `useShareSettings`（6 处逐一迁移，每 commit 一个消费方）
4. TextShare i18n 修复
验收：typecheck/test 绿 + 手工冒烟（首页单/多文件上传、文本分享、取件、user/admin 各列表页）

**W2 — 上传管线重构（行为等价替换）**
1. `api/_xhr.ts` + `share.uploadFile` 收编 + multifile.ts 改造
2. `useUploadQueue` + `pickUploadPlan` + FileUpload 瘦身 + PresignUploadDialog Promise 化（消灭 setInterval）
3. `useFileDrop`
验收：useUploadPlan/useUploadQueue 单测绿 + 手工四通道冒烟（小直传 / presign（临时调小阈值验证）/ 多文件直传 / 多文件分片绑定）+ E2E 加密分享→取件解密往返 + 上传中途取消 + **home 页 emit 契约回归**

**W3 — 列表页与错误通道治理**
1. `useTableQuery` + 9 表格页接入（每页一 commit）
2. PageHeader / StatusTag / ExpireText 接入
3. useErrorHandler 推广（去双 toast，35 文件替换，每域一 commit）
4. usePolling 收口 3 处
验收：各列表页分页/搜索/批量操作冒烟 + 制造 401/500 验证 toast 单次且含 trace_id

**W4 — 测试补齐 + 文档**
- §9 测试补齐；frontend README 增"架构分层"章节（分层图 + 新代码落位约定）
- 可选：引入 @vue/test-utils 做关键组件 smoke

---

## 11. 明确不做（YAGNI）

- 不换 UI 库、不引入新状态管理、不做微前端/模块联邦；
- 不抽独立组件库 npm 包——desktop 客户端（Tauri）是否复用 frontend 组件留待 desktop M1 设计（见记忆 fcb-desktop-client-roadmap）时评估，本设计不预先优化；
- 不做统一 ProTable 大组件（列差异大，composable 已够）；
- 不给自有组件开自动导入；
- 不在本轮引入任何新 runtime 依赖（W4 可选 devDep @vue/test-utils 除外）。

## 12. 风险与对策

| 风险 | 对策 |
|---|---|
| 上传决策边界回归（bodyCap 依赖运行时 uploadSize） | 决策抽纯函数 pickUploadPlan + 单测钉死（§6.1） |
| 6 处设置表单语义差异（admin/Files 仅改期等） | 逐一核对、允许暂留局部实现（§5.2） |
| 多文件上传链路无自动化回归 | W2 手工四通道冒烟清单 + useUploadQueue 单测 |
| 并行会话同仓改动（工作区惯例） | 每波开工前 `git status` / `git pull --ff-only`，小 commit |
| CSP 约束（历史 unsafe-eval 事故） | 零新依赖；不引入任何运行时编译类库 |
