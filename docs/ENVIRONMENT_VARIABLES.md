# 环境变量参考（ENVIRONMENT_VARIABLES）

所有环境变量优先级高于 config.yaml（12-factor 注入方式）。命名两套并存：文档化短名（如 `PORT`）与 `PB_` 前缀全名（如 `PB_SERVER_PORT`）。

> **前缀 `PB_`（PigeonBox 缩写）**：2026-10-08 由前身 `FCB_`（FileCodeBox）全量更名——项目尚未正式发布，做干净切换、不设 `FCB_*` 双读兼容。**若你从旧版本升级**：请将配置中的 `FCB_*` 变量名同步改为 `PB_*`（如 `FCB_SERVER_PORT`→`PB_SERVER_PORT`、`FCB_ADMIN_PASSWORD`→`PB_ADMIN_PASSWORD`），数据文件（`fileCodeBox.db`）与数据目录无需任何改动；chart 部署的 Secret 键同样由 `FCB_*` 改为 `PB_*`（升级后重建 Secret 或对齐键名）。请勿再引入 `FCB_*` 或其他前缀，以免同一部署中出现两套变量名。

## 敏感项（生产必设）

| 变量 | 说明 |
|---|---|
| `PB_JWT_SECRET` | JWT 签名密钥（全环境强制：空或已知默认值将拒绝启动，≥32 位强随机） |
| `PB_ADMIN_PASSWORD` | 首个管理员 admin 的密码（默认 admin123 仅限开发；生产模式未注入则**拒绝启动**，或设 `PB_DISABLE_DEFAULT_ADMIN=true` 走 /setup 向导。仅在库中无 admin 且即将创建时校验，存量部署升级不受影响） |
| `PB_DATABASE_PASSWORD` | MySQL/Postgres 密码 |
| `PB_REDIS_PASSWORD` | Redis 密码 |
| `PB_PRESIGN_SIGNING_KEY` | 预签名直传专用签名密钥（缺省复用 jwt_secret） |
| `PB_DOWNLOAD_TOKEN_SECRET` | 下载令牌（防盗链）专用签名密钥（缺省派生自 jwt_secret；独立设置可隔离泄露面，core v0.11.0 起） |

## 服务器

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_SERVER_HOST` / `HOST` | 0.0.0.0 | 监听地址 |
| `PB_SERVER_PORT` / `PORT` | 12345 | 监听端口 |
| `PB_SERVER_MODE` | debug | debug / release（release 视为生产） |
| `PB_SERVER_BASE_URL` / `BASE_URL` | 空 | 对外访问地址（分享链接生成用） |
| `PB_SERVER_READ_TIMEOUT` / `PB_SERVER_WRITE_TIMEOUT` | 30（镜像 config） | 读写超时（秒） |

## 数据库 / Redis

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_DATABASE_DRIVER` / `DB_TYPE` | sqlite | sqlite / mysql / postgres |
| `PB_DATABASE_DB_NAME` / `DB_NAME` | ./data/pigeonbox.db | SQLite 文件路径或库名；**镜像内置 config.yaml 实际写死 `./data/fileCodeBox.db`（驼峰），compose 部署以镜像配置为准** |
| `PB_DATABASE_HOST` / `DB_HOST` | — | MySQL/PG 主机 |
| `PB_DATABASE_PORT` / `DB_PORT` | — | MySQL/PG 端口 |
| `PB_DATABASE_USER` / `DB_USER` | — | MySQL/PG 用户名 |
| `PB_REDIS_HOST` / `REDIS_HOST` | 空 | 单机置空 = **内存模式**：匿名取件/预签名直传存进程内 TTL KV，全功能可用（重启丢失未取件映射、不跨副本共享；多副本 public/admin 置空则拒绝启动）。配了但连不上：standalone 降级内存模式并告警，public/admin 拒绝启动。⚠️ 该行为随 core 内存模式列车发布，此前版本置空 = 匿名取件不可用 |
| `PB_REDIS_PORT` / `REDIS_PORT` | 6379 | |
| `PB_REDIS_DB` / `REDIS_DB` | 0 | Redis 库号 |
| `PB_PRODUCTION` / `PRODUCTION` | false | 等价 `app.production=true`：强制校验 admin 密码/JWT 密钥等敏感项（compose 默认注入 `PB_PRODUCTION=1`） |

