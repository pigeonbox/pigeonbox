// status.go —— 进度一屏看(spec 2026-11-13 §5/G5):当前车次/相位/卡点/
// bump PR checks/产物缺口/哨兵 issue。全程只读(采集=远端真相;不写任何东西)。
//
// 两个出口:
//   - `trainctl status`        本地一屏(make train-status)
//   - `trainctl status --markdown`  CI 收尾步写 $GITHUB_STEP_SUMMARY
package main

import (
	"fmt"
	"strings"
)

type statusPR struct {
	name   string
	checks string
	green  bool
}

type statusData struct {
	train, state string
	prs          []statusPR
	openCount    int
	missing      []string
	imagesOK     bool
	stalled      []string
	conclusion   string
}

// collectStatus 只读采集。TrainFile 用 map 构造只读视图
// (checkReleased/imagesReady 只读 tf.Get——已核对 advance.go L351/L549)。
func collectStatus(env *Env) statusData {
	m := trainMapOnOrigin(env)
	tf := &TrainFile{m: m}
	d := statusData{train: m["train"], state: m["state"]}
	if d.state == "" {
		d.state = "(无)"
	}
	if d.train != "" {
		open := listOpenBumpPRs(env, d.train)
		d.openCount = len(open)
		for _, item := range open {
			repo, num, ok := strings.Cut(item, "#")
			if !ok {
				continue
			}
			num = strings.Fields(num)[0]
			checks, green := checksSummary(repo, num)
			d.prs = append(d.prs, statusPR{name: repo + "#" + num, checks: checks, green: green})
		}
		for _, mi := range checkReleased(env, tf) {
			d.missing = append(d.missing, mi.desc)
		}
		d.imagesOK = imagesReady(env, tf)
	}
	d.stalled = listStalledIssues()
	d.conclusion = deriveConclusion(d)
	return d
}

// checksSummary 单个 PR 的 checks 概览(口径与 checksAllGreenLatest 同族:
// 按检查名取最新;空=该仓无 checks 视为就绪)。
// conclusion 是大写枚举(gh --json statusCheckRollup 走 GraphQL)。
func checksSummary(repo, num string) (string, bool) {
	states, ok := checksLatest(repo, num)
	if !ok {
		return "checks 读取失败", false
	}
	if len(states) == 0 {
		return "无 checks(纯脚本仓)", true
	}
	bad := 0
	for _, s := range states {
		switch s.conclusion {
		case "SUCCESS", "SKIPPED", "NEUTRAL":
		default:
			bad++
		}
	}
	if bad > 0 {
		return fmt.Sprintf("%d/%d 未绿", bad, len(states)), false
	}
	return fmt.Sprintf("%d/%d 绿", len(states), len(states)), true
}

// listStalledIssues 开着的哨兵 issue(train-stalled 标签;无则空)。
func listStalledIssues() []string {
	out, err := ghRunner("issue", "list", "-R", hubRepo, "--state", "open",
		"--label", "train-stalled", "--json", "number,title",
		"--jq", `.[] | "#\(.number) \(.title)"`)
	if err != nil {
		return []string{"(哨兵读取失败: " + firstLine(err.Error()) + ")"}
	}
	var res []string
	for _, ln := range splitLines(out) {
		if s := strings.TrimSpace(ln); s != "" {
			res = append(res, s)
		}
	}
	return res
}

// deriveConclusion 一屏最重要的那行:现在卡在哪。
func deriveConclusion(d statusData) string {
	switch d.state {
	case "shipped":
		return "已发货"
	case "tagged", "shipping":
		if !d.imagesOK {
			return "等镜像(server/frontend/p2p)"
		}
		if len(d.missing) > 0 {
			return fmt.Sprintf("等产物(%d 项)", len(d.missing))
		}
		return "产物齐,等终验/收尾"
	case "draft", "(无)":
		if d.openCount > 0 {
			return fmt.Sprintf("等 %d 个 bump PR 合并", d.openCount)
		}
		return "bump 已合,等打 tag"
	default:
		return "state=" + d.state
	}
}

// renderStatus 渲染纯文本/markdown(同一份数据两个出口)。
func renderStatus(d statusData, markdown bool) string {
	var b strings.Builder
	title := fmt.Sprintf("列车 %s · state=%s", orNone(d.train), d.state)
	if markdown {
		fmt.Fprintf(&b, "## 🚂 %s\n\n", title)
	} else {
		fmt.Fprintf(&b, "══ %s\n", title)
	}
	line := func(format string, a ...any) {
		if markdown {
			fmt.Fprintf(&b, "- "+format+"\n", a...)
		} else {
			fmt.Fprintf(&b, "  "+format+"\n", a...)
		}
	}
	line("**卡点:** %s", d.conclusion)
	for _, p := range d.prs {
		mark := "⏳"
		if p.green {
			mark = "✅"
		}
		line("%s %s — %s", mark, p.name, p.checks)
	}
	if len(d.missing) > 0 {
		line("**产物缺口 (%d):** %s", len(d.missing), strings.Join(d.missing, " | "))
	}
	img := "未齐"
	if d.imagesOK {
		img = "齐"
	}
	line("**镜像:** %s", img)
	for _, s := range d.stalled {
		line("**哨兵:** %s", s)
	}
	return b.String()
}

// cmdStatus 入口:--markdown 走 GitHub job summary 形态。
func cmdStatus(env *Env, args []string) {
	md := false
	for _, a := range args {
		if a == "--markdown" {
			md = true
		}
	}
	fmt.Print(renderStatus(collectStatus(env), md))
}
