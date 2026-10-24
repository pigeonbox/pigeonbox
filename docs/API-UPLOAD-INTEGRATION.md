# PigeonBox 上传对接指南（API）

面向第三方系统 / 脚本的开发文档：如何通过 HTTP API 向 PigeonBox 上传文本与文件、并让对方取件。
当前示例统一以 `http://your-host:12345` 为 Base URL（下文记作 `$BASE`），对接时替换为你的部署地址即可。

> 认证凭据（API Key）的申请与吊销见 [API-TOKENS.md](API-TOKENS.md)；本文假设你已持有一把 `pb_sk_` 开头的 Key。

## 0. 30 秒上手

```bash
BASE=http://your-host:12345
KEY=pb_sk_xxxxxxxxxxxxxxxxxxxx

# 上传一个文件（≤10MB），拿到取件码
curl -X POST "$BASE/share/file/" \
  -H "Authorization: Bearer $KEY" \
  -F "file=@./report.pdf" \
  -F "expire_value=1" -F "expire_style=day" -F "require_auth=false"
# → {"code":0,"message":"文件上传成功","data":{"code":"41ySgNX0","url":"http://your-host:12345/#/share/41ySgNX0","pickup_code":"KJ8Y2M"}}

# 把取件链接发给对方，对方浏览器打开 $BASE/#/share/41ySgNX0 即可取件；
# 程序化取件见 §6，链接形态见 §1.5。
```

## 1. 通用约定

### 1.1 认证

三种请求头等价，任选其一；**不支持 URL query 传 Key**（防日志泄露，服务端直接忽略）：

```
Authorization: Bearer pb_sk_xxx    # 首选
Authorization: ApiKey pb_sk_xxx
X-API-Key: pb_sk_xxx
```

- 携带 Key：上传归因到你的账号（`upload_type=authenticated`），按账号配额计。
- 不带 Key：按匿名处理，受匿名开关与 per-IP 日配额约束（站点关闭匿名上传时会被拒）。
- Key 无效 / 过期 / 吊销：一律 HTTP `401` + 包络码 `40007` `{"code":40007,"message":"Invalid API Key"}`（不区分原因，防枚举）。
- 单 Key 限流：默认 20 QPS（突发 40），超限 `429`，业务码 `10011`。
- 多次携带无效 Key 会被临时锁定（429，"尝试过于频繁"），停止请求等剩余秒数即可。
- Key 不能做的事：访问 `/admin/**`、管理 Key 本身（`/user/api-keys` 仅 JWT）。上传管控（开关 / 类型白黑名单 / 配额）对 Key 请求同样生效。

### 1.2 响应包络

所有接口返回 `{"code": <业务码>, "message": "...", "data": {...}}`；**`code=0` 为唯一成功码**（2026-10-15 统一，老端点的 200 已退役，服务端兼容期仍接受）。HTTP 状态码与业务码基本一致（400/401/403/404/429/500）。全量对照见文档站错误码对照表页（docs-site/guide/error-codes.md）。

### 1.3 过期参数

| 字段 | 说明 |
|---|---|
| `expire_style` | `minute` / `hour` / `day` / `week` / `month` / `year` / `forever` / `count` |
| `expire_value` | 与 style 配对的数量：`day`+`1` = 1 天；`count`+`5` = 取件 5 次后失效；`forever` 忽略 value |

样式可被管理员裁剪（`upload.allowed_expire_styles`），被禁的样式返回 400。

### 1.4 常见错误码

