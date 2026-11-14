# PigeonBox 可靠性与安全路线（2026-11-14 技术评审后修订）

- 日期：2026-11-14
- 状态：**规划稿**（§4 三项待拍板；其余批次为默认执行序）
- 来源：外部技术评审（pigeonbox 组织 18 仓定向评审，2026-11-14 交付）
- 基线：列车 **5.8.0 / shipped**（v5.8.0，2026-11-12）；最新 **Train Verify failure**（2026-11-13 连续 3 次：
  `core/go.mod` 钉 contracts v0.24.0 vs `train.yaml` lib.contracts v0.23.0 —— 详见 hub#363）
- **前序稿关系（不推翻，只切换主线）**：
  - [2026-10-30 能力演进稿](2026-10-30-capability-evolution-roadmap.md)：§2/§3 已随 4.2.0 → 4.9.1 **全部兑现**；
    其方法（规划前先实测代码、设计稿的「未做」清单只当线索）继续沿用；
  - [2026-11-06 生命周期稿](2026-11-06-post-4.9-lifecycle-roadmap.md)：主线「版本到达率」已随 5.4.1 **收官**；
  - 既有拍板全部有效：两应用分拆（10-16）、p2p 直传维护模式冻结（PRODUCT.md）、
    D2（PWA 并入桌面端不单做）、**业务域不拆微服务**。
- 配套 issue：本日新建 **15 条**（§3 表）+ 同日深度审计补提 **47 条**（§3.1），历史已有单见 §1/§2。

## 0. 结论：主线从「功能扩张」切换为「可靠性与安全驱动」

评审的核心判断我们认可：生态已具备多仓边界、Go 业务内核复用、自动化交付体系三个优势，
但**认证旁路、存储生命周期不一致、配额与 Complete 缺并发保证、发布对账缺分层**四件事
说明工程质量还没跨过一个阶段。下一阶段四条主线：

1. **可靠性验证** —— 测试从「有 CI」走到「有可信质量证据」（L1–L8 + 三项强制测试）；
2. **跨平台交付质量** —— 平台能力契约、兼容矩阵、K8s 故障与回滚演练；
3. **安全边界收敛** —— P0 立即修 + 统一 Policy Enforcement（规则不再依赖调用方自觉）；
4. **真实产品体验** —— 中断恢复、失败面透明化、SDK（不做网盘化功能）。

**四不**（评审与既有定位一致）：不做网盘/Office 协作、不拆微服务、不做 DHT/去中心化发现、
不做独立 PWA。版本号**不预绑定功能**——由验证通过的变更决定能否进车，安全修复走 hotfix 通道。

## 1. 评审 P0/P1 的存量单盘点（全部已有单，本轮零补提）

评审 §三的 13 个 P0/P1 在 2026-11-13 审计轮已全部开单，本稿只做对账，不重复开单：

