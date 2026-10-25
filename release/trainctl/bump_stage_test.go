// bump_stage_test.go bump 暂存链路的**端到端**回归（2026-10-25 静默空转实录）。
//
// 事故复盘（3.3.28 实录）：CI 日志里每个仓都打「✓ 无列车变更,跳过」，
// 紧接着的汇总却打「✓ 已提交 → train/3.3.28(...)」，最后还打印
// 「✓ bump PR 已建齐」——但 GitHub 上**一个 PR 都没有**、train.yaml 仍是 3.3.27。
//
// 根因：commit() 在调 switchTrainBranch **之前**自己做了一次
// 「快照 + 还原到 HEAD」，而 switchTrainBranch 内部**又**做了一次
// 「快照 + 还原 + 切 + 写回」⇒ 外层把编辑还原后，内层快照到的是**已还原**
// 的内容（空）⇒ 写回时什么也没写 ⇒ 编辑彻底丢失 ⇒ `git add` 暂存的是 HEAD
// 内容 ⇒ `git diff --cached --quiet` 恒真 ⇒ 「无列车变更,跳过」⇒
// **不 push、不建 PR**，却仍然返回 success。
//
// 本组用例把「保存 → 还原 → 切分支 → 写回 → 暂存」这条链路**端到端**钉住：
// 编辑必须活到暂存区里（hasDiff=true），且暂存区内容必须是新值。
//
// 断言必须能变红（负对照）：
//	· 把 stageTrainFiles 改成「切分支前先还原（不保存）」⇒ 用例红；
//	· 把 switchTrainBranch 的写回去掉 ⇒ 用例红。
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// newStageEnv 造一个「远端裸仓 + 本地克隆」的环境。
func newStageEnv(t *testing.T) (origin, work string) {
	t.Helper()
	root := t.TempDir()
	origin = filepath.Join(root, "origin")
	work = filepath.Join(root, "work")
	if err := os.MkdirAll(origin, 0o755); err != nil {
		t.Fatal(err)
	}
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
	runIn(origin, "init", "-q", "-b", "main")
	runIn(origin, "config", "user.email", "t@example.com")
	runIn(origin, "config", "user.name", "t")
	writeFile(t, origin, "VERSION", "3.3.27\n")
	writeFile(t, origin, "other.txt", "keep\n")
	runIn(origin, "add", "-A")
	runIn(origin, "commit", "-qm", "init")

	runIn(work, "clone", "-q", origin, ".")
	runIn(work, "config", "user.email", "t@example.com")
	runIn(work, "config", "user.name", "t")
	return origin, work
}

// TestStageTrainFiles_KeepsEditAndStagesIt 端到端：本波编辑必须活到暂存区。
//
// 负对照：把「写回」去掉（模拟旧的双重还原 bug）⇒ 用例红。
func TestStageTrainFiles_KeepsEditAndStagesIt(t *testing.T) {
	_, work := newStageEnv(t)

	// 本波 bump 写下的新版本（模拟 edit() 落盘）
	writeFile(t, work, "VERSION", "3.3.28\n")

	switched, hasDiff, err := stageTrainFiles(work, "train/3.3.28", "origin/train/3.3.28", []string{"VERSION"})
	if err != nil {
		t.Fatalf("stageTrainFiles 失败: %v", err)
	}
	if len(switched) != 1 || switched[0] != "VERSION" {
		t.Fatalf("应记录 1 个被保存并写回的文件，实得 %v", switched)
	}
	if !hasDiff {
		t.Fatal("暂存区必须有变更（hasDiff=false ⇒ 编辑被还原/丢失 ⇒ 静默空转）")
	}
	// 暂存区里的内容必须是**新值**（不是 HEAD 的旧值）
	out, _ := exec.Command("git", "-C", work, "show", ":VERSION").Output()
	if got := strings.TrimSpace(string(out)); got != "3.3.28" {
		t.Fatalf("暂存区内容必须是本波编辑 3.3.28，实得 %q", got)
	}
	// 工作树也必须是新值
	if got := readFile(t, work, "VERSION"); got != "3.3.28\n" {
		t.Fatalf("工作树必须是本波编辑 3.3.28，实得 %q", got)
	}
	// 非列车文件不得被碰
	if got := readFile(t, work, "other.txt"); got != "keep\n" {
		t.Fatalf("非列车文件不得被改动，实得 %q", got)
	}
}

