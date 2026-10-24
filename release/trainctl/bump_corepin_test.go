package main

import "testing"

// 终端 core 钉版必须跟随库线版本（2026-10-24 实录：只 --set core= 漏
// core_pin ⇒ 终端静默留在旧版 ⇒ tag 阶段被「裸奔 tag 拦截」挡下，列车卡 draft）。
func TestFollowCorePin(t *testing.T) {
	cases := []struct {
		name        string
		curPin, lib string
		libChanged  bool
		want        string
		wantChanged bool
	}{
		{"库线变更 ⇒ 跟随", "v0.31.9", "v0.32.0", true, "v0.32.0", true},
		{"库线未变 ⇒ 保持", "v0.31.9", "v0.31.9", false, "v0.31.9", false},
		{"库线未变但值不同 ⇒ 仍保持（不产无关 diff）", "v0.31.9", "v0.32.0", false, "v0.31.9", false},
		{"已是同版 ⇒ 无变更", "v0.32.0", "v0.32.0", true, "v0.32.0", false},
		{"库线为空 ⇒ 不动", "v0.31.9", "", true, "v0.31.9", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, changed := followCorePin(c.curPin, c.lib, c.libChanged)
			if got != c.want || changed != c.wantChanged {
				t.Fatalf("followCorePin(%q,%q,%v) = (%q,%v)，期望 (%q,%v)",
					c.curPin, c.lib, c.libChanged, got, changed, c.want, c.wantChanged)
			}
		})
	}
}
