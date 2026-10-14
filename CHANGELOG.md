# Changelog

各模块仓独立发版；本文件记录工作区级的重要变更（格式参考 Keep a Changelog）。
组件列车的版本真相源 = [release/train.yaml](release/train.yaml)（各仓 tag/DEPS.env 由列车对账兜底）；
生态表见 [AGENTS.md](../AGENTS.md)，版本矩阵见 [architecture.md](docs/architecture.md) §2.3。
自 1.14.x 起列车级明细以 hub `v<train>` Release notes 为准，本文件仅记录工作区级变更。

## [1.22.0] - 2026-10-14

### Added（工作区级）
- **P3 留位清零**（contracts v0.14.0 / core v0.20.0 / p2p v0.6.3 / frontend-core v0.5.0）：
  - **联邦实例间推送邀请**：公开收件 `POST /api/v1/p2p/invite`（限流归桶）+ admin 待收邀请/认领/
    推送三端点（AdminP2PService 扩至九端点）+ Web 控制台面板——免手工口令交接（口令=bearer，
    信任级同手工交接；定时自动同步仍留位）。
  - **pb CLI `p2p` 八支子命令**（status/tasks/send/recv/cancel/invites/accept/push，
    admin API Key 通道，admin Key 角色复核）。
  - **p2pc `--json` NDJSON 事件流**（code/done/error 事件 + 形态锁单测；缺省纯文本不变，
    desktop 零影响）。

## [1.21.0] - 2026-10-14

### Added（工作区级）
- **P2P 对称节点融合全量（P1+P2a+P2b，core v0.19.0 / contracts v0.13.0 / p2p v0.6.2 / frontend-core v0.4.0）**：
  每台 standalone server = 对称 P2P 节点。federation 收进 SystemConfig `p2p` 段 +
  admin「系统配置 → P2P 与联邦」第 7 分区 + 运行时热启停（先立后破/失败回滚/错误响亮 500）；
  新增 p2px 设备直传 supervisor 域（spawn 随包 p2pc 子进程，任务态机 + 收件区配额 + TTL 清扫 +
  发布幂等闸 + 口令打码审计）；contracts 新增 `idl/p2p.thrift` AdminP2PService 六端点
  （`/admin/p2p/*`）；admin 设备直传控制台页；MCP 新增 `p2p_status/tasks/send/recv` 四工具（19 个）。
- **p2pc 全端随包**：server 镜像构建期按 `.p2pc-version` 拉取 p2pc（sha256 校验，装 `/app/p2pc`，
  缺省优雅降级）；fnos/qnap/openwrt 打包期按 `DEPS.env P2PC_REF` 钉版随包（fnos/qnap 服务脚本
  自动注入 `PB_P2PC_PATH`，openwrt 落 `/usr/bin/p2pc`）；desktop sidecar 钉版随列车同升。
- 设计稿 [docs/specs/2026-10-14-p2p-peer-integration-design.md](docs/specs/2026-10-14-p2p-peer-integration-design.md)；
  缺省语义：registry 留空=官方公共注册中心 `home.enjoye.top:56788`，public_url 留空=按站点 base_url 推断。

## [1.20.0] - 2026-10-12

### Changed（工作区级）
- **发布列车 v2 状态机编排器**（`release/trainctl`，Go stdlib-only）首航：bump 结构化写 15+ 版本点 →
  各仓 PR 自动 squash 合并 → advance（组件回调/定时 sweep/手动唤醒）按依赖序自动推 tag
  （库线 → frontend → server → 七终端 → desktop）→ 以 GitHub API 实况对账回挂/镜像 →
  全量 verify → 自动出 hub 快照。各仓 version-tagger 与 v1 链路（tag 轮询/sync-appversion/
  train-release.yml/scripts/release-train.sh）全部退役删除。
- 写凭据收敛为 org 级机器人 secret `PB_BOT_TOKEN`（10 个旧 PAT secrets 删除），
  配置清单见 [docs/release-bot-setup.md](docs/release-bot-setup.md)。
- 设计稿 [docs/specs/2026-10-12-release-train-v2-design.md](docs/specs/2026-10-12-release-train-v2-design.md)。

## [1.19.0] - 2026-10-12

### Changed（工作区级）
- 管理后台系统配置 11 横排 tab → 左导航分区（现 7 区，含 P2P 与联邦）+ 统一保存 + `?section=` 深链；
  登录页重构。
- 局部保存清零 base/storage/transfer 修复（值类型改指针 + nil 保留）；产品文档/截图对码。

## [1.17.0] - 2026-10-12

### Changed（工作区级）
- **产品版本统一**：镜像线并入产品号——server/frontend 镜像 tag、两仓 git tag、页脚与各平台 web/
  包体版本全部随列车号（存量 0.15.x 钉版可用，semver 排序无碍）；库线（contracts/kit/core/p2p/
  frontend-core）维持各自 semver。
