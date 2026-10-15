# 1.24.0 / 1.24.1 易用性与统一化验证报告

- **日期**：2026-10-15
- **范围**：列车 1.24.0（易用性修复波 + 配置优先级统一 env 恒>DB + 错误码四套归一）与热修列车 1.24.1（E2E 中发现的契约字段漏传）
- **方法**：自动化测试（vitest / go test / 棘轮守卫 / smoke 46 项）+ Playwright 端到端走查（截图取证）+ API 探针
- **结论**：自动化与 E2E 全绿；E2E 揪出 **2 处后端契约字段漏传**（1.24.0 未覆盖），已修复并随 **1.24.1 shipped（verify 0 不一致）** 发布，生产（10.10.10.3 @ 1.24.1）探针实证两字段均回传

## 一、环境

| 项 | 值 |
|---|---|
| 被测版本 | hub v1.24.0（ghcr server/frontend:1.24.0）→ 热修 v1.24.1（core v0.22.1） |
| 生产实例 | 10.10.10.3:56789（deploy 经 pull-mirror + force-recreate，双容器 healthy） |
| 本地受控栈 | core@工作区（go.work 联编，12355 内存模式）+ frontend-core dev（3000，PB_API_TARGET 代理） |
| 浏览器 | Playwright Chromium（1440×900 / 375×812 两视口） |
| 版本自证 | 生产页脚 `前端版本 v1.24.0`；本地 dev 页脚 `v0.7.0`；`/api/config` 返回 `code:0` |

## 二、自动化测试结果

| 套件 | 结果 | 说明 |
|---|---|---|
| frontend-core vitest | **124/124 绿** | 含新增 `i18n parity` 常驻守卫（zh/en key 全集对齐）、usePickup/useUploadQueue/api-interceptor/codeInput |
| frontend-core vue-tsc + vite build | 绿 | typecheck 无输出，build 成功 |
| core go test ./... | **全绿** | 含 arch 棘轮守卫（规则 8 conf 直读只减不增）、新增 env_reapply 4 用例（类型表/空串/未知键/nil 安全） |
| hub smoke-full.sh | **46 项**（44→46） | 新增 S5b/S5c 两条回归断言：文本分享必须回传 `pickup_code`、取件必须回传 `share_code`（见 §四） |
| docs-site build | 绿 | 含错误码对照表页死链检查 |
| qnap CI 冒烟 | 绿 | admin 登录断言改双码兼容后通过 |

## 三、E2E 测试用例与结果（Playwright 实测）

> 全部用例在本地受控栈执行（等价 1.24.0/1.24.1 代码），截图见 `assets/`。

