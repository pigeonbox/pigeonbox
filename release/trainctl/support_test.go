package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// TestValidateActualSupportJSON 真实声明必须自洽（本地文件；CI 的 scripts 治理门禁
// 再做 train.yaml / 文档 / 指标名的跨文件对账）。
func TestValidateActualSupportJSON(t *testing.T) {
	b, err := os.ReadFile("../support.json")
	if err != nil {
		t.Fatalf("读 release/support.json: %v", err)
	}
	if _, err := ParseSupportPolicy(string(b)); err != nil {
		t.Fatalf("release/support.json 不自洽: %v", err)
	}
}

// TestActualDocsMatchRender 真实文档里的生成块必须与渲染器逐字一致——
// 否则 bump 第一次跑就会产生无意义的大 diff，或手改块绕过声明。
func TestActualDocsMatchRender(t *testing.T) {
	b, err := os.ReadFile("../support.json")
	if err != nil {
		t.Fatalf("读 release/support.json: %v", err)
	}
	p, err := ParseSupportPolicy(string(b))
	if err != nil {
		t.Fatalf("parse support.json: %v", err)
	}
	cases := []struct {
		path, begin, end, want string
	}{
		{"../../docs/SUPPORT.md", supportMatrixBegin, supportMatrixEnd, RenderSupportMatrixBlock(p)},
		{"../../docs/SUPPORT.md", supportBeamBegin, supportBeamEnd, RenderPigeonBeamBlock(p)},
		{"../../SECURITY.md", supportWindowBegin, supportWindowEnd, RenderSecurityWindowBlock(p)},
	}
	for _, c := range cases {
		raw, err := os.ReadFile(c.path)
		if err != nil {
			t.Fatalf("读 %s: %v", c.path, err)
		}
		content := string(raw)
		i := strings.Index(content, c.begin)
		if i < 0 {
			t.Errorf("%s 缺生成块起点 %s", c.path, c.begin)
			continue
		}
		j := strings.Index(content[i:], c.end)
		if j < 0 {
			t.Errorf("%s 缺生成块终点 %s", c.path, c.end)
			continue
		}
		got := content[i : i+j+len(c.end)]
		if got != c.want {
			t.Errorf("%s 生成块与 release/support.json 渲染结果不一致（bump 会重写）\n--- got ---\n%s\n--- want ---\n%s", c.path, got, c.want)
		}
	}
}

const supportFixture = `{
  "schema": "1",
  "train": "5.8.0",
  "minor": "5.8",
  "window_start": "2026-11-12",
  "policy": {"current_security_days": 180, "previous_security_days": 90, "security_severities": ["critical","high"]},
  "lines": [
    {"version":"5.8.x","status":"supported","security":"full","until":"2027-05-11","note":"当前维护线"},
    {"version":"5.7.x","status":"critical","security":"critical_high","until":"2027-02-10","note":"上一 minor"},
    {"version":"5.6.x","status":"eol","security":"none","until":"2026-11-12","note":"已 EOL"}
  ],
  "pigeonbeam": {
    "wire_protocol":"v4","wire_floor":"v4","p2p_pin":"v0.9.7",
    "n_minus_one_since":"v0.7.1","compat_until":"2027-05-11","note":"test"
  }
}`

func TestUpdateSupportPolicyPatchKeepsWindow(t *testing.T) {
	next, err := UpdateSupportPolicy(supportFixture, "5.8.1", "v0.9.7", time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("UpdateSupportPolicy: %v", err)
	}
	p, err := ParseSupportPolicy(next)
	if err != nil {
		t.Fatalf("回读: %v", err)
	}
	if p.Train != "5.8.1" || p.Minor != "5.8" || p.WindowStart != "2026-11-12" {
		t.Fatalf("patch 车不应改动窗口：%+v", p)
	}
	if p.Lines[0].Until != "2027-05-11" {
		t.Fatalf("patch 车当前线截止日被改动: %s", p.Lines[0].Until)
	}
}

