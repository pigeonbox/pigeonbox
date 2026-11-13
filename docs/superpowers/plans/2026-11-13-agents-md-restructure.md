# AGENTS.md 规则重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 spec `docs/specs/2026-11-13-agents-md-restructure-design.md` 把 207KB/895 行的 AGENTS.md 重构为三层结构（层1 ≤24KB 薄索引 / 层2 hub `docs/rules/` 版本化 / 层3 工作区 `docs/topics/`），逐条处置零漏项，锚点与引用不断，守卫上线，5 题场景抽查通过。

**Architecture:** 两步落地——Step1 先把公开安全规则搬进 hub 仓（PR 可 review，含脱敏门与守卫脚本）；Step0/Step2 再备份并重写工作区（AGENTS.md 薄索引 + topics 档案）。内容搬运的**唯一映射真相源 = spec 附录 A（逐节 23 条）与附录 B（规则墙 ~50 条）**，本计划不复制其内容，只给执行模式、文件骨架、判据与验证。

**Tech Stack:** Markdown、bash 守卫脚本、`trainctl bump --dry-run`（锚点验证）、`gh` CLI、explore 子代理（场景抽查）。

## Global Constraints

- **AGENTS.md ≤ 24KB**（G1，32KB 注入预算留 25% buffer）；重构后必须全量可读
- **锚点冻结（G4/spec §6）**：生态仓库表 **15 个行首格**（12 字面键 + platforms 循环 3）精确匹配含反引号；**版本值在行末格**；行须为单行 Markdown 表行；说明列可精简
- **脱敏门（Step1）**：层2 任何文件 grep 内网模式必须**零命中**——`10\.`、`192\.168`、`100\.64`、`172\.1[6789]\.`、`JumpServer|堡垒机`、`home\.enjoye`、`murphy|bridge-work|tnode`（词边界）
- **行号引用清零（G5）**：`grep -rn "AGENTS.md L[0-9]" PigeonBox/ docs/`（工作区）零命中；改「AGENTS.md·<节名>」式
- **备份先行（G7）**：动 AGENTS.md 之前必须完成 `docs/archive/AGENTS.pre-restructure-2026-11-13.md` + sha256
- **与在途 bump 互斥**：Step2 前确认 `release/train.yaml` 的 `state: shipped`（bump 写同一张表）
- **零漏项（G3）**：spec 附录 A 的 23 节与附录 B 的逐条，每条处置必须落地并在勾稽表勾掉
- **hub 改动走 PR + CI 全绿**；工作区改动（AGENTS.md/topics）无版本控制 ⇒ 备份即回退
- 治理注（防再膨胀）必须写进层1 尾注，措辞见 Task 6

---

### Task 0: Step1 工作区（hub 改动隔离）

**Files:** 无代码；创建 worktree。

- [ ] **Step 1: 从 main 切工作分支的 worktree**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/PigeonBox
git fetch origin main
git worktree add ../hub-agents-rules -b feat/agents-rules origin/main
```

Expected: worktree 就绪于 `/Users/zhangyi/my_project/filecodebox-project/hub-agents-rules`。**Step1 的所有 hub 改动都在此目录**（AGENTS.md L148 并行会话纪律：不碰主检出）。

- [ ] **Step 2: 基线门禁**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules && make -n lint >/dev/null && echo MAKE_OK
```

Expected: `MAKE_OK`。

---

### Task 1: 层2 `docs/rules/` 落位（内容搬运主战场）

**Files:**
- Create: `hub-agents-rules/docs/rules/{README.md,contributing-rules.md,ci-gate-failures.md,release-rules.md,frontend-rules.md,brand.md,generic-engineering.md}`
- 映射真相源: spec 附录 A「→2」行 + 附录 B「→2」条（不在本计划复制）

**Interfaces:**
- Produces: 层2 单源规则集；`docs/rules/README.md` 是层1 指针的目标（Task 6 依赖其路径存在）

- [ ] **Step 1: 建 README（层2 门面）**

写 `docs/rules/README.md`：

