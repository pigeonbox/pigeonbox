# 发布列车 v4：preflight 门禁 + 打 tag 前 CI 闸 + BEHIND 自愈 + 进度可见

- 日期：2026-11-13
- 状态：**已实施（W1~W4 落地，2026-11-13）；真车验收（§10 清单）待下一趟列车**
- 继承：v2/v3 全部状态机语义（`train.yaml` 真相源、draft→tagged→shipped、同一次 CI
  运行内自轮询、库线收进列车、verify 对账）——**本设计不改状态机语义，只在它前面加一道门、
  在合并步里加一个自愈分支**
- 并行前置：同日 09:43 合并的 #347/#348「发布流程硬化五项」已落地
  （`run --dry-run` 真只读、Makefile 假文案改真、marker-ahead 库线漂移检测、
  hub 分歧自动 ff 恢复、notes 外部缺口提示）——**本设计不重复其中任何一项**，
  G4（dry-run 可信）直接视为已达成
- 设计稿沿革：`2026-10-12-release-train-v2-design.md`（状态机与操作面）、
  `2026-10-27-release-train-v3-one-command-design.md`（一条命令 + 库线收进列车）

## 1. 背景：#347 之后仍存在的结构性缺口（2026-11-13 源码取证）

| # | 缺口 | 证据 | 后果 |
|---|---|---|---|
| 1 | **红 CI 也能发车** | `advance.go` `advanceDraft`（L106-129）只等 bump PR 合并就 `runTag`；`ensureLibTag` 打库线 tag 前也不查 CI；grep 全仓无 `head_sha`/CI 结论检查 | AGENTS.md L875 自己写着「发版前必须人工 `gh run list` 看一次目标仓 CI」= **靠人记**；实录：core gofmt 连续红、contracts 生成链门禁红，均**带着红 CI 发出版** |
| 2 | **BEHIND 无自愈** | `tryMergeReady`（advance.go L227-257）只判 `checksAllGreenLatest` → merge → `--admin` 兜底；全仓 grep `update-branch`/`mergeStateStatus` **0 命中** | ruleset `required_status_checks.strict=true` ⇒ bump 分支落后 main 一个提交即 `BEHIND` ⇒ auto-merge **永不触发**（4.8.3/4.8.4 实录：需人工 `gh pr merge --admin` 或人工把 main 合进分支） |
| 3 | **进度不可见** | 无 `status` 子命令；orchestrator 无 `$GITHUB_STEP_SUMMARY`；卡住只能翻长日志或开 issue | 发车者/盯车者无法一屏回答「现在卡在哪、等什么」 |

**#347 已解决、本设计只引用的**：G4 dry-run（`run --dry-run` 只读预览，缺省真执行语义
保持不变）、Makefile `train-run-local` 假文案（改为不带 ARGS 拒绝执行）、
库线 marker-ahead 漂移（verify section1b 判红 + run [0] 警告）、本地逃生门 ff 自动恢复。

## 2. 目标与验收

| # | 目标 | 验收判据 |
|---|---|---|
| G1 | **下一趟真车零人工干预** | `make train TRAIN=x.y.z` 发车到 shipped 无人工点击；中途卡住=未完成 |
| G2 | **红 CI 不可能被 tag** | 机械门禁取代「发版前人工 `gh run list`」；负对照见 §7 |
| G3 | **PR 卡死形态自愈** | `BEHIND` 由列车 `gh pr update-branch` 自愈；`DIRTY`（冲突）点名要人；负对照见 §7 |
| G4 | dry-run 可信 | ✅ **已由同日 #347 落地**，本设计不实现、只不回退 |
| G5 | **进度一眼可见** | `make train-status` 一屏看相位/卡点；CI run 页面 job summary 直接可读 |
| G6 | **不放大事故面**（继承 v3-G7） | §6 不变量全部成立；现有 43+ 测试文件全绿为底线 |

## 3. 架构：preflight 相位 + 单一 CI 判据

