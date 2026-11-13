// ff_recover_test.go —— hub 分歧检查点的「先自动 ff-only 恢复」守卫(2026-11-13 收口)。
//
// 旧行为:commitHubTrainFile 在 state 推进前发现 hub 本地与远端分歧 ⇒ 直接 die
// 「先 pull --ff-only」——而这条检查点在 advance 的推进路径上,本地跑车几乎必撞,
// 能自动恢复的事却要人工。新行为:先自动尝试一次 git pull --ff-only,失败才报错
// (保留原报文 + 恢复失败原因)。
//
// 三种形态各走各的出路(与 git 语义一一对应):
//
//	· 只落后 ⇒ 自动恢复成功(正判据:恢复后两端 HEAD 一致);
//	· 分叉(两边各有提交)⇒ pull --ff-only 必失败 ⇒ 报错并带恢复失败原因;
//	· 只领先(本地有未推送提交)⇒ pull 是 no-op ⇒ 仍分歧 ⇒ 报错点名「仍分歧」。
//
// 负对照(实测转红后还原):把 ensureHubFfAligned 改回旧的「分歧即报错」
// ⇒ 只落后用例红(自动恢复丢失)。
//
// 另有源码接线守卫:commitHubTrainFile 必须调用 ensureHubFfAligned
// (抽了 helper 却不接线 = 改动形同虚设)。
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newFfPair 造「裸 origin + seed 推送端 + 工作克隆」,三端都在 c1。
func newFfPair(t *testing.T) (origin, work, seed string) {
	t.Helper()
	root := t.TempDir()
	origin = filepath.Join(root, "origin.git")
	work = filepath.Join(root, "work")
	seed = filepath.Join(root, "seed")
	for _, d := range []string{work, seed} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, root, "init", "-q", "--bare", "-b", "main", origin)
	gitRun(t, seed, "init", "-q", "-b", "main")
	gitRun(t, seed, "config", "user.email", "t@example.com")
	gitRun(t, seed, "config", "user.name", "t")
	writeFile(t, seed, "a.txt", "c1\n")
	gitRun(t, seed, "add", "-A")
	gitRun(t, seed, "commit", "-qm", "c1")
	gitRun(t, seed, "remote", "add", "origin", origin)
	gitRun(t, seed, "push", "-q", "-u", "origin", "main")
	gitRun(t, work, "clone", "-q", origin, ".")
	gitRun(t, work, "config", "user.email", "t@example.com")
	gitRun(t, work, "config", "user.name", "t")
	return origin, work, seed
}

// commitIn 在 dir 提交一个新文件。
func commitIn(t *testing.T, dir, file, msg string) {
	t.Helper()
	writeFile(t, dir, file, msg+"\n")
	gitRun(t, dir, "add", "-A")
	gitRun(t, dir, "commit", "-qm", msg)
}

// 正判据:只落后 ⇒ 自动 ff-only 恢复成功,恢复后与远端一致。
func TestEnsureHubFfAligned_BehindAutoRecovers(t *testing.T) {
	origin, work, seed := newFfPair(t)
	// 远端前进一步(本地落后)。
	commitIn(t, seed, "b.txt", "c2")
	gitRun(t, seed, "push", "-q", "origin", "main")

	if err := ensureHubFfAligned(work); err != nil {
		t.Fatalf("只落后应自动 ff-only 恢复(旧的「分歧即报错」是本用例要收口的行为): %v", err)
	}
	want := gitRun(t, origin, "rev-parse", "main")
	got := gitRun(t, work, "rev-parse", "HEAD")
	if got != want {
		t.Fatalf("恢复后本地应与 origin/main 一致: local=%s origin=%s", got, want)
	}
}

// 分叉(两边各有提交)⇒ pull --ff-only 必失败 ⇒ 报错,且保留原报文 + 失败原因。
func TestEnsureHubFfAligned_DivergedFailsWithReason(t *testing.T) {
	_, work, seed := newFfPair(t)
	commitIn(t, seed, "b.txt", "c2")
	gitRun(t, seed, "push", "-q", "origin", "main")
	commitIn(t, work, "local.txt", "local-commit")

	err := ensureHubFfAligned(work)
	if err == nil {
		t.Fatal("分叉必须报错(ff-only 恢复不了,不许静默放行)")
	}
	msg := err.Error()
	for _, want := range []string{"先 pull --ff-only", "自动 ff-only 恢复失败"} {
		if !strings.Contains(msg, want) {
			t.Errorf("报错应保留原报文口径 %q(操作者要能照着修): %s", want, msg)
		}
	}
}

// 只领先(本地有未推送提交)⇒ pull 是 no-op ⇒ 仍分歧 ⇒ 报错点名「仍分歧」。
func TestEnsureHubFfAligned_AheadStillFails(t *testing.T) {
	_, work, _ := newFfPair(t)
	commitIn(t, work, "local.txt", "local-commit")

	err := ensureHubFfAligned(work)
	if err == nil {
		t.Fatal("本地有未推送提交时必须报错(不能把未推送的 state 变更吞掉)")
	}
	if !strings.Contains(err.Error(), "仍分歧") {
		t.Errorf("应点名「恢复后仍分歧」: %s", err.Error())
	}
}

// 对齐时直接通过(不动远端)。
func TestEnsureHubFfAligned_AlignedNoop(t *testing.T) {
	_, work, _ := newFfPair(t)
	if err := ensureHubFfAligned(work); err != nil {
		t.Fatalf("已对齐不该报错: %v", err)
	}
}

// 源码接线守卫:commitHubTrainFile 必须走 ensureHubFfAligned(抽 helper 不接线=白改)。
func TestCommitHubTrainFile_UsesFfRecovery(t *testing.T) {
	src, err := os.ReadFile("tag.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "ensureHubFfAligned(dir)") {
		t.Fatal("commitHubTrainFile 必须调用 ensureHubFfAligned(接线被还原 = 自动恢复失效)")
	}
}
