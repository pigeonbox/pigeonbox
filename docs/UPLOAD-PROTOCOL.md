# 上传协议（可恢复）

> 面向**实现方**的协议参考：分块上传会话的生命周期、断点续传（可恢复）语义、秒传快速通道、跨设备边界、暂停/恢复、Beam 回退交接。
> 若你要「用 HTTP API 对接上传」，看 [API-UPLOAD-INTEGRATION.md §5](API-UPLOAD-INTEGRATION.md)（集成指南）；本文是它的**协议底稿**，两者互补、不重复。

Base URL 下文记作 `$BASE`。分块通道 `POST /chunk/upload/*` 一律持 API Key（`Authorization: Bearer pb_sk_xxx`）或取件/上传令牌，会话与身份绑定，他人无法劫持。

---

## 1. 通道矩阵（选哪条）

| 场景 | 通道 | 可恢复 | 备注 |
|---|---|---|---|
| 小文件（< 32MB） | 单请求 `POST /share/file/` 或 multi-direct | 否 | 单请求体，中断只能整体重发 |
| 大文件 / 弱网 / 要续传 | 分块 `POST /chunk/upload/*`（本文） | **是** | 任意大小，分片补缺 |
| 对象存储直传 | 预签名 `POST /api/v1/presign/*` | 否（单 PUT） | 流量不过服务器；见集成指南 §5.4 |
| 设备↔设备加速 | PigeonBeam（信鸽直传） | —— | 浏览器端失败时**跳转交接**，见 §6 |

**可恢复的只有分块通道**：它把文件切成片、每片独立上传，中断后凭会话位图补缺片。单请求/预签名是「一次 PUT 整体」，无法半途续。

---

## 2. 分块会话生命周期

```
init ──► 逐片 upload ──► complete ──►（多文件）bind
  │          │              │
  │          └── status ◄───┘   （任意时刻查位图）
  └── cancel                    （放弃，回收已传分片）
```

| 步骤 | 端点 | 说明 |
|---|---|---|
| 创建会话 | `POST /chunk/upload/init/` | 建/续会话；带 `file_hash` + 有效期元数据时可走**秒传快速通道**（§4） |
| 传一片 | `POST /chunk/upload/chunk/{upload_id}/{i}` | multipart，片放 `chunk` 字段；可乱序、可重传 |
| 查进度 | `GET /chunk/upload/status/{upload_id}` | 返回**已传分片位图**（续传的唯一跳片判据，§3） |
| 合并建享 | `POST /chunk/upload/complete/{upload_id}` | 分片到齐后合并，建分享、出取件码 |
| 放弃 | `DELETE /chunk/upload/cancel/{upload_id}` | 回收服务端已传分片（秒传探测落空的空会话也用它回收，§4） |
| 多文件绑定 | `POST /api/v1/share/multi-bind` | 把多个已 complete 的会话绑成一个多文件分享 |

`upload_id` 形态约束：`[0-9a-zA-Z_-]{1,128}`。**会话键由 `file_hash` 派生**（不传 `file_hash` 则服务端生成 UUID 键）⇒ 同一内容、同一发起方重 init 会**复用同一会话**，不会各起一个。

---

## 3. 断点续传（可恢复）语义

### 3.1 跳片判据：服务端位图，不是本地坐标

续传的唯一真相是 `GET /chunk/upload/status/{upload_id}` 返回的**已传分片索引集合**。客户端本地记的「传到第几片」可能滞后（请求在途、会话被清理、跨设备），**只能当提示，不能当跳片依据**——按本地坐标盲跳会拼出**空洞文件**（新会话里那些分片并不存在）。

正确续传流程：

```
status(upload_id) ──► uploadedIndexes = [0,1,2,5]   （服务端位图）
                     ──► 只补 {3,4,6,…}（缺片）
```

### 3.2 归属三通道（`X-Upload-Token`）

会话归属可通过三种等价凭据确立（任选其一）：

1. **API Key**（`Authorization: Bearer`）—— 授权用户；
2. **会话令牌**（init 返回的 `sessionToken`）—— 匿名发起方持有的会话凭证；
3. **上传令牌**（`X-Upload-Token` header）—— 跨请求续传凭据（预签名通道也用它）。

⇒ **跨设备续传**只对「同一登录用户」或「持有 `X-Upload-Token` 者」成立。匿名发起方若既没登录也没带令牌，换设备即失去会话归属，无法续。

### 3.3 续传边界（诚实声明）

