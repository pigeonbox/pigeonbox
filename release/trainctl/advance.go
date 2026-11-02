package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// bumpPRRepos 是 bump 会建 PR 的仓(hub 自身名为 pigeonbox;charts 走直推无 PR)。
// bumpPRRepos 是 bump 会建 PR 的仓(hub 自身名为 pigeonbox;charts 走直推无 PR)。
// server 必须在列：漏掉会导致 server bump PR 未合时 tag 照打（裸奔 tag——1.24.0/
// 1.24.1 连续两列车镜像缺当次修复即此因），open-PR 守卫对 server 失明。
var bumpPRRepos = []string{"pigeonbox", "frontend", "server", "fnos", "openwrt", "qnap", "desktop", "synology", "ugreen", "terramaster"}

// stepState 是一个推进步骤的结果(run 的自轮询与 advance 的单步推进共用)。
type stepState int

const (
	stepWaiting stepState = iota // 还没到位,继续等
	stepDone                     // 本阶段完成
	stepFailed                   // 硬失败:列车无法自推进(需人处理)
)

// cmdAdvance 状态机推进:draft →(PR 齐合并)→ tag → tagged →(产物+镜像齐)
// → verify → shipped + hub v<train> tag(Latest 快照)。
// 唤醒源:组件回调 repository_dispatch / sweep / 手动 dispatch / make。
// 幂等可重入:每次推进到能推进的最远处后退出;回调只是唤醒,真相以 GitHub API 实况为准。
func cmdAdvance(env *Env, args []string) {
	tf := syncHubMain(env)
	train := tf.Get("train")
	state := tf.Get("state")
	fmt.Printf("══ advance train=%s state=%s\n", train, state)

	switch state {
	case "draft":
		st, msg := advanceDraft(env, tf)
		switch st {
		case stepDone:
			okf("%s", msg)
		case stepFailed:
			// 与旧语义一致:停滞只告警 + 开哨兵 issue,**不**让 sweep 变红
			// (停滞的真相在 issue 里;sweep 变红只会制造噪声)。
			fmt.Printf("  ⚠ %s\n", msg)
		default:
			fmt.Printf("  ⏳ %s\n", msg)
		}
	case "tagged", "shipping":
		st, msg := advanceTagged(env, tf)
		switch st {
		case stepDone:
			okf("%s", msg)
		case stepFailed:
			fmt.Printf("  ⚠ %s\n", msg)
		default:
			fmt.Printf("  ⏳ %s\n", msg)
		}
	case "shipped":
		okf("列车 %s 已 shipped,无事可做", train)
	default:
		die("未知 state %q(train.yaml)", state)
	}
	_ = args
}

// syncHubMain 把 hub 本地 main 拉齐 origin/main 并重读 train.yaml。
//
// 1.25.2 事故:stale 本地 advance 把 origin train.yaml 回写成旧列车态 ⇒ 拉齐是
// 硬前置(分歧仍响亮失败,交人处理)。
func syncHubMain(env *Env) *TrainFile {
	// 分支守卫:推进必须发生在 main 上。
	// ⚠️ 必须在 pull **之前**判:在列车分支上跑 `git pull --ff-only origin main`
	// 会把 origin/main 合进列车分支 ⇒ 列车分支历史被污染 ⇒ push 被拒。
	if br, _ := Git(env.Root, "rev-parse", "--abbrev-ref", "HEAD"); br != "main" {
		die("hub 当前在 %s 分支,推进须在 main——先 git checkout main", br)
	}
	// ⚠️ 必须**先 fetch**再比较(2026-11-02 修,4.7.0 实录):bump PR 的合并提交
	// 只在远端,本地 origin/main 引用可能是旧的 ⇒ 不 fetch 就比较,rev-list 恒判
	// 「已同步」⇒ 不 pull ⇒ tf 停在旧列车 ⇒ run 的等待环 bumpWaitDecision 永远
	// waitHold ⇒ 90 分钟到点误报「bump PR 未合并」超时——而 PR 其实早已合并
	// (hub#252 14:11 已合、run 却报超时,人工 advance --finalize 才救回来)。
	// 与 bump.go:413「先 fetch」是同款坑的第二处。
	if _, err := Git(env.Root, "fetch", "-q", "origin", "main"); err != nil {
		// fetch 失败不阻断(离线/瞬断),退回本地引用继续判(行为同旧);
		// 下一轮 waitStep 还会再 fetch。响亮告警避免静默陈旧。
		warnf("hub fetch origin/main 失败(%v)——本轮用本地引用判定", firstLine(err.Error()))
	}
	tf := mustTrain(env)
	if out, err := Git(env.Root, "rev-list", "--count", "main...origin/main"); err == nil && out != "0" {
		if behind, _ := Git(env.Root, "rev-list", "--count", "origin/main..main"); behind == "0" {
			// 纯落后，fast-forward 拉齐
			if _, err := Git(env.Root, "pull", "--ff-only", "origin", "main"); err != nil {
				die("hub main 落后 origin 且 ff-only 拉齐失败: %v", err)
			}
			tf = mustTrain(env)
			fmt.Printf("  ↑ hub main 已 ff-only 拉齐 → train=%s state=%s\n", tf.Get("train"), tf.Get("state"))
		} else {
			die("hub 本地 main 与 origin 分歧(本地多 %s 提交),先人工处理: git pull --rebase", behind)
		}
	}
	return tf
}