## 上传安全

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_OPEN_UPLOAD` / `OPEN_UPLOAD` | true | 匿名上传总开关（服务端强制执行；false 时拒绝全部匿名上传，登录用户不受影响） |
| `PB_UPLOAD_SIZE` / `UPLOAD_SIZE` | 10485760 | 单请求体上限（字节） |
| `PB_TEXT_MAX_BYTES` | 227328 (222KB) | 文本分享内容上限 |
| `PB_UPLOAD_ALLOWED_EXTENSIONS` | 空（黑名单模式） | 扩展名白名单，逗号分隔；非空则必须命中（未命中拒绝，含无扩展名） |
| `PB_UPLOAD_BLOCKED_EXTENSIONS` | 内置默认 | 扩展名黑名单，逗号分隔；非空覆盖内置默认，白名单命中也拦截 |
| `PB_ENABLE_MAGIC_CHECK` | true | 魔数校验（拦截改扩展名伪装的可执行文件） |
| `PB_UPLOAD_ANON_DAILY_COUNT` / `PB_UPLOAD_ANON_DAILY_BYTES` | 0（不限） | 匿名上传 per-IP 日配额（次数 / 字节） |
| `PB_UPLOAD_MAX_SAVE_SECONDS_CAP` | — | 分享保存时长上限钳制（秒）；用户提交的过期时间超过此值时按上限落库 |

## 下载

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_DOWNLOAD_S3_DIRECT` | false | s3 直下：存储后端为 s3 时，文件下载 302 到短时效预签名 GET URL（下载流量不经过服务器）。对象存储桶需配置 CORS 允许站点来源 |

## 安全

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_TRUSTED_PROXIES` | 空 | 可信代理 CIDR，逗号分隔（如 `10.0.0.0/8,173.245.48.0/20`）。**反代部署必填**：仅当直连对端在网段内才采信 X-Forwarded-For，否则伪造 XFF 无法绕过限流/锁定 |
| `PB_DOWNLOAD_TOKEN_ENABLED` | true | 取件下载令牌（HMAC 时间窗）强制校验 |
| `PB_LOCKOUT_ENABLED` | true | 登录/取件失败计数锁定 |
| `PB_LOCKOUT_MAX_ATTEMPTS` | 10 | 窗口内失败阈值 |
| `PB_API_TOKEN_ENABLED` | true | 用户级 API Key（`pb_sk_`）认证总开关；false 时携带 Key 的请求一律 401（紧急停用），详见 docs/API-TOKENS.md |
| `PB_API_TOKEN_PER_KEY_QPS` | 20 | 单 Key 独立限流（令牌桶，进程内）；0 = 不限 |
| `PB_API_TOKEN_PER_KEY_BURST` | 40 | 单 Key 限流桶容量；0 = 2×QPS |
| `PB_SSRF_ALLOW_PRIVATE` | false | 允许 s3/webdav 端点指向私网。**局域网 MinIO/WebDAV（飞牛 NAS）部署需设 true** |
| `PB_CORS_ALLOW_ORIGINS` | 空 | CORS 白名单，逗号分隔 |
| `PB_ENABLE_HSTS` | 未配置 | 三态：生产模式默认 true/开发默认 false；显式 true/false 恒生效（逃生开关） |

## 限流

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_RATE_LIMIT_ENABLED` | true | 总开关 |
| `PB_RATE_LIMIT_GLOBAL_QPS` | 100 | 每 IP 全局 QPS |
| `PB_RATE_LIMIT_UPLOAD_QPS` | 10 | 上传维度 |
| `PB_RATE_LIMIT_DOWNLOAD_QPS` | 50 | 下载维度 |
| `PB_RATE_LIMIT_LOGIN_QPS` | 5 | 登录维度 |
| `PB_RATE_LIMIT_BLOCK_SECONDS` | 60 | 触发后封禁时长 |
| `PB_RATE_LIMIT_USE_REDIS` | false | Redis 固定窗口计数（多实例共享；Redis 不可用自动回退内存） |

