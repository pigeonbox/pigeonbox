# 发布列车 v3:一条命令 + 库线收进列车

- 日期: 2026-10-27
- 状态: **已实施**(代码落地 + 单测绿 + 门禁绿;首航待下一趟车验证)
- 取代: `2026-10-12-release-train-v2-design.md` 的**编排拓扑与操作面**(状态机语义、
  train.yaml 真相源、verify 对账、tag 断言全部保留不变)
- 拍板: 用户 2026-10-27 就两个岔路口拍板 —— ①**库线发版收进列车自动完成**
  (授权列车自己推库线 tag + 等模块代理同步);②**单次 CI 运行内自轮询到 shipped**
  (不再靠「回调 + cron」两套唤醒源)

## 1. 背景:为什么「慢 + 复杂」

### 1.1 实测数据(2026-10-27)

| 观察项 | 实测 | 出处 |
|---|---|---|
| bump PR 合并 → 组件 tagged → shipped | 8~46 分钟(多数 15~25) | hub git log 近 12 趟列车的三段提交时间 |
| `*/15` 的兜底 sweep 实际触发间隔 | **2~4 小时**(平均 2.6h) | `gh run list --event schedule` 抽样 20 次触发时刻 |
| 编排器每次开跑 | **串行克隆 15 个仓** | `train-orchestrator.yml` 的 clone 循环 |
| bump 阶段 | 4 次 `go mod tidy` + 4 次 `npm install --package-lock-only` + 3 次模板物化,**全串行** | `bump.go` 的 `goModPin` / `lockRefresh` / `nasPlatforms` |
| 操作面 | `make train-bump TRAIN=x.y.z SET="core=… core_pin=…"` —— 钉版要人算 | Makefile + AGENTS.md「十个必守点」第 1 条 |
| 库线发版 | **在列车之外**人工先打 tag,否则 bump 以「库线悬空钉」直接拒发 | `bump.go` 的悬空钉守卫 |

### 1.2 两个结构性根因

1. **推进靠两套唤醒源,而其中一套是假的。** 组件 Release 的 `repository_dispatch`
   回调只在「回调真的发出去」时有效;兜底 cron 名义 `*/15`,实测每 2~4 小时才跑一次
   ⇒ **回调一丢,列车就静默卡几小时**,而且没人知道卡在哪(日志在另一个 run 里)。
2. **库线发版不在状态机里,而库线恰恰是产品线的输入。** 一趟车要人工排两段序:
   先在 4 个库仓各打 tag(还要等模块代理同步),再发车。漏一步 ⇒ bump 拒发
   (3.3.16 实录卡在 draft)。

### 1.3 复杂度的真实来源不是代码行数

trainctl 已 5.4k 行/26 个测试文件,但**发车者要记的东西**才是复杂度:

- 要记得算对四个库线钉版(`core`/`contracts`/`p2p`/`frontend-core`);
- 要记得 bump 完还要跑 `advance`;
- 要记得 `--set` 里 `core` 与 `core_pin` 成对出现(漏一个就撞「裸奔 tag 拦截」);
- 要在卡住时知道去哪儿看(哨兵 issue 只在停滞时才开,且**曾经只开不关**)。

⇒ v3 的目标不是「把代码写短」,而是**把发车者要记的步骤从 4 步压到 1 步**。

## 2. 目标与验收标准

| # | 目标 | 验收 |
|---|---|---|
| G1 | **一条命令开完整趟车** | `make train TRAIN=x.y.z` 一次 dispatch 到 shipped,发车者不再手动跑 advance |
| G2 | **推进不依赖 cron 频率** | 正常路径全程在**同一次 CI 运行内**自轮询;cron 只做崩溃接力 |
| G3 | **库线不用人算** | 常态发车不传 `SET=`;`lib.*` 自动跟随各库仓最新已发布 tag |
| G4 | **库线发版收进列车** | 传 `SET="core=vX"` 时,列车自己打那个 tag 并等它可消费,再 bump |
| G5 | **不许发错版** | 打库线 tag 前断言:版本声明一致 + semver 单调性 |
| G6 | **不许把「没就位」当成「已就绪」** | 等 Go 模块代理可拉 + npm tgz 资产已挂,才允许 bump |
| G7 | **改动不放大事故面** | bump 的切分支/三方合并/暂存链路**一行未改**;新逻辑独立成文件 |

