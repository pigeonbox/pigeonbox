// run_dry_test.go —— `trainctl run --dry-run` 只读预览的守卫(2026-11-13 事故收口)。
//
// 事故:Makefile 帮助称「train-run-local 缺省 dry-run 零落盘」,而 run 恒实际执行
// ⇒ 按预览跑 `make train-run-local TRAIN=5.8.0`,实际建了 10 仓 bump PR、合并、
// 推全部 tag。本文件钉住三件事:
//
//  1. **模式分派**:缺省=恒真执行(CI 编排器 train-orchestrator.yml 调 run 无 --push,
//     依赖此语义,一字不能改);--dry-run=只读;两者同给响亮拒绝。
//  2. **零 push**:dry 演练收到的 opts 必须是 push=false(所有落盘/建分支/建 PR
//     都由 runBump 的 push 门控)。
//  3. **不发 tag**:库线 [0] 解析(previewLibLine)只算不发——显式 --set 一个未发布
//     版本也绝不能把 tag 打出去。
//
// 负对照:
//
//	· runExecMode 缺省分支改成 dry ⇒ TestRunExecMode 缺省用例红(CI 真执行语义丢失);
//	· runDryWith 在 drill 前把 push 置 true ⇒ 零 push 用例红;
//	· previewLibLine 串上 ensureLibTag ⇒ 不发 tag 用例红(负对照里 ensureLibTag
//	  同一版本确实会建出 tag,证明断言咬合)。
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newDryRunHub 造一个带 release/train.yaml(已提交到 HEAD)的 hub 仓 Env。
// 全部钉版给齐 ⇒ 测试可走 --freeze-libs 解析,零网络。
func newDryRunHub(t *testing.T) *Env {
	t.Helper()
	root := t.TempDir()
	gitRun(t, root, "init", "-q", "-b", "main")
	gitRun(t, root, "config", "user.email", "t@example.com")
	gitRun(t, root, "config", "user.name", "t")
	if err := os.MkdirAll(filepath.Join(root, "release"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, root, "release/train.yaml", strings.Join([]string{
		"schema: \"1\"",
		"train: 5.8.0",
		"state: shipped",
		"lib.contracts: v0.23.0",
		"lib.core: v0.40.0",
		"lib.p2p: v0.9.6",
		"lib.frontend-core: v0.18.0",
		"",
	}, "\n"))
	gitRun(t, root, "add", "-A")
	gitRun(t, root, "commit", "-qm", "train snapshot")
	return &Env{Root: root}
}

// newContractsFixture 在 hub 仓旁造 contracts 检出:package.json 声明 0.99.0、
// **没有任何 tag**(=「仓内已升版、tag 未发」的现场)。
func newContractsFixture(t *testing.T, env *Env) {
	t.Helper()
	origin := filepath.Join(env.Root, "contracts-origin")
	work := filepath.Join(env.Root, "contracts")
	for _, d := range []string{origin, work} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, origin, "init", "-q", "-b", "main")
	gitRun(t, origin, "config", "user.email", "t@example.com")
	gitRun(t, origin, "config", "user.name", "t")
	gitRun(t, origin, "config", "receive.denyCurrentBranch", "ignore")
	writeFile(t, origin, "package.json", "{\"name\":\"@pigeonbox/contracts\",\"version\":\"0.99.0\"}\n")
	gitRun(t, origin, "add", "-A")
	gitRun(t, origin, "commit", "-qm", "bump to 0.99.0")
	gitRun(t, work, "clone", "-q", origin, ".")
	gitRun(t, work, "config", "user.email", "t@example.com")
	gitRun(t, work, "config", "user.name", "t")
}

// --dry-run 必须被解析出来,且解析本身不置 push(run 内部按模式分派)。
func TestParseBumpArgs_DryRun(t *testing.T) {
	o := parseBumpArgs([]string{"TRAIN=5.8.0", "--dry-run", "--freeze-libs"})
	if !o.dryRun {
		t.Fatal("--dry-run 未被解析(dry 路径永远进不去 ⇒ 预览只能真执行)")
	}
	if o.push {
		t.Fatal("解析本身不应置 push(与 TestParseBumpArgs 同口径)")
	}
	// 缺省不带 --dry-run ⇒ dryRun=false(CI 编排器走真执行)。
	if parseBumpArgs([]string{"TRAIN=5.8.0"}).dryRun {
		t.Fatal("缺省不得是 dry-run(run 恒真执行是 CI 编排器的依赖)")
	}
}

