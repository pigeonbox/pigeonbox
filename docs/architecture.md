# PigeonBox 架构文档

> 装配仓的架构总览:生态全景、仓库依赖、core 内部分层、运行时请求流、数据流、部署形态与发布流水线。
> 所有图均为 Mermaid,GitHub 与文档站(pigeonbox.github.io)均原生渲染。版本与仓库角色速查见 [README](../README.md)。

---

## 1. 生态全景

```mermaid
graph TB
    USER["👤 自托管用户"] -->|"compose / Helm"| DELIVER
    NASU["🏠 NAS / 路由器用户"] -->|"原生包一键安装"| NASFORM
    DEV["👨‍💻 开发者"] -->|"git clone + make setup"| UMB

    subgraph ORG["pigeonbox 组织"]
        UMB["📁 pigeonbox<br/>装配仓 · make setup 拉齐工作区"]

        subgraph DELIVER["交付形态(独立发版)"]
            SRV["🚀 server<br/>部署应用 v1.22.0"]
            FE["🖥️ frontend<br/>前端壳 v1.22.0"]
            FEC["🎨 frontend-core<br/>公共前端 core v0.5.0"]
        end

        subgraph NASFORM["NAS 原生形态(随包 p2pc)"]
            FNOS["🐂 fnos<br/>飞牛 fnOS 原生应用 v1.22.0"]
            OWRT["📡 openwrt<br/>OpenWrt/iStoreOS 原生包 v1.22.0"]
            QNAP["🗄️ qnap<br/>威联通 QTS 原生应用 v1.22.0"]
            NAS3["📦 NAS 打包三仓 v1.22.0<br/>synology · ugreen · terramaster"]
        end

        subgraph BASE["基础层(被各形态复用)"]
            CORE["🧩 core<br/>业务核心库 v0.20.0"]
            CT["📦 contracts<br/>契约层 v0.18.4"]
            P2P["🕸️ p2p<br/>联邦注册中心 + p2pc v0.6.3"]
            KIT["🧰 kit<br/>共享 Go 工具库 v0.3.1"]
        end

        subgraph TOOLS["工具与客户端"]
            DESK["💻 desktop<br/>Tauri 客户端 desktop-v1.22.0"]
            CHT["☸️ charts<br/>Helm Chart 2.0.19"]
        end
    end

    %% 隐形链只用于排版: 把四组竖向堆叠(它们彼此并行, 无先后关系)
    DELIVER ~~~ NASFORM ~~~ BASE ~~~ TOOLS
    UMB -.->|"setup.sh 拉取"| DELIVER & NASFORM & BASE & TOOLS
    DESK -.->|"HTTP API 连接任意服务器"| DELIVER
    CHT -.->|"Helm 编排前后端分离栈"| DELIVER
```

> 图只画**结构**(谁依赖谁、谁发什么形态);各仓版本与细节见 §2.3 版本矩阵。
> NAS 打包三仓(synology/ugreen/terramaster)只出 compose 壳与官方镜像,不打 Go 代码。

**职责边界**:装配仓不含业务代码,只提供工作区装配(`setup.sh`/`go.work`/`Makefile`/`docker-compose.yml`)、发布列车(`release/train.yaml` + `make train-*`)与文档站;十三个模块仓库(经 setup.sh 拉取,含 NAS 打包四仓 synology/qnap/ugreen/terramaster——其中 qnap 已切原生 QPKG 含 Go 代码,其余三仓为纯 shell compose 壳)与 desktop(桌面客户端,Rust 项目不入 go.work)、charts(Helm Chart)两个产物仓独立开发、独立 CI、独立发版。

---

## 2. 仓库依赖关系

### 2.1 依赖图(构建期,单向无环)

```mermaid
graph LR
    subgraph FEW["前端(2026-10-09 拆分双仓)"]
        FES["frontend(壳)<br/>neutral 产物"]
        FEC["frontend-core<br/>平台无关应用 + 宿主适配器 SPI"]
        FES -->|"Release 源码 tgz 钉版"| FEC
    end
    PW["fnos/web · qnap/web<br/>(平台宿主适配器,归平台仓)"] -->|"Release 源码 tgz 钉版"| FEC
    OWW["openwrt/web<br/>(无适配器,纯 neutral)"] -->|"Release 源码 tgz 钉版"| FEC
    FEC -->|"@pigeonbox/contracts tgz<br/>(IDL 生成 TS d.ts,wire 契约类型)"| CTX["contracts"]
    FEC -.->|"/openapi.json 运行时规范<br/>(swagger 页直连后端)"| SRV["server"]
    SRV -->|"require v0.20.0"| CORE["core"]
    FNOS["fnos"] -->|"require v0.20.0<br/>库式调用 bootstrap"| CORE
    OWRT["openwrt"] -->|"require v0.20.0<br/>库式调用 bootstrap"| CORE
    QNAPG["qnap"] -->|"require v0.20.0<br/>库式调用 bootstrap"| CORE
    CORE -->|"require v0.14.0"| CTX
    P2P["p2p<br/>(联邦注册中心 + p2pc)"]
    CORE -.->|"core v0.8.0 起 federation 域为 p2p 客户端<br/>v0.19.0 起 server=对称节点(热启停)"| P2P
    FNOS -.->|"打包期按钉版拉取 p2pc 二进制<br/>(P2PC_REF,零 Go 依赖)"| P2P
    OWRT -.-> P2P
    QNAPG -.-> P2P
    KIT["kit<br/>(共享 Go 工具库)"]
    CORE -->|"17 处接入(httpjson/retry/<br/>uidgen/async/singleflight 等)"| KIT
    P2P -->|"ratelimit/version 已接入"| KIT

    classDef plain fill:#eef,stroke:#88a
    class CTX,CORE,SRV,FES,FEC,FNOS,OWRT,QNAPG,P2P,KIT plain
```

