# PigeonBox RoadMap

> 最后更新：2026-10-04。路线按「现在（进行中）/ 下一步 / 更远」组织，完成即勾选。
> 功能请求请到各仓 Issues；重大设计变更会先在 `docs/design/` 落设计文档。

## 定位

**匿名口令文件快递柜**：像取快递一样收发文本与文件。坚持轻量、开箱即用，
不做网盘、不做重存储平台——这是对上游社区共识（[#434](https://github.com/vastsa/PigeonBox/issues/434)）
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
- [x] **MCP Server**：JSON-RPC 8 工具（分享/查询/管理，上游无此能力）
- [x] **`fcb` CLI**（基于 API Key 体系）
- [x] 可选 ClamAV 病毒扫描（fail-open 接线）
- [x] OIDC 单点登录 / Range 断点续传 / 自定义取件码 / NAS 本地文件免上传导入与管理
- [x] `/share/metadata` 元数据端点（查询不扣次数）+ openapi.json 运行时生成（零漂移）
- [x] 开源合规件：LICENSE（7 仓）/ CONTRIBUTING / SECURITY / CHANGELOG / 文档站（docs-site VitePress）
- [x] 全局存储配额（storage.quota）+ 分片逐片哈希强校验
- [x] 存储驱动扩展：FTP/FTPS、SFTP、GCS、Azure Blob、HDFS(WebHDFS)、OneDrive(Graph)
- [x] 安全版主题（背景图/主题色白名单校验）
- [x] 质量基建：golangci-lint 门禁（CI 同款 make lint）、44 项全能力冒烟（scripts/smoke-full.sh）、
  chunk 大文件生命周期回归、Helm CI 真装 + helm test

## 现在（进行中）

- [ ] 提交 [awesome-selfhosted](https://awesome-selfhosted.net/) 收录（首次发布须 >4 个月，窗口 2027-02 起）
- [ ] 公开 demo 站（定时重置容器）
- [ ] 主题系统 / 自定义 CSS（旧单体 legacy 有原型；配置键已随假开关清理移除，实装按新形状回归）

## 下一步（近期规划）

- [ ] 存储迁移工具：local → 远端后端存量数据搬运
- [ ] 跨会话断点续传：按 file_hash 匹配未完成会话（现有同会话续传 + 跨会话秒传）
- [ ] Azure Blob/HDFS/OneDrive 驱动真机联调（REST 语义按官方文档实现，Azure 已签名单测；
      OneDrive 需 Azure AD 凭证）
- [ ] Telegram / Bark 通知渠道（SMTP 已落地，架构上扩渠道）
- [ ] Playwright E2E + 前端测试加密
- [ ] 飞牛 fnOS 真机联调（fnos v1.2.x 适配层已就绪：SSO/共享目录/通知/穿透多为接口桩，等 Open API 凭证解锁实调）

## 更远（探索中）

- [ ] 邮箱找回密码
- [ ] PWA / 移动端体验

## 设计决策记录

- 多仓拆分与依赖方向见 [architecture.md](docs/architecture.md)（CI 强制单向依赖）。
- 存储点亮 / 首启引导详细设计见 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。
- 破坏性变更（删/改名字段、改错误码语义）必须升主版本；生成物一律不手改。
- 未实现的能力不暴露配置键（假开关零容忍，2026-10-04 清理原则）。
