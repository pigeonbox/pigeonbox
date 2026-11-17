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

// stubCIGate 把门禁缝换成直通(本地 fixture 测试的隔离)。
func stubCIGate(t *testing.T) {
	t.Helper()
	prev := cigGate
	cigGate = func(string, string) error { return nil }
	t.Cleanup(func() { cigGate = prev })
}

// 钉住缝的默认值:默认必须是真判据——有人改成直通 ⇒ 门禁形同虚设。
func TestCIGateSeamDefault(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure"}]`},
	)
	if err := cigGate("core", "deadbeef"); err == nil {
		t.Fatal("cigGate 默认值必须是真判据(改成直通=门禁形同虚设)")
	}
}

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

// ── 编排器自身的 run 不得成为「CI 基线」(2026-11-17 实录:5.9.0 首跑自锁) ──
//
// 事故形态:`gh workflow run` 派发的 run,其 head_sha 就是默认分支 HEAD
// ⇒ 列车给 hub 默认分支头跑基线闸时,查到的 run 里包含列车自己这一趟
// ⇒ 闸等「自己跑完」⇒ 自己等不到 ⇒ 10 分钟超时自杀(连 bump 都没开始)。

func TestCIGate_SelfRunDoesNotBlock(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[
			{"s":"in_progress","c":"","p":".github/workflows/train-orchestrator.yml","id":4242},
			{"s":"completed","c":"success","p":".github/workflows/ci.yml","id":1000}]`},
	)
	if err := assertRepoCIGreen("pigeonbox", "abc123"); err != nil {
		t.Fatalf("编排器自己的 run 不该挡住 CI 基线(2026-11-17 自锁事故),实得: %v", err)
	}
}

// 只有编排器自己的 run ⇒ 该 sha 没有任何内容 CI 证据 ⇒ 不得静默放行
// (「查不到≠放行」),但必须点名原因,不能报成「run 尚未创建」。
func TestCIGate_OnlySelfRunNoEvidence(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"in_progress","c":"","p":".github/workflows/train-orchestrator.yml","id":4242}]`},
	)
	err := assertRepoCIGreen("pigeonbox", "abc123")
	if err == nil {
		t.Fatal("只有编排器自己的 run 时不得放行(没有内容 CI 证据)")
	}
	if !strings.Contains(err.Error(), "编排器") {
		t.Fatalf("必须点名「只有编排器自己的 run」,实得: %v", err)
	}
}

// 负对照:别的 workflow 在跑 ⇒ 照常等(豁免不得扩大成「一律放行」)。
func TestCIGate_OtherInProgressStillBlocks(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"in_progress","c":"","p":".github/workflows/ci.yml","id":1000}]`},
	)
	if err := assertRepoCIGreen("pigeonbox", "abc123"); err == nil {
		t.Fatal("内容 CI 在跑必须继续等(自锁豁免只针对编排器自己)")
	}
}

// 第二道保险:workflow path 取不到时,靠 run id 认出自己(GITHUB_RUN_ID)。
func TestCIGate_CurrentRunIDExcluded(t *testing.T) {
	t.Setenv("GITHUB_RUN_ID", "424242")
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[
			{"s":"in_progress","c":"","p":"","id":424242},
			{"s":"completed","c":"success","p":".github/workflows/ci.yml","id":1000}]`},
	)
	if err := assertRepoCIGreen("pigeonbox", "abc123"); err != nil {
		t.Fatalf("当前这次 run 必须被认出并豁免,实得: %v", err)
	}
}

