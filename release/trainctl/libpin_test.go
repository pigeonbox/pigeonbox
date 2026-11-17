// libpin_test.go —— 库线 tag 钉版对账闸的守卫与负对照。
//
// 负对照清单（每条都必须能变红，否则闸门形同虚设）：
//
//	· 把 libPinMismatch 的「逐字相等」放宽成「不更旧」⇒ 「声明更新版」用例红；
//	· 把 libPinMismatch 的比较整个去掉（恒返回空）⇒ 「声明陈旧版」用例红；
//	· 把 assertLibPinsAt 的「读不到 ⇒ 失败」改成静默放行 ⇒ 「判据不可用」用例红；
//	· 把 ensureLibTag 里的对账调用去掉 ⇒ 「零 tag 推出」用例红（tag 会被建出来）。
package main

import (
	"strings"
	"testing"
)

// libGomod 造一份 go.mod 内容（pins 为 require 行）。
func libGomod(pins ...string) string {
	var b strings.Builder
	b.WriteString("module github.com/pigeonbox/core\n\ngo 1.26.5\n\nrequire (\n")
	for _, p := range pins {
		b.WriteString("\t" + p + "\n")
	}
	b.WriteString(")\n")
	return b.String()
}

// ───────────────────────── 纯判据 ─────────────────────────

// 声明的钉版**陈旧**（本趟期望更新）⇒ 判红。
//
// 这正是 6.5.0 实录的形态：core 仍钉 contracts v0.25.0，本趟随车抬到 v0.26.0。
func TestLibPinMismatch_DetectsStalePin(t *testing.T) {
	versions := map[string]string{"lib.contracts": "v0.26.0"}
	msg := libPinMismatch(versions, "core", libGomod("github.com/pigeonbox/contracts v0.25.0"))
	if msg == "" {
		t.Fatal("声明陈旧钉版(contracts v0.25.0 ≠ 本趟 v0.26.0)必须判红")
	}
	if !strings.Contains(msg, "v0.25.0") || !strings.Contains(msg, "v0.26.0") {
		t.Fatalf("判红文案应点名两侧版本,实得 %q", msg)
	}
}

// 声明的钉版**更新**于本趟期望 ⇒ 同样判红（MVS 会把更新版带进构建 ⇒ 本趟
// 宣称的 lib.* 是假的）。
//
// 负对照:把「逐字相等」放宽成「不更旧」⇒ 本用例红。
func TestLibPinMismatch_DetectsNewerPin(t *testing.T) {
	versions := map[string]string{"lib.contracts": "v0.26.0"}
	msg := libPinMismatch(versions, "core", libGomod("github.com/pigeonbox/contracts v0.27.0"))
	if msg == "" {
		t.Fatal("声明更新钉版(contracts v0.27.0 ≠ 本趟 v0.26.0)必须判红——本趟宣称的 lib.* 会是假的")
	}
}

// 逐字相等 ⇒ 放行。
func TestLibPinMismatch_AcceptsExactPin(t *testing.T) {
	versions := map[string]string{"lib.contracts": "v0.26.0"}
	if msg := libPinMismatch(versions, "core", libGomod("github.com/pigeonbox/contracts v0.26.0")); msg != "" {
		t.Fatalf("钉版逐字相等时应放行,实得 %q", msg)
	}
}

// 本趟不涉及的库线（如 kit 已归档）⇒ 不判（不是错位，是这条依赖不在列车面内）。
func TestLibPinMismatch_SkipsLibNotInTrain(t *testing.T) {
	versions := map[string]string{"lib.contracts": "v0.26.0"}
	if msg := libPinMismatch(versions, "core", libGomod("github.com/pigeonbox/kit v0.3.1")); msg != "" {
		t.Fatalf("本趟无期望的库线应跳过,实得 %q", msg)
	}
}

// 空期望集（只读预览路径）⇒ 全不判。
func TestLibPinMismatch_EmptyVersionsSkipsAll(t *testing.T) {
	if msg := libPinMismatch(nil, "core", libGomod("github.com/pigeonbox/contracts v0.25.0")); msg != "" {
		t.Fatalf("空期望集应全跳过,实得 %q", msg)
	}
}

// 本仓自己的子模块路径（core/gen）⇒ 不是「对库线的依赖」⇒ 不判。
func TestLibPinMismatch_IgnoresOwnSubmodule(t *testing.T) {
	versions := map[string]string{"lib.core": "v0.47.0"}
	if msg := libPinMismatch(versions, "core", libGomod("github.com/pigeonbox/core/gen v0.46.0")); msg != "" {
		t.Fatalf("自身子模块路径不应参与库线对账,实得 %q", msg)
	}
}

// ───────────────────────── 接线（IO 路径） ─────────────────────────

