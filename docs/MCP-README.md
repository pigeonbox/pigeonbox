# PigeonBox MCP Server（AI 客户端对接指南）

PigeonBox 内置 **Model Context Protocol (MCP) server**：AI 客户端（Claude Desktop / Claude Code / Cursor / 任意标准 MCP 客户端）可以直接创建/管理文件分享。上游 vastsa/FileCodeBox v2.8.x 也有 MCP 但只有 `share_text`/`share_file` 两个快速分享工具；PigeonBox 是 **19 个工具 + 三级作用域**（访客快速分享 / 登录用户 / 管理员全量），并保留寄件码、预览、P2P 联邦、P2P 设备直传等独有面。

| 项 | 值 |
|---|---|
| 端点 | `POST /api/v1/mcp`（单端点，Streamable HTTP 传输，JSON-RPC 2.0，符合 MCP 规范） |
| 认证 | 默认管理员 JWT，`Authorization: Bearer <token>`；`mcp.allow_guest=true` 时可选认证，按身份分作用域（见下） |
| 开关 | `mcp.enabled`（默认 `true`）/ `mcp.allow_guest`（默认 `false`）；env `PB_MCP_ENABLED` / `PB_MCP_ALLOW_GUEST` |
| 协议版本 | `2025-03-26`（握手应答声明，服务端无会话状态，不强制握手） |

> **部署模式门控（core v0.13.0+）**：MCP 路由仅在 **standalone**（默认）与 **admin** 模式注册；
> `PB_DEPLOY_MODE=public` 的多副本公开面不含 MCP（请求 404）。多副本拓扑（chart
> `replicaCount>1`）下请对接 admin 面：`<release>-admin` Service 或 `serverAdmin.ingress` 域名。

## 访客快速分享（mcp.allow_guest）

面向"AI 助手帮用户发快递"的场景：`PB_MCP_ALLOW_GUEST=true` 后任意 MCP 客户端免登录即可
`share_text`/`share_file`（与网页匿名寄件**同链路、同限流（upload 桶）、同审核/扩展名白名单**，
登录调用者额外计入个人配额并落归属）。三级作用域：

| 调用者 | 可见工具 |
|---|---|
| 游客（未登录） | `share_text`、`share_file` |
| 登录用户（任意角色） | 上述 + `create_request_code`、`preview_share` |
| 管理员 | 全部 19 个 |

安全约束：游客**忽略 `custom_code`**（自定义取件码仅登录用户）；浏览器跨站请求一律拒绝
（`Origin`/`Sec-Fetch-Site` 校验 + Cookie 认证 CSRF 头门禁，防借访客浏览器灌分享）；
`tools/list` 按调用者过滤、`tools/call` 复核作用域。访客分享的取件码/链接只在工具结果中返回，
不落任何持久化列表——丢了链接只能靠再发一次。

## 能力清单（19 个工具）

覆盖分享全生命周期：**上传**（文本/文件）、**寄件码**（反向收件）、**预览**、**下载**（内容/文件）、**管理**（查询/列表/删除/统计）、**P2P 联邦**（状态/路由）、**P2P 设备直传**（状态/任务/发送/接收）。