// runExecMode:缺省=(false,true) 恒真执行;--dry-run=(true,false);同给=error。
//
// 负对照:把缺省分支改成 dry ⇒ 第一组断言红(CI 编排器的 run 将不再执行)。
func TestRunExecMode(t *testing.T) {
	cases := []struct {
		name string
		o    bumpOpts
		dry  bool
		push bool
		err  bool
	}{
		{"缺省=恒真执行(CI 编排器依赖)", bumpOpts{train: "5.8.0"}, false, true, false},
		{"--dry-run=只读预览", bumpOpts{train: "5.8.0", dryRun: true}, true, false, false},
		{"两者同给=互斥", bumpOpts{train: "5.8.0", dryRun: true, push: true}, false, false, true},
	}
	for _, c := range cases {
		dry, push, err := runExecMode(c.o)
		if c.err {
			if err == nil {
				t.Errorf("%s: 应报错(矛盾参数不许静默择一)", c.name)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: 不该报错: %v", c.name, err)
			continue
		}
		if dry != c.dry || push != c.push {
			t.Errorf("%s: runExecMode=(dry=%v,push=%v), 期望 (dry=%v,push=%v)",
				c.name, dry, push, c.dry, c.push)
		}
	}
}

// dry 演练收到的 opts 必须 push=false —— 零 push 的缝级断言
// (runBump 的分支/提交/PR/自动合并全部由 push 门控)。
func TestRunDry_DrillReceivesNoPush(t *testing.T) {
	env := newDryRunHub(t)
	o := bumpOpts{train: "9.9.9", freezeLibs: true, sets: map[string]string{}}
	var got []bumpOpts
	runDryWith(env, o, func(_ *Env, oo bumpOpts) { got = append(got, oo) })
	if len(got) != 1 {
		t.Fatalf("bump 演练应恰好被调 1 次,实得 %d 次", len(got))
	}
	if got[0].push {
		t.Fatal("dry 演练收到 push=true —— 零 push 契约被破坏(会建分支/PR)")
	}
	// [0] 库线解析结果必须回填给 bump(共享同一套解析,避免二次解析漂移)。
	if got[0].libVersions["lib.contracts"] != "v0.23.0" {
		t.Fatalf("演练应拿到回填的库线钉版 v0.23.0,实得 %q", got[0].libVersions["lib.contracts"])
	}
}

// previewLibLine:显式 --set 一个**未发布**版本 ⇒ 解析得出「将发布」,但绝不建 tag。
//
// 负对照:同一版本走 ensureLibTag(allowCreate=true) 会真的建出 tag ——
// 证明上面的「不建 tag」断言在缺陷态会红(而不是因为建不出来才绿)。
func TestPreviewLibLine_NoTagCreation(t *testing.T) {
	env := newDryRunHub(t)
	newContractsFixture(t, env)
	o := bumpOpts{train: "9.9.9", freezeLibs: true, sets: map[string]string{"contracts": "v0.99.0"}}

	res, err := previewLibLine(env, &o)
	if err != nil {
		t.Fatalf("previewLibLine 失败: %v", err)
	}
	// 正判据:预览要把「将发布什么」算出来(只打印,不发)。
	if res.versions["lib.contracts"] != "v0.99.0" {
		t.Fatalf("显式 --set contracts=v0.99.0 应解析为 v0.99.0,实得 %q", res.versions["lib.contracts"])
	}
	// 零创建:dry 路径不得打 tag。
	if env.TagExists("contracts", "v0.99.0") {
		t.Fatal("previewLibLine 不得创建 tag(--set 未发布版本在 dry 路径只许打印)")
	}

	// 负对照:真执行路径的 ensureLibTag 会建出同一 tag。
	lr := libTestRepo(t, "contracts")
	created, err := ensureLibTag(env, lr, "v0.99.0", true)
	if err != nil {
		t.Fatalf("负对照 ensureLibTag 失败: %v", err)
	}
	if !created || !env.TagExists("contracts", "v0.99.0") {
		t.Fatal("负对照:ensureLibTag 应创建 v0.99.0 —— 否则本用例测不到「不创建」(假绿)")
	}
}

// 收尾报文词面即契约:操作者必须能一眼确认什么都没发。
func TestDryRunDoneMsg_Contract(t *testing.T) {
	for _, want := range []string{"未发 tag", "未推 PR", "未等待"} {
		if !strings.Contains(dryRunDoneMsg, want) {
			t.Errorf("dry-run 收尾报文缺 %q(词面即契约): %s", want, dryRunDoneMsg)
		}
	}
}
