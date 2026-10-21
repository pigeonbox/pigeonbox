package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// cmdTag 在 bump PR 全合并后按依赖序推 tag,并把 state 推进到 tagged。
// 机器人是真账号:推 tag 产生正常 push 事件,各仓既有 Release 流水线自然触发
// ——v1 的 dispatch 兜底与 tagger 的「train: 前缀」门禁由此失去存在必要。
func cmdTag(env *Env) {
	tf := mustTrain(env)
	state := tf.Get("state")
	if state == "shipped" {
		die("列车 %s 已 shipped,不可再推 tag", tf.Get("train"))
	}
	if open := listOpenBumpPRs(env, tf.Get("train")); len(open) > 0 {
		die("bump PR 未全合并(advance 会在 checks 绿后自动合并):\n  %s", strings.Join(open, "\n  "))
	}
	runTag(env, tf)
}

type tagTarget struct {
	repo     string
	tag      string
	version  string // 期望的 VERSION 内容(空=跳过断言)
	manifest bool   // fnos:额外断言 fpk manifest version
	gomodPin string // server:断言 go.mod 钉的 core 版本(空=跳过断言)
}

func runTag(env *Env, tf *TrainFile) {
	train := tf.Get("train")
	serverV := tf.Get("images.server")
	fmt.Printf("══ tag 阶段 v%s\n", train)

	targets := []tagTarget{
		{repo: "frontend", tag: tf.Get("frontend.tag"), version: tf.Get("images.frontend")},
		// server 无 VERSION 文件,改以 go.mod 的 core 钉版做双写断言（本列车
		// lib.core 变更时,未合并 bump PR 的 main 上钉版必然还是旧值——裸奔检测）
		{repo: "server", tag: "v" + serverV, gomodPin: tf.Get("lib.core")},
		{repo: "fnos", tag: tf.Get("terminal.fnos.tag"), version: tf.Get("terminal.fnos.version"), manifest: true},
		{repo: "openwrt", tag: tf.Get("terminal.openwrt.tag"), version: tf.Get("terminal.openwrt.version")},
		{repo: "qnap", tag: tf.Get("terminal.qnap.tag"), version: tf.Get("terminal.qnap.version")},
		{repo: "desktop", tag: tf.Get("terminal.desktop.tag"), version: tf.Get("terminal.desktop.version")},
	}
	for _, p := range platforms {
		targets = append(targets, tagTarget{repo: p, tag: tf.Get("terminal." + p + ".tag"), version: tf.Get("terminal." + p + ".version")})
	}

	for i, t := range targets {
		if t.tag == "" {
			die("%s 缺 tag 声明(train.yaml)", t.repo)
		}
		if env.TagExists(t.repo, t.tag) {
			okf("%s %s 已存在,跳过", t.repo, t.tag)
		} else {
			pushTag(env, t)
		}
		// frontend tag 可见后 server 才能打(server Release 构建 frontend 镜像要检出同号 tag)
		if i == 0 {
			waitTagVisible(env, t.repo, t.tag, 3*time.Minute)
		}
	}

	// charts 不在此提交:chart 一旦发版就指向列车镜像,镜像未就位时会发布
	// 「钉空气」的 chart 版本(install 即 ImagePullBackOff 窗口)。移交 advance:
	// 镜像在位后再直提 Chart.yaml(1.20.0 首航复盘改进)。

	// state → tagged(提交进 hub main)
	tf.SetState("tagged")
	if err := tf.Save(); err != nil {
		die("写 train.yaml 失败: %v", err)
	}
	commitHubTrainFile(env, tf, "train: v"+train+" components tagged")
	okf("state=tagged 已提交;等组件 Release 回挂(回调/sweep 唤醒 advance 收尾)")
}

