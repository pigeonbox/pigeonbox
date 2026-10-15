package main

import "testing"

func TestReleaseTagFor(t *testing.T) {
	tf := &TrainFile{m: map[string]string{
		"images.server":        "1.21.0",
		"terminal.desktop.tag": "desktop-v1.21.0",
		"terminal.fnos.tag":    "v1.21.0",
		"lib.p2p":              "v0.6.1",
	}}
	cases := map[string]string{
		"desktop": "desktop-v1.21.0",
		"p2p":     "v0.6.1",
		"fnos":    "v1.21.0",
		"server":  "v1.21.0", // server 无 terminal.*.tag,取镜像号加 v
	}
	for repo, want := range cases {
		if got := releaseTagFor(tf, repo); got != want {
			t.Errorf("releaseTagFor(%s) = %s, want %s", repo, got, want)
		}
	}
}

// TestServerCorePinOK 裸奔 tag 拦截断言：go.mod 钉版必须等于列车 lib.core。
func TestServerCorePinOK(t *testing.T) {
	gomod := "module github.com/pigeonbox/server\n\nrequire (\n\tgithub.com/pigeonbox/core v0.22.1\n\tgithub.com/pigeonbox/contracts v0.15.1 // indirect\n)\n"
	if !serverCorePinOK(gomod, "v0.22.1") {
		t.Fatal("钉版匹配应通过")
	}
	if serverCorePinOK(gomod, "v0.22.0") {
		t.Fatal("旧钉版必须拦截（裸奔 tag：bump PR 未合并的 main 钉版仍是旧值）")
	}
	if serverCorePinOK("", "v0.22.1") {
		t.Fatal("空 go.mod 必须拦截")
	}
}