desktop 不进 go.work(Rust 项目),经 HTTP API 连接任意 PigeonBox 服务器,无构建期依赖;（2026-10-22 Wave B':desktop 已摘 p2pc sidecar,回归纯客户端;设备直传由独立应用 PigeonBeam 提供）。

> 图中钉版为 1.22.0 列车(`release/train.yaml`)声明值,由 `make train-bump` 统一写入各仓 go.mod/VERSION/manifest——禁止绕过列车手改钉版(见 §7)。

### 2.2 依赖规则(CI 强制守护)

| 规则 | 守护方式 |
|------|---------|
| contracts 零项目内依赖(纯类型,仅 thrift runtime + 标准库) | contracts CI:`go list -deps` 检查 |
| kit 零生态依赖(禁 import 任何兄弟模块);p2p 业务链零依赖(kit 地基层放行;p2pc 二进制的反向分发属**打包期钉版**——**仅 NAS 三端** fnos/qnap/openwrt `DEPS.env P2PC_REF`,不产生 Go 依赖) | kit / p2p CI dep guard:`go list -deps` 检查 |
| core 不许 import server / frontend / fnos | core CI 同上 |
| server / fnos 只经 go.mod 正式版本引用 core,**零 replace** | 各仓 go.mod 无 replace(本地联编由本仓 go.work 承担) |
| frontend wire 契约类型经 `@pigeonbox/contracts`(contracts IDL 生成的 TS d.ts,Release tgz 资产依赖);运行时 `/openapi.json` 仍是 API 规范真相源,快照不维护 | contracts CI `--check` 对账生成物;swagger 页与 vite 代理均直连后端同源(2026-10-04 移除漂移快照) |
| frontend-core 平台无关:源码禁引任何宿主 SDK,运行时依赖精确钉版随 tgz 传递解析;**宿主适配器归各平台仓 `web/`**(fnos/qnap),新增平台零改动 frontend-core | frontend-core CI 平台零容忍守卫(依赖清单/源码扫描/neutral 产物扫描);壳仓 CI 平台代码隔离扫描 |

### 2.3 版本矩阵