| 业务码 | 含义 | 对策 |
|---|---|---|
| 10001 | 参数错误 | 检查表单 / JSON 字段 |
| 10002 | 未登录 / 凭证缺失 | 该端点需要认证 |
| 401 (HTTP) + 40007 | `Invalid API Key`（包络码已 errcode 化） | 换 Key / 联系管理员 |
| 10010 | 请求体过大 | 两种场景共用此码：单请求体超 `upload.upload_size`（改走分块通道 §5），或整文件超 `upload.max_file_size`（站点的单文件上限，由管理员在后台配置）。**`message` 带具体上限值**，按它判断 |
| 10011 | 尝试过频已临时锁定 | 等待 `message` 中的剩余秒数 |
| 10012 | 上传已关闭 / 要求登录 | 带上 Key 重试 |
| 10014 | 匿名日配额用尽 | 带 Key 上传 |
| 20004 | 超过取件次数（`count` 过期样式耗尽，HTTP 403）；匿名取件码通道为 `20007` | 重新上传 |
| 10004 | 分享不存在或已过期 | 确认链接/码是否正确 |
| 20001 | 占位分享：文件**尚未上传完成** | 等上传完成再取（别当"已失效"，也别重传）|
| 20010 | 上传会话不存在 | 分块会话过期，重新 init |
| 20011 | 缺少下载令牌 | 取件必须先 select 拿 `download_url`（§6） |
| 20013 | 分享待审核 | 等管理员审核 |
| 30011 | 文件类型不允许 | 黑名单 / 白名单 / 魔数校验未过 |

完整清单见 `contracts/errcode/errcode.go`；**全量业务码对照表（含含义与默认文案）见文档站 error-codes 页**（[docs-site/guide/error-codes.md](../docs-site/guide/error-codes.md)），按 code 分支处理时以该表为准。

> ⚠️ **不要按码名推断行为**：`20002`（分享过期）当前**未发射**（保留码位）——分享不存在/已过期走 `10004`，取件次数耗尽走 `20004`（匿名取件码通道 `20007`），占位分享（文件未传完）走 `20001`。三者都是 HTTP 404/403 家族，但**语义不同**：20001 是"还没好，稍后再来"。
>
> **取件次数的计次口径（2026-10-24 起）**：一次取件 = 一次**内容交付**，且**一个下载令牌（取件会话）至多扣 1 次**。多文件逐个下载、断点续传、重复点击都算同一次取件（只扣 1 次）；文本分享在取件页首次交付正文时扣次；取件码通道的取件查询只发凭证、不扣次。

### 1.5 两种链接，别混用

PigeonBox 前端用 **hash 路由**（页面地址的路由段在 `#` 之后），所以有两种链接：

| 形态 | 用途 | 备注 |
|---|---|---|
| `{base}/#/share/{code}` | **分享页链接**：人点开看内容 / 输密码 / 下载 | ✅ 要发给用户的就是它 |
| `{base}/share/download?code={code}&token={token}` | **直链**：带下载令牌，服务端校验 | 令牌短时效；令牌必须在 query 里（落在 `#` 之后服务端收不到） |

⚠️ **`{base}/share/{code}`（少个 `#`）是死链，不要拼**：

- docker 前后端分离部署：前端 nginx 把 `/share/*` 反代给后端，而后端没有这条页面路由 ⇒ **HTTP 404**；
- 原生单进程部署（fnOS / QNAP / OpenWrt）：虽然回退到 SPA 首页，但首页用相对资源路径 ⇒ 浏览器按 `/share/` 解析资源 ⇒ **整页白屏**。

⇒ 分享页链接一律 `{base}/#/share/{code}`（`data.url` / `data.share_url` 就是这个形态，**直接用，不要自己拼**）。
需要带令牌的直链时走 §6 的 `/share/select/`，从响应里取 `download_url`。

### 1.6 两种码：分享码（8 位）与取件码（6 位）

每个分享有**两个码**，指向同一份内容，但强度语义不同：

| 码 | 响应字段 | 长度 | 语义 |
|---|---|---|---|
| 分享码 | `data.code` | 8 位（登录用户可自定义，3-32 位字母/数字/`-`/`_`）| 分享的正式标识 |
| 取件码 | `data.pickup_code` | 6 位数字 | **口令**：凭码即可取件，熵低于分享码 |

- **两种码都能当链接打开**：`{base}/#/share/{分享码}` 与 `{base}/#/share/{取件码}` 进同一个分享页（2026-10-23 起）。匿名投递（对方先拿码、文件后到）就是靠这条链路。
- **程序化取件两种码都收**：`/share/select/?code=` 与 `POST /anonymous/retrieve` 的 `code` 都接受分享码或取件码。
- **响应里的 `data.code` 一律是规范分享码**：即使你传的是取件码，返回的 `code` 与 `download_url` 里用的也都是规范分享码 ⇒ 后续按它走即可（下载令牌也是按规范码签发的，用取件码自行拼直链必然 401/20011）。
- ⚠️ **取件码是口令语义**：把取件码转交出去 = 交出取件凭据（拿到就能取，强度低于分享码）。要长期分享、或对接第三方系统，用分享码。

