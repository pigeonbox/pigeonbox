package main

import (
	"fmt"
	"time"
)

// ───────────────────────── run:一条命令开一趟车 ─────────────────────────
//
// 为什么要有它(2026-10-27 拍板:「慢 + 复杂」的结构性根因):
//
//  1. **推进靠两套唤醒源**:组件仓 Release 回调(repository_dispatch)+ `*/15` 的
//     cron 兜底。而 GitHub 的 schedule 实测**每 2~4 小时才跑一次**
//     (2026-10-27 抽样 20 次触发时刻:平均间隔 2.6 小时,最近一次 05:52Z、
//     上一次 00:52Z)⇒ 回调一丢,列车就静默卡几小时。
//  2. **操作面要记两段**:bump 完还得记得跑 advance;bump 的 `--set` 还得人工
//     算库线钉版(漏 core_pin 曾把 3.3.16 卡在 draft)。
//
// ⇒ 列车改为**单次 CI 运行内自轮询**:一次 dispatch 到底,自己等 PR 变绿、
// 合并、等产物齐、终验、出 hub 快照。cron 降级为纯兜底(进程崩了/回调丢了
// 仍有接力),操作面收敛成一条命令。
//
// 阶段:
//
//	[0] 库线   解析钉版 → 未发布则自己打 tag → 等「可消费」(模块代理/tgz 资产)
//	[1] bump   各仓 train/<v> 分支 + PR
//	[2] 合并   自轮询:checks 绿即合并(不必等 cron)
//	[3] 发货   等产物齐 → charts → 全量 verify → hub 快照 tag(Latest)
//
// 幂等:任何阶段可重入。bump 重跑复用同名列车分支(见 bump.go 的切分支逻辑);
// 已打的 tag/已合的 PR 会被跳过。
func cmdRun(env *Env, args []string) {
	o := parseBumpArgs(args)
	o.push = true // run 一定实际执行(dry-run 用 `trainctl bump` 单独跑)
	timeout := parseDuration(o.timeout, 90*time.Minute)

	fmt.Printf("══ 列车 run → %s (hotfix=%v, 单次运行内自轮询, 上限 %s)\n", o.train, o.hotfix, timeout)

	// ── [0] 库线:解析 → 发布 → 等可消费 ──
	ensureLibLine(env, &o)

	// ── [1] bump(可跳过:这趟车可能已经开出去了)──
	//
	// ⚠️ 「重跑」不是「重做」:同一列车号重跑时,bump PR 可能**已经合了**
	// (4.0.7 实录:bump PR 于 2026-10-27T16:43Z 合并,列车仍停在 draft
	// ⇒ 此时再跑一遍 bump 会「无变更 ⇒ 未建 PR」⇒ 撞「静默空转」守卫死掉)。
	// ⇒ 先读**远端 main**上的状态(train.yaml 真相源),已开出去就直接接着推。
	curTrain, curState := trainStateOnOrigin(env)
	skipBump, finished, why := bumpDecision(curTrain, curState, o.train)
	switch {
	case finished:
		fmt.Printf("✓ 列车 %s %s——无事可做。\n", o.train, why)
		return
	case skipBump:
		okf("列车 %s %s ⇒ 跳过 bump,直接推进", o.train, why)
	default:
		fmt.Println("── [1] bump(各仓 train/" + o.train + " 分支 + PR)")
		runBump(env, o)
	}

	// ── [2] 等 bump PR 全合并 ──
	fmt.Println("── [2] 等 bump PR 全合并(checks 绿即合并)")
	if err := waitStep("bump PR 合并", timeout, 45*time.Second, func() (stepState, string) {
		tf := syncHubMain(env)
		switch tf.Get("state") {
		case "draft", "":
			return advanceDraft(env, tf)
		default:
			return stepDone, "已进入 " + tf.Get("state") + " 态"
		}
	}); err != nil {
		die("%v", err)
	}

	// ── [3] 等产物 + 终验 + 出快照 ──
	fmt.Println("── [3] 等产物齐 → charts → 终验 → 出 hub 快照")
	if err := waitStep("产物齐/终验", timeout, 60*time.Second, func() (stepState, string) {
		tf := syncHubMain(env)
		switch tf.Get("state") {
		case "tagged", "shipping":
			return advanceTagged(env, tf)
		case "shipped":
			return stepDone, "已 shipped"
		default:
			return stepWaiting, "state=" + orNone(tf.Get("state")) + "(尚未到 tagged)"
		}
	}); err != nil {
		die("%v", err)
	}
	fmt.Println("✓ 列车已发货(hub 快照 Release 由 tag push 触发)")
}

