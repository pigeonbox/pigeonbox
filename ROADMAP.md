# PigeonBox RoadMap

> 最后更新：2026-11-07（对齐列车 **v5.6.0** —— 语言包漂移对账已发货）。路线按「现在（进行中）/ 下一步 / 更远」组织，完成即勾选。
> 功能请求请到各仓 Issues；重大设计变更会先在 `docs/design/` / `docs/specs/` 落设计文档。
> **后续排期的完整规划、落点仓、破坏性与验收判据见
> [2026-11-06 后续路线（生命周期主线）](docs/specs/2026-11-06-post-4.9-lifecycle-roadmap.md)**；
> 下方「下一步」是该稿的节选，**冲突以该稿为准**。
> 上一稿 [2026-10-30 能力演进](docs/specs/2026-10-30-capability-evolution-roadmap.md) 的 §2/§3
> 已随 4.2.0 → 4.9.1 **全部兑现**，其 §1「规划前先实测代码」的方法继续沿用。

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
- [x] **前端类型检查工具链钉版 + 跨仓对账门禁**（4.4.0 列车实录的事故修复）：vue-tsc 3.3.14 对
  `<script setup>` 里 `reactive()` 绑定的 v-model 嵌套成员**误生成 `.value` 访问** ⇒ 三个消费方
  （fnos/openwrt/qnap，对 frontend-core **源码**做 typecheck）全红 ⇒ 列车终验被挡；库侧同版本
  同样红，只是库自己的锁文件没动 ⇒ **库 CI 假绿、消费方显红**。修法：四仓统一钉
  **3.3.13 精确版本**（区间 = 锁文件随时漂进回归版）+ hub 门禁 `scripts/check-toolchain-pins.sh`
  （跨仓对账 + `--selfcheck` 注入三类故障）

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

- [ ] **装机分布落后**（2026-11-06 新识别，已升级为第一趟主线）：4.9.1 已发货，但已知至少一台
      NAS 真机长期停在 4.x 早期；该类机器在缺 root / 缺应用中心权限时**无法自行升级**
      ⇒ 生态没有任何「检查更新」能力、也没有可用的定时备份（见
      [2026-11-06 后续路线 §3.1](docs/specs/2026-11-06-post-4.9-lifecycle-roadmap.md)）