## 3. 架构

```
make train TRAIN=4.0.6
   │  gh workflow run train-orchestrator.yml -f phase=run
   ▼
train-orchestrator(一次运行 · timeout 180min · 15 仓并行克隆)
   │
   └─ trainctl run
        ├─[0] 库线    resolveLibVersions → ensureLibTag → waitLibConsumable
        │            (解析钉版)      (必要时自打 tag)   (等代理/tgz 就位)
        ├─[1] bump    结构化写 15+ 版本点 → 各仓 train/<v> 分支 + PR(自动合并)
        │            ★ 各仓之间并行(仓内逻辑不动)
        ├─[2] 合并    自轮询 advanceDraft:checks 绿即合并;红 ⇒ 快速失败
        ├─[3] 发货    自轮询 advanceTagged:镜像齐 → charts → 产物齐 → verify → 快照
        └─ 全程幂等可重入(重跑跳过已完成项)
```

**唤醒源降级为兜底**:组件 Release 的回调与 cron 都保留,但正常路径不再依赖它们
——回调仍会触发 advance(无害:state=shipped 时秒退)。

## 4. 库线(contracts/core/p2p/frontend-core)收进列车

### 4.1 版本解析的三级优先

| 优先 | 来源 | 语义 |
|---|---|---|
| 1 | `--set <lib>=<ver>` | 显式钉版;**列车负责发布**(未发布则自己打 tag) |
| 2 | 各库仓**最新已发布 tag** | 默认;与 `go get -u` 同语义;**只升不降** |
| 3 | `--freeze-libs` | 冻结在 train.yaml 现钉版 |

「只升不降」是硬约束:现钉版比最新 tag 还新(本地未同步/预发布)时保持现钉版,
否则会把钉版降级 ⇒ 产物里的库线比计划旧。

### 4.2 打 tag 的两道断言(G5)

1. **仓内版本声明一致**:`contracts` 的 `package.json`、`frontend-core` 的 `VERSION`
   ——发布流水线是「按 tag 覆写版本号」(contracts release.yml 的 `npm version`),
   所以声明与 tag 不一致 = **把 A 的代码发布成 B 的版本**。
   `core`/`p2p` 无仓内声明(Go 惯例:tag 即版本)⇒ 只做下一道断言。
2. **semver 单调性**:目标版本必须高于该仓现有最新 tag ⇒ 版本号不可复用/倒退。

### 4.3 「可消费」的判据(G6)

| 库类型 | 判据 | 不就位的后果 |
|---|---|---|
| Go 库(core/contracts/p2p) | 模块代理能拉到该版本(`<proxy>/<module>/@v/<ver>.info` = 200) | 产品线 go.sum 物化不出来 ⇒ 组件 CI 全红在 missing go.sum entry |
| npm 库(contracts/frontend-core) | 该仓 Release 上挂了 `<pkg>-<ver>.tgz` 资产 | 消费仓 `npm ci` 拒装 ⇒ 壳仓与 NAS web/ 的 CI 红 |

探测口径**与消费方一致**:GOPROXY 已设置时只探它(尊重企业代理/`off`/只用一个镜像),
未设置才探官方 + goproxy.cn 两档。

## 5. 提速的具体做法

