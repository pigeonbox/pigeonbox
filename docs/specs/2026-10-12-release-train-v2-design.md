# 发布列车 v2:状态机编排器设计

- 日期: 2026-10-12
- 状态: **已实施并首航**(1.20.0 于同日全程无人值守 shipped:bump→合并→tag→Release→回挂→finalize);
  首航复盘加固与清理波同日落毕(见 §12)
- 取代: `2026-10-08-release-train-design.md`(该稿被 train.yaml 与 release-train.sh 引用但**从未入库**,本稿为发布列车首份存档设计;v1 语义中仍有效的约定在本文重新声明)

## 1. 背景与问题

v1 列车(2026-10-08 起)的骨架是对的:`release/train.yaml` 唯一真相源 + `verify` 全生态对账 + 棘轮守卫。但骨架之上的编排实现存在结构性缺陷,1.14.x~1.19.0 五六趟列车累计三十余起事故为其背书:

| # | 缺陷 | 实证 |
|---|---|---|
| 1 | 编排靠隐式契约的事件链:merge 必须 squash 且标题 `train:` 前缀;tagger 靠 VERSION 路径触发;GITHUB_TOKEN 推 tag 不产生 push 事件需 PAT+dispatch 兜底 | 1.15.0 静默断链→9 仓 tagger 加 dispatch 兜底 |
| 2 | server 无 tagger,人工在 frontend tag 就绪后手打;server release 内轮询等 frontend tag 至多 20 分钟,超时回退 main | 0.15.12/0.15.13 回退 main 发出上一版幽灵产物 |
| 3 | bump 是 788 行 bash 巨石,用 sed/perl/awk 跨 10 仓写 15+ 版本点,半数注释是事故疤痕;BSD awk/GNU 差异、自拷贝 /tmp、tget_head 等补丁层叠 | 1.14.2/1.14.3 bump 矩阵静默失败;1.15.2 phantom 提交 |
| 4 | 只能在工作站跑:依赖本地全套检出+npm/go/gh 登录+SSH 路由,发布不可交接、不可复现 | dry-run 污染工作树致 1.14.6 PR 漏建 |
| 5 | CI 忙等:wait-images 45 分钟 docker pull 轮询 + wait-artifacts 90 分钟轮询占 runner | train-release.yml 现状 |
| 6 | 7 个仓级 classic PAT,改 GitHub 密码集体吊销 | 回挂 401 事故,PAT 应急批量刷新在案 |
| 7 | charts 不在列车内,靠 server→dispatch→sync-appversion 后到;draft 期 verify 容忍窗口 | chart 1.3.12~14 发版缺失曾静默 |
| 8 | 文档版本矩阵(architecture.md/AGENTS.md)由 awk 数管道符维护,格式一变即静默失败 | verify 第 9 节常态 soft_fail |

## 2. 目标与验收标准(五条硬标准)

1. **零隐式契约**:跨仓协作只有显式 API 调用与可断言状态;`train:` 前缀门禁、VERSION 路径触发、dispatch 兜底全部由编排器代码取代。
2. **零忙等**:无 docker pull 轮询、无产物轮询、无 server 等 tag 轮询;等待=事件回调+轻量 API 校验+定时 sweep 兜底。
3. **可交接**:开列车=hub 一次 workflow_dispatch,不依赖任何个人工作站环境;本地直跑 trainctl 仅作应急逃生门。
4. **断链不吞错、幂等可重入**:任何一步失败响亮退出;重跑自动跳过已完成项(继承 v1 文化)。
5. **train.yaml 仍是唯一真相源**:状态机扩展其 `state` 字段,不另建记录。

## 3. 总体架构

```
                     ┌────────────────────────── hub ──────────────────────────┐
 人工/make ──dispatch──► train-orchestrator.yml                                │
 组件仓回调 ─dispatch──►   ├─ phase=bump:   trainctl bump(检出10仓→结构化写版本  │
 定时 sweep ──cron────►   │                →建PR→自动squash合并)               │
                     │   ├─ phase=tag:    trainctl tag(frontend→server→七终端   │
                     │   │                →desktop→charts 提交;机器人真账号推   │
                     │   │                tag 天然触发各仓 Release)             │
                     │   └─ phase=advance: trainctl advance(按 GitHub API 实况  │
                     │                    推进状态;全齐→verify→shipped→hub tag) │
                     └──────────────────────────────────────────────────────────┘
                          ▲ repository_dispatch(train-advance)回调=唤醒信号
        ┌─────────────────┴───────────────────┐
   frontend/server/fnos/openwrt/qnap/…  release.yml(既有构建打包不变;
   末尾 +5 行回调;上传 token 切 PB_BOT_TOKEN)
```