## 2. 通道怎么选

| 场景 | 通道 | 单文件上限 |
|---|---|---|
| 普通文件（配置/报表/图片…） | 直传 `POST /share/file/`（§3） | `upload.upload_size`（单请求体上限，默认 10 MB） |
| 大文件（整文件单请求） | 预签名直传 `POST /api/v1/presign/upload` + `PUT`（§5.4） | `upload.max_file_size`（整文件上限，管理员在后台「上传与分享 → 单文件上限」配置，默认不限） |
| 大文件（分块） | 分块 `POST /chunk/upload/*`（§5） | `upload.max_file_size`（同上） |
| 代码片段 / 日志 / 文本内容 | `POST /share/text/`（§4） | 222 KB（`upload.text_max_bytes`） |

> **体积上限的业务判定在服务端**：整文件超限时在 init 阶段即被拒（业务码 10010，`message` 写明具体上限），不会白传流量。反向代理的请求体上限（compose 的 `PB_MAX_BODY_SIZE` / ingress 的 `proxy-body-size`）只是**物理防线**，须 ≥ `upload.max_file_size`；代理层直接返回 HTTP 413（不经业务包络）时才是它卡住了。

> 多文件打包分享自 server v0.9.3 / core v0.7.7 起**已开放**:`POST /api/v1/share/multi-direct`(multipart 多文件直传打包)与 `POST /api/v1/share/multi-bind`(把多个已传 chunk 会话绑定为一个多文件分享)。更早版本镜像调用返回 404,届时可循环单文件通道或客户端自行打 zip。

## 3. 文件直传（推荐，≤10MB）

`POST /share/file/`，`multipart/form-data`：

| 字段 | 必填 | 说明 |
|---|---|---|
| `file` | ✅ | 文件本体；用 `filename=` 指定对方看到的原始文件名 |
| `expire_value` / `expire_style` | ✅ | 见 §1.3（**没有默认值**，缺任一字段返回 10001） |
| `require_auth` | ✅ | `true` 时取件需密码，配合 `password` 字段；传 `false` 表示不设密码（**没有默认值**，缺该字段返回 10001） |
| `password` | 否 | 取件密码（服务端只存 bcrypt 哈希） |
| `note` | 否 | 文件备注（取件页展示给收件人） |

```bash
curl -X POST "$BASE/share/file/" \
  -H "Authorization: Bearer $KEY" \
  -F "file=@./report.pdf;filename=2026-10-月报.pdf" \
  -F "expire_value=7" -F "expire_style=day" \
  -F "require_auth=true" -F "password=取件密码"
```

成功响应：

```json
{"code":0,"message":"文件上传成功",
 "data":{"code":"41ySgNX0","url":"http://your-host:12345/#/share/41ySgNX0","pickup_code":"KJ8Y2M"}}
```

- `data.code` 是 8 位分享码，`data.url` 是**人类取件页链接**（hash 路由形态，见 §1.5，**直接用**）。**给程序对接只传分享码**。
- `data.pickup_code` 是 6 位取件码（文本/文件/永久分享同权铸造；E2E 密文分享不铸造为空）——两条码等效可取件，6 位码适合口头/短信报码，走匿名快捷通道（§6）。
- **取件码也能直接当页面链接用**：`$BASE/#/share/{取件码}` 可直接打开取件页（取件码在分享域同样可解析，2026-10-23 起）。适合"发个链接给对面"的场景。
- `data.deduped=true` 表示秒传去重命中（同账号历史同 hash+size 文件，免落盘直接出码，引用既有存储对象）。
- 文件名消毒规则：路径分隔符等危险字符会被清理，磁盘存储名是 UUID，对方取件时展示你传入的原始名。

## 4. 文本分享

`POST /share/text/`，支持 JSON 或表单：

```bash
curl -X POST "$BASE/share/text/" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"text":"要分享的文本内容","expire_value":1,"expire_style":"day","require_auth":false}'
# → {"code":0,"message":"分享成功","data":{"code":"Fv9hSrhz","url":"http://your-host:12345/#/share/Fv9hSrhz","pickup_code":"KJ8Y2M"}}
```

