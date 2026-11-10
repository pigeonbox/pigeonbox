// bump_restore_branches_test.go restoreBranches 的「每个 bump 仓都必须还原回
// 默认分支」回归（pigeonbox#337）。
//
// 事故形态：restoreBranches 手写 pairs 表漏了 server ⇒ def 取到空串 ⇒
// `git checkout -q ""` 失败 ⇒ server 留在 train/<v> 上——正是该函数要防的坑。
//
// 断言全部是结构事实（分支名、error 非 nil、源码级单源守卫），不依赖文案。
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setupBumpRepos 造「bump 切完分支后」的现场：每个 bumpRepos 仓（含 hub 自身）
// 都停在 train/9.9.9，默认分支按 defBranch() 建好。
func setupBumpRepos(t *testing.T) *Env {
	t.Helper()
	root := t.TempDir()
	initRepo(t, root, defBranch(".")) // hub 自身(".")
	for _, r := range bumpRepos {
		if r == "." {
			continue
		}
		initRepo(t, filepath.Join(root, r), defBranch(r))
	}
	for _, r := range bumpRepos {
		dir := root
		if r != "." {
			dir = filepath.Join(root, r)
		}
		runGitIn(t, dir, "checkout", "-q", "-b", "train/9.9.9")
	}
	return &Env{Root: root}
}

func repoDirOf(t *testing.T, env *Env, r string) string {
	t.Helper()
	dir, ok := env.RepoDir(r)
	if !ok {
		t.Fatalf("仓 %q 应可解析", r)
	}
	return dir
}

func currentBranch(t *testing.T, dir string) string {
	t.Helper()
	out, err := Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// TestRestoreBranches_AllBumpReposBackToDefault 每个 bumpRepos 仓（含 server）
// 都必须还原回默认分支。
//
// 负对照（回退修复即红）：恢复漏 server 的 pairs 表 ⇒ server 停在 train/9.9.9 ⇒ 红。
func TestRestoreBranches_AllBumpReposBackToDefault(t *testing.T) {
	env := setupBumpRepos(t)
	b := &bumper{env: env}
	if err := b.restoreBranches(); err != nil {
		t.Fatalf("restoreBranches 不该失败: %v", err)
	}
	for _, r := range bumpRepos {
		cur := currentBranch(t, repoDirOf(t, env, r))
		if cur != defBranch(r) {
			t.Errorf("仓 %q 还原后应在 %q,实得 %q(server 漏还原就是 pigeonbox#337)", r, defBranch(r), cur)
		}
	}
}

// TestRestoreBranches_FailureIsLoud 还原失败必须报错（只告警 = 仓留在列车分支
// 而命令照常成功,CI/后续流程无感知）。逐仓尽力还原:失败的仓不阻断其它仓。
//
// 负对照（改坏即红）：把 error 吞掉（只 warn）⇒ err==nil ⇒ 红。
func TestRestoreBranches_FailureIsLoud(t *testing.T) {
	env := setupBumpRepos(t)
	// 制造一个必然还原失败的仓:默认分支不存在
	runGitIn(t, repoDirOf(t, env, "qnap"), "branch", "-D", defBranch("qnap"))
	b := &bumper{env: env}
	if err := b.restoreBranches(); err == nil {
		t.Fatal("还原失败必须报错（判不了/还原不了 ⇒ 显式失败,不许静默放行）")
	}
	// 其它仓仍尽力还原(server 必须回到默认分支)
	if cur := currentBranch(t, repoDirOf(t, env, "server")); cur != defBranch("server") {
		t.Fatalf("失败的仓不阻断其它仓:server 应回 %q,实得 %q", defBranch("server"), cur)
	}
}

// TestRestoreBranches_UsesDefBranchSingleSource 机械守卫:「仓→默认分支」必须
// 走 defBranch() 单一真相源,不得再出现手写映射表——第四份清单必漂移
// （pigeonbox#337 的根因正是那张表漏了 server,且无任何一致性约束）。
//
// 断言的是源码结构（有没有调单一真相源 / 有没有手写字面量），不依赖文案。
func TestRestoreBranches_UsesDefBranchSingleSource(t *testing.T) {
	src, err := os.ReadFile("bump.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(src)
	start := strings.Index(text, "func (b *bumper) restoreBranches(")
	if start < 0 {
		t.Fatal("找不到 restoreBranches")
	}
	end := strings.Index(text[start:], "\nfunc ")
	if end < 0 {
		end = len(text) - start
	}
	body := text[start : start+end]
	if !strings.Contains(body, "defBranch(") {
		t.Error("restoreBranches 的默认分支必须取自 defBranch()（单一真相源）")
	}
	for _, forbidden := range []string{`"fnos": "master"`, `"frontend": "main"`, `"server": "main"`} {
		if strings.Contains(body, forbidden) {
			t.Errorf("restoreBranches 不得手写仓→分支映射（%s）——手写清单会漂移（pigeonbox#337）", forbidden)
		}
	}
}