要点:

- **机器人是真账号**:推 tag 产生正常 push 事件,各仓既有 Release 流水线自然触发——v1 的 dispatch 兜底、`train:` 前缀门禁、tagger 双写断言的存在理由全部消失(断言前移为编排器 tag 前置校验)。
- **回调只是唤醒,不是真相源**:advance 每次以 GitHub API 实况(hub Release 资产、ghcr 包版本、Chart.yaml)核对完成度;丢回调只延迟不错判,sweep(15 分钟,state=shipped 秒退)兜底。
- **charts 进列车**:编排器直接提交 Chart.yaml(patch+1、appVersion=镜像号)到 charts main,既有 chart-releaser 发布;server→charts dispatch 链与 sync-appversion.yml 废除。

## 4. trainctl(hub 新增 Go 工具)

- 位置 `release/trainctl/`,独立 go module(`github.com/pigeonbox/pigeonbox/release/trainctl`),**仅 stdlib**,不进 go.work(`GOWORK=off` 构建)。git/gh/npm/go 经 os/exec 调用(gh 承担 API 与鉴权,不引 SDK)。
- 仓库定位约定:依次探测 `<name>/`、`../<name>/`、`modules/<name>/`——同一二进制兼容本地工作区布局与 CI checkout 布局。
- 子命令:

| 子命令 | 职责 |
|---|---|
| `get <key>` | 读 train.yaml 单键(工作流取值) |
| `notes [tag]` | 渲染 hub Release 说明(组件矩阵) |
| `verify [--ci]` | v1 十一节对账全量移植(含检出新鲜度守卫、in-flight 降级、tag 锚定主线) |
| `bump TRAIN=x.y.z [--set k=v…] [--hotfix] [--dry-run]` | 结构化写 15+ 版本点→各仓 train/<v> 分支+PR→自动合并。**dry-run 纯内存输出计划,不落盘**(根治 v1 工作树污染) |
| `tag` | bump PR 全合并后按依赖序推 tag + charts 提交 + state=tagged |
| `advance` | 状态机推进:draft→(PR 齐合并)→tag→tagged→(产物+镜像齐)→verify→shipped+hub tag |

- 版本点写入全部结构化:`package.json`/`tauri.conf.json` 首个 `"version"` 键、tgz URL、fnos manifest kv、`Cargo.toml` version、compose `PB_IMAGE_TAG`、kustomization `newTag`、DEPS.env 生成、表格单元格(按列语义解析,非 awk 数管道符);`go mod edit -require` + `go mod tidy`、`npm install --package-lock-only` 经 exec。
- 自动合并:`gh pr merge --auto --squash`;仓未开 auto-merge 时由 advance/sweep 在 checks 绿后直接 `gh pr merge --squash`;branch protection 阻挡时 `--admin` 兜底并响亮记录。标题由程序生成(保持 `train:` 前缀以兼容过渡期未删的 tagger)。

## 5. 状态机与 train.yaml

```
draft ──(全部 bump PR 已合并)──► tagged ──(8 组件回挂资产齐 + server/frontend/p2p 镜像在位 + chart 对齐)──► shipped
```

- `state` 取值 `draft/tagged/shipped`(`released` 为瞬态,并入 advance 判据,不落盘);schema 不变,仅状态语义扩展。
- 每次唤醒(回调/sweep/手动)推进到能推进的最远处后退出;所有转移前置 verify-lite,shipped 前置全量 verify。
- 终态动作:state=shipped 提交 → hub 打 `v<train>` tag(机器人推送触发 hub release.yml)→ Latest 快照 notes=`trainctl notes`。

## 6. 机器人账号与 secret 收敛

