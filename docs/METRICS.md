# 跨仓质量指标（METRICS）

> 单源：口径与维护约定在本文件；**数字**由 `bash scripts/metrics.sh` 生成
> （stdout 或 `--out` 覆写），不手填——手填的数字必然漂移。
> 看板（GitHub Project「PigeonBox Ecosystem」）与本文件同源：分类/状态判定
> 都在 `scripts/board-lib.sh`。
> 背景与三个问题：[hub#366](https://github.com/pigeonbox/pigeonbox/issues/366)。

## 这份指标回答什么

多仓生态里单仓 issue 数不能代表产品质量。本文件（配合看板）回答三个问题：

1. **跨仓阻塞关系**——一个修复要动几个仓、卡在哪个引用链；
2. **已发布版本的缺陷数量**——按分类/仓切（见下方「按列车号」的口径缺口）；
3. **真机验证覆盖率**——哪些平台/版本真机过，哪些还悬着（真相源 [hub#240](https://github.com/pigeonbox/pigeonbox/issues/240)）。

## 怎么生成

```bash
bash scripts/metrics.sh                    # 打印 Markdown 到 stdout
bash scripts/metrics.sh --out /tmp/m.md    # 写文件（先写临时缓冲，失败不留半截）
bash scripts/board-sync.sh --dry-run       # 看板归档预览（CI 可跑，只读）
```

依赖：`gh`（已登录、有 repo 只读 scope 即可）、`jq`。**不需要 project scope**——
只有 `board-setup.sh` / `board-sync.sh` 真跑才要。

## 映射口径（真相源 `scripts/board-lib.sh`，此处为说明）

### Category 六分类（两阶段：前缀 > label/词面）

| 阶段 | 判据 | 归类 |
|---|---|---|
| A 前缀 | 标题 `【安全…` | Security |
| A 前缀 | `【平台…` / `【K8s…` | Platform |
| A 前缀 | `【正确性…` / `【架构…` | Correctness |
| A 前缀 | `【可靠…` `【发布…` `【测试…` `【门禁…` `【依赖…` | Reliability |
| A 前缀 | `【产品…` `【展望…` `【治理…` | Product |
| A 前缀 | `【生态…` | Community |
| B label | `security` / `bug` | Security / Correctness |
| C 词面 | 真机·分发·上架·K8s·NAS / CI·train-·SLO / 需产品 / 台账·文档 | Platform / Reliability / Product / Community |
| D label | `enhancement` / `documentation` | Product / Community |
| — | 其余 | **UNMAPPED**（dry-run 判红，须补规则） |

前缀优先于词面：前缀是维护者显式声明，词面只是猜（实测 #382「【发布·高】…NAS」
曾被词面 NAS 抢成 Platform）。

### Status 三状态（启发式，看板上可人工改）

| 判据 | 状态 |
|---|---|
| 带 `bug` / `security` label（本仓惯例：坐实才打） | 已验证缺陷 |
| `enhancement` label 或标题 `【展望…` | 功能提案 |
| 其余（只有前缀、尚无坐实/排定） | 待确认 |

「已验证/待确认」的人工复核**在看板字段上改**，不回写 issue 标题/label。

## 四项指标与可自动化程度

| 指标 | 来源 | 自动化 |
|---|---|---|
| ① 分类 × 仓 open 缺陷分布 | `gh issue list` + board-lib | ✅ `metrics.sh` 第 1 节 |
| ② 跨仓阻塞（open issue 正文的 `repo#num` 跨仓引用） | `gh issue list` 正文扫描 | ✅ `metrics.sh` 第 2 节（只认生态内仓，外站引用如 istore-repo 不算） |
| ③ 真机验证覆盖率 | hub#240 勾选框 + ✅/⏳ 计数 | ✅ `metrics.sh` 第 3 节（明细仍以 #240 表格为准，避免两处维护） |
| ④ 按列车号归档缺陷数 | — | ❌ **拉不到**：全生态 issue 无 milestone、无 train label，gh API 没有字段能把缺陷归到列车号；按关单时间倒推会把 hotfix/补车算错 |

④ 的口径（人工/待约定）：发车后在生成结果里贴当趟车的缺陷清账——来源是列车
bump PR 的 Fixes 列表与 `make train-verify` 输出。等生态开始给 issue 打
`train/<列车号>` label 或 milestone 后，`metrics.sh` 第 4 节可改为自动拉取。

## 看板维护约定

| 事项 | 约定 |
|---|---|
| 建板/补字段 | `bash scripts/board-setup.sh`（幂等；缺 project scope 时打印手动步骤并退出 3） |
| 归档/增量同步 | `bash scripts/board-sync.sh`（幂等：已在板的跳过 add、只回填字段） |
| CI 对账 | `board-sync.sh --dry-run`（只读，UNMAPPED 判红） |
| 谁归档 | 发车后由当趟车负责人跑一次 sync；新 issue 随下次 sync 进板 |
| 分类改判 | 改 `scripts/board-lib.sh` 规则或 issue 标题前缀，重跑 sync 即覆盖（字段回填是幂等覆盖语义） |

## 生成结果（快照，随生成刷新）

以下由 `bash scripts/metrics.sh` 产出；**数字是快照，口径以上文为准**。

```markdown
# 跨仓质量指标（自动生成）

> 生成：bash scripts/metrics.sh @ 2026-11-15 18:48 UTC；判定口径见 scripts/board-lib.sh，
> 指标定义与维护约定见 [docs/METRICS.md](METRICS.md)。数字随生成刷新，
> 口径正文不随生成变。

## ① open issue 分布（分类 × 仓）

| 仓 | Security | Correctness | Reliability | Platform | Product | Community | UNMAPPED | 合计 |
|---|---|---|---|---|---|---|---|---|
| pigeonbox | 1 | 0 | 5 | 3 | 4 | 2 | 0 | 15 |
| core | 2 | 3 | 1 | 0 | 4 | 0 | 0 | 10 |
| frontend-core | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 2 |
| openwrt | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| p2p | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 1 |
| ugreen | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| terramaster | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| charts | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 2 |

合计 **33** 条 open issue。

## ② 跨仓阻塞关系（open issue 正文里的跨仓引用）

引用形如 repo#num 指向**另一仓**的 issue/PR。

| 引用方 | 被引方 | 引用方标题 |
|---|---|---|
| pigeonbox#388 | charts#23 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | charts#31 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#159 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#160 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#161 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#169 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#170 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#172 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#173 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#182 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#183 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#184 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#186 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#191 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#192 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | core#193 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | fnos#212 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend#169 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#103 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#106 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#108 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#90 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#91 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#92 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#93 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#94 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | frontend-core#96 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | openwrt#110 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | p2p#50 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | p2p#51 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | terramaster#99 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#388 | ugreen#132 | 📋 Open Issue 全量台账（2026-11-16 · 47 单）——按优先级/类型/阻塞面分组的勾选清单 |
| pigeonbox#365 | core#12 | 【平台·中】跨平台 Capability Contract 与兼容矩阵：六适配仓统一声明能力并以可执行验收背书 |
| pigeonbox#365 | frontend-core#21 | 【平台·中】跨平台 Capability Contract 与兼容矩阵：六适配仓统一声明能力并以可执行验收背书 |
| pigeonbox#364 | core#151 | 【测试·高】分层质量矩阵 L1-L8：补并发/故障注入/升级/安全四层，强制三项高价值测试 |
| pigeonbox#240 | core#29 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | core#30 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | core#31 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | core#32 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | core#36 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | core#38 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | desktop#119 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | fnos#115 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | fnos#57 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | frontend#39 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | frontend-core#14 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | frontend-core#37 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | frontend-core#38 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | frontend-core#45 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | openwrt#110 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | openwrt#55 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | qnap#55 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | terramaster#99 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| pigeonbox#240 | ugreen#100 | [生态债] 剩余的真机验收与分发清单（2026-11-06 更新 · 5.0.0 已发货） |
| frontend-core#93 | core#102 | 【展望·需拍板】取件失败面透明化：寄件者可见「谁在何时因何失败」（与 #91 运营视图互补） |

## ③ 真机验证覆盖率（真相源 [hub#240](https://github.com/pigeonbox/pigeonbox/issues/240)）

- 销账条件勾选：**2/4**（50%）已完成
- 正文 ✅ 标记 9 处 / ⏳ 待办 2 处
- 平台真机明细逐条以 #240 表格为准（本表只给汇总，避免两处维护）

## ④ 按列车号归档缺陷数（暂不可自动）

**拉不到的原因**：全生态 issue 无 milestone、无列车 label，gh API 没有任何
字段能把缺陷归到列车号；按关单时间倒推列车窗口会把 hotfix/补车算错。

**口径（人工/待约定）**：发车后在本节贴当趟车的缺陷清账——来源是列车 bump
PR 的 Fixes 列表与 make train-verify 输出；等生态开始给 issue 打
train/<列车号> label 或 milestone 后，本节可改为自动拉取。

```
