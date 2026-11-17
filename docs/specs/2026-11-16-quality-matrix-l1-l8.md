# 分层质量矩阵 L1–L8：全景与三项强制测试落地状态

> 来源：[pigeonbox/pigeonbox#364](https://github.com/pigeonbox/pigeonbox/issues/364)
> （2026-11-14 生态技术评审 §六「从有 CI 到有可信质量证据」）。
> 本文是矩阵的**全景索引**：每层的覆盖判据、现状证据、缺口与归属仓。
> **2026-11-18 更新**：原 §3 列的「本轮不做、按层排期」六项剩余矩阵项，已随
> 6.2.0 → 6.6.0 五趟车**全部兑现**（逐条交付出处见 §3）；本轮挖出并修复的真实缺陷见 §4；
> 仍未关闭的外部条件与已知缺口见 §5（**如实登记，未粉饰**）。

## 1. 矩阵定义

| 层 | 覆盖 | 判据（什么算这层的证据） | 现状 | 缺口 |
|---|---|---|---|---|
| L1 单元 | 状态机、配额规则、计次语义、认证失败分支 | 仓内 `go test` 表驱动用例 | 已有（既有）：core 全量单测 + 路由守卫（`bootstrap` 测试） | — |
| L2 契约 | IDL 生成漂移、错误码语义、跨版本前后端兼容 | contracts 三条生成链 `CHECK=1` + openapi/gen-ts `--check` | **已建**：contracts 错误码基线（67 码）+ `--check` 自检 + core 侧业务码登记守卫 + hub 侧跨仓对账门禁 | — |
| L3 集成 | SQLite/MySQL/PG、Redis、MinIO、WebDAV | 换库真 PG/MySQL（core ci.yml:130） | **已建**：真 PG/MySQL（既有）+ MinIO / WebDAV 常态化集成用例（新增） | 已知缺口：远端孤儿清理扫不到对象、WebDAV 分片合并全量进内存等（§5） |
| L4 端到端 | 发布制品真装 → 登录/上传/取件/删除/恢复 | 真机冒烟 `scripts/smoke-full.sh`（49+ 项） | 已有（既有）：真机冒烟（hub CI smoke job） | — |
| L5 并发 | 同 upload_id Complete、配额竞争、下载计次、重复请求 | -race 下 N 并发断言唯一性 | **已建**：100 并发 Complete 幂等（既有）+ 取件计次并发 + 自定义取件码风暴 + 配额账本目录维度并发（新增） | 已知缺口：目录配额的跨副本并发不在覆盖内（§5） |
| L6 故障注入 | 存储失联、Redis 故障、Pod Kill、断网、磁盘满 | 故障注入后断言降级/恢复行为 | **已建**：16 个测试文件 / 37 个用例 / 5 个真实缺陷已修（新增） | — |
| L7 升级 | N-1/N-2 升级、数据完整性、配置迁移、失败回滚 | 破坏性升级失败后可恢复/可回滚的自动化断言 | **已建**：三端升级断言收编（既有）+ N-1/N-2 制品级矩阵 + 迁移失败注入（新增） | 已知缺口：desktop 不做脚本化升级演练（§5） |
| L8 安全 | 认证旁路、越权、SSRF、取件码枚举、路径逃逸、资源耗尽 | 专项安全用例 + security.yml | **已建**：系统化矩阵 + 双向对账门禁（新增）+ 下载令牌密钥数据竞争修复 | 已知缺口：SSRF 拨号期 TOCTOU（§5） |

## 2. 三项强制测试（issue 正文明示的最小可交付）

| # | 测试 | 层 | 落点 | 判据 | 负对照（改坏必红） | 状态 |
|---|---|---|---|---|---|---|
| ① | 100 并发 Complete 幂等 | L5 | core：`app/presign/force3_concurrent100_test.go`、`gen/handler/chunk/force3_concurrent100_test.go` | 100 方全部成功、同分享码；分享表恰 1 行；`uploads/` 合并产物恰 1 份 | 撤 `uploadlock.Lock` ⇒ 两用例均红（实跑：presign 建分享数≠1；chunk 无锁合并互相踩踏 500） | ✅ 已落 core CI（`go test -race ./...`） |
| ② | 可恢复备份：隔离目录逐文件 sha256 | L4/L7 | core：`app/backup/force3_restore_isolated_test.go` | 源/目标各自独立 DataPath+DB；每对象落盘 sha256 == manifest 摘要 == 源原始内容；文件数恰等 manifest 对象数 | restore 落盘前翻转首字节 ⇒ 三对象 sha256 断言全红（实跑） | ✅ 已落 core CI |
| ③ | 破坏性升级可恢复（统一入口） | L7 | hub：`scripts/check-upgrade-recoverability.sh` + ci.yml `upgrade-recoverability` job | 三端（qnap/synology/fnos）升级套件全绿 **且** 关键升级断言必须出现在输出（断言消失=红）：截断包中止 / 备份失败中止 / 快照轮转+逐字一致 / 换装断言+C7 负对照 | `--selfcheck` 五形态：跳过放行、半截检出红、全绿放行、套件红⇒红、断言缺失⇒红（实跑全过） | ✅ 已挂 hub CI |

### ③ 的覆盖语义（按平台语义映射 issue 三种失败）

| issue 要求 | 平台断言（既有测试收编，本脚本不重写） |
|---|---|
| 升级中断 | qnap：截断包在解包前被拦下 ⇒ 已装内容原封不动 |
| 空间不足 | qnap/synology：备份 cp 失败 ⇒ 中止安装/升级（真 ENOSPC 无法离线注入，以 cp 失败走同一中止分支代理），中止路径不留下半份快照 |
| 迁移失败可回滚 | qnap/synology：preupgrade 快照业务库、轮转保留 3 份、快照与源库逐字一致（回滚点物证）；fnos：换装失败网关/版本断言非 0 退出 + 补救命令 |

## 3. 剩余矩阵项 —— 已全部兑现（逐条列交付出处）

> 2026-11-16 立项时列的「本轮不做、按层排期」六项，已随 6.2.0 → 6.6.0 五趟车**全部兑现**。

> 本节与 ROADMAP 里的数字均为**实测值**（取自各仓**合并后**的提交，非计划值）：
> core#228 = 16 个测试文件 / 2637 行新增 / 37 个新用例；
> core#229 = `pkg/l8/matrix.json` 828 行 + 10 个新测试文件。

| 原剩余项 | 交付出处 |
|---|---|
| **L5**：配额竞争（reserve/扣减并发）、下载计次并发、重复请求风暴 | 取件计次并发 + 自定义取件码并发风暴（6.2.0）· 配额账本目录维度并发（6.5.0）—— [core#227](https://github.com/pigeonbox/core/pull/227) · [core#230](https://github.com/pigeonbox/core/pull/230) |
| **L6 整层**：存储失联 / Redis 故障 / Pod Kill / 断网 / 磁盘满的故障注入框架与代表用例 | L6 故障注入整层（16 个测试文件 / 2637 行 / 37 个用例）+ 5 个真实缺陷修复 —— [core#228](https://github.com/pigeonbox/core/pull/228) |
| **L7**：N-1/N-2 制品级升级矩阵（真装 → 升级 → 数据完整性对账）、迁移中途失败注入 | 静态门禁 + 发布后真演练（6 平台 12/12 格全绿）+ 迁移失败注入（统一入口由五形态扩到七形态）—— [hub#423](https://github.com/pigeonbox/pigeonbox/pull/423) |
| **L8 整层**：认证旁路 / 越权 / SSRF / 取件码枚举 / 路径逃逸 / 资源耗尽的系统化安全用例矩阵 | 系统化矩阵（机器可读清单）+ AST 级双向对账门禁 + 下载令牌密钥数据竞争修复 —— [core#229](https://github.com/pigeonbox/core/pull/229) |
| **L2**：跨版本前后端错误码兼容的常态化断言 | contracts 错误码基线（67 码）+ `--check` 自检 + core 侧业务码登记守卫 + hub 侧跨仓对账门禁 —— [contracts#37](https://github.com/pigeonbox/contracts/pull/37) · [contracts#38](https://github.com/pigeonbox/contracts/pull/38) · [frontend-core#123](https://github.com/pigeonbox/frontend-core/pull/123) · [frontend-core#124](https://github.com/pigeonbox/frontend-core/pull/124) · [hub#420](https://github.com/pigeonbox/pigeonbox/pull/420) · [core#227](https://github.com/pigeonbox/core/pull/227) |
| **L3**：MinIO / WebDAV 常态化集成用例 | 进程内真 WebDAV 服务 + 容器化 MinIO（env 门控 + 「没扫到 ⇒ 判红」开关）—— [core#231](https://github.com/pigeonbox/core/pull/231) |

## 4. 本轮挖出并修复的真实缺陷

> 补质量证据的过程本身就是找缺陷的过程：下表每一条都是**先由机械判据暴露、再当场修掉**的，
> 不是审计清单里的「已知问题」。

| 缺陷 | 位置 | 后果 | 修法 | 交付 PR |
|---|---|---|---|---|
| 基线生成脚本的 EXIT trap 覆盖退出码（成功哨兵形态） | contracts `scripts/gen-errcode-baseline.sh` | 脚本报错却 `exit 0` ⇒ 本地 `&&` 链假绿、CI 才红 | trap 内先取 `$?`：`rc≠0` 原样退出，`rc=0` 且成功哨兵未置位 ⇒ 退出 1 | [contracts#38](https://github.com/pigeonbox/contracts/pull/38) |
| 手抄错误码表漏 30014（手抄 66 条 vs 真相源 67 条） | frontend-core 错误码映射表 | 该码在五门语言里没有文案 ⇒ 界面显示键名原文 | 消灭手抄表，改为机器推导的**四向守卫**（键形 / 语义 / 映射⇄五门语言双向 / 未知码段位兜底） | [frontend-core#123](https://github.com/pigeonbox/frontend-core/pull/123) |
| 10 个已登记业务码的 HTTP 映射全落 HTTP 200 | core `pkg/resp` 错误码→HTTP 映射 | 业务错误进 200，客户端分辨不出成败 | 补齐映射（`10000`→500、`20010`→404、`40004`/`40009`→403、`40007`→401、`40010`/`40011`→400、`90001`~`90003`→502） | [core#227](https://github.com/pigeonbox/core/pull/227) |
| 单文件直传建分享失败未回滚已落盘文件 | core 直传建分享路径 | 孤儿文件不计入配额账本 ⇒ **磁盘可绕过 `storage.quota`** | 新增回滚 + 接线守卫 | [core#227](https://github.com/pigeonbox/core/pull/227) |
| Redis 连接错误被当致命 | core 匿名取件域 | **整个匿名取件面不可用**（DB 回源路径就在旁边） | 降级回落 DB | [core#228](https://github.com/pigeonbox/core/pull/228) |
| 铸造时 KV 写失败回滚了 DB 取件码并报错 | core 取件码铸造 | 与本域契约自相矛盾（DB 取件码已可用却报错） | 保留 DB 取件码、不阻断出码 | [core#228](https://github.com/pigeonbox/core/pull/228) |
| 铸造失败物理删除刚建好的分享行 | core 分享铸造 | 用户刚上传的分享凭空消失 | 不物理删除刚建好的分享行 | [core#228](https://github.com/pigeonbox/core/pull/228) |
| 预签名会话存储故障返回裸 error | core 预签名会话 + handler Abort 出口 | handler 兜底 30008 / HTTP 500 ⇒ 前端无法分辨「服务暂时不可用」与「参数非法」 | 改为 typed error（`10006` ⇒ **HTTP 503**），并把 handler 的 Abort 出口一并收口（原先写死 500） | [core#228](https://github.com/pigeonbox/core/pull/228) |
| 备份导出用**吞错的** `FileExists` 判定「对象不存在」 | core 备份导出 | 后端宕机时每个对象都被记成 missing、备份「成功」产出空 `objects/` ⇒ **DR 包在最需要它的时刻静默漏对象** | 改为错误可见的存在性探测（后端故障 ⇒ 导出必须失败；对象真不存在 ⇒ 仍按 missing 记录） | [core#228](https://github.com/pigeonbox/core/pull/228) |
| 下载令牌密钥的数据竞争（裸切片） | core 下载令牌密钥 | `go test -race` 报 DATA RACE | 改 `atomic.Pointer[[]byte]` | [core#229](https://github.com/pigeonbox/core/pull/229) |

## 5. 仍未关闭（外部条件与已知缺口）

**外部条件阻塞**（需真机 / 凭据 / 送审，代码侧推不动）：

- [hub#240](https://github.com/pigeonbox/pigeonbox/issues/240) 真机验收与分发清单；
- [openwrt#110](https://github.com/pigeonbox/openwrt/issues/110) iStore 真机复验；
- [terramaster#99](https://github.com/pigeonbox/terramaster/issues/99) TOS 7 待凭据 + 真机；
- [ugreen#132](https://github.com/pigeonbox/ugreen/issues/132) UPK 送审 + 真机。

**已知产品缺口**（已登记在案，**未修**）：

- **SSRF 拨号期 TOCTOU** —— 端点主机名校验只做一次，存储后端连接时无拨号期复判
  ⇒ 存在 DNS 重绑定窗口；
- **远端 presign 孤儿清理在 S3/WebDAV 后端几乎扫不到对象 ⇒ 孤儿永久泄漏**
  （本轮 L3 集成用例挖出，[core#231](https://github.com/pigeonbox/core/pull/231)）；
- **WebDAV 分片合并全量进内存**且不受 `MaxWholeReadBytes` 约束
  （本轮 L3 集成用例挖出，[core#231](https://github.com/pigeonbox/core/pull/231)）；
- **WebDAV 每次写先 `MkdirAll`**（本轮 L3 集成用例挖出，[core#231](https://github.com/pigeonbox/core/pull/231)）；
- **`ListRemoteObjects` 的 Key 口径跨后端不一致**
  （本轮 L3 集成用例挖出，[core#231](https://github.com/pigeonbox/core/pull/231)）；
- **目录配额的跨副本并发** —— 同既有账本边界，彻底收口需 DB 侧序列化点；
- **desktop 不做 N-1/N-2 脚本化升级演练** —— 安装包形态 + OS 托管数据目录。

## 6. 关联

- issue：[pigeonbox/pigeonbox#364](https://github.com/pigeonbox/pigeonbox/issues/364)（分层质量矩阵 L1–L8）
- 关联缺陷：core#151（并发不幂等，已由 core#158 修）、core#169（配额账本）
- 本轮回填 PR（hub#364 最小可交付）：core（测试①②）、hub（测试③ + 本文档）
- 本轮回填 PR（6.2.0 → 6.6.0）：
  contracts [#37](https://github.com/pigeonbox/contracts/pull/37) / [#38](https://github.com/pigeonbox/contracts/pull/38) ·
  frontend-core [#123](https://github.com/pigeonbox/frontend-core/pull/123) / [#124](https://github.com/pigeonbox/frontend-core/pull/124) /
  [#125](https://github.com/pigeonbox/frontend-core/pull/125) ·
  hub [#420](https://github.com/pigeonbox/pigeonbox/pull/420) / [#423](https://github.com/pigeonbox/pigeonbox/pull/423) ·
  core [#227](https://github.com/pigeonbox/core/pull/227) / [#228](https://github.com/pigeonbox/core/pull/228) /
  [#229](https://github.com/pigeonbox/core/pull/229) / [#230](https://github.com/pigeonbox/core/pull/230) /
  [#231](https://github.com/pigeonbox/core/pull/231) ·
  p2p [#62](https://github.com/pigeonbox/p2p/pull/62) ·
  charts [#33](https://github.com/pigeonbox/charts/pull/33)
- 当前主线的对外叙述：[ROADMAP.md「当前主线（2026-11-18 起：L1–L8 质量证据驱动）」](../../ROADMAP.md)；
  四批次逐条交付状态：[2026-11-14 路线稿 §8](2026-11-14-reliability-security-roadmap.md)
