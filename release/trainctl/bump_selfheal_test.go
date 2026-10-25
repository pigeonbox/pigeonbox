package main

import (
	"os"
	"os/exec"
	"path/filepath"
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
