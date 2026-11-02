package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestSyncHubMain_PicksUpRemoteMerge 4.7.0 实录「误判超时」的根因回归锁。
//
// 现场:bump PR(hub#252)只在**远端**合并,run 的等待环里本地 origin/main
// 引用是旧的 ⇒ 比较 main...origin/main 恒判「已同步」⇒ 不 pull ⇒ tf 停在
// 旧列车 ⇒ bumpWaitDecision 永远 waitHold ⇒ 90 分钟到点报「bump PR 未合并」
// 超时——而 PR 其实早已合并。
//
// 修法 = 比较/读取前先 fetch。本用例在「远端已合并、本地未 fetch」的现场
// 断言 syncHubMain 拿到的是**远端**新列车号。
//
// 负对照:把 syncHubMain 里的 fetch 去掉 ⇒ 本用例红(读到陈旧的 4.7.0)。
func TestSyncHubMain_PicksUpRemoteMerge(t *testing.T) {
	root := t.TempDir()
	origin := filepath.Join(root, "origin")
	work := filepath.Join(root, "work")
	for _, d := range []string{origin, work} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, origin, "init", "-q", "-b", "main")
	gitRun(t, origin, "config", "user.email", "t@example.com")
	gitRun(t, origin, "config", "user.name", "t")
	gitRun(t, origin, "config", "receive.denyCurrentBranch", "ignore")
	if err := os.MkdirAll(filepath.Join(origin, "release"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, origin, "release/train.yaml", "schema: \"1\"\ntrain: 4.7.0\nstate: shipped\n")
	gitRun(t, origin, "add", "-A")
	gitRun(t, origin, "commit", "-qm", "train 4.7.0 shipped")
	gitRun(t, work, "clone", "-q", origin, ".")

	// 远端合并了 bump PR(train.yaml 进 4.8.0/draft),但**不在本地 fetch**
	// ⇒ 本地 origin/main 引用陈旧——这正是 4.7.0 run 的现场。
	writeFile(t, origin, "release/train.yaml", "schema: \"1\"\ntrain: 4.8.0\nstate: draft\n")
	gitRun(t, origin, "add", "-A")
	gitRun(t, origin, "commit", "-qm", "hub bump PR merged (4.8.0)")

	env := &Env{Root: work}
	tf := syncHubMain(env)
	if tf.Get("train") != "4.8.0" {
		t.Fatalf("syncHubMain 必须 fetch 后读远端:应得 train 4.8.0,实得 %s"+
			"(读到陈旧引用 ⇒ run 的等待环会把「已合并」误判成超时)", tf.Get("train"))
	}
	if tf.Get("state") != "draft" {
		t.Fatalf("state 应随远端为 draft,实得 %s", tf.Get("state"))
	}
}