- 内容会做 HTML 转义（XSS 防护），上限默认 222 KB。
- `expire_value` / `expire_style` / `require_auth` 三个字段**都是必填**（没有默认值，缺任一返回 10001）。
- 需要密码时，JSON body 里带 `password` 字段即可（`-d '{"text":"…","require_auth":true,"password":"…"}'`）；表单方式 `-F "text=..." -F "require_auth=true" -F "password=..."` 同样有效。

## 5. 分块上传（大文件 / 弱网 / 秒传）

四步：**init → 逐片上传 → complete**（可随时 status / cancel）。全部通过同一 Key 认证，会话与你的身份绑定，他人无法劫持。

### 5.1 init —— 创建会话（可秒传）

`POST /chunk/upload/init/`，JSON：

```json
{
  "file_name": "big-video.mp4",
  "file_size": 1572864,
  "file_hash": "<整个文件的 SHA-256 hex，强烈建议传>",
  "chunk_size": 786432,
  "total_chunks": 2
}
```

响应：

```json
{"code":0,"message":"初始化成功",
 "data":{"upload_id":"48cb83ea…","chunk_size":"786432","total_chunks":"2",
         "is_quick_upload":false,"share_code":""}}
```

**秒传**：`file_hash` 命中**本账号**已有同内容文件时（同用户内去重），直接返回 `is_quick_upload:true` + `share_code`，**流程到此结束**，无需再传分片。init 可顺带携带 `note`（文件备注，complete 落成分享后随取件页展示）。

### 5.2 逐片上传

`POST /chunk/upload/chunk/{upload_id}/{chunk_index}`，multipart，分片放 `chunk` 字段。建议每片附带哈希做强校验（`hash` 字段：32 位按 MD5、64 位按 SHA-256，不符返回 422 可重试该片）：

```bash
curl -X POST "$BASE/chunk/upload/chunk/$UPLOAD_ID/0" \
  -H "Authorization: Bearer $KEY" \
  -F "chunk=@./part-000" -F "hash=$(md5 -q ./part-000)"
# → {"code":0,"message":"分片上传成功","data":{"chunk_index":0,"chunk_hash":"a2d1…"}}
```

- 分片索引从 **0** 开始；分片可乱序、可重传。
- 断点续传：中断后重新 init（同 file_hash 会得到同 upload_id），再 `GET /chunk/upload/status/{upload_id}` 查已传分片，只补缺失的。

### 5.3 complete —— 合并建分享

所有分片到齐后：

```bash
curl -X POST "$BASE/chunk/upload/complete/$UPLOAD_ID" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"upload_id":"48cb83ea…","expire_value":1,"expire_style":"day","require_auth":false}'
```

```json
{"code":0,"message":"上传完成",
 "data":{"share_code":"7GVACfJb","share_url":"http://your-host:12345/#/share/7GVACfJb",
         "file_name":"chunk-test.bin","file_size":1572864}}
```

- `data.share_url` 是**分享页链接**（hash 路由形态，见 §1.5，**直接用**）。它不带下载令牌 —— 令牌由 `/share/select/` 在取件时签发（见 §6）。
- ⚠️ **`share_url` 的域名不可信**（部署方 `server.base_url` 配置差异，实测曾返回 `localhost:12345`）。要自己拼域名时，**路径段必须带 `#`**：`$BASE/#/share/{share_code}`；写成 `$BASE/share/{share_code}` 是死链（§1.5）。
- 放弃上传：`DELETE /chunk/upload/cancel/{upload_id}`，清理服务端已传分片。

### 5.4 预签名直传（整文件一次 PUT，省流量）

大文件不想过分片、或后端配了对象存储时走这条：**init → PUT 整文件 → complete**。三步都是公开面（`/api/v1/presign/*`），**不需要 API Key**，但受站点的「允许访客上传」开关门控。

**① init** —— `POST /api/v1/presign/upload`，JSON：

```json
{
  "file_name": "images.tar",
  "file_size": 3428034560,
  "content_type": "application/octet-stream",
  "expire_value": 1,
  "expire_style": "day"
}
```

响应（`scheme` = `self` 表示流量经服务器中转；`s3` 表示直传对象存储、不过服务器）：

