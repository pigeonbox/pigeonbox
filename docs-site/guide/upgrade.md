---
title: 升级指南
---

# 升级指南

怎么把运行中的 PigeonBox 升到新版本，以及哪些版本之间**不兼容**。

> 各版本的完整变更（组件矩阵、破坏性变更清单）见[版本发布说明](/changelog)。

## 升级操作清单（Docker Compose，通用）

```bash
# 1. 备份状态目录（SQLite 库 + 上传文件 + .jwt_secret；上传文件目录另行拷贝）
cp -a data /backup/pigeonbox-data-$(date +%F)
#    一致性快照（不停机可选）：
#    sqlite3 data/fileCodeBox.db ".backup '/backup/fileCodeBox.db.bak'"
#    注意：匿名取件码映射在命名卷 redisdata，跨机迁移需一并导出（见部署指南）

# 2. .env 钉住新版本（server/frontend 两镜像同 tag 一起更新，建议具体版本而非 latest）
vi .env   # PB_IMAGE_TAG=3.0.0

# 3. 拉取新镜像并重建容器（必须 force-recreate，数据卷不动）
docker compose pull && docker compose up -d --force-recreate

# 4. 验证
curl http://localhost:12345/live       # 健康检查
docker compose logs --tail=50 pigeonbox  # 看启动日志有无报错
```

**回滚**：把 `.env` 的 `PB_IMAGE_TAG` 改回旧版本号，再走第 3 步 `docker compose pull && docker compose up -d --force-recreate` 重建即可（数据卷不动；若新版本已发生数据迁移，回滚前请先恢复第 1 步的备份）。

Kubernetes 部署升级随 chart `appVersion`（`helm upgrade`），详见 charts 仓库 README。更多细节（Redis 卷导出、备份策略）见[部署 Docker Compose](./deploy-docker)。

## 版本变更要点（历史列车；2.x 各列车见[版本发布说明](/changelog)）

### 3.0.0（设备直传拆出列车 · 破坏性）

- **设备直传拆为独立应用 PigeonBeam（信鸽直传）**：Box 侧不再编排直传数据面。`core` 的 `p2px` 域、contracts 的 9 个直传管理端点、MCP 直传四工具、`pb p2p` 的 5 支直传子命令、server 镜像随包 p2pc、desktop 的 p2pc sidecar **全部移除**。直传请用 [PigeonBeam](/guide/pigeonbeam)。
- **Box 侧保留联邦面**：4 个 `/admin/p2p/*` 端点（待收邀请 / 认领信封 / 推送 / 在线名录）、MCP 3 个联邦工具、`pb p2p` 4 支子命令。`POST /admin/p2p/invites/accept` 的返回体从「直传任务」改为**纯信封**——认领只出信封，文件接收由 PigeonBeam 完成。
- **首启行为变了（升级后需确认）**：不再播种弱口令 `admin/admin123`。`PB_ADMIN_PASSWORD` 留空 → 走 `/setup` 首启向导（浏览器打开站点建号）；已设则按该密码建 admin。**存量实例不受影响**（库中已有 admin，core 直接返回）。
- **陈旧配置会响亮提示**：若你的 `SystemConfig` 里还留着 `p2p.direct.*`（旧直传段），启动日志会明确告警「检测到陈旧配置 p2p.direct.*，已忽略；请把 registry_url 改配到 p2p.federation.registry_url」——**不是静默失效**，请照提示改。
- **管理台左导航改名**：「P2P 与联邦」分区改为「联邦」，直传控制台页移除（联邦面板独立成页）。
- **库线版本**：contracts v0.18.0 · core v0.27.0 · frontend-core v0.9.0。壳仓与 NAS 包的 tgz/二进制钉版由列车统一抬升。

::: warning 升级到 3.0.0 前请确认
① 备份 `data/`（见上方清单）；② 若你用过设备直传，**先确认 PigeonBeam 侧的替代路径**，本次升级会移除 Box 内的直传编排；③ NAS 端升级会顺带更新内嵌前端，旧的直传控制台页会消失（预期行为）。
:::

### 1.22.0（P2P 邀请推送列车）

- **联邦实例间推送邀请**：已建立联邦关系的站点间可在管理后台直接推送传输邀请（对方待收/认领），免手工口令交接；公开收件端点 `POST /api/v1/p2p/invite`（限流归桶，口令=bearer 信任级同手工交接）。
- **pb CLI 扩展**：新增 `pb p2p` 八支子命令（status/tasks/send/recv/cancel/invites/accept/push），admin API Key 通道。
- **p2pc `--json`**：NDJSON 事件流输出（code/done/error），供脚本/自动化消费；缺省纯文本输出不变。
- 直传双端协议仍为 wire v4：随列车把各端 p2pc 一并升级即可（server 镜像/NAS 包/desktop sidecar 均已随包钉版）。

### 1.21.0（P2P 对称节点列车）

- **P2P 联邦与设备直传收进管理后台**：「系统配置 → P2P 与联邦」分区热启停，保存即生效无需重启；旧 env/yaml 配置作为首启种子自动迁移，之后以数据库配置为准。
- **设备直传开箱可用**：server 镜像与 fnos/qnap/openwrt 包自本版起随包 p2pc 二进制，无需额外安装；管理后台新增「设备直传」控制台（发送/接收/发布为分享）。
- **standalone 专属**：多副本拆分部署（`PB_DEPLOY_MODE=public/admin`）下 P2P 能力自动降级关闭。
- **p2p wire 协议 v4**（p2p v0.6.x）：与 v3 之前互不兼容，直传双端（含 desktop sidecar、各端随包 p2pc）须同版升级——全端随本列车同号发布，一起升级即可。
- 取件输入锁定 6 格（超长粘贴自动转分享码链路）；管理后台配置页改左导航 7 分区。

### 1.17.0（产品版本统一列车）

- **版本号口径变化**：server/frontend 镜像 tag 由 `0.15.x` 形态并入产品号（`1.17.0` 起，无 `v` 前缀）；升级时把 `PB_IMAGE_TAG` / chart `image.tag` 直接写新版本号即可，存量 0.15.x 钉版镜像仍可拉取。
- 七终端应用包（desktop/fnos/openwrt/synology/qnap/ugreen/terramaster）同号发布，包内页脚版本与镜像一致。
- **秒传去重**：同账号重复上传同内容文件命中去重免落盘；删除分享按引用计数保护物理文件（被其他分享引用的文件不随删除消失）。

### 0.12.x（会话 Cookie 化列车）

- **浏览器会话迁 HttpOnly Cookie**：前端不再持久化令牌；第三方脚本/桌面端继续走 `Authorization: Bearer` 与 API Key，零改动。Cookie 认证的写请求须携带 `X-Requested-With: XMLHttpRequest`（CSRF 防御，前端已内置）。
- **密码分享取件页修复**：业务性 401（需要密码/密码错误）不再触发会话刷新，匿名取件人不再被跳转登录页。
- **p2p 直传协议 v2**（p2p v0.4 / desktop v1.3.1）：与旧版互不兼容，双端须同版升级。
- **CSP**：前端 nginx 层下发 `script-src 'self' 'unsafe-eval'`（vue-i18n 运行时编译需要；自建反代如自行收紧 CSP 需保留 eval，否则 i18n 白屏）。