```
make train TRAIN=x.y.z → train-orchestrator(phase=run) → trainctl run
   │
   [-1] preflight（新增，**全程只读**，全过才进入任何写操作）
        P1 凭据    PB_BOT_TOKEN 有效 + 对全部目标仓有写权限（轻量 API 探测）
        P2 状态    无其他列车卡非终态（沿用现有「旧列车守门」，不重写）
        P3 CI 基线 4 库线仓 + 各组件仓 @ main HEAD：assertRepoCIGreen
                   （红 ⇒ 立即失败 + 哨兵；在跑 ⇒ 有界等待）
        P4 钉版    复用 #347 marker-ahead（声明>tag 判红）+ ensureLibLinePublished
                   只读段（已存在钉版可消费、目标版本号单调）
        P5 检出    各仓 fetch 齐 + hub 工作树干净（把「跑到一半才报分歧」提前到发车时）
   │ 任何一道红 ⇒ die + reportStalledIssue（点名闸门与对象），**零写操作**
   ▼
   [0] 库线 → [1] bump → [2] 等合并 → [3] 等产物/终验/快照   ← 语义全部不变
        │            │
        │            └─ runTag：推 tag 前，对本趟**全部待 tag 仓**并行等 CI 绿
        │               （P3 落点版：防「preflight 后才转红」与「squash 合并的
        │                新 commit 尚未跑完 CI」两个窗口）
        └─ ensureLibTag：打库线 tag 前，对目标仓 main HEAD 调同一判据
```

**关键设计决策**：

1. **CI 判据只写一处** `assertRepoCIGreen(repo, sha)`（新文件 `cigate.go`）——
   preflight、`ensureLibTag`、`runTag` 三处调用同一函数，不搞两套口径。
2. **按 commit 查，不按「最新一次 run」**：bump PR 绿的是 PR head；squash 合并到 main
   是**新 commit**，门禁查的是「被 tag 的那个 sha」的 run。
3. **runTag 并行等待**：先算出本趟全部「仓→待 tag sha」，单个轮询循环（20s 间隔）
   等**全部**绿再按依赖序推 tag ⇒ 门禁净增时延 ≤ 一轮 CI（约 3~8 分钟），
   不是 N 轮串联。
4. **失败姿态复用哨兵模式**：门禁红 ⇒ `stepFailed` + `reportStalledIssue`
   （issue 正文点名仓 + sha + run URL）；人修完，cron/回调 sweep 接力——**不新增唤醒机制**。
5. **preflight 不写 train.yaml**：state 流转照旧 draft→tagged→shipped，schema 不动。

## 4. 闸门与自愈细节

### 4.1 `assertRepoCIGreen(repo, sha)`（G2 核心）

```
输入: repo（owner/name）+ 待打 tag 的 commit sha
1. 该仓 actions/workflows 总数 == 0            ⇒ pass（纯脚本仓，无 CI 可查）
2. 该仓默认分支**有没有** push 触发的 run 先例？
   （actions/runs?branch=<default>&per_page=5 为空 ⇒ 判「main 从不跑 CI」）
   ⇒ pass + 注记（PR-only CI 仓：内容已被 bump PR checks 绿把过，不误拦）
3. runs?head_sha=<sha>：
   - 任一 run conclusion ∈ {failure, cancelled, timed_out} ⇒ **立即 red**（失败不自愈）
   - 全部 success/skipped/neutral                ⇒ pass
   - 有 queued/in_progress，或 0 个 run          ⇒ 20s 轮询有界等待
     （上限 10 分钟；超时 ⇒ red——「跑不出来」按「没把住」处理）
```

- **落点三处**：preflight P3（基线，4 库线 + 组件仓 @ 当前 main HEAD）、
  `ensureLibTag`（打库线 tag 前 @ 目标 sha）、`runTag`（推组件 tag 前，§3 决策 3 的并行等待）。
- `advance`（cron/回调/手动的崩溃接力路径）经 `runTag` **自动获得同一门禁**。
- red ⇒ `stepFailed` + 哨兵，报文含「仓@sha + 失败 run URL + 修复后重跑 `make train-advance`」。

### 4.2 BEHIND 自愈（G3）——只改 `tryMergeReady` 一个函数

