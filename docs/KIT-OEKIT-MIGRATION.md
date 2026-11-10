# kit → oekit 迁移映射（更正版）

> **为什么有这份文档**：`pigeonbox/kit` 仓已归档（只读，2026-10-16），其 README 顶部的迁移映射表是 PigeonBox 生态下游迁移到 [oekit](https://github.com/oekit) 的唯一指引——但**该表有 2 条已失效**（`uidgen`/`validator` 的归宿写错），而归档后没有任何机制再改它。本文件是迁移指引的**现行真相源**；kit README 只作历史存档，**不再可信**。

## 逐包映射（28 包，更正版）

| 原 kit 包 | oekit 归宿 |
|---|---|
| `kit/{async,group,progress,ratelimit,retry,singleflight,syncx}` | `github.com/oekit/concurrency` 对应子包 |
| `kit/{cache,convert,encoding,enumx,errors,httpjson,jsonrepair,mathx,pagination,pathx,ptrx,slicex,stringx,timex}` | `github.com/oekit/pkg` 对应子包 |
| `kit/{uidgen,validator}` | **`github.com/oekit/kitx` 对应子包**（⚠️ 不在 `oekit/pkg`） |
| `kit/shutdown` | `github.com/oekit/logx/shutdown` |
| `kit/version` | `github.com/oekit/core/version` |
| `kit/workflow` | `github.com/oekit/workflow` |
| `kit/{streamx,wsutil}` | `github.com/oekit/network` 对应子包 |

## 与 kit README 的差异（2 条更正）

kit README 的表把 `kit/{...,uidgen,validator}` 一并写成 `github.com/oekit/pkg` 对应子包。
实际上 **`uidgen`/`validator` 自 `oekit/pkg` v0.10.0（2026-10-17，BREAKING）起被拆到 `github.com/oekit/kitx`**
（oekit/pkg 提交 `8492996 feat!: 移除 uidgen/validator——拆分至 github.com/oekit/kitx（BREAKING）`；
`oekit/kitx` 首个提交同为 2026-10-17「初始版本——自 oekit/pkg v0.10.0 拆分 uidgen/validator」）。
kit 的最后一次提交是 2026-10-16 ⇒ **公告发布次日即漂移**，至今无人能改（仓已归档）。

照 kit README 原表改 import 会编译失败，且报错极易误判：

```
main.go:4:2: cannot find module providing package github.com/oekit/pkg/uidgen
```

——这个报错看起来像 proxy/网络问题或自己 go.mod 写错，实际是**指引表写错了**。正确写法：

```go
import "github.com/oekit/kitx/uidgen"     // 不是 github.com/oekit/pkg/uidgen
import "github.com/oekit/kitx/validator"  // 不是 github.com/oekit/pkg/validator
```

`go get github.com/oekit/kitx@latest` 即可；`uidgen` 依赖 `google/uuid`、`validator` 依赖 `go-playground/validator`（与 kit 时代同）。

另两处 kit README 已失真的口径，一并更正：

- 「API 面核验零缺失」的结论**已不成立**（2/28 条归宿失效）；
- README 顶部的 CI badge 指向 2026-10-16 之后就不再运行的 CI，看板恒绿 ⇒ **看不出该仓已归档、指引已冻结**。

## 归档前置检查（流程）

本次事故的根因是**先归档、后漂移**：迁移指引活在已归档仓的 README 里，上游一拆包就再没人能改它。
归档任何**仍被下游当作迁移/接入/集成指引**的仓之前，必须先走完这道检查：

1. **判出口**：本仓的 README/文档是否被外部当作迁移、接入或集成指引？
   （搜下游仓、issue/PR 里的引用链接；kit 的答案是「是」——README 就是唯一迁移指引。）
2. **迁指引**：是 ⇒ 先把指引迁到**可写仓**（如本仓 `docs/`），或在归档说明与 README 顶部
   留一条「指引已迁至 <链接>」的跳转。指引**不许**留在只读仓里当唯一真相源。
3. **去冻结假象**：归档前摘掉或标注会冻结的 CI badge（恒绿 badge 会掩盖「仓已死、指引不再更新」）。
4. **留机制**：指引迁出后，指定**维护责任人/对账入口**（上游模块拆分/迁移时同步更正映射）。

长期建议：迁移映射做成**机器可读**（如由 `oekit/matrix-tools` 生成 JSON），下游从机器可读源读，
而不是从某个仓的 README 手抄——否则每次上游拆包都会再漂移一次。