```markdown
# PigeonBox 规则（层2 · 版本化单源）

> 本目录是「公开安全的持久规则」唯一真相源（AGENTS.md 重构 2026-11-13，spec
> `docs/specs/2026-11-13-agents-md-restructure-design.md`）。
> 工作区 AGENTS.md 只留精编与指针；含内网/机器细节的材料在工作区 `docs/topics/`（不入库）。

| 文件 | 覆盖 | 谁改这里 |
|---|---|---|
| contributing-rules.md | 提交约定 / 依赖单向 / 生成物勿手改 / 破坏性升版 / 钉版 | 任何仓的工程规则变更；CONTRIBUTING.md 指向此处 |
| ci-gate-failures.md | 门禁失效四形态 / 等 CI 三假信号 / git 有界取数 / 加门禁四问 | 改 CI/门禁前 |
| release-rules.md | 发版纪律（库线钉版、发车顺序、守门、切镜像判据、notes 渲染） | 动发布链前 |
| frontend-rules.md | 折叠屏断点 / 列宽公式 / CSS 特异度 / 路由与表格形态 | 动前端 UI 前 |
| brand.md | 品牌真相源 / 换色生成器 / 色板公式 | 动图标/主题色前 |
| generic-engineering.md | 幂等键 / 拆判定重审 / 守卫自证 / 静默失效响亮失败 / 负对照底线 / 数据迁移纪律 | 通用工程判断 |

**治理**：新规则先进对应文件（PR review）；AGENTS.md 禁止直接堆实录段落。
```

- [ ] **Step 2: 按附录逐条搬运（六文件）**

对 spec **附录 B** 中每条标 `→2` 的条目、与 **附录 A** 中 `→2` 的节：
1. 打开源文件对应行（AGENTS.md 行号见附录）；
2. 按统一**条目格式**落进目标文件（模式见 Step 3 实例）；
3. 在 spec 附录对应行尾追加 `✓已落 <file>`（勾稽，Task 10 验收数它）。

目标文件与附录条目对应：`contributing-rules` ← L889-890/891-893/894/895、附录A#7 部分；
`ci-gate-failures` ← L447-521 全节、L875、L877、L854（**仅留一行「真相在 checksLatest 注释」**）；
`release-rules` ← L784-796、L810、L817+L856（合并一条）、L858、L859、L825、L861、L811、附录A#14、附录A#11①；
`frontend-rules` ← L820-824、L829-841、L842-849、L883、L884（与 L305 合并）、附录A#16、L869/873（API 行为放此处不合适 ⇒ 这两条归 `contributing-rules` 的「对外契约」小节，搬运时按此归位）；
`brand.md` ← L381-433 全节（附录A#15）；
`generic-engineering` ← L797-808、L813-814、L815、L816、L819、L826、L827（与 L818 合并）、L828、L866-867（链接形态契约归此）+ 收敛对 L868/871（取 871）、L870/872（取 872）、L878、L882、审计规则 L523-585 全节、取件上浮条（spec 附录A#12 列出的通用7 条）。

- [ ] **Step 3: 条目格式实例（照此模式，不许只搬原文）**

以附录 B「L819 负对照验收底线」为例，落进 `generic-engineering.md` 的成品形态：

```markdown
## 负对照是验收底线（2026-10-26 实录，5 处全绿）

每条新断言都要能把实现改回缺陷态并**实跑变红**——「测试绿」只证明
「当前实现如此」，不证明「断言钉住了行为」。修 bug 先写复现测试；
覆盖率按模块只升不降。
```

规则：**压缩不删判据**——教训的「为什么」与「判据」必须保留，过程叙事（当时第几趟车、
谁的会话）删；带日期证据保留在标题括号里；与代码注释重复的（L854/L818 类）改为
「一行 + 指向代码符号」。