// trainStateOnOrigin 读**远端 main** 上的 train.yaml 真相源(列车号 + 状态)。
//
// ⚠️ 必须读 origin/main 而不是工作树:本地 main 落后 origin 时,工作树里还是
// **上一趟车**的 state ⇒ 判「这趟车是否已经开出去」会判错(4.0.7 实录:
// 本地还停在 4.0.6/shipped,远端已是 4.0.7/draft)。
func trainStateOnOrigin(env *Env) (train, state string) {
	if _, err := Git(env.Root, "fetch", "-q", "origin", "main"); err != nil {
		return "", ""
	}
	out, err := Git(env.Root, "show", "origin/main:"+trainFileRel)
	if err != nil {
		return "", ""
	}
	for _, ln := range splitLines(out) {
		k, v, ok := parseTrainLine(ln)
		if !ok {
			continue
		}
		switch k {
		case "train":
			train = v
		case "state":
			state = v
		}
	}
	return train, state
}

// bumpDecision 决定 run 的 bump 阶段要不要跑(纯函数,便于单测)。
//
// 返回 (skipBump, finished, reason)：
//
//	· 远端已是同一列车号且 shipped ⇒ finished=true(整趟车已完成,无事可做);
//	· 远端已是同一列车号且非 shipped ⇒ skipBump=true(bump 已合,接着推);
//	· 否则 ⇒ 照常 bump。
func bumpDecision(curTrain, curState, want string) (skipBump, finished bool, reason string) {
	switch {
	case curTrain == want && curState == "shipped":
		return true, true, "列车已 shipped"
	case curTrain == want && curState != "":
		return true, false, "列车已在 " + curState + " 态(bump 已合),接着推"
	default:
		return false, false, "照常开新车"
	}
}

// ensureLibLine 阶段 0:解析库线钉版 → 保证目标版本已发布 → 等「可消费」。
//
// 「可消费」= 消费方真的拿得到:
//
//	· Go 库(core/contracts/p2p):模块代理能拉到该版本;
//	· npm 库(contracts/frontend-core):Release 上挂了对应 tgz 资产。
//
// 不等就位就 bump ⇒ 产品线的 PR 必红在 npm ci / missing go.sum entry。
func ensureLibLine(env *Env, o *bumpOpts) {
	fmt.Println("── [0] 库线(contracts/core/p2p/frontend-core):解析 → 发布 → 等可消费")
	head, err := env.TrainFileHead()
	if err != nil {
		die("读 HEAD train.yaml 失败: %v", err)
	}
	current := map[string]string{
		"lib.contracts":     head.Get("lib.contracts"),
		"lib.core":          head.Get("lib.core"),
		"lib.p2p":           head.Get("lib.p2p"),
		"lib.frontend-core": head.Get("lib.frontend-core"),
	}
	res, err := resolveLibVersions(env, o.sets, o.freezeLibs, current)
	if err != nil {
		die("库线钉版解析失败: %v", err)
	}
	for _, n := range res.notes {
		fmt.Println("  " + n)
	}
	for _, lr := range libRepos() {
		v := res.versions[lr.key]
		if v == "" {
			continue
		}
		// 只有**显式指定**的版本才由列车负责发布(自动跟随的版本本来就已发布)。
		if _, err := ensureLibTag(env, lr, v, res.frozen[lr.key]); err != nil {
			die("%v", err)
		}
		// 等「可消费」的窗口**独立于整趟车的超时**(上限 15 分钟):
		// 代理同步/资产发布是分钟级的事;再久就是真出问题(该仓的 release 流水线挂了)
		// ⇒ 与其占着 runner 等一小时,不如立刻响亮失败让人去查。
		if err := waitLibConsumable(env, lr, v, minDuration(parseDuration(o.timeout, 10*time.Minute), 15*time.Minute).String()); err != nil {
			die("%v", err)
		}
	}
	// 解析结果回填:bump 用同一套版本(避免二次解析漂移)。
	o.libVersions = res.versions
}

// minDuration 取两个时长里较小的那个。
func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

// waitStep 轮询直到本阶段完成/失败/超时。
//
// 每次只在**状态变化**时打印一行(否则日志会被轮询刷屏);失败立即返回
// (run 场景下快速失败:红着的检查不会自己变绿,干等只是烧 runner)。
func waitStep(desc string, timeout, interval time.Duration, fn func() (stepState, string)) error {
	deadline := time.Now().Add(timeout)
	last := ""
	for {
		st, msg := fn()
		switch st {
		case stepDone:
			okf("%s 完成:%s", desc, msg)
			return nil
		case stepFailed:
			return fmt.Errorf("%s 失败:%s", desc, msg)
		}
		if msg != last {
			fmt.Printf("  ⏳ %s:%s\n", desc, msg)
			last = msg
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s 超时(%s)——最后状态:%s", desc, timeout, orNone(last))
		}
		time.Sleep(interval)
	}
}
