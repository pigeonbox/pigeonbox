# P2P 对称节点融合设计方案

- 日期:2026-10-14
- 状态:设计定稿待评审
- 涉及仓:p2p / core / server / frontend-core / fnos / qnap / openwrt / charts / hub(trainctl)
- 前置文档:`docs/specs/2026-10-04-p2p-registry-service-design.md`(工作区级,联邦 M2)

## 0. 结论摘要

把 p2pc 设备直传能力以**随附二进制 + 进程内 supervisor**的方式融合进每一个 PigeonBox 发行物,使**每台 server 实例天然成为一个对称 P2P 节点**(既能发也能收),由 admin 后台统一开关与操作;现有 federation(联邦注册客户端)同期收进同一后台配置分区并支持运行时热启停。分两阶段交付:

- **P1 — 联邦进后台**:SystemConfig 新增 `p2p` 指针段(含 `federation` 子结构),admin 配置页新增「P2P」分区;federation 装配可重入化,开关保存即热启停。
- **P2 — 直传对等节点**:每个发行物内嵌 p2pc 二进制(Docker 镜像 / fpk / QPKG / ipk / desktop 已有);core 新增直传 supervisor 域(spawn p2pc、解析输出、kill 取消、配额与孤儿防护);admin 新增「设备直传」操作页;MCP/CLI 复用同一服务层。

核心原则:**控制面留进程内(federation=轻量 HTTP 客户端),数据面走子进程(p2pc=QUIC/打洞/大文件)**;**口令即授权**,实例间无需预建信任;**standalone 专属能力**,多副本模式强制禁用。

## 1. 背景与目标

现状:p2pc(设备直传,PAKE+打洞+QUIC+断点续传)是 p2p 仓的纯 CLI 参考客户端,仅以 Tauri sidecar 形式随 desktop 分发;server 及各 NAS 终端不具备直传能力。federation(联邦注册客户端)在 core 内是启动期一次性装配,只能 yaml/env 配置,管理后台不可见。

目标:

1. 每个 PigeonBox 发行物(server 镜像、fnos、qnap、openwrt、desktop)都具备口令直传能力,任意两台实例可互传文件;
2. 管理后台统一配置与操作(开关、参数、发起/接收、任务状态);
3. 不向普通用户面扩散(本期 admin-only);
4. 不推翻现有发布列车、配置体系、打包线。

## 2. 验证事实(2026-10-14 实测/对码)

设计依据的关键事实,全部已核实:

| # | 事实 | 证据 |
|---|---|---|
| 1 | 公共 p2pd 入口 `home.enjoye.top`:56788=信令+UDP 反射,**56787=加密中继且公网 OPEN**;`/health` 返回 `{"relay_port":56787,...}` | 10.10.10.3 `/opt/pigeonbox-p2p/docker-compose.yml` + 公网探测 |
| 2 | 12347 仅是**本地兼容映射**(`12347:56787`),公网未转;新客户端经 `/health` 自发现 relay_port(p2p 480a184 起),不依赖 12347 | 同上;`p2p/internal/client/client.go:134-140` |
| 3 | p2pc CLI 已自动化就绪:`recv --yes`、`--registry/--relay/--key/--out/--code/--quiet`;口令以 `口令: XXX-…` 单行输出 | `p2p/cmd/p2pc/main.go` usage |
| 4 | p2pc send 对端未接入时**阻塞 10 分钟**后报错退出(非无限等待) | `p2p/internal/client/client.go:512` joinChannel 10min |
| 5 | 口令熵 60 bit(Crockford base32 去 I/L/O/U,12 位 4-4-4) | `p2p/internal/client/client.go:101-116` |
| 6 | p2p CI 已发布 p2pc **6 平台二进制**到 GitHub Release(Tauri triple 命名 + checksums.txt),并回挂 hub `p2p-$TAG` | `p2p/.github/workflows/release.yml:58-130` |
| 7 | p2pd 三控制面端点**已有限流**(register/announce 2/s,resolve 1/s + per-hash 10/s) | `p2p/internal/server/middleware.go`、`server.go:97-130` |
| 8 | p2pc 二进制体积 8.7MB(strip+trimpath 实测) | 本地编译 |
| 9 | core 现无任何 p2p 依赖;federation 自写 registry HTTP 契约;`internal/client` 外部不可 import | `core/go.mod`、`core/app/federation/client.go` |
| 10 | SystemConfig 指针段=自由 JSON,**新增配置段零 IDL 改动**;overlay 热生效先例齐全(含 UploadEx 保 LocalImport 特例) | `contracts/idl/admin.thrift:145-147`、`core/app/config/service.go:329-362` |
| 11 | chart 注入 `PB_FEDERATION_ENABLED` 是 **values 门控**(`p2p.enabled`,默认 false),非无条件 | `charts/…/templates/_server.tpl:57,214-224` |
| 12 | 多副本强制关 federation 先例:`applyDeploymentConstraints` 非 standalone 无条件置 false + Warn | `core/bootstrap/deployment.go:55-82` |
| 13 | train.yaml 有 `lib.p2p: v0.6.1`;p2pc 钉版机制**仅 desktop 有**(`terminal.desktop.p2pc`→`P2PC_REF`),其余终端缺 | `PigeonBox/release/train.yaml:11,22`、`trainctl/trainfile.go:150-155` |
| 14 | server Dockerfile 两阶段(alpine);fnos/qnap/openwrt 打包点已逐一定位(见 §10) | 各仓 Dockerfile/打包脚本 |