- [ ] **Step 4: 脱敏门（零命中才算过）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
grep -rEn '10\.|192\.168|100\.64|172\.1[6789]\.|JumpServer|堡垒机|home\.enjoye|\b(murphy|bridge-work|tnode)\b' docs/rules/ && echo "脱敏门红" || echo 脱敏门绿
```

Expected: `脱敏门绿`。红了就逐条看：是机制描述里误带地址 ⇒ 改写成「内网 NAS」类泛称；
是纯操作必需的地址 ⇒ **不许进层2**，改投 `docs/topics/deploy.md`（Task 5）。

- [ ] **Step 5: 勾稽自检**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
grep -c '→2' /Users/zhangyi/my_project/filecodebox-project/PigeonBox/docs/specs/2026-11-13-agents-md-restructure-design.md
grep -rc '已落' /Users/zhangyi/my_project/filecodebox-project/PigeonBox/docs/specs/2026-11-13-agents-md-restructure-design.md
```

Expected: 每个 `→2` 条目在附录里都有 `✓已落` 勾稽（数量对得上；附录 A/B 里 `→2` 出现次数与 `已落` 次数一致）。**不一致就回 Step 2 补**。

- [ ] **Step 6: 提交（分文件小步提交）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
git add docs/rules/ && git commit -m "docs(rules): 层2 规则单源落位（AGENTS.md 重构 Step1）

按 spec 附录 A/B 分流:contributing/ci-gate/release/frontend/brand/generic
六文件;条目压缩不删判据(教训的为什么+判据保留,过程叙事删);
脱敏门 grep 内网模式零命中。Refs pigeonbox/pigeonbox#354"
```

---

### Task 2: CONTRIBUTING 去双份 + 行号引用修复（hub）

**Files:**
- Modify: `hub-agents-rules/CONTRIBUTING.md`（「硬性规则（CI 强制）」节 L68-73）
- Modify: `hub-agents-rules/release/trainctl/cigate.go:5`（「AGENTS.md L875」）

**Interfaces:**
- Consumes: Task 1 的 `docs/rules/contributing-rules.md`

- [ ] **Step 1: CONTRIBUTING 硬性规则节改单源**

把 `## 硬性规则（CI 强制）` 下 4 条（依赖单向/生成物/破坏性/钉版）替换为：

```markdown
## 硬性规则（CI 强制）

**规则正文的唯一真相源 = [`docs/rules/`](docs/rules/)**（AGENTS.md 重构 2026-11-13 起单源维护，
本节不再复制正文）：依赖单向 / 生成物勿手改 / 破坏性升主版本 / 钉版规则见
[`docs/rules/contributing-rules.md`](docs/rules/contributing-rules.md)。

CI 强制面不变：contracts 生成链 `CHECK=1`、core 路由守卫、各仓 lint/冒烟照旧。
```

- [ ] **Step 2: 行号引用改节名引用**

`cigate.go:5` 中 `是靠人记的规则(AGENTS.md L875)` 改为：

```go
// 是一条靠人记的规则(AGENTS.md·门禁与发布流水线的失效形态节;2026-11-13 重构后
// 该节全文在 PigeonBox/docs/rules/ci-gate-failures.md)。本判据机械化它:
```

并跑全仓引用清零扫描（G5）：

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
grep -rn "AGENTS.md L[0-9]" . --include='*.go' --include='*.md' --include='*.sh' --include='*.yml' | grep -v docs/specs/ || echo 仓内清零
```

Expected: `仓内清零`（spec 文件里的行号是历史取证，豁免）。

- [ ] **Step 3: trainctl 回归 + 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules/release/trainctl && GOWORK=off go vet ./... && GOWORK=off go test ./... 2>&1 | tail -2
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
git add CONTRIBUTING.md release/trainctl/cigate.go && git commit -m "docs(contributing): 硬性规则改指 docs/rules 单源 + 行号引用改节名引用

CONTRIBUTING 与 AGENTS 双份口径收敛;cigate.go 的 AGENTS.md L875 引用
随重构改为节名引用(行号会漂)。Refs pigeonbox/pigeonbox#354"
```

Expected: 测试 `ok`；提交成功。

---

### Task 3: 守卫脚本 + Step1 PR（hub）

**Files:**
- Create: `hub-agents-rules/scripts/check-agents-md.sh`
- Modify: `hub-agents-rules/Makefile`（`agents-guard` 目标 + `.PHONY`）

**Interfaces:**
- Produces: `bash scripts/check-agents-md.sh` → 退出码 0=过 / 1=红（四判据）；`make agents-guard`