// advanceDraft 把 draft 态往前推一步:bump PR 全合并 → 打 tag → state=tagged。
//
// 返回 stepDone 表示 tag 已打(可进 tagged 阶段);stepWaiting 表示还在等 PR;
// stepFailed 表示有 bump PR 的检查红了(列车无法自推进,已开哨兵 issue)。
func advanceDraft(env *Env, tf *TrainFile) (stepState, string) {
	train := tf.Get("train")
	open := listOpenBumpPRs(env, train)
	if len(open) > 0 {
		tryMergeReady(open)
		open = listOpenBumpPRs(env, train)
		if len(open) > 0 {
			// 停滞哨兵:checks 有红的 bump PR 意味着列车卡住,sweep 静默等待
			// 无人知——开/更新常驻 issue(train-drift 同模式);绿的已合,
			// 在跑的等下趟唤醒
			if stalled := stalledBumpPRs(open); len(stalled) > 0 {
				reportStalledIssue(train, stalled)
				return stepFailed, fmt.Sprintf("bump PR 停滞(checks 红):%s", strings.Join(stalled, ", "))
			}
			return stepWaiting, fmt.Sprintf("等 %d 个 bump PR 合并:%s", len(open), strings.Join(open, ", "))
		}
	}
	runTag(env, tf)
	return stepDone, "tag 阶段完成(state=tagged);等组件 Release 回挂"
}

// advanceTagged 把 tagged 态往前推一步:镜像齐 → charts 提交 → 产物齐 →
// 全量 verify → shipped + hub 快照 tag。
func advanceTagged(env *Env, tf *TrainFile) (stepState, string) {
	train := tf.Get("train")
	// 时序门:镜像在位才提交 charts(chart 发版即指向列车镜像,先提交会
	// 发布「钉空气」版本;v1 就有此窗口,1.20.0 复盘收口)
	if !imagesReady(env, tf) {
		return stepWaiting, "镜像未齐(server/frontend/p2p),charts 提交暂缓;等回调/sweep"
	}
	commitCharts(env, tf) // 幂等:已对齐自跳
	missing := checkReleased(env, tf)
	if len(missing) > 0 {
		// 停滞哨兵(产物侧):缺失项对应的 Release 流水线已失败=资产永远
		// 不会自己来,状态机无限等——反查 run 结论,失败即开/更新常驻 issue
		if failed := failedReleaseRuns(tf, missing); len(failed) > 0 {
			reportStalledIssue(train, failed)
			return stepFailed, "组件 Release 失败:" + strings.Join(failed, ", ")
		}
		descs := make([]string, 0, len(missing))
		for _, m := range missing {
			descs = append(descs, m.desc)
		}
		return stepWaiting, fmt.Sprintf("产物未齐(%d 项):%s", len(missing), strings.Join(descs, " | "))
	}
	okf("全部产物/镜像/chart 在位")
	fmt.Println("══ 终验(全量 verify,不绿禁止 shipped)")
	// ⚠️ **终验故意传 ci=false**（不是笔误，勿「修正」成 --ci）：
	//   `verify --ci` 走的是**另一套实现**（只查各 NAS 仓 compose 的镜像钉版计数），
	//   而 ci=false 走「本地实现」分支 ⇒ 真的跑 `deploy/nas/sync.sh check --all`
	//   ⇒ 才有 **NAS 三仓与 hub 模板的逐字漂移**检查。
	//   ⇒ 改成 true ⇒ 终验**静默少查一整类漂移**（模板改了没同步 ⇒ 终验照样绿）。
	//   （2026-11-01 实录：4.6.6 终验正是这条路径 ⇒ 撞上 sync.sh 工作区根缺陷，
	//     误报 7 处漂移 ⇒ hub 快照发不出来。根因与修法见 hub#235。）
	if code := cmdVerify(env, false); code != 0 {
		return stepFailed, "verify 未绿——修完再重跑"
	}
	finalize(env, tf)
	return stepDone, "已 shipped(hub 快照 tag 已推)"
}