- [ ] 提交 [awesome-selfhosted](https://awesome-selfhosted.net/) 收录（首次发布须 >4 个月，窗口 2027-02 起）
- [ ] 公开 demo 站（定时重置容器）—— 已排入第三趟（见上，编号顺延为 5.3）
- [ ] iStore 上架：[linkease/istore-repo PR #810](https://github.com/linkease/istore-repo/pull/810) 待上游合并
- [ ] 飞牛应用中心上架（材料已备，唯一通道=官方微信交流群）
- [ ] 真机验收债（装机面，仓内无 backlog，靠外站 issue 跟踪）：openwrt#110（iStore 真机复验）、
      terramaster#99（Docker Hub 凭据 + 真机验证）、ugreen#132（UPK 送审 + Docker Hub 凭据 + 真机）
      —— **fnos#115 已销**（2026-11-04：真机 10.10.30.253 由 4.1.2 升到 4.8.5，
      `/beam` 走**正式 fpk 路径**复验通过 —— 验收脚本三遍 PASS=10/FAIL=0、
      p2pcweb 持久令牌跨升级逐字未变、数据零丢失、匿名端到端闭环 9/9；已关单）
      —— **ugreen#100 已销**（2026-11-02：官方 `ugcli pack` 真打出 UPK 正式包并进了 Release；
      顺带用官方工具查出并修掉 6 处「官方会拒」的包形态）

## 下一步（近期规划）

> 完整规划、落点仓、破坏性与验收判据见
> **[2026-11-06 后续路线（生命周期主线）](docs/specs/2026-11-06-post-4.9-lifecycle-roadmap.md)**；
> 下列各趟车为该稿节选（第四趟 5.5.0 是该稿**之后**的增量，不在其 §3 里 —— 它取自本文件
> 原「更远（探索中）」，因主线收官而提前）。
>
> **主线判断（2026-11-06）**：功能面已不是瓶颈 —— **版本到达率是**。
> 修好的安全缺陷如果装不到用户机器上，等于没修。所以先补生命周期，再补账号信任，最后才是易用增量。

### 第一趟 5.0.0 / 5.1.0 —— 生命周期（零破坏）

> **5.0.0 发了第一项**（更新检查），**5.1.0 发了第二项**（定时自动备份），**5.4.0 发了第三项**
> （升级路径统一），**5.4.1 补齐其 OpenWrt 分项**（升级前自动备份四端齐）。第三项曾两度顺延
> （5.2.0/5.3.0 让位给账号信任与易用触达）；不再沿用 4.10/4.11/4.12 —— 后续编号一律 5.x，
> 见规格稿头部的「发货记录」。

- [x] **更新检查**（**5.0.0 已发货**）：`/admin/diagnostics` 增 `update` 段（当前/最新/检查时间/来源）·
      24h 落盘缓存 · 离线返回 `unknown` 而非故障 · `pb doctor` 以 **INFO** 级展示
      （**不改变退出码**，否则 CI 会因「上游有新版本」恒红）· 维护页显示升级入口
- [x] **定时自动备份**（**5.1.0 已发货**）：后台调度（默认**关**，开启则每日一次 03:00）·
      与离线子命令**同格式**的一致快照（可直接互相恢复）· 保留 N 份（默认 7，`<=0` 不限，**只在成功后清理**旧包）·
      写入走 `.partial` → rename（半截包不会被当成可用包）· 失败**一个旧包都不删** · 维护页可下载、可立即备份
- [x] **升级路径统一**（**5.4.0 已发货**）：`docs/UPGRADE.md` 成为升级**唯一真相源**
      （六端步骤 + 升级前三件事 + 逐端回滚 + 跨版本兼容矩阵 + 破坏性节点表 + 升级后验真；
      文档站同名页改为 include 桩，根治「三处升级说明互相漂移」）·
      **升级前自动备份业务库**：DSM `preupgrade` 与 QTS `pkg_pre_install` 从无到有，
      与 fnOS 既有的 `upgrade_callback` 统一口径（`<db>.bak-<YYYYMMDD-HHMMSS>`、轮转留 3 份、
      按文件名排序）。失败语义按平台可控性区分：DSM/QTS **中止升级**，fnOS 记日志继续 ·
      **OpenWrt 5.4.1 已发货**：ipk `postinst` / apk `post-install`+`post-upgrade` 在
      `init.d restart` 之前快照；因钩子跑在新二进制就位之后（此时 abort 只会把服务留在停机状态）
      且 overlay 常只有几十 MB（flash 写满时 abort 是死结），这一端**有意**不中止：
      空间守卫 + best-effort + stderr/syslog 双写日志，判据由 `preupgrade-backup-selftest.sh`
      的 9 组用例与 5 组变异负对照兜住

### 第二趟 5.2.0 —— 账号与信任


- [x] **管理员 2FA（TOTP）**（**5.2.0 已发货**）：RFC 6238 + 8 个一次性恢复码（只存哈希）·
      `security.require_admin_totp` 默认关 · 关闭需口令 + TOTP 双因子
- [x] **邮箱找回密码**（**5.2.0 已发货**）：SMTP 未配置则不显示入口 · 恒回 200 防枚举 · 一次性 token 30 分钟 ·
      改密后**会话纪元 +1**（旧 JWT 立即失效）
- [x] **会话管理**（**5.2.0 已发货**）：登录设备列表 + 「退出所有设备」（API Key 不受影响，另行吊销）

### 第三趟 5.3.0 —— 易用与触达


- [x] **目录上传**（**5.3.0 已发货**）：保留相对路径 → 取件页按目录展示 + zip 保留结构 ·
      路径穿越一律拒绝（复用 `pathx.SanitizeRelStrict`）· 判重键是**完整相对路径**
      ⇒ 同目录同名显式报错不静默改名 · 超长（>200）拒绝不截断
      （MySQL varchar 按字符计、sqlite 不截断 ⇒ 截断会「本地绿、上线红」）
- [x] **多语言 ja / de / ru**（**5.3.0 已发货**）：1687 个叶子 key 与 zh-CN 逐条一致；
      `serverDisabledPattern` / `serverNoRootsPattern` **在所有语言里仍保持中文**
      （与后端原始中文报错逐字匹配，翻了就静默失效 · `parity.spec.ts` 11 用例钉住）
- [ ] **demo 站 + 分发跟进**（并行，不阻塞发车）：每日重置 · iStore / 飞牛应用中心 / awesome-selfhosted
      —— **顺延**：7 天自动重置判据要求连续跑满，且分发三渠道全卡外部审核窗口

### 第四趟 5.5.0 —— 提醒（零 wire 改动）

> 主线（生命周期）已在 5.4.1 收官，功能增量重新开闸。选题放在这里而不是更远，
> 是因为它**只缺最后一公里**：通知渠道（站内信 / webhook / SMTP / Telegram / Bark）
> 与调度基建（5.1.0 的按节拍后台任务）都已就位，缺的只是「在正确的时刻产生这条消息」。
> 零 wire 改动 —— 不新增端点、不新增渠道、contracts 不动。

- [x] **分享到期提醒**（**5.5.0 已发货**）：扫描「剩余有效期 ≤ 提前量」的**用户分享**，
      给寄件人发一次站内信（同时经已配置的 webhook / SMTP / Telegram / Bark 外推）
      —— 三个不变性：**一个分享只提醒一次**（`file_codes.expiry_reminded_at` 条件 UPDATE
      抢标记 ⇒ `public×N` 多副本下只有一处会发）· **抢了就得发出去**（发送失败立刻回滚，
      下一轮重试；宁可晚一轮，不可静默丢）· **短命分享不提醒**（寿命 ≤ 提前量：刚发 1 小时
      就对它说「还有 24 小时过期」是噪音，而这类分享**恰好立刻落在窗口内** ⇒ 必须显式排除）。
      **节拍 ≠ 频率**：循环固定每分钟醒一次，是否真扫由 `interval_minutes` 决定 ⇒ 改配置
      不必重启。默认**关**（主动打扰，与「更新检查」那种被动查询相反）；越界参数**收敛
      不报错**（1..720h / 1..1440min，0 取默认）。范围边界：匿名分享没有收件人、次数耗尽的
      分享提醒「请延长」是误导、被禁的分享提醒会泄露治理动作 ⇒ 都不在范围。三条延期路径
      （用户批量延期 / 管理员改单条 / 管理员批量延期）清标记 ⇒ 走到新到期窗口再提醒一次。
      守卫：core 10 例（发送一次且幂等 / 关开关不发 / 匿名与短命不发 / 耗尽与被禁不发 /
      延期后重新武装 / 发送失败回滚重试 / 多副本标记仲裁 / clamp 表驱动 / 保存→回读→
      **全局生效** / 默认关）+ 6 组变异负对照；frontend-core 7 例（面板绑定 / 边界 /
      缺省值 / 保存载荷 / null 归一 / api 类型 / 五语键）；冒烟 S30 六条断言锁「存得进 ·
      读得回 · 字段级合并 · 兄弟渠道不被牵连 · 复原」，**端到端投递与仲裁由 core 单测的
      可控时钟覆盖**——真实实例造不出「寿命 > 提前量 且 剩余 ≤ 提前量」的状态
      （新建分享的寿命就是有效期，而提前量下限是 1h），理由写在 S30 段注释里

### 第五趟 5.6.0 —— 语言包漂移对账（零 wire 改动）

> 选题动机：5.3.0 补齐五语之后，语言包**只能靠人**保持同步 —— 新增一个键忘了补另外四语、
> 改了占位符名（`{name}` → `{who}`）只改了中文、键随代码删了译文却留着……
> 这类漂移**不编译失败、不让测试红**，只在用户界面上显形（界面显示键名原文、占位符原样印出来）。
> 这趟把它变成机械判据。零 wire 改动 —— 不新增端点、contracts 不动（仍 v0.23.0）。

- [x] **语言包漂移对账**（**5.6.0 已发货**）：四条判据都是「每语种 × 每键」逐条比，不是抽样——
      **占位符集合**（`{name}` 之类排序后必须与 zh-CN 完全相同）· **复数分段数**
      （竖线段数一致，多一段少一段都是复数规则错位）· **死键**（键路径在剥注释后的
      全源码子串里不出现 ⇒ 判红）· **动态构造显式登记**（4 条前缀
      `upload.fileType.` / `upload_view.failure.` / `user.history.detailChannel.` /
      `user.notifications.type_` 各钉住调用点，**条目失效也判红**——否则「登记表」会变成
      永远绿的死条）。死键判据按**生成点**而不是 `t()` 消费点找：`utils/api-interceptor.ts`
      有 errcode → i18nKey 的映射表，只认字面量 `t('…')` 会把 69 条 errcode 全判成死键。
      顺带清掉存量 **214 条死键**（五份语言包各删 214 行、回收 8 个空对象，
      zh-CN 1985→1755），**不引入 baseline 白名单** ⇒ 门禁零容忍
- [x] **顺带修掉对账工具自身的静默失明**（这才是本趟最有价值的一条）：
      `src/utils/__tests__/sourceScan.ts` 的 `stripComments` 旧实现「先正则剥块注释、
      再剥行注释」，于是**行注释正文里**的「斜杠加星号」（写示例、写正则、写 Markdown 粗体
      都常见）被当成块注释开头，一路吞到几百行之后的下一个「星号加斜杠」——
      `src/views/user/History.vue` 实测 **430 行被吃到 197 行**（吞掉 233 行、占 52%），
      `src/views/admin/Config.vue` 少 38 行。危害在于**所有源码级守卫一起失明**：
      parity 的字面量 `t()` 扫描、try/catch 反馈、禁裸 fetch……都先剥注释再断言，
      而要被检查的代码已经不在输入里了 ⇒ 断言照样全绿。改为单遍扫描（正确处理字符串里的
      双斜杠、模板串里的注释符号、正则字面量与 HTML 注释）
- [x] **判据自身也要有牙齿**（仓级兜底的三次失败记在用例里，免得后人重走）：
      ① 逐行判「还在不在输出里」+ 最长连续缺失段 ⇒ 没牙齿（重复行一命中就切碎，实测 10 行）；
      ② 只统计全文件唯一行 ⇒ 仍没牙齿（实测 15 行：旧实现吃掉的是许多**碎片段**，
      不存在长连续段）；③ 行数删除比例阈值 ⇒ 会假红（`utils/capabilities.ts` 两个实现
      都删 59%，真注释密集，与 History.vue 的 54% 无法用同一阈值分开）⇒ 结论：聚合量与
      连续性都不行，要比**覆盖**：造一个「一定是代码」的保守 oracle（只按行首判注释），
      要求 `stripComments` 一行都不许少。回退负对照实测缺口 146 行（History.vue 105 /
      Config.vue 38），恢复即绿

## 已交付明细（4.2.0 → 4.9.1）

<details>
<summary>点开看三趟车的原始排期与踩坑实录（4.2.0 / 4.3.x / 5.x–6.x）</summary>

### 第一趟 4.2.0（零破坏，全是「兑现」不是「新建」）

> **✅ 已发货**：hub 快照 `v4.2.0`（Latest）· core `v0.32.30` · frontend-core `v0.11.38` ·
> chart `2.0.97` · 7 终端 + 双镜像全部回挂
> （PR：core#14 / server#70 / frontend-core#22 / hub#177 / hub#178 / hub#179）
> 真机验收（10.10.10.3 已升 4.2.0）：冒烟 **PASS=83 FAIL=0 SKIP=0**；
> `pb doctor` 8 项全 OK、退出码 0；吊销 Key 后正确降级为「深度检查未执行 + 退出码 1」

- [x] **`pb doctor` 自检命令**：部署自检输出可行动结论（DB / 存储 / Redis / 版本 / 站点地址 /
      首启 / 时钟），退出码 0 健康 · 1 有待处置或故障 · 2 用法错误；`--json` 供 CI 消费
- [x] **能力自描述（capability negotiation）**：`/api/config` 增 `capabilities` 段，
      前端按位显隐 —— 「这个面支持什么」收敛成一份真相源，不再各面各写 if
- [x] **首启令牌自动生成**：启动时生成一次性令牌（打印在日志 + 落 `.setup_token`），
      暴露面默认收口；`PB_SETUP_TOKEN_AUTO=0` 可关闭
      （顺带修掉「缺令牌被计入失败预算 ⇒ 正确令牌也被锁死」的真缺陷）

### 第二趟 4.3.x / 5.0

> **首启四步向导已存在**（2026-10-22 就落地：管理员 → 站点地址 → 投递策略 → 完成）⇒
> 真实缺口只剩 **NAS 出厂预接线**。

- [x] **NAS 出厂预接线**（Beam↔Box API Key 预置，免手工粘贴）——
      **三端全部已落地**（2026-11-01 销账）：
      fnOS [fnos#157](https://github.com/pigeonbox/fnos/pull/157)（真机验证）· [#158](https://github.com/pigeonbox/fnos/pull/158)（验收脚本装上探针注入 + 自证）·
      [#159](https://github.com/pigeonbox/fnos/pull/159)（等待就绪逻辑收进脚本本体）；
      qnap [#143](https://github.com/pigeonbox/qnap/pull/143) · [#144](https://github.com/pigeonbox/qnap/pull/144)；
      openwrt [#150](https://github.com/pigeonbox/openwrt/pull/150)（admin 口令从 UCI 导出 + procd 起 p2pcweb 的等待时机已处理）。
      决策（用户拍板）：预置 Key 的 scope = **全量**；创建方式 = **NAS 应用自动创建**（幂等、缺失才建）。
      ⚠️ 关键机制：API Key 明文只在创建时返回一次 ⇒ 明文落缓存（0600）+ 每次启动校验有效性（自愈换库/撤销）。
      ✅ **跨仓一致性门禁已有**（hub#241）：`scripts/check-nas-prewire-consistency.sh`
      比三端脚本的 **sha256 逐字一致**（不是文本 diff），判红时点名是哪两端不同；
      带 4 组自证（一致⇒绿 / 改一端⇒红 / 缺一端⇒红 / 无仓⇒跳过）⇒ 门禁有牙齿。
      已接进 hub CI（`nas-prewire-consistency` job，三仓检出到同一 workspace）；
      2026-11-04 复核三端远端 master 仍字节一致（`aaa5a97a…`）。
- [x] **API Key 权限 scope**：`admin`/`user`/`share` 三个能力面，服务端按**请求路径**强制
      （缺能力 ⇒ 403，与「Key 无无效」的 401 区分）；**缺省 = 全量** ⇒ 老 Key 零影响；
      非法取值直接报错（不静默放宽）。
      已实现并发货：contracts v0.20.5 / core v0.32.32 / frontend-core v0.11.39
      （PR contracts#9 · core#17 · core#18 · fe#26）；**4.3.0 发货，4.3.1 hotfix 补映射表漏项**
      （`/api/v1/notifies/**` 是真正用 Key 鉴权的面 ⇒ 原表漏了它）。
      真机验收：冒烟 **PASS=88 FAIL=0**（含 5 条 scope 断言：用户面 403 / 联邦面 403 /
      公开面 200 / 寄件面 200 / 测完即吊销）。
      （默认仍全量，存量 key 不受影响）

### 第三趟 5.x–6.x

- [x] **存储迁移**（`POST /admin/storage/migrate` + `pb storage migrate`）：把存量对象搬到目标后端，
      **搬完才切换**；取件码与链接不变、失败不切换、可中断可续（随 4.4.0 发货）
- [x] **可迁移备份包（导出 + 恢复）**（随 4.6.0 发货）：统一备份包格式
      （`manifest.json` + `db/backup.db` 一致快照 + `files.json` 清单 + `objects/` + 逐对象
      sha256）⇒ 换机器 / 灾备一个工具；**取件码与链接不变**（DB 快照原样带走）；
      恢复是**破坏性**操作 ⇒ 须显式 `--yes` + 停服；落地为 **server 二进制的离线子命令**
      （`pigeonbox backup export` / `pigeonbox restore`），不做 HTTP 端点、`pb` 保持轻量
- [x] **换库（SQLite → Postgres/MySQL）**：随 **4.6.3 发货**（core v0.32.41）——
      `pigeonbox db export` / `pigeonbox db import`（**逻辑搬运**，跨方言，与「备份包」的
      **物理快照**分工明确：备份包 = 同库同机换机器/灾备；换库 = 跨方言只搬行数据、不碰存储对象）
      ⇒ 导出 → 目标库建表 → 逐行插入 → **显式对齐自增序列**
      （PG `setval` / MySQL `AUTO_INCREMENT`；不修则「迁移完第一次新建分享」立刻撞主键）。
      破坏性语义：导入必须显式 `--yes` + 目标库为空（或 `--allow-nonempty`）。
      真机验收（10.10.10.3 → 真 PG）：**12 张表行数逐表一致** · 取件码**逐字一致** ·
      PG 新建行拿到 `max(id)+1` · **负对照**（把序列设到确实存在的 id）⇒ 确实撞主键。
      ⚠️ 4.6.3 顺带修掉 4.6.2 的「导不进去」：core v0.32.40 把 `upload_id` 声明成 `size:36`
      （实际值域 64）⇒ SQLite 忽略列宽所以生产无感，但换库到 PG 直接 `value too long` ⇒
      修法 = 列宽改 64 + 导入侧列宽校验（**先于任何插入** ⇒ 失败时目标库零写入）
      + 负对照改成**动态取一个确实存在的 id**（原负对照硬编码 id=1 而真机 id=1 恰是空洞 ⇒ 证明不了任何事）。
- [x] **联邦前台化（跨站投递）**：「邀到别人的柜」进前台寄件台（联邦目前只有 admin 面，匿名访客看不见）
      —— 已交付：core [#29](https://github.com/pigeonbox/core/issues/29)（公开发起端点）+ 前端
      [frontend-core#37](https://github.com/pigeonbox/frontend-core/issues/37)（前台寄件台接线），均已关闭
- [x] **零知识 E2E 走出 secure-context**：服务端只存 wrapped key（口令派生 KEK），
      把前提从「HTTPS」换成「有口令」（当前 NAS 典型 http 访问下 E2E 根本用不了）
      —— 已交付：core [#30](https://github.com/pigeonbox/core/issues/30) + 前端
      [frontend-core#38](https://github.com/pigeonbox/frontend-core/issues/38)，均已关闭
      （桌面端配套：desktop [#124](https://github.com/pigeonbox/desktop/pull/124) 识别 E2E 件并提示浏览器端取件）
- [x] **桌面端做「一等取件端」**：托盘通知 + 一键取 + 剪贴板只放 6 位取件码
      —— 已交付：desktop [#119](https://github.com/pigeonbox/desktop/pull/119)（已合），
      随 `desktop-v4.8.5` 发货

### 第一趟的收尾遗留（已随 4.2.0 / 4.3.x 发货）

- [x] **`pb` 二进制随镜像分发**（server#73）：4.2.0 起镜像内已有 `/app/pb`
      （真机实测 `docker exec pigeonbox /app/pb doctor` 8 项全 OK、退出码 0）
- [x] **诊断报告的版本改用构建版本**（core#16）：真机已显示 `v4.3.1`（原读 yaml 的
      `app.version` ⇒ 把 4.2.0 报成「1.0.0」）
- [x] **NAS 打包面也带 `pb`**：随 **4.6.6 发货** —— fnOS fpk（`app.tgz` → `bin/pb-linux-{amd64,arm64}`）·
      qnap qpkg（自解压段 → `data.tar.gz` → `bin/pb-linux-amd64`，并进 `bin/SHA256SUMS`）·
      openwrt ipk（`data.tar.gz` → **`usr/bin/pb`**，在 PATH 里）⇒ 三端**逐包解包确认**。
      门禁**按阶段分层**（fnos#153 · openwrt#148 · qnap#142）：CI（bump PR 阶段）缺 pb
      **只告警不阻断**（该阶段依赖必然不满足 ⇒ 硬断会自锁流水线）；
      release 流水线（tag push，依赖已就绪）才**硬断言** ⇒ 两头都不漏。

### 既有待办（未挂进三趟车）

- [x] **库侧适配 vue-tsc 3.3.14+**（4.5.0 已做）：frontend-core 的 `Config.vue` 里
      `configForm` / `exForm` / `rlForm` 由 `reactive({...})` 改为 `ref({...})`
      （模板侧一字不改，顶层 ref 在模板里自动解包，运行时语义相同）⇒ 3.3.14 的
      `.value` 误判消失（实测 `.value` 报错 **20→0**）⇒ **与工具链版本无关**
      （3.3.14 / 3.3.13 / 3.2.9 / 3.2.5 全部 0 报错）⇒ 不再依赖「钉到 3.3.13」
      这条止血线（钉版仍保留：防工具链再漂）。另给库加了**「最新 vue-tsc」前瞻探针**
      （CI job）——上游工具链一出回归，**库这边先红**，而不是等消费方红。
- [x] **API Key 列表回传 `revoked_at`**（4.5.0 已做）：撤销时间**早已正确落库**
      （真机实测 `user_api_keys.revoked_at` 有值），但 `GET /user/api-keys` 的响应里
      **没有这个字段** ⇒ 用户/前端看不到「这把 Key 是什么时候被撤销的」⇒ 审计信息断在
      **回传面**（列表含已撤销 Key 是设计如此：软撤销 + 留痕）。
      修法（4.5.0 落地）：contracts 增 `9: optional string revoked_at`（v0.20.7）·
      core 映射 + 单测（v0.32.35）· frontend-core 令牌页把吊销时间做成**状态列第二行
      小字**（不做成 tooltip：审计信息不该靠 hover 才看得到，v0.11.42）。
- [x] P2P 联邦定时自动同步（邀请推送已交付；定时调度面另立）
      —— 已交付：core [#32](https://github.com/pigeonbox/core/issues/32)（`app/federation/sync.go`
      周期调度 + 装配层 + admin 块内起跑，public 副本天然不跑），随 **4.7.1 发货**（core v0.32.45 / PR core#38）
- [x] 跨会话断点续传：按 file_hash 匹配未完成会话（现有同会话续传 + 同用户秒传）
      —— 已落地：`upload_id` 由 `file_hash` 派生 ⇒ 同文件跨会话复用同一会话键；
      归属判定三选一放行（上传者本人 IP/登录用户 · 持有效会话令牌 `X-Upload-Token` ·
      尚无任何分片落盘的空会话）⇒ 换设备/换网络可续传，且**不把别人的进行中会话交出去**
      （他人会话仍 409）。配套：会话被清理（软删）后同 `upload_id` 走**复活**而非新建
      （撞 `(upload_id, chunk_index)` 唯一索引 ⇒ 10008「初始化上传失败」），
      且**已完成**的会话不触发防截胡闸（只重置进度，绝不回给他人 share_code）。
- [x] Azure Blob/HDFS/OneDrive 驱动真机联调（REST 语义按官方文档实现，Azure 已签名单测；
      OneDrive 需 Azure AD 凭证）
      —— 已交付：core [#36](https://github.com/pigeonbox/core/issues/36)（真机联调 + 错误码映射确认
      + 行为差异记录），**当场查出并修掉 4 个「单测全绿、真机不可用」缺陷**
      （Azure 共享密钥模式查询串拼接错位 / canonicalized resource 用 `name=value` 而非 `name:value` /
      `listAll()` 不查 HTTP 状态码致鉴权失败伪装成空列表 / 第 4 项同族）
- [x] Telegram / Bark 通知渠道（SMTP 已落地，架构上扩渠道）
      —— 已交付：core [#31](https://github.com/pigeonbox/core/issues/31)（Bark 目标地址走 **SSRF 校验**
      —— 目标 URL 由用户填写）；附带修掉「错误/日志携带目标 URL（URL 内嵌 bot token）」这条红线未落地的缺陷
- [ ] 绿联 UPK / 铁威马 TOS 7 官方应用包送审
      —— **绿联 UPK ✅ 已交付**（2026-11-02：官方 `ugcli pack` 真打出正式包并进 Release；
      用官方工具查出并修掉 6 处「官方会拒」的包形态）；**铁威马 TOS 7 ⏳ 仍缺**
      （**镜像同步发 Docker Hub 已拍板并落地**（2026-10-31）：TOS 7 应用商店与绿联 UPK
      应用中心**只收 Docker Hub 镜像**（拒收 ghcr.io / quay.io / 私有仓库）⇒ 不同步则
      **两个平台都送不了审**，不是「可选项」；落地 = server release 流水线**一次构建、
      多 tag 推送**（ghcr + Docker Hub，tag 合并逻辑抽成 `scripts/image_tags.py` 单一真相源），
      **缺 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` 时只跳过 Docker Hub 那一路**
      （ghcr + Release 照常出）⇒ 不让外部资源卡死整条发版链。
      ⚠️ 剩余硬前置 = **凭据 + 各自平台的打包机/签名工具**
      （绿联要 Linux 打包机 ugcli + ugdev.sig 授权；铁威马要 Docker Hub 凭据））
- [x] 前端 en-US 翻译长尾收尾（界面文案全量英文化）
      —— 已闭环：en-US 语言包里**唯一**的两条中文值（`serverDisabledPattern` / `serverNoRootsPattern`）
      **不是漏翻**，而是必须与后端**原始中文报错**逐字一致（`msg.includes(...)` 匹配）⇒ 翻译了就静默失效；
      由 `src/i18n/__tests__/parity.spec.ts` 守卫（断言这两条**必须**保持中文）+ 双语 key 集合一致性守卫（8/8 绿）
- [x] Playwright E2E + 前端测试加密
      —— 已交付：frontend-core [#45](https://github.com/pigeonbox/frontend-core/issues/45)
      （浏览器级 E2E：取件/寄件/后台三条主路径 + 前端测试加密）
- [ ] ~~主题系统 / 自定义 CSS~~（暗色模式已落地，边际收益低、回归面大 ⇒ **建议降级，待拍板**）

</details>

## 更远（探索中）

> 「邮箱找回密码」「二次验证（2FA）」**已上移**到第二趟（见上，编号顺延为 5.2）；
> 「分享到期提醒」**已上移**到第四趟（**5.5.0 已发货**）；
> 「PWA / 小程序」已判定**不单独做**（与桌面端一等取件端重复）。此处只留尚未排期的探索项。

- [ ] 按目录的配额与分享策略（当前只有站点级全局配额）
- [ ] 语言包随版本漂移的自动对账机制


## 设计决策记录

- 多仓拆分与依赖方向见 [architecture.md](docs/architecture.md)（CI 强制单向依赖）。
- 存储点亮 / 首启引导详细设计见 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md)。
- 多副本拆分见 [docs/specs/2026-10-06-multi-replica-deployment-modes.md](docs/specs/2026-10-06-multi-replica-deployment-modes.md)；
  发布列车 v2 见 [docs/specs/2026-10-12-release-train-v2-design.md](docs/specs/2026-10-12-release-train-v2-design.md)；
  P2P 对称节点融合见 [docs/specs/2026-10-14-p2p-peer-integration-design.md](docs/specs/2026-10-14-p2p-peer-integration-design.md)。
- 破坏性变更（删/改名字段、改错误码语义、wire 协议）必须升主版本；p2p wire 破坏性变更双端须同版；生成物一律不手改。
- 未实现的能力不暴露配置键（假开关零容忍，2026-10-04 清理原则）。