## 通知

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_WEBHOOK_URL` | 空 | 外部 Webhook 推送地址（`notify.created` 事件 JSON POST，5s 超时，失败仅记日志） |

## AI 集成（MCP）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_MCP_ENABLED` | true | MCP server（POST /api/v1/mcp，Streamable HTTP/JSON-RPC 2.0，默认管理员 JWT 认证；15 个工具覆盖上传/寄件码/预览/下载/管理/联邦，详见 docs/MCP-README.md） |
| `PB_MCP_ALLOW_GUEST` | false | MCP 访客快速分享：true 时免登录可用 share_text/share_file（同网页匿名寄件限流/审核/白名单链路），登录用户 += create_request_code/preview_share，管理员全量（详见 docs/MCP-README.md「访客快速分享」） |
| `PB_MCP_MAX_FILE_SIZE` | 6291456 | MCP 单文件上传/下载上限（字节；base64 膨胀 4/3 后须低于请求体上限 max(10MB, upload.max_file_size)，超限时同步调大后者） |

## 内容审核（moderation）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_MODERATION_ENABLED` | false | 内容审核总开关（命中处理对匿名与用户上传生效） |
| `PB_MODERATION_BLOCKED_WORDS` | 空 | 敏感词表，逗号分隔 |
| `PB_MODERATION_BLOCK_ACTION` | reject | 命中动作（当前实现为直接拒绝） |

## P2P 联邦（federation，core v0.8.0 起）

