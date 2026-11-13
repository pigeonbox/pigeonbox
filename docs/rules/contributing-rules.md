# 工程与契约规则（contributing-rules）

> 单源：AGENTS.md 重构（2026-11-13，spec 附录 B 对应条目）；CONTRIBUTING.md 的
> 「硬性规则」节指向此处，**不再双份维护**。

## 依赖与架构

- **依赖单向（CI 强制）**：`server / fnos / openwrt / qnap ──► core ──► contracts`；
  前端 `frontend 壳与各平台仓 web/ ──► frontend-core ──► contracts(TS 类型)`。
  core 不许 import 上游模块；contracts 不许 import 项目内任何包；
  p2p 为业务链零依赖叶子仓（p2pc 反向分发属打包期钉版，不产生 Go 依赖）。
- **core 域服务近零耦合**：跨域引用仅 admin→config 与 share→moderation（均窄接口）；
  federation/mcp/oidc 在 bootstrap 手工注册；业务面路由走 IDL gen 链，
  残余手写路由在 customizedRegister 白名单。
- **地基优先用 oekit，不手搓**（2026-10-21 起）：需要路径清洗/限流/并发闸门/CLI 分发/
  错误构造等原语时先查 `github.com/oekit/*`。**收编前先读上游 CHANGELOG/issue，
  别按旧记录手搓**（实录：「oekit 无 try-acquire 信号量」是过期信息，上游早已实现
  `syncx.Gate.TryAcquire`）。地板版本以各仓 go.mod 为准，默认追最新。

## 生成物与契约

- **生成物勿手改（CI 强制）**：contracts `gen/`+`openapi/openapi.json`+`gen/ts/`、
  core `gen/router/`+`gen/handler/`（`gen/router/*/middleware.go` 鉴权接线是唯一手工区）。
  **IDL 真相源 `contracts/idl/`**：改路由 = 改 IDL → 跑生成链 →
  `bootstrap/routes_guard_test.go` 强制表态。生成器与 `--check`/`CHECK=1` 门禁见
  CONTRIBUTING「新增 API 端点」checklist。
- **破坏性变更升主版本**：删/改名字段、改错误码语义、wire 协议 ⇒ 主版本 +1；
  contracts 先发版，core 再升 require；p2p wire 破坏性变更双端须同版。
- **钉版**：thrift v0.13.0 由 contracts 以 `require` 传递，下游**不要** replace；
  core 显式钉 `bytedance/sonic v1.15.0`（hertz 声明版在 go1.27/arm64 有 linkname 错误）。
- **Go 工具链地板**：全模块统一 go minor + `toolchain` 地板（以各仓 go.mod 为准）；
  CI 的 setup-go 用**浮点 minor**（如 `"1.26"`）+ job 级显式 `GOTOOLCHAIN: auto`，
  地板由 go.mod 的 toolchain 行保证；**setup-go v7 勿合**（强制 `GOTOOLCHAIN=local`
  与地板冲突）。地板过期由 `hub/scripts/check-go-version-floor.sh` 顶红
  （govulncheck 门禁正是靠它把地板过期的仓顶红过）。

## 门禁必须在 CI 里（2026-10-21 立规）

新增/修改端点或契约时，**同步更新冒烟断言**；断言写的是「语义」不是实现细节。
决定 16 仓版本号的编排器（release/trainctl）这类核心代码，测试必须挂进 CI 与
`make test`——出过 1.24.0/1.24.1 连续两列车 server 镜像缺修复的事故才立的规。

## 供应链安全（基线，2026-11-13 摘录）

- 全生态 action **按 commit SHA 钉版**（`owner/repo@<40位sha> # 版本`，dependabot
  `github-actions` 生态跟进升级）；8 个 release workflow 带 workflow 级 `permissions:`
  + 每 job `timeout-minutes` + `concurrency:`（分组键用 `inputs.version || ref_name`，
  不用 `github.ref`——dispatch 跑分支、tag 跑 tag，用 ref 分不开两条会撞车的链路）。
- dependabot：**gomod 有意排除（版本归列车）**；npm 生态各前端仓全开。
- 8 个 Go 仓 govulncheck 门禁（可达漏洞即红，修复=升依赖地板）；
  secret scanning + push protection 全开；误报豁免在各仓 `.gitleaks.toml`
  （`[[allowlists]]` 复数语法；扩豁免必须写明理由）。

## 对外行为契约（改这些前先读）

- **管理台配置 PUT 是字段级合并**（2026-10-23）：提交里出现的字段生效
  （显式 null 视为清空）、未出现的保留现状、嵌套对象递归合并 ⇒ 只提交要改的字段
  是安全的；改前改后用 `GET /admin/config` 核对。门禁：core 单测 + 冒烟 S19a/b。
  （此前段级合并会把整段未提及字段清零 ⇒ 匿名上传被静默关闭。）
- **占位分享判定只有一处**：`model.IsNotReady`（`!IsTextShare() && GetFilePath()==""`）
  ⇒ select/download/preview/metadata 四面统一报 **20001「分享未完成上传」**
  （此前分享域回 200 + 指向不存在文件的直链，点了 500）。