| 仓库 | 当前版本 | 说明 |
|------|---------|------|
| contracts | v0.18.5 | thrift v0.13 生成代码,版本约束以 require 传递(下游零 replace);IDL 真相源 `idl/`,前端 TS 类型经 `cmd/gen-ts` → Release tgz;**v0.14.0=P2PPublicService(联邦推送邀请公开收件)+AdminP2PService 扩九端点;v0.13.0=AdminP2PService 六端点(idl/p2p.thrift,设备直传管理面)**;**v0.10.x=admin 面 IDL 化(admin.thrift:管理面 20 端点+local-files/设置测试/审计日志收编契约)**;v0.9.0=寄件码域 IDL 化(request.thrift)+用户分享组/notify mine 契约增量;另有 `cmd/gen-openapi`(IDL→openapi.json,core embed) |
| core | v0.31.9 | 17 域服务(含 config 系统配置中心;2026-10-22 Wave B' 删设备直传编排域);**v0.20.0=P3 联邦实例间推送邀请(公开收件 `POST /api/v1/p2p/invite` + admin 待收/认领/推送三端点,口令=bearer 信任级同手工交接;AdminP2PService 扩至九端点)**;**v0.19.0=P2P 对称节点融合:federation 收进 SystemConfig `p2p` 指针段+运行时热启停(先立后破/回滚维持原状),新增 p2px 域(standalone 专属,spawn p2pc 子进程做数据面)+AdminP2PService 六端点+MCP 直传四工具**;**v0.17~v0.18=秒传去重 D1(同用户内同 hash+size 命中免落盘直接出码+删除引用计数保护,宁泄漏勿误删)+上游缺口五件(下载文件名 ASCII 兜底/文件备注 note/先出码占位分享+presign 回填/自定义 admin 路径/暗色模式)+MCP 扩 19 工具(含访客三级作用域)**;**v0.16.x=dao 去全局化收官(方案B 全域注入):dao 构造必填 \*gorm.DB,全局回退/懒加载/包级 init 全退役,域服务单例 InitDefault 化;admin 残留手写面 IDL 化收官(local-files/设置测试/审计日志六端点迁 gen 链);架构棘轮守卫规则 9/10(dao 显式构造防回潮+全局 DB 句柄只减不增)**;v0.15.2=管理面 20 handler IDL 化收编+**presign→share 跨域边消解**(baseurl 下沉 pkg/baseurl+窄类型+装配点适配器);v0.15.1=架构治理波(存储注册表化+取件闸门统一 pkg/gate.CheckPickup+单例收编+棘轮规则 7/8)+**SystemConfig 独立成 app/config 域**(脱离 admin 上帝域)+秒传检索 P1 修复(GetByHashAndSize 过期遮蔽);**v0.15.0=寄件码域 IDL 化收编(gen/router/request)+文本分享与文件分享同权铸造 6 位取件码(文本取件链路)+页脚管理入口缺省展示(show_admin_addr 改 *bool)+依赖地板抬升(x/net v0.60.0/toolchain 1.26.9)**;**v0.14.0=单机内存模式(redis.host 空=进程内 KV,回源 DB+负缓存防穿透;public/admin 缺 Redis fail-fast)**;v0.13.0=PB_DEPLOY_MODE 三模式部署拆分(standalone/public×N/admin×1,Redis 配置广播)+回收站;v0.14.9=env 前缀 FCB_→PB_ 全量更名+存储洞察/孤儿清理幽灵端点补实现(/admin/storage/insights·clean-presign-orphans)+两波攻击面加固(HSTS 三态/presign Complete 后重放覆盖/分片数硬上限/OIDC 封禁拒发/IdentityFresh 身份复核);v0.14.8=取件历史双修复(分页 total 失真+6位码通道补记取件人与到件通知——此前仅 8位码链路记录)+取件码大小写折叠(download.code_case_insensitive 默认开);v0.11.x=HttpOnly Cookie 会话(CSRF 头门禁)+审计清欠+攻击面收缩;v0.10.0=全面安全审计加固(管理面/chunk 链路/JWT 纪元·封禁改密即时失效/纵深防御);v0.9.0=federation M4(registry 多主备 failover+心跳短退避);v0.8.x=federation 接入+kit 化;v0.7.x=API Token/多文件+zip/OIDC/寄件码/运行时 OpenAPI |
| frontend | v3.3.9(随列车产品号) | 前端壳(2026-10-09 拆分双仓):只做 **neutral 产物**(零平台代码,供 server/docker 镜像)+dev/typecheck;运行时依赖经 frontend-core 精确钉版传递;自带 Dockerfile(nginx-unprivileged 静态+反代),镜像 `ghcr.io/pigeonbox/frontend` 随 server 同 tag 发布;平台宿主适配器已迁出至 fnos/qnap 各仓 `web/` |
| frontend-core | v0.11.10 | 公共前端 core(2026-10-09 拆分):平台无关应用全量(视图/stores/API/i18n/组件/单测)+宿主适配器 SPI(`src/host`,installHost 运行时注入);消费=Release 源码 tgz(与 contracts 同模式,壳仓与各平台仓 `web/` 以 URL 依赖钉版);CI 平台零容忍守卫(依赖清单/源码禁宿主 SDK,neutral 产物扫描) |
| server | v3.3.9 | **Wave B'(2026-10-22) 镜像不再随包 p2pc(`/app/p2pc` 与 `.p2pc-version` 已删),pb CLI `p2p` 只余四支联邦子命令(peers/invites/accept/push)**;v1.22.0=pb CLI 新增 `p2p` 八支子命令(status/tasks/send/recv/cancel/invites/accept/push,admin API Key 通道);v1.21.0 起镜像随包 p2pc(`/app/p2pc`,`.p2pc-version` 钉版+sha256 校验,缺 P2PC_VERSION 优雅降级);v1.17.0 起镜像线并入产品号(全端同号)**;v0.15.x=单机内存模式列车(core v0.14.0);v0.14.x=多副本拆分列车(core v0.13.0,PB_DEPLOY_MODE);纯后端镜像(默认 release 模式,alpine 钉 3.22);frontend 分离镜像由同一 `v*` tag 同步发布(`ghcr.io/pigeonbox/server` / `frontend`) |
| fnos | v3.3.9(内置 core v0.31.9) | 原生 fpk(包内自带双架构二进制+前端+**随包 p2pc**,hub Release `fnos-v*`;P2PC_REF 钉版+sha256 校验,服务脚本自动注入 `PB_P2PC_PATH`);镜像 `ghcr.io/pigeonbox/fnos` 已停发(2026-10-09 Docker 链路移除,冻结在 v1.14.6;旧镜像 `pigeonbox-fnos` 冻结在 v0.2.6,更早 `pigeonbox-fnos` 冻结在 v0.2.1) |
| openwrt | v3.3.9(内置 core v0.31.9) | OpenWrt/iStoreOS 原生 ipk:procd 托管,UCI 配置(`/etc/config/pigeonbox`)+drop-in config.yaml,双架构 x86_64/aarch64_generic,**随包 p2pc(落 `/usr/bin/p2pc` 命中候选序)**;ipk 回挂 hub Release(`openwrt-v*`) |
| qnap | v3.3.9(原生,内置 core v0.31.9) | 威联通 QTS 原生 QPKG(v1.14.4 起切原生进程模式,对齐 fnos):包内自带双架构静态二进制+前端+**随包 p2pc**,单进程单端口,免 Container Station(QTS 4.5+);QPKG 服务脚本托管(setsid 后台引导+PID+看门狗自愈),.env 在卷根 pigeonbox/;QDK qbuild 组包,包回挂 hub Release(`qnap-v*`) |
| NAS 打包三仓 | v3.3.9(钉 server/frontend 镜像 v3.3.9) | synology SPK(noarch,DSM 7.2+ Container Manager)/ ugreen·terramaster compose 部署包(UPK/TOS7 应用包送审二期);纯 shell 零 Go,编排=双容器免 Redis(server 镜像自 Wave B'(2026-10-22)起不再随包 p2pc,直传请用独立应用 PigeonBeam;NAS 原生包 fnos/qnap/openwrt 仍随包 p2pc);共享模板在 hub `deploy/nas/`(qnap 原生切出后不消费);包回挂 hub Release(各 `*-v*` tag) |
| p2p | v0.9.0 | **v0.6.3=p2pc `--json` NDJSON 事件流(code/done/error,形态锁单测,缺省纯文本不变);v0.6.2=`recv -`+`PB_P2P_CODE` env 传码(argv 不留口令)+口令行格式锁(printCode 单源)**;v0.3.x=M3 设备直传全量(p2pc)+六平台二进制;v0.4.0=wire AEAD/注册 token/中继限流安全加固;v0.4.10=env 前缀 PB_ 更名;**v0.5.0=安全运营加固(XFF 末段解析/per-hash 限流/TLS/快照持久化/原生 fuzz)+传输协议 v3(显式版本协商+QUIC ≥8MB 三流并行)**;**v0.6.0=传输协议 v4(多文件 manifest 流+zstd 压缩+单遍哈希)+健壮性三件套(IPv6 双栈/PCP·NAT-PMP·UPnP 端口映射/先通后优)+发现层(DNS SRV+多注册中心 rendezvous 分片 failover)+p2pcweb 网页模式多文件+中继默认开**;协议 v3/v4 为破坏性变更,直传双端须同版;镜像 `ghcr.io/pigeonbox/p2p`(含 p2pc) |
| kit(已归档) | v0.3.1(终版) | **2026-10-16 起退役**:28 包全量并入 [oekit](https://github.com/oekit) 模块矩阵(pkg 16 微库+concurrency 7 并发;shutdown→logx、version→core、workflow、streamx/wsutil→network,API 面零缺失);消费方 core/p2p/fnos/openwrt/qnap 已切 `github.com/oekit/{pkg,concurrency,core,logx}`,NOTICE 归属随迁;仓只读留存 |
| desktop | desktop-v3.3.9 | Tauri 2 桌面客户端(纯客户端;设备直传请用独立应用 PigeonBeam——2026-10-22 Wave B' 已摘 p2pc sidecar,`externalBin` 与 CI 随包段一并删除);三平台安装包+麒麟/统信双架构(arm64 glibc ≤2.35 守卫)回挂本仓 Release(`desktop-v*` tag) |
| charts | chart 2.0.57(app v3.3.9) | `pigeonbox` chart:1.2.x 起内置数据面,1.3.x 增内置 S3(SeaweedFS),1.3.4 增 p2p 可选组件,1.3.7 增直传中继开关,**1.3.22 增多副本双拓扑(PB_DEPLOY_MODE)**;Pages + OCI 双发布 |

---

## 3. core 内部分层架构

```mermaid
graph TB
    subgraph BOOT["bootstrap/(库入口)"]
        BS["Bootstrap(configPath)<br/>BootstrapWithOptions(opts...)"]
        OPT["Options: WithStaticDir..."]
    end

    subgraph TRANSPORT["传输层"]
        GENH["gen/handler + gen/router<br/>(hz/thriftgo 生成装配,业务域路由收敛 IDL<br/>admin 面亦已收编+common/health/ratelimit 基建)"]
        HAND["transport/http<br/>(手写区收窄:存储注入/本地导入/多文件等桥接<br/>+ 认证中间件)"]
    end

    subgraph APP["业务层 app/(17 个域,近零耦合)"]
        SHARE["share 分享"]
        CHUNK["chunk 分片"]
        ANON["anonymous 匿名取件"]
        PRESIGN["presign 预签名直传"]
        ADMIN["admin 管理"]
        CONFIG["config 系统配置中心<br/>(SystemConfig,v0.15.1 独立成域)"]
        USER["user 用户/JWT/APIKey"]
        NOTIFY["notify 通知"]
        QRCODE["qrcode 二维码"]
        SETUP["setup 初始化"]
        STORAGESVC["storage 存储管理"]
        FED["federation P2P 联邦<br/>(v0.19.0 起收 SystemConfig p2p 段<br/>运行时热启停)"]
        MCP["mcp AI 管理端点<br/>(18 工具)"]
        MOD["moderation 内容审核"]
        OIDC["oidc SSO 登录"]
        PREVIEWDOM["preview 在线预览"]
        REQUEST["request 寄件码"]
    end

    subgraph INFRA["基础设施层"]
        REPO["repo/db(gorm dao+model·11表<br/>dao 构造必填 *gorm.DB 注入,零全局回退)<br/>repo/redis(可选,缺省降级)"]
        STOR["storage(OpenDAL:14 种后端<br/>fs/s3/webdav/ftp/sftp/gcs/<br/>azureblob/hdfs/onedrive/云厂商 S3 兼容)"]
        PKG["pkg/(12 包: auth·logger·middleware<br/>·resp·errors·utils·baseurl·gate<br/>·memkv·metrics·security·transfer)"]
    end

    subgraph DATA["数据"]
        DB[("SQLite / MySQL / PostgreSQL")]
        REDIS[("Redis(可选,缺省内存模式 memkv)")]
        OSS[("本地磁盘 / S3 兼容对象存储等 14 种")]
    end

    BS --> GENH & HAND
    GENH -->|"业务域路由(idl 收敛)"| APP
    BS -.->|"手工接线路由/钩子:<br/>federation(/api/v1/federation/*)·<br/>mcp(/api/v1/mcp)·oidc(登录回调)"| APP
    MOD -.->|"钩子注入上传/分享链路"| SHARE
    ADMIN -.->|"SystemConfig 读写<br/>窄接口注入"| CONFIG
    CONFIG -.->|"p2p 段变更钩子<br/>(热启停,先立后破)"| FED
    APP --> REPO & STOR & PKG
    REPO --> DB & REDIS
    STOR --> OSS
```

**分层纪律**(继承原 internal 设计):业务层不依赖传输协议、不直接操作数据库(经 repo;dao 构造**必填 `*gorm.DB`** 依赖注入,`GetDB()` 全局句柄仅限装配层显式使用,app/ 不得调用——架构棘轮守卫强制)。域与域之间近零耦合:现存跨域引用仅 **admin→config**(SystemConfig 独立域,窄接口)与 **share→moderation**(审核钩子窄接口,不算业务依赖);曾为唯一例外的 presign→share 已于 v0.16.x 消解(baseurl 下沉 `pkg/baseurl`+消费侧窄类型+装配点适配器)。2026-10-22 Wave B' 已删 p2px 设备直传编排域与其 `conf.P2PDirectConfig` 配置段,Box 侧只保留联邦面(`app/federation`:在线名录/口令联邦路由/邀请信箱),不再编排直传数据面;「发布为分享」改由独立应用 PigeonBeam 的「投递到柜」桥承担(经 Box 公开 API `/share/file/` + X-API-Key 转存分享,Box 侧零改动)。域服务单例经 `InitDefault` 化显式初始化,懒加载/包级 init 已退役。

> 域到路由的两种挂法:share/chunk/preview/request/admin/p2p 等走 gen 生成路由(admin 面增强端点 v0.15.2~v0.16.0 IDL 化收编,含用户/文件/统计/日志/local-files/设置测试/审计日志;v0.19.0 新增 contracts `idl/p2p.thrift` AdminP2PService 六端点 `/admin/p2p/*`,v0.20.0 扩至九端点(待收邀请/认领/推送)并新增 P2PPublicService 公开收件端点 `POST /api/v1/p2p/invite`——设备直传状态/任务/发送/接收/取消/发布/邀请推送);**2026-10-22 Wave B' 删净九个直传端点,`/admin/p2p/*` 现只余四端点联邦面(invites 待收列表/invites-accept 认领信封/invite-push 推送/directory 在线名录)+公开收件端点 `POST /api/v1/p2p/invite`**;手写路由保留在 bootstrap `customizedRegister` 白名单(presign 直传/多文件/取件元数据/OIDC/federation resolve/mcp 等,由路由守卫测试对账防漂移),其中 federation/mcp/oidc 为域级手工注册(mcp 为 Streamable HTTP 单端点,非 REST;协议层=官方 SDK github.com/modelcontextprotocol/go-sdk,规范 2026-07-28)。

### 3.1 全局中间件链(顺序敏感)

```
Recovery → RequestID → AccessLog → Metrics → SecurityHeaders → CORS → handler
(panic→500) (trace_id)  (结构化日志) (RED指标)  (安全响应头)     (跨域)
```

Metrics 默认绑定 `127.0.0.1:9090`(可用 `PB_METRICS_ADDR` 配置),仅供同节点 Prometheus 抓取。

SecurityHeaders 的 HSTS 为三态语义(conf 层裁决):未配置时生产模式默认开启、开发默认关,`security.cors.enable_hsts` 显式值恒以配置为准(env `PB_ENABLE_HSTS`)。业务指标名前缀 `pb_`(如 `pb_upload_bytes_total`),Redis 键前缀 `pb:`。

---

## 4. 运行时请求流

```mermaid
sequenceDiagram
    participant B as 浏览器/Vue3
    participant H as Hertz Server(bootstrap 装配)
    participant MW as 中间件链
    participant GH as gen/handler
    participant S as app/* 域服务
    participant R as repo 层
    participant D as DB / 存储

    B->>H: HTTP /share/text/(POST, JWT)
    H->>MW: Recovery→RequestID→AccessLog→Metrics→Security→CORS
    MW->>GH: 路由匹配(gen/router)
    GH->>GH: BindAndValidate(thrift 模型)
    GH->>S: ShareTextWithAuth(...,requireAuth,passwordHash,...)
    S->>S: 密码 bcrypt 哈希/过期计算/code 生成(冲突重试)
    S->>R: Create
    R->>D: INSERT file_codes
    S-->>GH: ShareResp(code, url)
    GH-->>B: 200 {code, url}(经 resp 统一包装/errcode)
```

**关键路径**:`/live` `/ready` 健康检查、`/metrics` Prometheus、静态资源(StaticDir 选项,SPA fallback)均在 bootstrap 层注册,不经过业务。另有 `POST /api/v1/mcp` 单端点(JSON-RPC 2.0,默认管理员 token;`mcp.allow_guest` 开启后游客可调访客级工具)供 AI 客户端(Claude Desktop 等)执行管理操作——现 18 个工具,覆盖分享全生命周期+系统状态+联邦状态/解析/在线名录/待收邀请/认领信封(p2p_peers/p2p_invites/p2p_accept,管理员专属);工具入参/出参类型化(推断式 JSON Schema 2020-12 + 严格入参校验 + structuredContent 结构化出参)。

---

## 5. 关键数据流

### 5.1 文件上传(双路径 + 秒传去重)

```mermaid
flowchart LR
    A[用户选文件] --> B{大小?}
    B -->|"< 100MB"| C["POST /share/file/(multipart)<br/>→ 秒传检索 → 存储落盘 → 建 file_codes 记录"]
    B -->|"≥ 100MB"| D["POST /presign/init<br/>(密码此时哈希入 InitMeta)"]
    D --> D2{"秒传命中?<br/>(CheckQuickUpload)"}
    D2 -->|"同用户同 hash+size 命中"| D3["免落盘直接建分享<br/>(引用旧物理对象,resp.Deduped)"]
    D2 -->|未命中| E["PUT 预签名 URL 直传对象存储<br/>(分片,浏览器直连,进度条)"]
    E --> F["POST /presign/complete<br/>→ 验 token → 合并分片状态 → 建分享"]
    C --> G[("分享码 + URL + 二维码")]
    D3 --> G
    F --> G
```

> 秒传去重 D1(v0.18.x 起):同用户内同 hash+size 命中即共享物理对象;删除走引用计数保护(`CountFilePathReferences`,仍被引用则保留,查不清时宁泄漏勿误删,孤儿由 janitor 对账兜底)。匿名取件码也可**先出码后上传**:`/anonymous/generate` 先铸占位分享,presign 直传 Complete 时回填文件(`ResolvePlaceholder`/`BindFilePath`)。

### 5.2 取件与密码保护

```mermaid
flowchart TD
    U["首页统一取件(输入锁 6 格;<br/>超长粘贴整串按分享码链路分派)"] --> U2{"码型?"}
    U2 -->|"6 位取件码(全大写不区分,Redis/内存映射+回源 DB)"| U3["POST /anonymous/retrieve<br/>(扣次数+记录取件人+到件通知,v0.14.8 起两通道对齐)"]
    U2 -->|"8 位分享码/3-64 位口令"| A["GET /share/select/?code=X"]
    A --> B{require_auth?}
    B -->|否| Z[返回内容]
    B -->|是| C{password 参数?}
    C -->|空| D["401 需要密码<br/>has_password:true"]
    C -->|非空| E{bcrypt 校验<br/>PasswordHash}
    E -->|不匹配/哈希缺失| F["401 密码错误<br/>(空哈希一律拒绝)"]
    E -->|匹配| Z
    Z --> Y["记录取件人 → 通知 owner(fire-and-forget)<br/>下载链路扣减次数(原子防超卖)"]
```

> 取件码通道(v0.14.8 起)与 8 位码链路的取件人记录/到件通知行为完全一致:
> `RecordViewerAndNotify` 统一收口,同 code 5 分钟内通知去重。
> v0.15.0 起文本分享与文件分享**同权铸造 6 位取件码**,文本取件走同一 `/anonymous/retrieve` 链路。
> 取件前置校验(过期/次数/密码/封禁)四入口锁规格统一收口 `pkg/gate.CheckPickup`(v0.15.1 起),各入口行为一致不再各写一套。

### 5.3 P2P 联邦(对称节点,standalone 专属)

v1.21.0(core v0.19.0)起**每台 standalone server 都是对称 P2P 节点**:联邦配置收进 SystemConfig `p2p` 指针段(admin「系统配置 → 联邦」分区),保存即运行时热启停(先立后破,失败回滚维持原状,错误响亮 500 不静默);env/yaml 仅为首启种子,DB overlay 优先。设计稿:`docs/specs/2026-10-14-p2p-peer-integration-design.md`。

> **设备直传已拆为独立应用 PigeonBeam(信鸽直传)**(2026-10-22 Wave B'):Box 侧不再编排直传,`p2p.direct.*` 配置段随直传编排层一并删除(core 启动时检出陈旧 `p2p.direct.*` 会**响亮提示**并要求改配到 `p2p.federation.registry_url`,不静默吞掉),Box 只保留联邦面(`app/federation`)。产品定位真相源:`PigeonBox/p2p/docs/PRODUCT.md`。

```mermaid
flowchart TB
    subgraph SRC["源节点(分享方 server,standalone)"]
        FED1["core federation 域<br/>宣布:熵门槛口令公告<br/>Ed25519 签名+心跳续租"]
    end
    R["🕸️ p2p 注册中心(自部署/官方公共节点<br/>registry 留空=home.enjoye.top:56788)<br/>租约注册·口令联邦路由(SHA-256 哈希)<br/>多注册中心 rendezvous 分片+failover<br/>裸域名 DNS SRV 发现(v0.6.0)"]
    FED1 -->|"公告/心跳"| R
    subgraph DST["取件方 server"]
        FED2["core federation 域<br/>SHA-256(口令)→解析源节点<br/>校验留在源节点,零跨节点信任"]
    end
    FED2 -->|"resolve + 反代取件"| R
```

> 设备直传数据面(p2pc 协议 v4:PAKE + QUIC mTLS 多流 + zstd + manifest 流 + 打洞/中继)现由独立应用 **PigeonBeam** 提供,Box 侧只做联邦路由与邀请信封交接。

**p2pc 分发面(Box 侧已退役)**:server 镜像**不再随包 p2pc**(2026-10-22 Wave B',`/app/p2pc` 与 `.p2pc-version` 随包段一并删除);现随包的只有 **NAS 三端**——fnos/qnap/openwrt(`DEPS.env P2PC_REF` 钉版,服务脚本注入 `PB_P2PC_PATH`,openwrt 落 `/usr/bin/p2pc`);desktop 已摘 sidecar,回归纯客户端。Box 侧管理面=contracts `AdminP2PService` **四端点**(`/admin/p2p/invites` 待收列表、`/admin/p2p/invites/accept` 认领信封、`/admin/p2p/invite-push` 推送、`/admin/p2p/directory` 在线名录)+admin 联邦面板(直传控制台页已删,联邦面板独立成页)+MCP 只留三个联邦工具(p2p_peers/p2p_invites/p2p_accept,直传四工具已删)+pb CLI `p2p` 只留四支联邦子命令(peers/invites/accept/push)。v1.22.0(core v0.20.0)新增**联邦实例间推送邀请**:对方站点经公开端点 `POST /api/v1/p2p/invite` 收件,管理员在控制台待收/认领/推送——免手工口令交接(口令=bearer,信任级同手工;定时自动同步仍未承诺)。`POST /admin/p2p/invites/accept` 的 data 现为**纯信封**(不再是直传任务):接受邀请不再意味着本机开始接收文件,实际接收由 PigeonBeam 客户端完成。public/admin 多副本拆分模式下**联邦自动降级**(节点身份是进程级的);直传已不在 Box 侧。

### 5.4 飞牛 fnOS 形态(原生单进程库式调用)

```mermaid
graph LR
    subgraph PROC["单个原生进程(飞牛 .fpk,看门狗自愈)"]
        MAIN["cmd/main(PID 文件+30s 健康检查<br/>3 次失败自动重启/崩溃直接拉起)"] --> ENS["ensureJWTSecret<br/>自动生成密钥持久化数据目录"]
        MAIN --> BOOT["bootstrap.BootstrapWithOptions()<br/>(库调用+WithStaticDir,前端同端口 SPA)"]
        MAIN --> ADP["adapter.Mount(h)<br/>/api/fnos/* 路由组"]
        ADP --> SSO["SSO 免登录<br/>(X-Trim-* 可信用户头→oidc_sub 映射)"]
        ADP --> TAPI["trim.file.* / trim.system.*<br/>(授权目录/系统信息)"]
    end
    GW["fnOS 统一网关 app.sock<br/>(stripPrefix 反代+nonce 防直连端口伪造头)"] ==>|"X-Trim-* 用户头"| SSO
    SOCK["/var/run/trim_open_gateway_apiscope.socket<br/>(TRIM_API_TOKEN)"] -.-> TAPI
    WEB["前端 JS SDK @trimjs/web-app<br/>(fnos/web 宿主适配器)"] -.-> GW
    subgraph VOL["@appdata 数据目录"]
        DB2[("SQLite + 上传文件 + .jwt_secret")]
    end
    PROC --> VOL
```

包内自带双架构静态二进制与前端产物(`app/www`),并随包 p2pc 设备直传二进制(服务脚本自动注入 `PB_P2PC_PATH`),不依赖 Docker/外网拉镜像。非 fnOS 环境(探测不到网关凭证)自动**降级**为普通单机服务器:`/api/fnos/*` 不可用,业务全部正常;通知中心/内网穿透官方一期未开放,诚实缺席不造假开关。威联通 qnap 仓为同构形态(QTS 原生 QPKG,SSO 信任锚=本机 `authLogin.cgi` 实时校验 `NAS_SID` 会话,详见 qnap README)。

---

## 6. 部署形态对比

| | server(自托管) | fnos(飞牛) | openwrt(路由器) | qnap(威联通) | desktop(桌面) |
|---|---|---|---|---|---|
| 进程 | 1 个二进制(main → core) | 1 个原生进程(main → core,看门狗自愈) | 1 个二进制(core,procd 托管+开机自启) | 1 个原生进程(QPKG 服务脚本托管+看门狗自愈) | Tauri 常驻托盘(纯客户端,直传请用 PigeonBeam) |
| 前端 | 无(0.9.0 起纯后端镜像;分离部署由 frontend 镜像承担静态+反代) | 包内前端产物(`app/www`,WithStaticDir 同端口 SPA) | 前端 dist 内置于 ipk(web/ 自包含,单端口 12345) | 包内前端产物(web/ 自包含,同端口 SPA) | 连接任意服务器 URL,无本地前端服务 |
| 配置 | config.yaml + PB_* env | PB_* env + 飞牛安装/配置向导(管理员密码/端口) | UCI(`/etc/config/pigeonbox`)+drop-in config.yaml | 卷根 `pigeonbox/.env`(File Station 可编辑) | 连接配置本地保存 |
| JWT 密钥 | PB_JWT_SECRET 必填(强校验) | 自动生成并持久化(装机即用) | 自动生成并持久化(装机即用) | 自动生成并持久化(装机即用) | 不持有(服务端事务) |
| 数据 | docker volume | @appdata 数据目录 | `/etc/pigeonbox/`(卸载保留) | 卷根 `pigeonbox/`(卸载保留) | 服务端存储 |
| 镜像/制品 | ghcr.io/pigeonbox/server(镜像不随包 p2pc) | `fnos-v*` pigeonbox.fpk(随包 p2pc;镜像已停发) | `openwrt-v*` ipk+apk(x86_64/aarch64,随包 p2pc→/usr/bin,hub Release) | `qnap-v*` QPKG(x86_64/arm_64,随包 p2pc,hub Release) | `desktop-v*` 安装包(纯客户端,hub Release) |
| 平台集成 | admin「系统配置 → 联邦」分区热启停联邦 | 开放平台 SSO(X-Trim-* 头)+trim.file/system API+@trimjs/web-app | LuCI 服务页+可视化配置表单 | QTS SSO 免登录(NAS_SID→authLogin.cgi 校验)+系统信息 | 直传请用独立应用 PigeonBeam |

**NAS 打包三仓**（synology/ugreen/terramaster，2026-10-07 起；qnap 已于 v1.14.4 切原生 QPKG 归入上表）覆盖群晖 DSM 7.2+（noarch SPK，Container Manager 编排，向导设端口/数据目录/**必填管理员密码**）、绿联 UGOS Pro 与铁威马 TOS 5/6/7（compose 项目导入部署包，UPK/官方应用包送审为二期）：统一打包 ghcr 官方镜像的 docker-compose 编排（双容器免 Redis 单机内存模式），零 Go 代码，数据落卷/共享目录，制品以 `synology-v*`/`ugreen-v*`/`terramaster-v*` tag 回挂本仓 Release；共享 compose/env 模板在 hub `deploy/nas/`（sync 漂移门禁）。

Kubernetes 形态（charts 仓 `charts/pigeonbox`）为**前后端分离两容器**：`frontend` Deployment（ghcr.io/pigeonbox/frontend，nginx 静态资源 + API 反代，无状态）+ `server` Deployment（API/数据，携带 PVC），Ingress 指向 frontend Service、API 由其反代后端；两镜像由 server 仓 release 工作流以同一 `v*` tag 同步发布。chart 另提供可选内置组件：数据面（Redis 默认开，MySQL/PostgreSQL 可选）、内置 S3 对象存储（`s3.enabled=true`，SeaweedFS 单进程）、p2p 联邦注册中心（`p2p.enabled=true`，1.3.7 起含直传中继开关——2026-10-22 起该组件定位为 **PigeonBeam 的公共 rendezvous 与加密中继底座**，Box 侧已无直传编排，与 core 联邦开关无关）——均默认关闭。

**多副本拆分**（chart 1.3.22+ / server ≥ 0.14.0，`replicaCount > 1`）：同一镜像以 `PB_DEPLOY_MODE` 切三种运行形态——`standalone`（默认，单进程全功能，即上表形态）/ `public`（公开面路由 ×N，管理路径物理 404，不跑迁移与后台任务）/ `admin`（管理面 + 后台任务 + DB 迁移 + 配置唯一写者，全局 1 实例）。管理端配置/存储变更经 Redis pubsub + revision 对账秒级同步到全部 public 副本；公网入口只指 public 面，admin 面走独立 Ingress（白名单）或 port-forward。硬约束：MySQL/PG + Redis 必配、存储 S3 或 RWX 卷、**federation 自动降级**(节点身份是进程级的,仅 standalone 跑联邦)。直传编排已不在 Box 侧,多副本拆分与直传无关。设计详见 `docs/specs/2026-10-06-multi-replica-deployment-modes.md`。

---

## 7. CI / 发布流水线

### 7.1 发布列车 v2(2026-10-08 起,全生态版本唯一通道;10-12 切状态机编排器)

版本真相源 = 本仓 `release/train.yaml`(扁平 dotted key,声明一趟列车全部组件版本/钉版/回挂期望);编排器 = 本仓 `release/trainctl`(Go,stdlib-only,设计稿 `docs/specs/2026-10-12-release-train-v2-design.md`)。禁止绕过列车手改 VERSION/DEPS.env/manifest/tauri.conf.json/go.mod 钉版——tag 前置断言与 `make train-verify` 双层拦截。

```mermaid
flowchart TD
    A["make train-bump TRAIN=x.y.z<br/>SET=\"core=v… core_pin=v…\""] -->|"结构化写 15+ 版本点<br/>各仓 train/x.y.z 分支 + PR<br/>自动 squash 合并"| B["bump 全仓落钉"]
    B --> C["trainctl advance 状态机<br/>(组件回调/15 分钟 sweep/手动唤醒)"]
    C -->|"按依赖序推 tag:<br/>库线先行→frontend→server→<br/>七终端→desktop"| D["机器人账号推 tag 天然触发<br/>各仓 Release 流水线<br/>(镜像/安装包/回挂 hub)"]
    D --> E["以 GitHub API 实况对账<br/>(回挂/镜像齐)"]
    E --> F["全量 verify 通过<br/>→ hub v x.y.z Latest 生态快照"]
```

写凭据统一为 org 级 secret `PB_BOT_TOKEN`(配置清单 `docs/release-bot-setup.md`);branch protection 阻挡时 advance 以 `--admin` 响亮兜底。应急逃生门:`make train-bump-local`(dry-run 零落盘)与 `make train-advance`(本地推进,正常优先 dispatch CI)。

### 7.2 CI 与打包

```mermaid
flowchart TD
    subgraph PR["每次 push / PR"]
        GO["Go 八仓(contracts/core/server/fnos/openwrt/<br/>qnap/p2p/kit):build + vet + test(-race)<br/>+ 依赖守护 + govulncheck + gitleaks"]
        FECI["frontend(壳):typecheck + neutral 构建<br/>+ 平台代码隔离扫描<br/>frontend-core:typecheck + vitest + 平台零容忍守卫"]
        DSK["desktop:<br/>rust 构建 + 前端 build"]
        CHT["charts:<br/>lint + template + kind 安装冒烟"]
    end
    subgraph REL["打 tag 发版(列车驱动)"]
        IMG["server/p2p: v* → buildx 多架构<br/>推 ghcr.io/pigeonbox/*(p2p 镜像含 p2pc;<br/>frontend 分离镜像随 server 同 tag)"]
        BIN["desktop: desktop-v* → 三平台+麒麟/统信双架构安装包<br/>(纯客户端,不随包 sidecar)<br/>fnos: v* → fpk(双架构静态二进制+web/ 前端+p2pc)<br/>openwrt: v* → ipk+apk(随包 p2pc) · qnap: v* → QPKG(随包 p2pc)<br/>NAS 三仓: synology-v*/ugreen-v*/terramaster-v* → SPK/部署包<br/>(均回挂本仓 Release,凭据=org 级 PB_BOT_TOKEN)"]
        PUB["frontend-core: v* → Release 源码 tgz<br/>contracts: v* → TS d.ts tgz<br/>hub: v* → 生态快照 Release<br/>charts: push main → Pages + OCI"]
    end
    COREDEV["core/contracts/frontend-core 发新版本"] -->|"列车统一升钉下游<br/>(require/tgz URL)"| REL
```

**发版流程**(经列车):库线改动 → tag(contracts/core/frontend-core 先行)→ `make train-bump` 把钉版写入各下游 → PR 自动合并 → advance 状态机按依赖序推 tag → CI 自动出镜像/安装包。全程无需 replace。p2p 随 Release 发布 p2pc 六平台二进制(命名=Tauri target triple);desktop 仓已于 2026-10-22 Wave B' 摘除 sidecar,CI 不再按平台拉取 p2pc,安装包为纯客户端;传输协议 v3 起为破坏性变更,**仅 NAS 三端**随包 p2pc 须随列车同升。fnos 镜像链路已于 2026-10-09 移除(只发原生 fpk,`ghcr.io/pigeonbox/fnos` 冻结在 v1.14.6)。

---

## 8. 技术栈

| 层 | 技术 |
|----|------|
| 后端 | Go 1.26 · CloudWeGo Hertz · GORM(SQLite/MySQL/Postgres) · go-redis(可选) |
| 契约 | Thrift IDL(v0.13 生成,require 传递版本约束) · OpenAPI 3(后端运行时生成 `/openapi.json`) |
| 存储 | OpenDAL 统一抽象,14 种后端(local / S3 兼容及各云厂商 / webdav / ftp / sftp / gcs / azureblob / hdfs / onedrive) |
| 前端 | Vue 3 · TypeScript · Vite · Element Plus · Pinia;frontend-core(平台无关应用+宿主适配器 SPI)+壳仓/平台仓 `web/` 消费 Release tgz(wire 契约类型经 `@pigeonbox/contracts`;API 规范真相源=后端运行时 `/openapi.json`) |
| 可观测 | zap 结构化日志 · Prometheus RED 指标 · X-Trace-Id 链路 |
| 安全 | bcrypt 分享密码 · JWT(JWT 纪元+封禁/改密即时失效) + API Key(`pb_sk_`) · OIDC SSO · NAS 平台 SSO(fnOS X-Trim-* / QTS NAS_SID) · CORS 白名单 · 限流(Redis/内存) · 安全响应头(CSP/HSTS 三态) · 内容审核钩子(敏感词/ClamAV) · MCP 管理端点(18 工具,访客三级作用域) · gitleaks/govulncheck/dependabot/secret scanning 全仓门禁 |
| 端到端 | 设备直传由独立应用 **PigeonBeam** 提供(协议 v4:PAKE + QUIC mTLS 多流并行 + zstd + 多文件 manifest + IPv6/端口映射/先通后优 + 加密中继兜底 + AEAD 断点续传);Box 侧只保留联邦面(对称节点可热启停) |
| 构建 | Docker 三阶段 · GitHub Actions(多架构) · ghcr · 发布列车 v2(release/train.yaml + trainctl 状态机) |
