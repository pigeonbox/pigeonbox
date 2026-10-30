# PigeonBox 能力演进路线（2026-10-30 规划稿）

- 日期：2026-10-30
- 状态：**规划稿**（§2 三项为默认执行项；§5 的 D1–D5 待拍板）
- 基线：列车 **4.1.2 / shipped**（`release/train.yaml`）—— core `v0.32.29` / frontend-core `v0.11.37` /
  p2p `v0.9.6` / contracts `v0.20.4`；hub Release `v4.1.2`
- **不推翻**既有拍板：`2026-10-16-two-app-split-design.md`（两应用分拆）、
  `2026-10-18-p2p-pairing-code-design.md`（四位配对码）、
  `2026-10-22-usability-cs-p2p-unification-design.md`（易用性与 CS+P2P 统一，Q1–Q9 已代决）
- 关联：`ROADMAP.md`（本稿落地后同步更新）、`docs/architecture.md`
- 配套 issue：见 §7

## 0. 结论

生态已从「能跑通」走到「装得下、发得出」（4.1.2：7 终端 + 双镜像 + chart + 文档站全线发货）。
下一阶段**不再堆功能**，而是三件事：

1. **让已有能力可发现** —— 能力自描述（一份真相源）+ `pb doctor`（自检）；
2. **把两个半成品补完** —— 零知识 E2E 走出 secure-context、联邦从 admin 面走向前台；
3. **补一块运维底座** —— 可迁移备份包 + 存储迁移（今天换机器 / 换后端 / 换数据库都没有工具）。

排期：**第一趟 4.2.0 三项零破坏**（doctor / 能力自描述 / setup 令牌）→ **第二趟**
（首启四步向导 + NAS 出厂预接线、API Key 权限 scope）→ **第三趟**（备份包、联邦前台化、
E2E、桌面端取件端）。

> **本稿的规划基线一律以代码现状为准，不以设计稿的「未做」清单为准**（理由见 §1.1）。

## 1. 规划前的现状核对（2026-10-30 实测，不是读文档）

### 1.1 两处「文档已过期」——照旧稿排期会做重复功

| 旧稿口径 | 实际代码（2026-10-30） |
|---|---|
| `2026-10-22-...-design.md` §「本轮明确未做」：投递路径选择器 + `/beam` 能力探测未做 | ✅ 已落地：`frontend-core/src/components/share/DeliveryPathSelector.vue`、`BeamEntryCard.vue`、`deliveryPath.ts`（`views/home/Send.vue` 已引用） |
| 同稿：NAS 打包面「一处都没设」`PB_DISABLE_DEFAULT_ADMIN` | ✅ 六面已铺开：`fnos/fnos/cmd/main`、`openwrt/pigeonbox.init`、`qnap/qpkg/shared/pigeonbox.sh`、`synology/spk/package/compose.yml`、`ugreen/deploy/compose.yml`、`terramaster/deploy/compose.yml` |
| **本稿 §1.2 原写「`/setup` 无任何令牌保护」** | ❌ **本稿自身写错**（2026-10-30 实施时发现）：令牌门禁**早已存在**——`core/bootstrap/setup_gate.go`（2026-10-22 建）有 `PB_SETUP_TOKEN` + 头/查询参数/Cookie 三通道 + 按 IP 失败锁定 + 启动告警；前端也早有 `utils/setupToken.ts`（`#/setup?token=` 解析）+ 401 出令牌框 + i18n「请填入服务启动日志中的令牌」。本稿当时只 grep 了 `core/app/setup/`（那里没有令牌）就下了「不存在」的结论 ⇒ **探错了对象**（门禁在 `bootstrap/`，不在 `app/setup/`） |

⇒ 教训固化：**设计稿的「未做」清单只能当线索，不能当事实**；开工前先 grep 代码 + 读 git log，
且**探某个能力前先确认它住在哪个包**（同一个能力可能横跨 `app/` 与 `bootstrap/`）。

### 1.2 真欠账（本轮实测命中）

