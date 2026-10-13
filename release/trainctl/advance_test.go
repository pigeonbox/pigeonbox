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