// finalize 置 state=shipped、提交、打 hub v<train> tag 并推送
// (push 触发 hub release.yml → Latest 快照,notes=trainctl notes)。
func finalize(env *Env, tf *TrainFile) {
	train := tf.Get("train")
	tf.SetState("shipped")
	if err := tf.Save(); err != nil {
		die("写 train.yaml 失败: %v", err)
	}
	commitHubTrainFile(env, tf, "train: ship v"+train)
	// 哨兵回收：列车已发货 ⇒ 当时的停滞/漂移已解除 ⇒ 关掉常驻哨兵 issue
	// （此前只开不关 ⇒ 每个出过停滞的列车都留一个悬账；2026-10-27 清了 4 条）。
	closeSentinelIssues(train)
	dir := env.Root
	tag := "v" + train
	if env.TagExists("pigeonbox", tag) {
		okf("hub tag %s 已存在,跳过", tag)
		return
	}
	head, err := Git(dir, "rev-parse", "origin/main")
	if err != nil {
		die("hub 解析 origin/main 失败: %v", err)
	}
	if _, err := Git(dir, "tag", tag, head); err != nil {
		// 本地已有同名 tag:指向一致则直接推,不一致响亮失败
		if local, lerr := Git(dir, "rev-parse", "-q", "--verify", "refs/tags/"+tag+"^{commit}"); lerr != nil || local != head {
			die("hub 本地 tag %s 已存在且 ≠ origin/main,人工核查", tag)
		}
	}
	if _, err := Git(dir, "push", "-q", "origin", "refs/tags/"+tag); err != nil {
		die("hub 推 tag %s 失败: %v", tag, err)
	}
	if !env.TagExists("pigeonbox", tag) {
		die("hub tag %s push 后远端不可见(静默失败?),人工核查", tag)
	}
	okf("hub %s 已推,release.yml 出 Latest 快照(notes=trainctl notes)", tag)
}

// listOpenBumpPRs 返回全部未合并的 train/<train> bump PR("repo#编号 标题")。
func listOpenBumpPRs(env *Env, train string) []string {
	var open []string
	for _, repo := range bumpPRRepos {
		out, err := Gh("pr", "list", "-R", ghOrg+"/"+repo, "--head", "train/"+train, "--state", "open",
			"--json", "number,title", "--jq", `.[] | "\(.number) \(.title)"`)
		if err != nil {
			warnf("%s PR 查询失败(%v 摘要)", repo, firstLine(err.Error()))
			continue
		}
		for _, ln := range splitLines(out) {
			if ln = strings.TrimSpace(ln); ln != "" {
				open = append(open, repo+"#"+ln)
			}
		}
	}
	return open
}