| 工具 | 作用域 | 关键参数 | 说明 |
|---|---|---|---|
| `share_text` | 游客+ | `text`（必填，上限 222KB）、`expire_value`+`expire_style`、`password`、`custom_code`（仅登录） | 创建文本分享，返回取件码、链接与 Markdown 链接 |
| `share_file` | 游客+ | `file_name`+`content_base64`（必填）、`expire_*`、`password`、`custom_code`（仅登录） | 上传文件建分享（base64 随请求携带），走配额/审核/扩展名白名单链路，单文件上限 `mcp.max_file_size`（默认 6MB）；结果附 `wget` 取件命令（无密码时） |
| `create_request_code` | 用户+ | `title`、`max_files`、`max_bytes`、`expire_*` | 创建寄件码投递链接（`{base}/#/request/<token>`），对方上传的文件落成你名义的分享 |
| `preview_share` | 用户+ | `code`、`password` | 取内容预览：文本文件返回摘要（截断 8000 字符），图片/视频/文档返回元数据；受取件闸门与密码保护约束 |
| `get_share` | 管理员 | `code` | 按取件码查询分享详情（不消耗取件次数），文件分享附子文件清单 |
| `get_share_content` | 管理员 | `code` | 读内容：文本返回正文，文件返回元数据与文件清单（不消耗取件次数） |
| `download_share_file` | 管理员 | `code` | 下载文件内容（base64 回传；仅单文件分享，已过期拒绝，不消耗取件次数；受 `mcp.max_file_size` 限制） |
| `list_shares` | 管理员 | `page`、`page_size`（≤100）、`keyword` | 分页列出全站分享（按取件码搜索） |
| `delete_share` | 管理员 | `code` | 删除分享（DB 记录 + 物理文件，写审计日志；硬删不经回收站） |
| `get_system_status` | 管理员 | — | 系统/上传统计（文件数、用户数、今日上传、过期文件） |
| `get_storage_info` | 管理员 | — | 存储使用状态（类型/容量/占用/文件数） |
| `list_users` | 管理员 | `page`、`page_size` | 分页列出用户 |
| `cleanup_expired` | 管理员 | — | 清理全部过期分享（DB + 物理文件），返回清理数与释放字节 |
| `federation_status` | 管理员 | — | P2P 联邦状态：是否启用/节点 ID/注册中心/最近心跳（未启用为事实陈述，非错误） |
| `federation_resolve` | 管理员 | `code` | 查询口令在联邦内的源节点（分享创建即自动公告；未接入则不可达） |
| `p2p_status` | 管理员 | — | 设备直传状态：supervisor 是否启用/p2pc 二进制路径与版本/收件区用量（standalone 专属） |
| `p2p_tasks` | 管理员 | — | 列出直传任务（发送/接收中的任务态、对端、进度） |
| `p2p_send` | 管理员 | `paths`（必填，须落在 `p2p.direct.send_roots` 白名单内） | 发起设备直传：spawn 随包 p2pc 发送指定文件/目录，返回 12 位口令（XXXX-XXXX-XXXX）交接收方 |
| `p2p_recv` | 管理员 | `code`（12 位直传口令） | 接收设备直传：spawn p2pc 拉取到收件区（`p2p.direct.recv_dir`），完成后可在 admin 直传控制台发布为分享 |

> 命令行等价面：server 仓 `pb` CLI 自 v1.22.0 起提供 `pb p2p` 八支子命令
> （status/tasks/send/recv/cancel/invites/accept/push，admin API Key 通道），
> 并支持联邦实例间**推送邀请**（对方站点公开收件 `POST /api/v1/p2p/invite`，免手工口令交接）。

`expire_style` 取值：`minute` / `hour` / `day` / `week` / `month` / `year` / `forever`；
`custom_code` 为 3-32 位字母/数字/`-`/`_`（冲突报错）。所有工具结果均为文本块，中文友好。

> `mcp.max_file_size`（默认 6MB，env `PB_MCP_MAX_FILE_SIZE`）约束 share_file 上传与
> download_share_file 下载的单文件大小——base64 膨胀 4/3 后需低于请求体上限
> （max(10MB, upload.max_file_size)），调大本值超过请求体上限时须同步调大
> `upload.max_file_size`。大文件请走 Web/客户端直传通道，MCP 定位是小文件与自动化。

## 快速开始

### 1. 获取管理员 token

```bash
TOKEN=$(curl -s -X POST http://localhost:12345/admin/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<your-password>"}' | jq -r .data.token)
```

- token 有效期 **7 天**（过期后重新登录获取）。
- token 与 Web 管理后台会话同源：在后台登出会使该账号所有 token 失效（全端互踢）。

### 2. 验证连通（裸协议）

服务端无会话状态，可直接调用任意方法（`initialize` 握手非必需）：

