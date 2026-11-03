# 上传/下载百分比设计（frontend-core）

> 2026-11-03 落纸。**用户已拍板**：范围 = 上传 + 下载两侧都补齐；载体 = 只改公共前端 `frontend-core`
> （浏览器管理台 / 取件页 / 桌面端 UI 共用同一套）；下载 = **全量接管**（所有下载走统一下载器）；
> 进度展示 = **就地**（按钮旁 / 行内进度条）。
> **本稿后端零改动**（core / contracts / server 全不动）。

## 1. 现状（2026-11-03 核过代码，不是推测）

### 1.1 上传侧：百分比大体在，但有缺口

| 通道 | 进度来源 | 落点 | 判据 |
|---|---|---|---|
| `direct`（单文件直传） | `xhr.upload.onprogress` | `useUploadQueue` → `task.progress` | ✅ 真进度 |
| `multi-direct`（多文件直传） | XHR **聚合**进度 | 按文件**均摊**到各任务行 | ⚠️ **失真**（见 §1.3） |
| `multi-chunk`（分片中转） | `chunkUploadFile` 的分片进度 | `task.progress` | ✅ 真进度（逐文件串行） |
| `presign`（>100MB 大文件） | `PresignUploadDialog` 内部 `xhrRaw` 进度 | **只在弹窗里** | ⚠️ **文件列表行恒 0%** |

出处：
- `frontend-core/src/api/_xhr.ts:77` — `xhr.upload.onprogress` ⇒ `onProgress(loaded, total)`
- `frontend-core/src/composables/useUploadQueue.ts:402-451` — `plan === 'presign'` 分支**不订阅任何进度回调**
- `frontend-core/src/components/upload/PresignUploadDialog.vue:236` — `progress.value = Math.round((loaded / total) * 95)`（PUT 阶段占 95%，complete 阶段 97→100）
- `frontend-core/src/composables/useUploadQueue.ts:464-479` — `multiDirect` 的 `onProgress(loaded)` 是**单请求聚合字节数**

### 1.2 下载侧：基本没有百分比

| 路径 | 现状 | 出处 |
|---|---|---|
| 取件页普通下载 | `window.open(url, '_blank')` | `views/share/View.vue:510` |
| 取件页 E2E 下载 | `fetch(url)` → `resp.arrayBuffer()` → `decryptBytes` → blob | `views/share/View.vue:465-486` |
| 取件页打包 zip | `window.open(url)` | `views/share/View.vue:514-520` |
| 管理台文件下载 | axios `responseType:'blob'` → `createObjectURL` | `views/admin/Files.vue:788-803` |

⇒ 四条路径**全部**没有页面内百分比。前三条走浏览器原生下载（浏览器自带下载气泡有 %，但页面内无）。

### 1.3 已核实的三个硬约束

**① E2E 是 AES-256-GCM ⇒ 不能边下边解密。**
`frontend-core/src/utils/e2e.ts:23` — `import { gcm } from '@noble/ciphers/aes.js'`；
`encryptBytes` / `decryptBytes` 的载荷形态是 `iv || ciphertext || tag`。
GCM 认证需要**完整密文 + tag** ⇒ 无法增量解密 ⇒ **E2E 下载的内存占用必然 = 文件大小**。
⇒ 本设计**不改变**这个事实（现状已经如此），只是把「下载 %」补上。根治需改协议为分块密文，**不在本次范围**。

**② `download_url` 默认同源，但可被配置成跨域。**
`contracts/idl/share.thrift:86` — `optional string download_url`；
`core/pkg/baseurl/shareurl.go:43` — `{base}/share/download?code={code}[&token={token}]` ⇒ **同源**，fetch 无 CORS 问题。
但 `core/conf/config.go:533` — `download.s3_direct_download` 开启时，`core/app/share/files.go:122` 的
`PresignDownloadURL` 会把下载地址换成**跨域 S3 预签名 GET** ⇒ JS 接管会撞 CORS。
⇒ **下载器必须能降级回原生下载**。

