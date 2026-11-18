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
	c := CompatCell{
		Platform: platform, Span: span, Arches: []string{"amd64"},
		Deploy: "native", Status: status, Level: "artifact",
	}
	// 跨度声明(结构化):与类别自洽的样例跨度(供判据用例复用)。
	switch span {
	case "N-1":
		c.From, c.To = "6.7.0", "6.8.0"
	case "N-2":
		c.From, c.To = "6.6.0", "6.8.0"
	case "major-cross":
		c.From, c.To = "6.8.0", "7.0.0"
	}
	return c
}

// 带层级的格点(hub#670:level 是必填维度)。
func cellLevel(platform, span, status, level string) CompatCell {
	c := cell(platform, span, status)
	c.Level = level
	return c
}

// 完整矩阵(两平台 × 三跨度)通过自洽校验。
func TestCompatValidateAcceptsCompleteMatrix(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
	for _, p := range []string{"fnos", "openwrt"} {
		for _, s := range compatSpans {
			m.Cells = append(m.Cells, cell(p, s, compatUnverified))
		}
	}
	if errs := validateCompat(m, []string{"fnos", "openwrt"}); len(errs) > 0 {
		t.Fatalf("完整矩阵不应报错: %v", errs)
	}
}

// level 值域封闭:未知层级判红(不能默默当没这维度)。
func TestCompatValidateRejectsUnknownLevel(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cellLevel("fnos", s, compatUnverified, "foo"))
	}
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "层级非法") {
		t.Fatalf("未知 level 必须判红: %s", errs)
	}
}

// level 必填:verified 去掉 level 判红(不标层级就分不清钩子级/制品级)。
func TestCompatValidateRequiresLevel(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
	for _, s := range compatSpans {
		c := cell("fnos", s, compatUnverified)
		c.Level = ""
		m.Cells = append(m.Cells, c)
	}
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "必须带 level") {
		t.Fatalf("缺 level 必须判红: %s", errs)
	}

	// verified + level + evidence ⇒ 通过。
	m2 := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
	for _, s := range compatSpans {
		c := cellLevel("fnos", s, compatVerified, "hook")
		c.Evidence = "https://example/run/1"
		m2.Cells = append(m2.Cells, c)
	}
	if errs := validateCompat(m2, []string{"fnos"}); len(errs) > 0 {
		t.Fatalf("verified+level+evidence 不应报错: %v", errs)
	}
}

// 缺格判红:未验必须显式登记,不接受从表里消失。
func TestCompatValidateCatchesGap(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16", Cells: []CompatCell{
		{Platform: "fnos", Span: "N-1", Arches: []string{"amd64"}, Deploy: "native", Status: compatVerified, Level: "hook", Evidence: "x"},
		{Platform: "fnos", Span: "N-1", Arches: []string{"arm64"}, Deploy: "native", Status: compatFailed, Level: "artifact", Evidence: "x", Repro: "y"},
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

// 一屏渲染必须显示层级(hook/artifact/device)——否则「验到了哪一层」看不见。
func TestCompatRenderTableShowsLevel(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16", Cells: []CompatCell{
		cellLevel("fnos", "N-1", compatVerified, "hook"),
		cellLevel("fnos", "N-2", compatUnverified, "artifact"),
		cellLevel("fnos", "major-cross", compatUnverified, "device"),
	}}
	out := renderCompatTable(m, []string{"fnos"})
	for _, want := range []string{"hook", "artifact", "device"} {
		if !strings.Contains(out, want) {
			t.Fatalf("一屏必须显示层级 %q: %s", want, out)
		}
	}
}

// 同状态多格:层级取最深(artifact < hook < device)。
func TestCompatRenderTableDeepestLevelWins(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-16", Cells: []CompatCell{
		cellLevel("fnos", "N-1", compatVerified, "artifact"),
		cellLevel("fnos", "N-1", compatVerified, "device"),
	}}
	row := ""
	for _, ln := range strings.Split(renderCompatTable(m, []string{"fnos"}), "\n") {
		if strings.HasPrefix(ln, "| fnos |") {
			row = ln
			break
		}
	}
	if row == "" {
		t.Fatalf("渲染结果里没有 fnos 行")
	}
	if !strings.Contains(row, "device") {
		t.Fatalf("同状态多格应取最深层级: %s", row)
	}
	if strings.Contains(row, "artifact") {
		t.Fatalf("同状态多格不应同时显示浅层级: %s", row)
	}
}

