# 上传/下载百分比 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐上传侧三处进度缺口，并新增统一下载器让四条下载路径都在页面内显示真实百分比。

**Architecture:** 上传侧只改 `frontend-core` 现有编排层（`useUploadQueue` + `PresignUploadDialog` + `FileItemRow`），把已有的真进度透出来、删掉一处失真的假百分比。下载侧新增 `src/utils/downloader.ts` 单一出口，按「文件系统流式写盘 / 内存 blob / 原生降级」三档落盘，四条下载路径共用；UI 侧由 `useDownloadProgress` composable + `DownloadButton.vue` 组件承载就地进度条。

**Tech Stack:** Vue 3 + TypeScript + Element Plus 2.13.4 · vitest 5（node 环境，无 jsdom）· Playwright 1.64（e2e）

**设计文档：** `PigeonBox/docs/specs/2026-11-03-upload-download-progress-design.md`

## Global Constraints

- **后端零改动**：`core` / `contracts` / `server` / `p2p` 一行都不碰。本计划只改 `PigeonBox/frontend-core/`。
- **改动仓**：`PigeonBox/frontend-core/` 是独立 git 仓，自成一个 PR；设计文档与本计划留在 hub 仓 `PigeonBox/`。
- **vitest 环境是 node**（`vite.config.ts` 只设了 `include`，未设 `environment` ⇒ 默认 node）。⇒ **DOM 能力必须走可注入的 seam**，测试里注入假实现；不要在模块顶层访问 `window`/`document`。
- **部署前缀**：`src/utils/base.ts` 的 `withBase()` 必须用于根绝对路径（统一网关 `/app/pigeonbox/` 部署下漏前缀 ⇒ 404；`views/admin/Files.vue:792-796` 已踩过这个坑）。
- **E2E 是 AES-256-GCM**（`src/utils/e2e.ts`）⇒ 不可增量解密 ⇒ E2E 下载固定走内存档，内存 = 文件体积（与现状持平）。
- **`multi-direct` 是单 multipart 请求** ⇒ 只有聚合进度 ⇒ 逐文件百分比是假的，必须删。
- **真数字只出现在真准确的地方**：拿不到真进度就降级展示，不编数字。
- **i18n 双语同步**：每个新键必须同时加 `src/i18n/locales/zh-CN.ts` 与 `en-US.ts`。
- 现有测试全绿是前提：`cd PigeonBox/frontend-core && npm test`。

---

## File Structure

| 文件 | 责任 |
|---|---|
| `src/utils/downloader.ts` **（新建）** | 下载器唯一出口：类型、三档落盘判定、文件名解析、进度计算、流式读取、降级与取消 |
| `src/utils/__tests__/downloader.spec.ts` **（新建）** | 下载器单测（纯逻辑 + 用注入 seam 驱动的流程） |
| `src/composables/useDownloadProgress.ts` **（新建）** | 把下载器进度包成 Vue 响应式状态（单任务一份，供每个下载按钮各持一份） |
| `src/composables/__tests__/useDownloadProgress.spec.ts` **（新建）** | composable 单测 |
| `src/components/download/DownloadButton.vue` **（新建）** | 就地进度条下载按钮（取件页与管理台共用） |
| `src/api/presign.ts`（改） | 新增 `PresignUploadPhase` / `PresignUploadProgress` 类型（进度透出的共享契约） |
| `src/components/upload/PresignUploadDialog.vue`（改） | 把内部 PUT 的原始进度与阶段透给调用方 |
| `src/composables/useUploadQueue.ts`（改） | presign 分支订阅进度；multi-direct 改批次总进度 + 标 `percentValid=false`；新增 `batchProgress` |
| `src/components/upload/FileItemRow.vue`（改） | `encrypting` 态用不确定态进度条；`percentValid=false` 时不渲染行内百分比 |
| `src/components/upload/FileUpload.vue`（改） | 顶部批次总进度条；presign 回调接线 |
| `src/views/share/View.vue`（改） | 三条下载路径（普通 / E2E / 打包 zip）接入统一下载器 |
| `src/views/admin/Files.vue`（改） | 管理台文件下载接入统一下载器 |
| `src/i18n/locales/zh-CN.ts` / `en-US.ts`（改） | 新增 `download.*` 段 + `upload.batchProgress` |
| `e2e/support/mock-api.ts`（改） | mock 支持二进制响应（下载进度 e2e 需要） |
| `e2e/download.spec.ts` **（新建）** | 下载进度 e2e |

**接口契约（后续任务据此接线，名字不得改）：**

```ts
// src/utils/downloader.ts
export type DownloadSink = 'fs' | 'blob' | 'native'
export type DownloadPhase = 'preparing' | 'downloading' | 'transforming' | 'saving' | 'done' | 'handed-off'
export interface DownloadProgress {
  loaded: number
  total: number          // 0 = 未知
  percent: number        // 0-100；total 未知时为 -1
  bytesPerSecond: number
  etaSeconds: number | null
  phase: DownloadPhase
}
export interface DownloadRequest {
  url: string
  filename: string
  headers?: Record<string, string>
  signal?: AbortSignal
  transform?: (bytes: ArrayBuffer) => Promise<ArrayBuffer>
  onProgress?: (p: DownloadProgress) => void
}
export interface DownloadOutcome { sink: DownloadSink; bytes: number; handedOff: boolean }
export interface FsWritable { write(chunk: Uint8Array): Promise<void>; close(): Promise<void>; abort?(): Promise<void> }
export interface FsTarget { writable: FsWritable; remove(): Promise<void> }
export interface DownloaderEnv {
  fetchImpl: typeof fetch
  hasFsApi: boolean
  pickTarget?: (suggestedName: string) => Promise<FsTarget | null>
  saveBlob: (blob: Blob, filename: string) => void
  nativeDownload: (url: string, filename: string) => void
}
export const MEMORY_SINK_LIMIT: number
export function parseContentDispositionFilename(header: string | null | undefined): string | null
export function computeProgress(loaded: number, total: number, startedAt: number, now: number): { percent: number; bytesPerSecond: number; etaSeconds: number | null }
export function pickSink(hasFsApi: boolean, total: number, limit?: number): DownloadSink
export function resolveDownloadUrl(url: string): string
export async function download(req: DownloadRequest, env?: Partial<DownloaderEnv>): Promise<DownloadOutcome>
export class DownloadCancelledError extends Error { code: -1 }

// src/api/presign.ts
export type PresignUploadPhase = 'init' | 'put' | 'complete'
export interface PresignUploadProgress { phase: PresignUploadPhase; loaded: number; total: number }
```

---

### Task 1: 下载器的纯逻辑层（文件名解析 / 进度计算 / 档位判定 / URL 前缀）

**Files:**
- Create: `PigeonBox/frontend-core/src/utils/downloader.ts`
- Test: `PigeonBox/frontend-core/src/utils/__tests__/downloader.spec.ts`

**Interfaces:**
- Consumes: `withBase(path: string): string` from `@/utils/base`
- Produces: `parseContentDispositionFilename` / `computeProgress` / `pickSink` / `resolveDownloadUrl` / `MEMORY_SINK_LIMIT` 与全部类型声明（见上方契约块）

- [ ] **Step 1: 写失败测试**

创建 `PigeonBox/frontend-core/src/utils/__tests__/downloader.spec.ts`：

```ts
import { describe, expect, it, afterEach } from 'vitest'
import {
  MEMORY_SINK_LIMIT,
  computeProgress,
  parseContentDispositionFilename,
  pickSink,
  resolveDownloadUrl,
} from '@/utils/downloader'
import { resetBaseCache } from '@/utils/base'

const setLocation = (pathname: string) => {
  ;(globalThis as { window?: unknown }).window = { location: { pathname } }
  resetBaseCache()
}

afterEach(() => setLocation('/'))

describe('parseContentDispositionFilename', () => {
  it('优先取 filename* 的 UTF-8 百分号编码名并解码', () => {
    expect(parseContentDispositionFilename("attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87.txt"))
      .toBe('中文.txt')
  })

  it('filename* 解析失败时降级到 filename', () => {
    expect(parseContentDispositionFilename("attachment; filename*=UTF-8''%E4%zz; filename=\"fallback.txt\""))
      .toBe('fallback.txt')
  })

  it('只有 filename 时取它（含引号包裹）', () => {
    expect(parseContentDispositionFilename('attachment; filename="plain.txt"')).toBe('plain.txt')
  })

  it('无 filename 段时返回 null', () => {
    expect(parseContentDispositionFilename('attachment')).toBeNull()
    expect(parseContentDispositionFilename(null)).toBeNull()
    expect(parseContentDispositionFilename(undefined)).toBeNull()
  })

  it('不会把 filename* 误当成 filename', () => {
    expect(parseContentDispositionFilename("attachment; filename*=UTF-8''a.txt")).toBe('a.txt')
  })
})

describe('computeProgress', () => {
  it('total 已知时给出百分比并钳位 0-100', () => {
    expect(computeProgress(50, 100, 0, 1000).percent).toBe(50)
    expect(computeProgress(150, 100, 0, 1000).percent).toBe(100)
    expect(computeProgress(-5, 100, 0, 1000).percent).toBe(0)
  })

  it('total 未知时 percent 为 -1（不确定态）', () => {
    expect(computeProgress(500, 0, 0, 1000).percent).toBe(-1)
  })

  it('按耗时算速度与剩余时间', () => {
    const r = computeProgress(1000, 4000, 0, 2000)
    expect(r.bytesPerSecond).toBe(500)
    expect(r.etaSeconds).toBe(6)
  })

  it('零耗时或零速度时 ETA 为 null', () => {
    expect(computeProgress(1000, 4000, 0, 0).etaSeconds).toBeNull()
    expect(computeProgress(0, 4000, 0, 1000).etaSeconds).toBeNull()
  })
})

describe('pickSink', () => {
  it('有文件系统 API 一律走 fs（内存零占用）', () => {
    expect(pickSink(true, 0)).toBe('fs')
    expect(pickSink(true, 999 * 1024 * 1024)).toBe('fs')
  })

  it('无文件系统 API：体积超限走 native，否则走 blob', () => {
    expect(pickSink(false, 10)).toBe('blob')
    expect(pickSink(false, MEMORY_SINK_LIMIT)).toBe('blob')
    expect(pickSink(false, MEMORY_SINK_LIMIT + 1)).toBe('native')
  })

  it('体积未知时先按 blob 试（超限再降级）', () => {
    expect(pickSink(false, 0)).toBe('blob')
  })
})

describe('resolveDownloadUrl', () => {
  it('绝对 URL 原样返回（服务端下发的 download_url）', () => {
    expect(resolveDownloadUrl('https://host.example/share/download?code=AB12CD&token=TK'))
      .toBe('https://host.example/share/download?code=AB12CD&token=TK')
  })

  it('根绝对路径补部署前缀（统一网关 /app/pigeonbox/ 场景）', () => {
    setLocation('/app/pigeonbox/')
    expect(resolveDownloadUrl('/share/download?code=AB12CD')).toBe('/app/pigeonbox/share/download?code=AB12CD')
  })

  it('根路径部署时前缀为空', () => {
    setLocation('/')
    expect(resolveDownloadUrl('/share/download?code=AB12CD')).toBe('/share/download?code=AB12CD')
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd PigeonBox/frontend-core && npx vitest run src/utils/__tests__/downloader.spec.ts
```
Expected: FAIL —— `Failed to resolve import "@/utils/downloader"`（文件还不存在）