**③ `multi-direct` 是单 multipart 请求 ⇒ 逐文件真进度拿不到。**
`frontend-core/src/api/multifile.ts:62-88` — 多个文件拼进**同一个** `FormData`，一次 POST。
XHR 的 `onprogress` 只给**聚合** `loaded`。
现行代码把聚合字节按**文件顺序**均摊（`useUploadQueue.ts:464-479`）⇒
第一个文件会先冲到 100%、其余长期停在 0%，**这是误导，不是估算**。
⇒ 要真实逐文件进度需后端改成分文件上传，**不在本次范围**。

### 1.4 服务端已备好但本次不用的能力

`core/app/share/files.go:72` — `OpenShareDownloadRange`（Range 请求已支持）⇒ 断点续传后端已就绪，
但本次**不接**（YAGNI）。

## 2. 目标形态

```
上传  ── 真进度 ──▶ 行内进度条（文件列表行）
下载  ── 真进度 ──▶ 按钮下方行内进度条（百分比 / 速度 / 剩余时间）
无真进度 ──▶ 如实显示「已移交浏览器下载」+ 体积，**不假装有 %**
```

原则：**真数字只出现在真准确的地方。** 拿不到真进度的场景，宁可降级展示，也不编一个数字。

## 3. 统一下载器 `src/utils/downloader.ts`

### 3.1 对外接口

```ts
export interface DownloadProgress {
  loaded: number
  /** 服务端未给 Content-Length 时为 0（不确定态） */
  total: number
  /** 0-100；total 未知时为 -1（调用方渲染不确定态） */
  percent: number
  bytesPerSecond: number
  etaSeconds: number | null
  phase: 'preparing' | 'downloading' | 'transforming' | 'saving' | 'done' | 'handed-off'
}

export interface DownloadRequest {
  url: string
  /** 兜底文件名；服务端 Content-Disposition 优先 */
  filename: string
  headers?: Record<string, string>
  signal?: AbortSignal
  /** 后处理（E2E 解密）。仅内存档可用——流式写盘无法在解密后改写 */
  transform?: (bytes: ArrayBuffer) => Promise<ArrayBuffer>
  onProgress?: (p: DownloadProgress) => void
}

export interface DownloadOutcome {
  /** 最终落地的档位 */
  sink: 'fs' | 'blob' | 'native'
  bytes: number
  /** sink==='native' 时为 true：页面内无 %，浏览器接管 */
  handedOff: boolean
}

export async function download(req: DownloadRequest): Promise<DownloadOutcome>
```

### 3.2 三档落盘策略

| 档 | 触发条件 | 行为 | 内存 | 页面内 % |
|---|---|---|---|---|
| `fs` | `window.showSaveFilePicker` 存在 | 用户选路径 → 逐 chunk 流式写盘 | ~0 | 精确 |
| `blob` | 无 fs API **且** 体积 ≤ `MEMORY_SINK_LIMIT`（默认 64MB） | 累积内存 → `createObjectURL` → `<a download>` | = 体积 | 精确 |
| `native` | 无 fs API **且** 体积 > 限 | 退回 `<a download>` / `window.open` | 0 | **无** |

体积来自响应头 `Content-Length`。响应头缺失 ⇒ 视为体积未知 ⇒ 按 `blob` 档尝试
（若累积过程中超过 `MEMORY_SINK_LIMIT` ⇒ **丢弃已累积缓冲 + 不落盘** ⇒ 降级 `native`）。

`MEMORY_SINK_LIMIT` 以命名常量导出（默认 `64 * 1024 * 1024`），便于单测直接钉边界。

### 3.3 调用次序（关键）

`showSaveFilePicker` 受 **transient activation** 约束 ⇒ 必须在**用户点击的同步调用链**里发起，
`await fetch` 之后再调用可能已失效 activation。

⇒ 次序固定为：

```
用户点击
  └─▶ ① 若 fs API 可用 ⇒ showSaveFilePicker()   ← 同步链内，用户可取消
        ├─ 用户取消 ⇒ 零请求、零字节、干净退出
        ├─ 拿到 writable
        └─ fs API 不可用（Firefox / Safari）⇒ 直接进 ②
  └─▶ ② fetch(url) → response
        ├─ 失败（CORS / 网络）⇒ 关闭空文件 + 自动降级 native + 报错
        └─ 成功 ⇒ 读 content-length ⇒ 选档位 ⇒ 逐 chunk 读取
```

