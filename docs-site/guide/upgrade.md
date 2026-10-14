---
title: 升级说明
---

<!-- 内容引自 hub 仓库 docs/v0.3-upgrade-notes.md（真相源），勿在本页手改内容 -->
<!--@include: ../../docs/v0.3-upgrade-notes.md-->

### 0.12.x（会话 Cookie 化列车）

- **浏览器会话迁 HttpOnly Cookie**：前端不再持久化令牌；第三方脚本/桌面端继续走 `Authorization: Bearer` 与 API Key，零改动。Cookie 认证的写请求须携带 `X-Requested-With: XMLHttpRequest`（CSRF 防御，前端已内置）。
- **密码分享取件页修复**：业务性 401（需要密码/密码错误）不再触发会话刷新，匿名取件人不再被跳转登录页。
- **p2p 直传协议 v2**（p2p v0.4 / desktop v1.3.1）：与旧版互不兼容，双端须同版升级。
- **CSP**：前端 nginx 层下发 `script-src 'self' 'unsafe-eval'`（vue-i18n 运行时编译需要；自建反代如自行收紧 CSP 需保留 eval，否则 i18n 白屏）。

### 1.17.0（产品版本统一列车）

- **版本号口径变化**：server/frontend 镜像 tag 由 `0.15.x` 形态并入产品号（`1.17.0` 起，无 `v` 前缀）；升级时把 `PB_IMAGE_TAG` / chart `image.tag` 直接写新版本号即可，存量 0.15.x 钉版镜像仍可拉取。
- 七终端应用包（desktop/fnos/openwrt/synology/qnap/ugreen/terramaster）同号发布，包内页脚版本与镜像一致。
- **秒传去重**：同账号重复上传同内容文件命中去重免落盘；删除分享按引用计数保护物理文件（被其他分享引用的文件不随删除消失）。

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
