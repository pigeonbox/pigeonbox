// compat_test.go —— 跨平台升级兼容矩阵(pigeonbox#386)判据自测。
//
// 断言全是结构事实:validator 的缺口/红灯判定、一屏渲染的最坏聚合、
// 子命令退出码。不依赖文案(错误里只查关键子串)。
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCompatFile(t *testing.T, root string, m *CompatMatrix) {
	t.Helper()
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "release"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, compatRel), raw, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func cell(platform, span, status string) CompatCell {
	return CompatCell{Platform: platform, Span: span, Arches: []string{"amd64"}, Deploy: "native", Status: status}
}

// 完整矩阵(两平台 × 三跨度)通过自洽校验。
func TestCompatValidateAcceptsCompleteMatrix(t *testing.T) {
	m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
	for _, p := range []string{"fnos", "openwrt"} {
		for _, s := range compatSpans {
			m.Cells = append(m.Cells, cell(p, s, compatUnverified))
		}
	}
	if errs := validateCompat(m, []string{"fnos", "openwrt"}); len(errs) > 0 {
		t.Fatalf("完整矩阵不应报错: %v", errs)
	}
}

// 缺格判红:未验必须显式登记,不接受从表里消失。
func TestCompatValidateCatchesGap(t *testing.T) {
	m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
	for _, s := range compatSpans[:2] { // 故意漏 major-cross
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	errs := validateCompat(m, []string{"fnos"})
	if len(errs) == 0 || !strings.Contains(strings.Join(errs, "\n"), "缺口") {
		t.Fatalf("缺格必须报缺口: %v", errs)
	}
}

// verified 必须带证据;failed 必须带证据 + 最小复现步骤。
func TestCompatValidateEvidenceAndRepro(t *testing.T) {
	m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified // 无 evidence
	m.Cells[1].Status = compatFailed   // 无 evidence/repro
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "evidence") {
		t.Fatalf("verified/failed 缺证据必须报: %s", errs)
	}
	if !strings.Contains(errs, "repro") {
		t.Fatalf("failed 缺复现步骤必须报: %s", errs)
	}
}

// 词表外的平台/跨度/部署/架构/状态一律报错。
func TestCompatValidateRejectsUnknownVocabulary(t *testing.T) {
	m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Platform = "beos"
	m.Cells[1].Span = "N-3"
	m.Cells[2].Deploy = "vm"
	m.Cells = append(m.Cells, cell("fnos", "N-1", "maybe"))
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	for _, want := range []string{"平台不在", "跨度非法", "部署形态非法", "状态非法"} {
		if !strings.Contains(errs, want) {
			t.Fatalf("缺 %q 报错: %s", want, errs)
		}
	}
}

// 平台清单从 train.yaml 的 terminal.<name>.tag 导出(与列车单源)。
func TestCompatPlatformsFromTrainFile(t *testing.T) {
	root := t.TempDir()
	writeTrainFile(t, root, "train: 9.9.9\nstate: shipped\n"+
		"terminal.fnos.tag: v9.9.9\nterminal.openwrt.tag: v9.9.9\n"+
		"terminal.desktop.tag: desktop-v9.9.9\nterminal.p2pc_ref: v0.9.7\n")
	tf := mustTrain(&Env{Root: root})
	got := compatPlatforms(tf)
	want := []string{"desktop", "fnos", "openwrt"}
	if len(got) != len(want) {
		t.Fatalf("平台清单 = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("平台清单 = %v, want %v", got, want)
		}
	}
}

// 一屏聚合取最坏:同平台同跨度一绿一红 ⇒ 显示红(绿不能盖住红)。
func TestCompatRenderTableWorstAggregation(t *testing.T) {
	m := &CompatMatrix{Schema: "1", Updated: "2026-11-16", Cells: []CompatCell{
		{Platform: "fnos", Span: "N-1", Arches: []string{"amd64"}, Deploy: "native", Status: compatVerified, Evidence: "x"},
		{Platform: "fnos", Span: "N-1", Arches: []string{"arm64"}, Deploy: "native", Status: compatFailed, Evidence: "x", Repro: "y"},
		cell("fnos", "N-2", compatUnverified),
		cell("fnos", "major-cross", compatUnsupported),
	}}
	out := renderCompatTable(m, []string{"fnos"})
	if !strings.Contains(out, "❌") {
		t.Fatalf("同格红点必须显示红: %s", out)
	}
	if !strings.Contains(out, "⬜") || !strings.Contains(out, "—") {
		t.Fatalf("未验/不支持符号必须出现: %s", out)
	}
}

// 子命令退出码:红灯 ⇒ 1;有未验但无红 ⇒ 0。
func TestCmdCompatCheckExitCodes(t *testing.T) {
	base := "train: 9.9.9\nstate: shipped\n" +
		"terminal.fnos.tag: v9.9.9\nterminal.openwrt.tag: v9.9.9\n"
	build := func(status string, evidence, repro string) *CompatMatrix {
		m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
		for _, p := range []string{"fnos", "openwrt"} {
			for _, s := range compatSpans {
				c := cell(p, s, status)
				c.Evidence, c.Repro = evidence, repro
				m.Cells = append(m.Cells, c)
			}
		}
		return m
	}

	t.Run("红灯非零退出", func(t *testing.T) {
		root := t.TempDir()
		writeTrainFile(t, root, base)
		writeCompatFile(t, root, build(compatFailed, "https://example/run/1", "steps"))
		if rc := cmdCompat(&Env{Root: root}, []string{"--check"}); rc != 1 {
			t.Fatalf("红灯格点应退出 1, got %d", rc)
		}
	})
	t.Run("未验不阻断", func(t *testing.T) {
		root := t.TempDir()
		writeTrainFile(t, root, base)
		writeCompatFile(t, root, build(compatUnverified, "", ""))
		if rc := cmdCompat(&Env{Root: root}, []string{"--check"}); rc != 0 {
			t.Fatalf("未验应退出 0, got %d", rc)
		}
	})
	t.Run("缺口非零退出", func(t *testing.T) {
		root := t.TempDir()
		writeTrainFile(t, root, base)
		m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
		for _, s := range compatSpans[:1] {
			m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
		}
		writeCompatFile(t, root, m)
		if rc := cmdCompat(&Env{Root: root}, []string{"--check"}); rc != 1 {
			t.Fatalf("缺口应退出 1, got %d", rc)
		}
	})
}

// 发车闸:红灯拒绝;全未验放行(只报黄)。
func TestGateCompat(t *testing.T) {
	base := "train: 9.9.9\nstate: shipped\nterminal.fnos.tag: v9.9.9\n"
	build := func(status string) *CompatMatrix {
		m := &CompatMatrix{Schema: "1", Updated: "2026-11-16"}
		for _, s := range compatSpans {
			c := cell("fnos", s, status)
			if status == compatFailed {
				c.Evidence, c.Repro = "x", "y"
			}
			m.Cells = append(m.Cells, c)
		}
		return m
	}
	rootFailed := t.TempDir()
	writeTrainFile(t, rootFailed, base)
	writeCompatFile(t, rootFailed, build(compatFailed))
	envFailed := &Env{Root: rootFailed}
	if err := gateCompat(envFailed, mustTrain(envFailed)); err == nil {
		t.Fatal("红灯格点必须拒绝发车")
	}
	rootOK := t.TempDir()
	writeTrainFile(t, rootOK, base)
	writeCompatFile(t, rootOK, build(compatUnverified))
	envOK := &Env{Root: rootOK}
	if err := gateCompat(envOK, mustTrain(envOK)); err != nil {
		t.Fatalf("全未验不应阻断发车: %v", err)
	}
}
