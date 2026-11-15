# PigeonBox SLO 与错误预算基线

> 状态：**v1 基线（2026-11-16）**。本文件定义可计算的 SLI/SLO、错误预算与燃烧率告警。
> 只对 `/metrics` 里**真实存在**的指标写目标；没有埋点的 SLI 明确列在 §5，不写目标、不计预算
> （遵循 issue #384「先埋点后承诺」）。
>
> - 指标真相源：`core` v0.40.0（`release/train.yaml` 的 `lib.core`）
> - 指标暴露：`bootstrap/handlers_public.go:250` 的 `/metrics`；服务默认监听
>   `127.0.0.1:9090`（`conf/config.go:203-215`），K8s base 已改为 `0.0.0.0:9090` 并加
>   `metrics` Service 端口（见 `deploy/k8s/base/`），由 ServiceMonitor 抓取。
> - 告警规则：[`deploy/k8s/base/prometheusrule.yaml`](../deploy/k8s/base/prometheusrule.yaml)
> - 采集/校验：`promtool check rules deploy/k8s/base/prometheusrule.yaml`；CI 的
>   `docs-consistency` job 另跑 `scripts` 治理测试（指标名必须能在 core 源码中找到）。

## 1. SLI / SLO 总表

| SLO | SLI（用户视角） | 真实指标 | 目标 | 窗口 | 错误预算 |
|---|---|---|---|---|---|
| SLO-1 寄件成功率 | 创建分享成功（2xx/3xx）/ 排除客户端拒绝后的创建请求 | `http_requests_total{method="POST",path=~…,status=…}` —— `core/pkg/middleware/metrics.go:55` | **99.5%** | 28 天 | **0.5%**（约 3h22m） |
| SLO-2 取件成功率 | 取件交付成功（2xx/3xx）/ 排除过期、次数耗尽、鉴权/限流拒绝后的取件请求 | `http_requests_total{method="GET",path=~…,status=…}` —— `core/pkg/middleware/metrics.go:55` | **99.9%** | 28 天 | **0.1%**（约 40m） |
| SLO-3 上传完成请求耗时 | 95% 的 complete 请求在 **2.5s** 内完成（服务端处理段） | `http_request_duration_seconds_bucket{method="POST",path=~…,le="2.5"}` —— `core/pkg/middleware/metrics.go:59` | **p95 ≤ 2.5s** | 28 天 | **5%** 的 complete 请求可超过 2.5s |

> 窗口统一 28 天（滚动窗口），错误预算 = 窗口内允许的失败/慢请求比例。
> 辅助计数器（不作为 SLI 分母，仅用于解释量级/诊断）：
> `pb_share_created_total{upload_type}`（`core/pkg/metrics/business.go:35`）、
> `pb_upload_bytes_total{channel}`（同文件 `:30`）、
> `pb_upload_rejected_total{reason}`（同文件 `:40`）。

## 2. SLI 口径与 PromQL

### SLO-1 寄件成功率

**纳入的创建入口**（覆盖直传 / 分片 / presign 三通道 + 多文件）：

| 通道 | 路由 | 代码位置（core v0.40.0） |
|---|---|---|
| 直传文件 | `POST /share/file/` | `gen/router/share/share.go:44-45` |
| 直传文本 | `POST /share/text/` | `gen/router/share/share.go:52-53` |
| 多文件直传 | `POST /api/v1/share/multi-direct` | `gen/handler/publicapi/public_api_service.go:40` |
| 多文件绑定 | `POST /api/v1/share/multi-bind` | `gen/handler/publicapi/public_api_service.go:47` |
| 分片完成 | `POST /chunk/upload/complete/:upload_id` | `gen/router/chunk/chunk.go:36-37` |
| presign 完成 | `POST /api/v1/presign/complete` | `gen/router/presign/presign.go:27` |

**口径**：

- 成功 = HTTP `2xx` / `3xx`；失败 = HTTP `5xx`。
- 分母排除 `4xx`（配额/类型/大小/参数等**客户端拒绝**不算服务可靠性失败）。
- 单次请求可能代表一个分享；`pb_share_created_total` 只用于核对成功量级。

```promql
# 28d 成功率（滚动）
sum(rate(http_requests_total{
  method="POST",
  path=~"/share/file/?|/share/text/?|/api/v1/share/multi-direct|/api/v1/share/multi-bind|/chunk/upload/complete/:id|/api/v1/presign/complete",
  status=~"2..|3.."
}[28d]))
/
sum(rate(http_requests_total{
  method="POST",
  path=~"/share/file/?|/share/text/?|/api/v1/share/multi-direct|/api/v1/share/multi-bind|/chunk/upload/complete/:id|/api/v1/presign/complete",
  status!~"4.."
}[28d]))
```

