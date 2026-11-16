package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// 支持策略/版本窗口的机器可读真相源（#387）。
//
// 为什么单独一份 JSON 而不是写死在 SECURITY.md 里：
//   - SECURITY.md / docs/SUPPORT.md 是给人看的，版本一抬就会漂；
//   - 列车 bump 每趟都要抬 train，支持窗口（当前 minor / 上一 minor / EOL）
//     必须跟着走，且 docs 门禁能机械对账；
//   - 发版编排器只依赖 Go 标准库（design: 2026-10-12-release-train-v2-design.md），
//     JSON 用 encoding/json 即可解析，不引入 YAML 依赖。
//
// 真相源：release/support.json。docs/SUPPORT.md 与 SECURITY.md 的表格块由
// RenderSupportMatrixBlock / RenderSecurityWindowBlock 生成（bump 时同步改写）。
const (
	supportPolicyRel     = "release/support.json"
	supportDocRel        = "docs/SUPPORT.md"
	securityDocRel       = "SECURITY.md"
	supportMatrixBegin   = "<!-- support-matrix:begin -->"
	supportMatrixEnd     = "<!-- support-matrix:end -->"
	supportWindowBegin   = "<!-- support-window:begin -->"
	supportWindowEnd     = "<!-- support-window:end -->"
	supportBeamBegin     = "<!-- support-beam:begin -->"
	supportBeamEnd       = "<!-- support-beam:end -->"
	supportDateLayout    = "2006-01-02"
	supportSchemaVersion = "1"
)

// SupportPolicy 是 release/support.json 的结构。
type SupportPolicy struct {
	Schema      string              `json:"schema"`
	Train       string              `json:"train"`
	Minor       string              `json:"minor"`
	WindowStart string              `json:"window_start"`
	Policy      SupportPolicyConfig `json:"policy"`
	Lines       []SupportLine       `json:"lines"`
	Pigeonbeam  PigeonBeamPolicy    `json:"pigeonbeam"`
}

// SupportPolicyConfig 是窗口/严重级别参数（改这里 = 改政策，需治理评审）。
type SupportPolicyConfig struct {
	CurrentSecurityDays  int      `json:"current_security_days"`
	PreviousSecurityDays int      `json:"previous_security_days"`
	SecuritySeverities   []string `json:"security_severities"`
}

// SupportLine 是一条版本线的支持声明。
type SupportLine struct {
	Version  string `json:"version"`  // 如 5.8.x / <=5.5.x
	Status   string `json:"status"`   // supported / critical / eol
	Security string `json:"security"` // full / critical_high / none
	Until    string `json:"until"`    // YYYY-MM-DD（EOL 行即 EOL 日期）
	Note     string `json:"note"`
}

// PigeonBeamPolicy 是 PigeonBeam 协议兼容周期声明（与 p2p 仓版本线对齐）。
type PigeonBeamPolicy struct {
	WireProtocol   string `json:"wire_protocol"`
	WireFloor      string `json:"wire_floor"`
	P2PPin         string `json:"p2p_pin"`
	NMinusOneSince string `json:"n_minus_one_since"`
	CompatUntil    string `json:"compat_until"`
	Note           string `json:"note"`
}

