---
name: pigeonbox-mcp
description: Upload and download files through a PigeonBox (文件快递柜) server via its built-in MCP endpoint — create text/file shares, read share content, download share files, look up / list / delete shares, check system/storage/federation status, clean up expired shares, and query the P2P federation (online directory of discoverable peers, pending-invite inbox, invite accept). Use whenever the user asks to share or fetch text/files via PigeonBox, administer a PigeonBox instance from an AI assistant, mentions 取件码 / 分享 / 快递柜 / P2P 联邦 — even if they never say "MCP".
---

# PigeonBox MCP

PigeonBox 服务器内置 MCP server：单端点 Streamable HTTP（`POST /api/v1/mcp`），
JSON-RPC 2.0，管理员 JWT 认证，协议层为官方 SDK（最新规范 2026-07-28，握手期旧版向下兼容）。
通过它可以替用户管理文件快递柜：创建分享、查/删分享、看系统与存储状态、列用户、清过期。

**工具结果是结构化输出**：`result.structuredContent` 为带 schema 的对象
（如 `share_text` → `{code, pickup_code, share_url, markdown, has_password}`），
`result.content[0].text` 是同一份 JSON 文本（老客户端回退面）。

## 连接事实

- 端点：`POST {BASE}/api/v1/mcp`；`BASE` 默认 `http://localhost:12345`
- 认证：`Authorization: Bearer <admin JWT>`；token 由 `POST {BASE}/admin/login`
  （body `{"username","password"}`，取 `data.token`）获取，**有效期 7 天**；
  管理后台登出会全端互踢使 token 失效
- 服务端无会话状态：无需 `initialize` 握手，可直接 `tools/call`，逐请求独立认证
- 请求头要求：`Content-Type: application/json` + `Accept: application/json, text/event-stream`
  （MCP 规范要求两者兼具；缺任一项回 HTTP 400/415，不进协议层）
- 部署门控：仅 standalone / admin 模式注册此端点；`PB_DEPLOY_MODE=public` 副本返回
  404 —— 此时换 admin 面地址（多副本拓扑的 `<release>-admin` Service / admin ingress）

## 首选路径：助手脚本

优先使用本 skill 目录下的 `scripts/mcp.sh`（依赖仅 curl + python3；自动登录、token
缓存 600 权限、401 自动重登重试）：

```bash
SCRIPT_DIR="<本 skill 目录>"   # 即本 SKILL.md 所在目录
export PB_BASE_URL=http://your-server:12345
export PB_ADMIN_USER=admin PB_ADMIN_PASSWORD='<密码>'

"$SCRIPT_DIR/scripts/mcp.sh" login                        # 取 token 并缓存
"$SCRIPT_DIR/scripts/mcp.sh" tools                        # 列出工具
"$SCRIPT_DIR/scripts/mcp.sh" call get_system_status '{}'
"$SCRIPT_DIR/scripts/mcp.sh" call share_text '{"text":"会议纪要正文…","expire_style":"day"}'
# 上传本地文件（base64 随请求携带；单文件上限默认 6MB）
"$SCRIPT_DIR/scripts/mcp.sh" call share_file "{\"file_name\":\"a.log\",\"content_base64\":\"$(base64 -i a.log | tr -d '\n')\"}"
# 下载文件分享（输出含 base64 段，解码即得原文件）
"$SCRIPT_DIR/scripts/mcp.sh" call download_share_file '{"code":"AB12CD34"}' | sed -n '/^base64:/,$p' | tail -n +2 | base64 -d > out.bin
```

`call` 输出工具的**结构化出参**（格式化 JSON）；业务失败（`isError: true`）时退出码为 1、
结果照常输出——把它当作工具报错读给用户，不要当作脚本崩溃。

已有 token 时可 `export PB_TOKEN=<jwt>` 跳过登录；`PB_TOKEN_FILE=/dev/null` 禁用缓存。

## 裸 curl 备用（脚本不可用时）

```bash
curl -s -X POST "$BASE/api/v1/mcp" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_system_status","arguments":{}}}'
```

## 工具参考（18 个）

上传/下载：`share_text`、`share_file`、`get_share_content`、`download_share_file`；寄件码与预览：`create_request_code`、`preview_share`；管理：`get_share`、`list_shares`、`delete_share`、`get_system_status`、`get_storage_info`、`list_users`、`cleanup_expired`；P2P 联邦：`federation_status`、`federation_resolve`、`p2p_peers`、`p2p_invites`、`p2p_accept`。

> 设备直传已拆为独立应用 **PigeonBeam**，Box 侧不再编排直传（相关工具已退役）。

> 作用域说明：管理员可见全部 18 个；`PB_MCP_ALLOW_GUEST=true` 时访客另见 `share_text`/`share_file`，登录用户另见 `create_request_code`/`preview_share`（详见 docs/MCP-README.md）。

