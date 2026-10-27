# PigeonBox MCP 官方 SDK 迁移设计

> 2026-10-22 实施稿。回答一个问题：**MCP server 怎么从仓内自研的 JSON-RPC 实现换成官方 SDK，并且不牺牲既有的三级作用域、限流/审核链路与部署门控。**
>
> 与 Wave B'（`2026-10-22-usability-cs-p2p-unification-design.md`）的关系：Wave B' 退役了 Box 侧直传编排层（直传拆为独立应用 PigeonBeam），本稿在其之后落地，**只动 MCP 层**，不碰直传/联邦的业务面。
>
> 配套文档：对外接入指南 `docs/MCP-README.md`、agent skill `skills/pigeonbox-mcp/SKILL.md`。

---

## 0. 设计主张

> **协议层不自己写；工具语义用类型描述；结果用结构化交付。**

1. **协议帧、版本协商、错误语义 = 官方 SDK 的职责**，仓内不再自研 JSON-RPC 2.0 实现；
2. **工具入参/出参 = Go 类型 + schema 推断**，不手写 JSON Schema map；
3. **工具结果 = 结构化对象**（`structuredContent`），不是给模型读的散文。

一条判据贯穿全文：**只要"规范已经定义好、且会继续演进"的东西（协议帧、版本号、schema 形状、错误码），就不在仓内自己实现**——自己实现等于自己背一份"规范债务"，且必然落后。

---

## 1. 为什么要换（现状诊断）

换之前的 `core/app/mcp/mcp.go` 是 1140 行自研实现，缺口有四：

| 缺口 | 事实 | 后果 |
|---|---|---|
| 协议落后 | 握手应答写死 `2025-03-26`；无 `server/discover`、无逐请求版本协商（SEP-2575） | 新规范客户端（≥2026-07-28）接不上；旧版本退役后无退路 |
| 帧与错误自研 | 自写 `rpcRequest/rpcResponse/writeRPCResult` 与错误码表 | 协议细节（通知 202、批量、id 缺失、batching 移除等）逐条自己补，迟早漏 |
| schema 手写 map | `objSchema/strProp/intProp` 手工拼 JSON Schema | 描述与实现易漂移；无校验（多传字段/类型错一律静默忽略） |
| 结果是散文 | 返回"分享码: XXXXXXXX\n取件码: …"文本块 | agent 只能正则刮字段；字段一改就断；无法程序化消费 |

补充事实：社区 SDK `mark3labs/mcp-go` 只到规范 2025-11-25，且非官方；**官方 SDK `github.com/modelcontextprotocol/go-sdk` v1.8.0 支持 2026-07-28**，v1.0.0 起承诺 API 兼容（不再做破坏性 API 变更）——这才是"主流"。

---

## 2. 变更面

### 2.1 依赖

- 新增直接依赖 `github.com/modelcontextprotocol/go-sdk v1.8.0`（真实发布版本，无 replace；`go.work` 内地模块优先，钉版由各仓 CI + hub train-verify 对账兜底）。
- 间接依赖 `github.com/google/jsonschema-go v0.4.3`（SDK 的 schema 推断底座）。

### 2.2 协议层（`core/app/mcp/server.go`，新建）

- `newMCPServer()`（`server.go:49`）：`sdk.NewServer` + `Instructions` + 工具注册；**不收窄 `SupportedProtocolVersions`**，即默认支持全部已知版本（2026-07-28 / 2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05），客户端报什么版本就协商什么版本。
- `Handler()`（`server.go:136`）：`sdk.NewStreamableHTTPHandler` + **无会话模式**（`Stateless: true`，不写 `Mcp-Session-Id`，`GET/DELETE` 按规范回 405）+ **JSON 响应**（`JSONResponse: true`，响应体 `application/json`，与历史行为线形一致）。惰性构建（`sync.Once`），保证请求体上限在 `SetMaxFileSize` 注入后才定。
- `mcpBodyLimit()`（`server.go:154`）：SDK 默认请求体上限仅 **4MiB**，会打断 6MB 单文件工具；改为按单文件上限推导 `max(10MiB, size*4/3+1MiB)`。
- `mcpSlogLogger()`（`server.go:168`）：SDK 要 `*slog.Logger`，仓内是 zap；用 `zap.NewStdLogAt(...).Writer()` + `slog.NewTextHandler` 桥接（不引入自研 `slog.Handler`）。

### 2.3 传输桥接（`core/bootstrap/routes_custom.go:104-142`）

官方 SDK 交付的是 `net/http.Handler`，而本站传输层是 Hertz。桥接用 hertz 自带的 `pkg/common/adaptor.HertzHandler`：