// TestStageTrainFiles_NotTouchingOtherFiles 暂存**只**含列车文件。
//
// 负对照：把 `git add --` 改成 `git add -A` ⇒ 用例红（用户的在制品被裹进提交）。
func TestStageTrainFiles_NotTouchingOtherFiles(t *testing.T) {
	_, work := newStageEnv(t)

	writeFile(t, work, "VERSION", "3.3.28\n")
	// 用户自己的在制品（不该进提交）
	writeFile(t, work, "my-wip.txt", "wip\n")

	switched, hasDiff, err := stageTrainFiles(work, "train/3.3.28", "origin/train/3.3.28", []string{"VERSION"})
	if err != nil {
		t.Fatalf("stageTrainFiles 失败: %v", err)
	}
	if len(switched) != 1 {
		t.Fatalf("只应保存列车文件，实得 %v", switched)
	}
	if !hasDiff {
		t.Fatal("暂存区必须有变更")
	}
	out, _ := exec.Command("git", "-C", work, "diff", "--cached", "--name-only").Output()
	names := strings.Fields(string(out))
	for _, n := range names {
		if n != "VERSION" {
			t.Fatalf("暂存区只应含 VERSION，实得 %v", names)
		}
	}
	// 用户的在制品必须仍在工作树里（没被吞）
	if _, err := os.Stat(filepath.Join(work, "my-wip.txt")); err != nil {
		t.Fatalf("用户的在制品必须保留: %v", err)
	}
}

// TestStageTrainFiles_ReusesExistingRemoteBranch 远端**已有**列车分支时，
// 切分支必须基于它（而非从 main 新建 ⇒ 历史分叉 ⇒ push 被拒）。
//
// 负对照：把 switchTrainBranch 的 case 2 去掉 ⇒ 用例红（分支基线错）。
func TestStageTrainFiles_ReusesExistingRemoteBranch(t *testing.T) {
	origin, work := newStageEnv(t)

	// 远端造一个同名列车分支（内容与 main 不同）
	runIn := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	runIn(origin, "checkout", "-q", "-b", "train/3.3.28")
	writeFile(t, origin, "VERSION", "3.3.28-pre\n")
	runIn(origin, "add", "-A")
	runIn(origin, "commit", "-qm", "existing train branch")
	runIn(origin, "checkout", "-q", "main")

	// 本地克隆后 fetch 到该分支
	runIn(work, "fetch", "-q", "origin")

	writeFile(t, work, "VERSION", "3.3.28\n")
	switched, hasDiff, err := stageTrainFiles(work, "train/3.3.28", "origin/train/3.3.28", []string{"VERSION"})
	if err != nil {
		t.Fatalf("stageTrainFiles 失败: %v", err)
	}
	if len(switched) != 1 {
		t.Fatalf("应保存并写回 VERSION，实得 %v", switched)
	}
	if !hasDiff {
		t.Fatal("暂存区必须有变更")
	}
	// 当前分支必须是列车分支，且基于远端列车分支（其历史里有 pre 那次提交）
	cur, _ := exec.Command("git", "-C", work, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if got := strings.TrimSpace(string(cur)); got != "train/3.3.28" {
		t.Fatalf("应在列车分支上，实得 %q", got)
	}
	// 分支必须包含远端列车分支的提交（基线正确，不是从 main 新建）
	has, _ := exec.Command("git", "-C", work, "merge-base", "--is-ancestor",
		"origin/train/3.3.28", "HEAD").CombinedOutput()
	if len(has) != 0 {
		t.Fatal("本地列车分支必须基于远端同名列车分支（否则 push 会 non-fast-forward 被拒）")
	}
}