- org 机器人账号 `pigeonbox-ci`(用户在 GitHub 侧创建):org member,15 仓 contents:write+workflows:write。
- **classic PAT**(必须 classic:ghcr 包查询需 `read:packages`,fine-grained 不支持 packages),scope:`repo` + `workflow` + `read:packages`。
- 存 org 级 Actions secret **`PB_BOT_TOKEN`**,一次替换 7 个 `*_PAT` + `CHARTS_PAT` + `TRAIN_PAT` + `RELEASE_PAT`;轮换只动一处;机器人账号不改密码,「改密码吊销全部 PAT」事故类别消灭。
- 过渡期工作流写法:`${{ secrets.PB_BOT_TOKEN || secrets.<旧PAT> }}`,旧 secret 在清理波删除。
- 取舍:org secret 全 org 可见=各仓共享一个写 token;现状 7 个 PAT 本就互有 hub contents:write,信任面无实质扩大,接受。

## 7. 组件仓改造

| 仓 | 改动 |
|---|---|
| frontend/fnos/openwrt/qnap/synology/ugreen/terramaster/desktop | release.yml:上传 token 切 `PB_BOT_TOKEN‖旧PAT`;attach-to-hub 末尾 +5 行 `repository_dispatch`(event `train-advance`,payload {component, tag});version-tagger.yml 过渡期保留(编排器先打则 tagger 见 tag 已存在自跳,无双打),**1.20.0 shipped 后删除** |
| server | release.yml:**charts dispatch 已随重构立即拔除**(编排器直提 Chart.yaml,并存会双跳 chart 版本)+回调;删「等 frontend tag 20 分钟+回退 main」留清理波(过渡期编排器保证 frontend tag 先行,轮询秒过);包体版本≠tag 硬断言**永久保留** |
| charts | sync-appversion.yml 过渡期保留、清理波删除;release.yml 末尾 +回调(可选,sweep 已覆盖) |
| frontend-core | tagger 服务其库线自发布,不属列车,不动 |
| contracts/core/kit/p2p | 库线自持 semver、人工 tag,列车只记录消费,不动 |

## 8. hub 工作流与工具面改造

- **train-orchestrator.yml**(新增):三入口 `workflow_dispatch`(inputs: train/phase/set/hotfix)+ `repository_dispatch`(train-advance)+ `schedule`(*/15);jobs 检出 hub+15 仓(**hub 根子目录布局,与本地 make setup 一致——finalize 全量 verify 的 sync.sh 按该布局解析 NAS 仓**),setup-go(<v7)+setup-node,`GH_TOKEN=PB_BOT_TOKEN‖TRAIN_PAT‖github.token`(只读 phase 可降级),按 phase 调 trainctl;concurrency 组串行防双跑。
- **train-release.yml**:废弃(编排器取代;文件保留至清理波)。
- **train-verify.yml**:`bash scripts/release-train.sh verify --ci` → `trainctl verify --ci`(对拍一致后切);drift issue 机制不变。
- **release.yml**(hub 快照):notes 改调 `trainctl notes`。
- **Makefile**:`train-verify`→`go run ./release/trainctl verify`(GOWORK=off);`train-bump`→`gh workflow run` 开列车+跟日志,另留 `train-bump-local` 直跑 trainctl 应急;`train-finalize`→`trainctl advance --finalize`(本地应急)。
- **文档矩阵**:trainctl 以结构化表格解析更新 architecture.md/AGENTS.md(可单测),verify 继续对账。
- **scripts/release-train.sh**:冻结不删(回退路径),1.20.0 shipped 后删除。

## 9. 迁移计划(不做大爆炸)

| 步骤 | 内容 | 回退 |
|---|---|---|
| 1 | 机器人账号+org secret(用户侧操作,出清单);既有链路 token 表达式切换,立即生效 | 删 org secret 即回旧 PAT |
| 2 | trainctl verify 移植,与 bash verify 并跑对拍(1.19.0 shipped 树双绿),切 train-verify.yml | yml 改回 bash 一行 |
| 3 | trainctl bump/merge;`--dry-run` 对 1.19.0 树零 diff 对拍 | 旧 bump 仍可用 |
| 4 | trainctl tag/advance + orchestrator 工作流 + 组件仓回调合入 | 编排器停用=回到 v1 事件链(tagger 未删) |
| 5 | **1.20.0 = 新链路首航**(旧链路全程可回退);shipped 后清理波:删 9 处 tagger、server 轮询与 charts dispatch、sync-appversion.yml、train-release.yml、release-train.sh、旧 PAT secrets | — |

## 10. 测试策略

