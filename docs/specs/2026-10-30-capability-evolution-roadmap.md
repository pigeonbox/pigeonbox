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

- **⚠️ 修正（2026-10-30 实施前核对代码）**：**四步向导早就有了**——`frontend-core/src/views/setup/Index.vue`
  2026-10-22 重做时就是「管理员 → 站点地址 → 投递策略 → 完成」四步（`step` ref 0..3），
  且站点地址用「建号 → 登录 → admin config API 存 base.public_url」三步落库绕开了 IDL 强类型。
  ⇒ 本稿原写的「四步向导」是**过期规划**；真实缺口只剩**NAS 出厂预接线**。
- **形态（真实缺口）**：NAS 出厂预置 Beam↔Box 的 API Key
  （今天要用户去 Box「个人设置 → API Token」手工生成再粘到 p2pcweb，摩擦是 10-22 稿 §5.3 点名的）。
  三个 NAS 仓的 `/beam` 适配器（fnos/qnap/openwrt）目前只把用户导向 p2pcweb（带 p2pcweb 自己的 token），
  **没有**预置 Box 侧的 API Key ⇒ p2pcweb 的「文件柜」tab 仍要手填 Box URL + API Key。
- **契约增量的两段式**：若要在向导里新增字段，仍受 `contracts/idl/setup.thrift` 强类型所限
  （必须「先发 contracts release → 再抬前端钉版」）⇒ 把这条固化成 hub 的一条 make 目标（未做）。
- **破坏性**：无（配置面新增）。
- **验收**：装完 NAS 包，Beam 的「文件柜」tab 不再要求手填 API Key。

