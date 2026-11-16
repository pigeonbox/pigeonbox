// compat.go —— 跨平台升级兼容矩阵实验室(pigeonbox#386)。
//
// 六平台适配仓(fnOS / OpenWrt+iStoreOS / Synology DSM / QNAP QTS / UGREEN
// UGOS / TeraMaster TOS)+ desktop 的升级路径、数据布局、包格式各不相同;
// 此前「谁验过哪条路径、哪些跨度根本没人走过」无法回答——验证靠发版时逐仓
// 真机冒烟,结论散落在 issue 与发布说明里。
//
// 本文件把矩阵落成**机器可读真相源** release/compat-matrix.json:
//   - 维度:平台 × 版本跨度(N-1 / N-2 / 跨大版本)× 架构(amdg64/arm64/armv7
//     在格点内声明)× 部署形态(native/compose/k8s);
//   - 每格状态四态:verified / failed / unverified / unsupported——**「未验」
//     是一等状态**:没有验过的格点必须诚实登记,而不是从表里消失(缺口看不见
//     比红灯更危险);
//   - verified / failed 必须带证据(issue/PR/run 链接);failed 还必须带最小
//     复现步骤(#386 验收:升级失败要有可复现步骤并进下一次回归)。
//
// 判定口径(为什么 unverified 不判红):要求「全绿」才能发车,在矩阵刚建立
// 时等价于永远发不了车——那是逼人填假绿。故 `--check` 只把 failed 判红,
// unverified 报黄计数;缺口(某平台某跨度一格都没有)判红——缺格是「没人
// 负责」,与「有人负责但还没验」不同。preflight 发车闸用同一口径。
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	compatRel    = "release/compat-matrix.json"
	compatSchema = "1"
)

// 格点状态的合法值。unverified 是一等状态(见文件头注释)。
const (
	compatVerified    = "verified"
	compatFailed      = "failed"
	compatUnverified  = "unverified"
	compatUnsupported = "unsupported"
)

// 版本跨度词表:相邻版、隔一版、跨大版本。
var compatSpans = []string{"N-1", "N-2", "major-cross"}

// 部署形态词表。
var compatDeploys = []string{"native", "compose", "k8s"}

// 架构词表。
var compatArches = []string{"amd64", "arm64", "armv7"}

// CompatMatrix 是 release/compat-matrix.json 的内存映像。
type CompatMatrix struct {
	Schema  string       `json:"schema"`
	Updated string       `json:"updated"`
	Cells   []CompatCell `json:"cells"`
}

// CompatCell 一个可执行格点。
//
// Arches 是该格点覆盖的架构集合(一个格点可以一次验多个架构);`unsupported`
// 允许为空 = 该平台该跨度整体不适用(如 desktop 无 NAS 包)。
type CompatCell struct {
	Platform string   `json:"platform"`
	Span     string   `json:"span"`
	Arches   []string `json:"arches"`
	Deploy   string   `json:"deploy"`
	Status   string   `json:"status"`
	Evidence string   `json:"evidence,omitempty"`
	Repro    string   `json:"repro,omitempty"`
	Updated  string   `json:"updated,omitempty"`
}

// loadCompat 读矩阵文件(不存在即报错:缺文件不是「未验」,是实验室没建)。
func loadCompat(root string) (*CompatMatrix, error) {
	path := filepath.Join(root, compatRel)
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读 %s: %w", compatRel, err)
	}
	var m CompatMatrix
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("解析 %s: %w", compatRel, err)
	}
	return &m, nil
}