// tryMergeReady 对 checks 全绿的 bump PR 直接 squash 合并
// (仓未开 auto-merge 或 bump 时开启失败的兜底;branch protection 阻挡时 --admin)。
func tryMergeReady(open []string) {
	for _, item := range open {
		repo, num, ok := strings.Cut(item, "#")
		if !ok {
			continue
		}
		num = strings.Fields(num)[0]
		full := ghOrg + "/" + repo
		// checks 未绿不动;「仓没有任何 check」(纯脚本 NAS 仓)视为就绪,
		// 否则 gh pr checks 恒报 no checks、PR 永远等不到合并。
		//
		// ⚠️ 不用 `gh pr checks` 判绿（2026-10-23 实弹）：它把**重跑前**的失败
		// attempt 也列进来 ⇒ 最新一次已绿仍整体报失败 ⇒ bump PR 永远等不到
		// 合并（列车卡在 draft）。改为按「检查名取最新一次」判定。
		green, hasChecks := checksAllGreenLatest(repo, num)
		if hasChecks && !green {
			continue // 未绿/有失败——留给下次唤醒(失败会由 CI 红着,人来管)
		}
		if _, err := Gh("pr", "merge", num, "-R", full, "--squash", "--delete-branch"); err != nil {
			if _, err2 := Gh("pr", "merge", num, "-R", full, "--squash", "--delete-branch", "--admin"); err2 != nil {
				warnf("%s#%s 合并失败(%v / admin: %v 摘要)", repo, num, firstLine(err.Error()), firstLine(err2.Error()))
				continue
			}
			warnf("%s#%s 经 --admin 合并(branch protection 阻挡,已响亮记录)", repo, num)
			continue
		}
		okf("%s#%s checks 绿,已 squash 合并", repo, num)
	}
}

// checksAllGreenLatest 判断 PR 的 checks 是否全绿 —— **按检查名取最新一次**。
//
// 为什么不用 `gh pr checks`：它按**所有** check run 判定 ⇒ 重跑前的失败 attempt
// 会留在列表里 ⇒ 最新一次已绿仍整体报失败 ⇒ bump PR 永远等不到合并
// （2026-10-23 实弹：NAS 三仓的 lint 重跑绿了，列车仍卡在 draft 半天）。
//
// 返回 (全绿?, 有检查吗)：「仓没有任何 check」（纯脚本 NAS 仓）⇒ 有检查=false
// （调用方按"就绪"处理，与旧语义一致）。
func checksAllGreenLatest(repo, num string) (green, hasChecks bool) {
	states, ok := checksLatest(repo, num)
	if !ok {
		return false, true // 查不到 ⇒ 保守：当作"未绿"，留给下次唤醒
	}
	if len(states) == 0 {
		return true, false
	}
	for _, v := range states {
		switch v.conclusion {
		case "SUCCESS", "SKIPPED", "NEUTRAL":
			// 通过
		case "":
			return false, true // 仍在跑
		default:
			return false, true
		}
	}
	return true, true
}

// checkState 是某个检查项**最新一次** attempt 的结论。
type checkState struct {
	name       string
	workflow   string
	conclusion string
	ts         string
}

// checksLatest 返回 PR 的检查项(按「检查名(+工作流名)」取**最新一次** attempt)。
//
// ⚠️ 必须按最新一次判定:`gh pr checks` 把**重跑前**的失败 attempt 也列进来
// ⇒ 最新一次已绿仍整体报失败 ⇒ bump PR 永远等不到合并(2026-10-23 实弹:
// NAS 三仓的 lint 重跑绿了，列车仍卡在 draft 半天)。合并判定与停滞判定
// 共用这一份实现 ⇒ 两边不会再出现「一边说绿、一边说红」的自相矛盾。
func checksLatest(repo, num string) ([]checkState, bool) {
	out, err := Gh("pr", "view", num, "-R", ghOrg+"/"+repo, "--json", "statusCheckRollup")
	if err != nil {
		return nil, false
	}
	// gh 的 `--json statusCheckRollup` 顶层是**对象** {"statusCheckRollup":[...]}，
	// 直接 unmarshal 到 slice 必然失败 ⇒ 恒返回「不绿」⇒ NAS 三仓（auto-merge 等不到
	// 那个无人产出的 check）永远等不到 --admin 兜底 ⇒ 列车卡在 draft。
	// 2026-10-23 实弹：按「取最新一次 attempt」重写分组逻辑时漏了这层壳。
	var wrapper struct {
		Rollup []struct {
			Name         string `json:"name"`
			WorkflowName string `json:"workflowName"`
			Conclusion   string `json:"conclusion"`
			StartedAt    string `json:"startedAt"`
			CompletedAt  string `json:"completedAt"`
		} `json:"statusCheckRollup"`
	}
	if err := json.Unmarshal([]byte(out), &wrapper); err != nil {
		return nil, false
	}
	// 按 检查名(+工作流名) 分组，取时间戳最大的那条
	latest := map[string]checkState{}
	for _, c := range wrapper.Rollup {
		key := c.WorkflowName + "/" + c.Name
		ts := c.CompletedAt
		if ts == "" {
			ts = c.StartedAt
		}
		if prev, ok := latest[key]; !ok || ts > prev.ts {
			latest[key] = checkState{name: c.Name, workflow: c.WorkflowName, conclusion: c.Conclusion, ts: ts}
		}
	}
	out2 := make([]checkState, 0, len(latest))
	for _, v := range latest {
		out2 = append(out2, v)
	}
	return out2, true
}