| # | 欠账 | 证据 | 影响 |
|---|---|---|---|
| 1 | **首启令牌只能手工配**（`PB_SETUP_TOKEN`），默认不启用 | `core/bootstrap/setup_gate.go` 已有完整门禁，但令牌源只有 env 一条 ⇒ 运维不配 = 暴露面全开 | 「没配」正是最危险的那一种 ⇒ 改成启动时**自动生成**一次性令牌（第一趟已落地，见 §2.3） |
| 1b | **缺令牌被计入按 IP 的失败预算**（门禁只把「猜错」当失败才对） | `setup_gate.go` 原实现：`!setupTokenMatch(...)` 一律 `RecordFailure` ⇒ **没带令牌**也算失败 | 自动令牌默认开启后，「打开页面就点初始化」是**正常流程**（前端 401 后才弹框）⇒ 照日志填令牌的那一次点击就可能把预算耗尽 ⇒ **明明有正确令牌却被 429 锁在门外**（第一趟已修） |
| 2 | 官方 CLI 只有 6 个子命令，无自检 | `server/cmd/pb/main.go:84-90` = put / import / ls / url / rm / p2p | 用户卡住时只能翻日志；9 部署面差异大，故障定位成本高（第一趟已落地 `pb doctor`） |
| 3 | **无存储迁移工具** | `core/app/storage/` 无迁移实现（`Migrat` 仅命中 admin janitor/restore 的测试） | 换后端 / 换机器只能重来，NAS 小盘迁对象存储无路 |
| 4 | **API Key 无权限 scope** | `contracts/idl/ratelimit.thrift:48` 的 `scope` 是限流桶名（global/upload/download/login），不是权限 | `pb_sk_` 是全量令牌，挂到 MCP / 集成方 / 脚本即全权 |
| 5 | 联邦只有 admin 面，匿名访客不可见 | `core/app/federation/`（invite / directory / client…）+ `core/bootstrap/deployment.go:72-74`（多副本自动降级关闭联邦） | 联邦唯一有产品意义的用法（跨站投递）没有入口 |
| 6 | 「这个面支持什么」各面各写一份 | 多副本无直传 / 联邦（架构事实）、charts `p2p.enabled`/`relay.enabled` 缺省关、NAS 有 Beam 而 docker 没有 | 10-22 稿 Q1 拍板的「没有就是没有、不给坏入口」无法统一执行（第一趟已落地能力位） |
| 7 | 指标只在 admin 副本 | `core/bootstrap/routes_custom.go:164`（主 server 不注册 `/metrics`）、`core/bootstrap/config.go:77` | **这条是有意为之**（避免公网泄露），不改；只要求自助化（`pb doctor` 已覆盖） |

## 2. 第一趟 4.2.0：零破坏的能力兑现

三项彼此独立，可分三个 PR 进同一趟车。

### 2.1 `pb doctor` —— 部署自检命令

- **问题**：9 种部署面（docker / charts / fnos / openwrt / qnap / synology / ugreen / terramaster / desktop）
  差异极大。用户在 NAS 上「装完不рабо」时，缺的不是日志，而是**一条能给出结论的命令**。
- **形态**：新增 `pb doctor` 子命令，输出**可行动结论**（每条 = 判定 + 证据 + 下一步），不是 dump。
  检查项（初版 8 条）：
  ① DB 可达与 schema 版本；② 当前存储后端与可写性（附配额占用）；
  ③ Redis 模式（未配 = 单机内存模式，**明确告知**而非报错）；
  ④ 站点公网地址是否配置（未配置 ⇒ 分享链接按请求 origin 拼，内网部署会把内网 IP 发给外部用户）；
  ⑤ **Beam `/beam` 是否挂载且令牌有效**（仅 NAS 面要求）；
  ⑥ 版本漂移（server / core 自身版本 + contracts 钉版一致性）；
  ⑦ 系统时钟漂移（影响令牌有效期与时间窗令牌）；
  ⑧ 部署模式与被降级的能力（直传 / 联邦是否因多副本被关）。
- **落点**：`server/cmd/pb`（子命令编排）+ core 侧**只读**诊断查询面。复用 `oekit/pkg/cli` 现成的
  0 / 1 / 2 退出码分级。
- **硬约束**：**不复用 HTTP 自诊断端点** —— 不给公网开新的信息面；所有检查走 admin 鉴权或本机回环。
- **破坏性**：无（纯新增）。
- **规模**：小～中（server + core 两侧，约 400 行含测试）。
- **验收**：10.10.10.3 与 fnOS 真机各跑一次，能把「健康 / 配置缺失 / 真故障」三类分开；
  退出码可直接进 CI（0 健康、1 配置缺失、2 真故障）。
- **风险**：诊断查询若复用 admin 业务接口，权限口径易漂 ⇒ 诊断查询集中在 core 一处，server 只做编排。

### 2.2 能力自描述（capability negotiation）—— 一份真相源