- **刷新页面后**：`File` 对象不跨刷新存活 ⇒ 需**重选同一文件**（指纹 = 名称/大小/修改时间全同）接管会话，不能无感恢复。
- **E2E 加密分享不续传**：每次加密用新密钥/新 IV ⇒ 密文逐次不同，续旧会话会拼出损坏密文 ⇒ 一律开新会话。
- **会话过期**：返回 `20010`（会话不存在/已失效）⇒ 重新 init 全量传。

---

## 4. 秒传快速通道（内容去重）

**秒传** = 同一用户历史上传过**同 hash + 同大小**的文件时，不再重复落盘/传分片，直接引用既有存储对象出码。

### 4.1 触发条件

`init` 时**同时**携带：

- `file_hash`：整个文件的 SHA-256 hex（**必传**才有秒传）；
- **有效期元数据**：`expire_style` / `expire_value`（及可选 `require_auth` / `password` / `custom_code` / `note`）——**带有效期元数据才启用「快速通道」**，命中即在 init 响应里直接建好新分享。

命中（同用户同 hash+size）⇒ init 响应直出：

```json
{"code":0,"data":{"is_quick_upload":true,"share_code":"7GVACfJb",
                  "share_url":"$BASE/#/share/7GVACfJb"}}
```

**流程到此结束**，无需再传分片。`is_quick_upload:true` 但未带有效期元数据时，只报告「内容已存在」，仍需走 complete 建享。

### 4.2 去重范围（D1：同用户内）

去重只在**同一用户**内生效（`FindQuickUploadSource`）：

- **匿名不命中**——匿名访客无「历史」可查，探测必落空；
- **跨用户不共享**——这是刻意的：跨用户秒传会变成**存在性 oracle**（能探出「别人传过某文件」），故不开放。

### 4.3 探测落空要回收

带 `file_hash` 的 init 若未命中，会生成一个**空会话**（键 = file_hash）——它没传任何分片，若不再用，须 `DELETE /chunk/upload/cancel/{upload_id}` **回收**，否则空会话堆积。

---

## 5. 暂停 / 恢复（客户端协调）

服务端没有「暂停」端点——**暂停是客户端在分片边界的协调**：

- **暂停**：客户端在传完当前片后停下（单片不打断），保留会话坐标；
- **恢复**：`status` 查位图 → 补缺片（同 §3 续传）。

因为每片独立、可乱序、可重传（§2），「停在片边界」天然安全——不会有半片悬空。这与单请求/预签名通道形成对比：那两条是「一次 PUT 整体」，中途停 = abort = 整个丢弃重来。

---

## 6. Beam 回退（跳转交接）

上传失败/太慢时，可把传输**交接到 PigeonBeam**（信鸽直传，设备↔设备）。浏览器端只做**跳转交接**，不编排 Beam 传输：

```
$BEAM_URL?source=web-upload[&pickup_code=<取件码>]
```

- `source=web-upload`：标记来源是网页上传；
- `pickup_code`（可选）：已有取件码时带上，Beam 端可直接续接该分享的交付；
- `$BEAM_URL` 由站点配置 `base.beam_base_url` 下发（`/api/config` 的 `beamBaseUrl`）；**未配置时前端零渲染该入口**（不给必然打不开的坏按钮）。

> 与 `/beam`（NAS 平台适配器挂在 Box 服务根上的 web 面板，前端自动探测）不是一回事：`beam_base_url` 是管理员显式配置的**独立 Beam 客户端**地址。

---

## 7. 错误码速查（上传相关）

| 业务码 | 常量 | 含义 / 处置 |
|---|---|---|
| `10010` | `CodeTooLarge` | 请求体/整文件超上限；后端文案带具体值 |
| `10015` | `CodePresignDisabled` | 匿名直传未开放 ⇒ 回退普通/分块通道 |
| `20009` | `CodeChunkInvalid` | 分片无效（哈希不符）⇒ **重传该片** |
| `20010` | `CodeUploadSessionGone` | 会话不存在/已失效 ⇒ 重新 init |
| `20012` | `CodeShareBlocked` | 分享被管理员禁用 |
| `30008` | `CodePresignFailed` | 预签名生成失败 |
| `30011` | `CodeFileTypeDenied` | 文件类型不允许（黑名单/魔数校验未过，改名绕不过） |

> 完整错误码表见 [错误码对照表](../guide/error-codes)。

---

## 相关

- [API 上传对接指南 §5](API-UPLOAD-INTEGRATION.md)（集成 how-to，含 curl 示例）
- [错误码对照表](../guide/error-codes)
- [PigeonBeam（信鸽直传）](../guide/pigeonbeam)
