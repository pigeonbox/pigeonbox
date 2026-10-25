package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const trainFileRel = "release/train.yaml"

// TrainFile 是 release/train.yaml 的内存映像:扁平 dotted key,保留原始行序
// (state 单键原地改写;整文件重生成只发生在 bump,见 Render)。
type TrainFile struct {
	path  string
	lines []string
	m     map[string]string
}

func LoadTrainFile(env *Env) (*TrainFile, error) {
	p := filepath.Join(env.Root, trainFileRel)
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("读 %s 失败: %w", trainFileRel, err)
	}
	tf := &TrainFile{path: p, lines: splitLines(strings.TrimRight(string(b), "\n")), m: map[string]string{}}
	for _, ln := range tf.lines {
		k, v, found := parseTrainLine(ln)
		if found {
			tf.m[k] = v
		}
	}
	return tf, nil
}

// Head 从 hub git HEAD 读 train.yaml(v1 tget_head 语义):
// bump 的基线/默认值必须用它——dry-run 残留或工作树改动不得污染判定
// (1.14.6 事故:dry-run 写入的新值被当基线,frontend 段被跳过 PR 漏建)。
func (e *Env) TrainFileHead() (*TrainFile, error) {
	out, err := Git(e.Root, "show", "HEAD:"+trainFileRel)
	if err != nil {
		return nil, err
	}
	tf := &TrainFile{path: "(HEAD)", lines: splitLines(out), m: map[string]string{}}
	for _, ln := range tf.lines {
		k, v, found := parseTrainLine(ln)
		if found {
			tf.m[k] = v
		}
	}
	return tf, nil
}

func parseTrainLine(ln string) (k, v string, found bool) {
	s := strings.TrimSpace(ln)
	if s == "" || strings.HasPrefix(s, "#") {
		return "", "", false
	}
	i := strings.Index(s, ":")
	if i <= 0 {
		return "", "", false
	}
	k = strings.TrimSpace(s[:i])
	v = strings.TrimSpace(s[i+1:])
	v = strings.Trim(v, `"`)
	if k == "" || strings.ContainsAny(k, " \t") {
		return "", "", false
	}
	return k, v, true
}

func (t *TrainFile) Get(key string) string { return t.m[key] }

// trainFileHasTrain 判定工作树里的 release/train.yaml 是否**真的**声明了
// 指定列车号（按 `train:` 键精确比对，不是子串包含）。
//
// 为什么不能只做子串包含（2026-10-25 自踩的修复）：`strings.Contains(content,
// "train: 3.3.2")` 会被 "train: 3.3.28" 命中 ⇒ 守卫形同虚设；
// 更糟的是 "train: 3.3.28" 也会命中 "train: 3.3.280" ⇒ 列车号写错一位照样通过。
//
// 用途：bump 的静默空转守卫（见 bump.go 的 hub()）——bump 写出的 train.yaml
// 必须与目标列车号一致，否则响亮失败（绝不静默空转）。
func trainFileHasTrain(dir, train string) bool {
	content := readContent(dir, trainFileRel)
	if content == "" {
		return false
	}
	for _, ln := range splitLines(content) {
		k, v, found := parseTrainLine(ln)
		if found && k == "train" {
			return v == train
		}
	}
	return false
}

// SetState 原地改写 state 行(保留文件其余字节)。
func (t *TrainFile) SetState(state string) {
	for i, ln := range t.lines {
		if strings.HasPrefix(ln, "state:") {
			t.lines[i] = "state: " + state
			t.m["state"] = state
			return
		}
	}
	t.lines = append(t.lines, "state: "+state)
	t.m["state"] = state
}

// Set 原地改写任意单键(不存在则追加)。
func (t *TrainFile) Set(key, val string) {
	prefix := key + ":"
	for i, ln := range t.lines {
		if strings.HasPrefix(ln, prefix) {
			t.lines[i] = prefix + " " + val
			t.m[key] = val
			return
		}
	}
	t.lines = append(t.lines, prefix+" "+val)
	t.m[key] = val
}

func (t *TrainFile) Save() error {
	return os.WriteFile(t.path, []byte(strings.Join(t.lines, "\n")+"\n"), 0o644)
}

// ───────────────────────── bump 整文件重生成 ─────────────────────────

// TrainParams 是 Render 的输入(全部已在 bump 解析完成)。
type TrainParams struct {
	Train, State                     string
	Hotfix                           bool
	Contracts, Core, Kit, P2P, FCore string
	Server                           string // 镜像号(无 v)
	FETag                            string // frontend tag(带 v)
	Chart, ChartApp                  string
	P2PCRef                          string // Box 包内随带 p2pc 钉版(NAS 三端+server;Phase 2② 起与 lib.p2p 脱钩,空=不落键)
	CorePin                          string
	Platforms                        []string
}

// Render 生成规范 train.yaml(键序/空行/引号与 v1 模板逐字节对齐,仅设计稿行更新)。
func Render(p TrainParams) string {
	var b strings.Builder
	w := func(s string) { b.WriteString(s + "\n") }
	boolStr := func(v bool) string {
		if v {
			return "true"
		}
		return "false"
	}
	w("# PigeonBox 发布列车真相源 —— 一趟列车全部组件版本/钉版/回挂期望的唯一声明。")
	w("# 设计稿: docs/specs/2026-10-12-release-train-v2-design.md;由 release/trainctl bump 生成,勿手改。")
	w(`schema: "1"`)
	w("train: " + p.Train)
	w("state: " + p.State)
	w("hotfix: " + boolStr(p.Hotfix))
	w("")
	w("lib.contracts: " + p.Contracts)
	w("lib.core: " + p.Core)
	w("lib.kit: " + p.Kit)
	w("lib.p2p: " + p.P2P)
	w("lib.frontend-core: " + p.FCore)
	w("images.server: " + p.Server)
	w("images.frontend: " + p.Server)
	w("frontend.tag: " + p.FETag)
	w("")
	w(`charts.chart: "` + p.Chart + `"`)
	w("charts.app: " + p.ChartApp)
	w("")
	w("terminal.desktop.tag: desktop-v" + p.Train)
	w("terminal.desktop.version: " + p.Train)
	// 2026-10-22 Wave B':desktop sidecar 退役 ⇒ terminal.desktop.p2pc 键退休
	// (desktop 不再随包 p2pc;直传改由独立应用 PigeonBeam 提供)。
	if p.P2PCRef != "" {
		// Phase 2②:Box 包内随带 p2pc 独立钉版(缺省冻结,不随 lib.p2p 联动;
		// 空值不落键,旧 yaml 由 verify/bump 回退 lib.p2p 保兼容)
		w("terminal.p2pc_ref: " + p.P2PCRef)
	}
	for _, t := range []string{"fnos", "openwrt", "qnap"} {
		w("terminal." + t + ".tag: v" + p.Train)
		w("terminal." + t + ".version: " + p.Train)
		w("terminal." + t + ".core_pin: " + p.CorePin)
		w("terminal." + t + ".frontend_core_pin: " + p.FCore)
	}
	for _, t := range p.Platforms {
		w("terminal." + t + ".tag: v" + p.Train)
		w("terminal." + t + ".version: " + p.Train)
	}
	w("")
	w(`features.version_files: "true"`)
	return b.String()
}