- [ ] **Step 3: 实现纯逻辑层**

创建 `PigeonBox/frontend-core/src/utils/downloader.ts`：

```ts
/**
 * 统一下载器（2026-11-03）——四条下载路径（取件页普通 / 取件页 E2E / 打包 zip /
 * 管理台文件）的唯一出口。
 *
 * 设计要点（详见 PigeonBox/docs/specs/2026-11-03-upload-download-progress-design.md）：
 * 1. **三档落盘**：fs（文件系统 API 流式写盘，内存零占用）/ blob（内存）/ native
 *    （退回浏览器原生下载，页面内无 %）。fs 档的存在是为了让大文件下载不爆内存。
 * 2. **先取保存句柄、再发请求**：showSaveFilePicker 受 transient activation 约束，
 *    必须在用户点击的同步链内调用 ⇒ 用户取消保存则一个字节都不会下载。
 * 3. **降级链**：fetch 失败（跨域 S3 未开 CORS / 网络）⇒ 关闭并删除已建空文件 ⇒
 *    退回 native。**transform 失败不降级**（降级会把密文交给用户，无意义）。
 * 4. **DOM 能力走可注入 seam**：本仓 vitest 跑在 node 环境（无 DOM），
 *    且各浏览器能力差异大 ⇒ 能力探测与落地动作全部走 env 参数，默认实现才碰 DOM。
 */
import { withBase } from '@/utils/base'

export type DownloadSink = 'fs' | 'blob' | 'native'

export type DownloadPhase =
  | 'preparing'
  | 'downloading'
  | 'transforming'
  | 'saving'
  | 'done'
  | 'handed-off'

export interface DownloadProgress {
  loaded: number
  /** 服务端未给 Content-Length 时为 0（不确定态） */
  total: number
  /** 0-100；total 未知时为 -1（调用方渲染不确定态） */
  percent: number
  bytesPerSecond: number
  etaSeconds: number | null
  phase: DownloadPhase
}

export interface DownloadRequest {
  url: string
  /** 兜底文件名；服务端 Content-Disposition 优先（仅 blob 档能拿到） */
  filename: string
  headers?: Record<string, string>
  signal?: AbortSignal
  /** 后处理（E2E 解密）。仅内存档可用——流式写盘无法在解密后改写 */
  transform?: (bytes: ArrayBuffer) => Promise<ArrayBuffer>
  onProgress?: (p: DownloadProgress) => void
}

export interface DownloadOutcome {
  sink: DownloadSink
  bytes: number
  /** true = 已移交浏览器原生下载，页面内没有百分比 */
  handedOff: boolean
}

/** 文件系统写入句柄（只声明用到的最小面，避免依赖 lib.dom 的最新类型） */
export interface FsWritable {
  write(chunk: Uint8Array): Promise<void>
  close(): Promise<void>
  abort?(): Promise<void>
}

/** fs 档的落地目标：writable 写内容，remove 删掉半截/空文件 */
export interface FsTarget {
  writable: FsWritable
  remove(): Promise<void>
}

export interface DownloaderEnv {
  fetchImpl: typeof fetch
  /** 浏览器是否支持文件系统访问 API */
  hasFsApi: boolean
  /** 取保存目标；返回 null = 用户取消 */
  pickTarget?: (suggestedName: string) => Promise<FsTarget | null>
  /** 内存档落盘 */
  saveBlob: (blob: Blob, filename: string) => void
  /** 降级：交给浏览器原生下载 */
  nativeDownload: (url: string, filename: string) => void
}

/** 内存档体积上限（字节）：超过即降级 native */
export const MEMORY_SINK_LIMIT = 64 * 1024 * 1024

/** 取消错误（与 src/api/_xhr.ts 的 code=-1 约定一致） */
export class DownloadCancelledError extends Error {
  code = -1
  constructor() {
    super('Cancelled')
    this.name = 'DownloadCancelledError'
  }
}

/**
 * 解析 Content-Disposition 里的文件名。
 * 优先级：filename*=UTF-8''<pct-encoded> → filename="..." → null（调用方兜底）。
 * 解析失败**静默降级**到下一优先级，不抛错。
 */
export function parseContentDispositionFilename(header: string | null | undefined): string | null {
  if (!header) return null
  const star = /filename\*\s*=\s*([^']*)'([^']*)'([^;]+)/i.exec(header)
  if (star) {
    try {
      const raw = star[3].trim().replace(/^["']|["']$/g, '')
      const decoded = star[1].toLowerCase().includes('utf-8') ? decodeURIComponent(raw) : raw
      if (decoded) return decoded
    } catch {
      // 百分号解码失败 → 落到 filename 分支
    }
  }
  const plain = /filename\s*=\s*("([^"]*)"|([^;]*))/i.exec(header)
  if (plain) {
    const v = (plain[2] ?? plain[3] ?? '').trim()
    if (v) return v
  }
  return null
}

/** 由已传字节与总字节算百分比 / 速度 / 剩余时间 */
export function computeProgress(
  loaded: number,
  total: number,
  startedAt: number,
  now: number
): { percent: number; bytesPerSecond: number; etaSeconds: number | null } {
  const elapsedSec = Math.max(now - startedAt, 0) / 1000
  const bytesPerSecond = elapsedSec > 0 ? loaded / elapsedSec : 0
  const percent = total > 0 ? Math.min(100, Math.max(0, Math.round((loaded / total) * 100))) : -1
  const etaSeconds =
    total > 0 && bytesPerSecond > 0 ? Math.max(0, Math.round((total - loaded) / bytesPerSecond)) : null
  return { percent, bytesPerSecond, etaSeconds }
}

/** 选落盘档位：fs 优先，其次按体积在 blob / native 之间分 */
export function pickSink(hasFsApi: boolean, total: number, limit: number = MEMORY_SINK_LIMIT): DownloadSink {
  if (hasFsApi) return 'fs'
  if (total > 0 && total > limit) return 'native'
  return 'blob'
}

/** 绝对 URL 原样；根绝对路径补部署前缀（统一网关场景漏前缀会 404） */
export function resolveDownloadUrl(url: string): string {
  if (/^https?:\/\//i.test(url)) return url
  return withBase(url)
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd PigeonBox/frontend-core && npx vitest run src/utils/__tests__/downloader.spec.ts
```
Expected: PASS（4 组 describe 全绿）

- [ ] **Step 5: 提交**

```bash
cd PigeonBox/frontend-core
git add src/utils/downloader.ts src/utils/__tests__/downloader.spec.ts
git commit -m "feat(download): 统一下载器纯逻辑层（文件名解析/进度计算/档位判定/前缀解析）

三档落盘 fs/blob/native 的判定、Content-Disposition 文件名解析（含 filename*
UTF-8 百分号解码）、百分比/速度/ETA 计算、根绝对路径补部署前缀。

DOM 能力全部走可注入 seam（本仓 vitest 是 node 环境无 DOM）。"
```

---

### Task 2: 下载器主流程（流式读取 / 三档落地 / 降级 / 取消）

**Files:**
- Modify: `PigeonBox/frontend-core/src/utils/downloader.ts`
- Test: `PigeonBox/frontend-core/src/utils/__tests__/downloader.spec.ts`

**Interfaces:**
- Consumes: Task 1 的全部导出
- Produces: `download(req: DownloadRequest, env?: Partial<DownloaderEnv>): Promise<DownloadOutcome>`、`DownloadCancelledError`

- [ ] **Step 1: 写失败测试**

在 `PigeonBox/frontend-core/src/utils/__tests__/downloader.spec.ts` 末尾追加（并把首行 import 改成包含 `download` 与 `DownloadCancelledError`）：