修正两条此前的过时认知(留档防再犯):AGENTS.md「12347 未转=公网直传缺口」记载已过时(事实 2);「p2pc send 无限等待」不成立(事实 4)。

## 3. 总体架构:对称节点模型

### 3.1 节点语义

p2pc 协议模型里没有常驻监听的"服务端":两端都主动拨号到注册中心汇合(注册+公告/resolve+WS 信令),PAKE 认证后打洞(失败自动回落中继,先通后优),AEAD 帧直传。因此"让每台 server 成为服务端"不需要新角色——**每个发行物内嵌 p2pc + 每个实例开同一个 admin 开关 = 每台实例成为对称节点**:

- 发送:admin 选本地路径(白名单内)→ spawn `p2pc send` → 面板即时显示口令与等待态;**口令交接窗口≈10 分钟**(p2pc 配对超时,超时任务失败重新发起即可)——适合 IM/电话即时交接,面板需醒目提示倒计时语义;
- 接收:admin 输口令 → spawn `p2pc recv --yes` → 文件直落收件暂存区 → 可一键"发布为分享"或落指定目录;
- 反向完全对称;外部依赖仅双方可达的 p2pd 注册中心(默认公共官方 `home.enjoye.top:56788`,可自建,与联邦共用 registry 配置)。

### 3.2 控制面/数据面分离(架构原则)

| 面 | 能力 | 形态 | 理由 |
|---|---|---|---|
| 控制面 | 联邦注册/公告/resolve | **进程内**(现有 federation 域,轻量 HTTP) | 需与 share 生命周期挂钩、取件同步 resolve,延迟敏感 |
| 数据面 | 设备直传 | **子进程**(spawn p2pc,kill 即取消) | QUIC/UDP 打洞/大文件 IO;崩溃隔离(OOM/panic 不连坐持有 DB/JWT 的 server);取消语义天然;协议演进(v4→v5)只换二进制,server 不动 |

### 3.3 授权与信任

口令即授权:12 位/60 bit/Crockford base32、PAKE 派生密钥、单次有效(announce 15 分钟过期)、无口令无法连接。实例间**无需预建信任**;联邦关系是可选增强(留位见 §14)。注册中心不可信(只做 rendezvous):保密性由 PAKE+证书指纹钉定保证,恶意注册中心只能拒绝服务,不能窃听。

## 4. 方案选型与决策记录