- [ ] **Step 1: 写守卫脚本（TDD 顺序：先跑一次看它对旧文件红）**

写 `scripts/check-agents-md.sh`：

```bash
#!/usr/bin/env bash
# check-agents-md.sh —— AGENTS.md 薄索引守卫(2026-11-13 规则重构,spec G6)。
#
# 四判据:①尺寸 ≤24KB ②层1 指针目标存在 ③无 >120 字重复长行 ④bump 版本矩阵
# 15 个行首格锚点在(契约见 spec §6;trainctl bump 按行首格定位、改末格)。
#
# ⚠️ 重构完成前跑本脚本会红(旧文件 207KB > 24KB)——属预期,不是脚本坏。
# 用法: bash scripts/check-agents-md.sh   (在 hub 仓根;读 ../AGENTS.md)
set -euo pipefail

AGENTS="../AGENTS.md"
[ -f "$AGENTS" ] || { echo "✗ 找不到 $AGENTS"; exit 1; }
rc=0

# ① 尺寸 ≤24KB(24576 字节)
size=$(wc -c < "$AGENTS")
if [ "$size" -gt 24576 ]; then
  echo "✗ ① 尺寸 $size B > 24576 B —— AGENTS.md 必须是薄索引(实录进 docs/topics/)"
  rc=1
else
  echo "✓ ① 尺寸 $size B"
fi

# ② 层1 指针目标存在:提取行内 ](路径) 与「→ docs/」「→ PigeonBox/docs/」式指针
missing=0
while IFS= read -r target; do
  [ -z "$target" ] && continue
  case "$target" in http*) continue;; esac
  # 指针两种形态:相对 hub 的 PigeonBox/... 与相对工作区的 docs/...
  p1="$target"
  p2="../$target"
  if [ ! -e "$p1" ] && [ ! -e "$p2" ]; then
    echo "✗ ② 断指针: $target"
    missing=1; rc=1
  fi
done < <(grep -oE '\]\((PigeonBox/[^)]+|docs/[^)]+)\)' "$AGENTS" | sed 's/](\(.*\))/\1/' | sort -u)
[ "$missing" -eq 0 ] && echo "✓ ② 指针目标全存在"

# ③ 重复长行(>120 字)出现 ≥2 次 = 语义重复回归
dups=$(awk 'length($0)>120' "$AGENTS" | sort | uniq -d | wc -l | tr -d ' ')
if [ "$dups" -gt 0 ]; then
  echo "✗ ③ $dups 条 >120 字长行重复 —— 收敛为一"
  awk 'length($0)>120' "$AGENTS" | sort | uniq -d | head -3
  rc=1
else
  echo "✓ ③ 无重复长行"
fi

# ④ bump 锚点 15 个行首格(spec §6:12 字面键 + platforms 3)
anchors=( '`PigeonBox/`' '`PigeonBox/contracts/`' '`PigeonBox/core/`' '`PigeonBox/frontend-core/`' '`PigeonBox/server/`' '`PigeonBox/frontend/`' '`PigeonBox/fnos/`' '`PigeonBox/openwrt/`' '`PigeonBox/qnap/`' '`PigeonBox/p2p/`' '`desktop/`' '`charts/`' '`PigeonBox/synology/`' '`PigeonBox/ugreen/`' '`PigeonBox/terramaster/`' )
miss=0
for a in "${anchors[@]}"; do
  # 行首格 = 表行以 "| <key> |" 开头(允许前后空格)
  if ! grep -qE "^\|[[:space:]]*${a//\`/\\\`}[[:space:]]*\|" "$AGENTS"; then
    echo "✗ ④ 缺锚点行: $a"
    miss=1; rc=1
  fi
done
[ "$miss" -eq 0 ] && echo "✓ ④ 15 个 bump 锚点全在"

exit $rc
```

