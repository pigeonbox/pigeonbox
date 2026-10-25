package main

import (
	"os/exec"
	"strings"
	"testing"
)

// TestSwitchTrainBranch_KeepsBranchNewerContent 同一列车号**重跑 bump**时，
// 分支上已有的（上一趟 bump 写下的）更新**不得被本波编辑覆盖**。
//
// 实测事故（2026-10-25，列车 3.3.31）：
//
//	· 第一趟 bump 把 frontend 的 package.json 版本抬到 3.3.31、VERSION 抬到 3.3.31；
//	· 重跑 bump 时「server 未变」⇒ 版本编辑被跳过 ⇒ 本波编辑里**没有**版本那一行；
//	  而本波编辑的 base 取自 **main**（此时前一趟的 PR 还没合 ⇒ main 上版本仍是 3.3.30）；
//	· 切到分支后若「直接写回快照」= 用 main 的内容**盖掉**分支上的 3.3.31
//	  ⇒ package.json 版本退回 3.3.30，而 VERSION 文件不在本波编辑里 ⇒ 幸免于难
//	  ⇒ **两处版本元数据分叉** ⇒ 终判「frontend 源码版本(3.3.30)与 tag(v3.3.31)
//	  不同号」⇒ 镜像构建被硬门拦下（这道门禁是有效的）。
//
// ⇒ 写回必须是**打补丁**（`git apply --3way`：把「本波编辑相对 HEAD 的增量」打到
//
//	分支内容上）⇒ 两边的改动都在；真冲突 ⇒ **响亮失败**，不静默覆盖。
//
// 负对照：把写回改回「直接覆盖快照」⇒ 本用例红。
func TestSwitchTrainBranch_KeepsBranchNewerContent(t *testing.T) {
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
	writeFile(t, dir, "package.json", jsonPkg("3.3.30", "v0.11.23"))
	run("add", "-A")
	run("commit", "-qm", "init")

	// 分支上已有「上一趟 bump」写下的更新（版本抬到 3.3.31）
	run("checkout", "-q", "-b", "train/3.3.31")
	writeFile(t, dir, "package.json", jsonPkg("3.3.31", "v0.11.23"))
	run("add", "-A")
	run("commit", "-qm", "bump 3.3.31")
	run("checkout", "-q", "main")

	// 本波编辑（在 main 之上）：把 tgz 钉版抬到新版本（**不动版本号**）
	writeFile(t, dir, "package.json", jsonPkg("3.3.30", "v0.11.25"))

	if _, err := switchTrainBranch(dir, "train/3.3.31", "origin/train/3.3.31", []string{"package.json"}); err != nil {
		t.Fatalf("switchTrainBranch 失败: %v", err)
	}
	got := readFile(t, dir, "package.json")
	if !strings.Contains(got, `"version": "3.3.31"`) {
		t.Errorf("分支上已有的版本更新（3.3.31）被本波编辑覆盖了，实得:\n%s", got)
	}
	if !strings.Contains(got, "download/v0.11.25/frontend-core.tgz") {
		t.Errorf("本波编辑丢失，实得:\n%s", got)
	}
}

// TestSwitchTrainBranch_BranchUnchanged 分支未改动该文件时，本波编辑正常落地。
func TestSwitchTrainBranch_BranchUnchanged(t *testing.T) {
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
	writeFile(t, dir, "VERSION", "3.3.30\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	writeFile(t, dir, "VERSION", "3.3.31\n")
	if _, err := switchTrainBranch(dir, "train/3.3.31", "origin/train/3.3.31", []string{"VERSION"}); err != nil {
		t.Fatalf("switchTrainBranch 失败: %v", err)
	}
	if got := readFile(t, dir, "VERSION"); got != "3.3.31\n" {
		t.Errorf("本波编辑未落地，实得 %q", got)
	}
}

// TestSwitchTrainBranch_ConflictTakesThisWave 真冲突（同一处两边都改）时，
// **以本波的值为准**（列车的版本/钉版以本波声明为准），且**告警**（不静默）。
func TestSwitchTrainBranch_ConflictTakesThisWave(t *testing.T) {
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
	writeFile(t, dir, "f.txt", "line1\nline2\nline3\n")
	run("add", "-A")
	run("commit", "-qm", "init")

	// 分支把第 2 行改成 A，本波编辑把第 2 行改成 B ⇒ 真冲突
	run("checkout", "-q", "-b", "train/3.3.31")
	writeFile(t, dir, "f.txt", "line1\nBRANCH\nline3\n")
	run("add", "-A")
	run("commit", "-qm", "branch edit")
	run("checkout", "-q", "main")
	writeFile(t, dir, "f.txt", "line1\nTHISWAVE\nline3\n")

	if _, err := switchTrainBranch(dir, "train/3.3.31", "origin/train/3.3.31", []string{"f.txt"}); err != nil {
		t.Fatalf("冲突应以本波值为准落地，不该失败: %v", err)
	}
	got := readFile(t, dir, "f.txt")
	if !strings.Contains(got, "THISWAVE") {
		t.Errorf("冲突处应以本波值为准，实得:\n%s", got)
	}
	if strings.Contains(got, "<<<<<<<") {
		t.Errorf("产物里不得残留冲突标记，实得:\n%s", got)
	}
}

// jsonPkg 造一个**多行**的 package.json（镜像真实文件：版本号与 tgz 钉版相隔
// 足够远 ⇒ 两处改动落在不同 hunk ⇒ 三方合并能自动合上）。
func jsonPkg(version, fc string) string {
	return "{\n" +
		"  \"name\": \"pigeonbox-frontend\",\n" +
		"  \"private\": true,\n" +
		"  \"version\": \"" + version + "\",\n" +
		"  \"type\": \"module\",\n" +
		"  \"scripts\": {\n" +
		"    \"dev\": \"vite\",\n" +
		"    \"build\": \"vite build\",\n" +
		"    \"typecheck\": \"vue-tsc --noEmit -p tsconfig.app.json\"\n" +
		"  },\n" +
		"  \"dependencies\": {\n" +
		"    \"@pigeonbox/frontend-core\": \"https://example/releases/download/" + fc + "/frontend-core.tgz\"\n" +
		"  }\n" +
		"}\n"
}
