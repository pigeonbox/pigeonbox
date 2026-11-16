# 诊断包与安装分布（hub#385）

> 两件事，一条命令 + 一个可选开关：
> 1. **本地优先**：`pb doctor --export` 导出诊断包，离线可交给维护者解析；
> 2. **可选匿名上报**（默认关闭）：`PB_UPDATE_REPORT_URL` 指向聚合端点后，
>    每次更新检查上报七个字段，用于回答「安全修复覆盖了多少活跃实例」。

## 1. 诊断包导出

```bash
# 人读结论（原有能力）
pb doctor

# 机器读结论（原有能力）
pb doctor --json

# 诊断包：{schema, exported_at, report, diagnostics} 一次写文件
pb doctor --export ./pb-diagnostics.json

# 写标准输出（管道用；与 --json 同时用会输出两段 JSON，别混用）
pb doctor --export - > ./pb-diagnostics.json
```

信封结构（`schema` 变化才升版）：

```jsonc
{
  "schema": "1",
  "exported_at": "2026-11-16T02:00:00Z",
  "report": { "server": "...", "checks": [...], "summary": {...}, "deep": true },
  "diagnostics": {
    "version": "5.8.0",
    "platform": "linux",         // hub#385 新增
    "arch": "arm64",             // hub#385 新增
    "upgrade_from": "5.7.0",     // hub#385 新增；全新安装缺省为空
    "schema_version": "000014",  // hub#385 新增；方言相关，AutoMigrate 形态为空
    "deployment_mode": "...", "database": {...}, "storage": {...},
    "update": {...}, "backup": {...}, "moderation": {...}
  }
}
```

- 文件权限 `0600`：诊断包含运行时事实（数据目录、存储后端、站点对外地址）。
- **导出是用户主动动作**：诊断包会包含站点对外地址等事实——交不交给维护者由用户
  决定。这与下面「默认关闭、只发七个字段」的匿名上报是两种不同授权。

## 2. 可选匿名上报（默认关闭）

| 项 | 值 |
|---|---|
| 开关 | `PB_UPDATE_REPORT_URL`（配置键 `update.report_url`），**默认空 = 完全不上报** |
| 时点 | 每次**成功**的更新检查（默认 24h 一次，带缓存；失败/离线不上报） |
| 传输 | `POST application/json`，5s 超时，fire-and-forget（失败不重试、不影响任何功能） |
| 实例标识 | 数据目录下 `instance-id`（16 字节随机 hex）；**删文件即重置**，与站点/账号/内容无映射 |

上报 body 的**完整字段清单**（契约——新增字段必须先改本表）：

| 字段 | 说明 |
|---|---|
| `version` | 当前构建版本（与 `/version` 同源） |
| `platform` | `runtime.GOOS`（linux/darwin/windows） |
| `arch` | `runtime.GOARCH`（amd64/arm64/armv7…） |
| `upgrade_from` | 上一次运行的版本（全新安装为空）——升级跨度 |
| `schema_version` | 已应用的迁移版本（未启用版本化迁移时为空；按 `database.driver` 分组看） |
| `instance_id` | 安装实例随机标识（仅用于同一实例去重） |
| `checked_at` | 本次检查时间（活跃度口径） |

**明确不采集**：站点域名/对外地址、用户与账号、分享码与文件内容、部署模式、
IP（端点可能自然记录来源 IP，但这不属于 payload；自建聚合端点的访问日志策略由
运营方负责并在自己的隐私说明里写清）。

关闭方法：去掉/清空 `PB_UPDATE_REPORT_URL` 并重启；此后不再产生任何上报。
重置实例标识：删除数据目录下的 `instance-id`。

## 3. 分布聚合（维护者侧）

```bash
# 收到的上报 JSONL（一行一条）或诊断包（--export 产物）目录
python3 scripts/version_distribution.py collected/
python3 scripts/version_distribution.py --latest 5.9.0 --series 5.6.0,5.7.0,5.8.0,5.9.0 collected/
cat collected/jsonl/*.json | python3 scripts/version_distribution.py -
python3 scripts/version_distribution.py --json collected/   # 机器读
```

输出：版本分布（含「落后 N 个版本」）、平台/架构分布、版本 × 平台交叉表；
有 `instance_id` 时按实例去重（同一实例多次上报只算一次）。

口径注意：

- `schema_version` 是**方言相关**的（SQLite 与 PostgreSQL 的迁移集版本号不同源，
  见 `app/dbmigrate/format.go` 头注）⇒ 跨方言聚合时按 `database.driver` 分组；
- 「活跃实例」= 在聚合窗口内有上报的实例（上报在更新检查成功时发生）；
  没开上报的实例不会出现在分布里——分布回答「开启上报的实例里版本占比」，
  不是全网绝对数。

## 4. 相关文档

- `docs/METRICS.md`：跨仓质量看板与指标口径（issue 分类/Triage 三态）；
- `docs/SLO.md`：服务可用性 SLO 与错误预算基线；
- `docs/ENVIRONMENT_VARIABLES.md`：`PB_UPDATE_*` 全量环境变量表；
- 公开看板：<https://github.com/orgs/pigeonbox/projects/1>（诊断相关平台的
  真机验收结论登记在对应 issue 与看板 Triage 字段）。