// ParseSupportPolicy 解析 release/support.json。
func ParseSupportPolicy(content string) (*SupportPolicy, error) {
	var p SupportPolicy
	if err := json.Unmarshal([]byte(content), &p); err != nil {
		return nil, fmt.Errorf("解析 support.json: %w", err)
	}
	if err := ValidateSupportPolicy(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// ValidateSupportPolicy 校验声明内部自洽（日期/状态/窗口公式）。
// 跨文件对账（train.yaml / 文档 / 指标）由 scripts 的治理门禁负责。
func ValidateSupportPolicy(p *SupportPolicy) error {
	if p.Schema != supportSchemaVersion {
		return fmt.Errorf("support schema = %q，期望 %q", p.Schema, supportSchemaVersion)
	}
	if !validSemverTriple(p.Train) {
		return fmt.Errorf("train = %q 不是 x.y.z", p.Train)
	}
	if p.Minor != majorMinor(p.Train) {
		return fmt.Errorf("minor = %q 与 train = %q 不同号", p.Minor, p.Train)
	}
	start, err := time.Parse(supportDateLayout, p.WindowStart)
	if err != nil {
		return fmt.Errorf("window_start = %q 不是 YYYY-MM-DD", p.WindowStart)
	}
	if p.Policy.CurrentSecurityDays <= 0 || p.Policy.PreviousSecurityDays <= 0 {
		return fmt.Errorf("安全窗口天数必须为正数")
	}
	seenCurrent := false
	for _, l := range p.Lines {
		if l.Version == "" || l.Until == "" {
			return fmt.Errorf("支持行缺 version/until：%+v", l)
		}
		if _, err := time.Parse(supportDateLayout, l.Until); err != nil {
			return fmt.Errorf("支持行 %s 的 until = %q 不是 YYYY-MM-DD", l.Version, l.Until)
		}
		switch l.Status {
		case "supported":
			seenCurrent = true
			want := start.AddDate(0, 0, p.Policy.CurrentSecurityDays).Format(supportDateLayout)
			if l.Until != want {
				return fmt.Errorf("当前线 %s 的 until = %s，按窗口公式应为 %s", l.Version, l.Until, want)
			}
			if l.Security != "full" {
				return fmt.Errorf("当前线 %s 的 security 必须为 full", l.Version)
			}
		case "critical":
			if l.Security != "critical_high" {
				return fmt.Errorf("critical 线 %s 的 security 必须为 critical_high", l.Version)
			}
			if l.Until < p.WindowStart {
				return fmt.Errorf("critical 线 %s 已过期（until=%s < window_start=%s）——应改为 eol", l.Version, l.Until, p.WindowStart)
			}
		case "eol":
			if l.Security != "none" {
				return fmt.Errorf("eol 线 %s 的 security 必须为 none", l.Version)
			}
		default:
			return fmt.Errorf("支持行 %s 的 status = %q（合法值 supported/critical/eol）", l.Version, l.Status)
		}
	}
	if !seenCurrent {
		return fmt.Errorf("support.json 缺当前维护线（status=supported）")
	}
	if p.Pigeonbeam.WireProtocol == "" || p.Pigeonbeam.P2PPin == "" {
		return fmt.Errorf("pigeonbeam.wire_protocol / p2p_pin 不能为空")
	}
	compat, err := time.Parse(supportDateLayout, p.Pigeonbeam.CompatUntil)
	if err != nil {
		return fmt.Errorf("pigeonbeam.compat_until = %q 不是 YYYY-MM-DD", p.Pigeonbeam.CompatUntil)
	}
	// 兼容期不得短于当前产品线安全窗口（当前线 until 由 window_start + 180 得出）。
	for _, l := range p.Lines {
		if l.Status != "supported" {
			continue
		}
		cur, _ := time.Parse(supportDateLayout, l.Until)
		if compat.Before(cur) {
			return fmt.Errorf("pigeonbeam.compat_until = %s 短于当前线 %s 的安全支持截止 %s",
				p.Pigeonbeam.CompatUntil, l.Version, l.Until)
		}
	}
	return nil
}

// UpdateSupportPolicy 在开新车时推进声明。
//
//   - patch 车（同 minor）：只改 train；
//   - 新 minor：旧当前线降为 critical（新窗口起算 + previous_security_days），
//     新当前线全量支持（新窗口起算 + current_security_days）；已过期的旧行归一为 eol。
//
// 返回新的 JSON 文本（缩进 2 空格 + 末尾换行），供 bump 写回。
func UpdateSupportPolicy(content, newTrain, newP2PPin string, now time.Time) (string, error) {
	p, err := ParseSupportPolicy(content)
	if err != nil {
		return "", err
	}
	if !validSemverTriple(newTrain) {
		return "", fmt.Errorf("新列车号 %q 不是 x.y.z", newTrain)
	}
	newMinor := majorMinor(newTrain)
	if newP2PPin != "" {
		p.Pigeonbeam.P2PPin = newP2PPin
	}
	if newMinor == p.Minor {
		p.Train = newTrain
		return renderSupportPolicy(p)
	}
	if compareMinor(newMinor, p.Minor) < 0 {
		// 回退/重跑旧车：只改 train，不重排窗口（避免把已承诺日期改坏）。
		p.Train = newTrain
		return renderSupportPolicy(p)
	}

	today := now.UTC().Format(supportDateLayout)
	start, _ := time.Parse(supportDateLayout, today) // now 必然可格式化
	// 先归一：已过期且仍标 supported/critical 的行改为 eol（不删历史行）。
	for i := range p.Lines {
		if p.Lines[i].Status != "eol" && p.Lines[i].Until < today {
			p.Lines[i].Status = "eol"
			p.Lines[i].Security = "none"
			p.Lines[i].Note = "已 EOL：不再提供安全补丁"
		}
	}
	// 旧当前线 → 上一 minor（critical）。
	for i := range p.Lines {
		if p.Lines[i].Status == "supported" {
			p.Lines[i].Status = "critical"
			p.Lines[i].Security = "critical_high"
			p.Lines[i].Until = start.AddDate(0, 0, p.Policy.PreviousSecurityDays).Format(supportDateLayout)
			p.Lines[i].Note = fmt.Sprintf("上一 minor：仅 critical/high 安全修复（%s 发布后 %d 天）", newTrain, p.Policy.PreviousSecurityDays)
		}
	}
	// 新当前线。
	current := SupportLine{
		Version:  newMinor + ".x",
		Status:   "supported",
		Security: "full",
		Until:    start.AddDate(0, 0, p.Policy.CurrentSecurityDays).Format(supportDateLayout),
		Note:     "当前维护线：全量安全修复 + 关键缺陷修复",
	}
	p.Lines = append([]SupportLine{current}, p.Lines...)
	p.Train = newTrain
	p.Minor = newMinor
	p.WindowStart = today
	// PigeonBeam 兼容期与产品窗口对齐（只延长不缩短）。
	if want := start.AddDate(0, 0, p.Policy.CurrentSecurityDays).Format(supportDateLayout); want > p.Pigeonbeam.CompatUntil {
		p.Pigeonbeam.CompatUntil = want
	}
	if err := ValidateSupportPolicy(p); err != nil {
		return "", err
	}
	return renderSupportPolicy(p)
}

// renderSupportPolicy 统一 JSON 渲染（bump 与测试共用；保证 diff 只有内容变化）。
func renderSupportPolicy(p *SupportPolicy) (string, error) {
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b) + "\n", nil
}

// RenderSupportMatrixBlock 渲染 docs/SUPPORT.md 的支持矩阵块。
func RenderSupportMatrixBlock(p *SupportPolicy) string {
	var b strings.Builder
	b.WriteString(supportMatrixBegin + "\n")
	fmt.Fprintf(&b, "当前维护线：**%s（列车 %s）**；安全支持窗口起算 **%s**。\n\n", p.Minor+".x", p.Train, p.WindowStart)
	b.WriteString("| 版本线 | 状态 | 安全修复范围 | 安全支持截止 | 说明 |\n")
	b.WriteString("|---|---|---|---|---|\n")
	for _, l := range p.Lines {
		fmt.Fprintf(&b, "| %s | %s | %s | %s | %s |\n",
			escapeTableCell(l.Version), supportStatusLabel(l.Status), supportSecurityLabel(l.Security),
			escapeTableCell(l.Until), escapeTableCell(l.Note))
	}
	b.WriteString(supportMatrixEnd)
	return b.String()
}

// RenderSecurityWindowBlock 渲染 SECURITY.md 的精简支持窗口块。
func RenderSecurityWindowBlock(p *SupportPolicy) string {
	var b strings.Builder
	b.WriteString(supportWindowBegin + "\n")
	var current, previous *SupportLine
	for i := range p.Lines {
		switch p.Lines[i].Status {
		case "supported":
			if current == nil {
				current = &p.Lines[i]
			}
		case "critical":
			if previous == nil {
				previous = &p.Lines[i]
			}
		}
	}
	if current != nil {
		fmt.Fprintf(&b, "当前维护线：**%s（列车 %s）**，安全支持至 **%s**。", current.Version, p.Train, current.Until)
	}
	if previous != nil {
		fmt.Fprintf(&b, "上一 minor %s 仅接收 critical/high 修复，至 **%s**。", previous.Version, previous.Until)
	}
	b.WriteString("更早版本见下表；EOL 版本不再接收安全补丁。\n\n")
	b.WriteString("| 版本线 | 支持状态 | 安全支持截止 |\n")
	b.WriteString("|---|---|---|\n")
	for _, l := range p.Lines {
		version := l.Version
		if l.Status == "supported" {
			version += "（当前，列车 " + p.Train + "）"
		}
		fmt.Fprintf(&b, "| %s | %s | %s |\n",
			escapeTableCell(version), supportStatusLabel(l.Status), escapeTableCell(l.Until))
	}
	b.WriteString(supportWindowEnd)
	return b.String()
}

// RenderPigeonBeamBlock 渲染 PigeonBeam 协议兼容周期表（bump 随 p2p 钉版更新）。
func RenderPigeonBeamBlock(p *SupportPolicy) string {
	var b strings.Builder
	b.WriteString(supportBeamBegin + "\n")
	b.WriteString("| 项 | 当前值 | 依据 |\n")
	b.WriteString("|---|---|---|\n")
	fmt.Fprintf(&b, "| wire 协议 | **%s**（floor %s） | p2p 仓 `docs/PRODUCT.md`「品牌约定」 |\n", p.Pigeonbeam.WireProtocol, p.Pigeonbeam.WireFloor)
	fmt.Fprintf(&b, "| p2p 版本线 | **%s** | `release/train.yaml` `lib.p2p`；p2p 仓对应 tag 的 Release |\n", p.Pigeonbeam.P2PPin)
	fmt.Fprintf(&b, "| N-1 协商窗口 | **自 p2p %s 起** | p2p `docs/PRODUCT.md` Phase 2①：版本帧 `{proto, floor}`，`agreed=min(双方 proto)`；v4 floor 恒等于 proto |\n", p.Pigeonbeam.NMinusOneSince)
	fmt.Fprintf(&b, "| v4 客户端兼容承诺 | **至少到 %s** | 与当前产品线同窗口；兼容期只延长不缩短 |\n", p.Pigeonbeam.CompatUntil)
	b.WriteString("| wire v5 的前置条件 | **必须双格式（v4 + v5）** | p2p `docs/PRODUCT.md`：wire 破坏性变更（v5 起）必须带 N-1 双格式实现，否则不得升 proto |\n")
	b.WriteString(supportBeamEnd)
	return b.String()
}

// UpdateMarkedBlock 替换 begin/end 之间的内容；块不存在则追加到文末。
func UpdateMarkedBlock(content, begin, end, block string) string {
	if i := strings.Index(content, begin); i >= 0 {
		if j := strings.Index(content[i:], end); j >= 0 {
			j = i + j + len(end)
			return content[:i] + block + content[j:]
		}
	}
	content = strings.TrimRight(content, "\n")
	if content != "" {
		content += "\n\n"
	}
	return content + block + "\n"
}

func supportStatusLabel(status string) string {
	switch status {
	case "supported":
		return "✅ 支持"
	case "critical":
		return "⚠️ 仅高危/严重"
	case "eol":
		return "❌ EOL"
	default:
		return status
	}
}

func supportSecurityLabel(security string) string {
	switch security {
	case "full":
		return "全量安全修复 + 关键缺陷修复"
	case "critical_high":
		return "仅 critical/high 安全修复"
	case "none":
		return "无"
	default:
		return security
	}
}

func escapeTableCell(s string) string {
	return strings.ReplaceAll(s, "|", `\|`)
}

func validSemverTriple(v string) bool {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(v), "v"), ".")
	if len(parts) != 3 {
		return false
	}
	for _, p := range parts {
		if p == "" {
			return false
		}
		if _, err := strconv.Atoi(p); err != nil {
			return false
		}
	}
	return true
}

func majorMinor(v string) string {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(v), "v"), ".")
	if len(parts) < 2 {
		return ""
	}
	return parts[0] + "." + parts[1]
}

func compareMinor(a, b string) int {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	if len(pa) != 2 || len(pb) != 2 {
		return 0
	}
	na, _ := strconv.Atoi(pa[0])
	nb, _ := strconv.Atoi(pb[0])
	if na != nb {
		if na < nb {
			return -1
		}
		return 1
	}
	ma, _ := strconv.Atoi(pa[1])
	mb, _ := strconv.Atoi(pb[1])
	switch {
	case ma < mb:
		return -1
	case ma > mb:
		return 1
	default:
		return 0
	}
}
