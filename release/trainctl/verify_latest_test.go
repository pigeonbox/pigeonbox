package main

import "testing"

// TestLatestCheckApplicable 回归（2026-10-24，3.3.24 列车两次假失败）：
//
// hub 的 v<train> Release 是 **finalize 推 tag 之后**由 release.yml 创建的，
// 而 train.yaml 的 state 变化更早 ⇒ 在 tagged/shipping 态，Latest **必然**还是
// 上一车 ⇒ 此时做 Latest 校验 = **必然假失败**。
//
// 3.3.24 实录：tagged 与 shipped 两次 verify 各假红一次，报
// 「hub Latest(v3.3.23) ≠ v3.3.24」；重跑即绿（那时 Release 已建好）。
//
// ⇒ 强校验只在 shipped 态做（与节标题「仅 shipped 态强校验」对齐）。
func TestLatestCheckApplicable(t *testing.T) {
	cases := map[string]bool{
		"draft":    false, // 新车未开 ⇒ 上一车的 Latest 才是对的
		"tagged":   false, // ← 3.3.24 假红的那一档：Release 还不存在
		"shipping": false, // 同上（历史遗留取值）
		"shipped":  true,  // 只有这一档才强校验
		"":         false, // 状态缺失不得当成 shipped
	}
	for state, want := range cases {
		if got := latestCheckApplicable(state); got != want {
			t.Errorf("latestCheckApplicable(%q) = %v, want %v", state, got, want)
		}
	}
}