```json
{"code":0,"message":"success",
 "data":{"upload_id":"up_424a97edf597df090e11b022",
         "upload_url":"http://your-host:12345/api/v1/presign/upload-direct/up_424a97edf597df090e11b022",
         "method":"PUT",
         "headers":{"X-Upload-Token":"d830867c569b84bb6867898548c6b15187a62e85429739b7f3d20dcdbf3d481a"},
         "expire_seconds":600,
         "object_key":"uploads/2026/10/23/up_424a97edf597df090e11b022.bin",
         "scheme":"self",
         "token":"d830867c569b84bb6867898548c6b15187a62e85429739b7f3d20dcdbf3d481a"}}
```

**② PUT 整文件** —— 用响应里的 `upload_url` 与 `headers` 原样 PUT：

```bash
curl -X PUT "$UPLOAD_URL" \
  -H "X-Upload-Token: $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @./images.tar
```

**③ complete** —— `POST /api/v1/presign/complete`，JSON：

```bash
curl -X POST "$BASE/api/v1/presign/complete" \
  -H "Content-Type: application/json" \
  -d '{"upload_id":"up_424a97edf597df090e11b022","token":"d830867c…"}'
```

```json
{"code":0,"message":"success",
 "data":{"code":"hreCXAsf","url":"/#/share/hreCXAsf",
         "file_name":"images.tar","file_size":3428034560,
         "download_url":"http://your-host:12345/share/download?code=hreCXAsf&token=…",
         "pickup_code":"9Z6SZD"}}
```

- `data.url` 是分享页链接（hash 路由，形态同 §1.5）；`data.download_url` 是带令牌的直链。
- `data.pickup_code` 是 6 位取件码（与文件分享同权铸造）。
- ⚠️ **PUT 的 body 字节数必须与 init 申报的 `file_size` 完全一致**（多一个字节都拒，报「文件大小与申报不符」）。`Content-Length` 也要如实填。
- ⚠️ **`upload_url` 直接用响应里的**，不要自己拼 —— 站点 `server.base_url` 未配置时它按请求 Host 推断，自拼容易拼错端口（§9）。
- 整文件超限时 **init 阶段就拒**（业务码 `10010`，`message` 写明具体上限字节数），不产生任何上传流量。

## 6. 取件方对接（无认证）

取件是**口令语义**，不认 API Key——拿到取件码的任何人都可取，这正是产品用途。两步：

```bash
# ① 元数据 + 签名下载链接
curl "$BASE/share/select/?code=41ySgNX0"
# {"code":0,"message":"获取成功","data":{"code":"41ySgNX0","text":"…(文本件时为内容)",
#  "file_name":"","file_size":"70","has_password":false,
#  "expire_time":"2026-10-05 13:31:04",
#  "download_url":"/share/download?code=41ySgNX0&token=…",
#  "files":[{"id":1,"name":"fcb-token-upload-test.txt","size":70}]}}

# ② 凭 download_url 下载（token 短时效，随取随用，不要缓存）
curl -o out.txt "$BASE$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['download_url'])")"
```

- **必须先 select 再 download**：直接访问 `/share/download?code=…` 会 `401 code=20011`（缺少下载令牌）。
- **密码件**：密码走请求头 `X-Share-Password`，**不再支持 `?password=` query**（query 会进访问日志与 Referer，已于 2026-10-16 收敛）：
  ```bash
  curl "$BASE/share/select/?code=xxx" -H "X-Share-Password: 取件密码"
  ```
  密码错返回 `401 code=20003`，响应 `data.has_password=true`（据此提示用户输密码，别去猜「密码错误 vs 需要密码」）。取件连续失败同样触发防爆破锁定（10011）。