- [ ] **Step 2: 跑一次（对当前旧 AGENTS.md 应红——①③④ 可能红）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules && bash scripts/check-agents-md.sh; echo "exit=$?"
```

Expected: **exit=1**（旧文件 207KB 必红①；这证明判据真的在拦，不是空转）。把红输出记进提交体（负对照①：判据对旧态转红）。

- [ ] **Step 3: Makefile 挂目标**

在 `train-status:` 目标后加：

```make
agents-guard:       ## AGENTS.md 薄索引守卫(≤24KB/指针/重复/锚点;读 ../AGENTS.md)
	@bash scripts/check-agents-md.sh
```

`.PHONY` 行（`... train-status train-bump ...` 处）插入 `agents-guard`。

- [ ] **Step 4: 门禁 + 开 PR**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules
bash scripts/check-action-pins.sh | tail -1
bash scripts/check-docs-consistency.sh --selfcheck 2>&1 | tail -1
gofmt -l release/trainctl/ | head -3   # 期望空
git add scripts/check-agents-md.sh Makefile && git commit -m "feat(scripts): AGENTS.md 薄索引守卫 agents-guard(四判据)

尺寸≤24KB/指针存在/无重复长行/15 个 bump 锚点;负对照:对重构前旧文件
(207KB)实跑转红 exit=1。CI 拿不到工作区 ../AGENTS.md ⇒ 本地 make
agents-guard,验收时跑。Refs pigeonbox/pigeonbox#354"
bash scripts/git-fetch-safe.sh push -u origin feat/agents-rules 2>/dev/null || git push -u origin feat/agents-rules
gh pr create -R pigeonbox/pigeonbox --base main --head feat/agents-rules \
  --title "docs(rules): AGENTS.md 重构 Step1 —— 层2 规则单源 + CONTRIBUTING 收敛 + 守卫" \
  --body "spec: docs/specs/2026-11-13-agents-md-restructure-design.md (#354)
层2 六文件落位(附录 A/B 逐条勾稽) + CONTRIBUTING 单源 + cigate.go 行号引用改节名 + agents-guard 守卫(负对照:对旧 207KB 实跑转红)。脱敏门:内网模式 grep 零命中。"
```

- [ ] **Step 5: 等 CI 绿 + auto-merge**

```bash
gh pr merge feat/agents-rules --auto --squash -R pigeonbox/pigeonbox 2>/dev/null || gh pr merge --auto --squash -R pigeonbox/pigeonbox
```

Expected: auto-merge 挂上；落地由 GitHub 通知（BEHIND 时 `gh pr update-branch` 后重挂——v4 实录手法）。

---

### Task 4: Step0 备份（动 AGENTS.md 前的硬前置）

**Files:**
- Create: `docs/archive/AGENTS.pre-restructure-2026-11-13.md`（工作区根 docs/，非仓内）

- [ ] **Step 1: 备份 + sha256**

```bash
cd /Users/zhangyi/my_project/filecodebox-project
mkdir -p docs/archive
cp AGENTS.md docs/archive/AGENTS.pre-restructure-2026-11-13.md
shasum -a 256 AGENTS.md docs/archive/AGENTS.pre-restructure-2026-11-13.md | tee docs/archive/AGENTS.pre-restructure-2026-11-13.sha256
```

Expected: 两个 sha256 **逐字相同**；不相同=复制坏了，重来。

- [ ] **Step 2: 与在途 bump 互斥确认**

```bash
grep -E '^(train|state):' /Users/zhangyi/my_project/filecodebox-project/PigeonBox/release/train.yaml
```

Expected: `state: shipped`（非 shipped ⇒ **停**：有在途 bump 会写同一张表，等它终态再动）。

---

### Task 5: 层3 `docs/topics/` 建档（附录 A 全部 →3 落位）

**Files:**
- Create: `docs/topics/incidents/2026-11-03-trains.md`、`docs/topics/deploy.md`、`docs/topics/repos.md`、`docs/topics/workspace.md`
- 勾稽: spec 附录 A 标 `→3` 的行（#4/#5/#11/#13/#19/#23 中 →3 项 + 附录 B 全部 →3 条）

**Interfaces:**
- Consumes: 附录 A/B 的 `→3` 条目与 AGENTS.md 源行
- Produces: Task 6 层1 指针的目标文件（路径必须与层1 指针一致）

- [ ] **Step 1: 四文件骨架**