- **实施实录（2026-11-01 起，fnOS 先验证形态，其余端照搬）**：
  - **决策（用户拍板）**：预置 Key 的 scope = **全量**（admin+user+share）；
    创建方式 = **NAS 应用自动创建**（幂等、缺失才建）——应用本就持有本机 admin 口令。
  - **实现三件套**：① `prewire_beam_box`（建/复用专用 Key + 写 p2pcweb 配置，
    只发非空字段 ⇒ 不冲掉用户已配的直传注册中心）；② 包生命周期脚本接线（失败**不阻断**，
    优雅降级为「手填」旧行为）；③ **自测门禁**（跑真脚本 + 假 Box/假 p2pcweb + 变异负对照）。
  - **关键机制（三条，勿改）**：
    ① **API Key 明文只在创建时返回一次**（库里只存 hash）⇒ 「缺失才建」**不能靠查列表复用**
    ⇒ 明文落缓存 `${PB_DATA_PATH}/.beam_box_api_key`（0600）+ 每次启动**校验有效性**（自愈换库/撤销）；
    ② p2pcweb 的 `/api/config` **只更新非空字段**（留空=保持）；
    ③ p2pcweb 的令牌走 **`X-P2PCWEB` 头**（只有首页 `/` 才认 `?t=`）。
  - **顺带修掉 fnOS 的一个老问题**：p2pcweb 的配置默认落 `os.UserConfigDir()`，
    而 NAS 上它以**包用户**跑、HOME 继承自 root ⇒ 落到 `/root/.config` ⇒ **包用户写不了**
    ⇒ 用户在 UI 里填的地址/Key **静默丢失** ⇒ 改为显式 `--config-file` 落数据卷
    （qnap/openwrt 本来就传了 `--config-file` ⇒ 只有 fnOS 缺）。
  - **真机实录（fnOS 10.10.30.253，隔离实例：4.6.6 server + 随包 p2pcweb）**：
    预接线两次 ⇒ 第一次建 Key、第二次复用（Key 总数恒 1）；配置落数据卷（0600）；
    **用预置的 Key 真投一单到柜成功**（`POST /share/file/` multipart → 200 + 取件码）。
  - **⚠️ 真机抓出四个「只在真机才暴露」的问题**（自测的 mock 一开始按「想象中的契约」写
    ⇒ **假绿**）——这本身是本轮最值钱的一条：
    ① p2pcweb 令牌只认 `X-P2PCWEB` 头（`?t=` 仅首页）⇒ 403；
    ② Key 校验端点若用 `/user/api-keys`（**会话面**）⇒ 恒 401 ⇒ 把好 Key 误判成失效
    ⇒ **每次启动都重建一把**（Key 列表膨胀）⇒ 必须用**只读且认 API Key** 的 `/api/v1/user/shares`；
    ③ `POST /share/file/` 是 **multipart**（`expire_value/expire_style/require_auth/file`）⇒ JSON body 得 400；
    ④ p2pcweb 的配置路径不可用 ⇒ 必须显式 `--config-file`。
  - **落地状态（2026-11-01 销账）**：fnOS [fnos#157](https://github.com/pigeonbox/fnos/pull/157) ✅ 已合（真机验证）·
    [fnos#158](https://github.com/pigeonbox/fnos/pull/158) ✅（验收脚本装上探针注入 + 自证）·
    [fnos#159](https://github.com/pigeonbox/fnos/pull/159) ✅（等待就绪逻辑收进脚本本体）；
    qnap [qnap#143](https://github.com/pigeonbox/qnap/pull/143) ✅ + [qnap#144](https://github.com/pigeonbox/qnap/pull/144) ✅；
    openwrt [openwrt#150](https://github.com/pigeonbox/openwrt/pull/150) ✅ **已照搬**
    （admin 口令从 UCI 导出、p2pcweb 由 procd 起的等待时机均已处理）。
    ⇒ **三端全部落地**。
  - **⚠️ 三端脚本必须字节一致**（现 fnOS 与 qnap 两份一致）⇒ 改动需同步；
    **跨仓一致性门禁（比 sha256）仍待补** —— 避免「改了三处漏一处」。

### 3.1.1 NAS 端补齐 pb CLI（官方命令行客户端）—— 2026-10-31 起

- **问题**：`pb`（`pb doctor` 部署自检、`pb` 其它子命令）只随 **server 镜像 / server Release 资产**
  发布 ⇒ **NAS 端完全没有** ⇒ NAS 用户（恰恰是最需要自检与排障的场景）拿不到这个工具。
- **形态（fnOS 先验证形态，其余端照搬）**：原生包里带 `pb` 二进制
  ⇒ 与 **p2pc 完全同款**（包内放二进制 ⇒ 打包脚本按「目录里已有文件」组装）。
- **⚠️ 范围澄清（2026-10-31 实施时核对）**：真正缺 pb 的**只有三个原生包端**
  ——**fnOS / openwrt / qnap**。
  而 **ugreen / terramaster / synology 走 docker compose 跑 server 镜像**
  ⇒ 那三端**本来就有 pb**（server#73 已把 pb 放进镜像 ⇒ `/app/pb`）
  ⇒ 不需要改它们的打包。**「照搬 5 端」这个估算是错的，实际是 3 端。**
- **各端的用户入口**：
  | 端 | 包内位置 | 用户怎么用 |
  |---|---|---|
  | fnOS | `app/bin/pb-linux-{amd64,arm64}` | `/var/apps/pigeonbox/target/bin/pb-linux-amd64 doctor` |
  | openwrt | `dist/pb` → `/usr/bin/pb` | **`pb doctor`**（在 PATH 里，最好用） |
  | qnap | `qpkg/{arch}/bin/pb-linux-*` | 进应用目录执行 `./pb-linux-amd64 doctor` |
- **⚠️ 关键实现判定：从 server 同号 tag 的**源码**编译，不下载 Release 的二进制资产。**
  fnOS 与 server 的 Release 由**同号 tag 同时触发** ⇒ 下载资产会与 server 的 Release
  流水线**竞态**（资产还没构建完就下载 ⇒ 拿不到 ⇒ fpk 构建失败）
  ⇒ 改为检出**同号 tag 的源码**本地编译 ⇒ **git tag 立即可见** ⇒ 零竞态。
  pb 是**纯 HTTP 客户端**（不链接 core，只用 `oekit/pkg/cli`）⇒ 实测 199 个依赖包 /
  编译 3.5 秒 / 产物 6.5MB ⇒ 不拖慢打包。
- **版本对齐**：server 与 NAS 的 tag **同号**（列车的 `terminal.fnos.tag` = `images.server` 的号）
  ⇒ pb 版本天然与包内服务端一致 ⇒ **不需要新增 train.yaml 版本位**。
- **失败语义**：pb 编译失败 ⇒ **优雅降级**（包内无 pb，应用照常可用）⇒ 不阻断发布；
  但「有没有 pb」由**随包门禁**把守（否则它只是「另一条静默路径」）。
- **门禁**（`fnos/scripts/check-pb-in-fpk.sh`）：打包目录与 fpk 内**都**含 pb 双架构二进制，
  且**真的能执行**（架构错会 exec format error ⇒ 只判「文件存在」不够）；
  负对照：删掉 pb ⇒ 必红。
- **顺带修掉一个 doctor 缺陷**（server#88）：`pb doctor` 在**未设 API Key** 时把
  「服务可达」判成 **FAIL** ⇒ 结论「1 项故障」⇒ **用户以为应用坏了**
  （真机实录：fnOS 装好即用场景）⇒ 根因是 `doReq` 缺 Key 时**根本不发请求**
  ⇒ 公开面检查形同虚设 ⇒ 另开**匿名通路** + 端点返回未认证时判 **warn**（服务有响应=活的）。

### 3.2 API Key 权限 scope

- **问题**：`pb_sk_` 此前是**全量令牌**（挂到 MCP / CI / 集成方即全权），无法「只给寄件权限」。
- **形态**：三个能力面 `admin`（管理面）/ `user`（用户自有资源）/ `share`（寄件·取件）；
  服务端按**请求路径**判定所需能力，Key 缺该能力 ⇒ **403**（与「Key 无效」的 401 区分开）；
  **缺省 / 空 = 全量** ⇒ 与引入前完全一致（老 Key 无需重建、存量部署零影响）；
  范围外的路径（`/api/config`、`/openapi.json`、`/version`…）**不受限制**
  ——否则「只给寄件权限」的 Key 连公开面都读不到，范围就失去意义；
  非法取值**直接报错**（不静默忽略：否则用户以为签发的是受限 Key，实际拿到全量 ⇒ 安全语义被静默放宽）。
- **落点**：contracts v0.20.5（`APIKeyData.scopes` / `CreateAPIKeyReq.scopes`，optional）
  → core（`pkg/middleware` 的词汇表与路径映射 + `Scopes` 列 + `000007` 迁移 + dao 桥 + service + handler）
  → frontend-core（「API 令牌」页的范围多选与标签展示，contracts 钉版 v0.20.5）。
- **破坏性**：无（默认全量）；非法取值是新的 400。
- **验收**：受限 Key 访问 `/share/**` ⇒ 200；访问 `/admin/**`、`/user/**` ⇒ 403 且文案说明缺哪个能力；
  无范围的 Key 在三类路径上全放行（老 Key 零影响的回归锁）。

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

#### 4.1.1 存储迁移（已实现，随 4.4.0 发货）

**存储迁移**（`POST /admin/storage/migrate` + `pb storage migrate`）已落地：
把存量对象从当前后端搬到目标后端，**搬完才切换**。

| 语义 | 实现 |
|---|---|
| 取件码与分享链接**不变** | DB 记录一个字节都不动，只换对象所在后端 |
| **全部复制成功才切换** | 任一对象失败 ⇒ 不切换 ⇒ 源后端继续在用（线上零影响） |
| **可中断可续** | 目标已存在的对象跳过 ⇒ 大实例断了重跑即可 |
| 不消耗取件次数 | 后端级操作，不走取件链路 |

- 落点：`core/app/storage/migrate.go`（迁移服务；存储域**不直接碰 DB** ⇒ 待迁清单由
  admin 域经 `ObjectLister` 注入、读源对象靠运行时的 `ObjectReader` 类型断言接入）·
  `core/app/admin/files.go`（对象清单来源，含软删 ⇒ 软删分享可恢复、对象要一起搬）·
  `gen/handler/storage/storage_service.go`（管理面端点；`dry_run` 只算计划不搬）。
- 契约：contracts **v0.20.6**（`MigrateStorageReq` / `MigrateStorageData` / `MigrateStorageResp`）。
- CLI：`pb storage migrate --to s3 [--path <目录>] [--dry-run]`（需 admin API Key）。
- 测试：7 条端到端（用**真实存储单例**读写对象）：搬完才切换 + 对象真落到目标目录 +
  切换已持久化；源对象不被删（迁移是复制不是移动）；**有对象失败 ⇒ 不切换、不持久化**；
  目标已存在 ⇒ 跳过；dry-run 不复制不切换；同源拒绝 / 不支持类型拒绝。
- **仍未做**：换库（SQLite → PG/MySQL）——备份包只支持 SQLite 一致快照，PG/MySQL 明确报错
  并指向 `pg_dump`/`mysqldump`；换库要另做「导出 → 目标库导入 → 校验」流程。

#### 4.1.2 统一备份包（已实现，随 4.6.0 发货）

**备份包**（`pigeonbox backup export` / `pigeonbox restore`）：把「DB 快照 + 文件清单 +
存储对象 + 校验」打成一个 tar.gz ⇒ 换机器 / 灾备一个工具。

| 语义 | 实现 |
|---|---|
| **取件码与链接不变** | DB 快照原样带走（`file_codes` / `file_code_files` / `system_configs` 全在内）⇒ 恢复后对外名片照旧可用；`files.json` 是独立副本，便于事后逐条核对 |
| **恢复是破坏性操作** | 必须**显式确认**（`--yes`）+ **停服**（DB 被替换时运行中的实例会读到半旧半新的数据）⇒ 恢复前还会探端口，服务在跑就拒绝 |
| **不占用取件次数** | 运维动作，不是取件动作 |

- 格式 v1：`manifest.json`（`backup_format` + 组件版本 + **逐对象 sha256**）·
  `db/backup.db`（SQLite `VACUUM INTO` 一致快照）· `files.json`（分享/取件码清单）·
  `objects/<相对路径>`（与 `file_codes.file_path` 同形）。
- **安全面**：解包逐条目名过**路径穿越**校验；逐对象 sha256 不符 ⇒ **整体中止、一个字节都不落盘**；
  不认识的 `backup_format` ⇒ 直接拒绝；DB 走「写临时 + rename」原子替换并清 WAL/SHM 边车。
- **落地形态**：**server 二进制的离线子命令**（`pigeonbox backup export` / `pigeonbox restore`）
  —— 不做 HTTP 端点（恢复会砸自己的脚），也不进 `pb`（`pb` 是纯 HTTP 客户端，刻意不链接
  core；链接 core 会让轻量 CLI 膨胀数十 MB）。
- 落点：core `app/backup`（新域，只依赖窄接口 ⇒ 与业务域零耦合）+ `bootstrap` 装配
  + server `cmd/server`（离线子命令）。

#### 4.1.3 换库（SQLite → Postgres/MySQL）—— **已实现**（随 4.6.2 发货）

**背景**：备份包（§4.1.2）只支持 SQLite 一致快照（`VACUUM INTO` 是 SQLite 专有），
PG/MySQL 明确报错并指向 `pg_dump`/`mysqldump`。⇒ 「换库」今天没有产品化路径：
想从 SQLite 换到 PG，只能自己 dump + 手工导 + 手工对齐自增。

**2026-10-31 实测的前置核查**（结论：可行，但**不能走物理拷贝路线**）：

| 核查项 | 结论 |
|---|---|
| 驱动层 | core 早已带 `gorm.io/driver/postgres` + `gorm.io/driver/mysql` ⇒ **驱动不缺** |
| 模型层方言安全 | 14 个模型只有 `type:text`（7 处）与 `size:255`；`type:text` 字段**均未带索引** ⇒ MySQL 建表无阻塞 |
| `file_codes.text` 列宽 | 该列存的是**原始文件名**（不是文件内容）⇒ MySQL `TEXT`(64KB) 绰绰有余 ⇒ 无截断风险 |
| `file_path` 列宽 | 形态为 `uploads/YYYY/MM/DD/<uuid>` ⇒ 远小于 255 ⇒ `varchar(255)` 无溢出风险 |
| **版本化迁移 SQL** | ⚠️ `migrations/*.sql` 是**纯 SQLite 方言**（反引号 + `integer PRIMARY KEY AUTOINCREMENT` + `numeric DEFAULT false`）⇒ 在 PG/MySQL 上**直接炸** ⇒ 不能拿它当换库的目标 schema 来源 |
| **自增序列对齐** | ⚠️ PG 的 `bigserial` 序列**不会**因为显式插入 ID 而前进 ⇒ 导完数据后不修序列 ⇒ **下一次插入立刻撞主键** ⇒ 这是换库最经典的静默地雷 |
| 单一模型清单 | ⚠️ `repo/db/model` **没有统一模型注册表**（14 个模型散在文件里，`autoMigrate()` 里手写清单）⇒ 换库要逐表搬，必须先有一份**单一真相源**的模型清单 |

**方案判定：走「逻辑导出/导入」，不走「物理文件拷贝」**

- ❌ 物理拷贝：SQLite 的 `.db` 文件**根本无法**被 PG/MySQL 读取 ⇒ 物理路线只可能停在 SQLite→SQLite。
- ✅ 逻辑导出：把每张表导成**行数据**（JSON），目标库按**目标方言**建表后逐行插入
  ⇒ 与源库方言解耦 ⇒ SQLite→PG/MySQL、PG→MySQL 全部同一条路径。

**落点**：

- `core/repo/db/model` —— **模型注册表**（单一真相源）：新增 `registry.go`，
  导出「全部模型 + 表名 + 主键 + 自增语义」清单；`autoMigrate()` 与换库共用同一份
  ⇒ **顺带修掉「新增模型漏登记」这个历史坑**（v0.11.1 漏登 FilePreview ⇒ 预览域整体 404）。
- `core/app/dbmigrate`（新域）—— 逻辑导出（SQLite/PG/MySQL → JSON 行集）+ 逻辑导入
  （JSON 行集 → 目标库）+ **序列对齐**（PG `setval` / MySQL `AUTO_INCREMENT` / SQLite 天然对齐）。
- `server/cmd/server` —— 离线子命令 `pigeonbox db export` / `pigeonbox db import`。

**三条语义（缺一条就危险）**：

1. **取件码与分享链接不变**：行数据原样搬运（含 `file_codes.id` 与 `code`）⇒ 对外名片照旧。
2. **导入是破坏性操作**：会写目标库 ⇒ 必须**显式确认** + 目标库为空（或 `--allow-nonempty`）。
3. **导入后自增必须对齐**：显式插入 ID 后，PG/MySQL 的自增计数器仍停在旧值 ⇒
   **必须显式重置到 `max(id)+1`**，否则下一次新建分享立刻撞主键 ⇒ 这条要有专门的守卫用例。

**风险与边界**：

- 布尔/时间列在 SQLite 是 `numeric`/`datetime`，在 PG 是 `boolean`/`timestamptz`
  ⇒ 逻辑导出必须**按目标列类型**归一化（不能把 SQLite 的 `0/1` 直接塞进 PG 的 `boolean`）。
- 软删（`deleted_at`）必须**原样带走** ⇒ 换库不是「只搬活数据」。
- `schema_migrations` 版本记录：跨方言后**不通用**（SQLite 的版本号与 PG 的迁移集无对应关系）
  ⇒ 目标库用 **AutoMigrate** 建表（方言无关），**不搬** `schema_migrations`。
- 真机验收需要 **PG/MySQL 容器** ⇒ core CI 加 service 容器（`postgres:16` / `mysql:8`），
  冒烟里跑「导出 → 导入 → 行数与关键字段一致 → **新建一条不撞主键**」。

**落点与形态（已实现）**：

| 项 | 落点 | 说明 |
|---|---|---|
| 模型注册表 | core `repo/db/model/registry.go` | **单一真相源**（12 张表 + 主键 + 自增语义）；`autoMigrate()` 与换库共用同一份 ⇒ 建表范围与搬运范围**必然一致** |
| 逻辑导出 / 导入 | core `app/dbmigrate`（新域） | 导出＝按模型反射取列（模型改了自动跟着改）；导入＝目标方言建表 + 显式列名 INSERT |
| 自增序列对齐 | core `app/dbmigrate/sequence.go` | PG `setval` / MySQL `ALTER TABLE AUTO_INCREMENT` / SQLite 天然对齐（跳过） |
| 离线子命令 | server `cmd/server/dbmigrate.go` | `pigeonbox db export` / `pigeonbox db import --target-driver <d> --target-dsn <dsn> --yes` |
| 机械守卫 | core `repo/db/model/registry_guard_test.go` | **AST 扫描**模型文件 ↔ 注册表逐一对账 ⇒ 新增模型漏登记 ⇒ **提交即红** |

**验收（真 PG + 真 MySQL 容器，core CI 流水线内）**：

- SQLite→PG / SQLite→MySQL：行数逐表一致、boolean 真落、**NULL 保持 NULL**（不是空串）、
  UTF-8 中文逐字一致；
- **序列对齐**：导入后新建行拿到 `max(id)+1`（PG/MySQL 都验）；
- **负对照**：把 PG 序列手动推回 1 ⇒ 新建行**确实**撞主键（duplicate key）
  ⇒ 证明上面那条不是「本来就绿」。

**实施中踩到的三个真坑（都写进了代码注释）**：

1. **NULL 与空串必须可区分**：第一版用 `[]string` + 空串表示 NULL ⇒ 导入时
   PG 的 `integer` 列收到 `""` 直接报错 ⇒ 改成 `*string`（JSON `null` vs `"…"`）。
2. **导入要显式写 ID**（主键与外键才不变）⇒ 目标库的**自增计数器不会前进**
   ⇒ 必须显式重置 ⇒ 这是换库最经典的静默地雷（SQLite 测不出来 ⇒ 必须真库验）。
3. **CI 里独立 job 连续四次在「Set up job」阶段红**（报错「Unable to resolve action」，
   而同一 run 里 `test` job 解析正常）⇒ 差异在「新 job 抢在 action 解析接口抖动时首个启动」
   ⇒ 处置：**并进 `test` job**，不新增 job（新增 job = 新增一条 action 解析路径）。

**顺带修掉的历史坑**：`repo/db/model` 此前**没有统一模型清单**（建表范围靠 `autoMigrate()`
里一份手写清单）⇒ 漂移后果是**静默**的（v0.11.1 漏登 FilePreview ⇒ 预览域整体 404）。
换库要**逐表**搬 ⇒ 漏一张表 = 那张表的数据在换库后**静默丢失**
⇒ 风险从「功能缺失」升级为「数据丢失」⇒ 清单收敛到一处 + AST 守卫强制一致。

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
| D1 | **镜像是否同步发 Docker Hub** | ✅ **已拍板（2026-10-31）：同步发**。TOS 7 应用商店与绿联 UPK 应用中心**只收 Docker Hub 镜像**（拒收 ghcr.io / quay.io / 私有仓库）⇒ 不同步 ⇒ 两个平台**都送不了审**，不是「可选项」。落地：`pigeonbox/server` 仓 release 流水线**一次构建、多 tag 推送**（ghcr + Docker Hub，tag 合并逻辑抽成 `scripts/image_tags.py` 单一真相源）。⚠️ **凭据缺失当「跳过」不当「失败」**：缺 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` 时只跳 Docker Hub 那一路（ghcr + Release 照常出）并打 `::warning`「Docker Hub 未发布」⇒ 不让外部资源卡死整条发版链 | 生态分发 |
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

### 第二趟（4.3.0）

| 项 | 落点仓 | PR | 状态 |
|---|---|---|---|
| API Key 权限 scope | contracts | [PR #9](https://github.com/pigeonbox/contracts/pull/9)（已发 **v0.20.5**） | ✅ 已发货 |
| ↳ 服务端强制（路径→范围、403、迁移 000007） | core | [PR #17](https://github.com/pigeonbox/core/pull/17)（已发 **v0.32.31**）· [PR #18](https://github.com/pigeonbox/core/pull/18)（已发 **v0.32.32**） | ✅ 已发货（4.3.0 + 4.3.1 hotfix） |
| ↳ 前端范围选择与展示 | frontend-core | [PR #26](https://github.com/pigeonbox/frontend-core/pull/26)（已发 **v0.11.39**） | ✅ 已发货 |
| NAS 出厂预接线（Beam↔Box API Key） | fnos / qnap / openwrt | [fnos#157](https://github.com/pigeonbox/fnos/pull/157) ✅ 已合并（真机验证）· [fnos#158](https://github.com/pigeonbox/fnos/pull/158) ✅ · [fnos#159](https://github.com/pigeonbox/fnos/pull/159) ✅ · [qnap#143](https://github.com/pigeonbox/qnap/pull/143) ✅ · [qnap#144](https://github.com/pigeonbox/qnap/pull/144) ✅ · [openwrt#150](https://github.com/pigeonbox/openwrt/pull/150) ✅ | ✅ **三端全部已合并**（2026-11-01 销账） |

### 第三趟（4.4.0）

| 项 | 落点仓 | PR / 版本 | 状态 |
|---|---|---|---|
| 存储迁移（换存储后端 / 换机器搬对象） | core | `core/app/storage/migrate.go`（已发 **v0.32.33**）· 契约 [contracts PR #10](https://github.com/pigeonbox/contracts/pull/10)（已发 **v0.20.6**）· CLI [server PR #76](https://github.com/pigeonbox/server/pull/76) | ✅ 已发货（4.4.0） |
| ↳ 前端类型检查工具链钉版 + 跨仓对账门禁 | hub（门禁）+ frontend-core / fnos / openwrt / qnap（钉版） | [hub PR #195](https://github.com/pigeonbox/pigeonbox/pull/195) · [frontend-core#29](https://github.com/pigeonbox/frontend-core/pull/29) · [fnos#133](https://github.com/pigeonbox/fnos/pull/133) · [openwrt#128](https://github.com/pigeonbox/openwrt/pull/128) · [qnap#126](https://github.com/pigeonbox/qnap/pull/126) | ✅ 已落地（4.4.0 列车期间） |
| 可迁移备份包（导出 / 导入） | contracts / core | — | ⏳ 未开工（§4.1） |
| 联邦前台化 | frontend-core + core | — | ⏳ 未开工（§4.2） |

### 第四趟（4.5.0）

| 项 | 落点仓 | PR / 版本 | 状态 |
|---|---|---|---|
| ↳ **库侧适配 vue-tsc 3.3.14+**（治本：不再依赖「钉版止血」） | frontend-core | [frontend-core#30](https://github.com/pigeonbox/frontend-core/pull/30)（`Config.vue` 三个表单绑定 `reactive()`→`ref()`，模板侧一字不改）· [frontend-core#32](https://github.com/pigeonbox/frontend-core/pull/32) / [#33](https://github.com/pigeonbox/frontend-core/pull/33)（版本声明三处同抬 + contracts 钉版） | ✅ 已发货（**v0.11.42**） |
| ↳ **CI 前瞻探针**：用**最新 vue-tsc** 跑库自己的类型检查 | frontend-core | 同上 PR 的 CI job「类型检查（最新 vue-tsc，前瞻探针）」 | ✅ 已落地 |
| ↳ **API Key 列表回传 `revoked_at`**（撤销时间早已落库但不回传 ⇒ 审计断在回传面） | contracts / core / frontend-core | [contracts#11](https://github.com/pigeonbox/contracts/pull/11)+[#12](https://github.com/pigeonbox/contracts/pull/12)（**v0.20.7**）· [core#20](https://github.com/pigeonbox/core/pull/20)+[#21](https://github.com/pigeonbox/core/pull/21)（**v0.32.35**）· [frontend-core#31](https://github.com/pigeonbox/frontend-core/pull/31)（令牌页显示吊销时间） | ✅ 已发货（**v0.11.42**） |

> **4.5.0 的主线 = 把 4.4.0 期间的两个「止损/欠账」补成「治本」**：
> ① vue-tsc 3.3.14 的 `.value` 误判：4.4.0 用「四仓钉 3.3.13 + 跨仓对账门禁」止血，
>    4.5.0 把库侧改成 `ref()` ⇒ **实测 `.value` 报错 20→0，且 3.3.14 / 3.3.13 / 3.2.9 /
>    3.2.5 全部 0 报错** ⇒ 与工具链版本无关 ⇒ 再加一条「最新 vue-tsc」CI 探针，
>    **上游工具链一出回归，库这边先红**（钉版与探针并存：钉版管确定性，探针管前瞻）。
> ② `revoked_at`：DB 一直有值、API 不回传 ⇒ 用户看不到「这把 Key 什么时候被撤销的」⇒
>    contracts 补字段 + core 映射（带单测）+ 前端把吊销时间做成**状态列第二行小字**
>    （不做成 tooltip：审计信息不该靠 hover 才看得到）。
>
> **4.5.0 列车期间抓到的第二个真问题（版本元数据滞后）**：contracts 的 `package.json`
> 版本声明**滞后两个版本**（v0.20.5 / v0.20.6 直接在功能提交上打的 tag）⇒ 库线守卫
> 「仓内版本声明 == 目标版本」直接把车拦下 ⇒ 已抬到 0.20.7（frontend-core 同理抬到
> 0.11.41 → 0.11.42，两次都是「版本声明三处同抬」）。另：`frontend-core v0.11.41`
> 的 contracts 钉版仍是 v0.20.6 ⇒ 消费方装出**两份** contracts ⇒ 契约单副本守卫红 ⇒
> 库线补发 **v0.11.42**（contracts 钉 v0.20.7）后消解（守卫的报错本身就写明了修法）。

> **4.4.0 列车期间抓到的真事故（不是业务代码错，是工具链漂移）**：
> vue-tsc **3.3.14** 对 `<script setup>` 里 `reactive()` 绑定的 v-model 嵌套成员
> **误生成 `.value` 访问** ⇒ TS2339「Property 'value' does not exist」×20 ⇒ 三个消费方
> （对 frontend-core **源码**做 typecheck）全红 ⇒ 列车终验被挡。
> 库侧同版本同样红 —— 只是库自己的锁文件没动 ⇒ **库 CI 假绿、消费方显红**
> ⇒ 「库绿了」从来不能代表「消费方绿」。
> 逐版本扫（同一份源码 + 同一份 tsconfig）：3.3.14→20 条；3.3.13/3.3.12/3.3.11/3.2.9→0 条。
> ⇒ 四仓统一钉 **3.3.13 精确版本**（区间 = 锁文件随时可能漂进上游回归版）+ 跨仓对账门禁
> `scripts/check-toolchain-pins.sh`（含 `--selfcheck` 注入三类故障）。
> **治本项（下一趟）**：`Config.vue` 的 `exForm`/`rlForm` 由 `reactive()` 改 `ref()`
> ⇒ 3.3.14 的误判消失（实测 `.value` 报错 20→0）⇒ 不再依赖钉版这条止血线。

> **4.3.0 / 4.3.1 已发货**：hub 快照 `v4.3.1`（Latest）· core `v0.32.32` · frontend-core `v0.11.39` ·
> contracts `v0.20.5` · chart `2.0.99`。
> 真机（10.10.10.3）验收：冒烟 **PASS=88 FAIL=0**（含 5 条 scope 断言）；
> 容器内 `pb doctor` 8 项全 OK、退出码 0、版本号显示 `v4.3.1`（构建版本）。
>
> **实施中抓到的关键事实（4.3.1 hotfix 的由来）**：API Key **真正能到的面只有三类**
> （其余管理面是 JWT-only ⇒ Key 进不去、恒 401）：
> `UserOrAPIKey`（/api/v1/notifies/**、/api/v1/user/shares/**）·
> `AdminOrAdminKey`（/admin/p2p/**）·
> `OptionalIdentity`（/share/**、/chunk/**、/api/v1/presign/**）。
> ⇒ **测 scope 必须挑这些面**（拿 /admin/config 测是**测不到 scope 的**），
> 而原映射表漏了 `/api/v1/notifies/**` ⇒ 4.3.0 的洞 ⇒ 4.3.1 hotfix 补上。

> **✅ 4.2.0 已发货**（hub 快照 `v4.2.0` / core `v0.32.30` / frontend-core `v0.11.38` / chart `2.0.97`）；
> 真机（10.10.10.3）验收：冒烟 PASS=83 FAIL=0；`pb doctor` 8 项全 OK、退出码 0；
> 吊销 Key 后正确降级为「深度检查未执行 + 退出码 1」（没检查 ≠ 检查通过）。
> 下一趟车的两个收尾项：**`pb` 二进制随镜像分发**（server#73）·
> **诊断报告的版本改用构建版本**（core#16：原读 yaml 的 app.version ⇒ 真机把 4.2.0 报成 1.0.0）。
> 实施过程中**新发现并修掉两个真缺陷**（不在原规划内）：
> ① 缺令牌被计入按 IP 失败预算 ⇒ 正确令牌也会被 429 锁死（§2.3）；
> ② setup 门禁的单测锁定键污染（单测里客户端 IP 为空 ⇒ 所有用例共用一个键，
> 既有用例重置的却是另一个键 ⇒ 后续用例全 429）。

> **✅ 4.4.0 已发货**（hub 快照 `v4.4.0` 已标 Latest · core `v0.32.33` · contracts `v0.20.6` ·
> frontend-core `v0.11.40` · chart `2.0.100`）；
> 真机（10.10.10.3）验收：**冒烟 PASS=92 FAIL=0 SKIP=1**（SKIP 的是「真迁移」——
> 它会改目标实例的存储后端 ⇒ 只在隔离实例上跑，隔离实例上 **PASS=94 FAIL=0 SKIP=0**，
> 含真迁移 `copied=9 failed=0 switched=true`）；容器内 `pb doctor` **8 项全 OK**
> （服务版本显示 `v4.4.0`）；**CI 权威终验 green**（train-verify run 41047289263）。
>
> **验收期间抓到的三个真问题**（均已修或已记入待办）：
> ① **vue-tsc 3.3.14 回归**（工具链漂移）⇒ 三个消费方 typecheck 全红、列车终验被挡 ⇒
>    四仓统一钉 3.3.13 + 跨仓对账门禁（详见上面的事故段）；
> ② **冒烟 S12 的「猜路径」判据**会写进**生产实例**的同名目录（真机实测残留
>    `/data/import/local-nas.txt`，已清理）⇒ 改成「以服务端是否看得见为准」+ 写错必清理；
> ③ **API Key 列表不回传 `revoked_at`**（DB 有值、API 无字段）⇒ 用户看不到撤销时间
>    ⇒ 已记入 ROADMAP 待办（下一趟车改 contracts + core + 前端）。

### 第五趟（4.6.x）

| 项 | 落点仓 | PR / 版本 | 状态 |
|---|---|---|---|
| **换库**（SQLite → PG/MySQL 的逻辑搬运 + 自增序列对齐） | core | [core#26](https://github.com/pigeonbox/core/pull/26)（`app/dbmigrate` + `repo/db/model/registry.go` + AST 守卫 + CI 真库验收；已发 **v0.32.40**） | ✅ 已实现 |
| ↳ 离线子命令 | server | [server#85](https://github.com/pigeonbox/server/pull/85)（`pigeonbox db export \| import`；core 钉 **v0.32.40**） | ✅ 已实现 |
| ↳ 冒烟断言 S26（换库端到端） | hub | 待 4.6.2 镜像就绪后合 | ⏳ 待合 |
| ↳ **修 S25 恒红**（容器 /tmp 的 root 属主残片 ⇒ app 无权覆盖 ⇒ 导出必失败） | hub | [hub#209](https://github.com/pigeonbox/pigeonbox/pull/209)（删重复块）· [hub#210](https://github.com/pigeonbox/pigeonbox/pull/210)（唯一文件名 + 真实 stderr + `-u 0` 清理兜底） | ✅ 已修 |
| 统一备份包（导出 / 恢复） | core / server | [core#22](https://github.com/pigeonbox/core/pull/22) · [server#83](https://github.com/pigeonbox/server/pull/83) | ✅ 已发货（4.6.0） |
| ↳ 存量缺失对象跳过并记账 | core | [core#25](https://github.com/pigeonbox/core/pull/25)（**v0.32.39**） | ✅ 已发货（4.6.1） |
| **NAS 端随包 pb CLI**（三个原生包端） | fnos / openwrt / qnap | [fnos#145](https://github.com/pigeonbox/fnos/pull/145) · [openwrt#141](https://github.com/pigeonbox/openwrt/pull/141) · [qnap#138](https://github.com/pigeonbox/qnap/pull/138) | ✅ 已发货（4.6.6） |
| ↳ **门禁语义分层**（CI 不阻断 / 发布流水线硬断言） | fnos / openwrt / qnap | [fnos#153](https://github.com/pigeonbox/fnos/pull/153) · [fnos#156](https://github.com/pigeonbox/fnos/pull/156)（EXIT trap 哨兵）· [openwrt#148](https://github.com/pigeonbox/openwrt/pull/148) · [qnap#142](https://github.com/pigeonbox/qnap/pull/142) | ✅ 已落地 |
| ↳ **tag 顺序保证**（server → 终端） | hub | [hub#232](https://github.com/pigeonbox/pigeonbox/pull/232)（server 之后也等 tag 可见） | ✅ 已落地 |
| ↳ 检出退避重试（兜底） | fnos / openwrt / qnap | [fnos#151](https://github.com/pigeonbox/fnos/pull/151) · [openwrt#146](https://github.com/pigeonbox/openwrt/pull/146) · [qnap#140](https://github.com/pigeonbox/qnap/pull/140) | ✅ 已落地 |
| ↳ `pb doctor` 缺陷：**缺 API Key 时把「服务可达」判成故障** | server | [server#88](https://github.com/pigeonbox/server/pull/88)（真机实录：结论「1 项故障」⇒ 用户以为应用坏了） | ✅ 已修 |

> **✅ 4.6.6 的 NAS 端 pb 已发布并逐包验证**（不是「门禁绿就算」）：
>
> | 端 | 包内位置 | 用户入口 | 解包验证 |
> |---|---|---|---|
> | fnOS | `app/bin/pb-linux-{amd64,arm64}` | `/var/apps/pigeonbox/target/bin/pb-linux-amd64 doctor` | ✅ fpk → `app.tgz` → `bin/` |
> | qnap | `qpkg/{arch}/bin/pb-linux-*`（且进 `bin/SHA256SUMS`） | 进应用目录 `./pb-linux-amd64 doctor` | ✅ qpkg 自解压段 → `data.tar.gz` → `bin/` |
> | openwrt | `usr/bin/pb`（**在 PATH 里**） | **`pb doctor`** | ✅ ipk → `data.tar.gz` → `usr/bin/` |
>
> **这一趟踩到并修掉的是「流水线死锁」**（比功能缺陷更隐蔽）：
>
> ```
> bump PR 的 CI 在 tag 阶段**之前**跑
>   ⇒ 此时 server 的同号 tag 还不存在 ⇒ 端上编 pb 必然失败
>   ⇒ 门禁硬红 ⇒ bump PR 合不进去
>   ⇒ 列车走不到 tag 阶段 ⇒ server tag 永远不存在 ⇒ 循环
> ```
>
> ⇒ 表现为「CI 坏了」，实际是**自己锁自己**。修法三件套：
> ① **门禁按阶段分层**（早阶段只告警、晚阶段硬断言）——
>    ⚠️ 不能只删早阶段断言，否则**没有任何地方**保证发布物含该能力
>    ⇒ 能力**静默丢失**（包照发、用户照用、只是没那个命令）；
> ② **依赖顺序落编排器**（tag 阶段「先等 server tag 可见，再打终端 tag」）；
> ③ 端上检出失败**退避重试**兜底。
>
> 另外记一个隐蔽点：仓里的脚本带 **EXIT trap 成功哨兵** ⇒
> 任何**有意放行**的分支都必须设哨兵变量，否则 trap 会把 `exit 0` 覆盖成 `exit 1`
> （症状：告警都打出来了、CI 还是红）。

> **4.6.x 的主线 = 把「换库」从「没有路径」补成「一条命令」**：
> 此前「SQLite 换 PG/MySQL」只有 `pg_dump`/`mysqldump` 这条人工路径 ⇒ 而
> **PG/MySQL 根本读不了 SQLite 的文件** ⇒ 物理快照路线（备份包）**只覆盖 SQLite→SQLite**。
> ⇒ 换库必须走**逻辑**路线：导出行数据（与方言无关）→ 目标库按**目标方言**建表 → 逐行插入
> → **显式对齐自增序列**。
>
> **这一趟最值得记的不是功能，是三个「静默」陷阱**：
> ① **NULL 与空串**（第一版把 NULL 变空串 ⇒ PG 的 integer 列直接报错）；
> ② **自增计数器不前进**（导入写显式 ID ⇒ PG 的 bigserial 序列不动 ⇒
>    「迁移完第一次新建分享」就撞主键 ⇒ **SQLite 测不出来**，必须真库验 +
>    带**负对照**否则无法证明那条断言有牙齿）；
> ③ **CI 里新增 job 会撞上 action 解析抖动**（独立 job 连续四次在 Set up job 阶段红
>    ⇒ 处置是并进既有 job，不新增 job）。
>
> 另外，真机冒烟在 4.6.1 上抓到 **S25 恒红**（容器 /tmp 里有 root 属主的 896MB 残片
> ⇒ 容器 `USER=app` 无权覆盖 ⇒ `os.Create` EACCES ⇒ 导出必失败且断言只说「退出码非 0」）
> ⇒ 修法三件套：文件名唯一 + 失败时带**真实 stderr** + 清理用 `-u 0` 兜底。

> **4.6.1 已发货**：hub 快照 `v4.6.1`（Latest）· server/frontend `v4.6.1` · core `v0.32.39` ·
> contracts `v0.20.7` · frontend-core `v0.11.44`。
> 真机（10.10.10.3）验收：升 **4.6.1**（镜像按 amd64 digest 拉取后 4MB 分块经堡垒机传输
> ⇒ sha256 逐字校验 ⇒ `docker load`）；冒烟 **PASS=97 FAIL=0 SKIP=1**
> （SKIP 的是 S24e「真迁移」——它会改目标实例的存储后端 ⇒ 只在隔离实例上跑）。

> **✅ 4.6.3 已发货**（hub 快照 `v4.6.3` · core **v0.32.41** · server `v4.6.3`）：
> 真机（10.10.10.3）升 4.6.3（镜像按 amd64 digest 拉取后 4MB 分块经堡垒机传输 ⇒
> sha256 逐字校验 ⇒ `docker load`）⇒ 冒烟 **PASS=102 FAIL=0 SKIP=1**
> （含 S25 备份包 5 条 + **S26 换库 5 条**：导出 / 导入 / **分享记录数一致（463 条）** /
> **取件码逐字一致（dDAKdyER）** / **新建行未撞主键（max=809 → new=810）**）；
> `pb doctor` **9 项全 OK**（退出码 0，版本 v4.6.3）。
>
> **真机换库端到端演练（生产库 → 真 PG）全绿**：12 张表行数**逐表一致**
> （users 5 / file_codes 437 / file_code_files 165 / upload_chunks 612 / transfer_logs 1222 /
> notifies 310 / pickup_charges 155 …）；取件码**逐字一致**；PG 上新建行拿到 `max(id)+1`
> ⇒ **序列对齐生效**；**负对照**（把序列设到一个确实存在的 id）⇒ 确实撞
> `duplicate key value violates unique constraint "file_codes_pkey"`
> ⇒ 证明上面那条不是「本来就绿」。
>
> **4.6.3 顺带修掉的两个「4.6.2 不可用」的原因**：
> ① server 的 `db` 子命令**没剥离子命令名** ⇒ `db export` 直接报「未知参数: export」
>    ⇒ **整个换库子命令不可用**（且单测按「不带子命令名」的形态调 ⇒ 假绿）；
> ② core 的 `upload_id` 列宽（见下）。
>
> **4.6.3 顺带补上的门禁覆盖缺口**：CI 的冒烟**用当前 main 源码编 server 起本地进程实例**
> ⇒ **根本没有容器** ⇒ S25/S26 一律 SKIP ⇒ 「备份包 / 换库」两个域在 CI 里
> **覆盖为零**（门禁绿是**假绿**：它绿是因为「没跑」）⇒ 补「本地二进制模式」
> ⇒ CI 从此真跑到 S25/S26（并顺带抓出本地模式的三个实现缺陷：
> 残留的 `docker exec` 段、`cp -f X X` 同路径、以及**误删刚导出的 dump**）。

> **⚠️ 4.6.2 的换库在真机数据上「导不进去」——4.6.3 已补（诚实记录）**：
> 4.6.2 的 server 镜像是用 **core v0.32.40** 构建的，而 v0.32.40 的模型把
> `upload_id` 声明成 `size:36`（实际值域是 **64**：由 file_hash 派生）
> ⇒ **SQLite 忽略 varchar 长度** ⇒ 生产上一直正常
> ⇒ 但**换库到 PG/MySQL 会直接失败**（`value too long for type character varying(36)`）。
>
> ⇒ 这个问题是**用真机生产库做换库演练**才抓到的（CI 的自造数据宽度恰好够 ⇒ **假绿**）。
> ⇒ 修法在 **core v0.32.41**（[core#27](https://github.com/pigeonbox/core/pull/27)）：
> ① `upload_id` 的 `size:36` → `size:64`；② **导入侧列宽校验**（超长时当场报人话：
> 哪张表/哪列/声明多宽/实际多长 ⇒ 而不是让目标库抛晦涩的驱动错误；
> 且校验**先于任何插入** ⇒ 失败时目标库零写入）；③ **负对照加固**
> （原负对照硬编码 `setval(seq,1,false)`，而真机那份库的 `file_codes` id 范围是
> **239~783** ⇒ **id=1 恰好是空洞** ⇒ 负对照**没撞主键** ⇒ 证明不了任何事
> ⇒ 改成**动态取一个确实存在的 id** + `is_called=false`）。
>
> ⇒ 教训两条：**① 自造数据的测试会给出假绿**（宽度/边界这类问题只有真实数据暴露）；
> **② 负对照本身也要设计得对**（前提不成立时，它证明不了任何事，还会让人误以为已验证）。

> **✅ 4.6.6 已发货**（hub 快照 `v4.6.6`（Latest）· core v0.32.41 · contracts v0.20.7 ·
> frontend-core v0.11.44 · chart 2.0.110）：本趟主体是 **NAS 三端随包 pb CLI**（§3.1.1）——
> fnos / openwrt / qnap 三个**原生包端**各带一份 `pb`
> ⇒ **逐包解包确认**（fnOS fpk → `app.tgz` → `bin/pb-linux-{amd64,arm64}`；
> qnap qpkg 自解压段 → `data.tar.gz` → `bin/pb-linux-amd64`（并进 `bin/SHA256SUMS`）；
> openwrt ipk → `data.tar.gz` → **`usr/bin/pb`**（在 PATH 里））。
> 门禁按**阶段分层**（[fnos#153](https://github.com/pigeonbox/fnos/pull/153) ·
> [openwrt#148](https://github.com/pigeonbox/openwrt/pull/148) ·
> [qnap#142](https://github.com/pigeonbox/qnap/pull/142)）：
> **CI（bump PR 阶段）缺 pb 只告警不阻断**（依赖在那个阶段必然不满足 ⇒ 硬断会自锁流水线），
> **release 流水线（tag push，依赖已就绪）才硬断言** ⇒ 两头都不漏。
>
> **⚠️ 4.6.6 发车实录：这趟卡了两次，两次都是「门禁只覆盖一种形态」**：
>
> ① **终验红：NAS 漂移误报 7 处**（[hub#235](https://github.com/pigeonbox/pigeonbox/pull/235)）
>    —— `deploy/nas/sync.sh check --all` 用**相对层数推算**「工作区根」：
>    2026-10-31 的 #221 按「兄弟布局」改成 `SCRIPT_DIR/../../..`，
>    而**真实布局是「嵌套」**（本地 `make setup` 与 CI `git clone` 都把子仓放在
>    hub 检出目录**内部**）⇒ root 指向 hub 的父目录 ⇒ NAS 仓全找不到 ⇒
>    7 处假漂移 ⇒ **终验不绿 ⇒ hub 快照发不出来**。
>    ⇒ 修法：**探测**而非推算（候选根里挑「其下确有 NAS 仓」的）
>    + selftest 覆盖**两种布局** + 负对照（root 指错必须报漂移）。
>    ⚠️ 关键教训：**当时的 selftest 只搭了兄弟布局 ⇒ 门禁自证是假的**
>    ⇒ 缺陷隔了**整整一轮列车**才暴露；同批的 `check-nas-sync-gate.sh`
>    只测「**检出形态**」（分支/游离 HEAD），不测「**布局形态**」⇒ 同一个盲区。
> ② **真机冒烟红：S26 换库恒 FAIL**（容器模式）
>    （[hub#236](https://github.com/pigeonbox/pigeonbox/pull/236)）——
>    取产物的 `docker cp` 被排在 **`db export` 之前** ⇒ 那一刻产物还不存在 ⇒ 必失败
>    ⇒ S26a 恒红（假红）；且 `S26_IMP_ERR` 还没建 ⇒ 连锁报 `parameter not set`。
>    ⚠️ **症状只在容器模式出现**（本地模式 fetch 是 no-op ⇒ 恒 ok）
>    ⇒ CI（本地进程实例）永远绿 ⇒ 这段覆盖**只在真机**才露出来。
>
> ⇒ 两条合起来是同一条教训：**门禁自测若只覆盖一种「形态」，另一种形态就是盲区；
> 而「兜底/降级分支」会把缺陷掩盖成绿**（兜底必须能穿透负对照）。
>
> **真机（10.10.10.3）验收**：升 **4.6.6**（镜像按 amd64 digest 拉取 ⇒ 4MB 分块经堡垒机传输
> ⇒ sha256 逐字校验 ⇒ `docker load` ⇒ `docker tag` 成 `ghcr.io/pigeonbox/*:4.6.6`
> ⇒ `docker compose up -d --no-deps --pull never`）；
> `pb doctor` **9 项全 OK**（退出码 0，版本 v4.6.6）；
> 冒烟 **PASS=102 FAIL=0 SKIP=1**
> （S25 备份包 5 条 + **S26 换库 5 条**：导出 / 导入 / 分享记录数一致 /
> **取件码逐字一致（dDAKdyER）** / **新建行未撞主键（max=887 → new=888）**；
> SKIP 的是 S24e「真迁移」——它会改目标实例的存储后端 ⇒ 只在隔离实例上跑）。
> ⚠️ **`pb doctor` 在容器内跑必须用 compose 服务名**（`http://pigeonbox-frontend:8080`）：
> 容器内 `127.0.0.1` 是容器自己 ⇒ 宿主映射端口（56789）**在容器网络里根本不存在**
> ⇒ 用 `http://127.0.0.1:56789` 会被判 **FAIL「服务可达」** ⇒ 结论「1 项故障」
> ⇒ **用户以为应用坏了**（与 server#88 的「缺凭据被当成服务故障」同型：
> **地址层 ≠ 凭据层 ≠ 进程层**，三者不能报同一句话）。

---

## ⚠️ 4.6.7 列车实录（2026-11-01）：库线钉版没抬 ⇒ 列车卡在「单副本守卫」

### 现象

4.6.7 列车**超时失败**（bump PR 阶段等满 1h30m）。
bump PR 全建齐了、也开了 auto-merge，但 **frontend 的 bump PR 一直红**：

```
node_modules 里有 2 份 @pigeonbox/contracts（必须恰好 1 份）:
  node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts
  node_modules/@pigeonbox/contracts
根因：frontend-core 的 contracts 钉版与壳不一致 ⇒ 先发 frontend-core 新版本把钉版抬齐
```

⇒ 其余仓的 bump PR 都合了，**只剩 frontend 一个** ⇒ 列车卡在等它。

### 根因（AGENTS.md 里其实早记了这条，但没落到手上）

`trainctl bump` **只改下游消费者**（server / fnos / openwrt / qnap / frontend 等的钉版由列车抬），
**库线仓自身**（core 的 `go.mod` 钉 contracts、frontend-core 的 tgz 钉 contracts）
**不在 bump 的 PR 列表里** ⇒ 库线 A 依赖库线 B 升级时，**A 的钉版无人抬**。

本次的具体过程：

1. contracts 升到 **v0.20.8**（本轮入库了 trap 修复 + setup-node 升级 ⇒ 内容变了 ⇒ 必须发新版本号）
2. 我发了 frontend-core **v0.11.45**（抬了自己的版本号三处）—— **但没抬它对 contracts 的钉版**（仍 v0.20.7）
3. 列车按「库线钉版自动跟随最新已发布 tag」把**壳**钉到 contracts **v0.20.8**
4. ⇒ 壳装 contracts 0.20.8，而 frontend-core 里嵌着 contracts 0.20.7 ⇒ **两份并存**
5. ⇒ frontend 的单副本守卫红 ⇒ 列车超时

⚠️ **core 有同样的问题**：`go.mod` 也仍钉 contracts v0.20.7（虽然 Go 侧没有「两份共存」的运行时症状，
但**版本错配**同样存在 ⇒ 下次 contracts 改 TS 载荷时 core 侧会编译旧契约）。

### 修法（两处都要，缺一不可）

| 库线仓 | 动作 |
|---|---|
| **frontend-core** | 钉版 ⇒ contracts v0.20.8（`package.json` 的 URL + `package-lock.json` 的 `resolved`/`version`/`integrity`）⇒ 发**新版本号 v0.11.46** |
| **core** | `go.mod` 钉版 ⇒ contracts v0.20.8 ⇒ 发**新版本号 v0.32.43** |

⇒ 然后**重跑 bump**（`make train` 重新解析最新已发布 tag）⇒ 壳才会钉到 v0.11.46。

### ⚠️ 三个具体的坑（都是这次踩的）

1. **integrity 必须取自「已发布的 Release 资产」**，不是本地 pack 的产物
   （本地 pack 的字节可能与 CI 的 npm 版本不同 ⇒ integrity 对不上 ⇒ npm 报 `EINTEGRITY`）。
   ⇒ 本次的真实值：`sha512-7X/Vw/h9j9begxbbtywathgvQsOa97d+mO+ieYfDnBNSHyJDRrcMzmnBYLm8ki+Qq4im4pK583SLhHZ9g/Nqsg==`
   （实测：下载 Release 资产 → `openssl dgst -sha512` → base64）。

2. **改 URL 后跑 `npm install` 不会自动更新 lock 里的 `version` 字段**
   （npm 从 tgz 内的 `package.json` 读版本）⇒ **必须手动同步** `version` + `integrity`，
   否则「2 份 contracts」照旧（URL 对了但版本号还是旧的 ⇒ npm 仍解析成两个包）。

3. **「库线内容变了」和「库线钉版要抬」是**两件独立的事**——
   本次我只做了前者（抬自己的版本号）⇒ 漏了后者 ⇒ 列车才卡住。
   ⇒ **发库线 tag 前的必查项**：这个库线仓**自己依赖**的库线，是否也升了？
   若是 ⇒ 它的钉版抬了吗？ ⇒ 抬了才能打 tag。

### 门禁的价值（这次是正向的）

frontend 的「单副本守卫」**没有掩盖问题，而是直接给出了根因**（门禁的报错原文就写着
「根因：frontend-core 的 contracts 钉版与壳不一致 ⇒ 先发 frontend-core 新版本把钉版抬齐」）
⇒ **门禁报错要当诊断信息读，不是当噪音**。
（对比：4.6.6 那趟两处假红都是门禁**自测形态不全**导致的误报 —— 形态问题与本次相反。）

> 其余条目（§3 / §4 / §5 / §6）尚未开 issue，按排期推进时再开。