⇒ **用户取消保存 ⇒ 一个字节都不会下载**（比现状 `window.open` 更省流量）。
⇒ fetch 失败时必须**关闭并丢弃**已创建的空文件，否则用户磁盘上留下一个 0 字节垃圾。
⇒ 「先取保存句柄、再发 fetch」还顺带保证了：**拿到的是用户真正要的路径**，不会下完才问存哪。

### 3.3.1 取消（AbortSignal）

`req.signal` 触发时：`reader.cancel()` 停流 ⇒ 关闭 writable ⇒ **删除已创建的空/半截文件**
（fs 档）⇒ 内存档直接丢弃缓冲 ⇒ 抛 `Cancelled`（`code = -1`，与 `_xhr.ts` 的取消约定一致）。
取消是**用户主动操作**，不算失败，UI 只提示「已取消」。

### 3.4 降级触发条件（穷举）

| 触发 | 处置 |
|---|---|
| `showSaveFilePicker` 不存在（Firefox / Safari） | 走 `blob` / `native` 档 |
| 用户取消保存对话框 | 静默退出，**不算错误** |
| `fetch` 网络错误 | 降级 `native`（交给浏览器重试），并提示 |
| 跨域 S3 未开 CORS（`s3_direct_download` 场景） | 同上 |
| 响应无 `Content-Length` | 按未知体积处理；`blob` 档累积超限 ⇒ 降级 `native` |
| `transform` 抛错（E2E 口令错 / 密文损坏） | **不降级**，直接报错（原生下载拿到的是密文，降级无意义） |

### 3.5 E2E 特例

E2E 固定走 `blob` 档（§1.3①：GCM 不能增量解密，流式写盘无法在解密后改写）：
下载阶段有 % ⇒ `transforming`（解密中，**无 %**）⇒ `saving` ⇒ `done`。
内存占用 = 文件体积，**与现状持平**，不新增内存风险。

⚠️ E2E **不适用** `MEMORY_SINK_LIMIT` 阈值：**降级到 `native` 会把密文原样交给用户**
（浏览器下载的是服务端返回的密文，用户拿到的文件解不开）⇒ 降级无意义 ⇒ E2E 一律不降级，
大文件就是大内存。这是协议决定的硬约束（§1.3①），不在本次根治范围。

### 3.6 文件名解析

优先级：`Content-Disposition` 的 `filename*=UTF-8''<pct-encoded>` → `filename="..."` → 调用方兜底名。
`filename*` 需 `decodeURIComponent`；解析失败静默降级到下一优先级，**不抛错**。

## 4. 四条下载路径接入

| 路径 | 文件 | 改法 |
|---|---|---|
| 取件页普通下载 | `views/share/View.vue` | `window.open` → `download()`；按钮下方挂行内进度条 |
| 取件页 E2E 下载 | `views/share/View.vue` | `fetchDecryptSave` → `download({ transform: 解密 })` |
| 取件页打包 zip | `views/share/View.vue` | `window.open` → `download()`，文件名 `{code}.zip` |
| 管理台文件下载 | `views/admin/Files.vue` | axios blob → `download()`；行内挂进度条 |

取件页多文件分享：每个文件行一条**独立**进度（各自一次 `download()` 调用），互不干扰。

## 5. 上传侧三处补齐

### 5.1 presign 行内进度（>100MB 大文件）

- `useUploadQueue` 的 `opts.presign` 签名扩为
  `(file: File, settings: ShareSettings, onProgress?: (p: PresignPhase) => void) => Promise<PresignCompleteData>`
- `PresignUploadDialog.open()` 接受 `onProgress`，把内部 PUT 的**原始** `loaded/total` 与阶段
  （`init` / `put` / `complete`）转发出去。
  ⚠️ 对外回调给**原始字节数**，不传 dialog 内部那套 0-95/97-100 的折算——折算由调用方做。
- 队列侧：`task.progress = round(loaded / total * 100)`，`task.statusText = t('upload.uploading')`。
- 弹窗本身**保留不动**（用户看得见大文件上传状态）。