> `path` 标签由 `core/pkg/middleware/metrics.go` 的 `normalizePath` 归一化：动态段（如
> `upload_id`）落为 `:id`，因此分片完成路径在指标里是 `/chunk/upload/complete/:id`。

### SLO-2 取件成功率

**纳入的取件交付入口**：

| 入口 | 路由 | 代码位置（core v0.40.0） |
|---|---|---|
| 取件详情/文本正文 | `GET /share/select/` | `gen/router/share/share.go:48-49` |
| 文件/文本下载 | `GET /share/download` | `gen/router/share/share.go:42` |

**口径**：

- 成功 = HTTP `2xx` / `3xx`（含 Range `206` 与 s3 直下 `302`）。
- 分母排除 `401`（密码/令牌错误）、`403`（取件次数耗尽 / 被封禁 / 待审）、
  `404`（不存在 / 已过期）、`429`（限流/枚举锁定）——这些是**用户可见的业务拒绝**，
  不消耗可靠性预算；其中「次数耗尽 20004」与「已过期」正是 issue #384 要求排除的两类。
- 其余 `4xx`（如 400 参数错、416 Range 不可满足）与 `5xx` 计入失败。

```promql
sum(rate(http_requests_total{
  method="GET",
  path=~"/share/select/?|/share/download",
  status=~"2..|3.."
}[28d]))
/
sum(rate(http_requests_total{
  method="GET",
  path=~"/share/select/?|/share/download",
  status!~"401|403|404|429"
}[28d]))
```

### SLO-3 上传完成请求耗时

**口径**：

- 指标是 HTTP 直方图 `http_request_duration_seconds{method,path}`，桶边界为
  `0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10`（`pkg/middleware/metrics.go:45-48`）。
- SLO 取 `le="2.5"`：`p95 ≤ 2.5s` 等价于「超过 2.5s 的请求比例 ≤ 5%」。
- 覆盖 `POST /chunk/upload/complete/:id` 与 `POST /api/v1/presign/complete`。
- ⚠️ **范围诚实**：这是「服务端 complete 请求处理耗时」，**不包含**客户端从 `init` 到
  `complete` 的整段上传时间。init→complete 的端到端耗时目前没有会话级直方图，
  属于 §5 的埋点缺口；不得用本 SLO 冒充端到端上传耗时。

```promql
# p95（28d，按通道可加 path 过滤分别看）
histogram_quantile(0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket{
    method="POST",
    path=~"/chunk/upload/complete/:id|/api/v1/presign/complete"
  }[28d]))
)

# 慢请求比例（燃烧率告警的 SLI）
1 - (
  sum(rate(http_request_duration_seconds_bucket{
    method="POST",
    path=~"/chunk/upload/complete/:id|/api/v1/presign/complete",
    le="2.5"
  }[28d]))
  /
  sum(rate(http_request_duration_seconds_count{
    method="POST",
    path=~"/chunk/upload/complete/:id|/api/v1/presign/complete"
  }[28d]))
)
```

## 3. 错误预算与燃烧率

### 3.1 预算

| SLO | 28 天预算 | 允许失败/慢请求 |
|---|---|---|
| SLO-1 | 0.5% | 约 201.6 分钟当量（按请求比例计） |
| SLO-2 | 0.1% | 约 40.3 分钟当量（按请求比例计） |
| SLO-3 | 5% | 每 100 个 complete 请求允许 5 个 > 2.5s |

### 3.2 燃烧率告警口径（多窗口）

采用 Google SRE Workbook 的多窗口多燃烧率：

| 燃烧率 | 长窗口 | 短窗口 | 预算消耗 | 处理 |
|---|---|---|---|---|
| **14.4x** | 1h | 5m | 1 小时内烧掉 2% | **page（critical）** |
| **6x** | 6h | 30m | 6 小时烧掉 5% | **ticket（warning）** |
| **1x** | 3d | 6h | 3 天烧掉 10% | **ticket（warning）** |

阈值 = 燃烧率 × 错误预算：

| SLO | 14.4x 阈值 | 6x 阈值 | 1x 阈值 |
|---|---|---|---|
| SLO-1（0.5%） | 7.2% | 3.0% | 0.5% |
| SLO-2（0.1%） | 1.44% | 0.6% | 0.1% |
| SLO-3（5%） | 72% | 30% | 5% |

> SLO-3 的 14.4x 阈值看起来很高（72% 请求 >2.5s），这是 95% 延迟 SLO 的数学结果；
> 实际 page 条件同时要求 1h 与 5m 都越过阈值，避免单点抖动误报。