| 决策 | 选择 | 否决项与理由 |
|---|---|---|
| D1 p2pc 进主程序的方式 | **随附二进制**(每发行物带 p2pc,进程内 supervisor spawn) | 库式内嵌(p2p 开公开包):消费的是**未定型的 Go API**(internal/client,wire v4 刚破还在演进)而非已稳定的 CLI 契约;阻塞无 ctx 的传输加取消=高风险改造;QUIC/大文件 IO 进 server 进程失去崩溃隔离;协议破坏性升级拖全列车。契约复制(federation 模式):直传协议(PAKE/打洞/多流)复制成本极高,否决 |
| D2 触发面 | **admin 操作页为主**,服务层独立成域供 MCP/CLI 复用;普通用户不可见 | 普通用户可用:权限面扩大,本期不做 |
| D3 配置落点 | **SystemConfig 新增指针段 `p2p`**(零 IDL 改动,热生效);env/yaml 仅作首启默认 | 纯 env/yaml:后台不可见,与目标矛盾 |
| D4 env vs DB 优先级 | **DB overlay 赢**;env/yaml 种子=DB 无记录时的首启默认(存量部署行为零变化);admin 页显示生效值+来源 | env 永远赢:chart/values 门控注入存在,开关在部分部署下会失效 |
| D5 生效范围 | **standalone 专属**;public×N / admin×N 强制禁(沿 federation 先例),admin API 拒绝+前端 hint | 多副本下节点身份/任务态语义未定义 |
| D6 发送路径白名单 | 独立配置 `send_roots`,**仿 local_import 三层防穿越校验**(绝对路径+禁 `..`+EvalSymlinks 归一);空=拒绝所有发送(安全缺省) | 复用 local_import roots:两功能语义不同,耦合配置更糟 |

## 5. 配置模型

SystemConfig 新增一个顶层指针段 `p2p`(指针段语义:body 未携带=保留现状,局部 PUT 不冲其他段):

```
p2p: {
  // —— 直传(P2)——
  enabled:        *bool     // 直传能力总开关,缺省 false
  registry_url:   *string   // p2pd 基址,缺省 "" = 公共官方 home.enjoye.top:56788
  relay_addr:     *string   // 显式中继,缺省 "" = 经 /health 自发现
  send_roots:     []string  // 发送路径白名单,缺省 [] = 拒绝所有发送
  recv_dir:       *string   // 收件暂存目录,缺省 <data>/p2p-inbox
  max_task_bytes: *int64    // 单任务字节上限,缺省 50 GiB
  inbox_quota_bytes: *int64 // 暂存区总配额,缺省 200 GiB
  binary_path:    *string   // p2pc 路径,缺省 "" = 按查找序(见 §7.1)
  // —— 联邦(P1)——
  federation: {
    enabled:              *bool    // overlay → conf.Federation.Enabled
    registry_url:         *string
    public_url:           *string
    node_key_path:        *string
    announce_min_entropy: *int
  }
}
```

优先级(全链):启动期 env/yaml → 代码缺省;DB(SystemConfig)overlay 其上;运行期以后台保存为准。`applySystemConfigOverlayLocked` 新增 `p2p` 分支映射到 `g.Federation`(直传参数只被 supervisor 域消费,不进全局 conf 的联邦结构)。校验规则:`validateSystemConfig` 新增——registry_url/relay_addr 仅允许 http/https 与 host:port 形态;send_roots 绝对路径+禁 `..`;binary_path 存在性由 supervisor 运行期探测(配置期不报错,面板显示可用性)。

env 对应:`PB_P2P_ENABLED` 等仅作首启种子,不再新增长表(以后台为主);federation 现有 env 键保留语义不变(首启种子)。

## 6. P1:federation 进 admin 后台(热启停)

1. **装配可重入化**:`bootstrap/wiring.go:161-179` 抽成 `assembleFederation()/stopFederation()`,mutex 保护;`federationSvcInstance` 包级 var 的读写全部加锁;停止时三个注入点反向摘除(`shareSvc.SetFederationNotifier(nil)`、`adminApp` 同、`customHandler.SetFederationService(nil)`、MCP adapter 置空)。
2. **热生效接线**:config 域 `ReconfigureHooks`(OIDC 热重建先例)注册 federation hook——保存 `p2p.federation` 段 → stop 旧 → assemble 新 → 重挂注入点。校验失败不落半态(先装配新实例成功再停旧,失败回滚)。
3. **约束门**:hook 内检查 `ServesStandalone()`;非 standalone 直接拒绝(错误文案明确),前端分区显示"多副本部署禁用"hint(仿 redis/transfer 门禁只读先例)。
4. **行为兼容**:DB 无 `p2p` 段的存量部署走首启种子,与今日完全一致;`deployment.go` 对 env 种子的强制关闭逻辑保持在 overlay 之前执行。
5. **前端**:配置页新增第 7 分区 `p2p`(设备直传与联邦);P1 只上联邦子段(开关+registry_url+public_url+熵门槛)+ 生效值/来源展示;`fetchExSections` 旧库 null 归一。