### 5.2 multi-direct 假百分比 → 批次总进度条

按 §1.3③，删掉逐行均摊。改法：
- 文件列表**顶部**加一条**批次总进度条**（真聚合 %，来自 XHR 聚合 `loaded/total`）。
  ⚠️ 该条**只在 `multi-direct` 通道出现**——它是唯一拿不到逐文件真进度的通道。
- `multi-direct` 的各任务行**不再显示百分比**，只保留状态文字（排队中 / 上传中 / 已完成）。
- 其余通道（`direct` / `presign` / `multi-chunk`）**维持行内百分比不变**——
  它们的百分比本来就是逐文件真进度（`multi-chunk` 是逐文件串行上传，每行各自有准数）。

### 5.3 E2E 加密阶段 0%

`encrypting` 状态下 `task.progress` 恒 0 ⇒ 1.35GB 加密几十秒界面零反馈。
改用 `el-progress` 的 `indeterminate` 脉冲态（Element Plus 2.13.4 支持）。

## 6. 展示形态：就地

- **上传**：维持文件列表行内 `el-progress`（+ §5.1 / §5.3 的修正）。
- **下载**：下载按钮**下方**一条行内 `el-progress`，配文字：百分比 + 速度 + 剩余时间。
- **降级到 `native`**：进度条换成一行提示「已移交浏览器下载」+ 体积，**不渲染假百分比**。

i18n 新增 `download.*` 段（zh-CN + en-US 对齐）：
`preparing` / `downloading` / `decrypting` / `saving` / `handedOff` / `unknownSize` /
`cancelled` / `failed` / `speed` / `eta` / `done`。

## 7. 测试

**单测（vitest，`src/utils/__tests__/downloader.spec.ts`）**
- 落盘档位判定：fs 可用 ⇒ `fs`；无 fs + 小体积 ⇒ `blob`；无 fs + 超限 ⇒ `native`；无 `Content-Length` ⇒ 按未知体积处理
- 阈值边界：恰好等于 `MEMORY_SINK_LIMIT` 的归属
- 文件名解析：`filename*` / `filename` / 兜底 三级优先级；`filename*` 需解码
- 进度计算：`percent` 钳位 0-100、`total=0` 时 `percent=-1`、ETA 为 `null`、速度单调
- 降级触发：fetch 失败 ⇒ 降级 `native`；`transform` 抛错 ⇒ **不降级**、直接报错
- 用户取消保存 ⇒ 零 fetch 调用

**e2e（playwright，`e2e/`）**
- mock fetch 驱动下载，断言 % 回调序列单调、最终落盘文件名正确
- 取件页下载按钮旁出现行内进度条

## 8. 明确不在本次范围

| 项 | 原因 |
|---|---|
| 断点续传 / Range | 服务端已支持（`OpenShareDownloadRange`），但 YAGNI，本次不接 |
| E2E 大文件内存根治 | 需改协议为分块密文 + 服务端配合，跨仓大改 |
| E2E **上传**侧 `encryptFile` 全量内存峰值 | 1.35GB ⇒ 峰值约 2.7GB；与「百分比」正交，另案 |
| multi-direct 逐文件真进度 | 需后端改成分文件上传（跨仓） |
| `core` / `contracts` / `server` 任何改动 | 本次纯前端 |

## 9. 行为变化（需知悉）

**普通下载在 Chrome/Edge 下会多一个「保存文件」对话框**（`showSaveFilePicker` 必须由用户手势触发，无法省）。
Firefox / Safari 无此 API ⇒ 走 `blob` 档（无对话框，小文件有 %，大文件降级原生）。
这是「全量接管」的固有代价，已在拍板时知悉。

## 10. 交付物位置

| 类型 | 路径 |
|---|---|
| 设计文档（本稿） | `PigeonBox/docs/specs/2026-11-03-upload-download-progress-design.md` |
| 实施计划 | `PigeonBox/docs/superpowers/plans/2026-11-03-upload-download-progress.md` |
| 代码 | `PigeonBox/frontend-core/`（独立仓，单独提 PR） |
