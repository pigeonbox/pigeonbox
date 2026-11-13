# 发布列车 v4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地设计稿 `docs/specs/2026-11-13-release-train-v4-design.md` 的四个工作流——打 tag 前 CI 门禁、BEHIND 自愈、发车 preflight 五道闸、进度可见（status/job summary），验收 = 下一趟真车零人工干预。

**Architecture:** 不改状态机语义与 bump 写回链路（spec §6 七条不变量）。新增三个文件（`cigate.go` / `preflight.go` / `status.go`），在 `libline.go`/`tag.go`/`advance.go`/`run.go` 做最小挂点；CI 判据单一来源 `assertRepoCIGreen`，三处落点共用；所有 gh 调用走既有可替换缝 `ghRunner`（默认 = `Gh`，行为零变化）。

**Tech Stack:** Go stdlib（trainctl 无第三方依赖）、`gh` CLI、GitHub Actions、Go 表驱动测试。

## Global Constraints

- **不变量（spec §6，逐条成立才算完成）**：bump 切分支/三方合并/暂存链路一行不改；train.yaml 状态机语义与 schema 不动、preflight 不写 train.yaml；唤醒源不变（不新增 cron/回调）；`checksAllGreenLatest` 判定口径不改；`run` 缺省真执行语义不改（#347 契约）、`verify` 判据不动；CI 门禁判据只允许调 `assertRepoCIGreen`（禁止内联第二套）；门禁查不到信息 ≠ 放行（有证据才 pass）。
- **测试命令**：`cd release/trainctl && GOWORK=off go test ./...`（与 Makefile/CI 同款；`GOWORK=off` 防 go.work 映射掩盖钉版）。
- **负对照纪律（仓内惯例）**：每条新断言必须实测「改回缺陷态 ⇒ 转红」再还原，提交信息里写明做了哪些负对照。
- **缝**：新代码一律调 `ghRunner`（env.go:176，默认 `= Gh`）；已有 `ghRun`（env.go:153）是哨兵 issue 专用缝，不混用。
- **共享测试助手（已存在，勿重造）**：`gitRun(t,dir,args...)`、`writeFile(t,dir,file,content)`、`newFfPair(t)`、`stubGh(t)`（bump_commit_e2e_test.go:76，只记录调用+特判 `pr create`）。
- **worktree 纪律（AGENTS.md L148）**：同机并行会话可能 `checkout`/`reset` 主检出 ⇒ 实施一律在独立 worktree（Task 0 创建）；push 用 `hub/scripts/git-fetch-safe.sh push`（SSH 超时实录）。
- **提交约定**：conventional 风格，每 task 至少一次提交；中文提交体写清「做了什么 + 负对照结果」。
- **不做的事**：不动 `run` 的 dry-run 分派（#347 已定）；不动 bump 的任何写回逻辑；不加新依赖；不改 AGENTS.md（规则重构是第二个子项目）。

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `release/trainctl/cigate.go` | 新建 | CI 门禁判据：`assertRepoCIGreen` / `waitAllCIGreen` / `cigState`（单一来源） |
| `release/trainctl/cigate_test.go` | 新建 | 判据全组合表驱动 + 路由桩 + 接线守卫 + 真机红 sha 负对照（env 门控） |
| `release/trainctl/libline.go` | 修改 | `ensureLibTag` 打 tag 前过门禁（落点 2） |
| `release/trainctl/tag.go` | 修改 | `runTag` 预检并行等待（落点 3a）+ `pushTag` 精确 sha 复核（落点 3b）+ `newTagGateReqs`/`remoteHeadSha` |
| `release/trainctl/run.go` | 修改 | `cmdRun` 前置 preflight + 库线失败开哨兵 |
| `release/trainctl/advance.go` | 修改 | `tryMergeReady` BEHIND 自愈 + `prMergeState`；`checksLatest` 的 `Gh`→`ghRunner`（一词，测试可桩） |
| `release/trainctl/advance_behind_test.go` | 新建 | 自愈状态机用例（3 次上限/DIRTY/回退路径） |
| `release/trainctl/preflight.go` | 新建 | 五道闸 `runPreflight` + `cmdPreflight` |
| `release/trainctl/preflight_test.go` | 新建 | 闸门用例 + 接线守卫（run.go/main.go/Makefile） |
| `release/trainctl/status.go` | 新建 | `collectStatus`/`renderStatus`/`cmdStatus` |
| `release/trainctl/status_test.go` | 新建 | 渲染表驱动 + 结论推导 + 接线守卫（main/Makefile/orchestrator） |
| `release/trainctl/main.go` | 修改 | `status`/`preflight` 子命令 + 帮助文本 |
| `Makefile` | 修改 | `train-status` / `train-preflight` 目标 |
| `.github/workflows/train-orchestrator.yml` | 修改 | 收尾 `if: always()` 步写 `$GITHUB_STEP_SUMMARY` |

---

### Task 0: 工作区与分支

**Files:** 无代码变更；创建 worktree。

- [ ] **Step 1: 从设计稿分支切出实施分支的 worktree**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/PigeonBox
git worktree add ../hub-train-v4 -b feat/train-v4 docs/train-v4-design
```

Expected: `Preparing worktree (new branch 'feat/train-v4')`，路径 `/Users/zhangyi/my_project/filecodebox-project/hub-train-v4`。后续所有改动都在此目录。

- [ ] **Step 2: 确认 worktree 里 trainctl 测试基线绿**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test ./...
```

Expected: `ok`（全部既有测试通过——这是「不回退」基线；若红，停下排查，不许带红开工）。

---

### Task 1: `cigate.go` — CI 门禁判据（红立即失败 / 在跑有界等待 / 有证据放行）

**Files:**
- Create: `release/trainctl/cigate.go`
- Test: `release/trainctl/cigate_test.go`

**Interfaces:**
- Consumes: `ghRunner`（env.go:176）、`defBranch(repo)`（env.go:35）、`shaShort(sha)`（tag.go:296）、`ghOrg`（env.go:18）
- Produces（后续 task 依赖）:
  - `type ciReq struct{ repo, sha string }`
  - `func assertRepoCIGreen(repo, sha string) error`（单仓单 sha；红/超时返回非 nil error）
  - `func waitAllCIGreen(reqs []ciReq) error`（并行等待共享时钟；空入参直接 nil）
  - 测试缝变量 `cigPollEvery` / `cigWaitLimit`（默认 20s / 10m，测试覆盖为 ms 级）

- [ ] **Step 1: 写失败测试**（`cigate_test.go` 全文）

```go
// cigate_test.go —— 打 tag 前 CI 门禁判据(spec 2026-11-13 §4.1/§7)。
//
// 负对照(实测转红后还原):把 cigState 的 failure 分支改成 wait ⇒
// TestCIGate_RedImmediate 转红(「红立即失败」丢失)。
package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

type ghRoute struct{ sub, resp string } // resp 以 "!" 开头 = 返回错误

// stubGhRoutes 按「参数子串」路由 ghRunner;返回记录的调用列表。
// 与 stubGh(只记录)的区别:需要按调用返回不同 JSON。
func stubGhRoutes(t *testing.T, routes ...ghRoute) *[]string {
	t.Helper()
	var calls []string
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		joined := strings.Join(args, " ")
		calls = append(calls, joined)
		for _, rt := range routes {
			if strings.Contains(joined, rt.sub) {
				if strings.HasPrefix(rt.resp, "!") {
					return "", errors.New(strings.TrimPrefix(rt.resp, "!"))
				}
				return rt.resp, nil
			}
		}
		return "", fmt.Errorf("桩未路由: %s", joined)
	}
	t.Cleanup(func() { ghRunner = prev })
	return &calls
}

// fastGate 把门禁时序压到毫秒级(测试里不许真等 20s)。
func fastGate(t *testing.T) {
	t.Helper()
	p, l := cigPollEvery, cigWaitLimit
	cigPollEvery, cigWaitLimit = time.Millisecond, 30*time.Millisecond
	t.Cleanup(func() { cigPollEvery, cigWaitLimit = p, l })
}

func TestCIGate_NoWorkflows(t *testing.T) {
	fastGate(t)
	calls := stubGhRoutes(t, ghRoute{"actions/workflows", "0"})
	if err := assertRepoCIGreen("pigeonbox", "abc123"); err != nil {
		t.Fatalf("无 workflow 的仓必须放行: %v", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("无 workflow 应在第 1 步放行,不应再查 runs(实际 gh 调用 %d 次)", len(*calls))
	}
}

func TestCIGate_NoPushCIOnDefaultBranch(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "0"},
	)
	if err := assertRepoCIGreen("pigeonbox", "abc123"); err != nil {
		t.Fatalf("main 从不跑 push CI(PR-only 仓)必须有证据放行: %v", err)
	}
}

func TestCIGate_GreenPasses(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"success"}]`},
	)
	if err := assertRepoCIGreen("core", "deadbeef"); err != nil {
		t.Fatalf("全绿必须放行: %v", err)
	}
}

// 负对照靶点:红必须**立即**失败,不进轮询。
func TestCIGate_RedImmediate(t *testing.T) {
	fastGate(t)
	calls := stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure"}]`},
	)
	err := assertRepoCIGreen("core", "deadbeef")
	if err == nil || !strings.Contains(err.Error(), "CI 红") {
		t.Fatalf("失败 run 必须立即判红,实得: %v", err)
	}
	n := 0
	for _, c := range *calls {
		if strings.Contains(c, "head_sha") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("红必须一次判定(不轮询),head_sha 实查 %d 次", n)
	}
}

func TestCIGate_WaitThenGreen(t *testing.T) {
	fastGate(t)
	polls := 0
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		switch {
		case strings.Contains(j, "actions/workflows"):
			return "2", nil
		case strings.Contains(j, "actions/runs?branch="):
			return "9", nil
		case strings.Contains(j, "head_sha"):
			polls++
			if polls == 1 {
				return `[{"s":"in_progress","c":""}]`, nil
			}
			return `[{"s":"completed","c":"success"}]`, nil
		}
		return "", fmt.Errorf("unexpected: %s", j)
	}
	t.Cleanup(func() { ghRunner = prev })
	if err := assertRepoCIGreen("core", "deadbeef"); err != nil {
		t.Fatalf("在跑→绿必须等到绿后放行: %v", err)
	}
	if polls < 2 {
		t.Fatalf("应至少轮询 2 次(等在跑),实得 %d", polls)
	}
}