| # | 用例 | 步骤 | 预期 | 实际 | 结论 | 证据 |
|---|---|---|---|---|---|---|
| TC-01 | 首页取件输入 | 打开首页 | 6 格锁定+「填满 6 位自动取件；大小写不限」提示 | 一致 | ✅ | 01 |
| TC-02 | 文本分享两码弹窗 | 文本分享→成功弹窗 | 出现「6 位取件码」快捷卡；Tab「分享码」；提示含「整段复制，粘贴进取件框」；按钮「复制分享码」 | 一致 | ✅ | 02 |
| TC-03 | 文本取件直达详情页 | 6 位码逐位输入→自动取件 | 跳 `/share/{share_code}`，原文完整渲染，**不是**空结果页 | 一致（`/#/share/dS1YFynz`，textShown=true） | ✅ | 03 |
| TC-04 | 8 位码粘贴兜底 | 取件框整段粘贴 8 位分享码 | 整串走分享详情页（不截断成前 6 位误取） | 一致（同码落地） | ✅ | 03 同页 |
| TC-05 | 错误提示人话化 | 输入不存在的取件码 | toast 中文「取件码不存在」（errcode 20005 映射），非英文裸串 | 一致 | ✅ | 05 |
| TC-06 | 移动端弹窗宽度 | 375×812 视口→分享→弹窗 | 弹窗 ≤375px、无横向溢出 | 343px，overflowX=false | ✅ | 06 |
| TC-07 | 永久有效期显示 | 有效期单位选「永久」 | 数字输入框隐藏，显示「永久」 | 一致 | ✅ | 06 同屏 |
| TC-08 | 修改密码入口 | 前台顶栏用户菜单 | 有「修改密码」项 | 一致 | ✅ | 07 |
| TC-09 | 修改密码弹窗 | 打开弹窗 | 当前/新/确认三个密码框 | passwordFields≥2（实为 3） | ✅ | 08 |
| TC-10 | 修改密码全链路 | 真实改密 admin123→NewPass124! | 成功 toast「密码已修改，请重新登录」；会话纪元 bump 旧令牌失效；新密码可登录 | 全部一致（API 闭环：新密码登录✓→改回✓→旧密码复登✓） | ✅ | 15 |
| TC-11 | 后台死控件移除 | 系统配置→站点与外观 | 无「端口」字段（曾为保存不生效的死控件） | portFieldRemoved=true | ✅ | 09 |
| TC-12 | OIDC 回调地址纠正 | 用户与登录分区 | 只读框 = `<origin>/api/v1/user/oidc/callback`（后端真值） | `http://localhost:3000/api/v1/user/oidc/callback` | ✅ | 10 |
| TC-13 | 安全分区 yaml-only 提示 | 安全与限流分区 | 显示「暂只能经 config.yaml / 环境变量配置…」 | 一致 | ✅ | 11 |
| TC-14 | P2P 分区 env 优先提示 | P2P 与联邦分区 | 显示「env > 后台配置 > config.yaml…」 | 一致 | ✅ | 12 |
| TC-15 | 存储页 env 优先提示 | 存储管理 | 显示统一优先级提示 | 一致 | ✅ | 13 |
| TC-16 | admin i18n 无残留 | 切 English→文件管理页 | main 区域零中文字符 | `chineseLeftoversInEN=[]` | ✅ | 14 |
| TC-17 | 错误码 errcode 化 | 错误密码登 admin | HTTP 401 + 包络 `code:10002`（原为裸 `401` 字面量） | `{"code":10002,…}` + HTTP 401 | ✅ | §五 |
| TC-18 | 成功码唯一 | 任意成功请求 | `code:0`（老端点 200 退役，兼容期双收） | `/api/config`、`/share/text/` 均 `code:0` | ✅ | §五 |

## 四、E2E 揪出的新问题与修复（→ 1.24.1）

E2E TC-02/TC-03 首跑**失败**，揪出两处 1.24.0 未覆盖的后端契约字段漏传（gen/handler 手写区映射遗漏——service 层有值、契约有字段、文件端点映射了，唯独文本链路漏了）：

| # | 问题 | 根因 | 修复 | 回归守卫 |
|---|---|---|---|---|
| B1 | 文本分享成功弹窗**永不出现** 6 位取件码快捷卡 | `ShareText` handler 响应只映射 code/url，漏 `pickup_code`（service 层 `ShareTextWithAuth` 已铸码） | handler 补 `PickupCode: strPtrIfNotEmpty(result.PickupCode)` | smoke S5b |
| B2 | 6 位码取件**退化为空结果页**（截断文件名+下载按钮），不跳详情页 | `Retrieve` handler 响应漏 `share_code`（`meta.IsText` 契约语义"handler 据此回传"未实现） | handler 补 `if meta.IsText { data.ShareCode = &meta.ShareCode }` | smoke S5c |

修复后探针：`/share/text/` → `{"code":0,"data":{"code":"KBUlYcUA","pickup_code":"CYCZAX"}}`；`/anonymous/retrieve` → `data.share_code:"736gGzxE"`；TC-02/TC-03 复跑全绿。随 **core v0.22.1 + 热修列车 1.24.1** 发布。