// missingItem 缺失项结构化(repo/tag 供失败 run 反查;repo 空=非仓类项)。
type missingItem struct {
	repo, tag, desc string
}

// checkReleased 以 GitHub API 实况核对「tagged → shipped」完成度,返回缺失项。
// 修复 v1 wait-artifacts 的 tag 映射 bug:v1 用 terminal.<t>.tag(=v1.19.0)查 hub
// Release,而回挂 tag 实为 <组件>-v<版本>(fnos-v1.19.0…)——五个组件全撞在 hub
// 快照 tag 命名空间上,等待形同虚设。
func checkReleased(env *Env, tf *TrainFile) []missingItem {
	var missing []missingItem

	// 1) 组件回挂资产(hub Release)
	hubTags := map[string]string{
		"desktop":     tf.Get("terminal.desktop.tag"), // 已带 desktop- 前缀
		"fnos":        "fnos-" + tf.Get("terminal.fnos.tag"),
		"openwrt":     "openwrt-" + tf.Get("terminal.openwrt.tag"),
		"qnap":        "qnap-" + tf.Get("terminal.qnap.tag"),
		"synology":    "synology-" + tf.Get("terminal.synology.tag"),
		"ugreen":      "ugreen-" + tf.Get("terminal.ugreen.tag"),
		"terramaster": "terramaster-" + tf.Get("terminal.terramaster.tag"),
		"p2p":         "p2p-" + tf.Get("lib.p2p"),
	}
	for _, name := range []string{"desktop", "fnos", "openwrt", "qnap", "synology", "ugreen", "terramaster", "p2p"} {
		tag := hubTags[name]
		out, err := Gh("api", "repos/"+hubRepo+"/releases/tags/"+tag, "--jq", ".assets | length")
		if err != nil || strings.TrimSpace(out) == "0" || strings.TrimSpace(out) == "" {
			missing = append(missing, missingItem{repo: name, tag: releaseTagFor(tf, name), desc: fmt.Sprintf("hub Release %s 资产未就绪", tag)})
			continue
		}
		okf("hub Release %s(资产 %s)", tag, strings.TrimSpace(out))
	}

	// 2) ghcr 镜像(server/frontend=列车号;p2p=库线号)
	type img struct{ repo, repoTag, image, imageTag string }
	for _, im := range []img{
		{"server", "v" + tf.Get("images.server"), "server", tf.Get("images.server")},
		{"server", "v" + tf.Get("images.server"), "frontend", tf.Get("images.server")},
		{"p2p", tf.Get("lib.p2p"), "p2p", strings.TrimPrefix(tf.Get("lib.p2p"), "v")},
	} {
		if !imageExists(im.image, im.imageTag) {
			missing = append(missing, missingItem{repo: im.repo, tag: im.repoTag, desc: fmt.Sprintf("ghcr.io/pigeonbox/%s:%s 未发布", im.image, im.imageTag)})
			continue
		}
		okf("ghcr.io/pigeonbox/%s:%s 在位", im.image, im.imageTag)
	}

	// 3) charts 对齐(chart-releaser 由 push main 触发,读 Chart.yaml 实况;
	//    commitCharts 可能刚在同一 run 里推过,先 fetch 保证不读本 run 起点的陈旧检出)
	if dir, ok := env.RepoDir("charts"); ok {
		_, _ = Git(dir, "fetch", "-q", "origin", "main")
	}
	if cyaml, err := env.Raw("charts/main/charts/pigeonbox/Chart.yaml"); err == nil {
		if got := yamlTopKey(cyaml, "version:"); got != tf.Get("charts.chart") {
			missing = append(missing, missingItem{repo: "charts", desc: fmt.Sprintf("chart version=%s ≠ %s", orNone(got), tf.Get("charts.chart"))})
		} else if gotApp := yamlTopKey(cyaml, "appVersion:"); gotApp != tf.Get("charts.app") {
			missing = append(missing, missingItem{repo: "charts", desc: fmt.Sprintf("chart appVersion=%s ≠ %s", orNone(gotApp), tf.Get("charts.app"))})
		} else {
			okf("chart %s(app %s)已落地", got, tf.Get("charts.app"))
		}
	} else {
		missing = append(missing, missingItem{repo: "charts", desc: "charts Chart.yaml 拉取失败"})
	}
	return missing
}

