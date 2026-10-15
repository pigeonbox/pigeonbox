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
  -F "expire_value=1" -F "expire_style=day"
# → {"code":200,"message":"文件上传成功","data":{"code":"41ySgNX0","url":"..."}}

# 把取件码发给对方，对方浏览器打开 $BASE/share/41ySgNX0 即可取件；
# 程序化取件见 §6。
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
| 10010 | 请求体过大 | 走分块通道（§5） |
| 10011 | 尝试过频已临时锁定 | 等待 `message` 中的剩余秒数 |
| 10012 | 上传已关闭 / 要求登录 | 带上 Key 重试 |
| 10014 | 匿名日配额用尽 | 带 Key 上传 |
| 20002/20004 | 分享过期 / 超过取件次数 | 重新上传 |
| 20010 | 上传会话不存在 | 分块会话过期，重新 init |
| 20011 | 缺少下载令牌 | 取件必须先 select 拿 `download_url`（§6） |
| 20013 | 分享待审核 | 等管理员审核 |
| 30011 | 文件类型不允许 | 黑名单 / 白名单 / 魔数校验未过 |

完整清单见 `contracts/errcode/errcode.go`；**全量业务码对照表（含含义与默认文案）见文档站 error-codes 页**（[docs-site/guide/error-codes.md](../docs-site/guide/error-codes.md)），按 code 分支处理时以该表为准。

## 2. 通道怎么选

| 场景 | 通道 | 单文件上限（当前部署） |
|---|---|---|
| 普通文件（配置/报表/图片…） | 直传 `POST /share/file/`（§3） | 10 MB（`upload.upload_size`，单请求体上限） |
| 大文件 | 分块 `POST /chunk/upload/*`（§5） | 50 MB（`upload.user_upload_size`，登录用户整文件上限） |
| 代码片段 / 日志 / 文本内容 | `POST /share/text/`（§4） | 222 KB（`upload.text_max_bytes`） |

> 多文件打包分享自 server v0.9.3 / core v0.7.7 起**已开放**:`POST /api/v1/share/multi-direct`(multipart 多文件直传打包)与 `POST /api/v1/share/multi-bind`(把多个已传 chunk 会话绑定为一个多文件分享)。更早版本镜像调用返回 404,届时可循环单文件通道或客户端自行打 zip。

## 3. 文件直传（推荐，≤10MB）

`POST /share/file/`，`multipart/form-data`：

| 字段 | 必填 | 说明 |
|---|---|---|
| `file` | ✅ | 文件本体；用 `filename=` 指定对方看到的原始文件名 |
| `expire_value` / `expire_style` | 默认 1 天 | 见 §1.3 |
| `require_auth` | 默认 false | `true` 时取件需密码，配合 `password` 字段 |
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
{"code":200,"message":"文件上传成功",
 "data":{"code":"41ySgNX0","url":"http://your-host:12345/share/41ySgNX0","pickup_code":"KJ8Y2M"}}
```

- `data.code` 是 8 位分享码，`data.url` 是人类取件页。**给程序对接只传分享码**，URL 按 §6 拼装。
- `data.pickup_code` 是 6 位取件码（文本/文件/永久分享同权铸造；E2E 密文分享不铸造为空）——两条码等效可取件，6 位码适合口头/短信报码，走匿名快捷通道（§6）。
- `data.deduped=true` 表示秒传去重命中（同账号历史同 hash+size 文件，免落盘直接出码，引用既有存储对象）。
- 文件名消毒规则：路径分隔符等危险字符会被清理，磁盘存储名是 UUID，对方取件时展示你传入的原始名。

## 4. 文本分享

`POST /share/text/`，支持 JSON 或表单：

```bash
curl -X POST "$BASE/share/text/" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"text":"要分享的文本内容","expire_value":1,"expire_style":"day","require_auth":false}'
# → {"code":200,"message":"分享成功","data":{"code":"Fv9hSrhz","url":"..."}}
```

- 内容会做 HTML 转义（XSS 防护），上限默认 222 KB。
- ⚠️ 需要密码的文本分享请改用**表单方式**（`-F "text=..." -F "require_auth=true" -F "password=..."`）；JSON body 不携带密码字段。

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
{"code":200,"message":"初始化成功",
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
# → {"code":200,"message":"分片上传成功","data":{"chunk_index":0,"chunk_hash":"a2d1…"}}
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
{"code":200,"message":"上传完成",
 "data":{"share_code":"7GVACfJb","share_url":"http://localhost:12345/share/7GVACfJb?token=…",
         "file_name":"chunk-test.bin","file_size":1572864,"pickup_code":"KJ8Y2M"}}
```