## 7. P2:直传 supervisor 域(core/app/p2px)

### 7.1 二进制定位与随包

查找序:`binary_path` 配置 → `PB_P2PC_PATH` env → 内置候选(`可执行文件同目录/p2pc`、`/usr/bin/p2pc`、`./p2pc`)。各打包线在服务脚本/镜像里把 p2pc 放进候选位(见 §10),终端无需配置。探测不到 → 域标记 unavailable,操作页显示"未找到 p2pc 二进制"引导态(仿 LocalFiles 未启用态),**不影响主服务**。

### 7.2 任务模型

```
Task{ID, Kind(send|recv), State(created|waiting|running|done|failed|canceled|expired),
     Code, Roots/Paths | RecvDir, BytesDone, FilesDone/Total, Pid,
     CreatedAt, StartedAt, EndedAt, Err}
```

- 内存态 + 审计日志;重启后未完成任务标 `expired`(不留僵尸态)。
- **并发上限**(缺省 2,NAS 资源友好);超出排队。
- **spawn**:`exec.CommandContext` + `Setpgid`(进程组);取消= kill 进程组(含孙进程)。
- **输出解析**:stdout 抓 `口令:` 行 → 任务进 waiting;stderr 逐行进任务日志(**原样透传**,协议版本不一致等 p2pc 文案直接可见);退出码定成败。解析器用 CI 断言锁 p2pc 输出格式(同列车变更);`--json` NDJSON 结构化输出作为 p2p 仓**可选增量**(P2b,见 §14)。
- **超时**:不自设任务级超时——p2pc 自身语义即真相(配对等待 10 分钟超时;传输中按帧 deadline)。supervisor 以进程退出为任务终态,避免双套超时打架。

### 7.3 防护(服务端特有)

| 风险 | 对策 |
|---|---|
| 接收磁盘耗尽(对端谎报/超量) | spawn 前查磁盘剩余;运行中 ticker 监控暂存区+任务落盘字节,超 `max_task_bytes`/总配额 → kill 任务 + 标 failed(不依赖 p2p 仓改动) |
| 发送任意文件读 | `send_roots` 白名单,校验仿 `app/share/localfiles.go:31-64` 三层(绝对/禁 `..`/EvalSymlinks 归一);空集拒绝 |
| 孤儿进程(server 崩溃/看门狗击杀) | Setpgid 进程组 + 关机 Cleanup 先杀子进程再停 DB(`bootstrap.Cleanup` 现序前插);启动清扫:标记遗留任务 expired;Linux 上子进程设 parent-death 感知(不可用则靠进程组继承死亡) |
| 暂存区堆积 | 1h ticker 清理(仿 `tasks.go:19-33`):超期(缺省 7 天)且未发布文件删除 |
| 恶意内容落地 | 暂存区独立目录;发布为分享时过现有 moderation 钩子(若启用) |

### 7.4 收件语义

recv 落 `recv_dir`(暂存区),任务完成后 admin 操作页出现收件任务:可**发布为分享**(走现有 share 铸造链,生成取件码进正常分享流)或**确认落目录**(仅限暂存区内子路径)。发布动作记审计。

### 7.5 可观测与通知

- 任务事件(创建/配对/完成/失败/取消)进 admin 审计;关键计数打 Prometheus(`PB_METRICS_ENABLED` 既有开关):任务总数/成败/在传字节。
- 完成/失败通知:复用 notify 域 `CreateForUserSimple`(站内信+webhook+SMTP 一站式),发给 admin 用户——异步传输的天然配套。

## 8. admin 面板与 i18n(frontend-core)

1. **配置页** `Config.vue`:第 7 分区 `p2p`(SECTION_IDS/navItems/表单块/saveCurrent 分支四处接线);P1 上联邦子段,P2 上直传参数子段(开关/registry/roots/暂存目录/配额);i18n zh+en 双文件同步(行号对齐惯例)。
2. **操作页** 新增 `views/admin/P2pTransfer.vue`(路由 `/admin/p2p`,侧栏入口):上半=发送(选路径[roots 内浏览]/发起/口令展示+复制/等待态),下半=接收(口令输入/发起/收件任务列表/发布为分享),中部=任务列表(状态/进度/取消/日志展开)。未启用/未探测到二进制 → 引导态。
3. PublicConfig 与普通用户面**零改动**。