// pushTag 在 origin/<默认分支> 的当前提交上打 tag 并推送;推送前做双写断言
// (v1 tagger 守卫前移:VERSION/manifest 与列车号不一致即拒绝,防手改版发布)。
func pushTag(env *Env, t tagTarget) {
	dir := env.MustRepoDir(t.repo)
	def := defBranch(t.repo)
	if _, err := Git(dir, "fetch", "-q", "--tags", "origin"); err != nil {
		die("%s fetch 失败: %v", t.repo, err)
	}
	sha, err := Git(dir, "rev-parse", "origin/"+def)
	if err != nil {
		die("%s 解析 origin/%s 失败: %v", t.repo, def, err)
	}
	if t.version != "" {
		got, err := Git(dir, "show", sha+":VERSION")
		if err != nil {
			die("%s@%s 无 VERSION 文件,拒绝打 tag: %v", t.repo, shaShort(sha), err)
		}
		if strings.TrimSpace(got) != t.version {
			die("%s VERSION=%s ≠ 列车期望 %s——发版走 trainctl bump,勿手改", t.repo, strings.TrimSpace(got), t.version)
		}
	}
	if t.manifest {
		mani, err := Git(dir, "show", sha+":fnos/manifest")
		if err == nil && manifestVersion(mani) != t.version {
			die("fnos manifest version=%s ≠ VERSION %s——双写不一致,拒绝打 tag", manifestVersion(mani), t.version)
		}
	}
	if t.gomodPin != "" && !serverCorePinOK(mustGomod(dir, sha), t.gomodPin) {
		die("%s go.mod 未钉 core %s——bump PR 未合并到 %s(裸奔 tag 拦截,1.24.0/1.24.1 同型事故),先合并 PR 再 advance",
			t.repo, t.gomodPin, def)
	}
	// 本地同名 tag 若存在必须指向同一提交(否则环境陈旧,响亮失败)
	if local, err := Git(dir, "rev-parse", "-q", "--verify", "refs/tags/"+t.tag+"^{commit}"); err == nil {
		if local != sha {
			die("%s 本地已有 tag %s 指向 %s ≠ origin/%s(%s),删除本地 tag 后重跑", t.repo, t.tag, shaShort(local), def, shaShort(sha))
		}
	} else if _, err := Git(dir, "tag", t.tag, sha); err != nil {
		die("%s 打 tag %s 失败: %v", t.repo, t.tag, err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "refs/tags/"+t.tag); err != nil {
		die("%s 推 tag %s 失败(检查凭据对 %s 的写权限): %v", t.repo, t.tag, t.repo, err)
	}
	// push 静默失败=孤儿 tag 事故根因之一——推完立即远端回读确认
	if !env.TagExists(t.repo, t.tag) {
		die("%s tag %s push 后远端不可见(静默失败?),人工核查", t.repo, t.tag)
	}
	okf("%s tag %s → %s@%s(Release 将由 push 事件触发)", t.repo, t.tag, def, shaShort(sha))
}

// waitTagVisible 轮询远端 tag 可见性(server Release 会检出 frontend 同号 tag,
// 秒级等待即可;取代 v1 server release.yml 里的 20 分钟忙等)。
func waitTagVisible(env *Env, repo, tag string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if env.TagExists(repo, tag) {
			return
		}
		time.Sleep(5 * time.Second)
	}
	warnf("%s tag %s %v 内未远端可见(server Release 自带等待+硬断言兜底)", repo, tag, timeout)
}