- 打包机制根治「版本幽灵」四件套：构建自证 version.txt / 干净换装 upgrade-inplace.sh /
  verify 三重防幽灵 / 发版守卫。
- 秒传去重 D1（同用户内命中免落盘 + 删除引用保护）、上游缺口五件（下载文件名 ASCII 兜底/
  文件备注 note/先出码后上传/自定义 admin 路径/暗色模式）、MCP 访客三级作用域 +
  对标四件套（保存视图/活动聚合流/向导政策段）随 1.17~1.18 列车发布。

## [1.16.0] - 2026-10-11

### Changed（工作区级）
- **dao 去全局化收官**（core v0.16.x）：16 域构造必填 `*gorm.DB` 注入，全局回退/懒加载/包级 init
  全退役；架构棘轮守卫新增规则 9/10（dao 显式构造防回潮 + 全局 DB 句柄只减不增）。
- admin 残留手写面 IDL 化收官（local-files/设置测试/审计日志迁 gen 链）。

## [1.15.0] - 2026-10-10

### Added
- **MCP 能力扩展为分享全生命周期（8→13 工具）+ 对接指南 + agent skill**：
  - 新增 5 工具——上传 `share_file`（base64 随 JSON-RPC 携带，share 域新 `ShareBytes`
    入口：文件名消毒/扩展名白名单/大小上限→SaveStream→CreateShare 同链路，配额/审核/
    联邦公告全生效）、下载 `get_share_content`（文本回正文/文件回清单，不耗次数）与
    `download_share_file`（base64 回传，单文件/未过期/受 `mcp.max_file_size` 限）、
    P2P 联邦 `federation_status`（启用/节点 ID/registry/心跳）与 `federation_resolve`
    （口令联邦路由查询）。
  - 新配置 `mcp.max_file_size`（默认 6MB，env `PB_MCP_MAX_FILE_SIZE`；base64 膨胀 4/3
    后须低于请求体上限，超限时同步调大 `upload.max_file_size`）。
  - 修复：`CreateShare` 路径（文件/多文件/本地导入/MCP）此前不生成 `full_share_url`，
    统一下沉到 `modelToResp` 三通道生成。
  - `docs/MCP-README.md` 重写为完整对接指南（仍为 docs-site `reference/mcp` 页真相源），
    新增 `skills/pigeonbox-mcp/` agent skill（SKILL.md + 自动登录/401 重试的
    `scripts/mcp.sh`，curl+python3 零额外依赖）；临时实例+真机 p2pd 联邦全链路验证
    （13 工具/上传下载回环比对/联邦状态与路由/错误路径）全绿。