## 9. MCP / CLI 复用

supervisor 域独立成服务层后,MCP 工具为薄包装(P2b):`p2p_status`(可用性/registry/在传任务)、`p2p_send`、`p2p_recv`、任务列表;沿 `federation_status` 先例接线,受 `mcp.allow_guest` 三级作用域约束(缺省 admin-only)。pb CLI 同理留位。**本期不实现,只保证服务层接口按可被工具消费的形态设计**(方法收窄、ctx 贯穿)。

## 10. 打包与发版列车

### 10.1 各线落点

| 线 | 改动 | p2pc 落位 |
|---|---|---|
| server 镜像 | CI 按 train 钉版从 p2p Releases 下载 `p2pc-<triple>` + 校验 checksums → 构建上下文 → Dockerfile Stage2 `COPY` 进 `/app/p2pc`;镜像 +8.7MB | `/app/p2pc`(server 二进制同目录,命中候选序) |
| fnos fpk | `scripts/build-native.sh` 下载双架构 p2pc → `fnos/fnos/app/bin/p2pc-linux-{arch}`;`cmd/main` arch 分支设 `PB_P2PC_PATH` | `app/bin/`(装机后 `target/bin/`) |
| qnap QPKG | `build-native.sh`/`build-qpkg.sh` 加 `qpkg/{x86_64,arm_64}/bin/p2pc-linux-{arch}`;`pigeonbox.sh` 服务脚本设 env | `qpkg/<arch>/bin/` |
| openwrt ipk/apk | `release.yml` 矩阵下载 → `build-ipk.sh` 数据树加 `usr/bin/p2pc`(init 脚本导出 `PB_P2PC_PATH`) | `/usr/bin/p2pc`;包体 +8.7MB(仅 x86_64/aarch64 目标,可接受) |
| desktop | **已具备**(sidecar),零改动;desktop↔server 同 wire 可互通=留位扩展 | 现状 |
| synology/ugreen/terramaster | 走 server 镜像,自动覆盖 | 镜像内 |

### 10.2 列车扩展(trainctl)

`lib.p2p` 已是版本真相源;扩展 `trainfile.go`/`bump.go`/`verify.go`:p2pc 钉版键下沉到 server/fnos/qnap/openwrt 的 DEPS(仿 `terminal.desktop.p2pc`→`P2PC_REF` 机制,如 `P2PC_REF`),打包脚本从 DEPS 读取下载;verify 对账「发行物内 p2pc 版本 == lib.p2p」。p2p 仓 wire 破坏性升级时全终端随列车同升(与 desktop sidecar 现行纪律一致)。

### 10.3 供应链

下载即校验 `p2pc-checksums.txt`(sha256);资产来源钉 Release 资产 URL(与 frontend-core tgz 钉版同一纪律)。

## 11. 安全、审计与部署约束

- 全部 admin-only(独立于普通用户面);操作走 admin 审计;错误文案原样透传(协议版本不一致引导双方升级)。
- registry/relay 可自建可替换;公共官方入口为缺省兜底。**运营侧前置**:公共中继(56787)已通但需流量策略(单任务限速/容量监控)——运营事项,非代码;部署实例镜像 tag 当前 `dev`,功能发布前对齐 Release tag。
- `applyDeploymentConstraints` 扩展:非 standalone 强制 `p2p.enabled=false`(与 federation 同款 Warn);admin API 在非 standalone 下拒绝启停请求。

## 12. 错误处理原则