```bash
# 握手（可选）
curl -s -X POST http://localhost:12345/api/v1/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'

# 列出工具
curl -s -X POST http://localhost:12345/api/v1/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 调用工具（例：查系统状态）
curl -s -X POST http://localhost:12345/api/v1/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_system_status","arguments":{}}}'
```

### 3. 客户端接入

远程 MCP（Streamable HTTP）通用配置——各客户端字段名略有差异，均含 URL + 请求头两要素：

**Claude Desktop**（`claude_desktop_config.json`）：

```json
{
  "mcpServers": {
    "pigeonbox": {
      "type": "http",
      "url": "http://your-server:12345/api/v1/mcp",
      "headers": { "Authorization": "Bearer <admin-token>" }
    }
  }
}
```

**Claude Code**（命令行一键注册）：

```bash
claude mcp add --transport http pigeonbox http://your-server:12345/api/v1/mcp \
  --header "Authorization: Bearer <admin-token>"
```

**Cursor / 其他标准 MCP 客户端**：在 MCP 配置（如 `~/.cursor/mcp.json`）中添加同构的
`mcpServers` 条目（`type: "http"` + `url` + `headers.Authorization`）。

### 4. （推荐）安装 Agent Skill

本仓附带开箱即用的 agent skill
（[skills/pigeonbox-mcp](https://github.com/pigeonbox/pigeonbox/tree/main/skills/pigeonbox-mcp)），
教 AI 助手正确使用上述协议与全部工具（含自动登录/401 重试的 `scripts/mcp.sh` 助手脚本）：

```bash
# Claude Code / ZCode 等支持 skill 的客户端，复制到项目或用户级 skill 目录即可
git clone https://github.com/pigeonbox/pigeonbox.git
cp -r pigeonbox/skills/pigeonbox-mcp ~/.agents/skills/   # 或 <project>/.agents/skills/、~/.claude/skills/
```

安装后对 AI 说「帮我在 PigeonBox 上分享一段文本 / 看看存储还剩多少 / 清理过期分享」即可触发。

## 安全注意事项

- **MCP 具备管理员级权力**（删分享、清库、读用户列表）。只授予管理员账号的 token，
  不要把 token 写进仓库、聊天记录或前端代码；优先用环境变量/密钥管理注入。
- **务必经 HTTPS 暴露**（反代终结 TLS）。Bearer token 明文跨公网等于交出管理员权限。
- 多副本部署时 MCP 只在 admin 面存在，公网入口天然打不到（404），无需额外封禁。
- 对 AI 客户端开放删除/清理类工具前评估误操作风险：`delete_share` 是**硬删除**（DB 记录 +
  物理文件，不经 v0.13.0 的回收站，不可恢复），`cleanup_expired` 批量清理全部过期分享。
- `mcp.enabled=false` 可整体关闭（env `PB_MCP_ENABLED=false`），关闭后路由不注册。

## 协议细节

- `initialize` 应答：`protocolVersion: "2025-03-26"`，capabilities 只声明 `tools`，`serverInfo.name = "pigeonbox"`。
- 通知类请求（无 `id`）→ HTTP 202 无响应体（MCP 规范）。
- 工具业务失败 → HTTP 200 + `result.isError: true` + 文本说明；协议层错误才用 JSON-RPC error
  （未知方法 `-32601`，非法参数 `-32602`，非法 JSON `-32700`）。
- 服务端无会话/无状态：无需握手、无需 `notifications/initialized`，逐请求独立认证。

## 常见问题

| 现象 | 原因与处置 |
|---|---|
| 404 | `mcp.enabled=false` 已关闭，或请求打在 `PB_DEPLOY_MODE=public` 副本上（改指 admin 面） |
| 401 | token 缺失/过期（7 天）/后台登出被互踢——重新 `POST /admin/login` |
| `-32601` | 方法名拼错；服务端只认 `initialize` / `ping` / `tools/list` / `tools/call` |
| `isError: true` | 工具业务失败（如取件码不存在、custom_code 冲突），读 content 文本即可 |
