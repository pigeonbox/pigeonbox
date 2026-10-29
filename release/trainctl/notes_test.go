package main

import (
	"strings"
	"testing"
)

// splitMarkdownRow 按**未转义**的 `|` 切列（`\|` 属于单元格内容，不是分隔符）。
//
// markdown 表格按未转义竖线分列，**反引号里的竖线也不例外**——这是本文件
// 存在的全部理由（见 TestNotesTablesHaveConsistentColumns）。
func splitMarkdownRow(line string) []string {
	s := strings.TrimSpace(line)
	cells := []string{}
	var cur strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' && i+1 < len(s) && s[i+1] == '|' {
			cur.WriteString(`\|`)
			i++
			continue
		}
		if c == '|' {
			cells = append(cells, strings.TrimSpace(cur.String()))
			cur.Reset()
			continue
		}
		cur.WriteByte(c)
	}
	cells = append(cells, strings.TrimSpace(cur.String()))
	if len(cells) > 0 && cells[0] == "" {
		cells = cells[1:]
	}
	if len(cells) > 0 && cells[len(cells)-1] == "" {
		cells = cells[:len(cells)-1]
	}
	return cells
}

// notesTrainFile 造一份 4.x 列车快照（两个破坏性变更清单都会渲染出来）。
func notesTrainFile(train string) *TrainFile {
	m := map[string]string{
		"train":                train,
		"images.server":        strings.TrimPrefix(train, "v"),
		"terminal.desktop.tag": "desktop-" + train,
		"terminal.fnos.tag":    train,
		"terminal.openwrt.tag": train,
		"terminal.qnap.tag":    train,
		"terminal.p2pc_ref":    "v0.9.2",
		"lib.p2p":              "v0.9.3",
		"lib.core":             "v0.32.21",
		"lib.contracts":        "v0.20.3",
		"lib.frontend-core":    "v0.11.35",
		"charts.chart":         "2.0.89",
	}
	for _, p := range platforms {
		m["terminal."+p+".tag"] = train
	}
	return &TrainFile{m: m}
}

// TestNotesTablesHaveConsistentColumns Release 说明里每张表的行必须与表头同列数。
//
// 为什么：markdown 表格按**未转义**的 `|` 分列，代码段里的竖线也不例外。
// 实弹：4.0.0 兼容层退役那张表有一行写成 `code===0 || code===200`（未转义）
// ⇒ GitHub 与 VitePress 都把它拆成 3 列，「表现」「处理」两列内容**整列消失**，
// "集成方请继续只认 0" 这条关键指引在 Release 页与文档站上都读不到。
//
// 判据打在**真正被渲染的那份文本**上（cmdNotes 的输出），而不是"我们以为的规则"：
// 守卫要能在缺陷态真的变红。
func TestNotesTablesHaveConsistentColumns(t *testing.T) {
	for _, train := range []string{"v4.0.6", "v3.3.36"} {
		notes := cmdNotes(notesTrainFile(train), train)
		lines := strings.Split(notes, "\n")
		for i := 0; i < len(lines); i++ {
			if !strings.HasPrefix(strings.TrimSpace(lines[i]), "|") {
				continue
			}
			headCols := len(splitMarkdownRow(lines[i]))
			j := i + 1
			for ; j < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[j]), "|"); j++ {
				if got := len(splitMarkdownRow(lines[j])); got != headCols {
					t.Errorf("[%s] 表格行列数不一致：表头 %d 列，该行 %d 列\n  %s",
						train, headCols, got, strings.TrimSpace(lines[j]))
				}
			}
			i = j - 1
		}
	}
}

// TestNotesEscapesPipeInCodeSpan 单元格里的代码段竖线必须写成 `\|`。
func TestNotesEscapesPipeInCodeSpan(t *testing.T) {
	notes := cmdNotes(notesTrainFile("v4.0.6"), "v4.0.6")
	if !strings.Contains(notes, `code===0 \|\| code===200`) {
		t.Error("成功码双写那行的代码段竖线未转义（应为 `\\|\\|`）——GitHub 上该行会被拆列，「表现」「处理」两列内容丢失")
	}
}

// TestSplitMarkdownRowDetectsUnescapedPipe 负对照：切列器必须能识破未转义竖线。
//
// 没有这条，TestNotesTablesHaveConsistentColumns 可能是**恒绿**（判据写错了地方），
// 缺陷态照样通过——这正是"补闸必须配负对照"要防的事。
func TestSplitMarkdownRowDetectsUnescapedPipe(t *testing.T) {
	good := "| a（`x \\|\\| y`） | b | c |"
	if got := len(splitMarkdownRow(good)); got != 3 {
		t.Errorf("已转义竖线应切出 3 列，实得 %d 列", got)
	}
	bad := "| a（`x || y`） | b | c |"
	if got := len(splitMarkdownRow(bad)); got == 3 {
		t.Error("未转义竖线应被识破（切出 >3 列），实得 3 列——切列器失效，守卫恒绿")
	}
}