// releaseTagFor 组件仓的 release tag(tag push 触发 Release 的引用)。
func releaseTagFor(tf *TrainFile, repo string) string {
	switch repo {
	case "desktop":
		return tf.Get("terminal.desktop.tag")
	case "p2p":
		return tf.Get("lib.p2p")
	default:
		if t := tf.Get("terminal." + repo + ".tag"); t != "" {
			return t
		}
		return "v" + tf.Get("images.server") // server/frontend 等
	}
}

// failedReleaseRuns 反查缺失项对应仓的 release 流水线是否已失败——
// 失败=列车停滞(资产永远不会自己来),供停滞哨兵上报。
func failedReleaseRuns(tf *TrainFile, missing []missingItem) []string {
	var failed []string
	for _, m := range missing {
		if m.repo == "" {
			continue
		}
		args := []string{"run", "list", "-R", ghOrg + "/" + m.repo, "--workflow", "release.yml",
			"--limit", "1", "--json", "conclusion,url", "--jq", `.[] | "\(.conclusion) \(.url)"`}
		if m.tag != "" {
			args = append(args, "--branch", m.tag)
		}
		out, err := Gh(args...)
		if err != nil || out == "" {
			continue
		}
		if strings.HasPrefix(out, "failure") {
			failed = append(failed, fmt.Sprintf("%s Release 失败: %s(%s)", m.repo, strings.Fields(out)[1], m.desc))
		}
	}
	return failed
}

// stalledBumpPRs 返回 checks 有失败项的 open bump PR(停滞判定;
// "no checks" 的纯脚本仓不算停滞——无 check 即就绪)。
//
// ⚠️ 判定必须按「最新一次 attempt」(与合并判定同一份实现):`gh pr checks` 会把
// **重跑前**的失败 attempt 也列进来 ⇒ CI 重跑绿了仍被判停滞 ⇒ 哨兵误报、
// 且会让 run 的「快速失败」误杀正在恢复的车。
func stalledBumpPRs(open []string) []string {
	var stalled []string
	for _, item := range open {
		repo, num, ok := strings.Cut(item, "#")
		if !ok {
			continue
		}
		num = strings.Fields(num)[0]
		states, ok := checksLatest(repo, num)
		if !ok || len(states) == 0 {
			continue // 查不到 / 仓无 check ⇒ 不算停滞
		}
		if bad := failedCheckNames(states); len(bad) > 0 {
			stalled = append(stalled, item+"("+strings.Join(bad, ",")+")")
		}
	}
	return stalled
}

// failedCheckNames 返回「最新一次 attempt 为失败」的检查项描述。
func failedCheckNames(states []checkState) []string {
	var out []string
	for _, s := range states {
		switch strings.ToLower(s.conclusion) {
		case "failure", "cancelled", "timed_out", "action_required", "startup_failure":
			out = append(out, s.name+" "+s.conclusion)
		}
	}
	return out
}