// compatPlatforms 从 train.yaml 的 terminal.<name>.tag 键导出平台清单
// (矩阵的横轴真相源与列车同一份,不另维护平台名单)。
func compatPlatforms(tf *TrainFile) []string {
	var out []string
	for k := range tf.m {
		if !strings.HasPrefix(k, "terminal.") || !strings.HasSuffix(k, ".tag") {
			continue
		}
		name := strings.TrimSuffix(strings.TrimPrefix(k, "terminal."), ".tag")
		if name == "" || name == "p2pc_ref" {
			continue
		}
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// validateCompat 校验矩阵自洽性与覆盖完备性。返回的错误列表为空即通过:
//   - schema/updated 必需;
//   - 平台必须在 train.yaml 的 terminal 清单内、跨度/部署/状态/架构在词表内;
//   - verified/failed 必须有 evidence;failed 还必须有 repro;
//   - 每个平台 × 每个跨度至少要有一个格点(缺口判红——「没人负责」)。
func validateCompat(m *CompatMatrix, platforms []string) []string {
	var errs []string
	add := func(format string, args ...any) { errs = append(errs, fmt.Sprintf(format, args...)) }
	if m.Schema != compatSchema {
		add("schema 应为 %q,实际 %q", compatSchema, m.Schema)
	}
	if strings.TrimSpace(m.Updated) == "" {
		add("updated 不能为空(记录矩阵最近一次核对日期)")
	}
	known := func(s string, set []string) bool {
		for _, v := range set {
			if v == s {
				return true
			}
		}
		return false
	}
	platformOK := func(p string) bool {
		for _, v := range platforms {
			if v == p {
				return true
			}
		}
		return false
	}
	// 覆盖完备性:平台 × 跨度。
	have := map[string]bool{}
	for i, c := range m.Cells {
		where := fmt.Sprintf("cells[%d] %s/%s", i, c.Platform, c.Span)
		if !platformOK(c.Platform) {
			add("%s: 平台不在 train.yaml terminal 清单(%s)", where, strings.Join(platforms, "/"))
		}
		if !known(c.Span, compatSpans) {
			add("%s: 跨度非法(可选 %s)", where, strings.Join(compatSpans, "/"))
		}
		if !known(c.Deploy, compatDeploys) {
			add("%s: 部署形态非法(可选 %s)", where, strings.Join(compatDeploys, "/"))
		}
		if !known(c.Status, []string{compatVerified, compatFailed, compatUnverified, compatUnsupported}) {
			add("%s: 状态非法(可选 verified/failed/unverified/unsupported)", where)
		}
		if c.Status != compatUnsupported && len(c.Arches) == 0 {
			add("%s: 非 unsupported 格点必须声明 arches", where)
		}
		for _, a := range c.Arches {
			if !known(a, compatArches) {
				add("%s: 架构 %q 非法(可选 %s)", where, a, strings.Join(compatArches, "/"))
			}
		}
		if (c.Status == compatVerified || c.Status == compatFailed) && strings.TrimSpace(c.Evidence) == "" {
			add("%s: %s 格点必须带 evidence(issue/PR/run 链接)", where, c.Status)
		}
		if c.Status == compatFailed && strings.TrimSpace(c.Repro) == "" {
			add("%s: failed 格点必须带最小复现步骤 repro", where)
		}
		if c.Status != compatUnsupported {
			have[c.Platform+"\x00"+c.Span] = true
		}
	}
	for _, p := range platforms {
		for _, s := range compatSpans {
			if !have[p+"\x00"+s] {
				add("缺口: %s × %s 没有任何格点登记(unverified 也必须显式登记,不接受缺格)", p, s)
			}
		}
	}
	return errs
}

// compatStats 按状态计数(一屏统计用)。
type compatStats struct {
	Verified    int
	Failed      int
	Unverified  int
	Unsupported int
}

func countCompat(m *CompatMatrix) compatStats {
	var s compatStats
	for _, c := range m.Cells {
		switch c.Status {
		case compatVerified:
			s.Verified++
		case compatFailed:
			s.Failed++
		case compatUnverified:
			s.Unverified++
		case compatUnsupported:
			s.Unsupported++
		}
	}
	return s
}

// compatStatusMark 一屏渲染用的状态符号:绿/红/白/灰。
func compatStatusMark(status string) string {
	switch status {
	case compatVerified:
		return "✅"
	case compatFailed:
		return "❌"
	case compatUnverified:
		return "⬜"
	case compatUnsupported:
		return "—"
	}
	return "?"
}

// renderCompatTable 渲染「平台 × 跨度」摘要表(格点内状态用符号聚合;
// 同一平台同一跨度可能有多个格点,按 绿>红>未验>不支持 的优先序显示最坏项——
// 聚合显示取最坏,避免「一个绿盖住同格的红」)。
func renderCompatTable(m *CompatMatrix, platforms []string) string {
	rank := map[string]int{compatVerified: 0, compatUnverified: 1, compatUnsupported: 2, compatFailed: 3}
	cell := map[string]string{}
	for _, c := range m.Cells {
		key := c.Platform + "\x00" + c.Span
		cur, ok := cell[key]
		if !ok || rank[c.Status] > rank[cur] {
			cell[key] = c.Status
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "| 平台 | %s |\n", strings.Join(compatSpans, " | "))
	fmt.Fprintf(&b, "|---|%s\n", strings.Repeat("---|", len(compatSpans)))
	for _, p := range platforms {
		row := make([]string, 0, len(compatSpans))
		for _, s := range compatSpans {
			row = append(row, compatStatusMark(cell[p+"\x00"+s]))
		}
		fmt.Fprintf(&b, "| %s | %s |\n", p, strings.Join(row, " | "))
	}
	return b.String()
}

// cmdCompat trainctl compat 子命令:
//
//	compat [--check]     一屏矩阵 + 红灯清单;--check 有 failed/缺口 ⇒ 退出码 1
//	compat --markdown    渲染 Markdown 表(贴 docs/发布说明)
func cmdCompat(env *Env, args []string) int {
	check, markdown := false, false
	for _, a := range args {
		switch a {
		case "--check":
			check = true
		case "--markdown":
			markdown = true
		default:
			fmt.Fprintf(os.Stderr, "未知参数 %q(用法: trainctl compat [--check] [--markdown])\n", a)
			return 2
		}
	}
	m, err := loadCompat(env.Root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "✗ compat: %v\n", err)
		return 1
	}
	tf := mustTrain(env)
	platforms := compatPlatforms(tf)
	if len(platforms) == 0 {
		fmt.Fprintln(os.Stderr, "✗ compat: train.yaml 未声明任何 terminal 平台")
		return 1
	}
	verrs := validateCompat(m, platforms)
	if len(verrs) > 0 {
		fmt.Fprintf(os.Stderr, "✗ compat 矩阵不自洽(%d 项):\n", len(verrs))
		for _, e := range verrs {
			fmt.Fprintf(os.Stderr, "  - %s\n", e)
		}
		return 1
	}
	if markdown {
		fmt.Print(renderCompatTable(m, platforms))
		return 0
	}
	s := countCompat(m)
	fmt.Printf("兼容矩阵(updated %s): %d 格点 · ✅%d / ❌%d / ⬜%d / —%d\n",
		m.Updated, len(m.Cells), s.Verified, s.Failed, s.Unverified, s.Unsupported)
	fmt.Print(renderCompatTable(m, platforms))
	// 失败格点逐个列复现步骤(#386 验收:失败要可复现并进回归)。
	if s.Failed > 0 {
		fmt.Println("\n红灯格点(必须修或显式转 unsupported):")
		for _, c := range m.Cells {
			if c.Status != compatFailed {
				continue
			}
			fmt.Printf("  ✗ %s × %s [%s] %s\n    证据: %s\n    复现: %s\n",
				c.Platform, c.Span, strings.Join(c.Arches, ","), c.Deploy, c.Evidence, c.Repro)
		}
	}
	if s.Unverified > 0 {
		fmt.Printf("\n黄灯: %d 个格点未验(诚实登记即可发车,但不得从矩阵里消失)\n", s.Unverified)
	}
	if check && s.Failed > 0 {
		fmt.Fprintf(os.Stderr, "\n✗ compat --check: %d 个红灯格点\n", s.Failed)
		return 1
	}
	return 0
}

// gateCompat 发车前的兼容矩阵闸:红灯 ⇒ 拒绝发车;缺口/不自洽 ⇒ 拒绝发车;
// 未验 ⇒ 只报黄(不阻断——见文件头「为什么 unverified 不判红」)。
func gateCompat(env *Env, tf *TrainFile) error {
	m, err := loadCompat(env.Root)
	if err != nil {
		return err
	}
	platforms := compatPlatforms(tf)
	if len(platforms) == 0 {
		return fmt.Errorf("train.yaml 未声明任何 terminal 平台")
	}
	if verrs := validateCompat(m, platforms); len(verrs) > 0 {
		return fmt.Errorf("矩阵不自洽(%d 项,首项: %s)", len(verrs), verrs[0])
	}
	s := countCompat(m)
	if s.Failed > 0 {
		return fmt.Errorf("%d 个红灯格点(见 trainctl compat 的复现清单)", s.Failed)
	}
	if s.Unverified > 0 {
		fmt.Printf("  ⚠ compat: %d 个格点未验(不阻断,登记在案)\n", s.Unverified)
	}
	return nil
}