| 工具 | 参数（JSON arguments） | 说明 |
|---|---|---|
| `share_text` | `text`（必填，≤222KB）、`expire_value`（默认 1）+`expire_style`（minute/hour/day/week/month/year/forever，默认 day）、`password`（可选，给即开启取件密码）、`custom_code`（可选，3-32 位字母数字-_-，冲突报错） | 创建文本分享；返回取件码（6 位）+ 分享码 + 完整链接。经 MCP 创建的分享来源记为 `mcp`，管理端可辨 |
| `share_file` | `file_name`+`content_base64`（必填）、`expire_*`、`password`、`custom_code` | 上传文件建分享（base64，走配额/审核/扩展名白名单），单文件上限 `mcp.max_file_size`（默认 6MB，`PB_MCP_MAX_FILE_SIZE` 可调）；exe 等白名单外类型被拒 |
| `create_request_code` | `title`（投递链接标题，显示给访客）、`max_files`、`max_bytes`（均 0=不限）、`expire_value`（默认 7）+`expire_style`（minute/hour/day/week/month/year，默认 day） | 创建寄件码（反向收件投递链接）：发给对方让其上传文件，落成你名义的分享 |
| `preview_share` | `code`（必填，分享码 8 位/取件码 6 位/自定义口令）、`password`（密码保护分享的取件密码） | 取分享内容预览：文本文件返回摘要文本；图片/视频/文档返回元数据；受取件闸门与密码保护约束 |
| `get_share` | `code`（分享码 8 位/取件码 6 位/自定义口令） | 查详情（分享码/取件码/类型/大小/剩余次数/过期时间），不消耗取件次数；文件分享附子文件清单 |
| `get_share_content` | `code` | 读内容：文本分享返回正文；文件分享返回元数据与文件清单（不消耗取件次数） |
| `download_share_file` | `code` | 下载文件内容（base64 回传）；仅单文件分享（多文件拒绝并提示），已过期拒绝，超上限拒绝；不消耗取件次数 |
| `list_shares` | `page`、`page_size`（≤100）、`keyword`（按分享码/取件码/文件名搜） | 全站分享分页列表 |
| `delete_share` | `code` | **硬删除**（DB + 物理文件，不经回收站，不可恢复），写审计日志 |
| `get_system_status` | — | 版本/文件数/用户数/总占用/今日上传/过期文件 |
| `get_storage_info` | — | 存储类型/容量/已用百分比/文件数 |
| `list_users` | `page`、`page_size` | 用户列表（ID/用户名/邮箱/状态） |
| `cleanup_expired` | — | 清理全部过期分享，返回数量与释放字节 |
| `federation_status` | — | 联邦是否启用/节点 ID/注册中心/最近心跳；**未启用返回正常陈述（非错误）** |
| `federation_resolve` | `code` | 查口令在联邦内的源节点（分享创建即自动公告；未接入联邦返回"不可达"，非错误） |
| `p2p_peers` | — | **在线名录**：可发现对端列表（node_id/name/对外地址/上线时刻）；空名录=对端未开启「可被发现」或离线 |
| `p2p_invites` | — | 待收邀请箱（id/口令/来源/附言/剩余分钟）；TTL 10 分钟 |
| `p2p_accept` | `invite_id`（必填） | 认领待收邀请（**纯信封**：出箱并返回信封；直传接收请用 PigeonBeam 客户端完成） |

## P2P 联邦面（agent 视角）

Box 侧只保留**联邦面**（跨实例路由与邀请交接），设备直传本体在独立应用 PigeonBeam：

1. `federation_status` 看本站是否接入联邦（节点 ID / 注册中心 / 心跳）；未接入是事实陈述，非错误。
2. `federation_resolve {"code":"…"}` 查某个口令在联邦内的源节点（分享创建即自动公告）。
3. `p2p_peers` 列在线名录（可发现对端）；空名录=对端未开启「可被发现」或离线。
4. 收到邀请：`p2p_invites` 轮询待收箱（TTL 10 分钟）→ `p2p_accept {"invite_id":"…"}`
   认领（纯信封：出箱并返回信封）。**真正的文件直传请引导用户用 PigeonBeam 客户端完成。**

**CLI 等价通道**（agent 有 shell 时更轻）：`pb p2p peers/invites/accept/push`。

**能力边界**：联邦邀请与名录对 agent 的语义=「口令 bearer 通道」——密封信箱防第三方窃看，
对端认领即获得口令。

典型任务选型：用户给一段文字要分享 → `share_text`（敏感内容加 `password`，要固定口令给
`custom_code`）；用户给一个本地文件要分享 → `share_file`（>6MB 提示走 Web/客户端直传）；
用户问"xxxx 里是什么" → `get_share_content`（返回 `text` 字段）；用户要取回文件 → `download_share_file`（返回 `content_base64` 字段）；
用户问"存储还剩多少/系统怎么样" → `get_storage_info` / `get_system_status`；定期保洁 →
`cleanup_expired`；联邦/跨站问题 → `federation_status` / `federation_resolve`。

## 错误处理惯例

- `result.isError: true`（HTTP 200）＝业务失败**或入参校验失败**：取件码不存在、custom_code 冲突、
  text 为空、多传了未定义字段、类型不符等，读 content 文本向用户解释并按 schema 补参重试
- JSON-RPC `error`＝协议错误：`-32602` 未知工具（工具不存在不是可自纠的业务失败）
- HTTP 400＝请求层被拒：缺 `Accept: application/json, text/event-stream`、非法 JSON、或方法名不存在
- HTTP 401＝token 过期（7 天）或后台登出互踢 → 重新登录
- HTTP 404＝端点未开启（`PB_MCP_ENABLED=false`）或打在 public 副本上 → 换 admin 面地址

## 安全红线

这组工具等价于管理员权限。`delete_share`、`cleanup_expired` 不可逆——AI 在执行删除类
操作前应向用户复述目标并确认；密码与 token 只经环境变量传递，不写入任何被跟踪的文件；
对外地址必须经 HTTPS 暴露（Bearer 明文跨公网等于交出管理员权限）。