```ts
import { describe, expect, it, vi } from 'vitest'
import { download, DownloadCancelledError, type DownloaderEnv, type DownloadRequest } from '@/utils/downloader'

/** 造一个分块可控的 Response（Content-Length 可选） */
const chunkedResponse = (chunks: string[], contentLength?: number) => {
  const encoder = new TextEncoder()
  let i = 0
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (i >= chunks.length) {
        controller.close()
        return
      }
      controller.enqueue(encoder.encode(chunks[i]!))
      i++
    },
  })
  const headers = new Headers()
  if (contentLength !== undefined) headers.set('Content-Length', String(contentLength))
  return new Response(body, { status: 200, headers })
}

const baseEnv = (over: Partial<DownloaderEnv> = {}): DownloaderEnv => ({
  fetchImpl: vi.fn(async () => chunkedResponse(['hello ', 'world'], 11)) as unknown as typeof fetch,
  hasFsApi: false,
  saveBlob: vi.fn(),
  nativeDownload: vi.fn(),
  ...over,
})

describe('download', () => {
  it('blob 档：读完整流并落盘，进度回调单调递增', async () => {
    const saveBlob = vi.fn()
    const seen: number[] = []
    const env = baseEnv({ saveBlob })
    const req: DownloadRequest = {
      url: '/share/download?code=AB12CD',
      filename: 'a.txt',
      onProgress: (p) => seen.push(p.percent),
    }
    const out = await download(req, env)
    expect(out.sink).toBe('blob')
    expect(out.bytes).toBe(11)
    expect(out.handedOff).toBe(false)
    expect(saveBlob).toHaveBeenCalledTimes(1)
    const percents = seen.filter((p) => p >= 0)
    expect(percents.length).toBeGreaterThan(0)
    for (let i = 1; i < percents.length; i++) {
      expect(percents[i]!).toBeGreaterThanOrEqual(percents[i - 1]!)
    }
    expect(seen[seen.length - 1]).toBe(100)
  })

  it('fs 档：先取保存目标再发请求，内容写进 writable', async () => {
    const written: string[] = []
    const remove = vi.fn(async () => {})
    const pickTarget = vi.fn(async () => ({
      writable: {
        write: async (c: Uint8Array) => { written.push(new TextDecoder().decode(c)) },
        close: async () => {},
      },
      remove,
    }))
    const env = baseEnv({ hasFsApi: true, pickTarget })
    const out = await download({ url: '/x', filename: 'a.txt' }, env)
    expect(out.sink).toBe('fs')
    expect(written.join('')).toBe('hello world')
    expect(pickTarget).toHaveBeenCalledTimes(1)
  })

  it('用户取消保存 ⇒ 零请求、零字节', async () => {
    const fetchImpl = vi.fn()
    const env = baseEnv({ hasFsApi: true, pickTarget: async () => null, fetchImpl: fetchImpl as unknown as typeof fetch })
    await expect(download({ url: '/x', filename: 'a.txt' }, env)).rejects.toBeInstanceOf(DownloadCancelledError)
    expect(fetchImpl).not.toHaveBeenCalled()
  })

  it('fetch 失败 ⇒ 删除已建文件并降级 native', async () => {
    const remove = vi.fn(async () => {})
    const nativeDownload = vi.fn()
    const pickTarget = vi.fn(async () => ({
      writable: { write: async () => {}, close: async () => {} },
      remove,
    }))
    const env = baseEnv({
      hasFsApi: true,
      pickTarget,
      nativeDownload,
      fetchImpl: vi.fn(async () => { throw new TypeError('Failed to fetch') }) as unknown as typeof fetch,
    })
    const out = await download({ url: '/x', filename: 'a.txt' }, env)
    expect(out.sink).toBe('native')
    expect(out.handedOff).toBe(true)
    expect(remove).toHaveBeenCalledTimes(1)
    expect(nativeDownload).toHaveBeenCalledTimes(1)
  })

  it('transform 失败 ⇒ 直接报错，不降级 native', async () => {
    const nativeDownload = vi.fn()
    const env = baseEnv({ nativeDownload })
    await expect(
      download(
        { url: '/x', filename: 'a.txt', transform: async () => { throw new Error('口令错误') } },
        env,
      ),
    ).rejects.toThrow('口令错误')
    expect(nativeDownload).not.toHaveBeenCalled()
  })

  it('blob 档累积超限 ⇒ 丢弃缓冲并降级 native', async () => {
    const nativeDownload = vi.fn()
    const saveBlob = vi.fn()
    const big = 'x'.repeat(1024)
    const env = baseEnv({
      saveBlob,
      nativeDownload,
      fetchImpl: vi.fn(async () => chunkedResponse(Array.from({ length: 80 }, () => big), 80 * 1024)) as unknown as typeof fetch,
    })
    const out = await download({ url: '/x', filename: 'a.bin' }, env)
    expect(out.sink).toBe('native')
    expect(saveBlob).not.toHaveBeenCalled()
    expect(nativeDownload).toHaveBeenCalledTimes(1)
  })

  it('blob 档用服务端 Content-Disposition 的文件名（优先于兜底名）', async () => {
    const saveBlob = vi.fn()
    const env = baseEnv({
      saveBlob,
      fetchImpl: vi.fn(async () => {
        const r = chunkedResponse(['x'], 1)
        r.headers.set('Content-Disposition', "attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95.txt")
        return r
      }) as unknown as typeof fetch,
    })
    await download({ url: '/x', filename: 'fallback.txt' }, env)
    expect(saveBlob.mock.calls[0]![1]).toBe('测试.txt')
  })

  it('abort ⇒ 抛 DownloadCancelledError', async () => {
    const controller = new AbortController()
    const env = baseEnv({
      fetchImpl: vi.fn(async () => {
        controller.abort()
        throw new DOMException('Aborted', 'AbortError')
      }) as unknown as typeof fetch,
    })
    await expect(
      download({ url: '/x', filename: 'a.txt', signal: controller.signal }, env),
    ).rejects.toBeInstanceOf(DownloadCancelledError)
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd PigeonBox/frontend-core && npx vitest run src/utils/__tests__/downloader.spec.ts
```
Expected: FAIL —— `download` 未导出

- [ ] **Step 3: 实现主流程**

在 `PigeonBox/frontend-core/src/utils/downloader.ts` 末尾追加：

```ts
/** 进度回报节流（毫秒）：避免大文件每 chunk 都触发 Vue 更新 */
const REPORT_THROTTLE_MS = 80

/** 默认 env：只在浏览器里才碰 DOM（node 环境测试全部走注入） */
function defaultEnv(): DownloaderEnv {
  const w = globalThis as unknown as {
    showSaveFilePicker?: (opts?: { suggestedName?: string }) => Promise<{
      createWritable(): Promise<FsWritable>
      remove(): Promise<void>
    }>
  }
  return {
    fetchImpl: (...args: Parameters<typeof fetch>) => fetch(...args),
    hasFsApi: typeof w.showSaveFilePicker === 'function',
    pickTarget: async (suggestedName: string) => {
      if (!w.showSaveFilePicker) return null
      const handle = await w.showSaveFilePicker({ suggestedName })
      const writable = await handle.createWritable()
      return { writable, remove: () => handle.remove() }
    },
    saveBlob: (blob: Blob, filename: string) => {
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      document.body.appendChild(a)
      a.click()
      a.remove()
      setTimeout(() => URL.revokeObjectURL(url), 10_000)
    },
    nativeDownload: (url: string, filename: string) => {
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.rel = 'noopener'
      document.body.appendChild(a)
      a.click()
      a.remove()
    },
  }
}

const isAbortLike = (e: unknown): boolean =>
  e instanceof Error && (e.name === 'AbortError' || e.message === 'Cancelled' || e.message === 'Aborted')

/**
 * 统一下载入口。
 *
 * 次序（不可调换）：先取保存目标（用户手势同步链内）→ 再发请求 → 选档位 → 流式读取。
 */
export async function download(req: DownloadRequest, env?: Partial<DownloaderEnv>): Promise<DownloadOutcome> {
  const e: DownloaderEnv = { ...defaultEnv(), ...env }
  const url = resolveDownloadUrl(req.url)
  const startedAt = Date.now()

  let loaded = 0
  let total = 0
  let phase: DownloadPhase = 'preparing'
  let lastReportAt = 0

  const report = (force = false) => {
    const now = Date.now()
    if (!force && now - lastReportAt < REPORT_THROTTLE_MS) return
    lastReportAt = now
    const p = computeProgress(loaded, total, startedAt, now)
    req.onProgress?.({
      loaded,
      total,
      phase,
      percent: p.percent,
      bytesPerSecond: p.bytesPerSecond,
      etaSeconds: p.etaSeconds,
    })
  }

  // ① fs 档：保存目标必须在用户手势的同步链内取（transient activation）
  let target: FsTarget | null = null
  if (e.hasFsApi && e.pickTarget) {
    try {
      target = await e.pickTarget(req.filename)
    } catch (err) {
      if (isAbortLike(err)) throw new DownloadCancelledError()
      throw err
    }
    if (!target) throw new DownloadCancelledError()
  }

  const cleanupFs = async () => {
    if (!target) return
    try {
      await target.writable.abort?.()
    } catch {
      // ignore
    }
    try {
      await target.remove()
    } catch {
      // ignore
    }
    target = null
  }

  // ② 发请求
  let resp: Response
  try {
    resp = await e.fetchImpl(url, {
      method: 'GET',
      headers: req.headers,
      signal: req.signal,
      credentials: 'same-origin',
    })
  } catch (err) {
    if (isAbortLike(err) || req.signal?.aborted) {
      await cleanupFs()
      throw new DownloadCancelledError()
    }
    // 降级：网络失败 / 跨域 CORS 未开 ⇒ 交回浏览器原生下载
    await cleanupFs()
    phase = 'handed-off'
    report(true)
    e.nativeDownload(url, req.filename)
    return { sink: 'native', bytes: 0, handedOff: true }
  }

  if (!resp.ok) {
    await cleanupFs()
    const err = new Error(`HTTP ${resp.status}`) as Error & { code: number }
    err.code = resp.status
    throw err
  }

  const contentLength = Number(resp.headers.get('Content-Length') || '') || 0
  total = contentLength
  const serverName = parseContentDispositionFilename(resp.headers.get('Content-Disposition'))
  const finalName = serverName || req.filename

  const sink: DownloadSink = target ? 'fs' : pickSink(false, total)

  // ③ 流式读取
  const chunks: Uint8Array[] = []
  let accumulated = 0
  phase = 'downloading'
  report(true)

  const reader = resp.body?.getReader()
  if (!reader) {
    // 无流式 body 的环境：退回一次性读（仍有 %，只是不增量）
    const buf = await resp.arrayBuffer()
    loaded = buf.byteLength
    total = total || loaded
    chunks.push(new Uint8Array(buf))
    accumulated = loaded
    report(true)
  } else {
    try {
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        if (!value) continue
        loaded += value.byteLength
        if (sink === 'fs') {
          await target!.writable.write(value)
        } else {
          chunks.push(value)
          accumulated += value.byteLength
          if (sink === 'blob' && accumulated > MEMORY_SINK_LIMIT) {
            // 内存档撑不住 ⇒ 丢弃缓冲、降级原生（不落半截文件）
            await reader.cancel().catch(() => {})
            phase = 'handed-off'
            report(true)
            e.nativeDownload(url, req.filename)
            return { sink: 'native', bytes: loaded, handedOff: true }
          }
        }
        report()
      }
    } catch (err) {
      await cleanupFs()
      if (isAbortLike(err) || req.signal?.aborted) throw new DownloadCancelledError()
      throw err
    }
  }

  // ④ 落地
  if (sink === 'fs') {
    phase = 'saving'
    report(true)
    await target!.writable.close()
    target = null
  } else {
    const merged = new Uint8Array(accumulated)
    let offset = 0
    for (const c of chunks) {
      merged.set(c, offset)
      offset += c.byteLength
    }
    const buf = merged.buffer
    if (req.transform) {
      phase = 'transforming'
      report(true)
      const out = await req.transform(buf)
      phase = 'saving'
      report(true)
      e.saveBlob(new Blob([out]), finalName)
    } else {
      phase = 'saving'
      report(true)
      e.saveBlob(new Blob([buf]), finalName)
    }
  }

  phase = 'done'
  report(true)
  return { sink, bytes: loaded, handedOff: false }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd PigeonBox/frontend-core && npx vitest run src/utils/__tests__/downloader.spec.ts
```
Expected: PASS（8 条 download 用例全绿）

