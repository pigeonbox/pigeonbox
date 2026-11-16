# 分层质量矩阵 L1–L8：全景与三项强制测试落地状态

> 来源：[pigeonbox/pigeonbox#364](https://github.com/pigeonbox/pigeonbox/issues/364)
> （2026-11-14 生态技术评审 §六「从有 CI 到有可信质量证据」）。
> 本文是矩阵的**全景索引**：每层的覆盖判据、现状证据、缺口与归属仓。
> 本轮（hub#364 最小可交付）只落三项强制测试，见 §3；其余为后续排期。

## 1. 矩阵定义

| 层 | 覆盖 | 判据（什么算这层的证据） | 现状 | 缺口 |
|---|---|---|---|---|
| L1 单元 | 状态机、配额规则、计次语义、认证失败分支 | 仓内 `go test` 表驱动用例 | core 全量单测 + 路由守卫（`bootstrap` 测试） | 计次语义 17 条不变量已有专项设计稿与测试；认证失败分支覆盖分散 |
| L2 契约 | IDL 生成漂移、错误码语义、跨版本前后端兼容 | contracts 三条生成链 `CHECK=1` + openapi/gen-ts `--check` | 已有（contracts CI） | 错误码语义的**跨版本**前后端兼容用例尚无常态化断言 |
| L3 集成 | SQLite/MySQL/PG、Redis、MinIO、WebDAV | 换库真 PG/MySQL（core ci.yml:130） | 已有 | MinIO/WebDAV 仅 probe，无常态化集成用例 |
| L4 端到端 | 发布制品真装 → 登录/上传/取件/删除/恢复 | 真机冒烟 `scripts/smoke-full.sh`（49+ 项） | 已有（hub CI smoke job） | 「恢复」此前只验产物存在 ⇒ **本轮②补齐逐文件校验** |
| L5 并发 | 同 upload_id Complete、配额竞争、下载计次、重复请求 | -race 下 N 并发断言唯一性 | **本轮①补齐**（100 并发 Complete 双路径）；配额竞争/下载计次仍缺 | 配额竞争、下载计次并发用例 |
| L6 故障注入 | 存储失联、Redis 故障、Pod Kill、断网、磁盘满 | 故障注入后断言降级/恢复行为 | **无**（全生态 workflow grep 无命中） | 整层待建；磁盘满与 L7 的「空间不足」共享注入手段 |
| L7 升级 | N-1/N-2 升级、数据完整性、配置迁移、失败回滚 | 破坏性升级失败后可恢复/可回滚的自动化断言 | **本轮③收编**（三端既有断言统一入口挂 hub CI）；N-1/N-2 真装升级仍缺 | N-1/N-2 制品级升级矩阵、迁移失败注入 |
| L8 安全 | 认证旁路、越权、SSRF、取件码枚举、路径逃逸、资源耗尽 | 专项安全用例 + security.yml | 零散（取件码枚举入口钉桩、路径逃逸 reject 测试已有） | 无系统化安全测试层；越权/SSRF/资源耗尽矩阵 |

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

## 3. 剩余矩阵项（本轮不做，按层排期）

- **L5**：配额竞争（reserve/扣减并发）、下载计次并发、重复请求风暴；
- **L6 整层**：存储失联 / Redis 故障 / Pod Kill / 断网 / 磁盘满的故障注入框架与代表用例；
- **L7**：N-1/N-2 制品级升级矩阵（真装 → 升级 → 数据完整性对账）、迁移中途失败注入；
- **L8 整层**：认证旁路 / 越权 / SSRF / 取件码枚举 / 路径逃逸 / 资源耗尽的系统化安全用例矩阵；
- **L2**：跨版本前后端错误码兼容的常态化断言；
- **L3**：MinIO / WebDAV 常态化集成用例。

## 4. 关联

- issue：[pigeonbox/pigeonbox#364](https://github.com/pigeonbox/pigeonbox/issues/364)（分层质量矩阵 L1–L8）
- 关联缺陷：core#151（并发不幂等，已由 core#158 修）、core#169（配额账本）
- 本轮回填 PR：core（测试①②）、hub（测试③ + 本文档）
