package main

import (
	"fmt"
	"strings"
)

// bumpPRRepos 是 bump 会建 PR 的仓(hub 自身名为 pigeonbox;charts 走直推无 PR)。
var bumpPRRepos = []string{"pigeonbox", "frontend", "fnos", "openwrt", "qnap", "desktop", "synology", "ugreen", "terramaster"}

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

	switch state {
	case "draft":
		open := listOpenBumpPRs(env, train)
		if len(open) > 0 {
			tryMergeReady(open)
			open = listOpenBumpPRs(env, train)
			if len(open) > 0 {
				fmt.Printf("  ⏳ 等 bump PR 合并(checks 绿后由 sweep/回调收尾):\n    %s\n", strings.Join(open, "\n    "))
				return
			}
		}
		runTag(env, tf)
		fmt.Println("  ✓ tag 阶段完成;等组件 Release 回挂(下次唤醒核对产物)")
	case "tagged", "shipping":
		missing := checkReleased(env, tf)
		if len(missing) > 0 {
			fmt.Printf("  ⏳ 产物未齐(%d 项),等回调/sweep:\n    %s\n", len(missing), strings.Join(missing, "\n    "))
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

// checkReleased 以 GitHub API 实况核对「tagged → shipped」完成度,返回缺失项。
// 修复 v1 wait-artifacts 的 tag 映射 bug:v1 用 terminal.<t>.tag(=v1.19.0)查 hub
// Release,而回挂 tag 实为 <组件>-v<版本>(fnos-v1.19.0…)——五个组件全撞在 hub
// 快照 tag 命名空间上,等待形同虚设。
func checkReleased(env *Env, tf *TrainFile) []string {
	var missing []string
	train := tf.Get("train")

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
			missing = append(missing, fmt.Sprintf("hub Release %s 资产未就绪", tag))
			continue
		}
		okf("hub Release %s(资产 %s)", tag, strings.TrimSpace(out))
	}

	// 2) ghcr 镜像(server/frontend=列车号;p2p=库线号)
	images := map[string]string{
		"server":   tf.Get("images.server"),
		"frontend": tf.Get("images.server"),
		"p2p":      strings.TrimPrefix(tf.Get("lib.p2p"), "v"),
	}
	for _, name := range []string{"server", "frontend", "p2p"} {
		tag := images[name]
		if !imageExists(name, tag) {
			missing = append(missing, fmt.Sprintf("ghcr.io/pigeonbox/%s:%s 未发布", name, tag))
			continue
		}
		okf("ghcr.io/pigeonbox/%s:%s 在位", name, tag)
	}

	// 3) charts 对齐(chart-releaser 由 push main 触发,读 Chart.yaml 实况)
	if cyaml, err := env.Raw("charts/main/charts/pigeonbox/Chart.yaml"); err == nil {
		if got := yamlTopKey(cyaml, "version:"); got != tf.Get("charts.chart") {
			missing = append(missing, fmt.Sprintf("chart version=%s ≠ %s", orNone(got), tf.Get("charts.chart")))
		} else if gotApp := yamlTopKey(cyaml, "appVersion:"); gotApp != tf.Get("charts.app") {
			missing = append(missing, fmt.Sprintf("chart appVersion=%s ≠ %s", orNone(gotApp), tf.Get("charts.app")))
		} else {
			okf("chart %s(app %s)已落地", got, tf.Get("charts.app"))
		}
	} else {
		missing = append(missing, "charts Chart.yaml 拉取失败")
	}
	_ = train
	return missing
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