- [ ] **Step 5: 提交**

```bash
cd PigeonBox/frontend-core
git add src/utils/downloader.ts src/utils/__tests__/downloader.spec.ts
git commit -m "feat(download): 统一下载器主流程（三档落地/降级/取消）

先取保存目标再发请求（transient activation，用户取消=零字节）；
fs 流式写盘 / blob 内存 / native 降级三档；
fetch 失败降级 native 并删除已建空文件；transform 失败不降级；
blob 档超 MEMORY_SINK_LIMIT 丢弃缓冲降级；文件名优先 Content-Disposition。"
```

---

### Task 3: `useDownloadProgress` composable

**Files:**
- Create: `PigeonBox/frontend-core/src/composables/useDownloadProgress.ts`
- Test: `PigeonBox/frontend-core/src/composables/__tests__/useDownloadProgress.spec.ts`

**Interfaces:**
- Consumes: `download()` / `DownloadProgress` / `DownloadPhase` / `DownloadOutcome` from `@/utils/downloader`
- Produces: `useDownloadProgress(t: (key: string, params?: Record<string, string>) => string)` 返回
  `{ phase, percent, loaded, total, bytesPerSecond, etaSeconds, error, handedOff, busy, run, cancel, reset }`，
  其中 `run(req: Omit<DownloadRequest, 'onProgress' | 'signal'>): Promise<DownloadOutcome | null>`。

- [ ] **Step 1: 写失败测试**

创建 `PigeonBox/frontend-core/src/composables/__tests__/useDownloadProgress.spec.ts`：

```ts
import { describe, expect, it, vi, beforeEach } from 'vitest'

/**
 * ⚠️ 用 vi.mock 工厂而不是 vi.spyOn：`download` 是 ESM 具名导出，
 * 在 vitest 里对 ESM 导出做 spyOn 会抛「not declared configurable」⇒
 * 工厂 mock 才是可靠写法。工厂里用 importActual 保留其余真实导出
 * （DownloadCancelledError 必须是真类，否则 catch 分支判不出来）。
 */
const downloadMock = vi.fn()

vi.mock('@/utils/downloader', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/utils/downloader')>()
  return {
    ...actual,
    download: (...args: unknown[]) => downloadMock(...args),
  }
})

const { useDownloadProgress } = await import('@/composables/useDownloadProgress')
const { DownloadCancelledError } = await import('@/utils/downloader')

const t = (k: string) => k

beforeEach(() => {
  downloadMock.mockReset()
})

describe('useDownloadProgress', () => {
  it('初始态：不确定、百分比 -1、不忙', () => {
    const d = useDownloadProgress(t)
    expect(d.percent.value).toBe(-1)
    expect(d.phase.value).toBe('preparing')
    expect(d.busy.value).toBe(false)
    expect(d.error.value).toBe('')
  })

  it('run 成功 ⇒ phase=done、busy 归 false', async () => {
    downloadMock.mockResolvedValue({ sink: 'blob', bytes: 10, handedOff: false })
    const d = useDownloadProgress(t)
    const out = await d.run({ url: '/x', filename: 'a.txt' })
    expect(downloadMock).toHaveBeenCalledTimes(1)
    expect(out?.bytes).toBe(10)
    expect(d.phase.value).toBe('done')
    expect(d.busy.value).toBe(false)
    expect(d.error.value).toBe('')
  })

  it('progress 回调写入响应式状态', async () => {
    downloadMock.mockImplementation(async (req: { onProgress?: (p: unknown) => void }) => {
      req.onProgress?.({ loaded: 50, total: 100, percent: 50, bytesPerSecond: 100, etaSeconds: 1, phase: 'downloading' })
      return { sink: 'blob', bytes: 100, handedOff: false }
    })
    const d = useDownloadProgress(t)
    await d.run({ url: '/x', filename: 'a.txt' })
    expect(d.percent.value).toBe(50)
    expect(d.loaded.value).toBe(50)
    expect(d.total.value).toBe(100)
    expect(d.etaSeconds.value).toBe(1)
  })

  it('取消 ⇒ error 为取消文案、busy 归 false', async () => {
    downloadMock.mockRejectedValue(new DownloadCancelledError())
    const d = useDownloadProgress(t)
    const out = await d.run({ url: '/x', filename: 'a.txt' })
    expect(out).toBeNull()
    expect(d.error.value).toBe('download.cancelled')
    expect(d.busy.value).toBe(false)
  })

  it('失败 ⇒ error 上屏、busy 归 false', async () => {
    downloadMock.mockRejectedValue(new Error('boom'))
    const d = useDownloadProgress(t)
    const out = await d.run({ url: '/x', filename: 'a.txt' })
    expect(out).toBeNull()
    expect(d.error.value).toBe('download.failed')
    expect(d.busy.value).toBe(false)
  })

  it('handedOff ⇒ phase=handed-off（页面内无百分比，如实呈现）', async () => {
    downloadMock.mockResolvedValue({ sink: 'native', bytes: 0, handedOff: true })
    const d = useDownloadProgress(t)
    await d.run({ url: '/x', filename: 'a.txt' })
    expect(d.handedOff.value).toBe(true)
    expect(d.phase.value).toBe('handed-off')
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd PigeonBox/frontend-core && npx vitest run src/composables/__tests__/useDownloadProgress.spec.ts
```
Expected: FAIL —— `Failed to resolve import "@/composables/useDownloadProgress"`

- [ ] **Step 3: 实现 composable**

创建 `PigeonBox/frontend-core/src/composables/useDownloadProgress.ts`：

```ts
import { ref, computed, type Ref, type ComputedRef } from 'vue'
import {
  download,
  DownloadCancelledError,
  type DownloadOutcome,
  type DownloadPhase,
  type DownloadRequest,
} from '@/utils/downloader'

/**
 * 单个下载任务的进度状态（2026-11-03）。
 *
 * 每个下载按钮各持一份 ⇒ 多文件分享时各行进度互不干扰。
 * 错误文案走 i18n（t 由调用方注入，composable 可脱离组件单测）。
 */
export function useDownloadProgress(t: (key: string, params?: Record<string, string>) => string) {
  const phase = ref<DownloadPhase>('preparing')
  const percent = ref(-1)
  const loaded = ref(0)
  const total = ref(0)
  const bytesPerSecond = ref(0)
  const etaSeconds = ref<number | null>(null)
  const error = ref('')
  const handedOff = ref(false)

  let controller: AbortController | null = null

  /** 进行中（preparing~saving 区间都算忙） */
  const busy = computed(
    () => phase.value !== 'done' && phase.value !== 'handed-off' && error.value === ''
  )

  const reset = () => {
    phase.value = 'preparing'
    percent.value = -1
    loaded.value = 0
    total.value = 0
    bytesPerSecond.value = 0
    etaSeconds.value = null
    error.value = ''
    handedOff.value = false
    controller = null
  }

  const run = async (
    req: Omit<DownloadRequest, 'onProgress' | 'signal'>
  ): Promise<DownloadOutcome | null> => {
    reset()
    controller = new AbortController()
    try {
      const out = await download({
        ...req,
        signal: controller.signal,
        onProgress: (p) => {
          phase.value = p.phase
          percent.value = p.percent
          loaded.value = p.loaded
          total.value = p.total
          bytesPerSecond.value = p.bytesPerSecond
          etaSeconds.value = p.etaSeconds
        },
      })
      handedOff.value = out.handedOff
      if (out.handedOff) phase.value = 'handed-off'
      return out
    } catch (e: unknown) {
      if (e instanceof DownloadCancelledError || (e as { code?: number })?.code === -1) {
        error.value = t('download.cancelled')
      } else {
        error.value = t('download.failed')
      }
      phase.value = 'done'
      return null
    } finally {
      controller = null
    }
  }

  const cancel = () => {
    controller?.abort()
  }

  return {
    phase: phase as Ref<DownloadPhase>,
    percent: percent as Ref<number>,
    loaded: loaded as Ref<number>,
    total: total as Ref<number>,
    bytesPerSecond: bytesPerSecond as Ref<number>,
    etaSeconds: etaSeconds as Ref<number | null>,
    error: error as Ref<string>,
    handedOff: handedOff as Ref<boolean>,
    busy: busy as ComputedRef<boolean>,
    run,
    cancel,
    reset,
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd PigeonBox/frontend-core && npx vitest run src/composables/__tests__/useDownloadProgress.spec.ts
```
Expected: PASS（6 条全绿）

- [ ] **Step 5: 提交**

```bash
cd PigeonBox/frontend-core
git add src/composables/useDownloadProgress.ts src/composables/__tests__/useDownloadProgress.spec.ts
git commit -m "feat(download): useDownloadProgress composable——单任务进度状态

每个下载按钮各持一份，多文件分享各行进度互不干扰；错误文案走注入的 t。"
```

---

### Task 4: `DownloadButton.vue` 就地进度条组件

**Files:**
- Create: `PigeonBox/frontend-core/src/components/download/DownloadButton.vue`

**Interfaces:**
- Consumes: `useDownloadProgress(t)` from `@/composables/useDownloadProgress`
- Produces: 组件 `DownloadButton`，props `{ url: string; filename: string; label?: string; disabled?: boolean; headers?: Record<string, string>; transform?: (b: ArrayBuffer) => Promise<ArrayBuffer> }`，emits `{ done: [DownloadOutcome]; error: [string] }`

- [ ] **Step 1: 创建组件**

创建 `PigeonBox/frontend-core/src/components/download/DownloadButton.vue`：

