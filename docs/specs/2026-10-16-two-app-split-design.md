# 两应用终态分拆设计——PigeonBox × PigeonBeam

> 2026-10-16 规划稿，待拍板。前置已落地：PigeonBeam 品牌与 wire N-1 协商窗口（p2p 仓 `docs/PRODUCT.md`，v0.7.0/v0.7.1）。本稿回答「两个应用各自应该长什么样、怎么改过去」。

## 0. 现状盘点（2026-10-16 实测）

直传面（PigeonBeam 职责）目前嵌在 PigeonBox 里的落点：

| 落点 | 规模/清单 |
|---|---|
| core `app/p2px` supervisor | 2787 行（spawn p2pc + 任务环 + 收件入柜编排） |
| contracts `AdminP2PService` | 12 端点中 **8 个纯直传**：status / tasks / tasks/:id/log / send / send/upload / recv / cancel / publish |
| core MCP | 22 工具中 **4 个纯直传**：p2p_status / p2p_tasks / p2p_send / p2p_recv |
| server `pb` CLI | p2p 九子命令中 **5 个纯直传**：status / tasks / send / recv / cancel |
| frontend-core | `P2pTransfer.vue` 1109 行（整页=直传控制台，内嵌一块联邦邀请面板）+ api/p2p.ts；系统配置 p2p 分区 direct 子段 |
| SystemConfig | `P2P{Federation, Direct}` 两段（config 层已天然分离） |
| 打包 | 五处随包钉版（server 镜像 / fnos / qnap / openwrt / desktop sidecar） |

联邦面（PigeonBox 真命题，留守）：core `app/federation` 1153 行；admin 端点 4 个（invites / invites/accept / invite-push / directory）；MCP 3 个（p2p_peers / p2p_invites / p2p_accept）；CLI 4 个（peers / invites / accept / push）；`P2P.Federation` 段；`P2PPublicService`（/api/v1/p2p/invite 公开收件）；charts p2pd 组件；p2pd 公共节点。

## 1. 终态定义

**PigeonBox（文件快递柜）**：匿名口令分享 + 联邦（跨站口令路由/推送邀请/名录）。**对 p2pc 零代码依赖、零二进制随带、零直传 UX**——admin 面只出现「联邦」，永远不出现「直传」。

**PigeonBeam（信鸽直传）**：p2pc / p2pcweb / p2pd。设备直传的全部 UX 归它（网页客户端已是完整控制面）；新增「投递到柜」桥能力。

**桥的定义（方向翻转，本设计的核心）**：现状 = Box 内嵌 p2pc 编排（p2px supervisor + admin 端点）；终态 = **Beam 作为 Box 的 API 客户端**——p2pcweb「投递到柜」模式：收到的文件经 Box 公开 API（URL + API Key，用户自配）上传并创建分享，拿 6 位取件码。Box 不为 Beam 增加任何端点；同机部署时这条 API 调用走本机，无额外网络成本。

## 2. 波次

**Wave A（非破坏，随下列车即可）**
- A1 Beam「投递到柜」：p2pcweb 增 recv 后自动投递 Box（配置 Box URL + API Key），返回取件码。纯 Beam 侧增量。
- A2 NAS 包直传面重定位：fnos/qnap/openwrt 继续随带 p2pc/p2pcweb（钉版冻结 = PRODUCT.md Phase 2②），但入口从「Box admin 控制台」切到「内嵌 p2pcweb 页面」——服务脚本直管 p2pcweb 进程（LAN 暴露 + 令牌门禁已有，打包侧可加反代鉴权），不再经 `/admin/p2p/*`。
- A3 desktop sidecar 冻结：不再随列车升级，v3 摘除。
- A4 文档：docs-site 开 PigeonBeam 区；org topics/门面补 PigeonBeam 定位。

**Wave B（破坏性拆除，v3.0.0 主波；列车已在 2.0.1，下一主版本即窗口）**
- B1 core：删 `app/p2px`（2787 行）；SystemConfig 删 `P2P.Direct` 段（陈旧 `direct` 键忽略+启动提示）；MCP 删 p2p_status/p2p_tasks/p2p_send/p2p_recv；config 域 direct 热切换钩子与测试同撤。
- B2 contracts：`p2p.thrift` 删 8 个直传端点及相关 struct；**留** invites/invites-accept/invite-push/directory + `P2PPublicService`；gen 链三产物重跑（CHECK=1 守卫）。
- B3 frontend-core：`P2pTransfer.vue` 拆解——联邦邀请面板迁入联邦页（或 config p2p 分区 federation 子段），直传控制台删除；api/p2p.ts 收缩到联邦端点；系统配置 p2p 分区删 direct 子段（7 分区左导航结构不变）。
- B4 server：`pb` CLI 删 status/tasks/send/recv/cancel 五子命令（help 同步）；Dockerfile 摘 `ARG P2PC_VERSION` 与 `/app/p2pc`。
- B5 desktop：摘 sidecar（externalBin + CI triple 拉取逻辑）；失败明示改「直传请安装 PigeonBeam」。
- B6 charts/deploy：核对直传中继组件口径（p2pd 留守联邦，中继随 p2pd 走）。

**Wave C（另行拍板）**
- repo 改名 `pigeonbox/p2p → pigeonbox/pigeonbeam`（建议缓：改名打断钉版 URL/CI secret/文档链接，收益仅观感）。
- PigeonBeam 独立文档站/独立桌面壳（Tauri）/各平台独立安装包（fpk/qpkg）。

## 3. 决策点（待拍板）

- **D1 NAS 是否继续随带直传面**：建议**继续**，但改为内嵌 Beam 客户端形态（A2）——「开箱直传」卖点保留，Box admin 归于纯粹。
- **D2 desktop sidecar v3 摘除**：建议**摘**——桌面直传=装 PigeonBeam（p2pcweb 已覆盖老底座）；Box 桌面端回归纯客户端。
- **D3 MCP/CLI 直传工具处置**：建议**删**而非「检测 p2pc 才暴露」——维护模式下探测存活的编排代码本身就是负债；联邦三工具与名录保留。
- **D4 repo 改名时机**：建议**缓**（Wave C）。

## 4. 兼容与迁移

- v3 破坏面清单（release notes 必列）：admin 8 端点 404；MCP 4 工具消失；CLI 5 子命令移除；配置 `p2p.direct` 段忽略。每项附「直传请用 PigeonBeam」指引。
- 过渡期互操作：N-1 区间协商（p2p v0.7.1）保障 Wave A/B 期间钉版混布的双端可达。
- 联邦面零变化：4 admin 端点、3 MCP 工具、4 CLI 子命令、`P2P.Federation` 段、公开收件 API 全部原样。
- 版本口径：Wave A 随 2.0.x 列车；Wave B 集成为 **v3.0.0**（admin API/MCP/CLI 三面同车删，避免三连破坏）。