```
Hertz handler ──adaptor──► http.Request ──SDK──► 工具 handler
     │                         │                     │
  guestGate/authMW        ctx 透传            从 ctx 读调用者身份
```

关键点：`adaptor` 用 `http.NewRequestWithContext(ctx, …)` 构造请求（`pkg/common/adaptor/handler.go`），而 SDK 把 `req.Context()` 一路透传到工具 handler（SDK 源码注释："Pass req.Context() here, to allow middleware to add context values"）——**调用者身份因此可以经 ctx 抵达工具层**，这是作用域模型能保住的前提。

### 2.4 工具层类型化（`core/app/mcp/tools.go`，新建 891 行）

- 18 个工具的入参/出参全部改为 Go 结构体（`tools.go:36` 的 `toolSpecs` 是注册表真相源：名称/描述/最低作用域/注册动作）。
- 入参 schema 由 SDK 推断（JSON Schema 2020-12）：`jsonschema` 结构体标签给中文描述；`omitempty` = 可选；**默认拒绝未定义字段**（`additionalProperties: false`）。
- 出参结构化：结果同时进 `result.structuredContent`（对象）与 `result.content[0].text`（同一份 JSON 文本，老客户端可读）。

### 2.5 三级作用域怎么保住

作用域模型（游客 / 登录用户 / 管理员）**一行语义都没变**，只换了实现位置：

| 环节 | 换前 | 换后 |
|---|---|---|
| 身份来源 | Hertz handler 显式传参 `Handle(ctx, body, caller)` | ctx 注入 `mcp.WithCaller(ctx, caller)`（`server.go:31`） |
| `tools/list` 过滤 | 自研 handler 内遍历工具表 | SDK 接收中间件按 `toolSpec.MinScope` 裁剪（`server.go:101`） |
| `tools/call` 复核 | `execTool` 内比对作用域 | `toolGuard` 统一闸门（`server.go:74`），越权 → 工具执行错误 |

**列表过滤仍不是授权边界**，`tools/call` 必复核——这条不变。

### 2.6 测试与冒烟

- `core/app/mcp/mcp_test.go` 全量重写：**走真实 HTTP 传输层**（真实 `Content-Type`/`Accept` 头 + `httptest`），而不是直接调内部方法——这样"请求头缺失会被 SDK 拒绝"这类契约在测试里就是真的。
- 新增三组用例：`server/discover`（新协议发现）、推断式 `inputSchema` 形状、严格入参校验（未知字段/类型错/缺必填/枚举越界）。
- `scripts/smoke-full.sh`：MCP 断言补 `Accept` 头；新增 **S14b**（`tools/call` 的 `structuredContent` 含 `code`+`share_url`）——端到端验证结构化出参。
- `skills/pigeonbox-mcp/scripts/mcp.sh`：补 `Accept` 头；`call` 输出改为结构化 JSON（格式化）。

---

## 3. 新契约（客户端可见）

### 3.1 协议版本矩阵

| 客户端形态 | 握手方式 | 服务端行为 |
|---|---|---|
| 旧客户端（≤2025-11-25） | `initialize` 握手 | 回协商版本（客户端报什么版本就协商什么；上限 2025-11-25） |
| 新客户端（≥2026-07-28） | `server/discover` + 逐请求 `_meta` 协商 | 返回支持的版本全集 + 能力 |

### 3.2 请求头要求（MCP 规范要求，缺任一项即被拒）

| 头 | 要求 | 缺失后果 |
|---|---|---|
| `Content-Type: application/json` | 必填 | HTTP 415 |
| `Accept: application/json, text/event-stream` | **两者兼具** | HTTP 400 |
| `Mcp-Protocol-Version: 2026-07-28` | 仅新协议 | 旧协议无此头即可 |
| `Mcp-Method: <method>` | 新协议必填，须与 body method 一致 | HTTP 400 |
| `Mcp-Name: <tool>` | 新协议的 `tools/call` 必填，须与 body name 一致 | HTTP 400 |
| body `params._meta` | 新协议必填：`io.modelcontextprotocol/protocolVersion` + `io.modelcontextprotocol/clientCapabilities` | HTTP 400 |

### 3.3 错误语义矩阵

| 情形 | 换前 | 换后（SDK 语义） |
|---|---|---|
| 工具业务失败（取件码不存在、custom_code 冲突…） | 200 + `isError:true` + 文本 | **不变**（200 + `isError:true` + 文本） |
| 入参不合法（未知字段/类型错/缺必填） | 静默忽略 | 200 + `isError:true`（模型可自纠，SEP-1303） |
| 未知工具 | 200 + `isError:true` | JSON-RPC `-32602`（工具不存在不是可自纠的业务失败） |
| 非法 JSON / 未知方法 | 200 + JSON-RPC `-32700`/`-32601` | **HTTP 400**（传输层拒绝，不进协议层） |
| 通知（无 `id`） | 202 无体 | **不变** |

