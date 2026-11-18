// verify_freshness_test.go 检出新鲜度守卫的两处真洞回归（2026-11-18）。
//
// 洞一（假红）：CI 的 actions/checkout 默认 fetch-depth: 1 ⇒ 工作区是**浅克隆**。
//
//	旧口径用 rev-list --count HEAD..origin/<br> 判「检出落后」⇒ HEAD 的祖先
//	不在库里 ⇒ 「从 HEAD 往回数」的计数不可信（CI 实录：报「落后 origin/main
//	986 提交」，真值只有 3~5；数字随远端历史长度漂移）⇒ hub 仓据此判
//	「判据不可用」⇒ **对账假红 + 误开 train-drift 常驻 issue**。
//
// 洞二（竞态）：CI 检出的就是**本次被验证的那次提交**（事件 SHA）⇒ 拿会移动的
// origin/<br> 当基准本身就是竞态（列车发车时主线接连前进）⇒ 即使数字算对，
// 「落后」在 CI 下也不该判红。
//
// 断言全部是结构事实（unavails/warns/fails 计数、behind 判定、countKnown 标志），
// 不依赖文案。
//
// 承重（负对照）：把 checkBehind 改回旧口径（直接 rev-list --count HEAD..origin/<br>
// 并当作真值）⇒ 本组用例红（countKnown 变 true、count 变数字）。
package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// newShallowBehindClone 造「浅克隆 + 远端领先 behind 提交」的夹具。
//
// 关键：**浅克隆的祖先不可得**（HEAD^ 不可解析）—— 这正是「提交数不可信」的
// 结构性前提，与 CI 的 actions/checkout(fetch-depth: 1) 同形。
func newShallowBehindClone(t *testing.T, name string, baseCommits, behind int) (string, string, string) {
	t.Helper()
	root := t.TempDir()
	origin := filepath.Join(root, "origin.git")
	work := filepath.Join(root, name)
	runGitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
	seed := filepath.Join(root, "seed")
	initRepo(t, seed, "main")
	runGitIn(t, seed, "remote", "add", "origin", origin)
	runGitIn(t, seed, "push", "-q", "-u", "origin", "main")
	for i := 1; i < baseCommits; i++ {
		writeFile(t, seed, "f.txt", strings.Repeat("x", i))
		runGitIn(t, seed, "add", "-A")
		runGitIn(t, seed, "commit", "-qm", "base")
	}
	runGitIn(t, seed, "push", "-q", "origin", "main")
	// file:// 走传输层 ⇒ --depth 生效（本地路径克隆默认忽略 --depth）。
	runGitIn(t, root, "clone", "-q", "--depth", "1", "file://"+origin, work)
	for i := 0; i < behind; i++ {
		writeFile(t, seed, "g.txt", strings.Repeat("y", i+1))
		runGitIn(t, seed, "add", "-A")
		runGitIn(t, seed, "commit", "-qm", "advance")
	}
	runGitIn(t, seed, "push", "-q", "origin", "main")
	return root, origin, work
}

// TestCheckBehind_ShallowCloneCountIsNotMeasured 浅克隆下提交数**原理上不可核实**：
// HEAD 的祖先对象不在库里 ⇒ 任何「从 HEAD 往回数」的计数都不可信
// ⇒ 必须标「不可核实」且**不携带任何数字**。
//
// 承重前提（断言）：夹具里 HEAD^ 必须不可解析；一旦可解析，说明祖先可得、
// 提交数本可核实 ⇒ 本用例失去承重能力 ⇒ 红。
func TestCheckBehind_ShallowCloneCountIsNotMeasured(t *testing.T) {
	_, _, work := newShallowBehindClone(t, "hub", 8, 2)
	// checkoutFreshOne 的第一步：fetch（否则 origin/main 还是旧的）。
	runGitIn(t, work, "fetch", "-q", "--tags", "origin")

	// 结构性前提：浅克隆里 HEAD 的祖先不可解析 ⇒ 提交数不可信。
	if _, err := Git(work, "rev-parse", "HEAD^"); err == nil {
		t.Fatal("夹具前提不成立：HEAD^ 可解析 ⇒ HEAD 的祖先可得 ⇒ 提交数本可核实 ⇒ 本用例失去承重能力")
	}
	bv := checkBehind(work, "main")
	if bv.err != nil {
		t.Fatalf("核实失败: %v", bv.err)
	}
	if bv.countKnown {
		t.Fatalf("浅克隆下提交数不可核实，countKnown 应为 false，实得 count=%d", bv.count)
	}
	if bv.count != 0 {
		t.Fatalf("不可核实时不得携带数字，实得 %d", bv.count)
	}
	if !bv.behind {
		t.Fatal("远端确实领先 ⇒ behind 应为 true")
	}
}