**1.24.1 发车记录**：core v0.22.1 → bump → **server 裸奔 tag 再次发生**（PR #14 未合即打 v1.24.1，tag 锚在无 bump 的 main）→ 处置=合 PR #14 → 删远端 tag → 重切重发 → verify **0 处不一致**，`hub v1.24.1` Latest 快照已出；fnos/openwrt/qnap 三终端 CORE_PIN=v0.22.1 且 tag 锚定核对无误。

**生产终态（10.10.10.3 @ 1.24.1，双容器 healthy）**：

```text
$ POST /share/text/          → code:0, pickup_code:"9W4QJT", share:"08qXfkTo"
$ POST /anonymous/retrieve   → code:0, share_code:"08qXfkTo"   # 与分享码一致
```

> 备注：B1/B2 与 1.24.0 里已修的前端半边（TextShare 透传 `pickup_code`、usePickup 消费 `share_code`）互为因果——前端修复在 1.24.0 单独发布时因后端漏传而不可观测，本次闭环。

## 五、生产实证（10.10.10.3，1.24.0）

```text
$ curl /api/config                                   → {"code":0,...}                    # TC-18
$ curl -X POST /admin/login (错误密码)                → HTTP 401 {"code":10002,...}        # TC-17
$ docker compose ps                                   → server/frontend:1.24.0 双 healthy
$ 页脚                                                → 前端版本 v1.24.0
```

生产实例关闭了匿名分享（访客上传/文本分享 403），E2E 交互用例在本地受控栈完成；生产侧做只读+认证链路实证。

## 六、配置优先级统一（env 恒 > DB）专项

| 项 | 结果 |
|---|---|
| 实现形态 | `bootstrap/env_reapply.go` 反射重施器 + `OnOverlayApplied` 钩子（每次 DB overlay 后重施）+ `syncMirrorFromGlobalLocked` 镜像回同步（后台所见即生效） |
| 棘轮合规 | arch 规则 8（conf 直读只减不增）零基线改动通过 |
| 测试 | env_reapply 4 用例（类型强转/空串不覆盖/未知键跳过/nil 安全）+ core 全量回归绿 |
| 文档 | ENVIRONMENT_VARIABLES.md「配置优先级」节重写（含旧行为迁移说明）；存储/安全/P2P 三处 UI 提示（TC-13/14/15） |

## 七、错误码统一专项

| 项 | 结果 |
|---|---|
| 成功码 | 44 处 `Code:200`→`0`，唯一成功码（TC-18） |
| legacy 1001-1008 | 常量名保留、值重钉 errcode（1005→新增 10016 Conflict）；对照表见 docs-site error-codes 页 |
| 401 字面量 | 收编 10002/20003/40007，HTTP 状态不变（TC-17） |
| 保留类 | ~160 处 HTTP 语义镜像码（400/403/404）文档化保留，随后续波次收编 |
| 兼容性 | 前端/pb 双码接受零改动；联邦/registry/p2px 客户端仅依 HTTP 状态（发车前核验）；qnap CI 断言已双码化 |

## 八、截图索引（assets/）

| 文件 | 用例 |
|---|---|
| 01-home-pickup-6box.png | TC-01 首页 6 格取件 |
| 02-text-share-dialog-pickup-strip.png | TC-02 两码弹窗+快捷卡 |
| 03-text-pickup-lands-share-detail.png | TC-03/04 取件直达详情页 |
| 05-error-toast-chinese.png | TC-05 中文错误提示 |
| 06-mobile-dialog-375px.png | TC-06/07 移动端+永久 |
| 07-user-menu-change-password.png | TC-08 用户菜单改密入口 |
| 08-change-password-dialog.png | TC-09 改密弹窗 |
| 09-config-site-no-port-field.png | TC-11 死控件移除 |
| 10-config-oidc-callback-fixed.png | TC-12 OIDC 回调纠正 |
| 11-config-security-yaml-hint.png | TC-13 安全分区提示 |
| 12-config-p2p-env-hint.png | TC-14 P2P env 提示 |
| 13-storage-env-hint.png | TC-15 存储 env 提示 |
| 14-admin-files-english.png | TC-16 EN 零中文残留 |
| 15-change-password-success.png | TC-10 改密成功 toast |