`docs/topics/deploy.md` 头部：

```markdown
# 部署面（层3 · 敏感 · 永不入库）

> 来源：AGENTS.md 重构（2026-11-13，spec 附录 A#19/B）。含内网 IP/拓扑/热修史——
> **禁止复制进任何公开仓**。现状以各机实测为准，条目日期即证据日期。

## 机器清单（215 / 10.10.10.3 / 10.10.30.253 / 43 集群）
## 10.10.10.3 TLS 与模板补丁
## 413 事故与两级上限
## 热修镜像史（4.8.0/4.8.1，已退役）
## 平台装包（fnOS/QNAP 真机判据）
```

`docs/topics/workspace.md` 头部：

```markdown
# 工作区环境细节（层3 · 不入库）

> 来源：AGENTS.md 重构（2026-11-13，spec 附录 A#3/#4/#5/#13）。
> setup/init 加固史 · 本机网络与推送兜底 · 探针栈配方与三坑 · 无头复验通道
```

`docs/topics/incidents/2026-11-03-trains.md`：附录 A#11 的 ②③⑥ 条原文压缩归档（教训+证据日期格式）。

`docs/topics/repos.md` 头部：

```markdown
# 逐仓沿革（层3 · 不入库）

> 来源：AGENTS.md 生态仓库表的说明列长文（2026-11-13 重构）。
> **与各仓 Release notes/CHANGELOG 重复的部分直接删**——那边是真相源，此处只留
> 表格放不下的「为什么长这样」类背景。
```

- [ ] **Step 2: 逐条搬运 + 勾稽**

按附录 A/B 的 `→3` 条目逐条搬（含附录 B：L850-853、L862、L863-864、L860（先核对现况：core lint 存量红问题若已修 ⇒ 该条改判 `删` 并在附录标注）、L857（同法核对 NAS check 是否已从保护规则删除）、L886、附录 A#19 部署面全节、#13 探针配方）。

每搬一条，在 spec 附录对应行尾追加 `✓已落 docs/topics/<file>`。

- [ ] **Step 3: 敏感自检（层3 不设脱敏，但要确认没漏进层2）**

```bash
grep -rEn '10\.10\.10\.3|10\.44\.|home\.enjoye' /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules/docs/rules/ && echo 红 || echo 层2无泄漏
```

Expected: `层2无泄漏`（此步是 Task 1 Step4 脱敏门的交叉复核；此时 Task 1 应已合并，主检出 `git pull` 后再跑）。

- [ ] **Step 4: 无 git 的提交替代——记录**

工作区无版本控制 ⇒ 无 commit 步；改为在 spec 附录记录完成状态（Step 2 已做），
并 `ls -la docs/topics/` 输出留档进最终汇报。

---

### Task 6: 层1 薄索引重写（AGENTS.md ≤24KB）

**Files:**
- Modify: `AGENTS.md`（整文件重写；旧内容已由 Task 4 备份、按附录分流至层2/3）

**Interfaces:**
- Consumes: 附录 A `留1` 项（层1 保留清单）、Task 1 的 `docs/rules/README.md`、Task 5 的 topics 路径

- [ ] **Step 1: 按层1 骨架重写**

目标结构（每节目标尺寸是上限）：

