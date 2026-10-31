package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// 2026-10-31 实测的**假绿**（本轮最严重的一个）：
//
//	从**上一趟已 shipped** 的状态开新车（4.6.4 shipped ⇒ 开 4.6.5）⇒
//	hub 自己的 bump PR 还没合并 ⇒ 远端 train.yaml **仍指向 4.6.4/shipped**
//	⇒ 「等 bump PR 合并」那一步**只看 state** ⇒ 判「已进入 shipped 态 ⇒ 完成」
//	⇒ 列车**根本没开**就打印「✓ 列车已发货」
//	⇒ 实测：**一个 4.6.5 tag 都没有推出来**、hub 无 v4.6.5 Release，
//	   9 个 bump PR 里 7 个已合并（人肉看日志才发现「已发货」是假的）。
//
// ⇒ 修法：等待步的判定必须**同时看「车次」与「状态」**：
//	版本对不上 ⇒ 还没合并 ⇒ **等**；对上了才看状态。

func TestBumpWaitDecision(t *testing.T) {
	cases := []struct {
		curTrain, curState, want string
		expect                   string
		why                      string
	}{
		// ★ 回归判据：上一趟车的 shipped ≠ 这趟车已完成
		{"4.6.4", "shipped", "4.6.5", waitHold, "上一趟车的 shipped ⇒ 必须等，不能判完成"},
		{"4.6.4", "draft", "4.6.5", waitHold, "上一趟车的 draft ⇒ 必须等"},
		{"", "", "4.6.5", waitHold, "读不到车次 ⇒ 必须等"},
		// 本趟车：状态决定下一步
		{"4.6.5", "draft", "4.6.5", waitAdvance, "本趟 draft ⇒ 推进"},
		{"4.6.5", "", "4.6.5", waitAdvance, "本趟无状态 ⇒ 推进"},
		{"4.6.5", "tagged", "4.6.5", waitDone, "本趟已 tagged ⇒ 本步完成"},
		{"4.6.5", "shipped", "4.6.5", waitDone, "本趟已 shipped ⇒ 本步完成"},
	}
	for _, c := range cases {
		got := bumpWaitDecision(c.curTrain, c.curState, c.want)
		if got != c.expect {
			t.Fatalf("bumpWaitDecision(%q,%q,%q)=%q，期望 %q（%s）",
				c.curTrain, c.curState, c.want, got, c.expect, c.why)
		}
	}
}

func TestShipWaitDecision(t *testing.T) {
	cases := []struct {
		curTrain, curState, want string
		expect                   string
		why                      string
	}{
		// ★ 回归判据：上一趟车的 shipped ≠ 这趟车已发货
		{"4.6.4", "shipped", "4.6.5", waitHold, "上一趟车已发货 ≠ 这趟车已发货 ⇒ 必须等"},
		{"4.6.4", "tagged", "4.6.5", waitHold, "上一趟车 tagged ⇒ 必须等"},
		{"4.6.5", "tagged", "4.6.5", waitAdvance, "本趟 tagged ⇒ 推进"},
		{"4.6.5", "shipping", "4.6.5", waitAdvance, "本趟 shipping ⇒ 推进"},
		{"4.6.5", "shipped", "4.6.5", waitDone, "本趟已发货 ⇒ 完成"},
		{"4.6.5", "draft", "4.6.5", waitHold, "本趟还在 draft ⇒ 还没到 tagged"},
	}
	for _, c := range cases {
		got := shipWaitDecision(c.curTrain, c.curState, c.want)
		if got != c.expect {
			t.Fatalf("shipWaitDecision(%q,%q,%q)=%q，期望 %q（%s）",
				c.curTrain, c.curState, c.want, got, c.expect, c.why)
		}
	}
}

// 判定函数的**版本比较**必须真的在用（防止有人把 `curTrain != want` 删掉
// ⇒ 行为测试会红，但**调用点**可能绕开函数 ⇒ 这里补一道结构守卫）。
//
// ⚠️ 这是**结构性**守卫（读源码），不是行为判定：行为判定在上面两个测试里
// （那两个打的是**真实函数**）。结构守卫只负责堵「调用点绕开判定」这条路。
func TestWaitStepsDelegateToVersionAwareDecisions(t *testing.T) {
	raw, err := os.ReadFile("run.go")
	if err != nil {
		t.Fatalf("读 run.go 失败: %v", err)
	}
	src := string(raw)

	// ① 两个等待步都必须调用版本感知的判定函数
	for _, fn := range []string{"bumpWaitDecision(", "shipWaitDecision("} {
		if !strings.Contains(src, fn) {
			t.Fatalf("run.go 里找不到 %s ⇒ 等待步没走版本感知判定（假绿会复活）", fn)
		}
	}

	// ② 等待步内**不得**出现「只看 state」的裸判定
	//    （旧写法：`switch tf.Get("state") { case "draft", "": ... default: return stepDone, ... }`）
	bare := regexp.MustCompile(`switch\s+tf\.Get\("state"\)`)
	if bare.MatchString(src) {
		t.Fatalf("run.go 里仍有 `switch tf.Get(\"state\")` 的裸判定 ⇒ " +
			"「只看状态不看车次」的假绿会复活")
	}

	// ③ 判定函数本身必须先比车次
	for _, fn := range []string{"func bumpWaitDecision", "func shipWaitDecision"} {
		i := strings.Index(src, fn)
		if i < 0 {
			t.Fatalf("找不到 %s", fn)
		}
		body := src[i:]
		if j := strings.Index(body, "\n}"); j > 0 {
			body = body[:j]
		}
		if !strings.Contains(body, "curTrain != want") {
			t.Fatalf("%s 里没有 `curTrain != want` ⇒ 版本比较被删掉了", fn)
		}
	}
}

// ── 在途探测：任何车次的 train/* PR 都算在途（2026-10-31 实测的假红）────────

func TestAnyTrainBumpPR(t *testing.T) {
	cases := []struct {
		heads  []string
		expect bool
		why    string
	}{
		// ★ 回归判据：hub 的 train.yaml 停在旧车次、组件仓的 bump PR 已是新车次
		//   ⇒ 只认旧车次会漏判 ⇒ 拿旧车次比新车次 ⇒ 假漂移 ⇒ 无关 PR 被红
		{[]string{"train/4.6.5"}, true, "新车次的 bump PR ⇒ 在途"},
		{[]string{"fix/xxx", "train/4.6.5"}, true, "混在别的 PR 里也要认"},
		{[]string{"train/4.6.4"}, true, "旧车次的 bump PR 也是在途"},
		{[]string{"fix/xxx", "feature/y"}, false, "没有 train/* ⇒ 不在途"},
		{[]string{}, false, "空列表 ⇒ 不在途"},
		{nil, false, "nil ⇒ 不在途"},
		{[]string{"train"}, false, "train（无斜杠）不是 bump PR"},
		{[]string{"trains/4.6.5"}, false, "trains/ 不是 train/"},
	}
	for _, c := range cases {
		if got := anyTrainBumpPR(c.heads); got != c.expect {
			t.Fatalf("anyTrainBumpPR(%v)=%v，期望 %v（%s）", c.heads, got, c.expect, c.why)
		}
	}
}
