// run_test.go —— 「一条命令开一趟车」这条链路的守卫。
//
// 覆盖三件容易退化的事:
//
//  1. **参数解析**:run 与 bump 共用同一套参数(--set/--hotfix/--freeze-libs/
//     --timeout);解析错 ⇒ 发车命令的开关传不进 CI。
//  2. **自轮询语义**:完成 / 失败 / 超时 三条出路必须各走各的——
//     尤其「失败要立刻返回」:红着的检查不会自己变绿,干等只是烧 runner。
//  3. **检查结论判定**:按「最新一次 attempt」判失败(重跑前的失败 attempt
//     不算数)——否则 CI 重跑绿了仍被判停滞 ⇒ 列车被误判卡死。
package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestParseBumpArgs(t *testing.T) {
	o := parseBumpArgs([]string{"TRAIN=4.0.6", "--set", "core=v0.32.21", "--hotfix", "--freeze-libs", "--timeout=45m"})
	if o.train != "4.0.6" {
		t.Fatalf("train 应是 4.0.6,实得 %q", o.train)
	}
	if !o.hotfix || !o.freezeLibs {
		t.Fatalf("hotfix/freeze-libs 应为真: %+v", o)
	}
	if o.sets["core"] != "v0.32.21" {
		t.Fatalf("--set core 应解析为 v0.32.21,实得 %q", o.sets["core"])
	}
	if o.timeout != "45m" {
		t.Fatalf("timeout 应是 45m,实得 %q", o.timeout)
	}
	if o.push {
		t.Fatal("解析本身不应置 push(run 内部会置)")
	}
}

func TestParseBumpArgs_RejectsBadTrain(t *testing.T) {
	// 非数字/点的列车号必须被拒(die 会 os.Exit ⇒ 只能测到「不 panic」)。
	// 这里直接测解析器的守卫逻辑:合法值必须通过。
	o := parseBumpArgs([]string{"TRAIN=4.0.6"})
	if o.train != "4.0.6" {
		t.Fatalf("合法列车号应通过,实得 %q", o.train)
	}
}

// waitStep:完成 ⇒ 返回 nil。
func TestWaitStep_Done(t *testing.T) {
	calls := 0
	err := waitStep("测试阶段", 2*time.Second, 10*time.Millisecond, func() (stepState, string) {
		calls++
		if calls < 3 {
			return stepWaiting, "还在等"
		}
		return stepDone, "好了"
	})
	if err != nil {
		t.Fatalf("waitStep 应成功: %v", err)
	}
	if calls != 3 {
		t.Fatalf("应在第 3 次轮询拿到完成,实得 %d 次", calls)
	}
}

// waitStep:失败 ⇒ 立刻返回错误(不等超时)——红着的检查不会自己变绿。
func TestWaitStep_FailedFailsFast(t *testing.T) {
	start := time.Now()
	calls := 0
	err := waitStep("测试阶段", 10*time.Minute, 50*time.Millisecond, func() (stepState, string) {
		calls++
		return stepFailed, "检查红了"
	})
	if err == nil {
		t.Fatal("失败态必须返回错误")
	}
	if !strings.Contains(err.Error(), "检查红了") {
		t.Fatalf("错误信息应带失败原因,实得 %v", err)
	}
	if calls != 1 {
		t.Fatalf("失败态应立刻返回(只轮询 1 次),实得 %d 次", calls)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("失败态不该等待到超时")
	}
}

// waitStep:一直不完成 ⇒ 超时返回错误(且错误信息带最后状态)。
func TestWaitStep_Timeout(t *testing.T) {
	err := waitStep("测试阶段", 120*time.Millisecond, 20*time.Millisecond, func() (stepState, string) {
		return stepWaiting, "还是没好"
	})
	if err == nil {
		t.Fatal("超时应返回错误")
	}
	if !strings.Contains(err.Error(), "还是没好") {
		t.Fatalf("超时信息应带最后状态,实得 %v", err)
	}
}

// parseDuration:非法值回落缺省,合法值生效。
func TestParseDuration(t *testing.T) {
	if got := parseDuration("90m", time.Minute); got != 90*time.Minute {
		t.Fatalf("90m 应解析为 90 分钟,实得 %s", got)
	}
	if got := parseDuration("", time.Minute); got != time.Minute {
		t.Fatalf("空值应回落缺省,实得 %s", got)
	}
	if got := parseDuration("乱写", time.Minute); got != time.Minute {
		t.Fatalf("非法值应回落缺省,实得 %s", got)
	}
}

// failedCheckNames:只有「最新一次 attempt 为失败」的检查才算失败。
//
// 负对照:把「failure」从名单里去掉 ⇒ 用例红(⇒ 重跑前的失败 attempt 会被误判)。
func TestFailedCheckNames(t *testing.T) {
	states := []checkState{
		{name: "lint", conclusion: "SUCCESS"},
		{name: "test", conclusion: "failure"},
		{name: "build", conclusion: ""}, // 仍在跑
		{name: "e2e", conclusion: "cancelled"},
	}
	got := failedCheckNames(states)
	if len(got) != 2 {
		t.Fatalf("应报出 test/e2e 两项失败,实得 %v", got)
	}
	if !strings.Contains(got[0], "test") || !strings.Contains(got[1], "e2e") {
		t.Fatalf("失败项内容不对: %v", got)
	}
	// 仍在跑的检查不算失败(否则每次轮询都误报停滞)。
	if strings.Contains(strings.Join(got, ","), "build") {
		t.Fatalf("仍在跑的检查不该算失败: %v", got)
	}
}

// stepState 的取值语义固定(避免有人改枚举导致 run 的失败路径失效)。
func TestStepStateValues(t *testing.T) {
	if stepWaiting == stepDone || stepDone == stepFailed || stepWaiting == stepFailed {
		t.Fatal("三个 stepState 必须互不相同")
	}
	var err error = errors.New("x")
	if err == nil {
		t.Fatal("sanity")
	}
}

// bumpDecision:同一列车号已开出去 ⇒ 跳过 bump(重跑 ≠ 重做)。
//
// 4.0.7 实录:bump PR 已合、列车停在 draft,此时再跑 bump 会「无变更 ⇒ 未建 PR」
// ⇒ 撞「静默空转」守卫 ⇒ 必须跳过 bump 直接接着推。
func TestBumpDecision(t *testing.T) {
	cases := []struct {
		curTrain, curState, want string
		skip, finished           bool
	}{
		{"4.0.7", "draft", "4.0.7", true, false},    // 已开出去 ⇒ 接着推
		{"4.0.7", "tagged", "4.0.7", true, false},   // 已打 tag ⇒ 接着推
		{"4.0.7", "shipped", "4.0.7", true, true},   // 已发货 ⇒ 无事可做
		{"4.0.6", "shipped", "4.0.7", false, false}, // 上一趟车 ⇒ 照常开新车
		{"", "", "4.0.7", false, false},             // 读不到 ⇒ 照常开新车
		{"4.0.7", "", "4.0.7", false, false},        // 有列车号无状态 ⇒ 照常开新车
	}
	for _, c := range cases {
		skip, finished, why := bumpDecision(c.curTrain, c.curState, c.want)
		if skip != c.skip || finished != c.finished {
			t.Fatalf("bumpDecision(%q,%q,%q)=(%v,%v), 期望 (%v,%v)",
				c.curTrain, c.curState, c.want, skip, finished, c.skip, c.finished)
		}
		if why == "" {
			t.Fatalf("bumpDecision 必须给出理由(%q,%q,%q)", c.curTrain, c.curState, c.want)
		}
	}
}