接入 [p2p](https://github.com/pigeonbox/p2p) 联邦注册中心：本实例注册为联邦节点，口令分享可被联邦内其他节点路由解析。默认关闭；启用须同时提供 `PB_FEDERATION_REGISTRY_URL` 与 `PB_FEDERATION_PUBLIC_URL`。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_FEDERATION_ENABLED` | false | 联邦接入总开关 |
| `PB_FEDERATION_REGISTRY_URL` | 空 | p2p 注册中心地址（如 `http://registry:12346`）；支持逗号分隔多主备——写全推、读依次 failover（core v0.9.0 起） |
| `PB_FEDERATION_PUBLIC_URL` | 空 | 本节点对外可达地址（联邦内其他节点回源取件用） |
| `PB_FEDERATION_NODE_KEY_PATH` | data/federation.key | Ed25519 节点私钥路径（缺失自动生成） |
| `PB_FEDERATION_MIN_ENTROPY` | 40 | 允许注册到联邦的口令最小熵（bit），低熵口令不上榜 |

设备直传（p2pc，2026-10-14 起）：supervisor 按需 spawn `p2pc` 子进程做口令直传；直传参数（启用/白名单/收件区/配额）在管理后台「P2P 与联邦」分区配置（SystemConfig `p2p.direct`，DB 即真相源），env 仅覆盖组件定位与口令传递通道：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_P2PC_PATH` | 空 | p2pc 二进制路径。留空按查找序：配置 `p2p.direct.binary_path` → 本 env → 可执行文件同目录/`./p2pc`/`/usr/bin/p2pc` → PATH。各终端包已内置并由服务脚本注入（fnos/qnap 自动指向包内 p2pc；openwrt 落 `/usr/bin/p2pc` 命中候选序） |
| `PB_P2P_CODE` | 空 | 仅 p2pc 进程内使用：`p2pc recv -` 时从此 env 读口令（argv 不留码，同机 ps 不可见）。server supervisor 发起接收任务时自动注入，运维/脚本手工调 p2pc 也可用此通道 |

## 部署模式（deployment，多副本拆分）

同一镜像三种运行模式：`standalone` 单进程全功能（默认，即历史形态）；`public` 公开面副本（可多实例横向扩容，只读配置 + 订阅管理端变更广播）；`admin` 管理面单实例（管理路由 + 后台任务 + DB 迁移 + 配置唯一写者）。public/admin 硬约束：`database.driver` 必须为 mysql/postgresql、Redis 必配（变更广播依赖）、federation 自动降级关闭。详见 `docs/specs/2026-10-06-multi-replica-deployment-modes.md`。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_DEPLOY_MODE` | standalone | 部署模式：standalone / public / admin |

## 可观测性

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_METRICS_ENABLED` | false | Prometheus 指标（独立监听 127.0.0.1:9090，`PB_METRICS_ADDR` 可改） |
| `PB_METRICS_PATH` | /metrics | 指标路径 |

## 站点 UI（ui）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_UI_SHOW_ADMIN_ADDR` | true | 公开页脚是否展示管理后台入口（缺省展示；置 `false` 仅隐藏入口，`/admin` 地址始终可直达；管理后台「外观主题」页可在线改，DB 配置段优先于 env/yaml） |
| `PB_UI_EXPOSE_OPENAPI` | true | 是否公开 `/openapi.json`（false 时端点 404，前端 /api-docs 页降级；生产建议置 false 收缩侦察面） |

## 其他

`PB_DATA_PATH`（数据目录）、`PB_STORAGE_TYPE` / `PB_STORAGE_PATH`（存储后端）、`PB_STORAGE_QUOTA`（站点级全局存储配额，字节，0=不限）、`PB_USER_ALLOW_REGISTRATION`（开放注册）、`CONFIG_PATH`（配置文件路径）。

S3 兼容存储凭据/连接（v0.7.7 起，对应 `storage.s3.*` 配置键；此前文档宣称可用但映射缺失，已补齐）：`PB_STORAGE_S3_ACCESS_KEY` / `PB_STORAGE_S3_SECRET_KEY` / `PB_STORAGE_S3_ENDPOINT` / `PB_STORAGE_S3_REGION` / `PB_STORAGE_S3_BUCKET` / `PB_STORAGE_S3_USE_SSL` / `PB_STORAGE_S3_PATH_STYLE`（自建 MinIO 置 `true`）。

## 2026-10 能力扩展（P0-P3）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_MODERATION_CLAMAV_ENABLED` | `false` | 文件病毒扫描总开关（clamd INSTREAM；moderation.enabled=true 时生效，fail-open） |
| `PB_MODERATION_CLAMAV_ADDR` | `localhost:3310` | clamd 地址 |
| `PB_ADMIN_LOG_RETENTION_DAYS` | 90 | 管理端审计/传输日志保留天数（janitor 定期清理超期记录） |
| `PB_SMTP_HOST` / `PB_SMTP_PORT` / `PB_SMTP_USERNAME` / `PB_SMTP_PASSWORD` / `PB_SMTP_FROM` | 空 | SMTP 邮件通知（站内信创建后对登记邮箱异步补发；port 465=隐式 TLS，587/25=STARTTLS） |
| `PB_OIDC_ENABLED` | `false` | OIDC 单点登录（回调 `<base_url>/api/v1/user/oidc/callback`，登录页按钮随 `/api/config` 的 `oidcEnabled` 出现） |
| `PB_OIDC_ISSUER` / `PB_OIDC_CLIENT_ID` / `PB_OIDC_CLIENT_SECRET` / `PB_OIDC_SCOPES` | 空 | OIDC 参数（scopes 默认 `openid profile email`） |
| `PB_LOCAL_IMPORT_ENABLED` | `false` | NAS 本地文件免上传导入（`POST /api/v1/user/shares/import-local`，仅登录用户） |
| `PB_LOCAL_IMPORT_ROOTS` | 空 | 允许导入的绝对目录白名单（逗号分隔，EvalSymlinks 防穿越） |

相关新端点：多文件分享 `POST /api/v1/share/multi-direct|multi-bind`、寄件码
`/api/v1/user/requests` + `/request/:token` + `/api/v1/request/:token/upload`、
多文件下载 `/share/download?code=xxx[&file=<id>]`（多文件默认流式 zip）。