## 九、遗留建议执行结果（2026-10-15 当日闭环，列车 1.25.0）

| 遗留建议 | 执行结果 |
|---|---|
| 1. 215/43 升级被网段阻塞 | **网段恢复，三台全部升级 1.25.0**：10.10.10.3（pull-mirror，探针全绿）；215（1.22.0→1.25.0，数据先备份 `/root/fcb-data-backup-1015.tgz`，入口 200/code:0/10002 实证）；43 k3s（**0.15.8→1.25.0 跨大版本**，helm upgrade chart 2.0.26，节点不可拉 ghcr 走 Mac arm64 `docker save`→`k3s ctr images import`，ingress NodePort 30409 实证 code:0/10002；踩 `--reuse-values` 复用旧 chart 默认 tag 的坑，改显式 values 重升） |
| 2. HTTP 语义镜像码收编（~160 处） | **已收编**（core v0.23.0，BREAKING）：400→10001、403→10003、404→10004、405→10009、409→10016、416→10001、422→20009、429→10005、500→10008、502/503→10006、401→10002/40007/20003，余 29 处 map 形态 200→0；HTTP 状态码全部不变。消费方同车对齐：前端 success 双码判断补齐（stores/View/NotifyBanner）、View 密码门 10003/10004 新旧兼容、分片重试兼容 20009（frontend-core v0.7.1）。本地探针实证：参数错误 `10001`/不存在 `10004`/错密码 `10002` |
| 3. smoke 断言家族补齐 | **已补**（46→49）：S9a2 文件分享铸 pickup_code、S9a3 文件取件 share_code 恒空（契约语义守卫——编写时曾误写为"应回传"，被本地实测纠正）、S10a2 select 带下载令牌；三条均本地实测通过 |
| 4. trainctl 裸奔 tag 守卫 | **已落地并实战生效**：①`bumpPRRepos` 补 server（根因——漏列致 open-PR 守卫对 server 失明）；②server 打 tag 前硬断言 go.mod 钉 core=lib.core（`serverCorePinOK`+单测）。1.25.0 发车实证：server PR #15 合并后才打 tag、v1.25.0 锚定 main、钉 core v0.23.0 |

**1.25.0 列车**：core v0.23.0（BREAKING 二波）/ frontend-core v0.7.1 / hub v1.25.0 Latest；verify 0 处不一致。三台主机终态统一 1.25.0。

> 附注：215 上尚有历史联邦测试残留容器 `filecodebox-p2p`（ghcr.io/pigeonbox/p2p:0.6.0，10-06 部署），与本次升级无关，留待用户决定去留。

## 十、四终端真机安装（1.25.0，2026-10-15 当日）

| 终端 | 设备/载体 | 旧版→新版 | 安装方式 | 验证 |
|---|---|---|---|---|
| qnap | 10.10.10.253（QTS 5.2.10 x86_64） | 1.20.0 → 1.25.0 | CLI：scp 后 `sudo sh *.qpkg` 原地升级 | 服务拉起、/ping 200、SPA 渲染、admin 登录 code:0 ✅ |
| openwrt | 10.10.30.250（iStoreOS 25.12.5 x86_64，apk 代际） | 1.14.2 → 1.25.0 | `apk add /tmp/*.apk`（受信签名，post-install 自动 restart） | 1.25.0-r0 就位、/ping 200、SPA、服务 running ✅ |
| fnos | 10.10.30.253（fnOS x86_64） | 1.14.0 → 1.25.0 | App Center GUI「手动安装→从 NAS 添加」（CLI `trim_app_center` 是无子命令的桩） | version.txt=1.25.0、/ping pong、数据目录保留 ✅ |
| desktop | 本机 Mac（aarch64） | 1.18.1 → 1.25.0 | dmg 覆盖 /Applications + 启动 | CFBundleShortVersionString=1.25.0、pigeonbox-desktop 进程运行 ✅ |