func TestCIGate_TimeoutNoRuns(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
	 ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[]`},
	)
	err := assertRepoCIGreen("core", "deadbeef")
	if err == nil || !strings.Contains(err.Error(), "超时") {
		t.Fatalf("run 始终建不出来必须超时报错(查不到≠放行),实得: %v", err)
	}
}

func TestCIGate_APIErrorRetriesThenTimeout(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t, ghRoute{"actions/workflows", "!Bad credentials"})
	err := assertRepoCIGreen("core", "deadbeef")
	if err == nil || !strings.Contains(err.Error(), "超时") || !strings.Contains(err.Error(), "Bad credentials") {
		t.Fatalf("API 错误应按「等」处理并在超时时带出最后错误,实得: %v", err)
	}
}

// waitAllCIGreen:一个红 ⇒ 整批失败并点名(并行等待的失败传播)。
func TestWaitAll_OneRedFailsFast(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"repos/pigeonbox/green/", `[{"s":"completed","c":"success"}]`},
		ghRoute{"repos/pigeonbox/bad/", `[{"s":"completed","c":"failure"}]`},
	)
	err := waitAllCIGreen([]ciReq{
		{repo: "green", sha: "aaa"}, {repo: "bad", sha: "bbb"},
	})
	if err == nil || !strings.Contains(err.Error(), "bad") {
		t.Fatalf("批等待必须点名红仓,实得: %v", err)
	}
}

func TestWaitAll_EmptyIsNoop(t *testing.T) {
	if err := waitAllCIGreen(nil); err != nil {
		t.Fatalf("空批必须直接放行: %v", err)
	}
}

// 真机负对照(spec §7):历史红 sha 必须被判红。零破坏——只读查询既有失败 run。
// 手动步骤见计划 Task 2 Step 6。
func TestCIGate_RealRedShaE2E(t *testing.T) {
	sha := os.Getenv("PB_CIGATE_RED_SHA")
	if sha == "" {
		t.Skip("PB_CIGATE_RED_SHA 未设置(真机负对照,手动触发)")
	}
	if err := assertRepoCIGreen("core", sha); err == nil {
		t.Fatalf("历史红 sha %s 必须被判红(真机负对照)", sha[:12])
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test -run 'TestCIGate|TestWaitAll' ./...
```

Expected: 编译失败 `undefined: assertRepoCIGreen / cigPollEvery / waitAllCIGreen / ciReq`。

- [ ] **Step 3: 实现 `cigate.go`**

```go
// cigate.go —— 打 tag 前的 CI 门禁判据(单一来源;spec 2026-11-13 §4.1)。
//
// 为什么存在:列车此前只做版本对账、不看 CI 状态 ⇒ 库线仓带着红 CI 照样发版
// (core gofmt 连续红/contracts 生成链红均实录发出过),「发版前人工 gh run list」
// 是一条靠人记的规则(AGENTS.md L875)。本判据机械化它:
//
//	落点三处(禁止内联第二套判定,spec §6 不变量 6):
//	  preflight 基线(preflight.go) / ensureLibTag(libline.go) / runTag+pushTag(tag.go)
//
// 判定语义(「查不到 ≠ 放行」,spec §6 不变量 7):
//   - 该仓无 workflow          ⇒ pass(无 CI 可查,注记原因)
//   - 默认分支从不跑 push CI   ⇒ pass(**有证据**的放行:内容已由 bump PR checks 把关)
//   - 目标 sha 有失败 run      ⇒ 立即 red(失败不会自愈,不等)
//   - 在跑 / run 未创建        ⇒ 有界等待(cigPollEvery 轮询,cigWaitLimit 超时即红)
//   - API 错误                 ⇒ 按「等」重试,超时把最后错误带出(瞬时网络抖动不误杀)
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// 时序参数做成变量:测试覆盖为毫秒级(负对照不许真等 20s)。
var (
	cigPollEvery = 20 * time.Second
	cigWaitLimit = 10 * time.Minute
)

type cigVerdict int

const (
	cigPass cigVerdict = iota
	cigRed
	cigWait
)

// ciReq 是一条「仓 → 待打 tag 的提交」门禁请求。
type ciReq struct {
	repo, sha string
}

// assertRepoCIGreen 单仓单 sha 的门禁(waitAllCIGreen 的单元素特化)。
func assertRepoCIGreen(repo, sha string) error {
	return waitAllCIGreen([]ciReq{{repo: repo, sha: sha}})
}

// waitAllCIGreen 并行等待全部请求绿:单轮询共享时钟(spec §3 决策 3 —— runTag
// 对本趟全部待 tag 仓一次等齐,净增 ≤ 一轮 CI,不是 N 轮串联)。
// 任一红立即整批失败并点名;全部 pass 才返回 nil。
func waitAllCIGreen(reqs []ciReq) error {
	if len(reqs) == 0 {
		return nil
	}
	deadline := time.Now().Add(cigWaitLimit)
	pending := make(map[int]ciReq, len(reqs))
	detail := make(map[int]string, len(reqs))
	lastErr := make(map[int]error, len(reqs))
	for i, r := range reqs {
		pending[i] = r
	}
	for {
		for i, r := range pending {
			v, d, err := cigState(r.repo, defBranch(r.repo), r.sha)
			if err != nil {
				lastErr[i] = err
				detail[i] = "API 错误: " + err.Error()
				continue
			}
			lastErr[i] = nil
			detail[i] = d
			switch v {
			case cigPass:
				delete(pending, i)
				if d != "" {
					fmt.Printf("  ✓ CI 门禁 %s: %s\n", r.repo, d)
				}
			case cigRed:
				return fmt.Errorf("%s@%s CI 红——拒绝打 tag:%s(修复后重跑,列车/sweep 会接力)",
					r.repo, shaShort(r.sha), d)
			}
		}
		if len(pending) == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			var lines []string
			for i := range pending {
				r := pending[i]
				if lastErr[i] != nil {
					lines = append(lines, fmt.Sprintf("%s@%s 等待超时(%v)", r.repo, shaShort(r.sha), lastErr[i]))
				} else {
					lines = append(lines, fmt.Sprintf("%s@%s 等待超时(%s)", r.repo, shaShort(r.sha), detail[i]))
				}
			}
			sort.Strings(lines)
			return fmt.Errorf("CI 门禁等待超时(%s):\n  %s", cigWaitLimit, strings.Join(lines, "\n  "))
		}
		time.Sleep(cigPollEvery)
	}
}

// cigState 单仓单 sha 的一次性判定(不等待;等待在 waitAllCIGreen 的循环里)。
func cigState(repo, def, sha string) (cigVerdict, string, error) {
	full := ghOrg + "/" + repo
	// 1) 该仓有没有 workflow
	out, err := ghRunner("api", "repos/"+full+"/actions/workflows", "--jq", ".total_count")
	if err != nil {
		return cigWait, "", err
	}
	if strings.TrimSpace(out) == "0" {
		return cigPass, "无 workflow(纯脚本仓)", nil
	}
	// 2) 默认分支有没有 push CI 先例(没有 ⇒ PR-only 仓,有证据放行)
	out, err = ghRunner("api", fmt.Sprintf("repos/%s/actions/runs?branch=%s&per_page=5", full, def), "--jq", ".total_count")
	if err != nil {
		return cigWait, "", err
	}
	if strings.TrimSpace(out) == "0" {
		return cigPass, "默认分支从不跑 push CI(PR-only,内容由 bump PR checks 把关)", nil
	}
	// 3) 目标 sha 的 run 结论(按 commit 查,不按「最新一次 run」——squash 合并
	//    到 main 是新 commit,bump PR 绿的是 PR head)
	out, err = ghRunner("api", fmt.Sprintf("repos/%s/actions/runs?head_sha=%s", full, sha),
		"--jq", `[.workflow_runs[] | {s: .status, c: (.conclusion // "")}]`)
	if err != nil {
		return cigWait, "", err
	}
	var runs []struct {
		S string `json:"s"`
		C string `json:"c"`
	}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		return cigWait, "", fmt.Errorf("解析 %s 的 runs 失败: %w", repo, err)
	}
	if len(runs) == 0 {
		return cigWait, "run 尚未创建", nil
	}
	// 失败优先:失败不会自愈,立即红(不等在跑的那个)
	for _, r := range runs {
		switch r.C {
		case "failure", "cancelled", "timed_out", "action_required", "startup_failure":
			return cigRed, fmt.Sprintf("存在失败 run(conclusion=%s)", r.C), nil
		}
	}
	for _, r := range runs {
		if r.S != "completed" {
			return cigWait, "run 在跑", nil
		}
		switch r.C {
		case "success", "skipped", "neutral", "stale":
			// 通过(stale=被重跑取代的旧记录,不拦)
		default:
			// 未知结论:响亮判红(spec §6 不变量 7),不静默放行
			return cigRed, fmt.Sprintf("未知 run 结论 %q(按「查不到≠放行」判红)", r.C), nil
		}
	}
	return cigPass, "", nil
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test -run 'TestCIGate|TestWaitAll' ./... -v 2>&1 | tail -25
```

Expected: 全部 `PASS`（9 条 + 1 条 skip 的真机负对照）。

- [ ] **Step 5: 负对照——把 failure 分支改成 wait，确认转红后还原**

把 `cigState` 的 `case "failure", ...:` 分支临时改成 `return cigWait, "x", nil`，跑：

```bash
GOWORK=off go test -run TestCIGate_RedImmediate ./...
```

Expected: **FAIL**（红不再立即失败 / head_sha 被轮询多次）。还原后重跑确认 `PASS`。

- [ ] **Step 6: 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add release/trainctl/cigate.go release/trainctl/cigate_test.go
git commit -m "feat(trainctl): 打 tag 前 CI 门禁判据 cigate(单一来源)

assertRepoCIGreen/waitAllCIGreen:红立即失败、在跑/未建 run 有界等待
(20s 轮询/10min 上限)、无 workflow 与 PR-only 仓**有证据**放行、
API 错误按等重试超时带出、未知结论按「查不到≠放行」判红。
负对照:failure 分支改 wait ⇒ TestCIGate_RedImmediate 实测转红后还原。"
```

---

### Task 2: 门禁落点接线（库线 tag / runTag 并行 / pushTag 精确复核 / 库线失败开哨兵）

**Files:**
- Modify: `release/trainctl/libline.go`（`ensureLibTag`，约 L312 sha 解析后）
- Modify: `release/trainctl/tag.go`（`runTag` 目标清单构建后 + `pushTag` L142 后；新增 `newTagGateReqs`/`remoteHeadSha`）
- Modify: `release/trainctl/run.go`（两处库线 `die` 前开哨兵，L63-65 / L69-71）
- Test: `release/trainctl/cigate_test.go`（追加接线守卫 + `newTagGateReqs` 用例）

**Interfaces:**
- Consumes: Task 1 的 `assertRepoCIGreen` / `waitAllCIGreen` / `ciReq`；既有 `reportStalledIssue(train, []string)`（advance.go:493）、`firstLine`、`env.TagExists`、`defBranch`
- Produces: `func newTagGateReqs(targets []tagTarget, exists func(repo, tag string) bool, shaFn func(repo string) (string, error)) ([]ciReq, error)`、`func remoteHeadSha(repo string) (string, error)`（Task 4 复用 `remoteHeadSha`）

- [ ] **Step 1: `libline.go` `ensureLibTag` 插入门禁**（在 `sha, err := Git(dir, "rev-parse", "origin/"+def)` 成功之后、`Git(dir, "tag", tag, sha)` 之前，约 L312-313 之间）

```go
	// 打 tag 前 CI 门禁(spec §4.1 落点 2):库线带红 CI 发版是实录缺口
	// (core gofmt 连红/contracts 生成链红均发出过)。同一判据,勿内联第二套。
	if err := assertRepoCIGreen(lr.repo, sha); err != nil {
		return false, fmt.Errorf("%s 打 tag 前门禁未过: %w", lr.key, err)
	}
```

- [ ] **Step 2: `tag.go` 新增两个助手**（文件底部）

```go
// newTagGateReqs 从 tag 目标里挑出将要**新建**的 tag(exists 命中的跳过——
// 重跑/接力语义不变),并解析各自默认分支头。shaFn 注入以便离线单测。
func newTagGateReqs(targets []tagTarget, exists func(repo, tag string) bool, shaFn func(repo string) (string, error)) ([]ciReq, error) {
	var reqs []ciReq
	for _, t := range targets {
		if t.tag == "" || exists(t.repo, t.tag) {
			continue
		}
		sha, err := shaFn(t.repo)
		if err != nil {
			return nil, fmt.Errorf("%s 取默认分支头失败: %w", t.repo, err)
		}
		reqs = append(reqs, ciReq{repo: t.repo, sha: sha})
	}
	return reqs, nil
}

// remoteHeadSha 经 GitHub API 取默认分支头(不依赖本地检出;preflight 与
// runTag 预检共用)。
func remoteHeadSha(repo string) (string, error) {
	out, err := ghRunner("api", "repos/"+ghOrg+"/"+repo+"/commits/"+defBranch(repo), "--jq", ".sha")
	if err != nil {
		return "", err
	}
	sha := strings.TrimSpace(out)
	if sha == "" {
		return "", fmt.Errorf("%s API 返回空 sha", repo)
	}
	return sha, nil
}
```

- [ ] **Step 3: `runTag` 预检（落点 3a）**——在 `targets` 清单构建完成之后（约 L50 `}` 结束 platforms 循环后）、`for i, t := range targets` 之前插入：

```go
	// 打 tag 前 CI 门禁(spec §4.1 落点 3a):只查将要新建的 tag,**并行**等待
	// ——单轮询共享时钟,净增 ≤ 一轮 CI;任一红 ⇒ 哨兵 + die(零 tag 推出)。
	if reqs, err := newTagGateReqs(targets,
		func(r, tg string) bool { return env.TagExists(r, tg) },
		remoteHeadSha,
	); err != nil {
		die("CI 门禁预检失败(取默认分支头):%v", err)
	} else if len(reqs) > 0 {
		if err := waitAllCIGreen(reqs); err != nil {
			reportStalledIssue(train, []string{"打 tag 前 CI 门禁:" + firstLine(err.Error())})
			die("%v", err)
		}
	}
```

- [ ] **Step 4: `pushTag` 精确 sha 复核（落点 3b）**——在 `sha, err := Git(dir, "rev-parse", "origin/"+def)` 成功之后、`assertTagTarget(dir, sha, t, def)` 之前（L142-143 之间）插入：

```go
	// 精确复核(spec §4.1 落点 3b):pre-pass 用 API 读的头可能已移动,这里对
	// **真正要打的提交**再过同一判据(已绿 ⇒ 一次 API 调用即过,不增时延)。
	if err := assertRepoCIGreen(t.repo, sha); err != nil {
		die("%s 打 tag 前 CI 门禁未过:%v", t.repo, err)
	}
```

- [ ] **Step 5: `run.go` 库线失败开哨兵**——两处 `die` 前各加一行（L63-65 与 L69-71）：

```go
		if err := ensureLibLinePublished(env, o.libVersions, map[string]bool{}, o.timeout); err != nil {
			reportStalledIssue(o.train, []string{"库线阶段:" + firstLine(err.Error())})
			die("%v", err)
		}
```

```go
		if err := ensureLibLine(env, &o); err != nil {
			reportStalledIssue(o.train, []string{"库线阶段:" + firstLine(err.Error())})
			die("%v", err)
		}
```

（`reportStalledIssue` 的既有调用点模式见 advance.go:121；train 取自 `o.train`，与 L46 打印一致。）

- [ ] **Step 6: 追加测试**（`cigate_test.go` 末尾）

```go
// newTagGateReqs:已存在的 tag 跳过;新建的解析头;shaFn 出错即整批失败。
func TestNewTagGateReqs(t *testing.T) {
	targets := []tagTarget{
		{repo: "frontend", tag: "v5.9.0"},
		{repo: "server", tag: "v5.9.0"},
		{repo: "fnos", tag: "fnos-v5.9.0"},
	}
	exists := func(r, tg string) bool { return r == "server" } // server 已打过
	got_sha := map[string]string{"frontend": "aaa", "fnos": "ccc"}
	shaFn := func(r string) (string, error) {
		s, ok := got_sha[r]
		if !ok {
			return "", fmt.Errorf("no sha for %s", r)
		}
		return s, nil
	}
	reqs, err := newTagGateReqs(targets, exists, shaFn)
	if err != nil {
		t.Fatal(err)
	}
	if len(reqs) != 2 {
		t.Fatalf("server 已存在应跳过,应剩 2 条,实得 %d: %+v", len(reqs), reqs)
	}
	if reqs[0].repo != "frontend" || reqs[0].sha != "aaa" {
		t.Fatalf("reqs[0] 应为 frontend@aaa,实得 %+v", reqs[0])
	}
	// shaFn 失败 ⇒ 整批失败
	if _, err := newTagGateReqs([]tagTarget{{repo: "nope", tag: "v1"}}, func(_, _ string) bool { return false },
		func(string) (string, error) { return "", fmt.Errorf("boom") }); err == nil {
		t.Fatal("shaFn 失败必须整批报错(不许静默漏掉一个仓)")
	}
}

// 接线守卫:三个落点必须调用同一判据(spec §6 不变量 6;抽了函数不接线=形同虚设)。
func TestCIGateWiring(t *testing.T) {
	for file, needles := range map[string][]string{
		"libline.go": {"assertRepoCIGreen("},
		"tag.go":     {"assertRepoCIGreen(", "waitAllCIGreen(", "newTagGateReqs("},
		"run.go":     {"reportStalledIssue(o.train"},
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("读 %s 失败: %v", file, err)
		}
		for _, n := range needles {
			if !strings.Contains(string(b), n) {
				t.Errorf("%s 缺少 %q —— 门禁/哨兵未接线,改动形同虚设", file, n)
			}
		}
	}
}
```

注意：`cigate_test.go` 头部 import 需补 `"os"`（Step 1 已含）。

- [ ] **Step 7: 跑测试**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test ./... 2>&1 | tail -5
```

Expected: `ok`（新用例绿 + 全部既有测试不回退）。

- [ ] **Step 8: 真机负对照（零破坏）**

```bash
RED=$(gh api "repos/pigeonbox/core/actions/runs?status=failure&per_page=1" --jq '.workflow_runs[0].head_sha')
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl
PB_CIGATE_RED_SHA=$RED GOWORK=off go test -run TestCIGate_RealRedShaE2E ./... -v
```

Expected: `PASS`（判据对**真实历史红 sha** 立即判红）。若 `RED` 取不到（无失败 run），换 `pigeonbox/contracts` 或 `pigeonbox/server` 重取；三个仓都取不到则记录说明，跳过并在提交体注明。

- [ ] **Step 9: 负对照（接线）**——把 `libline.go` 的门禁行临时注释掉，跑 `TestCIGateWiring`：

Expected: **FAIL** 点名 `libline.go 缺少 "assertRepoCIGreen("`。还原后绿。

- [ ] **Step 10: 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add release/trainctl/libline.go release/trainctl/tag.go release/trainctl/run.go release/trainctl/cigate_test.go
git commit -m "feat(trainctl): CI 门禁三落点接线(库线 tag/runTag 并行/pushTag 精确复核)

ensureLibTag 打 tag 前、runTag 新建 tag 预检(并行等待,净增≤一轮 CI,
任一红⇒哨兵+die)、pushTag 对真正要打的 sha 精确复核;库线阶段失败
开哨兵(此前只 die 不留痕)。重跑/接力语义不变(已存在 tag 不拦)。
负对照:接线守卫(删 libline 落点⇒红) + 真机历史红 sha 判红(env 门控)。"
```

---

### Task 3: BEHIND 自愈（`tryMergeReady` + `prMergeState`）

**Files:**
- Modify: `release/trainctl/advance.go`（`tryMergeReady` L227-257 重写尾部逻辑 + 新增 `prMergeState`；`checksLatest` L303 `Gh(`→`ghRunner(`；`advanceDraft` L114 调用点）
- Test: `release/trainctl/advance_behind_test.go`

**Interfaces:**
- Consumes: `ghRunner`、`checksAllGreenLatest`（口径不动）、`reportStalledIssue`、`stepFailed`、`firstLine`
- Produces: `var healAttempts = map[string]int{}`（进程内）、`func prMergeState(repo, num string) string`、`func tryMergeReady(open []string) (exhausted []string)`

- [ ] **Step 1: 写失败测试**（`advance_behind_test.go` 全文）

```go
// advance_behind_test.go —— bump PR 的 BEHIND 自愈(spec 2026-11-13 §4.2)。
//
// 背景:strict required check 下 bump 分支落后 main 一个提交即 BEHIND ⇒
// auto-merge 永不触发(4.8.3/4.8.4 实录需人工 gh pr merge --admin)。每趟车
// 后合并的 bump PR **必然** BEHIND(main 每合一个前进一格)⇒ 自愈是主路径。
//
// 负对照(实测转红后还原):删掉 tryMergeReady 的 BEHIND 分支 ⇒
// TestTryMergeReady_BehindSelfHeals 转红(update-branch 不再被调)。
package main

import (
	"fmt"
	"strings"
	"testing"
)

func resetHeal(t *testing.T) {
	t.Helper()
	prev := healAttempts
	healAttempts = map[string]int{}
	t.Cleanup(func() { healAttempts = prev })
}

// behindStub 造「mergeStateStatus 恒 BEHIND」的 gh 桩,记录调用。
func behindStub(t *testing.T) *[]string {
	t.Helper()
	var calls []string
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		calls = append(calls, j)
		switch {
		case strings.Contains(j, "update-branch"):
			return "", nil
		case strings.Contains(j, "mergeStateStatus"):
			return `{"mergeStateStatus":"BEHIND"}`, nil
		case strings.Contains(j, "statusCheckRollup"):
			return `{"statusCheckRollup":[]}`, nil
		case strings.Contains(j, "pr merge"):
			t.Error("BEHIND 时不得尝试合并(等 update-branch 后下轮复查)")
			return "", nil
		default:
			return "", fmt.Errorf("unexpected gh call: %s", j)
		}
	}
	t.Cleanup(func() { ghRunner = prev })
	return &calls
}

func count(calls *[]string, sub string) int {
	n := 0
	for _, c := range *calls {
		if strings.Contains(c, sub) {
			n++
		}
	}
	return n
}

func TestTryMergeReady_BehindSelfHeals(t *testing.T) {
	resetHeal(t)
	calls := behindStub(t)
	if ex := tryMergeReady([]string{"frontend#7"}); len(ex) != 0 {
		t.Fatalf("首次自愈不超限,不应返回 exhausted: %v", ex)
	}
	if count(calls, "update-branch") != 1 {
		t.Fatalf("BEHIND 必须触发一次 update-branch 自愈,实得 %d 次", count(calls, "update-branch"))
	}
}

func TestTryMergeReady_BehindCapExhausts(t *testing.T) {
	resetHeal(t)
	calls := behindStub(t)
	for i := 0; i < 3; i++ {
		if ex := tryMergeReady([]string{"frontend#7"}); len(ex) != 0 {
			t.Fatalf("第 %d 次仍在上限内,不应 exhausted: %v", i+1, ex)
		}
	}
	ex := tryMergeReady([]string{"frontend#7"})
	if len(ex) != 1 || !strings.Contains(ex[0], "frontend#7") {
		t.Fatalf("第 4 次必须返回 exhausted 并点名,实得: %v", ex)
	}
	if n := count(calls, "update-branch"); n != 3 {
		t.Fatalf("自愈必须恰好 3 次(第 4 次只上报不重试),实得 %d", n)
	}
}

// CLEAN ⇒ 走原路径合并,不碰 update-branch(现有行为一行不改)。
func TestTryMergeReady_CleanMergesAsBefore(t *testing.T) {
	resetHeal(t)
	var calls []string
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		calls = append(calls, j)
		switch {
		case strings.Contains(j, "update-branch"):
			t.Error("CLEAN 不应自愈")
			return "", nil
		case strings.Contains(j, "mergeStateStatus"):
			return `{"mergeStateStatus":"CLEAN"}`, nil
		case strings.Contains(j, "statusCheckRollup"):
			return `{"statusCheckRollup":[{"name":"lint","workflowName":"ci","conclusion":"success","startedAt":"2026-11-13T00:00:00Z","completedAt":"2026-11-13T00:01:00Z"}]}`, nil
		case strings.Contains(j, "pr merge"):
			return "", nil
		default:
			return "", fmt.Errorf("unexpected: %s", j)
		}
	}
	t.Cleanup(func() { ghRunner = prev })
	if ex := tryMergeReady([]string{"frontend#7"}); len(ex) != 0 {
		t.Fatalf("CLEAN 不应 exhausted: %v", ex)
	}
	if count(calls, "pr merge") != 1 {
		t.Fatalf("CLEAN+绿 必须走原路径合并,pr merge 实得 %d 次", count(calls, "pr merge"))
	}
}

// mergeStateStatus 读不到 ⇒ 保守走原路径(不自愈也不误判),不得 panic。
func TestTryMergeReady_StateReadErrorFallsBack(t *testing.T) {
	resetHeal(t)
	var calls []string
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		j := strings.Join(args, " ")
		calls = append(calls, j)
		switch {
		case strings.Contains(j, "mergeStateStatus"):
			return "", fmt.Errorf("api down")
		case strings.Contains(j, "statusCheckRollup"):
			return `{"statusCheckRollup":[]}`, nil
		case strings.Contains(j, "pr merge"):
			return "", nil
		default:
			return "", fmt.Errorf("unexpected: %s", j)
		}
	}
	t.Cleanup(func() { ghRunner = prev })
	if ex := tryMergeReady([]string{"frontend#7"}); len(ex) != 0 {
		t.Fatalf("状态读不到应走原路径,不应 exhausted: %v", ex)
	}
	if count(calls, "update-branch") != 0 {
		t.Fatal("状态读不到时不得擅自 update-branch")
	}
	if count(calls, "pr merge") != 1 {
		t.Fatal("状态读不到应回落到原合并路径")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test -run TestTryMergeReady ./...
```

Expected: 编译失败 `undefined: healAttempts` / `tryMergeReady` 参数不匹配（现有是 `tryMergeReady(open []string)` 无返回值——若编译通过但用例红，也属预期）。

- [ ] **Step 3: 实现**

3a. `advance.go` L303 `checksLatest` 里 `Gh("pr", "view", ...)` 改为 `ghRunner("pr", "view", ...)`（**一词改动**：默认 `= Gh` 行为零变化，让 checks 判定可被测试桩；不动判定口径）。

3b. `tryMergeReady` 重写（保留 L237-246 注释与 checks 判定、L247-255 合并段原样）：

```go
// healAttempts 记录每个 bump PR 本进程内的 BEHIND 自愈次数。进程内 map:
// run 单进程自轮询(45s/轮),standalone advance 每次进程重置 = 每次唤醒最多
// 自愈一次;上限 3 是防「main 持续前进」死循环(fail-fast + 哨兵,人来判断)。
var healAttempts = map[string]int{}

// tryMergeReady 对 checks 全绿的 bump PR 直接 squash 合并
// (仓未开 auto-merge 或 bump 时开启失败的兜底;branch protection 阻挡时 --admin)。
//
// 返回「自愈超限」的 PR 清单:调用方(advanceDraft)开哨兵并 stepFailed。
//
// BEHIND 自愈(spec §4.2):strict required check 下分支落后 main 即 BEHIND ⇒
// auto-merge 永不触发(4.8.3 实录)。每趟车后合并的 bump PR 必然 BEHIND ⇒
// 这是主路径:gh pr update-branch 把 base 合进分支、重触发 checks,45s 后复查。
// DIRTY(冲突)点名要人但不自愈,落到原路径(合并失败响亮记录,不静默)。
func tryMergeReady(open []string) (exhausted []string) {
	for _, item := range open {
		repo, num, ok := strings.Cut(item, "#")
		if !ok {
			continue
		}
		num = strings.Fields(num)[0]
		full := ghOrg + "/" + repo

		switch prMergeState(repo, num) {
		case "BEHIND":
			key := repo + "#" + num
			if healAttempts[key] >= 3 {
				exhausted = append(exhausted, fmt.Sprintf("%s(BEHIND 自愈 3 次仍落后 main——main 在持续前进,需人工处理)", key))
				continue
			}
			healAttempts[key]++
			if _, err := ghRunner("pr", "update-branch", num, "-R", full); err != nil {
				warnf("%s#%s BEHIND 自愈失败(第 %d 次):%s", repo, num, healAttempts[key], firstLine(err.Error()))
			} else {
				warnf("%s#%s 落后 main,BEHIND 自愈第 %d 次(update-branch 重触发 checks)", repo, num, healAttempts[key])
			}
			continue // 本轮不动合并;45s 后下轮复查
		case "DIRTY":
			warnf("%s#%s 与 main 冲突(DIRTY)——需人工解冲突,列车随后自动接力", repo, num)
			// 落到原路径:合并必失败并响亮记录(不静默)
		}

		// checks 未绿不动;「仓没有任何 check」(纯脚本 NAS 仓)视为就绪,
		// 否则 gh pr checks 恒报 no checks、PR 永远等不到合并。
		//
		// ⚠️ 不用 `gh pr checks` 判绿（2026-10-23 实弹）：它把**重跑前**的失败
		// attempt 也列进来 ⇒ 最新一次已绿仍整体报失败 ⇒ bump PR 永远等不到
		// 合并（列车卡在 draft）。改为按「检查名取最新一次」判定。
		green, hasChecks := checksAllGreenLatest(repo, num)
		if hasChecks && !green {
			continue // 未绿/有失败——留给下次唤醒(失败会由 CI 红着,人来管)
		}
		if _, err := ghRunner("pr", "merge", num, "-R", full, "--squash", "--delete-branch"); err != nil {
			if _, err2 := ghRunner("pr", "merge", num, "-R", full, "--squash", "--delete-branch", "--admin"); err2 != nil {
				warnf("%s#%s 合并失败(%v / admin: %v 摘要)", repo, num, firstLine(err.Error()), firstLine(err2.Error()))
				continue
			}
			warnf("%s#%s 经 --admin 合并(branch protection 阻挡,已响亮记录)", repo, num)
			continue
		}
		okf("%s#%s checks 绿,已 squash 合并", repo, num)
	}
	return exhausted
}

// prMergeState 读 PR 的 mergeStateStatus(gh --json 顶层是对象,勿 unmarshal 到
// 裸值——同 checksAllGreenLatest 的 statusCheckRollup 坑)。
// 读不到 ⇒ 返回空串走原路径(保守:不自愈也不误判)。
func prMergeState(repo, num string) string {
	out, err := ghRunner("pr", "view", num, "-R", ghOrg+"/"+repo, "--json", "mergeStateStatus")
	if err != nil {
		return ""
	}
	var w struct {
		MergeStateStatus string `json:"mergeStateStatus"`
	}
	if err := json.Unmarshal([]byte(out), &w); err != nil {
		return ""
	}
	return w.MergeStateStatus
}
```

注意：原 L247-255 的 `Gh(` 调用一并换成 `ghRunner(`（同缝，测试需要）；`json` 已在 advance.go import（`checksLatest` 用了）。

3c. `advanceDraft` 调用点（L114）改为：

```go
		if ex := tryMergeReady(open); len(ex) > 0 {
			reportStalledIssue(train, ex)
			return stepFailed, "BEHIND 自愈超限:" + strings.Join(ex, ", ")
		}
```

- [ ] **Step 4: 跑测试**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test ./... 2>&1 | tail -5
```

Expected: `ok`（新 4 条绿 + 既有不回退——尤其 `advance_test.go`/`sentinel_issue_test.go`）。

- [ ] **Step 5: 负对照**——删掉 `tryMergeReady` 的 `case "BEHIND":` 整段（保留 default 落原路径），跑 `TestTryMergeReady`：

Expected: `BehindSelfHeals` 与 `BehindCapExhausts` **FAIL**（update-branch 不再被调）。还原后绿。

- [ ] **Step 6: 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add release/trainctl/advance.go release/trainctl/advance_behind_test.go
git commit -m "feat(trainctl): bump PR BEHIND 自愈(update-branch + 3 次上限 + DIRTY 点名)

strict required check 下 bump 分支落后 main 即 BEHIND ⇒ auto-merge 永不
触发(4.8.3/4.8.4 实录需人工 gh pr merge --admin);每趟车后合并的 bump PR
必然 BEHIND ⇒ 自愈是主路径。tryMergeReady 读 mergeStateStatus:BEHIND ⇒
gh pr update-branch 重触发 checks(每 PR 每进程上限 3 次,超限返回
exhausted ⇒ advanceDraft 开哨兵+stepFailed);DIRTY 点名要人走原路径;
读不到状态保守回落原路径。checks 判定口径与 --admin 兜底一行不动。
顺带:checksLatest 的 Gh→ghRunner(一词,默认同缝,测试可桩)。
负对照:删 BEHIND 分支 ⇒ 两条自愈用例实测转红后还原。"
```

---

### Task 4: preflight 五道闸 + `trainctl preflight`

**Files:**
- Create: `release/trainctl/preflight.go`
- Modify: `release/trainctl/run.go`（`cmdRun`：finished 提前返回 → preflight → 原 switch）
- Modify: `release/trainctl/main.go`（`case "preflight"` + 帮助文本）
- Modify: `Makefile`（`train-preflight` 目标）
- Test: `release/trainctl/preflight_test.go`

**Interfaces:**
- Consumes: Task 1 `waitAllCIGreen`/`ciReq`、Task 2 `remoteHeadSha`、`checkMarkerAhead`（marker.go:49，#347）、`waitLibConsumable`（libline.go）、`trainStateOnOrigin`、`reportStalledIssue`、`bumpPRRepos`（advance.go:16）、`libRepos()`（libline.go:47）、`env.RepoDir`、`firstLine`
- Produces: `func runPreflight(env *Env, o *bumpOpts) error`（run 与独立子命令共用）、`func cmdPreflight(env *Env, args []string)`、`func preflightRepos() []string`、`func gateStateVerdict(curTrain, curState, want string) error`

- [ ] **Step 1: 写失败测试**（`preflight_test.go` 全文）

```go
// preflight_test.go —— 发车前五道闸(spec 2026-11-13 §3/§7)。
//
// 语义:preflight 全程只读,任何一道红 ⇒ 零写操作失败。
// 负对照(实测转红后还原):把 gateStateVerdict 的「旧列车非终态」分支删掉 ⇒
// 两个 blocked 用例转红。
package main

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// gateState:旧列车卡非终态必须挡新车(bumpDecision 对此是「照常开新车」,
// 守门只在 bump 内;run/preflight 必须自己挡)。
func TestGateStateVerdict(t *testing.T) {
	cases := []struct {
		name, curTrain, curState, want string
		blocked                         bool
	}{
		{"无车", "", "", "5.9.0", false},
		{"本趟续跑", "5.9.0", "draft", "5.9.0", false},
		{"上趟已 shipped", "5.8.0", "shipped", "5.9.0", false},
		{"旧车卡 draft", "5.8.0", "draft", "5.9.0", true},
		{"旧车卡 tagged", "5.8.0", "tagged", "5.9.0", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := gateStateVerdict(c.curTrain, c.curState, c.want)
			if c.blocked && err == nil {
				t.Fatalf("旧列车 %s@%s 必须挡住新车", c.curTrain, c.curState)
			}
			if !c.blocked && err != nil {
				t.Fatalf("不该挡: %v", err)
			}
		})
	}
}

// 凭据:无写权限的仓必须点名。
func TestGateCreds_DeniesWithoutWrite(t *testing.T) {
	stubGhRoutes(t,
		ghRoute{"api user", "someone"},
		ghRoute{"repos/pigeonbox/core", `{"permissions":{"push":true}}`},
		ghRoute{"repos/pigeonbox/server", `{"permissions":{"push":false}}`},
	)
	err := gateCreds([]string{"core", "server"})
	if err == nil || !strings.Contains(err.Error(), "server") || strings.Contains(err.Error(), "core,") {
		t.Fatalf("必须点名无写权限的 server 而不点 core,实得: %v", err)
	}
	if err := gateCreds([]string{"core"}); err != nil {
		t.Fatalf("有写权限必须放行: %v", err)
	}
}

// 钉版:marker 漂移判红;tag 未发的跳过([0] 代发);已发的必须可消费。
func TestGateLibPins(t *testing.T) {
	var consumableCalled []string
	probes := libPinProbes{
		marker: func(*Env) []markerAheadIssue {
			return []markerAheadIssue{{
				lr:       libRepo{key: "lib.contracts", repo: "contracts", marker: "package.json"},
				declared: "0.24.0", latest: "v0.23.0",
			}}
		},
		tagExists: func(*Env, string, string) bool { return false },
		consumable: func(_ *Env, lr libRepo, v string, _ time.Time) error {
			consumableCalled = append(consumableCalled, lr.key)
			return nil
		},
	}
	err := gateLibPinsWith(nil, map[string]string{"contracts": "v0.24.0"}, probes)
	if err == nil || !strings.Contains(err.Error(), "SET=") {
		t.Fatalf("marker 漂移必须判红并点名出路(SET=),实得: %v", err)
	}

	// 声明 == tag(不漂移)⇒ 不红:checkMarkerAhead 对每个 marker 仓都返回条目,
	// 判定必须看 ahead() 而不是「有没有条目」。
	probes.marker = func(*Env) []markerAheadIssue {
		return []markerAheadIssue{{
			lr:       libRepo{key: "lib.contracts", repo: "contracts", marker: "package.json"},
			declared: "0.23.0", latest: "v0.23.0",
		}}
	}
	probes.tagExists = func(*Env, string, string) bool { return false }
	consumableCalled = nil
	if err := gateLibPinsWith(nil, map[string]string{"core": "v0.41.0"}, probes); err != nil {
		t.Fatalf("不漂移 + tag 未发([0] 代发)不该在本闸拦截: %v", err)
	}
	if len(consumableCalled) != 0 {
		t.Fatalf("tag 未发不应触发可消费探测,实得 %v", consumableCalled)
	}

	probes.marker = func(*Env) []markerAheadIssue { return nil }
	probes.tagExists = func(*Env, string, string) bool { return true }
	probes.consumable = func(_ *Env, lr libRepo, v string, _ time.Time) error {
		return errors.New("proxy 404")
	}
	if err := gateLibPinsWith(nil, map[string]string{"core": "v0.41.0"}, probes); err == nil {
		t.Fatal("已发但不可消费必须判红")
	}

	// unavail(判据读不到)⇒ 按「查不到≠放行」判红(spec §6 不变量 7)。
	probes.marker = func(*Env) []markerAheadIssue {
		return []markerAheadIssue{{lr: libRepo{key: "lib.contracts", repo: "contracts", marker: "package.json"},
			unavail: errors.New("api down")}}
	}
	if err := gateLibPinsWith(nil, map[string]string{}, probes); err == nil || !strings.Contains(err.Error(), "不可用") {
		t.Fatalf("判据不可用必须判红(不许静默放行),实得: %v", err)
	}
}
```

接线守卫（同文件追加）：

```go
// 接线守卫:preflight 必须真接进 cmdRun/子命令/Makefile(spec §9 W3)。
func TestPreflightWiring(t *testing.T) {
	for file, needles := range map[string][]string{
		"run.go":         {"runPreflight(env, &o)"},
		"main.go":        {`case "preflight"`},
		"../../Makefile": {"train-preflight:"},
	} {
		b, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("读 %s 失败: %v", file, err)
		}
		for _, n := range needles {
			if !strings.Contains(string(b), n) {
				t.Errorf("%s 缺少 %q —— 未接线", file, n)
			}
		}
	}
}
```

⚠️ **顺序修正**：`main.go` 的 `status` 与 Makefile 的 `train-status:` 属 Task 5。为避免 Task 4 带红提交，本守卫在 Task 4 只断言 `run.go` + `main.go` 的 `preflight` + Makefile 的 `train-preflight:`；Task 5 再把 `status` 两条 needle 加进去（该步自身含「加 needle ⇒ 先红后绿」的验证）。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test -run 'TestGate|TestPreflight' ./...
```

Expected: 编译失败 `undefined: gateStateVerdict / gateCreds / gateLibPinsWith / libPinProbes`。

- [ ] **Step 3: 实现 `preflight.go`**

```go
// preflight.go —— 发车前五道闸(spec 2026-11-13 §3;相位 [-1])。
//
// 全程**只读**:不建分支/不推 tag/不写 train.yaml。任何一道红 ⇒ 调用方
// (cmdRun)开哨兵 + die,零写操作。失败姿态=收集全部闸的失败一起报
// (一次看清全部问题,而不是修一个再撞一个)。
//
// 干跑语义边界:--dry-run 不走 preflight(预览要快,spec §4.3 不碰 #347 的
// 执行模式分派);standalone `trainctl preflight` 只报退出码,不自动开哨兵
// (人工预演每跑一次就开一条 issue 太吵;哨兵只由 run 路径开)。
package main

import (
	"fmt"
	"strings"
	"time"
)

// runPreflight 依次跑五道闸;全部通过返回 nil。
func runPreflight(env *Env, o *bumpOpts) error {
	type gate struct {
		name string
		fn   func() error
	}
	gates := []gate{
		{"凭据", func() error { return gateCreds(preflightRepos()) }},
		{"状态", func() error { return gateState(env, o.train) }},
		{"CI 基线", func() error { return gateCIBaseline() }},
		{"钉版", func() error { return gateLibPins(env, o.libVersions) }},
		{"检出", func() error { return gateCheckouts(env) }},
	}
	var failed []string
	for _, g := range gates {
		if err := g.fn(); err != nil {
			fmt.Printf("  ✗ preflight/%s: %v\n", g.name, err)
			failed = append(failed, g.name+": "+firstLine(err.Error()))
		} else {
			fmt.Printf("  ✓ preflight/%s\n", g.name)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("%d/%d 道闸未过(零写操作,修完重跑;run 路径已开哨兵):\n  - %s",
			len(failed), len(gates), strings.Join(failed, "\n  - "))
	}
	okf("preflight 五道闸全过")
	return nil
}

// preflightRepos = bumpPRRepos ∪ libRepos() 的仓(去重,保序)。
func preflightRepos() []string {
	seen := map[string]bool{}
	var out []string
	add := func(r string) {
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	for _, r := range bumpPRRepos {
		add(r)
	}
	for _, lr := range libRepos() {
		add(lr.repo)
	}
	return out
}

// gateCreds:P1 凭据。gh 已认证 + 对每个目标仓有写权限(update-branch/推 tag/
// 建 PR 都靠它;权限不足会在写操作中途才炸 ⇒ 提前到发车时验)。
func gateCreds(repos []string) error {
	if _, err := ghRunner("api", "user", "--jq", ".login"); err != nil {
		return fmt.Errorf("gh 未认证或 token 失效: %v", err)
	}
	var denied []string
	for _, r := range repos {
		out, err := ghRunner("api", "repos/"+ghOrg+"/"+r, "--jq", ".permissions.push")
		if err != nil {
			return fmt.Errorf("探测 %s 权限失败: %w", r, err)
		}
		if strings.TrimSpace(out) != "true" {
			denied = append(denied, r)
		}
	}
	if len(denied) > 0 {
		return fmt.Errorf("凭据对以下仓无写权限: %s", strings.Join(denied, ", "))
	}
	return nil
}

// gateState:P2 状态。旧列车卡非终态 ⇒ 挡新车(bumpDecision 对此是「照常开
// 新车」——它的守门在 bump 里;run 的 preflight 必须自己挡)。
func gateState(env *Env, want string) error {
	curTrain, curState := trainStateOnOrigin(env)
	return gateStateVerdict(curTrain, curState, want)
}

// gateStateVerdict 纯判定(便于表驱动单测)。
func gateStateVerdict(curTrain, curState, want string) error {
	if curTrain == "" || curTrain == want || curState == "shipped" {
		return nil
	}
	return fmt.Errorf("旧列车 %s 卡在 state=%s——先处理它(放弃则人工把 state 改回 shipped;只改 state,勿改版本号)", curTrain, curState)
}

// gateCIBaseline:P3 CI 基线。全部目标仓 @ 当前默认分支头过同一门禁判据
// (红 ⇒ 起步就是坏的,别等到打 tag 才发现;在跑 ⇒ 有界等待)。
func gateCIBaseline() error {
	var reqs []ciReq
	for _, r := range preflightRepos() {
		sha, err := remoteHeadSha(r)
		if err != nil {
			return fmt.Errorf("%s 取默认分支头失败: %w", r, err)
		}
		reqs = append(reqs, ciReq{repo: r, sha: sha})
	}
	return waitAllCIGreen(reqs)
}

// libPinProbes 是 gateLibPins 的可注入探针(离线单测用;真身见 libPinReal)。
type libPinProbes struct {
	marker     func(env *Env) []markerAheadIssue
	tagExists  func(env *Env, repo, tag string) bool
	consumable func(env *Env, lr libRepo, v string, deadline time.Time) error
}

var libPinReal = libPinProbes{
	marker:     checkMarkerAhead,
	tagExists:  func(env *Env, repo, tag string) bool { return env.TagExists(repo, tag) },
	consumable: waitLibConsumable,
}

// gateLibPins:P4 钉版。
//   - marker-ahead(仓内已升版、tag 未发,#347 判据)⇒ 判红并点名两条出路;
//   - 已发布的钉版必须「可消费」(与消费方同源的探测);**尚未发布**的跳过
//     ——那是 [0] 阶段列车代发的对象,不在本闸拦截(否则 --set 新版本永远发不了车)。
func gateLibPins(env *Env, versions map[string]string) error {
	return gateLibPinsWith(env, versions, libPinReal)
}

func gateLibPinsWith(env *Env, versions map[string]string, p libPinProbes) error {
	// ⚠️ checkMarkerAhead 对**每个** marker 仓都返回条目(不过滤)——判定必须
	// 逐条看 ahead()/unavail,不能拿「有没有条目」当漂移。
	var bad []string
	for _, i := range p.marker(env) {
		if i.unavail != nil {
			bad = append(bad, "判据不可用(读不到 ≠ 不漂移): "+firstLine(i.unavail.Error()))
			continue
		}
		if i.ahead() {
			bad = append(bad, i.msg())
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("库线仓内已升版但 tag 未发(用 SET=<lib>=<版本> 发车,或先在该仓发 tag):\n    %s",
			strings.Join(bad, "\n    "))
	}
	deadline := time.Now().Add(5 * time.Minute) // 四库共用一个窗口(与 ensureLibLinePublished 同款)
	var failed []string
	for _, lr := range libRepos() {
		v := versions[lr.key]
		if v == "" {
			continue
		}
		if !p.tagExists(env, lr.repo, "v"+strings.TrimPrefix(v, "v")) {
			continue // 尚未发布 ⇒ [0] 由列车代发
		}
		if err := p.consumable(env, lr, v, deadline); err != nil {
			failed = append(failed, err.Error())
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("已发布钉版不可消费: %s", strings.Join(failed, "; "))
	}
	return nil
}

// gateCheckouts:P5 检出。
//   - hub 工作树必须干净(本地推进路径的 ff 恢复/提交都会被未提交改动挡死
//     ——AGENTS.md L865 的「先 commit+rebase」提前到发车时拦);
//   - 各已检出仓 fetch 齐(判据读远端;不 fetch ⇒ 拿陈旧 origin 判「不落后」)。
//     未检出的仓不在此拦:bump 的仓级 preflight(bump.go)会点名。
func gateCheckouts(env *Env) error {
	var failed []string
	out, err := Git(env.Root, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("hub git status 失败: %w", err)
	}
	if strings.TrimSpace(out) != "" {
		failed = append(failed, "hub 工作树不干净(先 commit / git stash;本地改动挡路时 git 会拒绝推进):\n      "+
			strings.ReplaceAll(strings.TrimSpace(out), "\n", "\n      "))
	}
	for _, r := range preflightRepos() {
		dir, ok := env.RepoDir(r)
		if !ok {
			continue
		}
		if _, err := Git(dir, "fetch", "-q", "origin", defBranch(r)); err != nil {
			failed = append(failed, fmt.Sprintf("%s fetch 失败: %v", r, err))
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("%s", strings.Join(failed, "\n  "))
	}
	return nil
}

// cmdPreflight 独立子命令(make train-preflight):只读预演,退出码即结论。
func cmdPreflight(env *Env, args []string) {
	o := parseBumpArgs(args)
	if o.train == "" {
		die("用法: trainctl preflight TRAIN=x.y.z")
	}
	fmt.Printf("══ preflight → %s(五道闸,全程只读)\n", o.train)
	if err := runPreflight(env, &o); err != nil {
		die("%v", err)
	}
}
```

- [ ] **Step 4: `cmdRun` 挂进 preflight**（`run.go`，当前 L48-75 重构为早返回形态；**只动控制流，不碰 switch 两个 case 的内容**）

```go
	curTrain, curState := trainStateOnOrigin(env)
	skipBump, finished, why := bumpDecision(curTrain, curState, o.train)

	if finished {
		fmt.Printf("✓ 列车 %s %s——无事可做。\n", o.train, why)
		return
	}
	// [-1] preflight:五道闸全过才碰任何东西(spec §3;全程只读)。
	// 失败 ⇒ 哨兵 + die(零写操作)。--dry-run 不走此路(runDry 在前面已返回)。
	if err := runPreflight(env, &o); err != nil {
		reportStalledIssue(o.train, []string{"preflight:" + firstLine(err.Error())})
		die("preflight 未过(零写操作,修完重跑/等 sweep 接力):%v", err)
	}
	switch {
	case skipBump:
		okf("列车 %s %s ⇒ 跳过 bump,直接推进", o.train, why)
		// ……以下 case skipBump / default 的内容与现状逐字一致(见 git diff,只搬不改)……
```

即：原 `switch { case finished: …return; case skipBump: …; default: … }` 拆成「finished 早返回 + preflight + 原 switch 删掉 finished 分支」。

- [ ] **Step 5: `main.go` 子命令 + 帮助**

`switch` 里 `case "verify":` 之后加：

```go
	case "preflight":
		cmdPreflight(env, args)
```

`helpText` 的 `trainctl advance` 行之后加：

```
  trainctl preflight TRAIN=x.y.z        发车前五道闸只读预演(凭据/状态/CI基线/钉版/检出)
```

- [ ] **Step 6: `Makefile` 加目标**（`train-verify:` 之后）

```make
train-preflight: trainctl ## 发车前五道闸只读预演(不写任何东西;红=发不了车)
	@test -n "$(TRAIN)" || { echo "用法: make train-preflight TRAIN=<列车号>"; exit 2; }
	./bin/trainctl preflight TRAIN=$(TRAIN)
```

同时把 `.PHONY` 行补上 `train-preflight`。

- [ ] **Step 7: 跑测试**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test ./... 2>&1 | tail -5
```

Expected: `ok`（本 task 的 needle 表只含 preflight 三条，status 三条由 Task 5 Step 5 扩入）。

- [ ] **Step 8: 负对照 ×2**

1. 删 `gateStateVerdict` 的非终态拦截（`curState == "shipped"` 条件去掉其它分支）⇒ `TestGateStateVerdict` 的两个 blocked 用例转红；还原。
2. `cmdRun` 里临时去掉 `runPreflight` 调用 ⇒ `TestPreflightWiring` 转红点名 `run.go`；还原。

- [ ] **Step 9: 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add release/trainctl/preflight.go release/trainctl/preflight_test.go release/trainctl/run.go release/trainctl/main.go Makefile
git commit -m "feat(trainctl): 发车 preflight 五道闸(只读,全过才写)+ trainctl preflight

P1 凭据(gh 认证+全目标仓写权限)/P2 状态(旧列车卡非终态挡新车——
bumpDecision 对此是「照常开新车」,run 必须自己挡)/P3 CI 基线(全仓
@默认分支头过同一判据)/P4 钉版(marker-ahead 判红+已发钉版可消费,
未发布的跳过留给 [0] 代发)/P5 检出(hub 工作树干净+各仓 fetch 齙)。
cmdRun 在 finished 早返回后、switch 前跑闸,红⇒哨兵+die 零写操作;
--dry-run 不走此路(#347 契约)。失败收集全部闸一起报。
负对照:gateState 拦截删除⇒表驱动红;去 runPreflight 调用⇒接线守卫红。"
```

---

### Task 5: `trainctl status` + CI job summary + `make train-status`

**Files:**
- Create: `release/trainctl/status.go`
- Modify: `release/trainctl/main.go`（`case "status"` + 帮助）
- Modify: `Makefile`（`train-status` 目标 + `.PHONY`）
- Modify: `.github/workflows/train-orchestrator.yml`（收尾 `if: always()` 步）
- Test: `release/trainctl/status_test.go`
- Modify: `release/trainctl/preflight_test.go`（`TestPreflightWiring` 补 status needle——Step 5）

**Interfaces:**
- Consumes: `trainMapOnOrigin`、`listOpenBumpPRs`、`checksLatest`、`checkReleased`、`imagesReady`、`ghRunner`、`splitLines`、`orNone`
- Produces: `type statusData`、`func collectStatus(env *Env) statusData`、`func renderStatus(d statusData, markdown bool) string`、`func deriveConclusion(d statusData) string`、`func cmdStatus(env *Env, args []string)`

- [ ] **Step 1: 写失败测试**（`status_test.go` 全文）

```go
// status_test.go —— 进度面板的渲染与结论推导(spec 2026-11-13 §5/G5)。
//
// 采集(collectStatus)是网络/ git 胶水,单测只覆盖纯函数:renderStatus /
// deriveConclusion / checksSummary 的计数逻辑。
// 负对照:把 deriveConclusion 的 draft 分支删掉 ⇒ TestDeriveConclusion 转红。
package main

import "strings"

func TestDeriveConclusion(t *testing.T) {
	cases := []struct {
		name string
		d    statusData
		want string
	}{
		{"已发货", statusData{state: "shipped"}, "已发货"},
		{"等镜像", statusData{state: "tagged"}, "等镜像"},
		{"等产物", statusData{state: "tagged", imagesOK: true, missing: []string{"a", "b"}}, "等产物(2 项)"},
		{"终验中", statusData{state: "tagged", imagesOK: true}, "产物齐,等终验/收尾"},
		{"等 PR", statusData{state: "draft", openCount: 3}, "等 3 个 bump PR 合并"},
		{"等打 tag", statusData{state: "draft"}, "bump 已合,等打 tag"},
		{"未知态", statusData{state: "shipping-x"}, "state=shipping-x"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := deriveConclusion(c.d); got != c.want {
				t.Fatalf("deriveConclusion = %q, want %q", got, c.want)
			}
		})
	}
}

func TestRenderStatus_MarkdownAndPlain(t *testing.T) {
	d := statusData{
		train: "5.9.0", state: "draft", openCount: 2,
		prs:      []statusPR{{name: "frontend#112", checks: "4/4 绿", green: true}},
		imagesOK: false,
		stalled:  []string{"#240 停滞"},
		conclusion: "等 2 个 bump PR 合并",
	}
	md := renderStatus(d, true)
	for _, want := range []string{"## 🚂", "5.9.0", "state=draft", "- **卡点:** 等 2 个 bump PR 合并", "✅ frontend#112", "#240 停滞"} {
		if !strings.Contains(md, want) {
			t.Errorf("markdown 输出缺 %q:\n%s", want, md)
		}
	}
	plain := renderStatus(d, false)
	if strings.Contains(plain, "## ") {
		t.Error("plain 输出不应有 markdown 标题语法")
	}
	if !strings.Contains(plain, "══ 列车 5.9.0") {
		t.Errorf("plain 输出缺标题行:\n%s", plain)
	}
}

// checksSummary:全绿/有未绿/读失败三态(计数逻辑;checksLatest 走 ghRunner 缝)。
func TestChecksSummary(t *testing.T) {
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		return `{"statusCheckRollup":[
			{"name":"lint","workflowName":"ci","conclusion":"success","startedAt":"a","completedAt":"a"},
			{"name":"test","workflowName":"ci","conclusion":"failure","startedAt":"b","completedAt":"b"}]}`, nil
	}
	t.Cleanup(func() { ghRunner = prev })
	s, green := checksSummary("frontend", "7")
	if green || !strings.Contains(s, "1/2") {
		t.Fatalf("有失败必须报未绿,实得 green=%v s=%q", green, s)
	}

	ghRunner = func(args ...string) (string, error) {
		return `{"statusCheckRollup":[{"name":"lint","workflowName":"ci","conclusion":"success","startedAt":"a","completedAt":"a"}]}`, nil
	}
	t.Cleanup(func() { ghRunner = prev })
	if s, green := checksSummary("frontend", "7"); !green {
		t.Fatalf("全绿必须 green,实得 %q", s)
	}

	ghRunner = func(args ...string) (string, error) { return "", errBoom() }
	t.Cleanup(func() { ghRunner = prev })
	if s, green := checksSummary("frontend", "7"); green || !strings.Contains(s, "失败") {
		t.Fatalf("读不到必须报失败且不装绿,实得 green=%v s=%q", green, s)
	}
}
```

（`errBoom()` 写成 `errors.New("boom")`，import 补 `"errors"`。）

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test -run 'TestDerive|TestRender|TestChecksSummary' ./...
```

Expected: 编译失败 `undefined: statusData / renderStatus / deriveConclusion / checksSummary`。

- [ ] **Step 3: 实现 `status.go`**

```go
// status.go —— 进度一屏看(spec 2026-11-13 §5/G5):当前车次/相位/卡点/
// bump PR checks/产物缺口/哨兵 issue。全程只读(采集=远端真相;不写任何东西)。
//
// 两个出口:
//   - `trainctl status`        本地一屏(make train-status)
//   - `trainctl status --markdown`  CI 收尾步写 $GITHUB_STEP_SUMMARY
package main

import (
	"fmt"
	"strings"
)

type statusPR struct {
	name   string
	checks string
	green  bool
}

type statusData struct {
	train, state string
	prs          []statusPR
	openCount    int
	missing      []string
	imagesOK     bool
	stalled      []string
	conclusion   string
}

// collectStatus 只读采集。TrainFile 用 map 构造只读视图
// (checkReleased/imagesReady 只读 tf.Get——已核对 advance.go L351/L549)。
func collectStatus(env *Env) statusData {
	m := trainMapOnOrigin(env)
	tf := &TrainFile{m: m}
	d := statusData{train: m["train"], state: m["state"]}
	if d.state == "" {
		d.state = "(无)"
	}
	if d.train != "" {
		open := listOpenBumpPRs(env, d.train)
		d.openCount = len(open)
		for _, item := range open {
			repo, num, ok := strings.Cut(item, "#")
			if !ok {
				continue
			}
			num = strings.Fields(num)[0]
			checks, green := checksSummary(repo, num)
			d.prs = append(d.prs, statusPR{name: repo + "#" + num, checks: checks, green: green})
		}
		for _, mi := range checkReleased(env, tf) {
			d.missing = append(d.missing, mi.desc)
		}
		d.imagesOK = imagesReady(env, tf)
	}
	d.stalled = listStalledIssues()
	d.conclusion = deriveConclusion(d)
	return d
}

// checksSummary 单个 PR 的 checks 概览(口径与 checksAllGreenLatest 同族:
// 按检查名取最新;空=该仓无 checks 视为就绪)。
func checksSummary(repo, num string) (string, bool) {
	states, ok := checksLatest(repo, num)
	if !ok {
		return "checks 读取失败", false
	}
	if len(states) == 0 {
		return "无 checks(纯脚本仓)", true
	}
	bad := 0
	for _, s := range states {
		switch s.conclusion {
		case "SUCCESS", "SKIPPED", "NEUTRAL":
		default:
			bad++
		}
	}
	if bad > 0 {
		return fmt.Sprintf("%d/%d 未绿", bad, len(states)), false
	}
	return fmt.Sprintf("%d/%d 绿", len(states), len(states)), true
}

// listStalledIssues 开着的哨兵 issue(train-stalled 标签;无则空)。
func listStalledIssues() []string {
	out, err := ghRunner("issue", "list", "-R", hubRepo, "--state", "open",
		"--label", "train-stalled", "--json", "number,title",
		"--jq", `.[] | "#\(.number) \(.title)"`)
	if err != nil {
		return []string{"(哨兵读取失败: " + firstLine(err.Error()) + ")"}
	}
	var res []string
	for _, ln := range splitLines(out) {
		if s := strings.TrimSpace(ln); s != "" {
			res = append(res, s)
		}
	}
	return res
}

// deriveConclusion 一屏最重要的那行:现在卡在哪。
func deriveConclusion(d statusData) string {
	switch d.state {
	case "shipped":
		return "已发货"
	case "tagged", "shipping":
		if !d.imagesOK {
			return "等镜像(server/frontend/p2p)"
		}
		if len(d.missing) > 0 {
			return fmt.Sprintf("等产物(%d 项)", len(d.missing))
		}
		return "产物齐,等终验/收尾"
	case "draft", "(无)":
		if d.openCount > 0 {
			return fmt.Sprintf("等 %d 个 bump PR 合并", d.openCount)
		}
		return "bump 已合,等打 tag"
	default:
		return "state=" + d.state
	}
}

// renderStatus 渲染纯文本/markdown(同一份数据两个出口)。
func renderStatus(d statusData, markdown bool) string {
	var b strings.Builder
	title := fmt.Sprintf("列车 %s · state=%s", orNone(d.train), d.state)
	if markdown {
		fmt.Fprintf(&b, "## 🚂 %s\n\n", title)
	} else {
		fmt.Fprintf(&b, "══ %s\n", title)
	}
	line := func(format string, a ...any) {
		if markdown {
			fmt.Fprintf(&b, "- "+format+"\n", a...)
		} else {
			fmt.Fprintf(&b, "  "+format+"\n", a...)
		}
	}
	line("**卡点:** %s", d.conclusion)
	for _, p := range d.prs {
		mark := "⏳"
		if p.green {
			mark = "✅"
		}
		line("%s %s — %s", mark, p.name, p.checks)
	}
	if len(d.missing) > 0 {
		line("**产物缺口 (%d):** %s", len(d.missing), strings.Join(d.missing, " | "))
	}
	img := "未齐"
	if d.imagesOK {
		img = "齐"
	}
	line("**镜像:** %s", img)
	for _, s := range d.stalled {
		line("**哨兵:** %s", s)
	}
	return b.String()
}

// cmdStatus 入口:--markdown 走 GitHub job summary 形态。
func cmdStatus(env *Env, args []string) {
	md := false
	for _, a := range args {
		if a == "--markdown" {
			md = true
		}
	}
	fmt.Print(renderStatus(collectStatus(env), md))
}
```

- [ ] **Step 4: `main.go` + `Makefile` + orchestrator**

main.go switch 加：

```go
	case "status":
		cmdStatus(env, args)
```

helpText 加：

```
  trainctl status [--markdown]           列车进度一屏(远端真相,只读;--markdown 供 CI summary)
```

Makefile（`train-preflight` 之后，`.PHONY` 同步补 `train-status`）：

```make
train-status: trainctl ## 列车进度一屏(相位/卡点/PR checks/产物缺口/哨兵)
	./bin/trainctl status
```

`.github/workflows/train-orchestrator.yml` —— 在「执行编排 phase」步骤（`esac` 所在，约 L168）**之后**追加：

```yaml
      - name: 列车进度摘要
        if: always()
        env:
          GH_TOKEN: ${{ env.BOT }}
        run: ./bin/trainctl status --markdown >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
```

（`BOT` 是 workflow 级 env（L54），与「执行编排 phase」步的 `GH_TOKEN: ${{ env.BOT }}`（L133）同源；`|| true` 保证摘要步失败不掩盖编排步的真实结论。）

- [ ] **Step 5: `TestPreflightWiring` 补 needle**（Task 4 的守卫升级）

`preflight_test.go` 的 needle 表改为（Task 4 版本只含 preflight 两条；status 实现完再扩成下表）：

```go
	"run.go":         {"runPreflight(env, &o)"},
	"main.go":        {`case "preflight"`, `case "status"`},
	"../../Makefile": {"train-preflight:", "train-status:"},
	"../../.github/workflows/train-orchestrator.yml": {"status --markdown", "if: always()"},
```

本步跑一次应绿（status 此时已实现）；TDD 顺序也可：先加 needle 看红，再实现。

- [ ] **Step 6: 跑测试**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go test ./... 2>&1 | tail -5
```

Expected: `ok`。

- [ ] **Step 7: 负对照**——`deriveConclusion` 临时删 `case "draft", "(无)":` 分支 ⇒ `TestDeriveConclusion` 的「等 PR/等打 tag」两条转红；还原。

- [ ] **Step 8: 提交**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add release/trainctl/status.go release/trainctl/status_test.go release/trainctl/main.go release/trainctl/preflight_test.go Makefile .github/workflows/train-orchestrator.yml
git commit -m "feat(trainctl): trainctl status 进度面板 + CI job summary + make train-status

一屏输出:车次/state/卡点结论/各 bump PR checks/产物缺口/镜像在位/
哨兵 issue;--markdown 供 orchestrator 收尾步(if: always())写
\$GITHUB_STEP_SUMMARY —— gh run 页面直接看终态,不翻日志。
TrainFile 用远端 map 构造只读视图(checkReleased/imagesReady 只用
tf.Get,已核对)。采集失败响亮标注(读不到≠装绿)。
负对照:删 draft 结论分支 ⇒ 表驱动转红后还原;接线守卫扩到
main/Makefile/orchestrator。"
```

---

### Task 6: 全量门禁 + 设计稿状态回写 + 推送开 PR

**Files:**
- Modify: `docs/specs/2026-11-13-release-train-v4-design.md`（状态行）

- [ ] **Step 1: trainctl 全量测试（CI 同款）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4/release/trainctl && GOWORK=off go vet ./... && GOWORK=off go test ./... -count=1
```

Expected: `ok`（33+ 既有测试 + 新增约 25 条全绿）。

- [ ] **Step 2: hub 门禁（与 CI 同款）**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4 && make lint 2>&1 | tail -10
bash scripts/check-docs-consistency.sh
make -n train-preflight TRAIN=5.9.0 && make -n train-status
```

Expected: `lint OK`、`✓ 文档对账通过`、make 干测打印出目标命令且不报错。

- [ ] **Step 3: 设计稿状态回写**

`docs/specs/2026-11-13-release-train-v4-design.md` 头部状态行改为：

```markdown
- 状态：**已实施（W1~W4 落地，2026-11-13）；真车验收（§10 清单）待下一趟列车**
```

- [ ] **Step 4: 提交 + 推送**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
git add docs/specs/2026-11-13-release-train-v4-design.md
git commit -m "docs(spec): v4 设计稿状态改「已实施,待真车验收」"
bash scripts/git-fetch-safe.sh push -u origin feat/train-v4
```

（`git-fetch-safe.sh` 是 AGENTS.md L158 指定的抗 SSH 超时推通道；若该脚本用法是 `git-fetch-safe.sh <args...>` 直接透传则如上；若只包 fetch，改用 `git push -u origin feat/train-v4`，超时再换 https 一次性 insteadOf 通道。）

- [ ] **Step 5: 开 PR**

```bash
cd /Users/zhangyi/my_project/filecodebox-project/hub-train-v4
gh pr create -R pigeonbox/pigeonbox --base main --head feat/train-v4 \
  --title "feat(trainctl): 发布列车 v4 —— preflight 五道闸 + 打 tag 前 CI 门禁 + BEHIND 自愈 + 进度面板" \
  --body-file - <<'EOF'
实现 docs/specs/2026-11-13-release-train-v4-design.md（设计稿先行 PR #350，合并后本 PR rebase 到 main）。

## 内容（W1~W4）

| 工作流 | 落点 |
|---|---|
| W1 CI 门禁 | `cigate.go` 单一判据 `assertRepoCIGreen`；三落点：`ensureLibTag` / `runTag` 并行预检 / `pushTag` 精确 sha 复核 |
| W2 BEHIND 自愈 | `tryMergeReady` 读 `mergeStateStatus`：BEHIND ⇒ `update-branch`（3 次上限⇒哨兵）、DIRTY 点名、其余走原路径 |
| W3 preflight | `preflight.go` 五道闸（凭据/状态/CI 基线/钉版/检出），`cmdRun` 前置，红⇒哨兵+零写操作；`trainctl preflight` 子命令 |
| W4 进度可见 | `trainctl status [--markdown]` + orchestrator `if: always()` job summary + `make train-status` |

## 不变量（spec §6）

bump 写回链路一行未改；状态机语义/train.yaml schema 未动；`run` 缺省真执行（#347 契约）未动；`checksAllGreenLatest` 口径未动；门禁判据单一来源。

## 验证

- `GOWORK=off go test ./...` 全绿（33 既有 + 新增）；`make lint` / 文档对账通过
- 负对照逐条实测转红后还原（提交体记录）：failure⇒wait、删 BEHIND 分支、删 gateState 拦截、去 runPreflight 接线、删 draft 结论分支
- 真机负对照：历史红 sha `PB_CIGATE_RED_SHA` 判红（零破坏只读）
- **真车验收（G1 零干预）留给下一趟列车**，清单见 spec §10

⚠️ 依赖 #350（设计稿）先合并。
EOF
```

- [ ] **Step 6: 汇报**

向用户汇报：PR 链接、四工作流落地情况、负对照清单、剩余验收项（真车 G1）。

---

## Self-Review（已执行）

1. **Spec coverage**：§2 G1（真车清单=Task 6 Step 5 明示留给下一趟）/G2（T1+T2）/G3（T3）/G4（不碰，#347）/G5（T5）/G6（Global Constraints 逐条 + 各负对照）；§3 架构与 §4 闸门细节（判据三落点、并行等待、哨兵、DIRTY/3 次上限、P1~P5）；§5 status/job summary/deprecated 不另做（帮助文本行已含 train-bump/train-advance 说明——**补**：Task 4 Step 5 的 helpText 追加行同时给旧接口标「兼容/崩溃接力用」，已并入该步）；§7 测试矩阵逐条映射到各 task 负对照；§9 W1~W4 = Task 1~5，W0=不重复（Global Constraints）。G1 真车项无法在本计划内闭环（需真实列车），如实留验收清单——非缺口，是 spec §10 既定安排。
2. **Placeholder scan**：无 TBD/TODO/实现提示残留——`markerAheadIssue` 字段（`lr/declared/latest/unavail`）、`waitLibConsumable` 签名、`checkMarkerAhead` 不过滤（须按 `ahead()` 判）均已按源码写成可直接编译的代码。
3. **Type consistency**：`ciReq{repo,sha}`/`assertRepoCIGreen(repo,sha)`/`waitAllCIGreen([]ciReq)`/`tryMergeReady([]string) []string`/`prMergeState string`/`runPreflight(env,*bumpOpts) error`/`gateLibPinsWith(...libPinProbes)`/`statusData` 字段在 T1→T2→T3→T4→T5 间逐一核对一致；`ghRunner` 缝贯穿；`healAttempts` 定义（T3）先于 `runPreflight` 使用（T4 无交叉）。
