// preflight.go —— 发车前五道闸(spec 2026-11-13 §3;相位 [-1])。
//
// 全程**只读**:不建分支/不推 tag/不写 train.yaml。任何一道红 ⇒ 调用方
// (cmdRun)开哨兵 + die,零写操作。失败姿态=收集全部闸的失败一起报
// (一次看清全部问题,而不是修一个再撞一个)。
//
// 干跑语义边界:--dry-run 不走 preflight(预览要快,spec §4.3 不碰 #347 的
// 执行模式分派);standalone `trainctl preflight` 只报退出码,不自动开哨兵
// (人工预演每跑一次就开一条 issue 太吵;哨兵只由 run 路径开)。
package main

import (
	"fmt"
	"strings"
	"time"
)

// runPreflight 依次跑五道闸;全部通过返回 nil。
func runPreflight(env *Env, o *bumpOpts) error {
	type gate struct {
		name string
		fn   func() error
	}
	gates := []gate{
		{"凭据", func() error { return gateCreds(preflightRepos()) }},
		{"状态", func() error { return gateState(env, o.train) }},
		{"CI 基线", func() error { return gateCIBaseline() }},
		{"钉版", func() error { return gateLibPins(env, o.libVersions) }},
		{"检出", func() error { return gateCheckouts(env) }},
	}
	var failed []string
	for _, g := range gates {
		if err := g.fn(); err != nil {
			fmt.Printf("  ✗ preflight/%s: %v\n", g.name, err)
			failed = append(failed, g.name+": "+firstLine(err.Error()))
		} else {
			fmt.Printf("  ✓ preflight/%s\n", g.name)
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("%d/%d 道闸未过(零写操作,修完重跑;run 路径已开哨兵):\n  - %s",
			len(failed), len(gates), strings.Join(failed, "\n  - "))
	}
	okf("preflight 五道闸全过")
	return nil
}

// preflightRepos = bumpPRRepos ∪ libRepos() 的仓(去重,保序)。
func preflightRepos() []string {
	seen := map[string]bool{}
	var out []string
	add := func(r string) {
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	for _, r := range bumpPRRepos {
		add(r)
	}
	for _, lr := range libRepos() {
		add(lr.repo)
	}
	return out
}

// gateCreds:P1 凭据。gh 已认证 + 对每个目标仓有写权限(update-branch/推 tag/
// 建 PR 都靠它;权限不足会在写操作中途才炸 ⇒ 提前到发车时验)。
func gateCreds(repos []string) error {
	if _, err := ghRunner("api", "user", "--jq", ".login"); err != nil {
		return fmt.Errorf("gh 未认证或 token 失效: %v", err)
	}
	var denied []string
	for _, r := range repos {
		out, err := ghRunner("api", "repos/"+ghOrg+"/"+r, "--jq", ".permissions.push")
		if err != nil {
			return fmt.Errorf("探测 %s 权限失败: %w", r, err)
		}
		if strings.TrimSpace(out) != "true" {
			denied = append(denied, r)
		}
	}
	if len(denied) > 0 {
		return fmt.Errorf("凭据对以下仓无写权限: %s", strings.Join(denied, ", "))
	}
	return nil
}

// gateState:P2 状态。旧列车卡非终态 ⇒ 挡新车(bumpDecision 对此是「照常开
// 新车」——它的守门在 bump 里;run 的 preflight 必须自己挡)。
func gateState(env *Env, want string) error {
	curTrain, curState := trainStateOnOrigin(env)
	return gateStateVerdict(curTrain, curState, want)
}

// gateStateVerdict 纯判定(便于表驱动单测)。
func gateStateVerdict(curTrain, curState, want string) error {
	if curTrain == "" || curTrain == want || curState == "shipped" {
		return nil
	}
	return fmt.Errorf("旧列车 %s 卡在 state=%s——先处理它(放弃则人工把 state 改回 shipped;只改 state,勿改版本号)", curTrain, curState)
}

// gateCIBaseline:P3 CI 基线。全部目标仓 @ 当前默认分支头过同一门禁判据
// (红 ⇒ 起步就是坏的,别等到打 tag 才发现;在跑 ⇒ 有界等待)。
func gateCIBaseline() error {
	var reqs []ciReq
	for _, r := range preflightRepos() {
		sha, err := remoteHeadSha(r)
		if err != nil {
			return fmt.Errorf("%s 取默认分支头失败: %w", r, err)
		}
		reqs = append(reqs, ciReq{repo: r, sha: sha})
	}
	return waitAllCIGreen(reqs)
}

// libPinProbes 是 gateLibPins 的可注入探针(离线单测用;真身见 libPinReal)。
type libPinProbes struct {
	marker     func(env *Env) []markerAheadIssue
	tagExists  func(env *Env, repo, tag string) bool
	consumable func(env *Env, lr libRepo, v string, deadline time.Time) error
}

var libPinReal = libPinProbes{
	marker:     checkMarkerAhead,
	tagExists:  func(env *Env, repo, tag string) bool { return env.TagExists(repo, tag) },
	consumable: waitLibConsumable,
}

// gateLibPins:P4 钉版。
//   - marker-ahead(仓内已升版、tag 未发,#347 判据)⇒ 判红并点名两条出路;
//   - 已发布的钉版必须「可消费」(与消费方同源的探测);**尚未发布**的跳过
//     ——那是 [0] 阶段列车代发的对象,不在本闸拦截(否则 --set 新版本永远发不了车)。
func gateLibPins(env *Env, versions map[string]string) error {
	return gateLibPinsWith(env, versions, libPinReal)
}

func gateLibPinsWith(env *Env, versions map[string]string, p libPinProbes) error {
	// ⚠️ checkMarkerAhead 对**每个** marker 仓都返回条目(不过滤)——判定必须
	// 逐条看 ahead()/unavail,不能拿「有没有条目」当漂移。
	var bad []string
	for _, i := range p.marker(env) {
		if i.unavail != nil {
			bad = append(bad, "判据不可用(读不到 ≠ 不漂移): "+firstLine(i.unavail.Error()))
			continue
		}
		if i.ahead() {
			bad = append(bad, i.msg())
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("库线仓内已升版但 tag 未发(用 SET=<lib>=<版本> 发车,或先在该仓发 tag):\n    %s",
			strings.Join(bad, "\n    "))
	}
	deadline := time.Now().Add(5 * time.Minute) // 四库共用一个窗口(与 ensureLibLinePublished 同款)
	var failed []string
	for _, lr := range libRepos() {
		v := versions[lr.key]
		if v == "" {
			continue
		}
		if !p.tagExists(env, lr.repo, "v"+strings.TrimPrefix(v, "v")) {
			continue // 尚未发布 ⇒ [0] 由列车代发
		}
		if err := p.consumable(env, lr, v, deadline); err != nil {
			failed = append(failed, err.Error())
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("已发布钉版不可消费: %s", strings.Join(failed, "; "))
	}
	return nil
}

// gateCheckouts:P5 检出。
//   - hub 工作树必须干净(本地推进路径的 ff 恢复/提交都会被未提交改动挡死
//     ——AGENTS.md·同机并行会话(worktree 纪律)节的「先 commit+rebase」提前到发车时拦);
//   - 各已检出仓 fetch 齐(判据读远端;不 fetch ⇒ 拿陈旧 origin 判「不落后」)。
//     未检出的仓不在此拦:bump 的仓级 preflight(bump.go)会点名。
func gateCheckouts(env *Env) error {
	var failed []string
	out, err := Git(env.Root, "status", "--porcelain")
	if err != nil {
		return fmt.Errorf("hub git status 失败: %w", err)
	}
	if strings.TrimSpace(out) != "" {
		failed = append(failed, "hub 工作树不干净(先 commit / git stash;本地改动挡路时 git 会拒绝推进):\n      "+
			strings.ReplaceAll(strings.TrimSpace(out), "\n", "\n      "))
	}
	for _, r := range preflightRepos() {
		dir, ok := env.RepoDir(r)
		if !ok {
			continue
		}
		if _, err := Git(dir, "fetch", "-q", "origin", defBranch(r)); err != nil {
			failed = append(failed, fmt.Sprintf("%s fetch 失败: %v", r, err))
		}
	}
	if len(failed) > 0 {
		return fmt.Errorf("%s", strings.Join(failed, "\n  "))
	}
	return nil
}

// cmdPreflight 独立子命令(make train-preflight):只读预演,退出码即结论。
func cmdPreflight(env *Env, args []string) {
	o := parseBumpArgs(args)
	if o.train == "" {
		die("用法: trainctl preflight TRAIN=x.y.z")
	}
	fmt.Printf("══ preflight → %s(五道闸,全程只读)\n", o.train)
	if err := runPreflight(env, &o); err != nil {
		die("%v", err)
	}
}
