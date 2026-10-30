# PigeonBox RoadMap

> 最后更新：2026-10-30（对齐列车 **v4.1.2**）。路线按「现在（进行中）/ 下一步 / 更远」组织，完成即勾选。
> 功能请求请到各仓 Issues；重大设计变更会先在 `docs/design/` / `docs/specs/` 落设计文档。
> **能力演进的完整规划与验收判据见 [docs/specs/2026-10-30-capability-evolution-roadmap.md](docs/specs/2026-10-30-capability-evolution-roadmap.md)**（2026-10-30 规划稿）；下方「下一步」是该稿的节选，**冲突以该稿为准**。

## 定位

**匿名口令文件快递柜**：像取快递一样收发文本与文件。坚持轻量、开箱即用，
不做网盘、不做重存储平台——这是对上游社区共识（[#434](https://github.com/vastsa/FileCodeBox/issues/434)）
的继承，也是我们与 Gokapi / copyparty / Nextcloud 的边界。

## 已完成（2026-10 突击批次）

- [x] 单体 → 多仓拆分，CI/发布链路（contracts/core/server/frontend/fnos/charts）
- [x] 安全基线：分享密码、失败锁定、下载令牌、SSRF 校验、魔数校验、文件名消毒、审计接线、可信代理解析
- [x] 管理端站点配置 DB 持久化（system_configs 单行写穿）
- [x] **存储后端点亮**：S3 / WebDAV / 云厂商预设（oss/cos/bos/ks3/obs）真实读写，
  运行时切换持久化、presign/分片走当前后端、管理端展示实际生效后端
- [x] **真·S3 预签名直传直下**：上传预签名 PUT + Complete 以 S3 为事实源核实；下载 302 预签名 GET
- [x] **首启引导**：`/api/config` 真实 `initialized`；前端 Setup 初始化页
- [x] **多用户平台**：注册/JWT/API Key（pb_sk_，per-Key 限流与归因）/配额/我的分享管理
- [x] **多文件分享 + 流式 zip 打包下载**（单/多文件统一子表模型）
- [x] **寄件码 / 反向收件**：分享者建链、访客投递、到件通知
- [x] **端到端加密分享**（WebCrypto，≤100MB，服务器零知识）
- [x] **通知渠道扩展**：SMTP 邮件（notify 域多渠道架构）
- [x] **MCP Server**：官方 SDK `modelcontextprotocol/go-sdk`（v1.8.0）单端点 **18 工具**
  （分享/寄件码/预览/下载/管理/联邦，含访客三级作用域；**直传四工具已随两应用分拆退役**；上游无此能力）
- [x] **`pb` CLI**（基于 API Key 体系）
- [x] 可选 ClamAV 病毒扫描（fail-open 接线）
- [x] OIDC 单点登录 / Range 断点续传 / 自定义取件码 / NAS 本地文件免上传导入与管理
- [x] `/share/metadata` 元数据端点（查询不扣次数）+ openapi.json 运行时生成（零漂移）
- [x] 开源合规件：LICENSE / CONTRIBUTING / SECURITY / CHANGELOG / 文档站（docs-site VitePress）
- [x] 全局存储配额（storage.quota）+ 分片逐片哈希强校验
- [x] 存储驱动扩展至 14 种：FTP/FTPS、SFTP、GCS、Azure Blob、HDFS(WebHDFS)、OneDrive(Graph)
- [x] 安全版主题（背景图/主题色白名单校验）
- [x] 质量基建：golangci-lint 门禁（CI 同款 make lint）、44 项全能力冒烟（scripts/smoke-full.sh）、
  chunk 大文件生命周期回归、Helm CI 真装 + helm test

## 已完成（2026-10-05 ~ 10-14，列车 1.13.0 → 1.21.0）

- [x] **多副本部署拆分**：`PB_DEPLOY_MODE` 三模式（standalone / public×N / admin×1，Redis 配置广播），chart 双拓扑
- [x] **单机内存模式**：`redis.host` 留空 = 进程内 KV 全功能（回源 DB + 负缓存），compose/NAS 免 Redis
- [x] **前端双仓拆分**：frontend-core（平台无关应用 + 宿主适配器 SPI）+ frontend 壳；平台适配器归 fnos/qnap 各仓 `web/`
- [x] **NAS 六平台**：fnos 原生 fpk（开放平台 SSO 深度融合，Docker 镜像停发）、openwrt ipk+apk（UCI/LuCI）、
  qnap 原生 QPKG（QTS SSO 免登录）、synology SPK、ugreen/terramaster compose 部署包
- [x] **发布列车 v1 → v2**：`release/train.yaml` 真相源 + `release/trainctl` 状态机编排器（bump PR 自动合并 →
  按依赖序推 tag → 回挂对账 → hub 快照），凭据收敛 org 级 `PB_BOT_TOKEN`
- [x] **产品版本统一**：1.17.0 起镜像线并入产品号，七终端 + 镜像 + 页脚全随列车号
- [x] **dao 去全局化**：16 域构造必填注入 + 架构棘轮守卫（10 条规则）
- [x] **管理后台重构**：系统配置 11 横排 tab → 7 分区左导航（含 P2P 与联邦）、登录页重构、局部保存清零修复
- [x] **双码体系收口**：6 位取件码（不区分大小写）/ 8 位分享码；取件输入锁 6 格；文本/文件/永久分享同权铸造
- [x] **秒传去重 D1**：同用户内同 hash+size 命中免落盘直接出码 + 删除引用计数保护
- [x] **上游缺口五件**：下载文件名 ASCII 兜底、文件备注（note）、先出码后上传（占位分享 + presign 回填）、
  自定义 admin 路径、暗色模式（light/dark/auto）
- [x] **P2P 对称节点融合**：每台 standalone server = 对称 P2P 节点——federation 收 SystemConfig `p2p` 段 +
  运行时热启停；联邦实例间推送邀请（免手工口令交接）；`p2pc --json` NDJSON 事件流与 env 传码硬化。
  **后续修订（2026-10-22 两应用分拆）**：设备直传编排域 `app/p2px` 及其 admin 端点 / MCP 工具 / CLI 子命令 /
  随包钉版 / desktop sidecar 已随 Wave B' 退役 —— **直传拆为独立应用 PigeonBeam（信鸽直传）**，
  Box 侧只留联邦面（invites / invites-accept / invite-push / directory，`core/app/federation/`）；
  server 镜像**不再随包 p2pc**，desktop 回归纯客户端。真相源：`p2p/docs/PRODUCT.md` +
  `docs/specs/2026-10-16-two-app-split-design.md`。
- [x] **企业级加固**：供应链三件套 15 仓（gitleaks/dependabot/CODEOWNERS）、govulncheck 门禁、
  secret scanning + push protection 全开、攻击面收缩（限流桶/指纹剥离/no-store/CORS 收敛）

## 现在（进行中）

- [ ] 提交 [awesome-selfhosted](https://awesome-selfhosted.net/) 收录（首次发布须 >4 个月，窗口 2027-02 起）
- [ ] 公开 demo 站（定时重置容器）
- [ ] iStore 上架：[linkease/istore-repo PR #810](https://github.com/linkease/istore-repo/pull/810) 待上游合并
- [ ] 飞牛应用中心上架（材料已备，唯一通道=官方微信交流群）
- [ ] 真机验收债（装机面，仓内无 backlog，靠外站 issue 跟踪）：fnos#115（`/beam` 正式 fpk 生命周期）、
      openwrt#110（iStore 真机复验）、ugreen#100、terramaster#99

## 下一步（近期规划）

> 完整规划、落点仓、破坏性与验收判据见
> **[能力演进路线 2026-10-30](docs/specs/2026-10-30-capability-evolution-roadmap.md)**；下列三趟车为该稿节选。

### 第一趟 4.2.0（零破坏，全是「兑现」不是「新建」）

- [ ] **`pb doctor` 自检命令**：部署自检输出可行动结论（DB / 存储 / Redis 模式 / 站点地址 /
      Beam 挂载 / 版本漂移 / 时钟 / 被降级的能力），退出码 0·1·2 分级可测
- [ ] **能力自描述（capability negotiation）**：`/api/config` 扩能力位，前端按位显隐
      —— 「这个面支持什么」收敛成一份真相源，不再各面各写 if
- [ ] **`/setup` 一次性令牌**：补安全债（当前只靠「还没有 admin」判定 ⇒ 公网面存在抢注）

### 第二趟 4.3.x / 5.0

- [ ] **首启四步向导 + NAS 出厂预接线**（站点地址 → 投递策略 → 试一次 → 完成；
      Beam↔Box API Key 预置，免手工粘贴）。依赖「契约增量 → 发 release → 抬前端钉版」两段式
- [ ] **API Key 权限 scope**：read/write/admin/anon-share + 过期 + last-used + 单 key 撤销
      （默认仍全量，存量 key 不受影响）

### 第三趟 5.x–6.x

- [ ] **可迁移备份包 + 存储迁移**：统一备份包格式（换机器 / 换后端 / 灾备）+ local→远端存量搬运
      + SQLite→Postgres/MySQL 换库；**迁移后原取件码与链接不变**
- [ ] **联邦前台化（跨站投递）**：「邀到别人的柜」进前台寄件台（联邦目前只有 admin 面，匿名访客看不见）
- [ ] **零知识 E2E 走出 secure-context**：服务端只存 wrapped key（口令派生 KEK），
      把前提从「HTTPS」换成「有口令」（当前 NAS 典型 http 访问下 E2E 根本用不了）
- [ ] **桌面端做「一等取件端」**：托盘通知 + 一键取 + 剪贴板只放 6 位取件码

### 既有待办（未挂进三趟车）

- [ ] P2P 联邦定时自动同步（邀请推送已交付；定时调度面另立）
- [ ] 跨会话断点续传：按 file_hash 匹配未完成会话（现有同会话续传 + 同用户秒传）
- [ ] Azure Blob/HDFS/OneDrive 驱动真机联调（REST 语义按官方文档实现，Azure 已签名单测；
      OneDrive 需 Azure AD 凭证）
- [ ] Telegram / Bark 通知渠道（SMTP 已落地，架构上扩渠道）
- [ ] 绿联 UPK / 铁威马 TOS 7 官方应用包送审（硬前置：镜像同步发 Docker Hub，待拍板）
- [ ] 前端 en-US 翻译长尾收尾（界面文案全量英文化）
- [ ] Playwright E2E + 前端测试加密
- [ ] ~~主题系统 / 自定义 CSS~~（暗色模式已落地，边际收益低、回归面大 ⇒ **建议降级，待拍板**）

## 更远（探索中）

- [ ] 邮箱找回密码
- [ ] 二次验证（2FA）
- [ ] ~~PWA / 移动端体验、小程序~~ ⇒ 建议**并入「桌面端一等取件端」**，不单独做（待拍板）


## 设计决策记录

- 多仓拆分与依赖方向见 [architecture.md](docs/architecture.md)（CI 强制单向依赖）。
- 存储点亮 / 首启引导详细设计见 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。
- 多副本拆分见 [docs/specs/2026-10-06-multi-replica-deployment-modes.md](docs/specs/2026-10-06-multi-replica-deployment-modes.md)；
  发布列车 v2 见 [docs/specs/2026-10-12-release-train-v2-design.md](docs/specs/2026-10-12-release-train-v2-design.md)；
  P2P 对称节点融合见 [docs/specs/2026-10-14-p2p-peer-integration-design.md](docs/specs/2026-10-14-p2p-peer-integration-design.md)。
- 破坏性变更（删/改名字段、改错误码语义、wire 协议）必须升主版本；p2p wire 破坏性变更双端须同版；生成物一律不手改。
- 未实现的能力不暴露配置键（假开关零容忍，2026-10-04 清理原则）。
