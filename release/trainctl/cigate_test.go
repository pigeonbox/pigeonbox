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
