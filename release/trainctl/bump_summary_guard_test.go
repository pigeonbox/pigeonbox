// bump_summary_guard_test.go bump 汇总与**静默空转守卫**的断言
// （2026-10-25 3.3.28 实录引入）。
//
// 事故：bump 空转时每个仓都打「✓ 无列车变更,跳过」，紧接着的汇总却打
// 「✓ 已提交 → train/3.3.28(...)」，最后还打「✓ bump PR 已建齐」——
// 但 GitHub 上**一个 PR 都没有**、train.yaml 仍是 3.3.27。
// ⇒ 人看日志以为成功了 ⇒ 列车不动 ⇒ 只能靠人肉发现。
//
// ⇒ 本组用例钉住两件事：
// ① 守卫：push 模式下**一个 PR 都没建** ⇒ 必须报错（绝不沉默通过）；
// ② 汇总行必须区分「已提交」/「未建 PR」（照抄 planned 计划 = 谎报）。
//
// 断言必须能变红（负对照）：把 summaryGuard 恒返回 nil ⇒ 用例红。
package main

import (
	"os"
	"strings"
	"testing"
)

// TestSummaryGuard_NoPRLandedIsAnError 一个 PR 都没建 ⇒ 必须报错。
func TestSummaryGuard_NoPRLandedIsAnError(t *testing.T) {
	b := &bumper{
		train: "3.3.28", push: true,
		planned: map[string][]string{".": {"release/train.yaml"}},
		prDone:  map[string]bool{},
	}
	var err error
	out := captureStdout(t, func() { err = printBumpSummary(b) })
	if err == nil {
		t.Fatalf("一个 PR 都没建时必须报错（静默空转绝不沉默通过）:\n%s", out)
	}
	if !strings.Contains(err.Error(), "静默空转") {
		t.Fatalf("错误信息应点明「静默空转」，实得 %q", err.Error())
	}
}

// TestSummaryGuard_AtLeastOnePRIsEnough 有一个仓建了 PR ⇒ 通过。
func TestSummaryGuard_AtLeastOnePRIsEnough(t *testing.T) {
	b := &bumper{
		train: "3.3.28", push: true,
		planned: map[string][]string{".": {"release/train.yaml"}, "fnos": {"VERSION"}},
		prDone:  map[string]bool{".": true},
	}
	var err error
	captureStdout(t, func() { err = printBumpSummary(b) })
	if err != nil {
		t.Fatalf("有仓建了 PR 时不应报错: %v", err)
	}
}

// TestSummaryGuard_DryRunNeverFails dry-run 模式永不报错（只读演练）。
func TestSummaryGuard_DryRunNeverFails(t *testing.T) {
	b := &bumper{
		train: "3.3.28", push: false,
		planned: map[string][]string{".": {"release/train.yaml"}},
		prDone:  map[string]bool{},
	}
	var err error
	captureStdout(t, func() { err = printBumpSummary(b) })
	if err != nil {
		t.Fatalf("dry-run 模式不应触发空转守卫: %v", err)
	}
}

// TestPrintBumpSummary_ReportsRealState 汇总行必须区分「已提交」与「未建 PR」。
//
// 负对照：把汇总行改回「一律打印已提交」（照抄 planned）⇒ 本用例红。
func TestPrintBumpSummary_ReportsRealState(t *testing.T) {
	b := &bumper{
		train: "3.3.28", push: true,
		planned: map[string][]string{".": {"release/train.yaml"}},
		prDone:  map[string]bool{}, // 谎报场景：计划有变更但没建 PR
	}
	out := captureStdout(t, func() { _ = printBumpSummary(b) })
	if strings.Contains(out, "已提交") {
		t.Fatalf("未建 PR 的仓不得被汇总成「已提交」:\n%s", out)
	}
	if !strings.Contains(out, "未建 PR") {
		t.Fatalf("汇总必须显式标出「未建 PR」:\n%s", out)
	}
}

// captureStdout 捕获 f 的 stdout。
func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = old }()
	f()
	_ = w.Close()
	buf := make([]byte, 65536)
	n, _ := r.Read(buf)
	_ = r.Close()
	return string(buf[:n])
}