func TestUpdateSupportPolicyNewMinorShifts(t *testing.T) {
	next, err := UpdateSupportPolicy(supportFixture, "5.9.0", "v0.9.8", time.Date(2026, 12, 15, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("UpdateSupportPolicy: %v", err)
	}
	p, err := ParseSupportPolicy(next)
	if err != nil {
		t.Fatalf("回读: %v", err)
	}
	if p.Minor != "5.9" || p.WindowStart != "2026-12-15" {
		t.Fatalf("新 minor 窗口未推进：minor=%s start=%s", p.Minor, p.WindowStart)
	}
	if got := p.Lines[0]; got.Version != "5.9.x" || got.Status != "supported" || got.Until != "2027-06-13" {
		t.Fatalf("新当前线错误：%+v", got)
	}
	if got := p.Lines[1]; got.Version != "5.8.x" || got.Status != "critical" || got.Until != "2027-03-15" {
		t.Fatalf("旧当前线未降为 critical+90 天：%+v", got)
	}
	if got := p.Lines[2]; got.Version != "5.7.x" || got.Status != "critical" || got.Until != "2027-02-10" {
		t.Fatalf("更早的 critical 承诺日被提前改写（不得提前 EOL）：%+v", got)
	}
	if p.Pigeonbeam.P2PPin != "v0.9.8" {
		t.Fatalf("PigeonBeam p2p_pin 未随列车钉版更新: %s", p.Pigeonbeam.P2PPin)
	}
	if p.Pigeonbeam.CompatUntil != "2027-06-13" {
		t.Fatalf("PigeonBeam 兼容期未随产品窗口延长: %s", p.Pigeonbeam.CompatUntil)
	}
}

func TestUpdateSupportPolicyExpiresStaleCritical(t *testing.T) {
	// 5.9.0 在 2027-05-20 才开：5.7.x 的 2027-02-10 已过，必须归一为 eol。
	next, err := UpdateSupportPolicy(supportFixture, "5.9.0", "v0.9.8", time.Date(2027, 5, 20, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("UpdateSupportPolicy: %v", err)
	}
	p, err := ParseSupportPolicy(next)
	if err != nil {
		t.Fatalf("回读: %v", err)
	}
	for _, l := range p.Lines {
		if l.Version == "5.7.x" && l.Status != "eol" {
			t.Fatalf("过期 critical 线未归一为 eol: %+v", l)
		}
	}
}

func TestRenderBlocksConcrete(t *testing.T) {
	p, err := ParseSupportPolicy(supportFixture)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	matrix := RenderSupportMatrixBlock(p)
	for _, want := range []string{
		supportMatrixBegin, supportMatrixEnd,
		"当前维护线：**5.8.x（列车 5.8.0）**",
		"2026-11-12", "2027-05-11", "2027-02-10", "2026-11-12",
		"| 5.7.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 |",
	} {
		if !strings.Contains(matrix, want) {
			t.Errorf("支持矩阵块缺 %q\n%s", want, matrix)
		}
	}
	sec := RenderSecurityWindowBlock(p)
	for _, want := range []string{supportWindowBegin, supportWindowEnd, "5.8.x（当前，列车 5.8.0）", "2027-05-11", "上一 minor 5.7.x"} {
		if !strings.Contains(sec, want) {
			t.Errorf("SECURITY 窗口块缺 %q\n%s", want, sec)
		}
	}
	beam := RenderPigeonBeamBlock(p)
	for _, want := range []string{supportBeamBegin, supportBeamEnd, "**v4**（floor v4）", "**v0.9.7**", "**至少到 2027-05-11**", "双格式（v4 + v5）"} {
		if !strings.Contains(beam, want) {
			t.Errorf("PigeonBeam 兼容块缺 %q\n%s", want, beam)
		}
	}
}

func TestUpdateMarkedBlock(t *testing.T) {
	in := "前缀\n" + supportMatrixBegin + "\n旧\n" + supportMatrixEnd + "\n后缀\n"
	out := UpdateMarkedBlock(in, supportMatrixBegin, supportMatrixEnd, supportMatrixBegin+"\n新\n"+supportMatrixEnd)
	if !strings.Contains(out, "新") || strings.Contains(out, "旧") {
		t.Fatalf("块替换失败: %q", out)
	}
	if !strings.Contains(out, "前缀") || !strings.Contains(out, "后缀") {
		t.Fatalf("块外内容被破坏: %q", out)
	}
	// 块不存在 ⇒ 追加
	out2 := UpdateMarkedBlock("正文", supportMatrixBegin, supportMatrixEnd, supportMatrixBegin+"\nX\n"+supportMatrixEnd)
	if !strings.HasSuffix(out2, supportMatrixEnd+"\n") || !strings.Contains(out2, "正文") {
		t.Fatalf("追加失败: %q", out2)
	}
}

func TestCompareMinor(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"5.9", "5.8", 1},
		{"5.8", "5.9", -1},
		{"5.8", "5.8", 0},
		{"10.0", "9.9", 1},
	}
	for _, c := range cases {
		if got := compareMinor(c.a, c.b); got != c.want {
			t.Errorf("compareMinor(%s,%s)=%d want %d", c.a, c.b, got, c.want)
		}
	}
}