- ⚠️ **`share_url` 的域名不可信**（部署方 base_url 配置差异，实测曾返回 `localhost:12345`）。请自行拼装：`$BASE/share/{share_code}`。
- 放弃上传：`DELETE /chunk/upload/cancel/{upload_id}`，清理服务端已传分片。

## 6. 取件方对接（无认证）

取件是**口令语义**，不认 API Key——拿到取件码的任何人都可取，这正是产品用途。两步：

```bash
# ① 元数据 + 签名下载链接
curl "$BASE/share/select/?code=41ySgNX0"
# {"code":200,"data":{"code":"41ySgNX0","download_url":"/share/download?code=…&token=…",
#  "expire_time":"2026-10-05 13:31:04","file_size":"70","has_password":false,
#  "files":[{"name":"fcb-token-upload-test.txt","size":70}], "text":"…(文本件时为内容)"}}

# ② 凭 download_url 下载（token 短时效，随取随用，不要缓存）
curl -o out.txt "$BASE$(python3 -c "import json,sys;print(json.load(sys.stdin)['data']['download_url'])")"
```

- **必须先 select 再 download**：直接访问 `/share/download?code=…` 会 `401 code=20011`（缺少下载令牌）。
- 密码件：`GET /share/select/?code=xxx&password=yyy`；密码错返回 401。取件连续失败同样触发防爆破锁定（10011）。
- 文本件：select 响应的 `data.text` 即内容，无需下载。
- 也可用 `GET /anonymous/search/{code}` 做轻量存在性查询。
- **6 位取件码快捷通道**：分享响应里的 `pickup_code`（6 位）与 8 位分享码等效，走匿名通道 `POST /anonymous/retrieve`（JSON `{"code":"KJ8Y2M","password":"…"}`）取元数据，下载用 `GET /anonymous/download/{code}`——同闸门校验、同扣次数、同记取件人，适合口头/短信报码场景。

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
                data={"expire_value": expire_value, "expire_style": expire_style},
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
                "upload_id": uid, "expire_value": expire_value, "expire_style": expire_style},
                timeout=120)
    body = r.json()
    if body.get("code") != 200:
        raise RuntimeError(f"upload failed: {body}")
    code = body["data"].get("code") or body["data"]["share_code"]
    return code, f"{BASE}/share/{code}"                   # share_url 域名不可信，自行拼装

if __name__ == "__main__":
    print(upload("/path/to/file.bin"))
```

## 9. 注意事项（实测踩坑）

1. **取件 URL 一律自行拼装** `$BASE/share/{code}`，不要使用响应里的 `url` / `share_url` 域名（受部署 base_url 配置影响，可能返回内网地址）。
2. 下载必须走 select 下发的签名 `download_url`，token 短时效；401/20011 = 没带 token 或 token 过期。
3. 所有写接口（含分片）请控制并发在 Key 限流内（默认 20 QPS），分片建议串行或 ≤4 并发。
4. 文件类型受管理员黑/白名单与魔数校验约束（30011），改名绕不过。
5. 分块会话有生存期，中断后尽快续传；长期中断请 cancel 后重传。
6. Key 请通过环境变量 / 配置中心下发，勿写死在代码仓库。