```vue
<template>
  <div class="download-btn-wrap">
    <el-button
      :disabled="disabled || busy"
      :loading="busy"
      :size="size || 'default'"
      class="dl-btn"
      @click="onClick"
    >
      <el-icon><Download /></el-icon>
      {{ label || t('common.download') }}
    </el-button>

    <!-- 进度条：就地挂在按钮下方（不弹窗、不打断当前页面） -->
    <div v-if="visible" class="dl-progress">
      <el-progress
        :percentage="percent >= 0 ? percent : 0"
        :indeterminate="percent < 0"
        :stroke-width="4"
        :show-text="false"
        :status="error ? 'exception' : ''"
      />
      <div class="dl-meta">
        <span v-if="error" class="dl-error">{{ error }}</span>
        <span v-else-if="handedOff" class="dl-handoff">{{ t('download.handedOff') }}</span>
        <span v-else class="dl-status">{{ statusText }}</span>
        <span v-if="!error && !handedOff && bytesPerSecond > 0" class="dl-speed">
          {{ t('download.speed', { speed: formatSpeed(bytesPerSecond) }) }}
        </span>
        <span v-if="!error && !handedOff && etaSeconds !== null" class="dl-eta">
          {{ t('download.eta', { time: formatDuration(etaSeconds) }) }}
        </span>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { Download } from '@element-plus/icons-vue'
import { useDownloadProgress } from '@/composables/useDownloadProgress'
import type { DownloadOutcome } from '@/utils/downloader'

/**
 * 就地进度条下载按钮（2026-11-03）。
 *
 * ⚠️ **onClick 里第一句就调 download()**：文件系统 API 的 showSaveFilePicker 受
 * transient activation 约束 ⇒ 必须在用户手势的同步链内发起 ⇒ 中间任何 await
 * 都可能让 activation 失效（保存对话框弹不出来）。
 */
const props = defineProps<{
  url: string
  filename: string
  label?: string
  disabled?: boolean
  /** 按钮尺寸（对齐 Element Plus） */
  size?: 'small' | 'default' | 'large'
  headers?: Record<string, string>
  transform?: (bytes: ArrayBuffer) => Promise<ArrayBuffer>
}>()

const emit = defineEmits<{ done: [DownloadOutcome]; error: [string] }>()

const { t } = useI18n()
const dl = useDownloadProgress(t)

const busy = dl.busy
const percent = dl.percent
const error = dl.error
const handedOff = dl.handedOff
const bytesPerSecond = dl.bytesPerSecond
const etaSeconds = dl.etaSeconds

/** 进度条只在「进行中 / 出错 / 已移交」时出现——空闲时不占版面 */
const visible = computed(() => dl.phase.value !== 'preparing' || !!dl.error.value)

const statusText = computed(() => {
  switch (dl.phase.value) {
    case 'preparing':
      return t('download.preparing')
    case 'transforming':
      return t('download.decrypting')
    case 'saving':
      return t('download.saving')
    case 'downloading':
      return dl.total.value > 0
        ? t('download.downloading')
        : t('download.unknownSize')
    default:
      return t('download.done')
  }
})

const formatSpeed = (bps: number): string => {
  const mb = bps / (1024 * 1024)
  return mb >= 1 ? `${mb.toFixed(1)} MB/s` : `${Math.max(1, Math.round(bps / 1024))} KB/s`
}

const formatDuration = (sec: number): string => {
  if (sec < 60) return `${sec}s`
  const m = Math.floor(sec / 60)
  return `${m}m${String(sec % 60).padStart(2, '0')}s`
}

const onClick = async () => {
  // ⚠️ 同步链第一句：见文件头注释
  const p = dl.run({
    url: props.url,
    filename: props.filename,
    headers: props.headers,
    transform: props.transform,
  })
  const out = await p
  if (out) emit('done', out)
  else if (dl.error.value) emit('error', dl.error.value)
}
</script>

<style scoped>
.download-btn-wrap {
  display: inline-flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
}

.dl-progress {
  min-width: 160px;
}

.dl-meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--color-text-secondary);
  margin-top: 4px;
}

.dl-error { color: var(--color-danger); }
.dl-handoff { color: var(--color-text-secondary); }
.dl-status { color: var(--color-text-regular); }
</style>
```

- [ ] **Step 2: 跑类型检查**

```bash
cd PigeonBox/frontend-core && npm run typecheck
```
Expected: PASS（无 error）。若报 `el-progress` 的 `indeterminate` 属性不存在，说明 element-plus 类型版本偏旧 ⇒ 改用 `:indeterminate` 的 kebab 写法 `<el-progress indeterminate ...>` 并在 tsconfig 的 `vueCompilerOptions` 关闭严格模板检查（**不要**改 element-plus 版本）。

- [ ] **Step 3: 提交**

```bash
cd PigeonBox/frontend-core
git add src/components/download/DownloadButton.vue
git commit -m "feat(download): DownloadButton——就地进度条下载按钮

按钮下方挂行内进度条（百分比/速度/剩余时间）；降级到浏览器原生下载时
如实显示「已移交浏览器下载」而不假装有百分比。
onClick 首句即调 download()：showSaveFilePicker 需要 transient activation。"
```

---

### Task 5: i18n 新键（zh-CN + en-US）

**Files:**
- Modify: `PigeonBox/frontend-core/src/i18n/locales/zh-CN.ts`
- Modify: `PigeonBox/frontend-core/src/i18n/locales/en-US.ts`

**Interfaces:**
- Consumes: Task 3 / Task 4 引用的键名
- Produces: `download.*` 段 + `upload.batchProgress`

- [ ] **Step 1: 加中文键**

在 `PigeonBox/frontend-core/src/i18n/locales/zh-CN.ts` 的顶层 `share: {` **之前**插入：

```ts
  download: {
    preparing: '准备中…',
    downloading: '下载中',
    decrypting: '解密中…',
    saving: '正在保存…',
    done: '下载完成',
    handedOff: '已移交浏览器下载',
    unknownSize: '大小未知',
    cancelled: '下载已取消',
    failed: '下载失败',
    speed: '{speed}/s',
    eta: '剩余 {time}',
  },
```

并在 `upload: {` 段内追加一行：

```ts
    batchProgress: '本批上传中 {percent}%',
```

- [ ] **Step 2: 加英文键**

在 `PigeonBox/frontend-core/src/i18n/locales/en-US.ts` 的顶层 `share: {` **之前**插入：

```ts
  download: {
    preparing: 'Preparing…',
    downloading: 'Downloading',
    decrypting: 'Decrypting…',
    saving: 'Saving…',
    done: 'Download complete',
    handedOff: 'Handed off to browser download',
    unknownSize: 'Size unknown',
    cancelled: 'Download cancelled',
    failed: 'Download failed',
    speed: '{speed}/s',
    eta: '{time} left',
  },
```

并在 `upload: {` 段内追加：

```ts
    batchProgress: 'Uploading batch {percent}%',
```

- [ ] **Step 3: 校验两语言键集合一致**

```bash
cd PigeonBox/frontend-core && npx vitest run src/utils/__tests__/orphanExports.spec.ts
```
Expected: PASS（该用例覆盖 i18n 孤儿键检查；若它只查反向，改为手工核对两文件 `download` 段键数一致）

- [ ] **Step 4: 提交**

```bash
cd PigeonBox/frontend-core
git add src/i18n/locales/zh-CN.ts src/i18n/locales/en-US.ts
git commit -m "feat(i18n): download.* 段与 upload.batchProgress（zh-CN + en-US 对齐）"
```

---

### Task 6: 取件页三条下载路径接入统一下载器

**Files:**
- Modify: `PigeonBox/frontend-core/src/views/share/View.vue`
- Test: `PigeonBox/frontend-core/e2e/download.spec.ts`（本任务先建空壳，Task 11 补齐断言）

**Interfaces:**
- Consumes: `DownloadButton.vue`（Task 4）、`download()` / `decryptBytes`（既有）
- Produces: 取件页三处下载按钮改用 `DownloadButton`

- [ ] **Step 1: 改 script 段**

在 `PigeonBox/frontend-core/src/views/share/View.vue` 的 `<script setup>` 里：

1. 引入组件与解密函数（在既有 import 区追加）：

```ts
import DownloadButton from '@/components/download/DownloadButton.vue'
import { decryptBytes } from '@/utils/e2e'
```

2. **删除** `fetchDecryptSave`（约 465-486 行）整个函数，替换为：

```ts
/**
 * E2E 解密器：统一下载器的 transform 钩子。
 *
 * ⚠️ AES-256-GCM **不可增量解密**（认证需要完整密文+tag）⇒ 只能整块解密
 * ⇒ 内存占用 = 文件体积（与现状持平，不新增内存风险）。
 */
const e2eTransform = async (buf: ArrayBuffer): Promise<ArrayBuffer> => {
  const key = e2eKey.value
  if (!key) throw new Error(t('share.keyMissingParam'))
  return decryptBytes(key, buf)
}

/** 下载失败提示（行内错误组件已展示，这里只做全局兜底） */
const onDownloadError = (msg: string) => {
  ElMessage.error(msg)
}

/** 下载地址（复用既有 buildDownloadUrl；口令保护且无直链时返回空串 ⇒ 按钮不渲染） */
const downloadUrlFor = (fileId?: number): string => buildDownloadUrl(fileId)

/** 下载文件名：行内给定名 > 分享文件名 > 取件码兜底 */
const downloadNameFor = (fileId?: number, name?: string): string =>
  name || shareData.value?.file_name || `${canonicalCode.value || shareCode.value}.bin`
```

3. **删除** `downloadFile`（约 488-511 行）整个函数——下载动作已由 `DownloadButton` 内部发起，
   不再需要页面级 `downloadFile`。

4. **删除** `downloadAll`（约 514 行起）里 `window.open` 的部分，替换为：

```ts
/** 打包下载（多文件分享；服务端流式 zip。E2E 分享服务端无法打包，按钮已隐藏） */
const downloadAllUrl = computed(() => buildDownloadUrl())
const downloadAllName = computed(() => `${canonicalCode.value || shareCode.value}.zip`)
```

5. **删除** `isEncrypted` 分支里的 `fetchDecryptSave` 调用（该分支已被组件的
   `transform` 钩子接管）；`isEncrypted` / `e2eKey` / `needE2ePassword` 等判定保持不变
   （仍用于决定是否要求用户输入口令）。

- [ ] **Step 2: 改单文件卡片的下载按钮**