// reportStalledIssue 常驻 issue 哨兵(train-drift 同模式:单 issue 追加防刷屏)。
// 覆盖两类停滞:bump PR checks 红(合并不了)/ 组件 Release 失败(资产永远不来)。
// 哨兵失败只告警,不阻断状态机。
//
// ⚠️ **按 label 查，不按标题搜**（2026-10-27 清账实录）：GitHub 搜索索引有延迟，
// 刚建/刚改的 issue 可能搜不到 ⇒ 走创建路径 ⇒ 每个出过停滞的列车都多一个
// issue（实测 hub 悬着 3.3.3 / 1.25.1 / 1.23.0 三条，而这几趟车早已发货）。
// label 是精确匹配、无索引延迟 ⇒ 恒定命中同一条常驻 issue（标题也固定，
// 列车号放正文；否则标题会停在首个列车的号上，与正文对不上）。
func reportStalledIssue(train string, stalled []string) {
	body := fmt.Sprintf("列车 %s 停滞——以下环节失败,状态机无法自推进(修复后重跑对应流水线或人工推进):\n\n", train)
	for _, s := range stalled {
		body += "- " + s + "\n"
	}
	body += fmt.Sprintf("\n[最近一轮 sweep](https://github.com/%s/actions/workflows/train-orchestrator.yml)", hubRepo)
	if !GhOK("label", "create", "train-stalled", "-R", hubRepo, "--color", "D93F0B", "--description", "列车停滞(PR 检查或组件 Release 失败)", "--force") {
		warnf("train-stalled label 创建失败(忽略,继续开 issue)")
	}
	num, err := ghRun("issue", "list", "-R", hubRepo, "--state", "open", "--label", "train-stalled",
		"--json", "number", "--jq", ".[0].number")
	if err == nil && num != "" {
		if _, err := ghRun("issue", "comment", num, "-R", hubRepo, "--body", body); err != nil {
			warnf("train-stalled issue 评论失败: %v", firstLine(err.Error()))
		}
		return
	}
	if _, err := ghRun("issue", "create", "-R", hubRepo, "--label", "train-stalled",
		"--title", "🚂 train-stalled: 发布列车停滞", "--body", body); err != nil {
		warnf("train-stalled issue 创建失败: %v", firstLine(err.Error()))
	}
}

// closeSentinelIssues 哨兵回收：列车发货 ⇒ 停滞/漂移哨兵全部关闭。
//
// 背景（2026-10-27 清账实录）：哨兵此前**只开不关** —— reportStalledIssue 只有
// open/comment 路径，全流程没有任何关闭 ⇒ 每个出过停滞的列车都留一个悬账
// （实测 hub 悬着 3.3.3 / 1.25.1 / 1.23.0 三条停滞 + 一条 10-07 的漂移哨兵，
// 而这些列车早已发货）⇒ 台账越积越多，噪声掩盖真问题。
//
// 关闭条件：列车已 shipped（state 落库 + hub 提交）⇒ 当时的停滞/漂移已解除。
// 关闭失败只告警不阻断（issue 写权限是 best-effort：本地无 token / CI token 权限
// 不足时不该拦住发车）。
func closeSentinelIssues(train string) {
	for _, label := range []string{"train-stalled", "train-drift"} {
		out, err := ghRun("issue", "list", "-R", hubRepo, "--state", "open", "--label", label,
			"--json", "number", "--jq", ".[].number")
		if err != nil {
			warnf("%s 哨兵列表失败(忽略): %v", label, firstLine(err.Error()))
			continue
		}
		for _, num := range strings.Fields(out) {
			if num == "" {
				continue
			}
			comment := fmt.Sprintf("列车 %s 已发货（state=shipped，全量 verify 绿）⇒ 当时的停滞/漂移已解除，本哨兵自动关闭。", train)
			if _, err := ghRun("issue", "close", num, "-R", hubRepo, "--comment", comment); err != nil {
				warnf("关闭 %s 哨兵 issue #%s 失败(忽略): %v", label, num, firstLine(err.Error()))
				continue
			}
			okf("已关闭 %s 哨兵 issue #%s", label, num)
		}
	}
}

// imagesReady 只查镜像(server/frontend=列车号;p2p=库线号),供 charts 时序门用。
func imagesReady(env *Env, tf *TrainFile) bool {
	serverV := tf.Get("images.server")
	p2pV := strings.TrimPrefix(tf.Get("lib.p2p"), "v")
	for _, img := range [][2]string{{"server", serverV}, {"frontend", serverV}, {"p2p", p2pV}} {
		if !imageExists(img[0], img[1]) {
			return false
		}
	}
	return true
}