- **问题**：§1.2 欠账 6。今天「这个面支持什么」由各面各写一份 if 拼出来；新增一个部署面 = 再抄一份。
- **⚠️ 事实分两侧（实施时才发现的关键约束）**：能力**不是**「服务端全知道」——
  - **服务端事实**（core 算）：部署模式、联邦是否启用、存储后端与降级、Redis 模式、
    站点公网地址是否配置、首启是否要令牌；
  - **客户端事实**（前端探）：WebCrypto 是否可用（E2E 的前提是**安全上下文**，服务端无从得知）、
    Beam 入口是否挂载（`/beam` 是**平台适配器**挂在 Box 服务根上的，Box 自己不知道有没有）。
  ⇒ 前端不得因「服务端没说有」就当作「有」，也不得因「服务端没说」就当作「没有」。
- **形态（落地版）**：
  - 公开面 `GET /api/config` 增 `capabilities` 段：**只放匿名可见也无害的三项**
    （`deployment_mode` / `public_url_set` / `setup_token_required`）；
  - 管理面 `GET /admin/diagnostics`：**完整快照**（存储/Redis/DB/版本/首启/时钟）；
  - 顶层已有同义字段的（`federationEnabled` 等）**不重复下发**——同一事实两个字段必然漂移
    （`presignEnabled` 的教训：它是 `presignPolicy` 的派生布尔）。
- **落点**：core（`bootstrap/capabilities.go` + `bootstrap/diagnostics.go`）+
  frontend-core（`utils/capabilities.ts` + `stores/config.ts` + 两个消费点）。
- **破坏性**：无（**纯增量字段**）。`SystemConfig` 段在契约层刻意不锁形（`admin.thrift` 明写
  「新增配置段无需改本文件」）⇒ **不必改 contracts**，不必走「先发 contracts release → 再抬前端钉版」。
- **规模**：小（core ~150 行 + frontend-core ~100 行 + 测试）。
- **验收**：
  - 多副本拓扑（public×N + admin×1）下前端**不出现**直传 / 联邦入口，且点不动；
  - NAS 面出现 Beam 入口；docker 面不出现；
  - **负对照**：把能力位关掉，UI 必须收起入口，而不是给一个点不动的按钮；
  - **缺字段 = 未知**：老后端不下发 `capabilities` ⇒ 前端不得据此隐藏功能（宁可多给入口）。
- **风险**：能力位与运行时真实状态可能漂（如后端启动后才起 Redis）⇒ 能力位必须由**运行时真实状态**
  计算，不是配置回显。

### 2.3 首启令牌自动生成 —— 把暴露面默认收口

- **问题**（修正后的口径）：令牌门禁**早已存在**（`core/bootstrap/setup_gate.go`，2026-10-22 建），
  但令牌源只有 `PB_SETUP_TOKEN` 一条 ⇒ **运维不配 = 暴露面全开**，而「没配」恰是最危险的那一种。
- **形态（落地版）**：启动时**自动生成一次性令牌**：
  - 打印在启动日志（含可直接打开的链接 `/?token=…#/setup`，hash 路由形态）；
  - 同时落到数据目录 `.setup_token`（**0600**）——NAS 用户不必翻日志；
  - 显式 `PB_SETUP_TOKEN` 优先；`PB_SETUP_TOKEN_AUTO=0/off/false/no` 可关闭（回到旧行为 + 启动告警）；
  - 首启成功后由 `app/setup` 的 `OnInitialized` 钩子清理（进程内 + 文件）。
- **落点**：core（`bootstrap/setup_gate.go` + `app/setup/service.go` 钩子 + `bootstrap/bootstrap.go` 接线）。
- **破坏性**：**行为变更**（非契约破坏）——**未初始化实例**的首次安装流程多一步「从日志取令牌」。
  已初始化实例完全不受影响。⇒ 随 **4.2.0** 发货，并在发布说明里写清（可一键关闭）。
- **规模**：小（core ~120 行 + 测试）。
- **验收**：
  - 未初始化实例 ⇒ 启动日志里有令牌与链接，`/setup` 无令牌被拒、带令牌放行；
  - 已初始化实例 ⇒ 不生成令牌；
  - `PB_SETUP_TOKEN_AUTO=0` ⇒ 不生成（回到「不要求 + 告警」）；
  - **负对照**（本次实施发现并修掉的真缺陷）：**缺令牌不再计入按 IP 的失败预算**
    ——原实现把「没带令牌」也算失败 ⇒ 自动令牌默认开启后，管理员照日志填令牌的那一次
    点击就可能已把预算耗尽 ⇒ **明明有正确令牌却被 429 锁在门外**。现在只有「猜错」才计。