```
对每个 open bump PR：
  st := gh pr view --json mergeStateStatus        （新增一次读，不改 checks 判定）
  st == BEHIND ⇒
      本进程该 PR 自愈计数 ≥ 3  ⇒ stepFailed 语义 + 哨兵（防 main 持续前进死循环）
      否则计数+1，gh pr update-branch（把 base 合进 PR 分支、重触发 checks）
      → warnf 点名「自愈第 N 次」→ continue（45s 后下轮复查）
  st == DIRTY ⇒ warnf 点名「冲突需人工解」→ 走原路径（原路径合并必失败并响亮记录）
  其余状态 ⇒ **现有 checks 判定 → merge → --admin 兜底，一行不改**
```

- **为什么这是常规路径而非边角**：一趟车里后合并的 bump PR 必然落后于先合并的
  （main 每合一个 bump PR 就前进一格）⇒ `strict=true` 下最后几个 PR **常态 BEHIND**
  ⇒ 自愈是每趟车都会走的主路径；真车本身即 G3 的天然负对照。
- `--admin` 兜底**保留**（NAS 三仓「无人产出的 required check」仍靠它）；
  自愈解决的是「BEHIND 让 checks/合并永远等不到」这一轴，两者正交。
- 自愈计数为**进程内** map（run 单进程自轮询 90min；standalone advance 每次进程重置，
  与「每次唤醒最多自愈一次」同语义）。

### 4.3 dry-run（G4）——已由 #347 落地，本设计明确不碰

`run` 缺省真执行、`--dry-run` 只读的语义**是 #347 刚拍板的契约**
（train-orchestrator.yml 依赖缺省真执行）——本设计 **不改 `run` 的执行模式分派**。

## 5. 操作面（G5）

1. **`trainctl status`**（新子命令，只读，无副作用）：
   - 一屏输出：当前车次/state（读远端 train.yaml）→ 各 bump PR 及其 checks 状态 →
     产物缺口（复用 `checkReleased`）→ 镜像在位与否 → 哨兵 issue 链接 →
     「当前最可能的卡点」一行结论；
   - `--markdown` 变体供 CI 写 job summary；数据全部走既有 `Gh`/`Git` 助手，零新依赖。
2. **orchestrator 加 `if: always()` 收尾步**：`trainctl status --markdown >> $GITHUB_STEP_SUMMARY`
   ——无论成败，gh run 页面直接看到终态摘要（不改 run 进程内部）。
3. **`make train-status`**：本地一键（依赖 `trainctl` 目标，保证重建，规避陈旧二进制）。
4. **帮助文本**：`train-bump`/`train-advance` 标注「兼容/崩溃接力用，日常走
   `make train`」；`run --dry-run` 与 `train-bump-local` 的分工说明与 #347 文案对齐。

## 6. 不变量（改这条链前先读；违反任一 = 设计作废）

1. **bump 的切分支/三方合并/暂存链路一行不改**（v3-G7）；BEHIND 自愈作用于
   **GitHub 侧 PR 分支**，不碰本地写回逻辑。
2. **状态机语义与 `train.yaml` schema 不变**；preflight **不写** train.yaml；
   train.yaml 行解析器（行内注释会吞值）维持现状。
3. **唤醒源不变**：run 自轮询为主，cron/回调仍是兜底；不新增唤醒机制。
4. **`checksAllGreenLatest` 判定口径不改**（按检查名取最新一次，2026-10-23 实弹结论）。
5. **`run` 缺省真执行语义不改**（#347 契约）；`verify` 判据与退出码语义不改。
6. **CI 门禁判据单一来源**：任何新落点只能调 `assertRepoCIGreen`，禁止内联第二套判定。
7. **门禁红必须响亮**：不允许「拿不到信息就放行」——查不到 CI 与「CI 绿」是两回事
   （与 verify 的 failUnavailable 同口径；§4.1 第 2 步的 pass 是**有证据的放行**
   ：该仓 main 从不跑 push CI，注记原因）。

## 7. 测试与负对照