// commitCharts 把 charts 纳入列车:直接提交 Chart.yaml(version=charts.chart,
// appVersion=charts.app)到 charts main,既有 chart-releaser(push main 触发)发版。
// 取代 v1 的 server→dispatch→sync-appversion 后到链。
func commitCharts(env *Env, tf *TrainFile) {
	dir, ok := env.RepoDir("charts")
	if !ok {
		warnf("charts 检出缺失,跳过(advance 会以 Chart.yaml 实况核对,sweep 兜底)")
		return
	}
	wantVer := tf.Get("charts.chart")
	wantApp := tf.Get("charts.app")
	rel := "charts/pigeonbox/Chart.yaml"
	if _, err := Git(dir, "fetch", "-q", "origin", "main"); err != nil {
		die("charts fetch 失败: %v", err)
	}
	cur, err := Git(dir, "show", "origin/main:"+rel)
	if err != nil {
		die("charts 读 origin/main:%s 失败: %v", rel, err)
	}
	if yamlTopKey(cur, "version:") == wantVer && yamlTopKey(cur, "appVersion:") == wantApp {
		okf("charts Chart.yaml 已对齐(version %s / appVersion %s),跳过", wantVer, wantApp)
		return
	}
	if st, _ := Git(dir, "status", "--porcelain"); st != "" {
		die("charts 工作树不干净,拒绝提交(先人工处理):\n%s", st)
	}
	if _, err := Git(dir, "checkout", "-q", "-B", "main", "origin/main"); err != nil {
		die("charts 对齐 origin/main 失败: %v", err)
	}
	edited := cur
	edited = replaceYamlTopKey(edited, "version:", wantVer)
	edited = replaceYamlTopKey(edited, "appVersion:", wantApp)
	if err := os.WriteFile(dir+"/"+rel, []byte(edited), 0o644); err != nil {
		die("charts 写 Chart.yaml 失败: %v", err)
	}
	if _, err := Git(dir, "add", rel); err != nil {
		die("charts add 失败: %v", err)
	}
	msg := fmt.Sprintf("train: chart %s for v%s (app %s)", wantVer, tf.Get("train"), wantApp)
	if _, err := Git(dir, "commit", "-qm", msg); err != nil {
		die("charts commit 失败: %v", err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "main"); err != nil {
		die("charts push 失败(检查凭据): %v", err)
	}
	okf("charts Chart.yaml → version %s / appVersion %s 已推 main(chart-releaser 接管)", wantVer, wantApp)
}

// commitHubTrainFile 提交 hub 的 train.yaml(state 推进)并推 origin main。
func commitHubTrainFile(env *Env, tf *TrainFile, msg string) {
	dir := env.Root
	br, _ := Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
	if br != "main" {
		die("hub 当前在 %s 分支,推进 state 须在 main(先 checkout main)", br)
	}
	if _, err := Git(dir, "fetch", "-q", "origin", "main"); err != nil {
		die("hub fetch 失败: %v", err)
	}
	if n, _ := Git(dir, "rev-list", "--count", "main...origin/main"); n != "0" {
		die("hub 本地与远端分歧(%s),先 pull --ff-only", n)
	}
	if _, err := Git(dir, "add", trainFileRel); err != nil {
		die("hub add 失败: %v", err)
	}
	if GitOK(dir, "diff", "--cached", "--quiet") {
		okf("train.yaml 无变化,跳过提交")
		return
	}
	if _, err := Git(dir, "commit", "-qm", msg); err != nil {
		die("hub commit 失败: %v", err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "main"); err != nil {
		die("hub push 失败(检查凭据): %v", err)
	}
	okf("hub main ← %s", msg)
}

func replaceYamlTopKey(content, prefix, val string) string {
	lines := splitLines(content)
	for i, ln := range lines {
		if strings.HasPrefix(ln, prefix) {
			quoted := val
			if prefix == "version:" {
				quoted = `"` + val + `"` // Chart.yaml 惯例 version 带引号
			}
			lines[i] = prefix + " " + quoted
			return strings.Join(lines, "\n") + "\n"
		}
	}
	return content
}

func shaShort(sha string) string {
	if len(sha) > 8 {
		return sha[:8]
	}
	return sha
}

// mustGomod 读取指定提交的 go.mod 内容（裸奔检测用）。
func mustGomod(dir, sha string) string {
	got, err := Git(dir, "show", sha+":go.mod")
	if err != nil {
		die("%s 无 go.mod: %v", dir, err)
	}
	return got
}

// serverCorePinOK 断言 go.mod 钉了指定版本的 core（train.yaml lib.core 同值）。
// 精确匹配版本号本身，不做「包含」——子串匹配会把预发布版放行
// （pin=v0.26.0 时，"github.com/pigeonbox/core v0.26.0-rc1" 也含该子串）。
func serverCorePinOK(gomod, pin string) bool {
	for _, line := range strings.Split(gomod, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "github.com/pigeonbox/core ") {
			continue
		}
		ver := strings.TrimSpace(strings.TrimPrefix(line, "github.com/pigeonbox/core "))
		// 去掉行尾注释（go.mod 允许 `v0.26.0 // indirect`）
		if i := strings.Index(ver, "//"); i >= 0 {
			ver = strings.TrimSpace(ver[:i])
		}
		if ver == pin {
			return true
		}
	}
	return false
}