1. 子系统失败不连坐主服务:supervisor 初始化失败/二进制缺失 = 功能降级 + 面板可见,server 正常运行。
2. p2pc 的 stderr/退出码是唯一真相源,supervisor 不重写错误语义,只结构化呈现。
3. 热启停原子性:新实例装配失败回滚旧实例;半态不可见。
4. 断链响亮:train verify、checksum 校验、发布物版本断言失败即红,不吞。
5. **配置值≠运行态必须响亮**(评审 P1-1 修订):federation 热切换失败(装配失败/多副本拒绝/public_url 不可推断)时,UpdateConfig 把错误透传给管理员(保存请求 500+原因),审计记失败——禁止"保存成功但联邦从未启动"式静默。启动期失败以非联邦模式运行+响亮日志。
6. **缺省语义后端兜底**(评审 P0-1 修订):registry_url 留空=官方公共注册中心(`http://home.enjoye.top:56788`)、public_url 留空=站点对外地址(server.base_url)在 fedRT.apply 统一实现——界面提示与后端行为必须一致;推断结果为 0.0.0.0/空时响亮拒绝(不可达取件链接即事故)。同配置重复保存短路,不触发 deregister/register 抖动。

## 13. 测试策略

- **单测**(core):supervisor 用假 p2pc(脚本化 stdout/退出码的 stub 二进制)覆盖任务状态机/超时/取消/配额 kill/孤儿清扫;config 段校验与 overlay;federation 热启停并发安全(-race)。
- **CI 集成**:进程内 fixture registry(p2p `client_test.go:35 newFixture` 先例 + p2pcweb e2e 先例)起最小 p2pd,强制 `--no-punch` 走中继,真实 p2pc 双进程互传小文件断言;解析器格式锁断言。
- **真机双实例**:10.10.10.3 ↔ fnos 真机(或 215)各开开关,A 发 B 收 + 反向;打洞成功与中继回退两路径;协议版本不一致报错呈现。
- **回归**:存量部署(DB 无 p2p 段)行为与今日逐字节一致;chart values 门控行为不变。

## 14. 明确不做与留位

| 项 | 说明 |
|---|---|
| 联邦实例间推送(P3) | 已有联邦关系的实例,发送方经联邦通道推"传输邀请",对端审批即收——免口令交接,自动化同步的前提。本期不做,**自动化备份同步场景本期不承诺**(口令交接是人工的) |
| 普通用户直传面 | 权限模型另议 |
| desktop↔server 直传 | 同 wire 天然可通,后续零协议成本扩展 |
| p2pc `--json` 输出 | p2p 仓可选增量(NDJSON 事件流),先以行解析+CI 格式锁交付 |
| MCP/CLI 工具 | 服务层预留,工具实现为 P2b 薄包装 |

## 15. 风险与运营前置清单

1. **公共中继带宽**:打洞失败流量全走 56787(已实测公网可达)。运营策略:自建 p2pd 引导(文档+配置面板提示)+ 公共中继流量监控;必要时限速。**发布前置项**。
2. **混合版本舰队**:wire 破坏性升级窗口内两台实例不同版=传输失败;报错原样透传 + 文档升级指引;全终端随列车收敛。
3. **口令交接窗口≈10 分钟**:p2pc 配对超时内未接入即失败(事实 4)。面板醒目提示;若实测交接体验差,p2p 仓可加 `--wait-timeout` flag(非破坏增量,留位)。
4. **打包面工作量**:四条打包线+trainctl 扩展,机械但面广;desktop 机制可直接类比。
5. **AGENTS.md 端口记载勘误**:「12347 未转=公网直传缺口」过时,实施时顺手更新。
6. 部署实例 `PB_IMAGE_TAG=dev` 对齐 Release tag(运营项)。

## 16. 分期与工作量概估

| 期 | 内容 | 仓 |
|---|---|---|
| P1 | SystemConfig.p2p 段(federation 子段)+ overlay/校验;wiring 可重入化 + ReconfigureHooks;配置页第 7 分区;单测 | core / frontend-core |
| P2a | ~~supervisor 域(任务/防护/通知/审计);操作页;server 镜像随包;deployment 约束;单测+CI 集成~~ **✅ 2026-10-14 完成**(含发布链 Internal 旁路、真互传 E2E sha256 一致) | core / frontend-core / server |
| P2b | fnos/qnap/openwrt 打包随包;trainctl p2pc 钉版扩展+verify;MCP 薄工具;真机双实例验证;文档(usage/ENVIRONMENT/AGENTS 勘误) | fnos / qnap / openwrt / hub / docs |
| P3(留位) | 联邦推送邀请/自动化同步;`--json` 输出 | core / p2p |
