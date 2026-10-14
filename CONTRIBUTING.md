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
make smoke     # 起 server 冒烟（健康检查/admin 登录/文本分享）
```

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