- **风险**：令牌打在日志里 ⇒ 日志可见性 = 首启权 ⇒ 文档写清，并引导「首次认领后立即轮换口令」。

## 3. 第二趟 4.3.x / 5.0

### 3.1 首启四步向导 + NAS 出厂预接线

- **形态**：向导四步 = 站点地址 → 投递策略 → 试一次 → 完成；NAS 出厂预置 Beam↔Box 的 API Key
  （今天要用户去 Box「个人设置 → API Token」手工生成再粘到 p2pcweb，摩擦是 10-22 稿 §5.3 点名的）。
- **阻塞点**：`contracts/idl/setup.thrift` 的 `BaseConfig` / `SitePreConfig` 是**强类型**，而前端消费的是
  发布版 tgz 钉版 ⇒ 改 IDL 后新增字段**本轮到不了前端**（必须先发 contracts release 再抬前端钉版）。
- **本趟真正要补的是流程**：把「契约增量 → 发 release → 抬前端钉版」固化进 hub 的一条 make 目标，
  否则每次改 setup 面都会卡在同一处。
- **破坏性**：无（配置面新增），但**依赖 contracts 增量先行** ⇒ 排期上先 contracts 后前端。
- **验收**：六个打包面都能在首启三步内拿到可用的站点地址与投递策略；Beam 预接线后，
  NAS 用户不再需要手工粘贴 API Key。

### 3.2 API Key 权限 scope

- **形态**：`pb_sk_` 增加细粒度 scope（read / write / admin / anon-share）+ 过期时间 + last-used +
  单 key 撤销；管理台可查看与吊销。
- **兼容口径**：**默认仍是全量**，显式申请才收窄；存量 key 不受影响（遵循「接口层信任调用方、
  不做隐式兜底/白名单」的既有口径）。
- **破坏性**：无（默认行为不变）；若将来把默认改成最小权限，则是破坏性变更，需升主版本。
- **验收**：带受限 scope 的 key 调用越权端点 ⇒ 403 且错误码明确；`pb_sk_` 的鉴权路径与限流桶口径不互相污染。

## 4. 第三趟 5.x–6.x

### 4.1 可迁移备份包 + 存储迁移

- **形态**：
  1. **统一备份包格式**（DB + 文件清单 + 对象 + 校验）⇒ 换机器 / 换后端 / 灾备三件事一个工具；
  2. **存量搬运** local → 远端后端（ROADMAP 早就有，至今未做）；
  3. **换库** SQLite → Postgres / MySQL（今天换库只能重建）。
- **语义要点**：**迁移后原取件码与链接不变** —— 链接稳定性是对外名片，迁移不能改用户的地址。
- **落点**：core（`app/storage` + 新 `app/backup`）+ `pb`（`pb backup` / `pb restore` 子命令）。
- **破坏性**：备份包格式本身按版本演进（`backup_format` 字段）；恢复是破坏性操作 ⇒ **恢复必须显式确认**。
- **风险**：搬运期双写 / 断点续做的口径易漂 ⇒ 搬运过程幂等 + 可中断续做，且**不占用取件次数**。

### 4.2 联邦前台化（跨站投递）

- **问题**：§1.2 欠账 5。联邦今天只在 admin 面有 4 个端点，匿名访客根本看不到它。
  10-22 稿 §2.2 的「邀到别人的柜」是联邦**唯一有产品意义**的用法
  （p2p 直传已冻结，联邦是唯一未被冻结的 p2p 面）。
- **形态**：前台寄件台增加「邀到别人的柜」路径；对方站点用 6 位取件码取件；
  未命中时按现有联邦回退链路查找（`usePickup.ts` 已有联邦回退）。
- **前置**：需先定「跨站投递的站点寻址口径」——对方站点怎么被指名（域名 / 联邦 ID / 邀请信封）。
- **破坏性**：待定；若新增公开端点则 contracts 需要增量（走 publicapi 域，注意 v0.20.3 的域=副本可见性规则）。
- **依赖**：D5 排序（建议排在备份包之后）、contracts 增量、B0 后的 `app/federation` 边界。

### 4.3 零知识 E2E 走出 secure-context

- **问题**：`crypto.subtle` 只在安全上下文可用 ⇒ NAS 典型访问 `http://192.168.x.x:12345`
  下**端到端加密根本用不了**，前端只是把开关禁用（10-24 实测）。今天它是「有但一半不可用」。
- **形态**：服务端只存 **wrapped key**（口令派生 KEK），把 E2E 的前提从「HTTPS」换成「有口令」；
  或由桌面端 / PigeonBeam 承载加解密（D4 拍板）。