| 做法 | 省什么 | 风险控制 |
|---|---|---|
| 同一次运行内自轮询 | 回调丢失时的**小时级**空转 | 状态机语义不变,`advance` 仍是单步幂等接口 |
| 15 仓**并行**克隆 | 每次开跑的几分钟 | **不用 `--depth`/`--filter`**:列车分支要快进合并,浅克隆会让远端同名分支丢历史 ⇒ push non-fast-forward(3.3.16 同型) |
| 各仓 bump **并行** | bump 阶段的 tidy/npm/物化串行等待 | 只在**仓之间**并行;仓内切分支/三方合并/暂存链路一行未改;NAS 三仓仍串在 hub 之后(模板源是 hub 本地工作树) |
| bump 的锁与计划表加锁 | 并行下的 map 竞态 | `bump.mu`;`go test -race` 实跑无 DATA RACE |

## 6. 不变量(改动这条链前先读)

1. **推进归编排器自己**:正常路径全程在同一次运行内;cron 是兜底不是主路径。
   ⚠️ **别把 cron 的 `*/15` 当成「每 15 分钟」**——GitHub 的 schedule 实测漂到小时级。
2. **判「最新」一律 semver 排序**:禁用 tag creatordate;非 semver tag
   (`desktop-v4.0.5` 这类异命名空间)不参与排序。
3. **只升不降**:库线钉版解析绝不降级。
4. **打库线 tag 前两道断言**:版本声明一致 + semver 单调性;不满足 ⇒ 响亮失败,
   绝不打错版本。
5. **不就位不 bump**:库线必须「可消费」才允许动产品线。
6. **失败要立刻返回**:红着的检查不会自己变绿,干等只是烧 runner ⇒ `run` 快速失败,
   并开哨兵 issue(`advance` 的老路径仍只告警不让 sweep 变红)。
7. **检查结论按「最新一次 attempt」判**:`gh pr checks` 会把重跑前的失败 attempt 也
   列进来 ⇒ 重跑绿了仍被判停滞 ⇒ 合并判定与停滞判定**共用同一份实现**
   (`checksLatest`),两边不会再自相矛盾。
8. **bump 的切分支/三方合并/暂存链路不动**:那三段有事故史(3.3.28 静默空转 /
   3.3.30 版本分叉 / 3.3.16 非快进),并行只发生在仓之间。

## 7. 兼容与迁移

| 旧接口 | 状态 | 说明 |
|---|---|---|
| `make train-bump TRAIN=… SET=…` | 保留 | 只开列车(= `phase=bump`),不推进 |
| `make train-advance` | 保留 | 单步推进(= `phase=advance`)= 崩溃接力与人工兜底 |
| `make train-finalize` | 保留 | `advance` 的别名 |
| `make train-bump-local` | 保留 | 本地直跑 bump(dry-run 零落盘) |
| `make train-run-local` | **新增** | 本地直跑整趟车 |
| `make train TRAIN=…` | **新增(推荐)** | 一条命令开完整趟车 |

`trainctl bump` 的**库线钉版语义变了**:从「冻结在 train.yaml」改为「默认自动跟随
最新已发布 tag」。这是**有意的**:它消灭了「人算钉版」这个漏点。不想带库线升级时
用 `--freeze-libs`。

## 8. 验证

- `release/trainctl` 全量单测绿(含新增 `libline_test.go` / `run_test.go`),
  `go test -race` 无 DATA RACE;
- bump 的 dry-run 计划在并行化前后**逐字一致**(基线/对拍);
- 仓内门禁全绿:`check-action-pins.sh`、`check-docs-consistency.sh`、
  `check-gofmt-all.sh`、`check-required-checks.sh`;
- 编排器工作流 YAML 合法,`phase` 选项含 `run`。

## 9. 首航待办

1. 下一趟车用 `make train` 发,观察「单次运行内到 shipped」的端到端时长;
2. 首航后核对:库线自动跟随的钉版是否符合预期(尤其 core 已在 v0.32.21 而
   train.yaml 还钉 v0.32.19 的历史差);
3. 若 `--set` 打库线 tag 的路径首次使用,确认「版本声明断言」拦得住误操作。
