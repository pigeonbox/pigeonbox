package main

import (
	"fmt"
	"strings"
)

// bumpPRRepos 是 bump 会建 PR 的仓(hub 自身名为 pigeonbox;charts 走直推无 PR)。
// bumpPRRepos 是 bump 会建 PR 的仓(hub 自身名为 pigeonbox;charts 走直推无 PR)。
// server 必须在列：漏掉会导致 server bump PR 未合时 tag 照打（裸奔 tag——1.24.0/
// 1.24.1 连续两列车镜像缺当次修复即此因），open-PR 守卫对 server 失明。
var bumpPRRepos = []string{"pigeonbox", "frontend", "server", "fnos", "openwrt", "qnap", "desktop", "synology", "ugreen", "terramaster"}

// cmdAdvance 状态机推进:draft →(PR 齐合并)→ tag → tagged →(产物+镜像齐)
// → verify → shipped + hub v<train> tag(Latest 快照)。
// 唤醒源:组件回调 repository_dispatch / 15 分钟 sweep / 手动 dispatch / make。
// 幂等可重入:每次推进到能推进的最远处后退出;回调只是唤醒,真相以 GitHub API 实况为准。
func cmdAdvance(env *Env, args []string) {
	// --finalize 仅为 make train-finalize 语义兼容,行为与无参一致(能进则进)
	tf := mustTrain(env)
	train := tf.Get("train")
	state := tf.Get("state")
	fmt.Printf("══ advance train=%s state=%s\n", train, state)

	// hub 本地 main 落后 origin 时自动 ff-only 拉齐（1.25.2 事故：stale 本地
	// advance 把 origin train.yaml 回写成旧列车态）。分歧（有本地提交）仍 die。
	if out, err := Git(env.Root, "rev-list", "--count", "main...origin/main"); err == nil && out != "0" {
		if behind, _ := Git(env.Root, "rev-list", "--count", "origin/main..main"); behind == "0" {
			// 纯落后，fast-forward 拉齐
			if _, err := Git(env.Root, "pull", "--ff-only", "origin", "main"); err != nil {
				die("hub main 落后 origin 且 ff-only 拉齐失败: %v", err)
			}
			tf = mustTrain(env)
			train, state = tf.Get("train"), tf.Get("state")
			fmt.Printf("  ↑ hub main 已 ff-only 拉齐 → train=%s state=%s\n", train, state)
		} else {
			die("hub 本地 main 与 origin 分歧(本地多 %s 提交),先人工处理: git pull --rebase", behind)
		}
	}

	switch state {
	case "draft":
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
				}
				fmt.Printf("  ⏳ 等 bump PR 合并(checks 绿后由 sweep/回调收尾):\n    %s\n", strings.Join(open, "\n    "))
				return
			}
		}
		runTag(env, tf)
		fmt.Println("  ✓ tag 阶段完成;等组件 Release 回挂(下次唤醒核对产物)")
	case "tagged", "shipping":
		// 时序门:镜像在位才提交 charts(chart 发版即指向列车镜像,先提交会
		// 发布「钉空气」版本;v1 就有此窗口,1.20.0 复盘收口)
		if !imagesReady(env, tf) {
			fmt.Println("  ⏳ 镜像未齐(server/frontend/p2p),charts 提交暂缓;等回调/sweep")
			return
		}
		commitCharts(env, tf) // 幂等:已对齐自跳
		missing := checkReleased(env, tf)
		if len(missing) > 0 {
			// 停滞哨兵(产物侧):缺失项对应的 Release 流水线已失败=资产永远
			// 不会自己来,状态机无限等——反查 run 结论,失败即开/更新常驻 issue
			if failed := failedReleaseRuns(tf, missing); len(failed) > 0 {
				reportStalledIssue(train, failed)
			}
			descs := make([]string, 0, len(missing))
			for _, m := range missing {
				descs = append(descs, m.desc)
			}
			fmt.Printf("  ⏳ 产物未齐(%d 项),等回调/sweep:\n    %s\n", len(missing), strings.Join(descs, "\n    "))
			return
		}
		okf("全部产物/镜像/chart 在位")
		fmt.Println("══ 终验(全量 verify,不绿禁止 shipped)")
		if code := cmdVerify(env, false); code != 0 {
			die("verify 未绿——以上 ✗ 项修复后重跑 advance")
		}
		finalize(env, tf)
	case "shipped":
		okf("列车 %s 已 shipped,无事可做", train)
	default:
		die("未知 state %q(train.yaml)", state)
	}
	_ = args
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
		// 否则 gh pr checks 恒报 no checks、PR 永远等不到合并
		if _, err := Gh("pr", "checks", num, "-R", full); err != nil {
			if !strings.Contains(err.Error(), "no checks") {
				continue // 未绿/有失败——留给下次唤醒(失败会由 CI 红着,人来管)
			}
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
func stalledBumpPRs(open []string) []string {
	var stalled []string
	for _, item := range open {
		repo, num, ok := strings.Cut(item, "#")
		if !ok {
			continue
		}
		num = strings.Fields(num)[0]
		out, err := Gh("pr", "checks", num, "-R", ghOrg+"/"+repo)
		if err != nil && strings.Contains(err.Error(), "no checks") {
			continue
		}
		for _, ln := range splitLines(out) {
			f := strings.Fields(ln)
			if len(f) >= 2 && f[1] == "fail" {
				stalled = append(stalled, item)
				break
			}
		}
	}
	return stalled
}

// reportStalledIssue 常驻 issue 哨兵(train-drift 同模式:单 issue 追加防刷屏)。
// 覆盖两类停滞:bump PR checks 红(合并不了)/ 组件 Release 失败(资产永远不来)。
// 哨兵失败只告警,不阻断状态机。
func reportStalledIssue(train string, stalled []string) {
	body := fmt.Sprintf("列车 %s 停滞——以下环节失败,状态机无法自推进(修复后重跑对应流水线或人工推进):\n\n", train)
	for _, s := range stalled {
		body += "- " + s + "\n"
	}
	body += fmt.Sprintf("\n[最近一轮 sweep](https://github.com/%s/actions/workflows/train-orchestrator.yml)", hubRepo)
	if !GhOK("label", "create", "train-stalled", "-R", hubRepo, "--color", "D93F0B", "--description", "列车停滞(PR 检查或组件 Release 失败)", "--force") {
		warnf("train-stalled label 创建失败(忽略,继续开 issue)")
	}
	num, err := Gh("issue", "list", "-R", hubRepo, "--state", "open", "--search", "train-stalled in:title",
		"--json", "number", "--jq", ".[0].number")
	if err == nil && num != "" {
		if _, err := Gh("issue", "comment", num, "-R", hubRepo, "--body", body); err != nil {
			warnf("train-stalled issue 评论失败: %v", firstLine(err.Error()))
		}
		return
	}
	if _, err := Gh("issue", "create", "-R", hubRepo, "--label", "train-stalled",
		"--title", "🚂 train-stalled: "+train+" 列车停滞", "--body", body); err != nil {
		warnf("train-stalled issue 创建失败: %v", firstLine(err.Error()))
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

// imageExists 优先走 ghcr packages API(需 token 带 read:packages,机器人 classic
// PAT 具备);API 不可用或首页未见 tag 时回落 docker pull(v1 同款,公开镜像匿名可拉)。
func imageExists(name, tag string) bool {
	out, err := Gh("api", fmt.Sprintf("/orgs/%s/packages/container/%s/versions?per_page=100", ghOrg, name),
		"--jq", "[.[].metadata.container.tags[]]")
	if err == nil && strings.Contains(out, `"`+tag+`"`) {
		return true
	}
	return runQuiet("docker", "pull", "-q", "ghcr.io/"+ghOrg+"/"+name+":"+tag) == nil
}