规则实现：`deploy/k8s/base/prometheusrule.yaml` 的 `pigeonbox.slo` / `pigeonbox.slo.alerts`
两组；每个告警都带 `runbook_url` 指回本文对应小节。

### 3.3 预算耗尽时的发布策略

| 剩余预算 | 发布策略 |
|---|---|
| > 50% | 正常发布 |
| ≤ 50% | 暂停非安全/非关键修复发布；安全修复走 hotfix |
| 0% | 冻结常规发布，直到 28 天窗口恢复；只允许安全修复与回滚 |

预算判定以本文 PromQL 为准；`pb_upload_rejected_total{reason="quota"}` 等业务拒绝
**不**计入 SLO 失败，但可作为容量告警的辅助信号（charts 已有
`PigeonBoxQuotaRejectionsSpike` 先例）。

## 4. 告警规则与校验

- 规则文件：`deploy/k8s/base/prometheusrule.yaml`（Prometheus Operator `PrometheusRule`）。
- 抓取：`deploy/k8s/base/servicemonitor.yaml` 指向 `metrics` 端口（9090）；K8s base 的
  configmap 设置 `PB_METRICS_ADDR=0.0.0.0:9090`，Service 暴露 `metrics` 端口。
- 本地校验：

```bash
promtool check rules deploy/k8s/base/prometheusrule.yaml
# 没有 promtool 时至少做 YAML 语法校验：
python3 -c 'import yaml,sys; yaml.safe_load(open("deploy/k8s/base/prometheusrule.yaml"))'
```

- CI 校验：`docs-consistency` job 在检出 `core` 后跑
  `(cd scripts && REQUIRE_SOURCE_METRICS=1 GOWORK=off go test -run 'TestSupportPolicyAndSLO' -v ./...)`；
  该测试会断言规则里出现的 `pb_*` / `http_*` 指标名都能在 core 源码中找到定义，
  并断言 SLO 文档引用的指标名与规则一致（防止文档/规则各写一套）。

## 5. 未埋点 SLI（不设目标、不计预算）

以下三项是 issue #384 的目标，但当前 core v0.40.0 的 `/metrics` **没有对应指标**。
按「先埋点后承诺」：先加计数器/直方图积累 2–4 周基线，再在本文件补目标；在此之前
**不得**在告警规则里引用下列名称（CI 会拦）。

| 缺失 SLI | 现状采集点 | 需要的指标契约（待核心仓实现） | 阻塞/关联 |
|---|---|---|---|
| GC 积压（待清理对象数 / 最老任务年龄） | 远端 presign 孤儿有只读统计 `CountRemotePresignOrphans`（`core/app/admin/janitor.go:303-306`，经 `/admin/storage/insights`）；本地孤儿/分片清理只有日志计数（`janitor.go:172` 等），无 Prometheus 指标 | `pb_gc_pending_jobs{kind}`（Gauge）、`pb_gc_oldest_job_age_seconds{kind}`（Gauge） | core#172 生命周期统一 |
| 备份恢复成功率 | `/admin/diagnostics` 有 `backup` 段（`core/bootstrap/diagnostics.go` 的 `AutoBackupStatus`，只覆盖定时备份状态）；恢复走 `core/app/backup/restore.go` 与离线 `pigeonbox restore`，无成功率指标 | `pb_backup_restore_total{result}`（Counter）、`pb_backup_last_success_timestamp_seconds`（Gauge） | hub#364 备份隔离恢复验收 |
| 升级成功率 | 各 NAS 包 preupgrade/postupgrade 脚本；平台侧，无统一 metrics | `pb_upgrade_attempts_total{platform,result}`（Counter） | hub#365 平台能力契约 |

> 埋点验收：上述指标出现在 `/metrics` 且有连续 2–4 周数据后，按 §1 模板补 SLI/SLO，
> 并在 `deploy/k8s/base/prometheusrule.yaml` 增加对应燃烧率告警；在此之前不写目标值。

## 6. 与诊断页的关系

`/admin/diagnostics` 仍提供容器/DB/Redis/存储/版本的即时快照，用于排障；
SLO 是**时间窗口内的用户视角**，两者不互相替代。一次人为故障注入后，按下列顺序看：

1. `slo:pigeonbox_*_error:ratio5m` / `slo:pigeonbox_upload_complete_slow:ratio5m` 哪条先恶化；
2. 对应 `http_requests_total{path,status}` 的路径/状态分布；
3. `/admin/diagnostics` 与日志中的 DB/Redis/存储/GC 线索。

## 7. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-16 | 首版：SLO-1/2/3 基线 + 燃烧率告警；GC/备份恢复/升级成功率列为未埋点缺口 |