- **OpenWrt/iStoreOS 原生 ipk 适配层接入为第 8 模块**（[openwrt](https://github.com/pigeonbox/openwrt) v0.1.0）：
  单进程库式调 core + 前端 dist 内置（单端口 12345 同端口服务 Web+API），procd 托管/开机自启，
  UCI 配置（`/etc/config/pigeonbox`）+ drop-in config.yaml，`Depends: redis-server`（OpenWrt 官方源）；
  双架构 x86_64 / aarch64_generic。ipk 回挂 hub `openwrt-v*` Release。
  设计与 ipk 打包三坑（纯 tar.gz 非 ar / ustar 强制 / `/sbin/init` 引导）见
  [docs/specs/2026-10-06-openwrt-istoreos-adapter-design.md](docs/specs/2026-10-06-openwrt-istoreos-adapter-design.md)。

### Changed
- **多副本拆分列车**（core v0.13.0 / server v0.14.0 / chart 1.3.22+）：`PB_DEPLOY_MODE`
  三模式 standalone（默认）/ public×N / admin×1——按模式注册路由组、public 管理面门卫 404、
  迁移/后台任务归 admin、Redis pubsub 配置广播 + revision 对账；chart `replicaCount>1`
  自动渲染 public×N + admin×1 双拓扑。core 新增回收站（软删/恢复/彻底删除）。
  contracts v0.6.5 增 `CodePresignDisabled`（10015，匿名直传未开放时客户端回退普通通道）。
- **前端双仓拆分**（2026-10-09）：frontend-core（平台无关应用 + 宿主适配器 SPI，Release tgz 消费）
  独立成仓；frontend 退为壳（neutral 产物 + nginx 镜像）；平台宿主适配器迁归 fnos/qnap 各仓 `web/`。
- **fnos 只发原生 fpk**（2026-10-09）：Docker 链路全拔，`ghcr.io/pigeonbox/fnos` 冻结 v1.14.6；
  qnap 切原生 QPKG（v1.14.4 起，QTS SSO 免登录）。
- **NAS 打包四仓模板化**：synology/ugreen/terramaster 共享 hub `deploy/nas/` 模板（sync 漂移门禁）。
- **Release 链静默修复**：tagger 推 tag 不产生 push 事件 → 打 tag 后 `gh workflow run` 显式触发，
  dispatch 失败即红不吞错（9 仓加固）。

## [1.13.0] - 2026-10-05

生态快照（组件列车至 core v0.12.5 / server v0.13.5 / chart 1.3.21 / p2p v0.4.1 /
fnos v1.2.3 / desktop-v1.3.1）。0.2.0 之后的累计工作区级变更见下方归档节；
更近的组件列车（core v0.8 kit 化 → v0.9 federation M4 → v0.10 安全审计 →
v0.11/0.12 hz 链路治理+攻击面收缩+契约化）明细见 AGENTS.md 生态表版本注。

## [归档] 0.2.0 → 1.12.0 生态快照累计变更（2026-10-03 → 2026-10-05 已发布）

### Added
- **站点级全局存储配额**（core v0.7.0）：`storage.quota`（字节，0=不限，env `PB_STORAGE_QUOTA`），
  全通道统一闸口（直传/分片完成/预签名完成/本地导入/多文件）；超限返回
  `CodeStorageQuota`；统计口径=存活 file_codes 合计，统计故障 fail-open。
- **分片逐片期望哈希强校验**（core v0.7.0，对标上游）：分片上传可携带 `hash`
  （32 位=MD5/64 位=SHA-256 自适应），服务端恒时比对不符即拒收该分片（422 retryable）；
  前端逐片 SHA-256 随片携带并自动重传。
- **六种新存储驱动**（core v0.7.0）：FTP/FTPS、SFTP（密码/PEM 私钥+可选 host_key 严格校验）、
  Google Cloud Storage（S3 兼容 XML+HMAC，region 留空即用）、Azure Blob（SharedKey/SAS 零 SDK）、
  HDFS（WebHDFS REST）、OneDrive（Microsoft Graph，refresh_token 自动续期+大文件分片会话）。
- **安全版主题**（core/frontend v0.7.0）：`ui.background`（http(s) 图片 URL）与
  `ui.accent_color`（#hex）serve 白名单校验后经 `/api/config` 下发；前端深浅模式蒙层
  与 Element Plus 色阶覆盖。**不接受自由 CSS**（对齐上游 2.6.0 CSS 注入修复教训）。
- **管理入口可见性**：`ui.show_admin_addr=true` 时首页页脚展示管理入口（默认隐藏）。
- 冒烟矩阵扩至 43 项（分片哈希 422/放行、showAdminAddr 下发）；存储驱动新增
  `live` 构建标签 Docker 真机集成测试（atmoz/sftp + pure-ftpd）。

### Changed
- 冒烟脚本（scripts/smoke-full.sh）修复头部变量丢失并新增 `SMOKE_BASE` 外置实例模式
  （一条命令验证任意 Docker/compose/K8s 部署）。
- charts：chart-releaser 加 `skip_existing`（非发版 push 不再 422 打红）。

- **真·S3 预签名直传直下**（core）：存储后端为 s3 时 `presign.Init` 直接签发对象存储
  预签名 PUT URL（`meta.Scheme=s3`），上传流量不过服务器；`Complete` 向 S3 核实对象
  真实存在并以实际大小落库（服务器未接触内容，秒传指纹依赖客户端预计算哈希）。
  下载侧新增 `download.s3_direct_download`（env `PB_DOWNLOAD_S3_DIRECT`，默认关）：
  开启后文件下载 302 到短时效预签名 GET。**注意**：浏览器直传/直下需在对象存储桶上
  配置 CORS 允许站点来源；local/webdav 后端自动回退自家中转，行为不变。
- **存储后端点亮**（core）：S3 / WebDAV 真实读写全链路（opendal 驱动：minio-go / gowebdav），
  `StorageService` 按配置类型分派；本地盘路径行为零改动。
- **在线切换存储后端**（core）：管理端切换/保存走「SSRF 校验 → 认证级 Probe → 热重载 → 持久化」，
  重启后从 `system_configs.runtime_storage` 恢复（env > DB > yaml）；`StorageInfo` 新增
  `effective` 字段展示实际生效后端。
- **presign 直传接入存储分派**（core）：直传落盘跟随当前激活后端（此前硬编码本地盘）。
- **首启引导**：`/api/config` 返回真实 `initialized`；前端新增 `/setup` 初始化页（含 i18n）。
- **开源合羄件**：7 仓 LICENSE（初为 MIT，2026-10-04 起全生态切换 **Apache-2.0**）；CONTRIBUTING / SECURITY / CHANGELOG / ROADMAP / 双语 README。
- **API Key 体系**（core）：`fcb_sk_` 前缀用户级 API Key（SHA256 存储/per-Key 限流/审计归因/
  一键吊销/临期通知），`/api/v1` 组 JWT|API Key 双认证，管理端总开关与热更新。
- **多文件分享 + zip 打包**（core/frontend）：单/多文件统一子表模型，`/api/v1/share/multi-direct|multi-bind`，
  下载侧对流式 zip（不落盘、防 Zip Slip、重名去重）。
- **寄件码/反向收件**（core/frontend）：分享者建链接、访客投递、到件通知（对齐 Gokapi file requests）。
- **端到端加密分享**（frontend）：WebCrypto 客户端加密（≤100MB），密钥走 `#fragment`，服务器零知识。
- **通知渠道**：SMTP 邮件落地（notify 域多渠道）。
- **MCP Server 实装**（core）：`POST /api/v1/mcp` JSON-RPC 8 工具（分享/查询/管理/清理）。
- **`fcb` CLI**（server）：分享/取件/管理命令行（基于 API Key）。
- **可选 ClamAV 病毒扫描**（core，fail-open 接线）。
- **OIDC 单点登录 / Range 断点续传(206) / 自定义取件码 / NAS 本地文件免上传导入**（core/frontend）。
- **`/share/metadata` 元数据端点**（core）：查询不扣次数、不要密码，text 分享不外泄内容。
- **openapi.json 运行时生成**（core）：启动时由运行时路由表生成契约级骨架规范，
  根治手工快照漂移与容器 404；frontend 移除 openapi.json/api.gen.ts 死链（无消费方）。
- **管理端本地文件管理**（core/frontend）：`/admin/local-files` 列表/删除/生成提取码
  （root 索引+白名单相对路径三层防穿越）。
- **文档站**（hub）：docs-site VitePress（内容 @include 引 docs/ 真相源）。

### Changed（技术修复）
- `core/bootstrap`：StorageService 改为进程内单例（此前 3 处各建实例，在线切换无法生效）。
- `core/app/admin`：`SystemConfig` 新增 `runtime_storage` 段（存储域经接口读写，本域只持久化）；
  `UpdateConfig` 对该段做防御性合并。
- opendal `Operator.New`：s3/webdav 参数缺失时返回错误（不再静默回退 fs）。
- `core`: chunk `CompleteUpload` 恒 500 修复（`UpdateChunkCompleted` 缺 `.Model()` 致 GORM
  "Table not set"）——v0.6.0 镜像带此缺陷，**分片用户请升级 ≥ server 0.6.1 / fnos 0.2.4**。
- 镜像 tag 口径：ghcr tag 为无 `v` 前缀形态（`0.6.4`）；chart 0.2.7 起对 AppVersion/显式
  image.tag 统一剥 `v`（此前默认安装渲染出不存在的 `:v0.6.4`）。
- charts CI：push 事件下 ct 安装冒烟曾 0 秒空跑，改为显式 helm 安装 + rollout + helm test。
- fnOS 镜像内置默认配置（`configs/config.yaml`）：裸 `docker run` 开箱可用
  （此前无 env 时匿名上传被拒、存储路径为空）；应用包模式行为不变（env 覆盖）。

### Removed（假开关清理：未实现的能力不再暴露配置键）
- `upload.max_save_seconds`、`download.enable_concurrent_download` / `max_concurrent_downloads`
  （从未实现；全局过期上限用 `upload.max_save_seconds_cap`）。
- `user.require_email_verify`（无验证码流程；注册 email 为普通必填字段）。
- `ui.theme/background/page_explain/show_admin_addr/opacity/notify_*`（仅 `ui.robots_text` 实际消费；
  主题系统实装时按新形状回归）。
- `observability.tracing.*` 与 `PB_TRACING_ENABLED`（OTel 未实装）。
- onedrive 存储类型空壳常量。残留旧键的存量配置可无损升级（viper 忽略未知键）。

### 升级说明
- 新增直接依赖：`github.com/minio/minio-go/v7`、`github.com/studio-b12/gowebdav`（core）。
- 局域网对象存储/WebDAV（NAS 场景）需 `security.ssrf.allow_private_networks: true`（既有机制）。
- 存量部署（`storage.type=local`）行为不变；详细设计见
  [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。

## [0.2.0] - 2026-10-02

- 单体拆分为 contracts / core / server / frontend / pigeonbox-fnos / charts 多仓。
- 安全基线：分享密码修复、失败锁定、下载令牌、SSRF 校验、魔数检测、文件名消毒、审计接线。
- 管理端站点配置 DB 持久化（`system_configs` 单行写穿）。

## [0.1.0] - 2026-07

- Go 重写版首发布（对照 Python 原版 vastsa/FileCodeBox 的功能面）。