// TestCheckBehind_FullCloneReportsTrueCount 全克隆下提交数必须是真值。
func TestCheckBehind_FullCloneReportsTrueCount(t *testing.T) {
	_, _, work := newBehindClone(t, "hub", 3)
	runGitIn(t, work, "fetch", "-q", "--tags", "origin")
	bv := checkBehind(work, "main")
	if bv.err != nil {
		t.Fatalf("核实失败: %v", bv.err)
	}
	if !bv.countKnown {
		t.Fatal("全克隆下提交数必须可核实")
	}
	if bv.count != 3 {
		t.Fatalf("落后提交数应为 3，实得 %d", bv.count)
	}
	if !bv.behind {
		t.Fatal("应判为落后")
	}
}

// TestCheckoutFreshness_CIModeHubBehindIsNotUnavailable CI 模式下 hub 检出
// 落后**不得**判「判据不可用」——检出=本次被验证的提交，origin/<br> 前进属竞态。
//
// 负对照（回退修复即红）：删掉 CI 分支（恢复旧口径「一律按落后判红」）
// ⇒ 本用例红（unavails=1）。
func TestCheckoutFreshness_CIModeHubBehindIsNotUnavailable(t *testing.T) {
	_, _, work := newShallowBehindClone(t, "hub", 8, 2)
	v := &verifier{env: &Env{Root: work}, ci: true}
	v.checkoutFreshness()
	if v.unavails != 0 {
		t.Fatalf("CI 模式：检出=本次被验证的提交 ⇒ 不得判「判据不可用」，实得 unavails=%d", v.unavails)
	}
	if v.fails != 0 {
		t.Fatalf("CI 模式不得判真漂移，实得 fails=%d", v.fails)
	}
}

// TestCheckoutFreshness_CIModeMismatchedSubjectWarns CI 下「检出的不是本次触发
// 提交」要报出来（告警，不是判红——判红会让检出形态异常直接卡死发车）。
func TestCheckoutFreshness_CIModeMismatchedSubjectWarns(t *testing.T) {
	t.Setenv("GITHUB_SHA", "0000000000000000000000000000000000000000")
	_, _, work := newShallowBehindClone(t, "hub", 8, 2)
	v := &verifier{env: &Env{Root: work}, ci: true}
	v.checkoutFreshness()
	if v.warns < 1 {
		t.Fatalf("检出的不是触发提交 ⇒ 应告警，实得 warns=%d", v.warns)
	}
	if v.unavails != 0 {
		t.Fatalf("检出形态异常不得判「判据不可用」，实得 unavails=%d", v.unavails)
	}
}

// TestCheckoutFreshness_LocalModeShallowBehindIsUnavailable 本地模式下
// 「检出落后」**仍判**「判据不可用」（工作树确实陈旧 ⇒ 语义正确），
// 但走的是「提交数不可核实」那条分支（不输出假数字）。
func TestCheckoutFreshness_LocalModeShallowBehindIsUnavailable(t *testing.T) {
	_, _, work := newShallowBehindClone(t, "hub", 8, 2)
	v := &verifier{env: &Env{Root: work}}
	v.checkoutFreshness()
	if v.unavails != 1 {
		t.Fatalf("本地模式：检出落后 ⇒ 1 处判据不可用，实得 %d", v.unavails)
	}
	if v.warns != 0 {
		t.Fatalf("hub 落后不得降级为告警，实得 warns=%d", v.warns)
	}
}
