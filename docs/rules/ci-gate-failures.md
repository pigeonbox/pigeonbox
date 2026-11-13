# 门禁与发布流水线的失效形态（ci-gate-failures）

> 单源：AGENTS.md 重构（2026-11-13，spec 附录 A#17 / 附录 B L875·L877·L854）。
> **改 CI/门禁前先读**；行号级真相在代码注释（如 `trainctl/advance.go` 的
> `checksAllGreenLatest`）。

## 一、门禁存在 ≠ 门禁在跑（四种形态）

| # | 形态 | 实例 | 修法 |
|---|---|---|---|
| ① | **门禁没挂在合并路径上** | hub 曾是唯一把 CI 漏在 required checks 之外的仓（main 的 required 只有 Secret Scan）⇒ 直推 main 不受任何门禁约束 | ruleset `ci-required` + `scripts/check-required-checks.sh` 持续断言 |
| ② | **前一步失败 ⇒ 后面全 skip** | core 的 CI 是单 job 串行步骤链 ⇒ gofmt 步先红 ⇒ Vet/Test(race)/Lint/**架构棘轮**全 skipped ⇒ 真正的门禁两列车没跑过 | 各门禁步加 `if: always()` |
| ③ | **需要网络的步骤吃掉别的门禁** | openwrt 的 `npm ci` 偶发失败 ⇒ build 红 ⇒ 两个真机冒烟门禁（`needs: build`）全 skip | 类型检查拆独立 job + `--fetch-retries` |
| ④ | **判定逻辑依赖检出形态** | push 事件检出**分支**、pull_request 检出**游离 HEAD** ⇒ 同一 commit 两个结论 | 两侧取同一坐标系；形态判别测试 |

⇒ **加每道门禁前必问四句**：① 挂在合并路径上吗？② 它前面失败时还跑吗？
③ 它依赖网络吗？④ 它的判定依赖检出形态吗？

**门禁红了要立刻追问「红在哪一步」**（2026-10-23 两次同型实录）：解析阶段失败 ≠ 断言失败；
job 级 `skipped` 说明那道门禁**没跑**；「为什么没拦住」比「把红修绿」更要紧
（core gofmt 连红、contracts 生成链红都曾带着红 CI 发出版——**发版前必须自己看一次
目标仓的 CI 结论**，且 v4 起 trainctl 已有打 tag 前 CI 门禁机械化它）。

## 二、具体形态的实录与机械拦法

- **action pin 打错一位 ⇒ 门禁从未启动**：checkout SHA 打错一位 ⇒ GitHub 在解析
  action 阶段就失败 ⇒ job 一行断言没跑过 ⇒ 空转两个发版列车。
  ⇒ `hub/scripts/check-action-pins.sh`（格式 + 同 action 不得钉矛盾 SHA + `--remote`
  验 commit 存在），接进 CI 与 `make pins`/`make lint`。
- **NAS 漂移门禁「必假漂移」**：期望侧取同列车分支模板、实际侧写死 `origin/main`
  ⇒ 天生差一版 ⇒ 三个 NAS 物化 PR 全红 ⇒ 整条列车卡 draft。
  ⇒ 实际侧改取 `origin/<当前检出分支>`；`check-nas-sync-gate.sh` 做三形态判别。
- **gofmt 漂移能挡住架构门禁**：gofmt 步先红 ⇒ 后面架构棘轮/race/lint 全 skip
  ⇒ 一个真实 DATA RACE 在 main 上活了两列车。⇒ 七仓全有 Gofmt 步；
  hub `check-gofmt-all.sh` 本地提交前拦。**本地复刻 CI 门禁要逐字同款，别私自裁剪
  检查面**（2026-11-13 实录：`gofmt -l | grep -v _test` 漏检 ⇒ CI 红）。
- **生成链脱节 ⇒ 红着发版**（2026-10-23）：改 IDL 没跑生成链 ⇒ `CHECK=1` 双红且
  已发布态即红。⇒ 改 IDL 必须跑全三条生成链并把产物一起提交；门禁红了先查为何没拦。

## 三、等 CI 的三种假信号

- **「还在跑」被报成「失败」**：`gh pr checks` 退出码 **8 = Checks pending**（不是失败）
  ⇒ `sleep 240; gh pr checks <pr> 2>&1` 只并流不并码 ⇒ CI 其实绿着却被报失败。
  ⇒ 等 CI 一律走 `hub/scripts/wait-pr-checks.sh`（0=全绿 / 1=有失败 / 2=超时 / 3=用法错）。
- **「重跑前的失败 attempt 污染判绿」**：`gh pr checks` 按所有 check run 判定
  ⇒ 最新一次已绿仍整体报失败。⇒ 判绿必须**按检查名(+工作流名)取最新一次 attempt**
  （真相源 `trainctl/advance.go` 的 `checksAllGreenLatest`，2026-10-23 实弹定型）。
  ⚠️ `gh --json statusCheckRollup` 走 GraphQL ⇒ conclusion 是**大写枚举**（SUCCESS）。
- **`sleep N` 是猜时长、不是等条件**：⇒ 改按条件轮询（有 pending 就继续，直到终态或超时）。

## 四、git 的网络操作会挂住 ⇒ 取数必须有界（2026-11-02 实录）

- git 在链路瞬断时**不自行放弃** ⇒ 任何无超时的 git 调用方被拖死（agent 后台任务被杀
  只剩半截输出、`make setup` 无限等、trainctl CI job 拖满 6 小时上限三处同款）。
- **「取数失败」与「没有差异」必须可区分** ⇒ 退出码三态：**0=成功 / 1=失败 / 2=超时**。
- **比对拿同一个 ref 的两端**：`git rev-list --left-right --count <ref>...origin/<ref>`；
  拿 HEAD 比 origin/main 是比错了对象（feature 分支上会报假分叉）。
- ⇒ 本地取远端一律走 `hub/scripts/git-fetch-safe.sh`（超时+重试+三态+`compare`）；
  trainctl 的 `Git()` 有 `GitTimeout` 且**必须同时设 `cmd.WaitDelay`**
  （`CommandContext` 杀 git 本身，孙进程仍持有 stdout 管道 ⇒ 超时形同虚设）。
- **默认分支别硬编码 `main`**：fnos 是 `master` ⇒ `git fetch origin main` 报
  `couldn't find remote ref` ⇒ 取数失败却看着像网络问题。⇒ 一律解析 `origin/HEAD`。
