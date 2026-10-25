package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestRestoreTrainManagedFiles 只还原**列车管理的文件**里被本地改动的部分，
// 且**不碰**其它本地改动。
//
// 场景（2026-10-25 实录）：同一车次重跑 bump（要把 pin 改指向新版本）时，
// 工作树里还留着前一波 bump 写下的改动 ⇒ `git checkout -b train/<v> …` 直接失败
// （"Your local changes … would be overwritten by checkout"）⇒ 整个 bump 死掉
// ⇒ 只能改用新车次绕过（白作废一车次）。
//
// 断言必须能变红（负对照）：把 restoreTrainManagedFiles 改成「还原全部改动」
// ⇒ 「用户自己的在制品被吞」用例红。
//
// 注：trainctl 是**零第三方依赖**的工具（发布流水线要在最小镜像里跑）⇒
// 这里用标准库断言，不用 testify。
func TestRestoreTrainManagedFiles(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	writeFile(t, dir, "VERSION", "3.3.22\n")
	writeFile(t, dir, "user-work.txt", "mine\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	// 模拟「前一波 bump 写下的改动」+「用户自己的在制品改动」
	writeFile(t, dir, "VERSION", "3.3.23\n")
	writeFile(t, dir, "user-work.txt", "mine-edited\n")

	restored := restoreTrainManagedFiles(dir, []string{"VERSION"})
	if len(restored) != 1 || restored[0] != "VERSION" {
		t.Fatalf("只应还原列车管理的文件，实得 %v", restored)
	}
	if got := readFile(t, dir, "VERSION"); got != "3.3.22\n" {
		t.Errorf("列车文件应被还原到 HEAD，实得 %q", got)
	}
	if got := readFile(t, dir, "user-work.txt"); got != "mine-edited\n" {
		t.Errorf("非列车文件的本地改动不得被吞，实得 %q", got)
	}
}

// TestRestoreTrainManagedFiles_KeepsUntracked 未跟踪文件不动（bump 的文件本来
// 就在仓里；未跟踪只可能是用户自己的新文件 ⇒ 绝不能删）。
func TestRestoreTrainManagedFiles_KeepsUntracked(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	writeFile(t, dir, "VERSION", "1\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	// 未跟踪的新文件（用户自己的）
	writeFile(t, dir, "new-file.txt", "x\n")

	restored := restoreTrainManagedFiles(dir, []string{"VERSION", "new-file.txt"})
	if len(restored) != 0 {
		t.Errorf("未跟踪文件不得被当成「已改动」还原，实得 %v", restored)
	}
	if _, err := os.Stat(filepath.Join(dir, "new-file.txt")); err != nil {
		t.Errorf("未跟踪文件必须保留（不得删用户的在制品）: %v", err)
	}
}

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestSnapshotRestoreTrainFiles_RoundTrip 「保存 → 还原 → 写回」必须**无损**。
//
// 这正是 2026-10-25 自踩的坑：切分支前若**只还原不保存** ⇒ 把本波 bump 刚写好的
// 编辑抹回 HEAD ⇒ 所有仓报「无列车变更」⇒ 整趟 bump 静默空转（还返回 success）。
//
// 断言必须能变红（负对照）：只做「还原」不做「写回」⇒ 内容丢失 ⇒ 用例红。
func TestSnapshotRestoreTrainFiles_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	writeFile(t, dir, "VERSION", "3.3.27\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	// 本波 bump 写下的新内容
	writeFile(t, dir, "VERSION", "3.3.28\n")

	// ① 保存
	saved := snapshotTrainFiles(dir, []string{"VERSION"})
	if len(saved) != 1 {
		t.Fatalf("应保存 1 个改动文件，实得 %d", len(saved))
	}
	// ② 还原（让 checkout 能过）
	restoreTrainManagedFiles(dir, []string{"VERSION"})
	if got := readFile(t, dir, "VERSION"); got != "3.3.27\n" {
		t.Fatalf("还原后应回到 HEAD，实得 %q", got)
	}
	// ③ 写回（编辑不丢）
	restoreSavedFiles(dir, saved)
	if got := readFile(t, dir, "VERSION"); got != "3.3.28\n" {
		t.Fatalf("写回后应保留本波编辑（3.3.28），实得 %q", got)
	}
}

// TestSnapshotTrainFiles_IgnoresUnmodified 未改动的文件不进快照（不白写回）。
func TestSnapshotTrainFiles_IgnoresUnmodified(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	run("config", "user.email", "t@example.com")
	run("config", "user.name", "t")
	writeFile(t, dir, "VERSION", "1\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	if saved := snapshotTrainFiles(dir, []string{"VERSION"}); len(saved) != 0 {
		t.Errorf("未改动的文件不应进快照，实得 %v", saved)
	}
}

// TestSwitchTrainBranch_KeepsEditsAcrossBranchSwitch 端到端：**已有远端同名列车
// 分支** + 工作树里有本波编辑 ⇒ 切分支必须成功**且编辑不丢**。
//
// 这是 2026-10-25 的两个真实故障的合体复现：
//
//	A. 切分支被「本地改动」挡住 ⇒ bump 死掉；
//	B. 只还原不保存 ⇒ 编辑被抹 ⇒ 整趟 bump 静默空转。
func TestSwitchTrainBranch_KeepsEditsAcrossBranchSwitch(t *testing.T) {
	origin := t.TempDir()
	work := t.TempDir()
	runIn := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	// origin（裸仓）：先推一个 main，再建一个「旧列车分支」
	runIn(origin, "init", "-q", "-b", "main")
	runIn(origin, "config", "user.email", "t@example.com")
	runIn(origin, "config", "user.name", "t")
	writeFile(t, origin, "VERSION", "3.3.27\n")
	runIn(origin, "add", "-A")
	runIn(origin, "commit", "-qm", "init")
	runIn(origin, "checkout", "-q", "-b", "train/3.3.28")
	writeFile(t, origin, "VERSION", "3.3.28-old\n")
	runIn(origin, "add", "-A")
	runIn(origin, "commit", "-qm", "old train branch")
	runIn(origin, "checkout", "-q", "main")

	// work：克隆 origin，处于 main，工作树里有「本波 bump 的编辑」
	runIn(work, "clone", "-q", origin, ".")
	runIn(work, "config", "user.email", "t@example.com")
	runIn(work, "config", "user.name", "t")
	writeFile(t, work, "VERSION", "3.3.28\n") // 本波编辑

	switched, err := switchTrainBranch(work, "train/3.3.28", "origin/train/3.3.28", []string{"VERSION"})
	if err != nil {
		t.Fatalf("切列车分支失败（本地改动挡住了 checkout?）: %v", err)
	}
	if len(switched) != 1 {
		t.Fatalf("应记录 1 个被保存并写回的文件，实得 %v", switched)
	}
	if got := readFile(t, work, "VERSION"); got != "3.3.28\n" {
		t.Fatalf("切分支后本波编辑必须保留（3.3.28），实得 %q", got)
	}
	// 当前分支应是列车分支
	// ⚠️ 必须显式指定 Dir：否则 git 会在**测试进程的工作目录**（trainctl 包目录，
	// 也就是 hub 仓）里执行 ⇒ 读到 hub 自己的分支名（"main"）⇒ 用例假红。
	curCmd := exec.Command("git", "rev-parse", "--abbrev-ref", "HEAD")
	curCmd.Dir = work
	cur, _ := curCmd.Output()
	if cur := strings.TrimSpace(string(cur)); cur != "train/3.3.28" {
		t.Fatalf("应在列车分支上，实得 %q", cur)
	}
}