// 子命令退出码:红灯 ⇒ 1;有未验但无红 ⇒ 0。
func TestCmdCompatCheckExitCodes(t *testing.T) {
	base := "train: 9.9.9\nstate: shipped\n" +
		"terminal.fnos.tag: v9.9.9\nterminal.openwrt.tag: v9.9.9\n"
	build := func(status string, evidence, repro string) *CompatMatrix {
		m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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
		m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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
		m := &CompatMatrix{Schema: "2", Updated: "2026-11-16"}
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

// ── 跨度机判（2026-11-18：跨度从 evidence 自由文本变成结构化字段）──────────

// 标 N-1 却跨了两版 ⇒ 判红（这正是实测出现过的错位：标 N-1、证据写 6.5.0→6.6.0）。
func TestCompatValidateRejectsSpanDistanceMismatch(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "6.6.0", "6.8.0" // N-1 却跨两版
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "N-1 跨度必须是同一大版本内相邻 minor") {
		t.Fatalf("N-1 跨两版必须判红: %s", errs)
	}
}

// N-2 写成相邻一版 ⇒ 判红（反方向的错位）。
func TestCompatValidateRejectsSpanN2Mismatch(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[1].Status = compatVerified
	m.Cells[1].Evidence = "https://example/run/1"
	m.Cells[1].From, m.Cells[1].To = "6.7.0", "6.8.0" // N-2 却只跨一版
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "N-2 跨度必须是同一大版本内隔一个 minor") {
		t.Fatalf("N-2 跨一版必须判红: %s", errs)
	}
}

// major-cross 写成同一大版本 ⇒ 判红。
func TestCompatValidateRejectsMajorCrossSameMajor(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[2].Status = compatVerified
	m.Cells[2].Evidence = "https://example/run/1"
	m.Cells[2].From, m.Cells[2].To = "6.7.0", "6.8.0" // major-cross 却不跨大版本
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "major-cross 必须跨大版本") {
		t.Fatalf("major-cross 同大版本必须判红: %s", errs)
	}
}

// N-1 跨大版本 ⇒ 判红（跨大版本只能登记为 major-cross）。
func TestCompatValidateRejectsN1CrossingMajor(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "6.9.0", "7.0.0"
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "N-1 跨度不得跨大版本") {
		t.Fatalf("N-1 跨大版本必须判红: %s", errs)
	}
}

// verified 缺 from/to ⇒ 判红（没有跨度声明就没有可核对的跨度主张）。
func TestCompatValidateRequiresSpanFields(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "", ""
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "必须声明 from/to") {
		t.Fatalf("verified 缺跨度声明必须判红: %s", errs)
	}
}

// 跨度方向反了（from ≥ to）⇒ 判红。
func TestCompatValidateRejectsInvertedSpan(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "6.8.0", "6.7.0"
	errs := strings.Join(validateCompat(m, []string{"fnos"}), "\n")
	if !strings.Contains(errs, "跨度方向非法") {
		t.Fatalf("跨度方向反了必须判红: %s", errs)
	}
}

// 相对当前车：to 晚于当前车 ⇒ 假绿（证据还没产生就写上未来版本）⇒ 判红。
func TestCompatTrainRelativeRejectsFutureTo(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "6.8.0", "9.9.9"
	errs, _ := compatTrainRelative(m, "6.8.0")
	if !strings.Contains(strings.Join(errs, "\n"), "晚于当前车") {
		t.Fatalf("to 晚于当前车必须判红: %v", errs)
	}
}

// 相对当前车：to 停在更早版本 ⇒ 不判红，但必须被点名为陈旧（漂移看得见）。
func TestCompatTrainRelativeReportsStale(t *testing.T) {
	m := &CompatMatrix{Schema: "2", Updated: "2026-11-18"}
	for _, s := range compatSpans {
		m.Cells = append(m.Cells, cell("fnos", s, compatUnverified))
	}
	m.Cells[0].Status = compatVerified
	m.Cells[0].Evidence = "https://example/run/1"
	m.Cells[0].From, m.Cells[0].To = "6.6.0", "6.7.0" // 停在上一车
	errs, stale := compatTrainRelative(m, "6.8.0")
	if len(errs) != 0 {
		t.Fatalf("陈旧不等于错误,不应判红: %v", errs)
	}
	if len(stale) != 1 {
		t.Fatalf("陈旧格点必须被点名: %v", stale)
	}
}