- **单测**(trainctl 内,fixture 驱动):各结构化编辑器(JSON 首 version、tgz URL、manifest kv、Cargo/compose/kustomization/表格)、train.yaml 读写、状态机转移判定(假 gh/git 输出注入)。
- **对拍**:`trainctl verify` vs `release-train.sh verify` 在当前 shipped 树结果一致;`trainctl bump TRAIN=1.19.0 --dry-run` 计划=空(已 shipped 零变更)。
- **实航**:1.20.0 全程走新链路,旧链路热备。

## 11. 风险与开放项

- org secret 建立前,编排器写操作依赖旧 TRAIN_PAT(仅 hub 权限),跨仓 tag/合并能力受限——步骤 1 是硬前置。
- `gh pr merge --admin` 需机器人对受保护分支有 admin 权;org owner 授权即可。
- sweep 每 15 分钟一次空跑成本(秒退),接受。
- 库线(contracts/core/kit/p2p/frontend-core)发版仍人工 tag + `--set` 记录,不在本次自动化范围(有意为之:库线讲兼容语义,节奏独立)。

## 12. 首航复盘(1.20.0,2026-10-12 当日)

**结果**:bump(9 仓 PR)→ 合并(checks 绿后自动 squash;3 仓 branch protection 经 --admin 响亮兜底)
→ 9 仓 tag(编排器推 3 仓;另 6 仓被过渡期未删的 tagger 抢先,编排器幂等跳过——无双发)
→ 组件 Release + 回挂 → 回调唤醒 advance → 全量 verify 绿 → shipped + hub v1.20.0 Latest。
全程无人值守;从 bump 到 shipped 约 40 分钟(长尾=desktop 三平台 Tauri 构建)。

**首航捕获并已修的问题**:

| # | 问题 | 修法 |
|---|---|---|
| 1 | verify 第 4 节(NAS 钉版)CI 路径读 main,缺 in-flight 降级——bump PR 的 train-verify 恒红(v1 就存在,人工合并不敏感;v2 自动合并会卡死) | 读 main 的检查统一 softFail 语义(第 8 节 tgz 一并补) |
| 2 | NAS lint 门禁抓 raw CDN 模板,撞 hub PR 合并时序+~5min CDN 缓存=幽灵模板误红 | sync.sh 支持 `PB_NAS_TEMPLATE_REF` + gh api 优先;NAS ci.yml 对 train PR 读同列车分支 |
| 3 | 9 仓均未开 auto-merge,bump 的 `gh pr merge --auto` 全部落空 | `gh api -F allow_auto_merge=true` 九仓已开 |
| 4 | charts 在 tag 阶段提交,chart 先于镜像发版=「钉空气」窗口 | charts 提交移入 advance 并加镜像时序门;checkReleased 读前 fetch(防读本 run 起点克隆) |
| 5 | verify 检出新鲜度守卫漏 charts(Raw 直读 origin 引用,未 fetch 即旧版) | 补入守卫清单 |
| 6 | PR 分支的 CI 用 PR 树内工作流/代码——main 上的修复不回溯在途 PR(本次 verify 修复即此形态) | 记录为已知 CI 语义;合并判定靠 required checks(gitleaks),verify 非 required |

**清理波(同日完成)**:删 8 仓 version-tagger(frontend-core 保留,属库线自发版)、server 等 tag
轮询(改硬门:frontend 同号 tag 不在即失败,回退 main 永久封死)、charts sync-appversion.yml、
hub train-release.yml + scripts/release-train.sh;删 10 个旧 PAT secrets(7 仓 *_PAT + TRAIN_PAT +
CHARTS_PAT + RELEASE_PAT);全部凭据表达式收敛为 `PB_BOT_TOKEN`(org secret)。

## 13. 二次加固(首航后审计,同日)

- **并行列车门禁**:bump --push 仅允许从 `shipped` 态开车(同列车号续跑豁免)——v1「并行列车吞提交」事故类的结构性封死。
- **sweep 快速通道**:orchestrator 加快速预判步,非人工 dispatch 且 `state=shipped` 且无在途 train PR 时跳过克隆/装链/构建(96 次/天空跑从 ~3 分钟压到 ~10 秒;人工 dispatch 永远执行)。
- **停滞哨兵**:bump PR checks 有红 → advance 开/更新常驻 issue「🚂 train-stalled」(列车卡住从静默等死变可见;与 train-drift 同模式)。

审计同时实证无碍项:chart 2.0.17 正常发布、train-verify 清理波后持续绿、分支保护未引用已删工作流、镜像双架构在位、无文档死链。