```markdown
# AGENTS.md — pigeonbox-project
（4 行头部：项目一句话 + 品牌现状 + 版本沿革指向 Release notes + 本文件=薄索引）

## 怎么用本文件（治理注，必留）
新事故 → docs/topics/incidents/<日期>-<主题>.md；只有「每次任务都会撞」的教训
才在本文件加一行；**禁止**向本文件堆实录段落（守卫: make agents-guard）。
公开安全的持久规则 → hub docs/rules/（PR 维护）；内网/部署/逐仓沿革 → docs/topics/。

## 生态仓库（⚠️ bump 版本矩阵回写锚点 —— 行首格/末格结构冻结，见 spec §6）
（原表保留 15 行：行首格不变、说明列压到 ≤60 字/仓、版本末格不动；
 逐仓沿革长文已移 docs/topics/repos.md）

## 目录现状（≤25 行）
（原 L39-58 压缩：目录树 + 文档站 2 行 + setup 同源 1 行 + git-fetch-safe 1 行）

## 永真硬规则（≤40 行）
worktree 纪律(压缩) · API Key scopes 表(压4行) · 主版本 4.x 规则 ·
许可证 2 行 · 取件计次 2 行(指设计稿) · 视觉自检 1 行 · 发版前扫全生态 CI 1 行 ·
加门禁四问 · 上传两闸口不变量 2 行

## 常用命令
（原 L613-624 + v4 新增 train-status/train-preflight/preflight）

## 发车必守点（压缩版，≤30 行）
（附录 A#21 逐条处置后的现状版：#3/#5/#6 留，#1/#2/#7/#8/#10 压成现状一行，
 #4 标注「列车已自愈 BEHIND」，#9 实施时核对现况）

## 指针索引（每条一句「什么时候读我」）
→ PigeonBox/docs/rules/README.md（六文件各自入口）
→ docs/topics/deploy.md（动部署/升级前）
→ docs/topics/workspace.md（工作区环境/setup/探针问题）
→ docs/topics/incidents/（历史事故现场）
→ docs/topics/repos.md（逐仓背景）
→ 各设计稿/规划稿（取件计次、能力演进等，原指针保留）
```

写法铁律：**每条留1 内容都要能在新结构里找到出处**——附录 A 标 `留1` 的行是清单，逐行落实；
附录 B 标 `留1` 的条目逐条落实（合计 ≤10KB）。

- [ ] **Step 2: 尺寸与守卫**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-agents-rules && bash scripts/check-agents-md.sh; echo exit=$?
```

Expected: **exit=0**（四判据全绿：≤24KB、指针全存在、无重复长行、15 锚点在）。红了按判据逐条修——**不许放宽阈值**。

- [ ] **Step 3: 行号引用全清零（G5）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project
grep -rn "AGENTS.md L[0-9]" PigeonBox/ docs/ --include='*.go' --include='*.md' --include='*.sh' | grep -v 'docs/specs/2026-11-13' || echo 工作区+仓内全清零
```

Expected: `全清零`（spec 取证行豁免）。

- [ ] **Step 4: 逐行勾稽终检**

```bash
cd /Users/zhangyi/my_project/filecodebox-project
spec=PigeonBox/docs/specs/2026-11-13-agents-md-restructure-design.md
echo "附录A行数: $(sed -n '/附录 A/,/附录 B/p' $spec | grep -cE '^\| [0-9]+ \|')"
echo "已勾稽: $(grep -o '✓已落' $spec | wc -l | tr -d ' ')"
```

Expected: 附录 A 23 行全部处置完毕（每行有 `留1/→2/→3/删` 且 `→2/→3` 行带 `✓已落`）；
`删` 行不需要勾稽但必须有理由。数字对不上 ⇒ 回附录补勾。

- [ ] **Step 5: 记录最终尺寸**

```bash
wc -c AGENTS.md && shasum -a 256 AGENTS.md
```

Expected: ≤24576 字节；sha256 记入最终汇报（与 Task 4 备份 sha 对照=回退点）。

---

### Task 7: 场景抽查（G6，真子代理 5 题）

**Files:** 无；产出=抽查记录（附进最终汇报）

- [ ] **Step 1: 逐题派发（每题一个独立 explore 子代理）**

用 `task` 工具派 `explore` 子代理，prompt 模板（每题替换 `<Q>`）：

```
只依据你注入的项目 AGENTS.md（不要读 PigeonBox/docs/specs/ 下任何设计稿）回答：
<Q>
回答里必须给出你依据的**章节名或文件路径**（如 AGENTS.md·发车必守点 或 docs/topics/xxx.md）。
```

五题（spec §5）：
1. `<Q>` = 4.8.3 那次 BEHIND 卡合并，人工兜底怎么做、根因是什么？
2. `<Q>` = chunk 续传为什么不能重新 init？
3. `<Q>` = 同机另一会话在改 core，我动手前的纪律是什么？
4. `<Q>` = 发车前库线钉版要人算吗，什么时候必须传 SET=？
5. `<Q>` = 管理台表格加一列，窄屏裁切怎么验？

