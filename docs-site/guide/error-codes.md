---
title: 错误码对照表
---

# 错误码对照表

面向集成者：程序化对接 PigeonBox API 时判断成功/失败、按业务码分支处理的权威依据。对照表与代码同源——新码真相源 [contracts/errcode/errcode.go](https://github.com/pigeonbox/contracts/blob/main/errcode/errcode.go)，legacy 码见 core 仓 `pkg/errors/errors.go`。

## 响应包络与成功码

所有业务接口返回统一包络：

```json
{"code": <业务码>, "message": "...", "data": {...}}
```

**唯一成功码是 `code: 0`**（2026-10-15 统一，此前老端点返回 200 的双轨已退役）。兼容期内服务端与官方客户端（前端 / pb CLI）仍同时接受 `200`，但**新集成代码请只认 0**：

```text
code == 0                  → 成功
其余                       → 失败，读 message 并按下方表分支
```

HTTP 状态码与业务码基本一致（400/401/403/404/422/429/500），可直接用 HTTP 层做粗筛、业务码做精判。

> **破坏性变更提示（第三波，2.0.0/2026-10-16）**：取件密码弃走 URL——`/share/download` 与 `/share/select` 停收 `?password=` query（有访问日志/Referer 泄漏面）。密码改经 POST body（`/anonymous/retrieve`）或 `X-Share-Password` 请求头（`/share/select`）校验；文件下载一律凭取件流程签发的时间窗令牌（`/share/download?code=&token=`），无令牌=20011。官方前端/CLI/MCP 已同车对齐。
> **破坏性变更提示**：错误码统一分两波落地——第一波（core v0.22.0）：老端点成功 `200→0`、legacy 短码 `1001-1006` 迁入 errcode、认证失败包络码 `401` 字面量改为 `10002/20003/40007`；第二波（core v0.23.0）：HTTP 语义镜像码全量收编（`400→10001`、`404→10004`、`500→10008` 等，见上）。HTTP 状态码始终不变；官方客户端已同车对齐。仍在线上看到旧值的只可能是未升级的旧实例。

## 处理建议

1. **先判包络再取 data**：按上行规则判成功；失败时 `message` 是面向人的文案，分支逻辑用 `code`。
2. **按段位归类**：`1xxxx` 通用（参数/认证/限流）、`2xxxx` 分享与取件、`3xxxx` 存储、`4xxxx` 用户与认证、`5xxxx` 系统内部、`9xxxx` 第三方。段位语义稳定，未知码可先按段位兜底。
3. **HTTP 语义镜像码（已收编，2026-10-15 二波）**：此前部分端点的包络码直接镜像 HTTP 语义（400/403/404/429/500 字面量），现已全量收编 errcode——`400→10001`、`403→10003`、`404→10004`、`405→10009`、`409→10016`、`413→10010`、`416→10001`、`422→20009`（分片哈希不符）、`429→10005`、`500→10008`、`502/503→10006`、`401→10002/40007/20003`（见下条）。不经业务包络的只剩网关/反代层响应（非 JSON）。
4. **认证类码值与 HTTP 状态**：HTTP 层仍以 401/403 表意，包络码已 errcode 化——未登录/token 缺失或无效=`10002`；取件密码门（缺密码/密码错）=`20003`（HTTP 401，`data.has_password=true`）；无效 API Key=`40007`（HTTP 401，统一文案防枚举）；角色不足=`10003`；缺失下载令牌=`20011`。
5. **不要对 `message` 做字符串匹配**：文案随版本演进，分支只认 `code`。
6. **"取不到件"有三档，别混**（2026-10-23 口径收口，2026-10-24 再校）：`20001`=文件**还没传完**，稍后重试；`10004`=分享**不存在/已过期**（时间过期）；`20004`=**超过取件次数**（次数用完；匿名取件码通道为 `20007`「取件码已用完」）。三者都是 404/403 家族，但动作完全不同（等 / 放弃 / 重传）。常量名 `CodeShareNotFound` 属历史遗留，**别按名字推断语义**。
   > 2026-10-24 起「次数用完」不再伪装成「不存在/已过期」：此前它混在 `IsExpired` 里 ⇒ 收件人看到 404「分享不存在或已过期」，且**按取件次数的分享最后一次取件必然 404 拿不到文件**。

## 全量业务码（contracts/errcode）

### 成功

| code | 常量 | 含义 |
|---|---|---|
| 0 | `CodeSuccess` | 成功（同义：老端点的 200） |

### 1xxxx 通用

| code | 常量 | 含义 |
|---|---|---|
| 10000 | `CodeUnknown` | 未知错误 |
| 10001 | `CodeInvalidParam` | 参数错误 |
| 10002 | `CodeUnauthorized` | 未登录 / 凭证缺失 |
| 10003 | `CodeForbidden` | 无权限 |
| 10004 | `CodeNotFound` | 资源不存在（分享不存在/已过期走此码；与 `20001` 的"未完成上传"区分开）|
| 10005 | `CodeRateLimit` | 限流（请求过多） |
| 10006 | `CodeUnavailable` | 服务不可用 |
| 10007 | `CodeTimeout` | 请求超时 |
| 10008 | `CodeInternal` | 内部错误 |
| 10009 | `CodeMethodNotAllowed` | 方法不允许 |
| 10010 | `CodeTooLarge` | 请求体过大：单请求体超 `upload.upload_size`，或整文件超 `upload.max_file_size`（直传/分片通道的整文件上限）。**后端文案带具体上限值**，客户端可直接展示 |
| 10011 | `CodeTooManyAttempts` | 尝试过频已临时锁定（防爆破锁定；`message` 含剩余秒数） |
| 10012 | `CodeUploadDisabled` | 上传已关闭（`upload.open_upload=false` 或未满足登录要求） |
| 10013 | `CodeIPBlocked` | 来源 IP 已被封禁（预留段位） |
| 10014 | `CodeAnonymousQuota` | 匿名上传日配额已用尽 |
| 10015 | `CodePresignDisabled` | 匿名直传未开放（客户端应回退普通上传通道） |
| 10016 | `CodeConflict` | 资源冲突（重复创建/状态互斥；承接 legacy 1005） |

### 2xxxx 分享 / 取件

| code | 常量 | 含义 |
|---|---|---|
| 20001 | `CodeShareNotFound` | 分享**未完成上传**（占位分享：文件还没传上来）。取件页/预览/匿名取件五面同码同文案。这是投递到柜的**正常中间态**（对方先拿码、文件后到），不是"分享已失效" |
| 20002 | `CodeShareExpired` | 分享过期 —— **保留码位，当前未发射**；分享不存在/已过期实际走 `10004` |
| 20003 | `CodeSharePasswordWrong` | 取件密码错误 |
| 20004 | `CodeShareReachLimit` | 超过取件次数（`count` 过期样式耗尽，HTTP 403）——2026-10-24 起正式发射；匿名取件码通道用 `20007` |
| 20005 | `CodePickupCodeNotFound` | 取件码（6 位）不存在 |
| 20006 | `CodePickupCodeExpired` | 取件码已过期 |
| 20007 | `CodePickupCodeExhausted` | 取件码已用完 |
| 20008 | `CodeFileNotFound` | 文件不存在 |
| 20009 | `CodeChunkInvalid` | 分片无效 |
| 20010 | `CodeUploadSessionGone` | 上传会话不存在或已失效（重新 init） |
| 20011 | `CodeDownloadToken` | 下载令牌无效或已过期（取件必须先 select 拿 `download_url`） |
| 20012 | `CodeShareBlocked` | 分享已被管理员禁用 |
| 20013 | `CodeSharePendingReview` | 分享待审核，暂不可取 |

### 3xxxx 存储

| code | 常量 | 含义 |
|---|---|---|
| 30001 | `CodeStorageInit` | 存储初始化失败 |
| 30002 | `CodeStorageQuota` | 存储配额超限 |
| 30003 | `CodeStorageUpload` | 上传失败 |
| 30004 | `CodeStorageDownload` | 下载失败 |
| 30005 | `CodeStorageDelete` | 删除失败 |
| 30006 | `CodeStorageScheme` | 存储方案不支持 |
| 30007 | `CodeStorageIO` | 存储 IO 错误 |
| 30008 | `CodePresignFailed` | 预签名生成失败 |
| 30009 | `CodePresignToken` | 预签名 token 无效 |
| 30010 | `CodePresignExpired` | 预签名已过期 |
| 30011 | `CodeFileTypeDenied` | 文件类型不允许（黑名单/白名单/魔数校验未过，改名绕不过） |
| 30012 | `CodeEndpointDenied` | 存储端点地址不合法（scheme/SSRF 守卫） |
| 30013 | `CodeContentRejected` | 内容未通过审核（敏感词等） |

### 4xxxx 用户 / 认证

| code | 常量 | 含义 |
|---|---|---|
| 40001 | `CodeUserNotFound` | 用户不存在 |
| 40002 | `CodeUserExists` | 用户已存在 |
| 40003 | `CodePasswordWrong` | 密码错误 |
| 40004 | `CodeUserDisabled` | 用户已禁用 |
| 40005 | `CodeTokenInvalid` | Token 无效 |
| 40006 | `CodeTokenExpired` | Token 过期 |
| 40007 | `CodeAPIKeyInvalid` | API Key 无效 |
| 40008 | `CodePermissionDeny` | 权限不足 |
| 40009 | `CodeRegClosed` | 注册已关闭 |
| 40010 | `CodeEmailInvalid` | 邮箱格式错误 |
| 40011 | `CodePasswordWeak` | 密码强度不足 |

### 5xxxx 系统

| code | 常量 | 含义 |
|---|---|---|
| 50001 | `CodeDBError` | 数据库错误 |
| 50002 | `CodeCacheError` | 缓存错误 |
| 50003 | `CodeConfigErr` | 配置错误 |
| 50004 | `CodeSchedule` | 调度错误 |
| 50005 | `CodeNotInit` | 系统未初始化 |
| 50006 | `CodeAlreadyInit` | 系统已初始化 |

### 9xxxx 第三方

| code | 常量 | 含义 |
|---|---|---|
| 90001 | `CodeThirdPartySMS` | 短信发送失败 |
| 90002 | `CodeThirdPartyEmail` | 邮件发送失败 |
| 90003 | `CodeThirdPartyAPI` | 第三方 API 失败 |

## legacy 1001-1006（已迁移，2026-10-15）

core 仓早期的 `pkg/errors` 短码已整体退役：常量名保留为别名、值重钉到 contracts/errcode 对应项，所有发射点一次性迁移，wire 上不再出现旧值。收到下表左列旧值只可能来自未升级的旧实例：

| 旧值 | 现值 | 常量 |
|---|---|---|
| 1001 | 10001 | `CodeInvalidParam` |
| 1002 | 10002 | `CodeUnauthorized` |
| 1003 | 10003 | `CodeForbidden` |
| 1004 | 10004 | `CodeNotFound` |
| 1005 | 10016 | `CodeConflict` |
| 1006 | 10008 | `CodeInternal` |
| 1007（预留，无调用方） | 10006 | `CodeUnavailable` |
| 1008（预留，无调用方） | 10005 | `CodeRateLimit` |

## 相关页面

- 上传/取件端到端对接：[API-UPLOAD-INTEGRATION.md](https://github.com/pigeonbox/pigeonbox/blob/main/docs/API-UPLOAD-INTEGRATION.md)（hub 仓库 docs/）
- 认证凭据（API Key）：[API Token](/reference/api-tokens)
