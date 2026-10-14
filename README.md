<div align="center">

<img src="https://raw.githubusercontent.com/pigeonbox/pigeonbox/main/docs/brand/logo.svg" width="112" alt="PigeonBox"/>

</div>

# PigeonBox(umbrella) · 文件快递柜

[![License](https://img.shields.io/github/license/pigeonbox/pigeonbox)](LICENSE)
[![Tag](https://img.shields.io/github/v/tag/pigeonbox/pigeonbox)](https://github.com/pigeonbox/pigeonbox/tags)
[![Downloads](https://img.shields.io/github/downloads/pigeonbox/pigeonbox/total?label=%E5%AE%89%E8%A3%85%E5%8C%85%E4%B8%8B%E8%BD%BD)](https://github.com/pigeonbox/pigeonbox/releases)

高性能文件/文本匿名分享平台(**PigeonBox · 文件快递柜**)的**装配仓库**:本仓不含业务代码,只负责把各模块仓库拉齐成一个可开发、可构建、可部署的完整工作区。

> 🗂️ [组织主页](https://github.com/orgs/pigeonbox)有生态总览与各形态(Docker / Kubernetes / 桌面 / NAS)快速开始。
> 拆分前的单仓库完整版本保留在 [legacy 分支](https://github.com/pigeonbox/PigeonBox/tree/legacy)(全量历史)。
> English overview: [README.en-US.md](README.en-US.md)

## 模块仓库

| 仓库 | 角色 | 版本 |
|------|------|------|
| [contracts](https://github.com/pigeonbox/contracts) | 契约层:错误码 + Thrift 生成类型 + IDL 真相源(纯类型,零业务依赖) | v0.14.0 |
| [core](https://github.com/pigeonbox/core) | 业务核心库:18 个域服务(含 config 系统配置中心、p2px 设备直传 supervisor) + repo/storage + `bootstrap.Bootstrap()` 库入口 | v0.20.0 |
| [server](https://github.com/pigeonbox/server) | 独立部署应用:main 薄壳 + pb CLI(含 `p2p` 八支子命令) + 配置模板 + Dockerfile(0.9.0 起纯后端,镜像随包 p2pc) | v1.22.0 |
| [frontend](https://github.com/pigeonbox/frontend) | 前端壳:neutral 产物 + nginx 分离镜像(随 server 同版本发布;平台宿主适配器归各平台仓 `web/`) | 随 server 同 `v*` |
| [frontend-core](https://github.com/pigeonbox/frontend-core) | 公共前端 core:平台无关应用(Vue3+TS+Vite+Element Plus)+宿主适配器 SPI,Release 源码 tgz 消费 | v0.5.0 |
| [desktop](https://github.com/pigeonbox/desktop) | 桌面客户端:Tauri 2 托盘常驻,连接任意 PigeonBox 服务器,p2pc sidecar 设备直传 | desktop-v1.22.0 |
| [fnos](https://github.com/pigeonbox/fnos) | 飞牛 fnOS 原生应用(fpk 单进程+开放平台 SSO 深度融合+随包 p2pc;Docker 镜像已停发) | v1.22.0 |
| [openwrt](https://github.com/pigeonbox/openwrt) | OpenWrt/iStoreOS 原生包(ipk+apk 双格式):procd 托管+UCI 配置+LuCI 集成,单端口 12345 内置 Web 界面,随包 p2pc | v1.22.0 |
| [synology](https://github.com/pigeonbox/synology) | 群晖 DSM 7.2+ 套件(SPK,noarch):Container Manager 编排,向导设端口/数据目录/管理员密码(必填) | v1.22.0 |
| [qnap](https://github.com/pigeonbox/qnap) | 威联通 QTS 原生应用(QPKG,x86_64+arm_64):单进程免 Container Station(QTS 4.5+),QTS 账号 SSO 免登录,随包 p2pc | v1.22.0 |
| [ugreen](https://github.com/pigeonbox/ugreen) | 绿联 UGOS Pro 部署包:Docker→项目 compose 一键粘贴(含国内加速编排) | v1.22.0 |
| [terramaster](https://github.com/pigeonbox/terramaster) | 铁威马 TOS 5/6/7 部署包:Docker Manager 项目导入 | v1.22.0 |
| [p2p](https://github.com/pigeonbox/p2p) | P2P 联邦注册中心 + 设备直传:节点租约注册、口令联邦路由、WS 信令、加密中继、p2pc CLI/网页客户端(wire 协议 v4) | v0.6.3 |
| [kit](https://github.com/pigeonbox/kit) | 共享 Go 工具库:28 个零生态依赖通用包(retry/syncx/singleflight/shutdown/workflow 等) | v0.3.1 |
| [charts](https://github.com/pigeonbox/charts) | Kubernetes Helm Chart:前后端分离双 Deployment(含多副本 public/admin 双拓扑) | pigeonbox-2.0.19 |

依赖方向(单向,CI 守护):`server / fnos / openwrt / qnap ──► core ──► contracts`;前端 `壳仓与各平台仓 web/ ──► frontend-core(tgz) ──► contracts(TS d.ts)`;`core`、`p2p` 按需消费 `kit`(kit 为零生态依赖地基层);`p2p` 为业务链零依赖叶子仓(Go 模块零耦合;server 镜像与 fnos/qnap/openwrt/desktop 在**打包期**按钉版拉取 p2pc 二进制)

## 快速开始

```bash
git clone https://github.com/pigeonbox/pigeonbox.git && cd pigeonbox

make setup     # 拉齐模块仓库(幂等,重复执行=更新)
make test      # 全仓测试(Go 各模块 + 前端 typecheck)
make lint      # golangci-lint 各 Go 模块(CI 同款门禁)
make build     # workspace 联编
make smoke     # 起 server 跑冒烟(健康检查/admin 登录;44 项全量断言见下一行)
# bash scripts/smoke-full.sh   # 全能力真机冒烟(44 项断言,含临时 Redis)
```

纯 Docker 部署(详见 [docs/DEPLOY-COMPOSE.md](docs/DEPLOY-COMPOSE.md)):

```bash
cp .env.example .env          # 可选,全部项有安全默认
docker compose up -d          # ghcr 发布镜像;前端入口 http://localhost:12345(PB_API_PORT,默认 12345),前端镜像同时反代 API,server 不发布端口
# BUILD=1 make compose-up     # 本地构建(需先 make setup)
# docker compose --profile nginx up -d   # 加 nginx 反代(须配 PB_TRUSTED_PROXIES,见部署指南;PB_HTTP_PORT 默认 80 仅作用于此 profile)
```

默认管理员 `admin / admin123`(生产务必以 `PB_ADMIN_PASSWORD` 覆盖)。JWT 密钥留空时首启自动生成并持久化到 `./data/.jwt_secret`。

## 工作区布局(setup 后)

```
pigeonbox/           ← 本仓(装配层:脚本/联编/编排/发布列车/文档站)
├── go.work             # contracts+core+server+fnos+openwrt+qnap+p2p+kit 本地联编
├── contracts/  core/  server/  frontend/  frontend-core/  fnos/  openwrt/  p2p/  kit/   ← 独立 git 仓库(gitignore 掉)
├── synology/  qnap/  ugreen/  terramaster/   ← NAS 打包四仓(qnap 为原生 QPKG 含 Go,其余纯 shell,同样 gitignore)
├── release/train.yaml  ← 全生态版本真相源(发布列车)
└── data/               ← compose 数据卷
```

各模块仓库独立开发、独立 CI、独立发版;`server/Dockerfile` 的构建上下文恰好就是本目录,`make docker` 直接出完整镜像。

## 发版

全生态版本经**发布列车**统一驱动(真相源 `release/train.yaml`,编排器 `release/trainctl` 状态机,禁止绕过手改钉版):

```bash
make train-bump TRAIN=x.y.z SET="core=vX.Y.Z core_pin=vX.Y.Z"   # 开新列车:结构化写版本点→各仓 PR→自动合并
make train-verify                            # train.yaml ↔ 全生态对账(CI 每日+PR 同款)
make train-advance                           # 手动推进状态机(正常由组件回调/定时 sweep 自动推进)
```

列车按依赖序自动推 tag(库线 contracts/kit/core/p2p/frontend-core 先行 → frontend → server → 七终端 → desktop),机器人账号推送天然触发各仓 Release 流水线:多架构镜像推 ghcr(见各仓 `release.yml`):
`ghcr.io/pigeonbox/server` · `ghcr.io/pigeonbox/frontend`(与 server 同版本) · `ghcr.io/pigeonbox/p2p`。
（fnos 2026-10-09 起只发原生 fpk，`ghcr.io/pigeonbox/fnos` 镜像已停发、冻结在 v1.14.6。）
桌面安装包(desktop-v*)与 NAS 应用包(fnos-v*/openwrt-v*/synology-v*/qnap-v*/ugreen-v*/terramaster-v*)统一回挂[本仓 Releases](https://github.com/pigeonbox/pigeonbox/releases);回挂与镜像齐后自动出 hub `v<x.y.z>` Latest 生态快照。写凭据统一为 org 级 secret `PB_BOT_TOKEN`(配置见 [docs/release-bot-setup.md](docs/release-bot-setup.md))。

## 原 README(产品功能/截图/API 说明)

见 [legacy 分支 README](https://github.com/pigeonbox/PigeonBox/blob/legacy/README.md)。

## License

[Apache-2.0](LICENSE)