- [ ] **Step 2: 判卷**

通过标准（spec §5）：**≥4/5 一次答对**且引用**新结构路径**（节名/文件名，不是旧行号）。
判卷记录格式：`题N: 对/错 · 引用路径 · 备注`。

- [ ] **Step 3: 不达标处置**

<4/5 ⇒ 定位是「指针没写清」还是「内容搬错层」：改 AGENTS.md 指针措辞或挪内容，
**改完重跑 Task 6 Step 2 守卫**，再补测失分题（最多两轮；两轮仍不过 ⇒ 停下汇报，不许放水）。

---

### Task 8: 验收收尾（G1-G7 清单 + spec 状态回写 + 汇报）

**Files:**
- Modify: `PigeonBox/docs/specs/2026-11-13-agents-md-restructure-design.md`（状态行）
- Modify: `docs/archive/…`（无；只读核对）

- [ ] **Step 1: G1-G7 逐条打勾**

| # | 验证命令 | 期望 |
|---|---|---|
| G1 | `wc -c AGENTS.md` | ≤24576 |
| G2 | `ls hub/docs/rules/*.md` + `ls docs/topics/*.md` | 六文件 + 四档案在 |
| G3 | spec 附录勾稽计数（Task 6 Step 4） | 零漏项 |
| G4 | `cd hub && make trainctl && ./bin/trainctl bump TRAIN=9.9.9 --dry-run 2>&1 \| grep -c '未找到表格行'` | `0`（dry-run 零落盘；跑完 `git checkout -- release/train.yaml` 防残留） |
| G5 | `grep -rn "AGENTS.md L[0-9]" PigeonBox/ docs/ \| grep -v docs/specs/2026-11-13` | 空 |
| G6 | `make agents-guard` + Task 7 判卷 | exit=0 且 ≥4/5 |
| G7 | `shasum -a 256 AGENTS.md docs/archive/AGENTS.pre-restructure-2026-11-13.md` 对照 Task 4 记录 | 备份完好 |

- [ ] **Step 2: spec 状态回写 + 提交**

状态行改：`- 状态：**已实施（Step0-2 落地，G1-G7 全过）；场景抽查 N/5**`（N=Task 7 实际）。
在 hub 分支（若 Task 3 的分支已合并 ⇒ 新开 `docs/agents-md-restructure-done` 分支）提交推送，
PR 或直接挂进既有 #354（若未合并）。

- [ ] **Step 3: 最终汇报**

向用户汇报：G1-G7 结果表、抽查判卷、最终 AGENTS.md 尺寸与 sha256、备份位置、
层2/层3 文件清单、遗留（若有：L857/L860 核对结论、两轮抽查未过项）。

---

## Self-Review（已执行）

1. **Spec coverage**：G1→T6S2/S5；G2→T1/T5；G3→T1S5/T5S2/T6S4 勾稽链；G4→T8S1；
   G5→T2S2/T6S3/T8S1；G6→T3 守卫+T7 抽查；G7→T4。附录 A23 节与附录 B 逐条经
   T1（→2）/T5（→3/核对项）/T6（留1）三路全收，`删` 项在附录标理由即可——**零漏项闭环**。
   spec §4 治理注→T6S1 骨架首节；§5 风险（撞车）→T4S2。
2. **Placeholder scan**：无 TBD/TODO；`L857/L860 现况核对`是带判据的二选一动作（已修⇒删/仍在⇒→3+理由），
   非占位；搬运内容以 spec 附录为映射真相源（spec 即交付物，非省略）；条目格式给了完整实例（T1S3）。
3. **Type/路径一致性**：`docs/rules/README.md`（T1）↔ 层1 指针（T6）↔ 守卫②的路径提取（T3）一致；
   `check-agents-md.sh` 四判据与 T6S2/T8S1 调用一致；`agents-guard` 目标名 T3 定义/T8 引用一致；
   topics 四文件名 T5 创建/T6 指针/T8G2 检查一致；锚点 15 键 T3 脚本数组与 spec §6 一致。