- 文本件：select 响应的 `data.text` 即内容，无需下载。
- 也可用 `GET /anonymous/search/{code}` 做轻量存在性查询。
- **6 位取件码快捷通道**：分享响应里的 `pickup_code`（6 位）与 8 位分享码等效，走匿名通道 `POST /anonymous/retrieve`（JSON `{"code":"KJ8Y2M","password":"…"}`；密码件在 **body** 里传，不在 query）取元数据——同闸门校验，适合口头/短信报码场景。
  - 下载用 **retrieve 响应里的 `data.download_url`**（形如 `/share/download?code=…&token=…`），拼上 `$BASE` 直接下载。
  - **扣次口径（2026-10-24，与 §1.4 段一致）**：一次取件 = 一次**内容交付** = 一个下载令牌（取件会话），同一令牌**至多扣 1 次**。
    - `POST /anonymous/retrieve` **只发凭证、不扣次**（也不记取件人）；扣次发生在随后的 `/share/download` **交付那一刻**，按令牌指纹去重 ⇒ 多文件逐个下载、断点续传、重复点击都算同一次取件（只扣 1 次）。
    - 文本分享按 **（分享码, 取件人 IP）** 计次：同一 IP 反复打开取件页只扣 1 次（能一直看），不同取件人各扣 1 次 ⇒ owner 设的「N 次」= N 个**取件者**。
    - ⚠️ 旧文档曾写「retrieve 自己扣次数并记取件人」——**已过时**（那是一次取件扣 2 次的老实现），请以本段与 §1.4 为准。
  - ⚠️ `GET /anonymous/download/{code}` 只对**无密码**分享可用；密码保护分享一律 401（`code=20003`，`data.has_password=true`），必须走 retrieve 拿 `download_url`。
- **取件码也能走分享域（2026-10-23 起）**：`GET /share/select/?code={取件码}` 与 `GET /share/select/?code={分享码}` 等价（大写/小写均可），响应里的 `data.code` 统一归一为 **8 位分享码**，`download_url` 也是 ⇒ 两种码随便用，取件页链接可直接拼 `$BASE/#/share/{取件码}`。
- **占位分享（文件还没传上来）**：`/share/select/?code=` 返回 `404 code=20001`「分享未完成上传，暂时无法取件」。这是**投递到柜**的正常中间态（对方先拿码、文件后到），**不是"分享已失效"**（那是 `10004`）——别把 20001 当失败去重传，也别当"已过期"通知用户。

## 7. 上传后管理（Key 或 JWT）

```
GET    /api/v1/user/shares?status=active&search=&page=1&page_size=20   # 我的分享
POST   /api/v1/user/shares/batch-delete   # 软删，body: {"codes":["41ySgNX0"]} 
POST   /api/v1/user/shares/batch-extend   # 批量延期
POST   /api/v1/user/shares/{code}/restore # 恢复软删
DELETE /api/v1/user/shares/{code}/hard    # 永久删除（仅已软删的）
```

## 8. Python 参考实现

自动选通道（≤8MB 直传，否则分块），含秒传与重试：

```python
import hashlib, os, requests

BASE = "http://your-host:12345"
KEY  = "pb_sk_xxxxxxxxxxxx"
H    = {"Authorization": f"Bearer {KEY}"}

def sha256_file(path, buf=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(buf):
            h.update(chunk)
    return h.hexdigest()

def upload(path, expire_value=1, expire_style="day", chunk_size=4 << 20):
    size = os.path.getsize(path)
    digest = sha256_file(path)
    if size <= 8 << 20:                                   # ---- 直传 ----
        with open(path, "rb") as f:
            r = requests.post(f"{BASE}/share/file/", headers=H,
                files={"file": (os.path.basename(path), f)},
                data={"expire_value": expire_value, "expire_style": expire_style,
                      "require_auth": "false"},           # 必填字段：没有默认值
                timeout=120)
    else:                                                 # ---- 分块 ----
        total = (size + chunk_size - 1) // chunk_size
        r = requests.post(f"{BASE}/chunk/upload/init/", headers=H, json={
            "file_name": os.path.basename(path), "file_size": size,
            "file_hash": digest, "chunk_size": chunk_size, "total_chunks": total}, timeout=30)
        d = r.json()["data"]
        if not d["is_quick_upload"]:
            uid = d["upload_id"]
            with open(path, "rb") as f:
                for i in range(total):
                    piece = f.read(chunk_size)
                    requests.post(f"{BASE}/chunk/upload/chunk/{uid}/{i}", headers=H,
                        files={"chunk": piece}, data={"hash": hashlib.md5(piece).hexdigest()},
                        timeout=120)
            r = requests.post(f"{BASE}/chunk/upload/complete/{uid}", headers=H, json={
                "upload_id": uid, "expire_value": expire_value, "expire_style": expire_style,
                "require_auth": False},                   # 必填字段：没有默认值
                timeout=120)
    body = r.json()
    if body.get("code") != 0:                             # 成功码是 0（不是 200）
        raise RuntimeError(f"upload failed: {body}")
    code = body["data"].get("code") or body["data"]["share_code"]
    # 分享页链接 = hash 路由形态（少个 '#' 是死链，见 §1.5）
    return code, f"{BASE}/#/share/{code}"

if __name__ == "__main__":
    print(upload("/path/to/file.bin"))
```

