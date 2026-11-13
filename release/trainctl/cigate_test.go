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
