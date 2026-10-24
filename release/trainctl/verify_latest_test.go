package main

import "testing"

// TestIsShippedPhase 回归（2026-10-24，3.3.24 列车 tagged/shipped 两阶段各假红一次）：
//
// 列车状态机里**下游产物不是与 state 同时到位的**，因此「非 shipped 态就强校验」
// = **必然假失败**：
//
//   - hub Latest：v<train> Release 是 finalize 推 tag **之后**才由 release.yml
//     创建的（finalize 先提交 state=shipped ⇒ 那个 push 就触发了 verify 工作流
//     ⇒ 校验跑在 Release 建好之前，实测约 40 秒窗口）；
//   - charts：Chart.yaml 的提交被**显式推迟**到 advance（镜像在位后才直提，
//     否则 chart 发版会指向还不存在的镜像 ⇒ install 即 ImagePullBackOff）
//     ⇒ tagged 态 charts **必然**还是上一车。
//
// ⇒ 跨仓产物只在 shipped 态强校验；其余态告警。
//
// 组件 tag 不在此列：tag 阶段是**先推全部组件 tag、再提交 state=tagged**
// ⇒ tagged 态 tag 必然已存在，严格校验是安全的（tagchk 仍按 draft 告警）。
func TestIsShippedPhase(t *testing.T) {
	cases := map[string]bool{
		"draft":    false, // 新车未开 ⇒ 跨仓产物都还不存在
		"tagged":   false, // ← 3.3.24 假红的那一档：charts 还没提交
		"shipping": false, // 历史遗留取值
		"shipped":  true,  // 只有这一档才强校验跨仓产物
		"":         false, // 状态缺失不得当成 shipped
	}
	for state, want := range cases {
		if got := isShippedPhase(state); got != want {
			t.Errorf("isShippedPhase(%q) = %v, want %v", state, got, want)
		}
	}
}

// TestChartAlignVerdict charts 对齐检查的三态判定。
//
// 负对照意义：若把判定内联回 handler（或还原成「仅 draft 告警」），本用例即
// 失去牙齿 ⇒ 3.3.24 那种「tagged 态假红一次」就会重演且无人察觉。
func TestChartAlignVerdict(t *testing.T) {
	cases := []struct {
		state string
		got   string
		want  string
		exp   string
	}{
		// shipped 态：对齐了 → ok
		{"shipped", "2.0.72", "2.0.72", verdictOK},
		// shipped 态：没对齐 → fail（强校验，漏推 charts 会被抓）
		{"shipped", "2.0.71", "2.0.72", verdictFail},
		// tagged 态：charts 还没提交（镜像未齐）⇒ **只能告警**，
		// 否则 3.3.24 那种「tagged 态必然假红」会重演
		{"tagged", "2.0.71", "2.0.72", verdictWarn},
		// draft 态：车刚开，跨仓产物都还不存在 ⇒ 告警
		{"draft", "2.0.71", "2.0.72", verdictWarn},
		// 任意非 shipped 态但值恰好对上了 → ok
		{"tagged", "2.0.72", "2.0.72", verdictOK},
	}
	for _, c := range cases {
		if got := chartAlignVerdict(c.state, c.got, c.want); got != c.exp {
			t.Errorf("chartAlignVerdict(%q, %q, %q) = %q, want %q", c.state, c.got, c.want, got, c.exp)
		}
	}
}