## 9. 注意事项（实测踩坑）

1. **分享页链接是 hash 路由形态**：`$BASE/#/share/{code}`。少个 `#` 的 `$BASE/share/{code}` 是**死链**（docker 端 404、原生端白屏，§1.5）。响应里的 `url` / `share_url` 字段本身就是正确形态，**优先直接用**；只有域名字段不可信（受部署 `server.base_url` 影响，可能是 `localhost` / 内网地址）时才自行换域名，且**必须保留 `#` 段**。
2. 下载必须走 select 下发的签名 `download_url`，token 短时效；401/20011 = 没带 token 或 token 过期。
3. 所有写接口（含分片）请控制并发在 Key 限流内（默认 20 QPS），分片建议串行或 ≤4 并发。
4. 文件类型受管理员黑/白名单与魔数校验约束（30011），改名绕不过。
5. 分块会话有生存期，中断后尽快续传；长期中断请 cancel 后重传。
6. Key 请通过环境变量 / 配置中心下发，勿写死在代码仓库。
7. **预签名直传（§5.4）的 PUT body 字节数必须与 init 申报的 `file_size` 精确一致**，多一个字节都会被拒（「文件大小与申报不符」），`Content-Length` 也要如实填。
8. **代理层的请求体上限会先于服务端拦住大文件**：nginx / ingress 返回的是**裸 HTTP 413**（不经业务包络、没有 JSON 体），后端日志里也查不到该请求——说明是代理层卡住，不是服务端拒绝。服务端拒绝一律走业务码（`10010` + JSON）。代理层上限须 ≥ 站点的 `upload.max_file_size`（compose 对应 `PB_MAX_BODY_SIZE`，ingress 对应 `proxy-body-size`）。

## 10. 管理端配置接口：字段级合并语义

`PUT /admin/config`（管理员 JWT）与 `PUT /admin/config/user`（用户配置段）按**字段级**合并提交的 JSON 到已落库配置：

- 提交里**出现**的字段生效；
- 提交里**未出现**的字段保留现状——**含嵌套对象**（改 `notify.smtp.host` 不会把同级的 `smtp.port` / `smtp.username` 清零）；
- 显式 `null` 表示"清空该字段"：对**切片/指针**字段有效（可清空）；对**标量**字段是 no-op（Go 的 json 把 `null` 解进非指针标量不改值——那些字段的 `0` 本身就是"不限/关闭"语义，清不清等价）；
- 合并底座是**已落库**的配置，不是 overlay 后的运行态（overlay 含 env 种子，当底座会把 env 值固化进库）；
- 提交体必须是 JSON 对象（段集合），否则 `400`。

> **变更史（2026-10-23）**：此前该接口只到**段级**合并——段内未提及的字段会被**整体清零**。实测后果：`PUT {"upload_ex":{"max_file_size":1024}}` 会把 `upload_ex` 其余字段（`open_upload` / `enable_chunk` / `text_max_bytes` …）全部归零，表现为"只想改单文件上限，结果匿名上传被关了"（`/share/file/` 立刻 10012）。旧行为已下线。
>
> 用户配置段同理：只提交 `{"allowuserregistration":true}` 不会再把 `sessionexpiryhours` / `useruploadsize` / `userstoragequota` 一并清零。

> **给集成方的建议**：改配置前先 `GET` 一份当前值，改完再 `GET` 一次做差分，确认只动了你打算动的字段。字段级合并保证了"没提交的不变"，但**提交体里写错的字段名会被静默忽略**（JSON 解码不拒绝未知字段）——不报错、也不生效（如把 `upload_ex` 写成 `upload`）。这种"无声失败"只能靠回读核对发现。