把 `views/share/View.vue` 约 167 行处的：

```vue
              <el-button v-if="!downloadBlocked" type="primary" size="large" class="download-btn" @click="downloadFile()">
                <el-icon><Download /></el-icon>
                {{ t('share.downloadFile') }}
              </el-button>
```

替换为：

```vue
              <DownloadButton
                v-if="!downloadBlocked"
                size="large"
                class="download-btn"
                :url="downloadUrlFor()"
                :filename="downloadNameFor()"
                :label="t('share.downloadFile')"
                :transform="isEncrypted ? e2eTransform : undefined"
                @error="onDownloadError"
              />
```

- [ ] **Step 3: 改多文件列表的下载按钮**

把约 146 行处的：

```vue
                  <el-button v-if="!downloadBlocked" size="small" text type="primary" :loading="e2eBusy" @click="downloadFile(f.id, f.name)">
                    <el-icon><Download /></el-icon>
                    {{ t('common.download') }}
                  </el-button>
```

替换为：

```vue
                  <DownloadButton
                    v-if="!downloadBlocked"
                    size="small"
                    :url="downloadUrlFor(f.id)"
                    :filename="downloadNameFor(f.id, f.name)"
                    :label="t('common.download')"
                    @error="onDownloadError"
                  />
```

- [ ] **Step 4: 改打包下载按钮**

把约 131 行处的：

```vue
                <el-button
                  v-if="!shareData.encrypted && !downloadBlocked"
                  type="primary"
                  class="download-btn"
                  @click="downloadAll"
                >
                  <el-icon><Download /></el-icon>
                  {{ t('share.zipDownload') }}
                </el-button>
```

替换为：

```vue
                <DownloadButton
                  v-if="!shareData.encrypted && !downloadBlocked"
                  size="large"
                  class="download-btn"
                  :url="downloadAllUrl"
                  :filename="downloadAllName"
                  :label="t('share.zipDownload')"
                  @error="onDownloadError"
                />
```

- [ ] **Step 5: 清理不再使用的引用**

跑 `npm run typecheck`，按报错清掉 `downloadFile` / `downloadAll` / `fetchDecryptSave`
删除后遗留的未使用 import（如 `Download` 图标若已无引用则删）。

- [ ] **Step 6: 跑类型检查与构建**

```bash
cd PigeonBox/frontend-core && npm run typecheck && npm run build
```
Expected: 两个都 PASS

- [ ] **Step 5: 提交**

```bash
cd PigeonBox/frontend-core
git add src/views/share/View.vue
git commit -m "feat(download): 取件页三条下载路径接入统一下载器

普通下载 / E2E 下载 / 打包 zip 全部改走 DownloadButton ⇒ 页面内有百分比。
E2E 经 transform 钩子整块解密（AES-GCM 不可增量），内存与现状持平。"
```

---

### Task 7: 管理台文件下载接入

**Files:**
- Modify: `PigeonBox/frontend-core/src/views/admin/Files.vue`

**Interfaces:**
- Consumes: `DownloadButton.vue`（Task 4）、`adminApi.fileDownloadUrl`
- Produces: 管理台文件行下载按钮改用 `DownloadButton`

- [ ] **Step 1: 替换下载按钮**

把 `views/admin/Files.vue` 第 306 行附近的：

```vue
            <el-button v-if="!row.is_text" size="small" round @click="downloadFile(row)">{{ t('admin.filesPage.download') }}</el-button>
```

替换为：

```vue
            <DownloadButton
              v-if="!row.is_text"
              size="small"
              :url="adminApi.fileDownloadUrl(row.id)"
              :filename="row.file_name || `${row.code}.bin`"
              :label="t('admin.filesPage.download')"
              @error="onDownloadError"
            />
```

（第 240 行附近若还有一处同名按钮，一并替换。）

- [ ] **Step 2: 改 script 段**

在 `views/admin/Files.vue` 的 `<script setup>` 里：

1. 引入组件：

```ts
import DownloadButton from '@/components/download/DownloadButton.vue'
```

2. 把 `downloadFile`（约 788-814 行）整个函数替换为：

```ts
/**
 * 管理端下载：/admin/files/:id 受 AdminMiddleware 保护，window.open 带不上凭证
 * —— 统一下载器走 fetch（同源自动带 Cookie），并能显示百分比。
 *
 * ⚠️ 2026-10-26 审计修复的要点**不能丢**：裸 axios 走浏览器根路径、不带部署前缀
 * ⇒ 统一网关（/app/pigeonbox/）下必然 404。统一下载器内部用 withBase() 补前缀，
 * 等价于统一实例的 baseURL 行为。
 */
const onDownloadError = (msg: string) => {
  ElMessage.error(msg)
}
```

3. 确认 `adminApi` 已在该文件 import（若无则补 `import { adminApi } from '@/api/admin'`）。

- [ ] **Step 3: 跑类型检查与构建**

```bash
cd PigeonBox/frontend-core && npm run typecheck && npm run build
```
Expected: PASS

- [ ] **Step 4: 提交**

```bash
cd PigeonBox/frontend-core
git add src/views/admin/Files.vue
git commit -m "feat(download): 管理台文件下载接入统一下载器（带前缀 + 有百分比）"
```

---

### Task 8: 上传侧 —— presign 行内进度透出

**Files:**
- Modify: `PigeonBox/frontend-core/src/api/presign.ts`
- Modify: `PigeonBox/frontend-core/src/components/upload/PresignUploadDialog.vue`
- Modify: `PigeonBox/frontend-core/src/composables/useUploadQueue.ts`
- Modify: `PigeonBox/frontend-core/src/components/upload/FileUpload.vue`

**Interfaces:**
- Consumes: 既有 `xhrRaw` 进度回调
- Produces: `presignApi` 之外新增类型 `PresignUploadPhase` / `PresignUploadProgress`（放在 `src/api/presign.ts`）；
  `useUploadQueue` 的 `opts.presign` 签名改为
  `(file: File, settings: ShareSettings, onProgress?: (p: PresignUploadProgress) => void) => Promise<PresignCompleteData>`

- [ ] **Step 1: 加类型**

在 `PigeonBox/frontend-core/src/api/presign.ts` 顶部类型区追加：

```ts
/** presign 直传的阶段（进度透出的共享契约，2026-11-03） */
export type PresignUploadPhase = 'init' | 'put' | 'complete'

/**
 * presign 直传进度。
 *
 * ⚠️ 对外给**原始字节数**，不带弹窗内部那套 0-95/97-100 的折算——折算由调用方做
 * （弹窗要封顶 95% 给 complete，队列要的是纯百分比）。
 */
export interface PresignUploadProgress {
  phase: PresignUploadPhase
  /** put 阶段为已传字节；其余阶段为 0 */
  loaded: number
  /** put 阶段为总字节；其余阶段为 0 */
  total: number
}
```

- [ ] **Step 2: 弹窗透出进度**

在 `PigeonBox/frontend-core/src/components/upload/PresignUploadDialog.vue`：

1. import 加上类型：

```ts
import { presignApi, type PresignCompleteData, type PresignUploadProgress } from '@/api/presign'
```

2. `PresignOptions` 追加：

```ts
  /** 进度透出（2026-11-03）：把内部 PUT 的原始字节数与阶段交给调用方 */
  onProgress?: (p: PresignUploadProgress) => void
```

3. 在 `doUpload` 的 PUT 之前加一行：

```ts
    options.value.onProgress?.({ phase: 'init', loaded: 0, total: 0 })
```

4. 把 `xhrRaw` 的 `onProgress` 改成同时透出：

```ts
      onProgress: (loaded, total) => {
        progress.value = Math.round((loaded / total) * 95)
        options.value.onProgress?.({ phase: 'put', loaded, total })
      },
```

5. 在 Complete 之前加一行：

```ts
    options.value.onProgress?.({ phase: 'complete', loaded: f.size, total: f.size })
```

6. 秒传命中分支（`initData.existed`）在 `finish(...)` 之前加一行：

```ts
      options.value.onProgress?.({ phase: 'complete', loaded: f.size, total: f.size })
```

- [ ] **Step 3: 队列订阅进度**

在 `PigeonBox/frontend-core/src/composables/useUploadQueue.ts`：

1. import 加上类型：

```ts
import type { PresignCompleteData, PresignUploadProgress } from '@/api/presign'
```

2. `opts.presign` 的类型改为：

```ts
  presign?: (
    file: File,
    settings: ShareSettings,
    onProgress?: (p: PresignUploadProgress) => void
  ) => Promise<PresignCompleteData>
```

3. presign 分支（`r = await opts.presign?.(task.file, settings)`）改为：

```ts
          r = await opts.presign?.(task.file, settings, (p) => {
            if (p.phase === 'put' && p.total > 0) {
              task.progress = Math.round((p.loaded / p.total) * 100)
              task.statusText = t('upload.uploading')
            } else if (p.phase === 'complete') {
              task.progress = 100
              task.statusText = t('upload.prepare')
            }
          })
```

- [ ] **Step 4: FileUpload 接线**

在 `PigeonBox/frontend-core/src/components/upload/FileUpload.vue`，把 `presign:` 回调改为：

```ts
  presign: (file, s, onProgress) =>
    presignDialog.value!.open(file, {
      expire_value: s.expire_value,
      expire_style: s.expire_style,
      require_auth: s.require_auth,
      password: s.password || undefined,
      note: s.note || undefined,
      e2e: s.e2e,
      onProgress,
    }),
```

- [ ] **Step 5: 跑测试与类型检查**

```bash
cd PigeonBox/frontend-core && npm test && npm run typecheck
```
Expected: 全绿（既有 `useUploadQueue.spec.ts` 不得回归）

- [ ] **Step 6: 提交**

```bash
cd PigeonBox/frontend-core
git add src/api/presign.ts src/components/upload/PresignUploadDialog.vue src/composables/useUploadQueue.ts src/components/upload/FileUpload.vue
git commit -m "feat(upload): presign 大文件行内进度透出

弹窗里本就有的 xhrRaw 进度此前只画在弹窗内，文件列表行恒 0%；
现在把原始字节数与阶段（init/put/complete）透给队列，行内也能看到百分比。"
```

---

### Task 9: 上传侧 —— multi-direct 假百分比改批次总进度