// assertLibPinsAt：读 tag 上的 go.mod 对账——陈旧 ⇒ 失败；一致 ⇒ 放行。
func TestAssertLibPinsAt_RefusesStalePin(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{
		"v0.46.0": "go.mod=" + libGomod("github.com/pigeonbox/contracts v0.25.0"),
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	err := assertLibPinsAt(env, map[string]string{"lib.contracts": "v0.26.0"}, lr, "v0.46.0")
	if err == nil {
		t.Fatal("tag 上声明陈旧钉版时必须失败")
	}
	if !strings.Contains(err.Error(), "钉版对账失败") {
		t.Fatalf("失败文案应点明是钉版对账,实得 %v", err)
	}
	if err := assertLibPinsAt(env, map[string]string{"lib.contracts": "v0.25.0"}, lr, "v0.46.0"); err != nil {
		t.Fatalf("钉版一致时应放行,实得 %v", err)
	}
}

// 判据不可用（ref 不存在 ⇒ 读不到 go.mod）⇒ 失败（没核对 ≠ 通过）。
//
// 负对照:把「读不到 ⇒ 失败」改成静默放行 ⇒ 本用例红。
func TestAssertLibPinsAt_RefusesUnreadable(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{
		"v0.46.0": "go.mod=" + libGomod("github.com/pigeonbox/contracts v0.25.0"),
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	if err := assertLibPinsAt(env, map[string]string{"lib.contracts": "v0.26.0"}, lr, "v9.9.9"); err == nil {
		t.Fatal("ref 不存在(判据不可用)时必须失败")
	}
}

// 该 ref 上没有 go.mod（不是 Go 模块）⇒ 跳过，不判红。
func TestAssertLibPinsAt_SkipsRepoWithoutGoMod(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{"v0.46.0": "README.md=x\n"})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	if err := assertLibPinsAt(env, map[string]string{"lib.contracts": "v0.26.0"}, lr, "v0.46.0"); err != nil {
		t.Fatalf("没有 go.mod 的仓应跳过对账,实得 %v", err)
	}
}

// 非 Go 模块库线（frontend-core 是 npm 包）⇒ 直接跳过。
func TestAssertLibPinsAt_SkipsNonGoModule(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "frontend-core", map[string]string{"v0.22.0": "VERSION=0.22.0\n"})
	env := &Env{Root: root}
	lr := libTestRepo(t, "frontend-core")

	if err := assertLibPinsAt(env, map[string]string{"lib.contracts": "v0.26.0"}, lr, "v0.22.0"); err != nil {
		t.Fatalf("非 Go 模块库线应跳过对账,实得 %v", err)
	}
}

// ───────────────────────── 端到端（打 tag 前） ─────────────────────────

// ensureLibTag：钉版对账不过 ⇒ **零 tag 推出**（tag 不得建出来）。
//
// 负对照:把 ensureLibTag 里的对账调用去掉 ⇒ 本用例红（tag 会被建出来）。
func TestEnsureLibTag_RefusesPinMismatch_NoTagCreated(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{
		"v0.46.0": "go.mod=" + libGomod("github.com/pigeonbox/contracts v0.25.0"),
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	versions := map[string]string{"lib.contracts": "v0.26.0", "lib.core": "v0.47.0"}
	if _, err := ensureLibTag(env, versions, lr, "v0.47.0", true); err == nil {
		t.Fatal("钉版对账不过时必须拒绝打 tag")
	}
	if env.TagExists("core", "v0.47.0") {
		t.Fatal("钉版对账不过时不得留下 tag(零 tag 推出)")
	}
}

// 对照组:钉版一致 ⇒ 照常打 tag（证明闸门不是「恒红」）。
func TestEnsureLibTag_CreatesTagWhenPinsMatch(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{
		"v0.46.0": "go.mod=" + libGomod("github.com/pigeonbox/contracts v0.25.0"),
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	versions := map[string]string{"lib.contracts": "v0.25.0", "lib.core": "v0.47.0"}
	created, err := ensureLibTag(env, versions, lr, "v0.47.0", true)
	if err != nil {
		t.Fatalf("钉版一致时应照常打 tag,实得 %v", err)
	}
	if !created || !env.TagExists("core", "v0.47.0") {
		t.Fatal("钉版一致时应建出 tag")
	}
}

// 已存在的库线 tag 也要对账（自动跟随已发布 tag 的车同样会错位）。
func TestEnsureLibTag_RefusesStalePinOnExistingTag(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{
		"v0.46.0": "go.mod=" + libGomod("github.com/pigeonbox/contracts v0.25.0"),
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")

	versions := map[string]string{"lib.contracts": "v0.26.0", "lib.core": "v0.46.0"}
	if _, err := ensureLibTag(env, versions, lr, "v0.46.0", false); err == nil {
		t.Fatal("已存在的库线 tag 上钉版陈旧时必须失败")
	}
}