// imageExists 判定镜像是否已发布。三条路，依次回落：
//
//  1. ghcr packages API（需 token 带 read:packages；机器人 classic PAT 具备）；
//  2. **registry HTTP API**（公开镜像**匿名可查**，只要能出网）；
//  3. docker pull 回落（v1 同款，但要求本机 docker daemon 可用且代理正常）。
//
// 为什么必须有第 2 条（2026-10-31 实测）：
//
//	本机 gh token 是 `repo` scope（**不含** read:packages）⇒ 第 1 条不可用；
//	而第 3 条在本机也不通（Docker Desktop 配了失效的手动代理 ⇒ docker pull
//	直接 refused）⇒ 两条路都失败 ⇒ **误判「镜像未齐」** ⇒ 列车卡在 tagged
//	（而实际镜像早已发布）。
//	⇒ 第 2 条只需能出网 + 公开镜像可匿名查 ⇒ 在绝大多数环境下都可用。
func imageExists(name, tag string) bool {
	out, err := Gh("api", fmt.Sprintf("/orgs/%s/packages/container/%s/versions?per_page=100", ghOrg, name),
		"--jq", "[.[].metadata.container.tags[]]")
	if err == nil && strings.Contains(out, `"`+tag+`"`) {
		return true
	}
	if registryHasTag(ghOrg, name, tag) {
		return true
	}
	return runQuiet("docker", "pull", "-q", "ghcr.io/"+ghOrg+"/"+name+":"+tag) == nil
}

// registryHasTag 用 registry HTTP API 判镜像 tag 是否存在（公开镜像匿名可查）。
//
// ⚠️ **必须先取匿名 pull token 再带 token 探 manifest**（2026-10-31 实测的假绿）：
//
//	ghcr 对**不带 token** 的 manifest 请求**恒回 401**
//	（实测：4.6.4 已存在 ⇒ 401；4.6.5 未发布 ⇒ 也是 401）⇒
//	若把 401 当「算存在」⇒ **这个探测恒为真 ⇒ 从来没真的检查过镜像**。
//	⇒ 而列车据此判定「镜像在位」⇒ **会在镜像还没推完时就发车**
//	（实测 4.6.5：server 镜像的 manifest 此刻仍是 404，列车却报「在位」）。
//
// 正确口径：
//
//	① 取匿名 pull token（`/token?scope=repository:<repo>:pull`）——公开镜像允许匿名；
//	② 带 token 探 manifest ⇒ **404 才是真「不存在」**；
//	③ 取不到 token / 401 / 403 / 5xx ⇒ **无法判定 ⇒ 保守判「不存在」**
//	   （宁可等下一轮 sweep 再探，也不要在探测不可靠时把列车推到「产物齐」）。
func registryHasTag(org, name, tag string) bool {
	return registryHasTagAt("https://ghcr.io", org, name, tag)
}

// registryHasTagAt 是 registryHasTag 的可测版本（baseURL 可注入 ⇒ 单测用
// httptest 起本地假 registry 打**真实函数**，而不是测一份副本）。
//
// 单元测试若只测「另写一份同逻辑的副本」⇒ 真实代码改了它照样全绿
// ⇒ 门禁是摆设。⇒ 判定逻辑必须在**被测的那个函数**里。
func registryHasTagAt(baseURL, org, name, tag string) bool {
	client := &http.Client{Timeout: 20 * time.Second}
	repo := org + "/" + name

	// ① 匿名 pull token（拿不到 ⇒ 无法判定 ⇒ 保守判「不存在」）
	tok, ok := registryPullToken(client, baseURL, repo)
	if !ok {
		return false
	}

	// ② 带 token 探 manifest
	req, err := http.NewRequest("HEAD",
		baseURL+"/v2/"+repo+"/manifests/"+tag, nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", strings.Join([]string{
		"application/vnd.oci.image.index.v1+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
		"application/vnd.oci.image.manifest.v1+json",
		"application/vnd.docker.distribution.manifest.v2+json",
	}, ", "))
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	// 只有 200 算「已发布」；其余（404 不存在 / 401 token 无效 / 5xx 探测异常）
	// 一律判「不存在」——宁可等下一轮 sweep 再探。
	return resp.StatusCode == 200
}

// registryPullToken 取 registry 的匿名 pull token（公开镜像允许匿名拉）。
// 取不到 ⇒ (空串, false) ⇒ 调用方按「无法判定」处理。
func registryPullToken(client *http.Client, baseURL, repo string) (string, bool) {
	host := baseURL
	if u, err := url.Parse(baseURL); err == nil && u.Host != "" {
		host = u.Host
	}
	tokenURL := fmt.Sprintf("%s/token?scope=repository:%s:pull&service=%s",
		baseURL, repo, url.QueryEscape(host))
	resp, err := client.Get(tokenURL)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var payload struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", false
	}
	if payload.Token == "" {
		return "", false
	}
	return payload.Token, true
}