**Files:**
- Modify: `PigeonBox/frontend-core/src/composables/useUploadQueue.ts`
- Modify: `PigeonBox/frontend-core/src/components/upload/FileUpload.vue`
- Modify: `PigeonBox/frontend-core/src/components/upload/FileItemRow.vue`
- Test: `PigeonBox/frontend-core/src/composables/__tests__/useUploadQueue.spec.ts`

**Interfaces:**
- Consumes: `multiDirect` 的聚合 `onProgress(loaded, total)`
- Produces: `useUploadQueue` 返回值新增 `batchProgress: ComputedRef<{ active: boolean; percent: number; loaded: number; total: number }>`；
  `UploadTask` 新增可选字段 `percentValid?: boolean`

- [ ] **Step 1: 写失败测试**

在 `PigeonBox/frontend-core/src/composables/__tests__/useUploadQueue.spec.ts` 末尾追加
（该文件已有 `mkFile` / `baseSettings` / `mocked` 辅助，直接复用）：

```ts
describe('multi-direct 批次总进度（2026-11-03）', () => {
  it('batchProgress 默认不激活', () => {
    const q = useUploadQueue({ settings: baseSettings(), t })
    expect(q.batchProgress.value.active).toBe(false)
  })

  it('multi-direct：行内百分比标为不可信，批次总进度呈现真聚合值', async () => {
    mocked.multiDirect.mockImplementation(async (_files, _opts, onProgress) => {
      onProgress?.(60, 100)
      return { code: 'A1', url: 'http://x/#/share/A1' }
    })
    // 两个 1MB 文件 + bodyCap 10MB ⇒ pickUploadPlan 判 multi-direct
    const q = useUploadQueue({ settings: baseSettings(), t, bodyCap: () => 10 * MB })
    q.addFiles([mkFile('a.txt', 1 * MB), mkFile('b.txt', 1 * MB)])
    await q.start()

    // 行内百分比不可信（单请求只有聚合字节数）
    expect(q.tasks.value.every((f) => f.percentValid === false)).toBe(true)
    // 批次总进度是 XHR 的真聚合值
    expect(q.batchProgress.value.active).toBe(true)
    expect(q.batchProgress.value.loaded).toBe(60)
    expect(q.batchProgress.value.total).toBe(100)
    expect(q.batchProgress.value.percent).toBe(60)
  })

  it('direct 通道：行内百分比仍可信（percentValid 不为 false）', async () => {
    mocked.uploadFile.mockResolvedValue({ code: 'A1', url: 'http://x/#/share/A1' })
    const q = useUploadQueue({ settings: baseSettings(), t })
    q.addFiles([mkFile('a.txt', 1)])
    await q.start()
    expect(q.tasks.value[0]!.percentValid).not.toBe(false)
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd PigeonBox/frontend-core && npx vitest run src/composables/__tests__/useUploadQueue.spec.ts
```
Expected: FAIL —— `batchProgress` / `percentValid` 未定义

- [ ] **Step 3: 队列实现**

在 `PigeonBox/frontend-core/src/composables/useUploadQueue.ts`：

1. `UploadTask` 接口加字段：

```ts
  /**
   * 行内百分比是否可信（2026-11-03）。
   *
   * `multi-direct` 是**单个 multipart 请求**⇒ XHR 只给聚合字节数 ⇒ 把它按文件
   * 顺序均摊会让第一个文件先冲到 100%、其余长期 0%，**是误导不是估算**。
   * ⇒ 该通道的行内百分比关掉，改由批次总进度条呈现真聚合值。
   */
  percentValid?: boolean
```

2. `addFiles` 里构造任务时加 `percentValid: true`。

3. 新增批次进度 state：

```ts
  /**
   * 批次总进度（2026-11-03）：只有 multi-direct 用得上（唯一拿不到逐文件真数
   * 的通道）⇒ 由聚合 XHR 进度驱动，列表顶部一条进度条呈现。
   */
  const batchProgress = ref({ active: false, percent: 0, loaded: 0, total: 0 })
```

4. `start()` 开头重置：`batchProgress.value = { active: false, percent: 0, loaded: 0, total: 0 }`

5. multi-direct 分支：把原先的按文件均摊回调**整段替换**为：

```ts
        const payloads = pending.map((f) => f.payload)
        // 行内百分比不可信：单请求只有聚合字节数（见 UploadTask.percentValid 注释）
        for (const task of pending) task.percentValid = false
        const result = await multiDirect(
          payloads,
          multiOptions(wrappedKey),
          (loaded, total) => {
            batchProgress.value = {
              active: true,
              percent: Math.min(100, Math.round((loaded / Math.max(total, 1)) * 100)),
              loaded,
              total,
            }
            for (const task of pending) {
              task.statusText = t('upload.uploading')
            }
          },
          multiAbort.signal
        )
```

6. 其余通道（direct / presign / multi-chunk）保持行内百分比 ⇒ 在这些分支里显式置
   `task.percentValid = true`（presign 分支在订阅进度处、chunk 分支在循环开头）。

7. `useUploadQueue` 的 return 里加：

```ts
    batchProgress: batchProgress as ComputedRef<{ active: boolean; percent: number; loaded: number; total: number }>,
```

- [ ] **Step 4: FileUpload 加批次总进度条**

在 `PigeonBox/frontend-core/src/components/upload/FileUpload.vue` 模板中，
`<transition-group name="file-list" ...>` **之前**插入：

```vue
    <!-- 批次总进度（仅 multi-direct 通道出现）：单请求只有聚合字节数 ⇒ 逐文件
         百分比是假的（见 useUploadQueue 的 percentValid 注释）⇒ 真数放这里 -->
    <div v-if="batchProgress.active" class="batch-progress">
      <el-progress :percentage="batchProgress.percent" :stroke-width="6" />
      <span class="batch-progress-text">{{ t('upload.batchProgress', { percent: batchProgress.percent }) }}</span>
    </div>
```

并从 composable 解构里取出 `batchProgress`；样式段追加：

```css
.batch-progress {
  margin-bottom: 8px;
}

.batch-progress-text {
  font-size: 12px;
  color: var(--color-text-secondary);
}
```

- [ ] **Step 5: FileItemRow 不渲染不可信的百分比**

在 `PigeonBox/frontend-core/src/components/upload/FileItemRow.vue`，把进度条的 `v-if` 改为：

```vue
      <el-progress
        v-if="showProgressBar"
        :percentage="task.progress"
        :stroke-width="4"
        :show-text="false"
        :status="task.status === 'success' ? 'success' : ''"
        class="file-progress"
      />
```

并在 `<script setup>` 里加：

```ts
// percentValid=false ⇒ 该行百分比不可信（multi-direct 聚合均摊）⇒ 不渲染条
const showProgressBar = computed(() => {
  if (props.task.status === 'success') return true
  const busy = props.task.status === 'uploading' || props.task.status === 'encrypting' || props.task.status === 'binding'
  return busy && props.task.percentValid !== false
})
```

- [ ] **Step 6: 跑测试与类型检查**

```bash
cd PigeonBox/frontend-core && npm test && npm run typecheck
```
Expected: 全绿

- [ ] **Step 7: 提交**

```bash
cd PigeonBox/frontend-core
git add src/composables/useUploadQueue.ts src/components/upload/FileUpload.vue src/components/upload/FileItemRow.vue src/composables/__tests__/useUploadQueue.spec.ts
git commit -m "fix(upload): multi-direct 行内百分比是假的 ⇒ 改批次总进度条

单 multipart 请求只有聚合字节数，按文件顺序均摊会让第一个文件先冲 100%、
其余长期 0% ⇒ 关掉该通道的行内百分比，改由列表顶部的批次总进度条呈现真聚合值。
其余通道（direct/presign/multi-chunk）本就是逐文件真进度，维持不变。"
```

---

### Task 10: 上传侧 —— E2E 加密阶段不确定态

**Files:**
- Modify: `PigeonBox/frontend-core/src/components/upload/FileItemRow.vue`

**Interfaces:**
- Consumes: `UploadTask.status === 'encrypting'`
- Produces: 加密阶段渲染 `el-progress` 的不确定态（脉冲条），不再显示 0%

- [ ] **Step 1: 改进度条**

在 `PigeonBox/frontend-core/src/components/upload/FileItemRow.vue`，把 Task 9 产出的进度条改为：

```vue
      <el-progress
        v-if="showProgressBar"
        :percentage="task.status === 'encrypting' ? 0 : task.progress"
        :indeterminate="task.status === 'encrypting'"
        :stroke-width="4"
        :show-text="false"
        :status="task.status === 'success' ? 'success' : ''"
        class="file-progress"
      />
```

- [ ] **Step 2: 跑类型检查**

```bash
cd PigeonBox/frontend-core && npm run typecheck
```
Expected: PASS

- [ ] **Step 3: 提交**

```bash
cd PigeonBox/frontend-core
git add src/components/upload/FileItemRow.vue
git commit -m "fix(upload): E2E 加密阶段显示不确定态进度条

encrypting 期间 progress 恒 0 ⇒ 1.35GB 加密几十秒界面零反馈；
改用 el-progress 的 indeterminate 脉冲态。"
```

---

### Task 11: e2e —— 下载进度

**Files:**
- Modify: `PigeonBox/frontend-core/e2e/support/mock-api.ts`
- Create: `PigeonBox/frontend-core/e2e/download.spec.ts`

**Interfaces:**
- Consumes: Task 4 的 `DownloadButton`（渲染文案）、Task 5 的 i18n 键
- Produces: `MockHandler` 新增可选字段 `binary?: { contentType: string; body: Buffer }`

- [ ] **Step 1: 给 mock 加二进制响应能力**

在 `PigeonBox/frontend-core/e2e/support/mock-api.ts`：

1. `MockHandler` 接口追加：

```ts
  /** 二进制响应体（下载类端点）：与 body 二选一 */
  binary?: { contentType: string; body: Buffer }
```

2. mock 路由里，把 payload 组装改成：

```ts
    if (hit.binary) {
      await route.fulfill({
        status: hit.status ?? 200,
        contentType: hit.binary.contentType,
        body: hit.binary.body,
      })
      return
    }

    const payload = typeof hit.body === 'function' ? hit.body(record) : hit.body
    await route.fulfill({
      status: hit.status ?? 200,
      contentType: 'application/json',
      body: JSON.stringify(payload),
    })
```

- [ ] **Step 2: 写 e2e 用例**