### 3.4 工具结果形态

```jsonc
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "content": [{ "type": "text", "text": "{\"code\":\"pjb4QPlu\", …}" }],
    "structuredContent": { "code": "pjb4QPlu", "pickup_code": "…", "share_url": "…", … }
  }
}
```

`share_text` → `{code, pickup_code, share_url, markdown, has_password}`；`list_shares` → `{total, page, page_size, items[]}`；其余工具的出参见 `core/app/mcp/tools.go`。

### 3.5 工具清单（18，直传四工具已于 Wave B' 退役）

访客：`share_text` `share_file`；登录用户 += `create_request_code` `preview_share`；管理员 = 全部 18（含 `get_share` `get_share_content` `download_share_file` `list_shares` `delete_share` `get_system_status` `get_storage_info` `list_users` `cleanup_expired` `federation_status` `federation_resolve` `p2p_peers` `p2p_invites` `p2p_accept`）。

---

## 4. 迁移指引（breaking 清单）

| 变化 | 谁受影响 | 怎么改 |
|---|---|---|
| 必须带 `Accept: application/json, text/event-stream` | 所有自研客户端、脚本 | 补头（`skills/pigeonbox-mcp/scripts/mcp.sh` 已改） |
| 工具结果从散文变结构化 | 靠正则刮字段的 agent | 读 `structuredContent`（或 `content[0].text` 的 JSON） |
| 入参变严格 | 惯于多传字段/传错类型的模型 | 按 `tools/list` 返回的 `inputSchema` 填参；错误信息含具体字段名，可据以自纠 |
| 未知工具 → `-32602` | 依赖 `isError` 判"工具不存在"的客户端 | 改为判 JSON-RPC `error` |
| 非法 JSON/未知方法 → HTTP 400 | 期望 200 + JSON-RPC error 的客户端 | 改判 HTTP 状态 |
| `GET/DELETE /api/v1/mcp` 由 404 变 405 | 探测端点可用性的脚本 | 无需处理（规范要求 405） |

---

## 5. 保持不变的部分（不变量）

- **工具业务语义**未变：分享/取件码/寄件码/预览/下载/管理/联邦各工具的行为、限额、错误文案口径不变。
- **三级作用域**未变：游客快速分享仍与网页匿名寄件同链路、同限流、同审核/扩展名白名单；`custom_code` 仍仅登录用户可用。
- **限流与审核链路**未变：MCP 建分享仍走 share 域的配额/审核/白名单。
- **部署门控**未变：仅 standalone / admin 面注册；public 副本仍 404。
- **无会话、逐请求独立认证**未变：无需握手即可 `tools/call`（新客户端另可用 `server/discover`）。
- **跨站防护**未变：`mcpGuestGate`（Origin/`Sec-Fetch-Site` + Cookie CSRF 头门禁）仍在桥接之前。

---

## 6. 验证与门禁

| 项 | 结果 |
|---|---|
| `core` 全量测试 | 全包绿（含新增 app/mcp 用例与路由契约快照：GET/DELETE 两路由入契约表） |
| `go vet`（app/mcp + bootstrap） | 干净 |
| 6 模块 `GOWORK=off` 独立编译 | 全过（钉版真实、无 replace） |
| 真机冒烟 `scripts/smoke-full.sh` | **52 PASS / 0 FAIL**（含 S14 `tools=18`、S14b 结构化出参） |
| shellcheck（CI 同款） | `scripts/smoke-full.sh`、`skills/pigeonbox-mcp/scripts/mcp.sh` 均 exit=0 |

---

## 7. 后续（本次未做，留作可选）

1. **出参 schema 显式化**：`jsonschema-go` 的结构体标签只承载描述，`enum`/`minimum` 需显式 `*jsonschema.Schema` 才能表达；当前枚举校验放在 handler 层（错误信息可读），如需 schema 级枚举再补。
2. **提示词级输出描述**：出参结构体的 `jsonschema` 标签已给字段说明，若需给模型更明确的"如何使用"指引，可在 `Instructions` 追加任务选型建议。
3. **多副本会话模式**：当前无会话；若未来需要 server→client 推送（进度/通知），需从 `Stateless` 切到有会话模式并把调用者身份绑到会话（届时作用域模型要从 ctx 改为会话态）。
