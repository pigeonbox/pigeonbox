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
		blocked                        bool
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

// 凭据:无写权限的仓必须点名。桩返回值模拟 gh --jq 的**裸输出**(true/false)。
func TestGateCreds_DeniesWithoutWrite(t *testing.T) {
	stubGhRoutes(t,
		ghRoute{"api user", "someone"},
		ghRoute{"repos/pigeonbox/core", "true"},
		ghRoute{"repos/pigeonbox/server", "false"},
	)
	err := gateCreds([]string{"core", "server"})
	if err == nil || !strings.Contains(err.Error(), "server") {
		t.Fatalf("必须点名无写权限的 server,实得: %v", err)
	}
	if strings.Contains(err.Error(), "core") {
		t.Fatalf("core 有写权限,不该被点名: %v", err)
	}
	if err := gateCreds([]string{"core"}); err != nil {
		t.Fatalf("有写权限必须放行: %v", err)
	}
}

// 钉版:marker 漂移判红;tag 未发的跳过([0] 代发);已发的必须可消费;
// 判据不可用按「查不到≠放行」判红。
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
	err := gateLibPinsWith(nil, map[string]string{"lib.contracts": "v0.24.0"}, probes)
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
	if err := gateLibPinsWith(nil, map[string]string{"lib.core": "v0.41.0"}, probes); err != nil {
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
	if err := gateLibPinsWith(nil, map[string]string{"lib.core": "v0.41.0"}, probes); err == nil {
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

// preflightRepos = bumpPRRepos ∪ libRepos()(去重)。
func TestPreflightRepos(t *testing.T) {
	got := preflightRepos()
	seen := map[string]bool{}
	for _, r := range got {
		if seen[r] {
			t.Fatalf("重复仓: %s", r)
		}
		seen[r] = true
	}
	for _, want := range []string{"pigeonbox", "server", "contracts", "core", "p2p", "frontend-core"} {
		if !seen[want] {
			t.Errorf("缺仓: %s", want)
		}
	}
}

// 接线守卫:preflight 必须真接进 cmdRun/子命令/Makefile(spec §9 W3)。
// (status 三条 needle 由 Task 5 扩入。)
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