- **价值**：这是隐私卖点唯一的硬证据，也是「匿名口令分享」定位的差异化落点。
- **破坏性**：是（分享数据结构与取件链路要带 wrapped key）⇒ 走主版本。
- **风险**：口令强度依赖用户 ⇒ 必须有弱口令提示与强度门槛；密钥轮换 / 撤销语义要一次定清。

### 4.4 桌面端做「一等取件端」（并入 PWA / 小程序）

- **形态**：desktop 摘掉 sidecar 后只剩瘦客户端 ⇒ 补三件事：托盘通知「你的柜子有件待取」、
  一键取件、**剪贴板只放 6 位取件码**（不放链接、不放口令）。
- **取舍**：ROADMAP 的「PWA / 移动端体验、小程序」与本项能力重叠、成本高一个数量级 ⇒
  建议**并入本项**，不单独做 PWA / 小程序（D2）。

## 5. 明确不做 / 需拍板

| # | 决策 | 建议 | 影响面 |
|---|---|---|---|
| D1 | **镜像是否同步发 Docker Hub** | **待拍板**。同步 ⇒ terramaster#99 / ugreen#100 送审解锁，但拉取体验分散；不同步 ⇒ 两平台送不了审 | 生态分发 |
| D2 | PWA / 小程序是否独立做 | **并入桌面端**（§4.4），不做独立 PWA / 小程序 | 省一整个端的重构 |
| D3 | 主题系统 / 自定义 CSS | **降级**（暗色模式已落地，边际收益低、回归面大） | ROADMAP 清理 |
| D4 | E2E 承载方 | **服务端只存 wrapped key 为主，客户端承载为辅** | 隐私卖点落地方式 |
| D5 | 第三趟内部排序 | **备份包先、联邦前台化后**（运维底座先于产品面） | 第三趟排期 |

### 明确不做

- **直传新特性**：p2p 已进入维护模式冻结（`p2p/docs/PRODUCT.md`），新投入只流向协议兼容窗口、
  打包健康度与文档包装；
- **自研代码生成**：能力自描述若涉生成，走既有 hz / IDL 生成链，仓里不留自研生成器；
- **主题系统 / 独立 PWA**：见 D2 / D3。

## 6. 生态债（不占代码，占人）

| 类别 | 项 | 状态 |
|---|---|---|
| 真机验收 | fnos#115（`/beam` 正式 fpk 生命周期）、openwrt#110（iStore 真机复验）、ugreen#100、terramaster#99 | 四条 issue 仍 open |
| 分发 | iStore 上架 PR #810（待上游合并）、fnOS 应用中心上架（唯一通道 = 官方微信群）、公开 demo 站（定时重置）、awesome-selfhosted 收录（窗口 2027-02 起，首次发布须 >4 个月） | 未完成 |

## 7. 实施状态

| 项 | 落点仓 | 配套 issue / PR | 状态 |
|---|---|---|---|
| `pb doctor` 自检命令 | server（+ core 诊断端点） | [server#69](https://github.com/pigeonbox/server/issues/69) / [PR #70](https://github.com/pigeonbox/server/pull/70) | ✅ 已实现（PR #70） |
| 能力自描述（capability negotiation） | core | [core#12](https://github.com/pigeonbox/core/issues/12) / [PR #14](https://github.com/pigeonbox/core/pull/14) | ✅ 已实现（PR #14） |
| ↳ 前端按能力位显隐 | frontend-core | [frontend-core#21](https://github.com/pigeonbox/frontend-core/issues/21) / [PR #22](https://github.com/pigeonbox/frontend-core/pull/22) | ✅ 已实现（PR #22） |
| 首启令牌自动生成 + 缺令牌不吃失败预算 | core | [core#13](https://github.com/pigeonbox/core/issues/13) / [PR #14](https://github.com/pigeonbox/core/pull/14) | ✅ 已实现（PR #14） |

> 三项均已合入各仓 main，待 **4.2.0 列车**发货后勾选 ROADMAP。
> 实施过程中**新发现并修掉两个真缺陷**（不在原规划内）：
> ① 缺令牌被计入按 IP 失败预算 ⇒ 正确令牌也会被 429 锁死（§2.3）；
> ② setup 门禁的单测锁定键污染（单测里客户端 IP 为空 ⇒ 所有用例共用一个键，
> 既有用例重置的却是另一个键 ⇒ 后续用例全 429）。

> 其余条目（§3 / §4 / §5 / §6）尚未开 issue，按排期推进时再开。