**过程发现与坑（记录在案）**：
1. **首装 qnap Abort 是下载截断**：`gh release download` 并行四包时一条 TCP 超时，qpkg 只落了 1.9MB（Release 实际 21MB）。设备安装器 Abort 是**正确防御**；今后下载必须核对 md5 侧车/资产尺寸后再装机。
2. release.yml 的结构断言 `tar -tzf | grep` 管道退出码只看 grep——截断包也能骗过（列表可读即绿）；建议补尺寸守卫（未实施，留待下波）。
3. fnos 文件选择树坑复现：单击只选中不进入，须坐标点行首「>」箭头展开后才见文件。
4. fnOS SSH 防爆破锁定窗口期注意：本轮全部合并为少量长会话操作，未触发。

**CodeConflict 常量引用收尾**：core main 已为 `CodeConflict = errcode.CodeConflict`（contracts v0.15.1 起生效，随 deps 仪式落地），过时的 v0.22.0 期临时注释已清理推送——"下个库版无历史包袱"即此状态，无需再动。

## 附录：本地受控栈验证配方（坑在案）

- server 入口是 `server/cmd/server`（非 main.go）；门禁两 env：`PB_SERVER_PORT` + `PB_JWT_SECRET`（全环境强制）。
- 残留进程会占 12355（`lsof -t -iTCP:12355` 清杀）；后台启动用绝对路径脚本（shell cwd 在子进程会被重置）。
- go.work 联编即测本地 core 工作区；`GOWORK=off` 则吃 go.mod 钉版（验旧版行为时反过来用）。
- helm `--reuse-values` 会复用旧 chart 的**默认值**（含旧镜像 tag）——跨 chart 大版本升级改用显式 values 文件。

## 十一、P2P 配置页重设计（用户反馈"难理解、不知道怎么用"，frontend-core v0.7.2 / 列车 1.25.1）

**原页问题**（用户截图反馈）：设备直传与跨站联邦两个独立功能挤在一页且无解释；两个"注册中心地址"并排出现归属不明；"口令公告熵门槛""节点密钥路径（Ed25519）"等服务端术语直接裸露；配完不知道下一步去哪操作。

**重设计**（信息架构重排，字段绑定与保存语义零变更）：
1. **页首双导航卡**：设备直传（推荐使用，附三步上手白话引导 + 直达操作页链接）/ 跨站联邦（进阶，一句白话说明"个人自用 NAS 一般无需开启"）。
2. **直传区块前置**：启用开关 → 发送白名单 → 收件目录 → 配额，常用字段一屏内；注册中心/名录发现/p2pc 路径收进「高级参数」折叠。
3. **联邦整段折叠**：默认收起，标题明示"多站点共享口令才需要"；熵门槛/节点密钥再收一层「高级参数（一般保持默认）」。
4. **术语白话化**（双语）：「口令公告熵门槛（位）」→「口令公告门槛：防猜保护，过于简单的口令不对外公告」；「Ed25519 节点身份…」→「⚠ 本站联邦身份文件：改动即更换身份，一般不要动」（危险色）。

**验证**：typecheck/124 单测/i18n parity 绿；本地栈 Playwright 实测——直传字段前置可见、联邦默认折叠、熵门槛不可见、展开交互正常（截图 assets/16、18）。

## 十二、设备直传控制台页重设计（用户反馈"不知道怎么用"，frontend-core v0.7.3 / 列车 1.25.2）