| 项 | 正判据 | 负对照（实测转红后还原） |
|---|---|---|
| `assertRepoCIGreen` | 表驱动全组合：无 workflow / main 从不跑 / 绿 / 红 / 在跑→绿 / 在跑→超时 / 0 run→超时 | ①把「failure ⇒ 立即 red」改成「等待」⇒ 红用例转红；②第 2 步 pass 无注记 ⇒ 用例转红 |
| 落点接线 | preflight / ensureLibTag / runTag 三处均调用该函数（源码接线守卫，仿 #347 ff_recover 接线守卫） | 删掉任一落点 ⇒ 守卫红 |
| BEHIND 自愈 | 状态机用例：BEHIND→update-branch→计数；≥3 次→failed+哨兵；DIRTY→不自愈点名；CLEAN→原路径 | 把 `st==BEHIND` 分支删掉 ⇒ BEHAND 用例红 |
| preflight | 五道闸全绿放行；任一红 ⇒ 零写操作 + 哨兵（断言 git/gh 零副作用） | 把 P3 跳过 ⇒ 「红 CI 放行」用例红 |
| status | 只读断言（跑完远端 refs / train.yaml 无变化）+ 输出含相位/缺口 | — |
| **真机负对照 G2** | 用 `assertRepoCIGreen(repo, <历史红 run 的 sha>)` 实测（core gofmt 红期的既有 commit，**零破坏**）⇒ 必须立即 red | — |
| **真机负对照 G3** | 每趟真车最后合并的 bump PR 必然 BEHIND ⇒ 观察 update-branch 自愈生效（G1 验收顺带覆盖） | — |

门禁：`release/trainctl` `GOWORK=off go test ./...` 全绿 + `go vet` + 现有 33 个测试文件
不回退 + hub `make lint` 全套。

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| CI 门禁拉长车程 | 并行等待（§3 决策 3）+ 单窗 10min 上限 + PR-only 仓自动放行；净增 ≤ 一轮 CI |
| `update-branch` 权限不足 | preflight P1 提前验写权限；失败降级现有 `--admin` 路径并响亮 warn |
| main 持续前进导致自愈死循环 | 每 PR 每进程 3 次上限 ⇒ fail-fast + 哨兵（人来判断，不无限重试） |
| 与并行会话冲突 | 实施前 rebase #348 后的 main；改动集中在 `advance.go` / 新文件 `cigate.go`/`preflight.go`/`status.go` / orchestrator 收尾步 / Makefile |
| 真车首验翻车 | G1 即验收；卡住有哨兵 issue + `make train-advance` 崩溃接力 + `run --dry-run` 可先演练 |

## 9. 工作分解（每步独立可合、CI 绿为底线）

| 步 | 内容 | 依赖 |
|---|---|---|
| W1 | `cigate.go`：`assertRepoCIGreen` + 三落点接线 + runTag 并行等待 + 哨兵报文 | rebase #348 |
| W2 | `advance.go`：`tryMergeReady` 加 `mergeStateStatus` 分支（BEHIND 自愈 / DIRTY 点名 / 3 次上限） | 无（可与 W1 并行） |
| W3 | `preflight.go`：`run` 前置 `[-1]` 五道闸 + `trainctl preflight` 独立子命令 + `make train-preflight` 目标 | W1（复用 CI 判据） |
| W4 | `status.go`：`trainctl status [--markdown]` + orchestrator `if: always()` 收尾步 + `make train-status` + 帮助文本 | 无 |

- **G4/库线漂移/ff 恢复/notes 缺口**：已由 #347 完成（W0），本设计不列任务。
- 全部落地后按 §10 清单跑真车验收；**规则文档（AGENTS.md 瘦身）是已拍板的第二个子项目**，
  在本设计验收后另行开 spec，届时把 v4 的新纪律写进理清后的规则。

## 10. 真车验收清单（G1）

- [ ] `make train TRAIN=<下一版本>` 发车 → shipped **全程无人工干预**
- [ ] 负对照 G2：历史红 sha 实测 `assertRepoCIGreen` 立即 red（§7）
- [ ] 负对照 G3：最后合并的 bump PR 走 update-branch 自愈（日志见「自愈第 N 次」）
- [ ] preflight 任一闸红 ⇒ 零写操作 + 哨兵 issue 点名闸门
- [ ] `make train-status` 一屏可读；gh run 页面 job summary 可读
- [ ] `release/trainctl` 测试全绿、负对照全部实测转红后还原
