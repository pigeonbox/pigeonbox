// env_raw_test.go Env.Raw 的「陈旧读数不得冒充真值」回归（pigeonbox#326）。
//
// 事故形态（issue 实测）：fetch 失败被 `_, _ =` 吞掉 ⇒ 回落读**上一次 fetch 的
// 旧 origin/<ref>**（err=nil）⇒ 对账拿陈旧值判绿 ⇒ 发版门禁在网络抖动的时刻
// 静默放行。第二处同族：本地 <ref> 回落在 tag 被重打后读到旧 tag 对象。
//
// 断言全部是结构事实（错误可分类 errors.Is / 返回值为空 / 读到远端真值），
// 不依赖任何文案。
package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runGitIn 在 dir 下跑 git，失败即中止测试。
func runGitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// initRepo 在 dir 建一个带初始提交的 git 仓（分支名 branch）。
func initRepo(t *testing.T, dir, branch string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitIn(t, dir, "init", "-q", "-b", branch)
	runGitIn(t, dir, "config", "user.email", "t@example.com")
	runGitIn(t, dir, "config", "user.name", "t")
	writeFile(t, dir, "go.mod", "module x\n")
	runGitIn(t, dir, "add", "-A")
	runGitIn(t, dir, "commit", "-qm", "init")
}

// writeTrainFile 在 hub 根写最小 train.yaml。
func writeTrainFile(t *testing.T, root, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "release"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "release", "train.yaml"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestRaw_FetchFailureIsUnavailableAndNeverStale 路径 A 的直接反证：
// fetch 失败 ⇒ 必须报错、错误必须归类「判据不可用」、**绝不**返回本地陈旧内容。
//
// 负对照（回退修复即红）：恢复旧实现的「`_, _ =` 吞 fetch 错误 + 回落
// origin/<ref> / 本地 <ref>」⇒ 本用例红（err=nil 且返回陈旧 go.mod）。
func TestRaw_FetchFailureIsUnavailableAndNeverStale(t *testing.T) {
	root := t.TempDir()
	repo := filepath.Join(root, "core")
	initRepo(t, repo, "main")
	// origin 指向死路径 ⇒ fetch 必失败（本地路径错误：快、不依赖网络）
	runGitIn(t, repo, "remote", "add", "origin", filepath.Join(root, "no-such-remote.git"))
	// 本地分支上放一个醒目的「陈旧值」——旧实现会把它冒充真值返回
	writeFile(t, repo, "go.mod", "module stale-value-must-never-leak\n")
	runGitIn(t, repo, "add", "-A")
	runGitIn(t, repo, "commit", "-qm", "stale")

	env := &Env{Root: root}
	out, err := env.Raw("core/main/go.mod")
	if err == nil {
		t.Fatalf("fetch 失败必须报错（判据不可用），实得 nil；读数=%q", out)
	}
	if !errors.Is(err, ErrCriteriaUnavailable) {
		t.Fatalf("错误必须可归类为 ErrCriteriaUnavailable（显式错误分类），实得 %v", err)
	}
	if out != "" {
		t.Fatalf("fetch 失败不得返回任何读数（陈旧值冒充真值），实得 %q", out)
	}
}

// TestRaw_ReadsFetchedTruthNotStaleLocalRefs 读数必须是「本次 fetch 的真值」：
//   - 远端推进后本地未 pull ⇒ 读到远端新值（不是本地旧值）；
//   - 克隆之后才打的 tag ⇒ 本地引用读不到，也必须读到（不是 CDN 404）；
//   - tag 被重打 ⇒ 读到重打后的新值（本地 refs/tags 是旧对象，实测）。
//
// 负对照（回退修复即红）：恢复旧读取链（origin/<ref> → 本地 <ref> → CDN）⇒
// 重打 tag 用例红（读到本地旧 tag 的内容）。
func TestRaw_ReadsFetchedTruthNotStaleLocalRefs(t *testing.T) {
	root := t.TempDir()
	origin := filepath.Join(root, "origin.git")
	seed := filepath.Join(root, "seed")
	work := filepath.Join(root, "core") // 生产布局:<hub根>/<repo>
	runGitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
	initRepo(t, seed, "main")
	runGitIn(t, seed, "remote", "add", "origin", origin)
	runGitIn(t, seed, "push", "-q", "-u", "origin", "main")
	runGitIn(t, root, "clone", "-q", origin, work)

	env := &Env{Root: root}

	// ① 远端推进,本地不 pull ⇒ 必须读到远端新值
	writeFile(t, seed, "go.mod", "module fresh-value\n")
	runGitIn(t, seed, "add", "-A")
	runGitIn(t, seed, "commit", "-qm", "bump")
	runGitIn(t, seed, "push", "-q", "origin", "main")
	if out, err := env.Raw("core/main/go.mod"); err != nil || strings.TrimSpace(out) != "module fresh-value" {
		t.Fatalf("分支读数必须是 fetch 后的远端真值,实得 %q err=%v", out, err)
	}

	// ② 克隆后才打的 annotated tag ⇒ 本地引用读不到,也必须读到
	runGitIn(t, seed, "tag", "-a", "v1", "-m", "t")
	runGitIn(t, seed, "push", "-q", "origin", "v1")
	if out, err := env.Raw("core/v1/go.mod"); err != nil || strings.TrimSpace(out) != "module fresh-value" {
		t.Fatalf("tag 读数必须取自本次 fetch(FETCH_HEAD),实得 %q err=%v", out, err)
	}

	// ③ 重打 tag ⇒ 必须读到新值(本地 refs/tags 是旧对象,读它=陈旧冒充真值)
	writeFile(t, seed, "go.mod", "module retag-value\n")
	runGitIn(t, seed, "add", "-A")
	runGitIn(t, seed, "commit", "-qm", "retag")
	runGitIn(t, seed, "tag", "-f", "-a", "v1", "-m", "t")
	runGitIn(t, seed, "push", "-q", "-f", "origin", "refs/tags/v1")
	if out, err := env.Raw("core/v1/go.mod"); err != nil || strings.TrimSpace(out) != "module retag-value" {
		t.Fatalf("重打 tag 后读数必须是新值,实得 %q err=%v(读到陈旧本地 tag?)", out, err)
	}
}