**原页问题**：不解释"对端是谁、要装什么、点完发生什么"；发送成功后**口令没有任何显著呈现**（只弹一行 toast，口令藏在任务表里）；发送路径要求手抄服务器内部路径（send_roots 白名单不可见）；"名录对端/密封邀请"术语无解释；任务表空态无引导。

**重设计**（操作逻辑零变更，纯呈现层）：
1. **顶部白话说明条**：本页=服务器直传操作台；对端只需桌面版（接收卡贴口令）或 p2pc 命令行，无需注册账号。
2. **白名单目录点选 chips**：从系统配置读取 send_roots 渲染为可点标签，点选即填入路径——不用手抄内部路径；未配置时给配置页直达链接。
3. **发送成功→口令结果框**（核心修复）：大号口令+复制按钮+有效期警示+对端两种接收指引（桌面版路径 / 可复制的 `p2pc recv <口令>` 命令）。口令由 p2pc 异步生成，前端轮询任务列表到口令出现再弹（创建时为空的时序修复）。
4. **接收卡白话说明**：对方发起后会给你 12 位口令，粘贴即收。
5. **任务表空态引导**：无任务时提示先上方发送/接收。

**验证**：typecheck/124 单测绿；本地栈真实 p2pc（v0.6.10 darwin-arm64）全流程实测——chip 点选填入→发起→口令 `1PKE-5C7R-40NR` 异步生成→结果框弹出（截图 assets/19）。

> 建议留待下波：发送路径的文件浏览器（在白名单目录内可视化选文件，免手输路径）。

## 十三、P2P 两页重设计的发版（1.25.1 / 1.25.2）

- **1.25.1 shipped**：含系统配置 P2P 页重设计（frontend-core v0.7.2）。过程波折两起，均按档案处置：①hub bump PR 因分支落后 main 卡 auto-merge（update-branch 后自愈）；②desktop Release 首跑 failure（windows job），重跑 --failed 后 12 资产齐。
- **1.25.2 shipped**：含设备直传控制台页重设计（frontend-core v0.7.3）。过程暴露一个**新的列车陷阱**：stale 本地 advance 把 origin/main 的 train.yaml 从 1.25.2/draft 回写成 1.25.1/tagged（覆盖了已合并的 bump），导致 verify 28 处「不一致」全是假象、重 bump 又被「1.25.1 仍在 tagged」守卫拦下。处置链：按守卫提示人工确认 1.25.1 弃单（产物实际已全发布，v1.25.1 Latest）→ state 记账改 shipped → 重跑 bump → 强推被残留的 train/1.25.2 分支 → PR 合并 → tag 全锚定 → shipped。**教训待固化**：advance 的本地写回在陈旧检出差条件下会污染远端账面，trainctl 宜加「本地 train.yaml 与 origin 分歧时禁写回」守卫（未实施）。

## 十四、真机跟进至 1.25.2（同日傍晚）

| 终端 | 状态 |
|---|---|
| desktop（本机 Mac） | ✅ 1.25.2（含 P2P 两页重设计） |
| 10.10.10.3 服务器 | ✅ 1.25.2（pull-mirror，双容器 healthy，code:0） |
| qnap 10.10.10.253 | ✅ 1.25.2（qpkg 原地升级，ping 200）。坑：scp 目标路径 `/tmp/` 会被 QTS 静默重写到失败，须传家目录（落地名=本地文件名）；首次安装中断会留僵尸 qpkg_cli + /tmp 清理窗口 |
| fnos 10.10.30.253 | 📦 1.25.2 fpk 已预置 `/vol1/1000/develop/pigeonbox-v1.25.2.fpk`（应用中心两击可升；浏览器被用户会话占用故未代操作） |
| openwrt 10.10.30.250 | ⏸ 停留 1.25.0：本机到该设备的传输路径持续超时/停滞（scp 与 ssh stdin 均中断，1.25.2 包 16MB 只能传 ~400KB），设备 SSH 防护伴随限连。包已备好，待网络恢复后 `apk add` 即可 |