创建 `PigeonBox/frontend-core/e2e/download.spec.ts`。

⚠️ 已核实的三处名字（别猜）：
- 分享页路由 = **`/share/:code`**（`src/router/index.ts:21`）⇒ hash 模式下的地址是 `/#/share/AB12CD`
- 分享详情端点 = **`/share/select/`**（`src/api/share.ts:61`，带尾斜杠；mock 按「路径包含」匹配，写 `/share/select` 即可）
- 下载端点 = **`/share/download`**（服务端下发的 `download_url` 形态）
- 分享页渲染文件卡片的判据 = `hasFileContent` = **有 `file_name` 或 `files` 非空**
  （`src/views/share/View.vue:412`）⇒ mock 响应必须给 `file_name`

```ts
import { expect, test } from '@playwright/test'
import { envelope, installApiMocks, siteBootstrap } from './support/mock-api'

/**
 * 下载进度（2026-11-03）。
 *
 * 断言只认**语义**（可见文案、进度条容器出现、状态文案收敛），不认 DOM 层级。
 * ⚠️ 浏览器默认不带 showSaveFilePicker（无头 Chrome 无该 API）⇒ 走内存 blob 档，
 *    进度条会出现、能走完 ⇒ 用例不依赖文件系统 API。
 */

const SHARE_DETAIL = envelope({
  code: 'AB12CD',
  file_name: 'e2e-download.txt',
  file_size: 11,
  has_password: false,
  encrypted: false,
  download_url: '/share/download?code=AB12CD&token=TK',
  files: [],
})

test.describe('下载进度', () => {
  test('点击下载后出现行内进度条并走完', async ({ page }) => {
    await installApiMocks(page, [
      ...siteBootstrap(),
      { method: 'GET', url: '/share/select', body: SHARE_DETAIL },
      {
        method: 'GET',
        url: '/share/download',
        binary: { contentType: 'application/octet-stream', body: Buffer.from('hello world') },
      },
    ])

    await page.goto('/#/share/AB12CD')

    const btn = page.getByRole('button', { name: /下载/i }).first()
    await expect(btn).toBeVisible()
    await btn.click()

    // 进度条就地出现（不弹窗）
    await expect(page.locator('.dl-progress').first()).toBeVisible()
    // 走完后状态收敛（完成 / 已移交浏览器）
    await expect(page.locator('.dl-meta').first()).toContainText(/完成|已移交|Download complete|Handed off/i)
  })

  test('下载失败时行内显示错误文案', async ({ page }) => {
    await installApiMocks(page, [
      ...siteBootstrap(),
      { method: 'GET', url: '/share/select', body: SHARE_DETAIL },
      { method: 'GET', url: '/share/download', status: 500, body: { code: 500, message: 'boom' } },
    ])

    await page.goto('/#/share/AB12CD')
    await page.getByRole('button', { name: /下载/i }).first().click()

    await expect(page.locator('.dl-error').first()).toBeVisible()
  })
})
```

- [ ] **Step 3: 跑 e2e**

```bash
cd PigeonBox/frontend-core && npm run build && npm run e2e -- e2e/download.spec.ts
```
Expected: PASS（2 条）

> ⚠️ 若失败文案没出现：HTTP 500 的响应体是 JSON 信封，下载器按 `resp.ok` 判定 ⇒ 直接抛
> `HTTP 500` ⇒ composable 归一为 `download.failed` ⇒ 组件渲染 `.dl-error`。
> 若断言超时，先看浏览器控制台是否有 unhandled rejection（`page.on('pageerror')`）。

> ⚠️ 若取件页路由是 `/share/:code` 而非 hash 路由，按 `src/router` 的实际定义调整
> `page.goto` 的地址；若分享详情走的是别的端点，同步改 `MockHandler.url`。
> **只认语义**：按钮名、进度条容器 class、状态文案。

- [ ] **Step 4: 提交**

```bash
cd PigeonBox/frontend-core
git add e2e/support/mock-api.ts e2e/download.spec.ts
git commit -m "test(e2e): 下载进度用例（mock 支持二进制响应）"
```

---

### Task 12: 全量验证 + 提 PR

**Files:**
- 无代码改动（仅验证与 PR 描述）

**Interfaces:**
- Consumes: 全部前置任务
- Produces: 绿的全量测试 + frontend-core PR

- [ ] **Step 1: 跑全量单测**

```bash
cd PigeonBox/frontend-core && npm test
```
Expected: 全绿（既有 20+ 个 spec 文件 + 新增 3 个）

- [ ] **Step 2: 跑类型检查与构建**

```bash
cd PigeonBox/frontend-core && npm run typecheck && npm run build
```
Expected: 两个都 PASS

- [ ] **Step 3: 跑全量 e2e**

```bash
cd PigeonBox/frontend-core && npm run e2e
```
Expected: 全绿（desktop + mobile 两个 project）

- [ ] **Step 4: 确认无后端改动**

```bash
cd PigeonBox && git status --short && cd core && git status --short && cd ../contracts && git status --short
```
Expected: 三个仓都无输出（core/contracts/server 零改动）

- [ ] **Step 5: 提交并开 PR**

```bash
cd PigeonBox/frontend-core
git status --short
git add -A
git commit -m "chore: 上传/下载百分比——统一下载器 + presign 行内进度 + 批次总进度

下载：新增 src/utils/downloader.ts（fs/blob/native 三档落地），取件页三条路径
与管理台文件下载接入，页面内显示真实百分比。
上传：presign 大文件行内进度透出；multi-direct 行内假百分比改批次总进度条；
E2E 加密阶段改不确定态进度条。
后端零改动。"
```

开 PR（标题沿用仓内惯例）：

```bash
gh pr create --title "feat: 上传/下载百分比——统一下载器 + presign 行内进度" --body "$(cat <<'EOF'
## 做什么

- **下载侧全量接管**：新增 `src/utils/downloader.ts` 单一出口，三档落盘
  （文件系统 API 流式写盘 / 内存 blob / 退回浏览器原生下载），
  取件页（普通 / E2E / 打包 zip）与管理台文件下载全部接入，页面内显示真实百分比。
- **上传侧三处补齐**：
  - presign 大文件（>100MB）：弹窗里本就有的进度此前没透出，文件列表行恒 0% ⇒ 现在行内也可见
  - multi-direct：单 multipart 请求只有聚合字节数，逐文件百分比是假的 ⇒ 改批次总进度条
  - E2E 加密阶段：progress 恒 0 ⇒ 改不确定态脉冲条

## 为什么不假造百分比

multi-direct 的行内百分比原先是「把聚合字节按文件顺序均摊」⇒ 第一个文件先冲到 100%、
其余长期 0%，**是误导不是估算**。本次删掉它，改用真聚合值。
拿不到真进度的场景（降级到浏览器原生下载）如实显示「已移交浏览器下载」。

## 影响面

- **后端零改动**（core / contracts / server / p2p 一行未碰）
- 行为变化：Chrome/Edge 下普通下载会多一个「保存文件」对话框
  （`showSaveFilePicker` 必须由用户手势触发，无法省）；Firefox/Safari 无此 API，
  小文件走内存档（无对话框、有 %），大文件退回原生下载。

## 验证

- `npm test` / `npm run typecheck` / `npm run build` / `npm run e2e` 全绿

设计文档：`PigeonBox/docs/specs/2026-11-03-upload-download-progress-design.md`
EOF
)"
```

- [ ] **Step 6: 回填 hub 仓**

在 hub 仓 `PigeonBox/` 提交实施计划的落库记录（若本计划文档有改动）：

```bash
cd PigeonBox
git add docs/superpowers/plans/2026-11-03-upload-download-progress.md
git commit -m "docs(plans): 上传/下载百分比实施计划落库"
```

---

## Self-Review

**1. Spec 覆盖检查**

| Spec 章节 | 覆盖任务 |
|---|---|
| §1 现状与硬约束 | 记录在 Global Constraints 与各任务注释 |
| §3.1 对外接口 | Task 1（类型 + 纯逻辑）、Task 2（download 主体） |
| §3.2 三档落盘 | Task 1（`pickSink`）、Task 2（落地实现）、Task 2 测试（超限降级） |
| §3.3 调用次序 | Task 2（先取保存目标再 fetch）、Task 4（onClick 首句）、Task 2 测试（取消=零请求） |
| §3.3.1 取消 | Task 2（`DownloadCancelledError`）、Task 3（cancel）、Task 2 测试 |
| §3.4 降级触发 | Task 2（fetch 失败降级、transform 不降级、缺 Content-Length） |
| §3.5 E2E 特例 | Task 2（transform 钩子）、Task 6（e2eTransform） |
| §3.6 文件名解析 | Task 1（`parseContentDispositionFilename`）+ 测试 |
| §4 四条下载路径 | Task 6（取件页三条）、Task 7（管理台一条） |
| §5.1 presign 行内进度 | Task 8 |
| §5.2 multi-direct 批次总进度 | Task 9 |
| §5.3 E2E 加密不确定态 | Task 10 |
| §6 展示形态 + i18n | Task 4（组件）、Task 5（i18n） |
| §7 测试 | Task 1/2/3 单测、Task 9 队列测试、Task 11 e2e |
| §8 不在范围 | Global Constraints + 各任务注释（未越界） |
| §9 行为变化 | Task 12 的 PR 正文已写明 |

**2. 占位符扫描**：全文无 TBD / TODO / 「类似 Task N」/ 无代码的「加错误处理」类步骤。

**3. 类型一致性核对**

- `DownloadProgress.phase` 的六个取值在 Task 1（类型）、Task 2（实现）、Task 4（`statusText` switch）一致 ✅
- `DownloaderEnv.pickTarget` 返回 `FsTarget | null`，Task 2 实现与 Task 2 测试一致 ✅
- `useDownloadProgress.run` 的入参类型 `Omit<DownloadRequest, 'onProgress' | 'signal'>`，Task 3 定义与 Task 4 调用一致 ✅
- `PresignUploadProgress` 在 `src/api/presign.ts` 定义，Task 8 的三处引用路径一致 ✅
- `UploadTask.percentValid` 在 Task 9 定义、Task 9 的 `FileItemRow` 读取 ✅
- `batchProgress` 在 Task 9 的 return 里以 `ComputedRef<{active,percent,loaded,total}>` 暴露，Task 9 的模板按同一形状使用 ✅