| 级别 | 问题 | 单 | 状态（2026-11-14） |
|---|---|---|---|
| P0 | 管理员 TOTP 认证旁路 | [core#162](https://github.com/pigeonbox/core/issues/162) | open，**建议走 hotfix** |
| P0 | Synology 安装 chown -R 越界 | [synology#149](https://github.com/pigeonbox/synology/issues/149) | open |
| P0 | Synology 升级放宽 .env 权限 | [synology#148](https://github.com/pigeonbox/synology/issues/148) | open |
| P1 | 回收站绕过配额 | [core#167](https://github.com/pigeonbox/core/issues/167) | open |
| P1 | 并发配额检查非原子 | [core#169](https://github.com/pigeonbox/core/issues/169) | open |
| P1 | 彻底删除不清对象 | [core#168](https://github.com/pigeonbox/core/issues/168) | open |
| P1 | Complete 并发不幂等 | [core#151](https://github.com/pigeonbox/core/issues/151) | open |
| P1 | ZIP 流失败不关闭 | [core#154](https://github.com/pigeonbox/core/issues/154) | open |
| P1 | 预览不扣取件次数 | [core#170](https://github.com/pigeonbox/core/issues/170) | open |
| P1 | 取件码枚举防护不覆盖 | [core#163](https://github.com/pigeonbox/core/issues/163) | open |
| P1 | OIDC 出站 SSRF | [core#164](https://github.com/pigeonbox/core/issues/164) | open |
| P1 | 邀请信箱无身份校验 | [p2p#45](https://github.com/pigeonbox/p2p/issues/45) | open |
| P1 | 信令会话可耗尽 | [p2p#46](https://github.com/pigeonbox/p2p/issues/46) | open |
| P1 | chart 默认无认证 Redis | [charts#20](https://github.com/pigeonbox/charts/issues/20) | open |
| P1 | redis.auth 后 Init 死等 | [charts#19](https://github.com/pigeonbox/charts/issues/19) | open |

> 另有同族存量单在册未列：core#165/#166/#171、p2p#47/#48/#49、desktop#143、
> frontend-core#90/#92、charts#21/#22、openwrt#198、hub#358/#359/#360/#362。

## 2. 分批路线

### 第一批 · 安全与数据正确性（P0 走 hotfix，不等列车）

1. **P0 三单**：core#162（TOTP 旁路 —— 修复前公网管理入口用 VPN/白名单兜底）、synology#149、#148；
2. **数据正确性组**：core#167 / #169 / #168 / #151 / #154 / #170 / #171 —— **按整改伞
   [core#172](https://github.com/pigeonbox/core/issues/172) 的统一生命周期模型修**，不做零散补丁；
3. **安全边界组**：core#163 / #164、p2p#45 / #46、charts#19 / #20、desktop#143 ——
   收口进 [core#173](https://github.com/pigeonbox/core/issues/173) 的策略面；
4. 验收口径：修复必须**带复现/负对照测试**（bug 先写复现测试的既有约定）。

### 第二批 · 发布工程与质量证据

1. [hub#363](https://github.com/pigeonbox/pigeonbox/issues/363)：train verify 拆两层
   （已发布快照 vs main 开发态）+ 机器可读 release manifest —— **这是「漂移红灯」的治本**；
2. [hub#364](https://github.com/pigeonbox/pigeonbox/issues/364)：L1–L8 质量矩阵，
   先落**三项强制测试**（100 并发 Complete 幂等 / 备份隔离恢复 / 破坏性升级可恢复）；
3. [core#172](https://github.com/pigeonbox/core/issues/172)：文件生命周期统一
   （Blob/FileReference + 状态机 + 原子配额账本 + 引用计数 GC）—— 第一批的承载架构；
4. [core#173](https://github.com/pigeonbox/core/issues/173)：统一 Policy Enforcement
   + CI 路由「鉴权×频控」矩阵扫描（新增公开入口必须声明策略）。

### 第三批 · 交付质量、协议与供应链

1. [charts#23](https://github.com/pigeonbox/charts/issues/23)：K8s 一等交付
   （PDB、容量告警、灰度回滚演练、节点终止/Redis 不可用/上传中 Pod 迁移三场景验证）；
2. [hub#365](https://github.com/pigeonbox/pigeonbox/issues/365)：平台 Capability Contract
   + Platform Compatibility Matrix（六适配仓声明能力，每字段配可执行验收）；
3. [p2p#50](https://github.com/pigeonbox/p2p/issues/50)：wire 互操作测试矩阵
   （属 PRODUCT.md 冻结豁免的「协议兼容窗口」投入；v5 升级前置条件）；
4. 供应链与披露收尾：hub#358（SECURITY.md）/ #359（Dependabot）/ #360（k8s :latest）/
   frontend-core#90（action pin）/#92（sass 依赖）/ .github#1（README :latest）；
5. 生态债：hub#240 真机验收与分发清单（openwrt#110、terramaster#99、ugreen#132 三条外部条件单）。

### 第四批 · 产品体验（6–12 个月，评审 §八；均不破坏既有拍板）

1. [frontend-core#94](https://github.com/pigeonbox/frontend-core/issues/94)：弱网与中断恢复
   （下载断点、上传恢复、真机三场景哈希一致验收）；
2. [frontend-core#93](https://github.com/pigeonbox/frontend-core/issues/93)：取件失败面透明化
   （**需拍板隐私边界**，见 §4）；
3. [hub#367](https://github.com/pigeonbox/pigeonbox/issues/367)：官方 Go/TS SDK；
4. [hub#368](https://github.com/pigeonbox/pigeonbox/issues/368)：企业受控部署策略（策略模板层）；
5. 存量展望单按册推进：core#160（Passkey）、core#159（按目录配额）、core#161（ClamAV strict）、
   frontend-core#91（访问运营视图）、hub#366（公开看板）、charts#24（README 版本生成化）；
6. [p2p#51](https://github.com/pigeonbox/p2p/issues/51)：跨网直连率优化 —— **需先拍板豁免 p2p 冻结**（§4）。

## 3. 本轮新建 issue（15 条，2026-11-14）

| # | 单 | 仓 | 分类 |
|---|---|---|---|
| 1 | [hub#363](https://github.com/pigeonbox/pigeonbox/issues/363) train verify 两层化 + release manifest | hub | 发布工程 |
| 2 | [hub#364](https://github.com/pigeonbox/pigeonbox/issues/364) L1–L8 质量矩阵 + 三项强制测试 | hub | 测试 |
| 3 | [hub#365](https://github.com/pigeonbox/pigeonbox/issues/365) 平台 Capability Contract + 兼容矩阵 | hub | 平台 |
| 4 | [hub#366](https://github.com/pigeonbox/pigeonbox/issues/366) 公开项目看板六分类 + 跨仓质量指标 | hub | 生态运营 |
| 5 | [hub#367](https://github.com/pigeonbox/pigeonbox/issues/367) 官方 Go/TS SDK | hub | 产品 |
| 6 | [hub#368](https://github.com/pigeonbox/pigeonbox/issues/368) 企业受控部署策略 | hub | 产品 |
| 7 | [.github#1](https://github.com/pigeonbox/.github/issues/1) Profile README 用 server:latest | .github | 文档 |
| 8 | [core#172](https://github.com/pigeonbox/core/issues/172) 文件生命周期统一（整改伞） | core | 架构 |
| 9 | [core#173](https://github.com/pigeonbox/core/issues/173) 统一 Policy Enforcement + 路由矩阵 | core | 安全 |
| 10 | [charts#23](https://github.com/pigeonbox/charts/issues/23) K8s 一等交付补齐 | charts | K8s |
| 11 | [charts#24](https://github.com/pigeonbox/charts/issues/24) README 示例版本陈旧 | charts | 文档 |
| 12 | [p2p#50](https://github.com/pigeonbox/p2p/issues/50) wire 互操作测试矩阵 | p2p | 协议 |
| 13 | [p2p#51](https://github.com/pigeonbox/p2p/issues/51) 跨网直连率优化（需拍板） | p2p | 展望 |
| 14 | [frontend-core#93](https://github.com/pigeonbox/frontend-core/issues/93) 取件失败面透明化（需拍板） | frontend-core | 产品 |
| 15 | [frontend-core#94](https://github.com/pigeonbox/frontend-core/issues/94) 弱网与中断恢复体验 | frontend-core | 产品 |

> 每条都经源码核验后才开（文件:行证据写在各单正文里）；评审稿中
> 「Profile README 仍含早期默认管理员说明」一条**实测不成立**（.github/profile/README.md:110
> 已写明 3.0.0 起无默认口令），未开单，勘误记于 .github#1 正文。

### 3.1 同日第二批：四路深度审计补提（47 条，2026-11-14）

> 方法：四路并行**只读**审计（contracts+server / 前端双仓 / 五平台打包仓 / desktop+hub 脚本），
> 每条候选由主会话**逐行抽核**后才开单（含门禁实测复跑、origin/main 拉取对账、go-sdk 源码核验）；
> 各路「怀疑过但排除」合计 26 条也留档（如 MCP GET/DELETE 经 SDK 源码证实恒 405、
> 钥匙串无明文回退、413 映射三通道全覆盖）。

| 仓 | 条数 | 单号 | 主题 |
|---|---|---|---|
| hub | 6 | [#370](https://github.com/pigeonbox/pigeonbox/issues/370)–[#375](https://github.com/pigeonbox/pigeonbox/issues/375) | 体积门禁形态盲区 / 根 compose latest / go-version-floor 自证掩蔽 / shellcheck 射程 / ci-health 只认 failure / 大写单位假红 |
| contracts | 6 | [#28](https://github.com/pigeonbox/contracts/issues/28)–[#33](https://github.com/pigeonbox/contracts/issues/33) | 三道生成链过滤口径不一致 / typedef 作用域不对称 / **打 tag 即打包不跑 CHECK** / 错误码清单滞后 27 码 / CHECK 日志截断 / gen-ts 指引死循环 |
| server | 8 | [#125](https://github.com/pigeonbox/server/issues/125)–[#132](https://github.com/pigeonbox/server/issues/132) | **release 拼零保护 tag 名（ruleset 实测为空）** / entrypoint 不透传 / pb put -t 吞文件 / doctor 30min 超时 / url -p 缺值 / 子命令静默起服 / latest 无条件打标 / db import 防混库旁路 |
| frontend | 3 | [#168](https://github.com/pigeonbox/frontend/issues/168)–[#170](https://github.com/pigeonbox/frontend/issues/170) | Dockerfile 20m 漏门禁 / **CSP×presign 跨域直传（需复核）** / 壳 typecheck 不覆盖 views+router |
| frontend-core | 7 | [#95](https://github.com/pigeonbox/frontend-core/issues/95)–[#101](https://github.com/pigeonbox/frontend-core/issues/101) | **OIDC 回调登录态不进 store（登录成功被踢回）** / **main 依赖大抬升未抬版（core 绿≠发布物）** / fetchUserInfo 无测试 / userRole 写点不收口 / 标题不刷新 / Swagger 缺 CSRF 头 / OIDC 页硬编码中文 |
| desktop | 4 | [#144](https://github.com/pigeonbox/desktop/issues/144)–[#147](https://github.com/pigeonbox/desktop/issues/147) | get_pickup_status 读侧漏闸（#143 对账数错）/ 明文确认内网判据可绕 / 轮询并发无互斥 / 列表只拉第一页 50 条 |
| fnos | 3 | [#210](https://github.com/pigeonbox/fnos/issues/210)–[#212](https://github.com/pigeonbox/fnos/issues/212) | **prewire 把口令/Key 放 curl argv（三端同源）** / 升级快照静默失败+按 mtime 轮转 / /beam 令牌进 URL query |
| qnap | 2 | [#189](https://github.com/pigeonbox/qnap/issues/189)–[#190](https://github.com/pigeonbox/qnap/issues/190) | 升级 sed 后不恢复 600（synology#148 同型）/ prewire argv 同款 |
| openwrt | 3 | [#199](https://github.com/pigeonbox/openwrt/issues/199)–[#201](https://github.com/pigeonbox/openwrt/issues/201) | **口令/Redis 密码明文存 UCI 0644 全程无收紧** / prerm 吞停服失败 / prewire argv 同款 |
| ugreen | 3 | [#155](https://github.com/pigeonbox/ugreen/issues/155)–[#157](https://github.com/pigeonbox/ugreen/issues/157) | UPK 硬编码 1024m / 升级无快照无备份提示 / compose 无 logging 上限 |
| terramaster | 2 | [#153](https://github.com/pigeonbox/terramaster/issues/153)–[#154](https://github.com/pigeonbox/terramaster/issues/154) | 升级无快照无备份提示 / TOS7 compose 无 logging 上限 |

**三条最重的**（建议优先排期）：

1. [server#125](https://github.com/pigeonbox/server/issues/125)：release 把零保护的 tag 名拼进持
   `PB_BOT_TOKEN` 的高权限脚本（两仓 ruleset 实测均为空）——唯一具备升级为供应链事故路径的发现；
2. [frontend-core#96](https://github.com/pigeonbox/frontend-core/issues/96)：main 依赖大抬升
   （contracts 0.24.0 / vue-i18n 11 / pdfjs 6 / vite 8）未抬版 ⇒ 列车 bump 永远钉旧 tgz，
   core 绿 ≠ 发布物行为 —— 与 hub#363 的两层验证互为表里；
3. 三端 prewire argv 凭据泄露（[fnos#210](https://github.com/pigeonbox/fnos/issues/210) /
   [qnap#190](https://github.com/pigeonbox/qnap/issues/190) /
   [openwrt#201](https://github.com/pigeonbox/openwrt/issues/201)）——
   三份脚本 sha256 逐字节一致，修复必须三仓同改（hub#241 门禁会拦单端改动）。

## 4. 需拍板项（阻塞对应批次）

| # | 拍板点 | 影响 |
|---|---|---|
| D6 | **p2p#51 是否豁免直传冻结**（PRODUCT.md 维护模式 vs 评审「跨网优化」中优先） | 不豁免则留档不排期 |
| D7 | **取件失败面的隐私边界**（失败记录保留时长、是否展示来源粒度） | frontend-core#93 开工前置 |
| D8 | **core#172 整改伞的排期归属**（第一批热修逐单修 vs 先立模型再修） | 决定第一批的 PR 形态 |

## 5. 长期工程指标（评审 §十；**目标非现状**）

| 指标 | 目标 |
|---|---|
| 已确认严重认证绕过 | 0 个未修复进入正式发行版 |
| 发布列车依赖不一致 | 0 个（hub#363 落地后按层判读） |
| 同一上传会话重复创建分享 | 0 个 |
| 配额并发超额 | 在定义的业务边界内为 0 |
| 无引用且过宽限期的对象 | 可检测、可重试、最终清理 |
| 备份可恢复性 | 每个正式版本至少一次隔离恢复验收 |
| 正式镜像使用可变 latest | 0 个 |
| 关键跨版本升级路径 | 自动化覆盖 + 真机验证记录 |
| 重要安全策略入口覆盖 | 100% 公开路由有声明与测试 |

## 6. 明确不做

- 完整网盘、Office 在线协作（偏离轻量文件快递柜定位）；
- 将业务域拆为微服务（评审与既有拍板一致：模块化单体即可）；
- DHT / 去中心化内容网络（p2p 定位：直传、失败中继、可达性、可靠恢复优先）；
- 独立 PWA / 小程序（D2：并入桌面端一等取件端）；
- 主题系统 / 自定义 CSS（D3：降级）。

## 7. 与既有体系的关系

- **门禁**：本稿新增项凡可机械化的，一律落 hub CI 门禁（对齐「加门禁前四问」与
  `docs/rules/ci-gate-failures.md`），不做纯文档承诺；
- **发车**：第一批 P0 走 hotfix 通道；其余按 `release/train.yaml` 正常列车，
  版本号由验证通过的变更决定（不预绑定）；
- **真机**：第四批验收一律真机（10.10.10.3 / 10.10.30.253），冒烟基线随 hub#333 后口径。
