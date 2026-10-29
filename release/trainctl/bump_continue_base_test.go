package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestSwitchTrainBranch_ContinueRunBasesOnOriginDefault 锁住 hub#163：
//
//	**同车次续跑**（上一轮 bump 的 PR 已合并 ⇒ GitHub 删掉了远端 train/<v> 分支）
//	时，新建列车分支必须以 **origin/<该仓默认分支>** 为基线，
//	而不是「当前 HEAD」。
//
// 实测事故（2026-10-28，4.0.7 列车改钉版 p2p v0.9.4→v0.9.5）：5 个仓的 PR
// 全部 CONFLICTING，需人工逐仓 rebase + force push。
//
// 根因：远端 train/<v> 不存在 ⇒ 旧实现走「从当前 HEAD 建同名分支」⇒ 而当前
// HEAD（本地 main）**落后于 origin/main**（origin/main 里已含上一轮 bump 的
// 合并提交）⇒ 历史分叉 ⇒ push 时 GitHub 判 CONFLICTING。
//
// ⇒ 正解：以 origin/<默认分支> 为基线建分支 ⇒ 分支天然基于最新 main ⇒ 无冲突。
//
// 本用例搭一个**带真实 remote 的裸仓**（origin 是本地另一目录 ⇒ fetch 真实生效）：
//
//	· origin/main 上有「上一轮 bump 的合并提交」；
//	· 本地 HEAD 停在**更早**的提交上（模拟本地没 pull）；
//	· 远端 train/<v> 分支**不存在**（模拟 PR 合并后 GitHub 删分支）。
//
// 断言：新分支的基线是 origin/main 的提交，**不含**上一轮 bump 的合并提交
// （否则就是分叉 ⇒ 必冲突）。
//
// 负对照：把实现改回「从当前 HEAD 建分支」⇒ 本用例红。
func TestSwitchTrainBranch_ContinueRunBasesOnOriginDefault(t *testing.T) {
	root := t.TempDir()
	origin := filepath.Join(root, "origin.git")
	work := filepath.Join(root, "work")

	// ── 起一个 bare remote ──
	runIn(t, root, "init", "-q", "--bare", origin)

	// ── 克隆出工作仓，写入「初始」提交 ──
	runIn(t, root, "clone", "-q", origin, work)
	runIn(t, work, "config", "user.email", "t@example.com")
	runIn(t, work, "config", "user.name", "t")
	runIn(t, work, "branch", "-M", "main")
	writeFile(t, work, "VERSION", "4.0.7\n")
	runIn(t, work, "add", "-A")
	runIn(t, work, "commit", "-qm", "init")
	runIn(t, work, "push", "-q", "origin", "main")

	// ── 造出「上一轮 bump 的合并提交」并推到 origin/main ──
	// 真实场景：上一轮 bump 的 PR 被合并 ⇒ 它的内容进了 origin/main，
	// 且 GitHub 删掉了远端 train/<v> 分支。
	writeFile(t, work, "train.yaml", "train: 4.0.8\n")
	runIn(t, work, "add", "-A")
	runIn(t, work, "commit", "-qm", "train: bump to 4.0.8 (上一轮，已合并)")
	runIn(t, work, "push", "-q", "origin", "main")

	// ── 本地**不**拉取 ⇒ 本地 HEAD 落后于 origin/main ──
	// 这正是 #163 的触发条件（本地没 pull / 上一轮合并提交只在远端）。
	runIn(t, work, "reset", "-q", "--hard", "HEAD~1")

	// ── 远端 train/<v> 分支**不存在**（PR 合并后 GitHub 删分支）──
	// 本地也没有同名分支 ⇒ 走 switchTrainBranch 的 default 分支。

	// 本波编辑：把版本抬到 4.0.9
	writeFile(t, work, "VERSION", "4.0.9\n")

	if _, err := switchTrainBranch(work, "train/4.0.9", "origin/train/4.0.9", []string{"VERSION"}); err != nil {
		t.Fatalf("switchTrainBranch 失败: %v", err)
	}

	// 断言 1：分支基线必须是 origin/main（含「上一轮 bump 的合并提交」）。
	head, err := exec.Command("git", "-C", work, "rev-parse", "HEAD").CombinedOutput()
	if err != nil {
		t.Fatalf("git rev-parse HEAD: %v\n%s", err, head)
	}
	originMain, err := exec.Command("git", "-C", work, "rev-parse", "origin/main").CombinedOutput()
	if err != nil {
		t.Fatalf("git rev-parse origin/main: %v\n%s", err, originMain)
	}
	if strings.TrimSpace(string(head)) != strings.TrimSpace(string(originMain)) {
		t.Errorf("续跑新建的分支未以 origin/main 为基线\n  HEAD       = %s\n  origin/main= %s\n  (以当前 HEAD 建分支 ⇒ 历史分叉 ⇒ push 必 CONFLICTING)",
			strings.TrimSpace(string(head)), strings.TrimSpace(string(originMain)))
	}

	// 断言 2：分支历史里必须含「上一轮 bump 的合并提交」
	// （证明基线是**最新** main，而不是本地那个旧的 HEAD）。
	log, err := exec.Command("git", "-C", work, "log", "--oneline", "-3").CombinedOutput()
	if err != nil {
		t.Fatalf("git log: %v\n%s", err, log)
	}
	if !strings.Contains(string(log), "上一轮") {
		t.Errorf("分支基线不含 origin/main 上「上一轮 bump 的合并提交」⇒ 基线取错了，实得:\n%s", log)
	}

	// 断言 3：本波编辑仍要落地（不能因为换了基线就丢编辑）。
	got := readFile(t, work, "VERSION")
	if got != "4.0.9\n" {
		t.Errorf("本波编辑未落地，实得 %q", got)
	}
}

// TestOriginBaseBranch_UsesRemoteDefaultBranch originBaseBranch 必须问 remote
// 自己「默认分支是谁」（origin/HEAD），而不是硬编码 main。
//
// 硬编码 main 的危害：fnos 的默认分支是 **master** ⇒ 取 origin/main 会取不到
// ⇒ 静默退回「当前 HEAD」⇒ #163 在 fnos 上原样复发。
func TestOriginBaseBranch_UsesRemoteDefaultBranch(t *testing.T) {
	root := t.TempDir()
	origin := filepath.Join(root, "origin.git")
	work := filepath.Join(root, "work")

	runIn(t, root, "init", "-q", "--bare", origin)
	runIn(t, root, "clone", "-q", origin, work)
	runIn(t, work, "config", "user.email", "t@example.com")
	runIn(t, work, "config", "user.name", "t")
	writeFile(t, work, "f.txt", "x\n")
	runIn(t, work, "add", "-A")
	runIn(t, work, "commit", "-qm", "init")
	runIn(t, work, "branch", "-M", "master")
	runIn(t, work, "push", "-q", "origin", "master")
	// 设 origin/HEAD ⇒ git 认为默认分支是 master（模拟 fnos 那样的 master 仓）
	runIn(t, work, "remote", "set-head", "origin", "master")

	ref, err := originBaseBranch(work)
	if err != nil {
		t.Fatalf("originBaseBranch 失败: %v", err)
	}
	if ref != "origin/master" {
		t.Errorf("默认分支探测错，实得 %q，期望 %q", ref, "origin/master")
	}
}

// runIn 在指定目录跑 git 命令，失败即测试失败（附带输出）。
func runIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v (dir=%s): %v\n%s", args, dir, err, out)
	}
}
