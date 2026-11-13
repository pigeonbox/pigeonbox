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

func countCalls(calls *[]string, sub string) int {
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
	if countCalls(calls, "update-branch") != 1 {
		t.Fatalf("BEHIND 必须触发一次 update-branch 自愈,实得 %d 次", countCalls(calls, "update-branch"))
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
	if n := countCalls(calls, "update-branch"); n != 3 {
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
			// gh --json statusCheckRollup 走 GraphQL ⇒ conclusion 是大写枚举(SUCCESS)
			return `{"statusCheckRollup":[{"name":"lint","workflowName":"ci","conclusion":"SUCCESS","startedAt":"2026-11-13T00:00:00Z","completedAt":"2026-11-13T00:01:00Z"}]}`, nil
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
	if countCalls(&calls, "pr merge") != 1 {
		t.Fatalf("CLEAN+绿 必须走原路径合并,pr merge 实得 %d 次", countCalls(&calls, "pr merge"))
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
	if countCalls(&calls, "update-branch") != 0 {
		t.Fatal("状态读不到时不得擅自 update-branch")
	}
	if countCalls(&calls, "pr merge") != 1 {
		t.Fatal("状态读不到应回落到原合并路径")
	}
}
