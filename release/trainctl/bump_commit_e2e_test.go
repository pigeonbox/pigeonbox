// bump_commit_e2e_test.go bump commit() 的**端到端**回归
// （2026-10-25 静默空转事故引入）。
//
// 为什么必须有这个用例（内层 stageTrainFiles 单测**不够**）：
//
// 事故根因在 commit() 的**外层**：它自己做了一次「快照 + 还原到 HEAD」，
// 而 switchTrainBranch 内部**又**做了一次「快照 + 还原 + 切 + 写回」
// ⇒ 外层把编辑还原后，内层快照到的是**已还原**的内容（空）⇒ 写回时什么也没写
// ⇒ 编辑彻底丢失 ⇒ `git add` 暂存的是 HEAD 内容 ⇒ `git diff --cached --quiet`
// 恒真 ⇒ 「无列车变更,跳过」⇒ **不 push、不建 PR**，却仍打印「✓ 已提交」
// ⇒ 整趟 bump 静默空转（还返回 success）。
//
// ⇒ 只测内层链路**测不出**这个回归（2026-10-25 实录：内层全绿，真实 CI 仍空转）。
// 本用例把 gh 换成桩（ghRunner seam），在**本地裸仓**上真跑 commit() 全链路，
// 断言：分支被推了、PR 被建了、**远端分支上的内容是新值**。
//
// 断言必须能变红（负对照）：
//
//	· 在 commit() 里重新加回外层「快照 + 还原」⇒ 本用例红（远端分支仍是旧值）；
//	· 把 stageTrainFiles 的写回去掉 ⇒ 本用例红。
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// newCommitEnv 造「远端裸仓 + 本地克隆」，并返回两端路径。
func newCommitEnv(t *testing.T) (origin, work string) {
	t.Helper()
	root := t.TempDir()
	origin = filepath.Join(root, "origin.git")
	work = filepath.Join(root, "work")
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	runIn := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	// 裸仓当 origin。
	// ⚠️ 必须 `-b main`：默认 HEAD 指向 master ⇒ 克隆得到**空仓**
	// ⇒ 工作树里的文件全是未跟踪 ⇒ `git diff HEAD` 失败 ⇒
	// 快照机制永远拿不到内容 ⇒ 用例**测不到东西**（假绿，2026-10-25 实录）。
	runIn(root, "init", "-q", "--bare", "-b", "main", origin)
	// 用一个工作树把内容推进裸仓
	seed := filepath.Join(root, "seed")
	if err := os.MkdirAll(seed, 0o755); err != nil {
		t.Fatal(err)
	}
	runIn(seed, "init", "-q", "-b", "main")
	runIn(seed, "config", "user.email", "t@example.com")
	runIn(seed, "config", "user.name", "t")
	writeFile(t, seed, "VERSION", "3.3.27\n")
	runIn(seed, "add", "-A")
	runIn(seed, "commit", "-qm", "init")
	runIn(seed, "remote", "add", "origin", origin)
	runIn(seed, "push", "-q", "-u", "origin", "main")

	// 工作克隆
	runIn(work, "clone", "-q", origin, ".")
	runIn(work, "config", "user.email", "t@example.com")
	runIn(work, "config", "user.name", "t")
	return origin, work
}

// stubGh 把 gh 换成桩，记录调用。
func stubGh(t *testing.T) *[]string {
	t.Helper()
	var calls []string
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		if len(args) >= 2 && args[0] == "pr" && args[1] == "create" {
			return "https://github.com/pigeonbox/pigeonbox/pull/999", nil
		}
		return "", nil
	}
	t.Cleanup(func() { ghRunner = prev })
	return &calls
}

// TestCommit_PushesBranchAndCreatesPR commit() 必须**真的**推分支 + 建 PR。
//
// 这是「静默空转」的直接反证：分支没推 / PR 没建 ⇒ 列车不动。
func TestCommit_PushesBranchAndCreatesPR(t *testing.T) {
	origin, work := newCommitEnv(t)
	calls := stubGh(t)

	// 本波 bump 写下的新版本（模拟 edit() 落盘）
	writeFile(t, work, "VERSION", "3.3.28\n")

	b := &bumper{
		env: nil, train: "3.3.28", push: true,
		planned: map[string][]string{".": {"VERSION"}},
		prDone:  map[string]bool{},
	}
	b.commit(".", work, "train: bump to 3.3.28", []string{"VERSION"})

	// ① PR 必须被建（gh pr create 被调到）
	found := false
	for _, c := range *calls {
		if strings.Contains(c, "pr create") {
			found = true
		}
	}
	if !found {
		t.Fatalf("commit() 必须调 gh pr create（实际调用: %v）", *calls)
	}
	// ② 远端必须有 train/3.3.28 分支
	out, err := exec.Command("git", "-C", origin, "branch", "--list", "train/3.3.28").CombinedOutput()
	if err != nil || strings.TrimSpace(string(out)) == "" {
		t.Fatalf("远端必须有 train/3.3.28 分支（实际: %q）", strings.TrimSpace(string(out)))
	}
	// ③ **远端分支上的内容必须是新值**（这是事故里被吞掉的东西）
	remote, err := exec.Command("git", "-C", origin, "show", "train/3.3.28:VERSION").CombinedOutput()
	if err != nil {
		t.Fatalf("读远端分支内容失败: %v\n%s", err, remote)
	}
	if got := strings.TrimSpace(string(remote)); got != "3.3.28" {
		t.Fatalf("远端 train/3.3.28 上的 VERSION 必须是 3.3.28，实得 %q（编辑被还原/丢失）", got)
	}
	// ④ prDone 必须记账（汇总行靠它反映实况）
	if !b.prDone["."] {
		t.Fatal("commit() 必须记账 prDone（汇总行据此判断是否真落地）")
	}
}

// TestCommit_NoDoubleRestore 负对照的**形态**断言：commit() 内部**不得**再做
// 一次「快照 + 还原」——那正是 3.3.28 静默空转的根因（外层还原 ⇒ 内层写回空）。
//
// 本用例直接查源码（机械守卫）：commit() 里出现 snapshotTrainFiles /
// restoreTrainManagedFiles 即红。
//
// 为什么用源码断言而不是行为断言：双还原的**后果**（编辑丢失）已被
// TestCommit_PushesBranchAndCreatesPR 抓住；本用例锁的是**成因**，
// 让「谁把还原搬回外层」在 review 时立刻变红。
func TestCommit_NoDoubleRestore(t *testing.T) {
	src, err := os.ReadFile("bump.go")
	if err != nil {
		t.Fatalf("读 bump.go 失败: %v", err)
	}
	text := string(src)
	// 取出 commit() 函数体
	start := strings.Index(text, "func (b *bumper) commit(")
	if start < 0 {
		t.Fatal("找不到 commit()")
	}
	end := strings.Index(text[start:], "\nfunc ")
	if end < 0 {
		end = len(text) - start
	}
	body := text[start : start+end]
	for _, forbidden := range []string{"snapshotTrainFiles", "restoreTrainManagedFiles"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("commit() 内部不得出现 %s（外层还原会让内层的写回拿到空内容 ⇒ 编辑丢失 ⇒ 静默空转；快照/还原只能由 stageTrainFiles 做一次）", forbidden)
		}
	}
}
