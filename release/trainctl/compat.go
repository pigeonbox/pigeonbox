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
//     复现步骤(#386 验收:升级失败要有可复现步骤并进下一次回归);
//   - 每格必须带 level(「验到了哪一层」,hub#670):值域封闭三档——
//     hook(跑产物自带的**真实升级钩子** + 回滚点逐字比对)/
//     artifact(只做**制品级**换版:解包/覆盖/数据未变/版本已更新,不跑钩子)/
//     device(**真机级**:真实设备上装→用→升级→回滚)。
//     同一个 verified 在不同平台语义不同(钩子级 ≻ 制品级),不标层级就
//     无法回答「这条升级路径到底被验到了多深」。
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

// 验证层级词表(封闭):验到了哪一层。
//
//	hook    —— 钩子级:跑产物自带的真实升级钩子,回滚点与升级前库逐字一致
//	artifact—— 制品级:只做制品级换版(解包/覆盖/数据未变/版本已更新),不跑钩子
//	device  —— 真机级:真实设备/系统上装→用→升级→回滚全流程
//
// 深度序(断言覆盖面):artifact < hook < device。
var compatLevels = []string{"hook", "artifact", "device"}

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
	// Level 声明该格点「验到了哪一层」(hook/artifact/device,值域封闭)。
	//
	//	verified   ⇒ 实际达到的层级(可以高于该平台的机械上限:fnos N-1 是人工真机)
	//		failed     ⇒ 失败被观察到的层级
	//	unverified ⇒ 该格点计划验的层级(该平台的机械可达上限;desktop 只能 device)
	Level    string `json:"level"`
	Evidence string `json:"evidence,omitempty"`
	Repro    string `json:"repro,omitempty"`
	Updated  string `json:"updated,omitempty"`
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
//   - 每格必须带 level 且 level 在封闭词表内(hook/artifact/device);
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
		// level 必填且值域封闭:同一个 verified 在不同平台语义不同
		// (钩子级 ≻ 制品级),不标层级就答不出「这条路径验到了多深」。
		if strings.TrimSpace(c.Level) == "" {
			add("%s: %s 格点必须带 level(验到了哪一层:可选 %s)", where, c.Status, strings.Join(compatLevels, "/"))
		} else if !known(c.Level, compatLevels) {
			add("%s: 层级非法(可选 %s)", where, strings.Join(compatLevels, "/"))
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

// countCompatLevels 按层级计数(一屏统计用)。
func countCompatLevels(m *CompatMatrix) map[string]int {
	out := map[string]int{}
	for _, c := range m.Cells {
		out[c.Level]++
	}
	return out
}

// compatLevelDepth 层级深度序(断言覆盖面):artifact < hook < device。
//
//	artifact —— 只验了制品级换版(数据未变 + 版本已更新)
//	hook    —— 还跑了真实升级钩子并逐字比对了回滚点(覆盖面 ⊃ artifact)
//	device  —— 真机全流程(覆盖面 ⊃ hook)
func compatLevelDepth(level string) int {
	switch level {
	case "artifact":
		return 1
	case "hook":
		return 2
	case "device":
		return 3
	}
	return 0
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
//
// 每格同时显示**层级**(hook/artifact/device):状态相同不再代表强度相同——
// 「✅ hook」(跑过真实升级钩子 + 回滚点逐字比对)与「✅ artifact」(只做制品级
// 换版)的结论强度差一个量级,必须一眼可辨。同状态多格时层级取最深。
func renderCompatTable(m *CompatMatrix, platforms []string) string {
	rank := map[string]int{compatVerified: 0, compatUnverified: 1, compatUnsupported: 2, compatFailed: 3}
	type cellView struct {
		status string
		level  string
	}
	views := map[string]cellView{}
	for _, c := range m.Cells {
		key := c.Platform + "\x00" + c.Span
		cur, ok := views[key]
		if !ok {
			views[key] = cellView{status: c.Status, level: c.Level}
			continue
		}
		if rank[c.Status] > rank[cur.status] {
			views[key] = cellView{status: c.Status, level: c.Level}
			continue
		}
		if rank[c.Status] == rank[cur.status] && compatLevelDepth(c.Level) > compatLevelDepth(cur.level) {
			cur.level = c.Level
			views[key] = cur
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "| 平台 | %s |\n", strings.Join(compatSpans, " | "))
	fmt.Fprintf(&b, "|---|%s\n", strings.Repeat("---|", len(compatSpans)))
	for _, p := range platforms {
		row := make([]string, 0, len(compatSpans))
		for _, s := range compatSpans {
			v, ok := views[p+"\x00"+s]
			if !ok {
				row = append(row, "?")
				continue
			}
			row = append(row, compatStatusMark(v.status)+" "+v.level)
		}
		fmt.Fprintf(&b, "| %s | %s |\n", p, strings.Join(row, " | "))
	}
	fmt.Fprintf(&b, "\n层级：hook=钩子级 · artifact=制品级 · device=真机级\n")
	return b.String()
}

// cmdCompat trainctl compat 子命令:
//
//	compat [--check]     一屏矩阵(含层级)+ 红灯清单;--check 有 failed/缺口 ⇒ 退出码 1
//	compat --markdown    渲染 Markdown 表(含层级,贴 docs/发布说明)
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
	lv := countCompatLevels(m)
	fmt.Printf("层级分布：hook %d · artifact %d · device %d\n",
		lv["hook"], lv["artifact"], lv["device"])
	// 失败格点逐个列复现步骤(#386 验收:失败要可复现并进回归)。
	if s.Failed > 0 {
		fmt.Println("\n红灯格点(必须修或显式转 unsupported):")
		for _, c := range m.Cells {
			if c.Status != compatFailed {
				continue
			}
			fmt.Printf("  ✗ %s × %s [%s] %s level=%s\n    证据: %s\n    复现: %s\n",
				c.Platform, c.Span, strings.Join(c.Arches, ","), c.Deploy, c.Level, c.Evidence, c.Repro)
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
