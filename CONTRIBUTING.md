# CONTRIBUTING

感谢关注 PigeonBox！本仓是**装配仓库**（hub）：不含业务代码，负责把各模块仓拉齐成工作区。业务贡献请到对应模块仓提 Issue/PR：

| 想改什么 | 去哪个仓 |
|---|---|
| API 契约 / 错误码 / Thrift 类型 | [contracts](https://github.com/pigeonbox/contracts) |
| 业务逻辑 / 存储 / 引导（Go） | [core](https://github.com/pigeonbox/core) |
| 部署壳 / 配置 / Docker | [server](https://github.com/pigeonbox/server) |
| Web 界面（Vue3 + TS，平台无关应用） | [frontend-core](https://github.com/pigeonbox/frontend-core) |
| 前端壳 / nginx 镜像 / neutral 产物 | [frontend](https://github.com/pigeonbox/frontend) |
| 桌面客户端（Tauri 2） | [desktop](https://github.com/pigeonbox/desktop) |
| 飞牛 fnOS 适配 | [fnos](https://github.com/pigeonbox/fnos) |
| OpenWrt/iStoreOS 原生包 | [openwrt](https://github.com/pigeonbox/openwrt) |
| 威联通 QTS 原生 QPKG | [qnap](https://github.com/pigeonbox/qnap) |
| 群晖 / 绿联 / 铁威马 部署包 | [synology](https://github.com/pigeonbox/synology) · [ugreen](https://github.com/pigeonbox/ugreen) · [terramaster](https://github.com/pigeonbox/terramaster) |
| P2P 联邦注册中心 / p2pc 设备直传 | [p2p](https://github.com/pigeonbox/p2p) |
| 共享 Go 工具库 | [kit](https://github.com/pigeonbox/kit) |
| Helm Chart | [charts](https://github.com/pigeonbox/charts) |

## 快速开始（本仓）

```bash
git clone git@github.com:pigeonbox/pigeonbox.git && cd pigeonbox
make setup     # 拉齐 13 个模块仓（幂等，重复执行=更新；SETUP_FNOS=0 / SETUP_OPENWRT=0 / SETUP_P2P=0 / SETUP_KIT=0 / SETUP_SYNOLOGY=0 / SETUP_QNAP=0 / SETUP_UGREEN=0 / SETUP_TERRAMASTER=0 可跳过对应仓）
make test      # 八 Go 模块测试（contracts/core/server/fnos/openwrt/qnap/p2p/kit） + 前端 typecheck
make build     # go.work 联编 → bin/
make smoke     # 起 server 冒烟（仅 /live + admin 登录两项断言；文本分享等全量断言在 scripts/smoke-full.sh）
```

全能力真机冒烟（44 项断言，含文本/文件分享、分片、秒传、寄件码、MCP、匿名码等）单独跑：

```bash
bash scripts/smoke-full.sh    # 自动编译+起临时实例(含临时 Redis)，跑完即清理
```

## 外部贡献者：fork 工作流

hub 仓不含业务代码，业务改动一律提到**对应模块仓**（不是 hub）。模块目录被 hub gitignore，本地放进 `PigeonBox/<模块>/` 即可被 go.work 收编联调：

1. 在 GitHub 上 fork 目标模块仓（如 `pigeonbox/core`）；
2. clone 自己的 fork，并加 upstream 便于同步：

   ```bash
   git clone git@github.com:<你的用户名>/core.git
   cd core
   git remote add upstream git@github.com:pigeonbox/core.git
   ```

3. 把 clone 出来的目录放进 hub 工作区：`mv core /path/to/pigeonbox/core`（或直接在 hub 目录内 clone）。之后 `make build` / `make test` 即对本地改动联编（go.work 的 use 行优先于 go.mod 钉版）；若模块不在 go.work 的 use 列表（如 NAS 打包四仓纯 shell），单独按各仓 README 构建即可；
4. 在 fork 上开分支、提交，PR 提到**模块仓** `pigeonbox/<模块>`；
5. 同步 upstream：`git fetch upstream && git rebase upstream/main`。

## 新增一个 API 端点（端到端 checklist）

路由真相源是 `contracts/idl/`，生成链贯穿 contracts → core → 前端，顺序不能乱：

1. **contracts 仓**：改 `idl/*.thrift`（新增 service 方法/请求响应类型）；
2. `./scripts/gen-model.sh` —— 生成 `gen/` thrift 模型（CI 有 `CHECK=1` 校验，生成物与源一起提交，勿手改）；
3. `go run ./cmd/gen-openapi` —— 重新生成 `openapi/openapi.json`（core embed 消费）；
4. `go run ./cmd/gen-ts` —— 重新生成 `gen/ts/*.d.ts` 前端类型；
5. **提交 contracts 仓并发 tag**（如 `v0.x.y`）——前端经 Release tgz URL 钉版消费，不发 tag 前端拿不到类型；
6. **core 仓**：`./scripts/gen-router.sh` —— IDL → `gen/router/`。注意 `gen/router/*/middleware.go` 是**唯一手工区**（鉴权接线，hz 不触碰）：新生成的路由组若非公开面，要在对应 middleware.go 补中间件（照既有先例，如 `_adminp2psendMw` 挂 `middleware.AdminOrAdminKey()`）；
7. core 写 handler/域服务逻辑，跑 `go test ./bootstrap/` —— `routes_guard_test.go` 路由守卫必须绿（漏接线/路由漂移此处会红）；
8. **前端（frontend-core 仓）**：等 contracts 发完 tag，改 `package.json` 里 `@pigeonbox/contracts` 的 tgz 资产 URL 到新版本，再写视图/API 层；
9. hub 侧验证：`make setup` 拉齐后 `make test`（contracts/core + 前端 typecheck 一把过）。

## 硬性规则（CI 强制）

1. **依赖单向**：`server / fnos / openwrt / qnap ──► core ──► contracts`；前端 `frontend 壳与各平台仓 web/ ──► frontend-core ──► contracts(TS 类型)`。core 不许 import 上游模块；contracts 不许 import 项目内任何包；p2p 为业务链零依赖叶子仓（p2pc 二进制的反向分发属打包期钉版，不产生 Go 依赖）。
2. **生成物不手改**：contracts `gen/`（thrift 模型 + `gen/ts/` 前端类型 + `openapi/openapi.json`，各生成器带 `--check`/`CHECK=1` CI 校验）、core `gen/`（router/handler，`gen/router/*/middleware.go` 鉴权接线是唯一手工区）。流程：先改 `contracts/idl/`（真相源）→ `contracts/scripts/gen-model.sh` + `core/scripts/gen-router.sh`（前端类型/OpenAPI 为 `go run ./cmd/gen-ts` / `./cmd/gen-openapi`）→ 跑路由守卫测试 → 生成物与源一起提交。
3. **破坏性变更升主版本**：删/改名字段、改错误码语义必须 bump 主版本；contracts 先发版，core 再升 require。
4. **钉版本规则**：thrift v0.13.0 由 contracts 传递（下游不要 replace）；core 显式钉 sonic v1.15.0（勿动）。

## 提交约定

- commit message 用 conventional 风格：`feat(storage): ...` / `fix(security): ...` / `docs: ...`。
- 新功能必须带测试；修 bug 先写复现测试。覆盖率按模块只升不降。
- 涉及架构/协议的改动，先在本仓 `docs/design/` 落设计文档再动手（参考 [docs/design/2026-10-03-storage-lightup-and-onboarding.md](docs/design/2026-10-03-storage-lightup-and-onboarding.md) 的粒度）。

## 本地存储/网络提示

- 本机到 GitHub 的 22 端口不通时，确认 `~/.ssh/config` 已把 `github.com` 路由到 `ssh.github.com:443`。
- 局域网 S3/WebDAV（NAS 场景）需开启 `security.ssrf.allow_private_networks: true`。

## 行为准则

保持友善、就事论事。社区信任是自托管项目的生命线——对安全、遥测、治理相关议题保持透明。