// newTagGateReqs:已存在的 tag 跳过;新建的解析头;shaFn 出错即整批失败。
func TestNewTagGateReqs(t *testing.T) {
	targets := []tagTarget{
		{repo: "frontend", tag: "v5.9.0"},
		{repo: "server", tag: "v5.9.0"},
		{repo: "fnos", tag: "fnos-v5.9.0"},
	}
	exists := func(r, tg string) bool { return r == "server" } // server 已打过
	says := map[string]string{"frontend": "aaa", "fnos": "ccc"}
	shaFn := func(r string) (string, error) {
		s, ok := says[r]
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
	if _, err := newTagGateReqs([]tagTarget{{repo: "nope", tag: "v1"}}, func(_, _ string) bool { return false },
		func(string) (string, error) { return "", fmt.Errorf("boom") }); err == nil {
		t.Fatal("shaFn 失败必须整批报错(不许静默漏掉一个仓)")
	}
}

// 接线守卫:三个落点必须调用同一判据(spec §6 不变量 6;抽了函数不接线=形同虚设)。
func TestCIGateWiring(t *testing.T) {
	for file, needles := range map[string][]string{
		"libline.go": {"cigGate("},
		"tag.go":     {"cigGate(", "waitAllCIGreen(", "newTagGateReqs("},
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

// 真机负对照(spec §7):历史红 sha 必须被判红。零破坏——只读查询既有失败 run。
// 手动步骤见计划 Task 2 Step 8。
func TestCIGate_RealRedShaE2E(t *testing.T) {
	sha := os.Getenv("PB_CIGATE_RED_SHA")
	if sha == "" {
		t.Skip("PB_CIGATE_RED_SHA 未设置(真机负对照,手动触发)")
	}
	if err := assertRepoCIGreen("core", sha); err == nil {
		t.Fatalf("历史红 sha %s 必须被判红(真机负对照)", sha[:12])
	}
}

// ── 同工作流的后续运行覆盖先前的失败(2026-11-17 实录:desktop@8de20aa9) ──

// TestCIGate_LaterSameWorkflowSupersedesEarlierFailure 同一工作流的后一次运行
// 成功 ⇒ 覆盖先前的失败。
//
// 现场:desktop@8de20aa9 上「Release Desktop」先一次失败(ensure-release 无权
// create release)、再派发一次成功 ⇒ 旧口径把 6.3.0 发车卡在起步。
//
// 负对照:去掉 latestPerWorkflow ⇒ 本用例转红(闸门又会把发车卡住)。
func TestCIGate_LaterSameWorkflowSupersedesEarlierFailure(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure","p":".github/workflows/release.yml","id":100},{"s":"completed","c":"success","p":".github/workflows/release.yml","id":101}]`},
	)
	if err := assertRepoCIGreen("desktop", "deadbeef"); err != nil {
		t.Fatalf("同工作流后续成功应覆盖先前失败,实得: %v", err)
	}
}

// TestCIGate_DifferentWorkflowFailureStillRed 不同工作流之间**不互相覆盖**:
// 内容 CI 红不得被别的绿工作流掩盖(那会把真红洗掉)。
func TestCIGate_DifferentWorkflowFailureStillRed(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure","p":".github/workflows/ci.yml","id":100},{"s":"completed","c":"success","p":".github/workflows/release.yml","id":101}]`},
	)
	err := assertRepoCIGreen("core", "deadbeef")
	if err == nil || !strings.Contains(err.Error(), "CI 红") {
		t.Fatalf("不同工作流里的失败必须仍然判红,实得: %v", err)
	}
}

// TestCIGate_LaterSameWorkflowInProgressWaits 同工作流的后一次还在跑 ⇒ 等它,
// 不按先前的失败立即判红(最新证据优先)。
func TestCIGate_LaterSameWorkflowInProgressWaits(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure","p":".github/workflows/release.yml","id":100},{"s":"in_progress","c":"","p":".github/workflows/release.yml","id":101}]`},
	)
	err := assertRepoCIGreen("desktop", "deadbeef")
	if err == nil {
		t.Fatal("最新一次还在跑时应等待(而不是按先前的失败判红),实得: 放行")
	}
	if strings.Contains(err.Error(), "CI 红") {
		t.Fatalf("最新一次在跑不得判红(应等待),实得: %v", err)
	}
}

// TestLatestPerWorkflow 单测:同路径只留 id 最大(=最晚)的那条;不同路径各留一条。
func TestLatestPerWorkflow(t *testing.T) {
	in := []ciRun{
		{S: "completed", C: "failure", P: "a.yml", ID: 10},
		{S: "completed", C: "success", P: "b.yml", ID: 11},
		{S: "completed", C: "success", P: "a.yml", ID: 12},
	}
	got := latestPerWorkflow(in)
	if len(got) != 2 {
		t.Fatalf("应剩 2 条(两个工作流各一条),实得 %d: %+v", len(got), got)
	}
	byPath := map[string]ciRun{}
	for _, r := range got {
		byPath[r.P] = r
	}
	if byPath["a.yml"].ID != 12 || byPath["a.yml"].C != "success" {
		t.Fatalf("a.yml 应取最新(id=12),实得 %+v", byPath["a.yml"])
	}
	if byPath["b.yml"].ID != 11 {
		t.Fatalf("b.yml 应保留 id=11,实得 %+v", byPath["b.yml"])
	}
}

// TestCIGate_RerunOfSameRunSupersedes GitHub 的「重跑失败作业」**沿用原 run id**
// (只加 run_attempt)⇒ 新旧判据必须看 updated_at,不能只看 run id。
//
// 现场:这是最常见的修复动作(重跑),只看 id 会漏掉它 ⇒ 闸门仍红。
func TestCIGate_RerunOfSameRunSupersedes(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"failure","p":".github/workflows/ci.yml","id":100,"u":"2026-11-17T17:20:00Z"},{"s":"completed","c":"success","p":".github/workflows/ci.yml","id":100,"u":"2026-11-17T18:30:00Z"}]`},
	)
	if err := assertRepoCIGreen("core", "deadbeef"); err != nil {
		t.Fatalf("同一 run id 的重跑成功后应覆盖先前失败,实得: %v", err)
	}
}

// TestCIGate_LatestUpdatedAtFailureStillRed 反向:同一工作流里**最新**的那条
// 仍是失败 ⇒ 照红(不能被更早的成功掩盖)。
func TestCIGate_LatestUpdatedAtFailureStillRed(t *testing.T) {
	fastGate(t)
	stubGhRoutes(t,
		ghRoute{"actions/workflows", "2"},
		ghRoute{"actions/runs?branch=", "9"},
		ghRoute{"actions/runs?head_sha=", `[{"s":"completed","c":"success","p":".github/workflows/ci.yml","id":100,"u":"2026-11-17T17:20:00Z"},{"s":"completed","c":"failure","p":".github/workflows/ci.yml","id":100,"u":"2026-11-17T18:30:00Z"}]`},
	)
	err := assertRepoCIGreen("core", "deadbeef")
	if err == nil || !strings.Contains(err.Error(), "CI 红") {
		t.Fatalf("最新一条仍是失败时必须判红,实得: %v", err)
	}
}
