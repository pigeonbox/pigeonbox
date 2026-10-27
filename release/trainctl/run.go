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

	curTrain, curState := trainStateOnOrigin(env)
	skipBump, finished, why := bumpDecision(curTrain, curState, o.train)

	switch {
	case finished:
		fmt.Printf("✓ 列车 %s %s——无事可做。\n", o.train, why)
		return
	case skipBump:
		okf("列车 %s %s ⇒ 跳过 bump,直接推进", o.train, why)
		// 续跑:本趟车的钉版**已写死在 train.yaml**(bump PR 已合)⇒ 用它,
		// **不做自动跟随**——跟随最新 tag 与本趟车无关,却可能因为「最新那个
		// 库线版本的产物还没发布」而卡住一趟本来能发的车。
		o.libVersions = trainPinsOnOrigin(env)
		// 空 allowCreate = **不允许**列车在本趟车里打新库线 tag(那属于「开新车」
		// 的动作;续跑只校验既有钉版是否仍可消费)。
		if err := ensureLibLinePublished(env, o.libVersions, map[string]bool{}, o.timeout); err != nil {
			die("%v", err)
		}
	default:
		// ── [0] 库线:解析 → 发布 → 等可消费 ──
		fmt.Println("── [0] 库线(contracts/core/p2p/frontend-core):解析 → 发布 → 等可消费")
		if err := ensureLibLine(env, &o); err != nil {
			die("%v", err)
		}
		// ── [1] bump ──
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

// trainMapOnOrigin 读**远端 main** 上的 train.yaml(全部扁平键 = 真相源)。
//
// ⚠️ 必须读 origin/main 而不是工作树:本地 main 落后 origin 时,工作树里还是
// **上一趟车**的 state ⇒ 判「这趟车是否已经开出去」会判错(4.0.7 实录:
// 本地还停在 4.0.6/shipped,远端已是 4.0.7/draft)。
func trainMapOnOrigin(env *Env) map[string]string {
	out := map[string]string{}
	if _, err := Git(env.Root, "fetch", "-q", "origin", "main"); err != nil {
		return out
	}
	raw, err := Git(env.Root, "show", "origin/main:"+trainFileRel)
	if err != nil {
		return out
	}
	for _, ln := range splitLines(raw) {
		k, v, ok := parseTrainLine(ln)
		if ok {
			out[k] = v
		}
	}
	return out
}

// trainStateOnOrigin 读远端 main 上的列车号与状态。
func trainStateOnOrigin(env *Env) (train, state string) {
	m := trainMapOnOrigin(env)
	return m["train"], m["state"]
}

// trainPinsOnOrigin 取远端 main 上本趟车的库线钉版(续跑时用,不做自动跟随)。
func trainPinsOnOrigin(env *Env) map[string]string {
	m := trainMapOnOrigin(env)
	pins := map[string]string{}
	for _, lr := range libRepos() {
		if v := m[lr.key]; v != "" {
			pins[lr.key] = v
		}
	}
	return pins
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
func ensureLibLine(env *Env, o *bumpOpts) error {
	head, err := env.TrainFileHead()
	if err != nil {
		return fmt.Errorf("读 HEAD train.yaml 失败: %w", err)
	}
	current := map[string]string{
		"lib.contracts":     head.Get("lib.contracts"),
		"lib.core":          head.Get("lib.core"),
		"lib.p2p":           head.Get("lib.p2p"),
		"lib.frontend-core": head.Get("lib.frontend-core"),
	}
	res, err := resolveLibVersions(env, o.sets, o.freezeLibs, current)
	if err != nil {
		return fmt.Errorf("库线钉版解析失败: %w", err)
	}
	for _, n := range res.notes {
		fmt.Println("  " + n)
	}
	// 只有**显式指定**的版本才由列车负责发布(自动跟随的版本本来就已发布)。
	if err := ensureLibLinePublished(env, res.versions, res.frozen, o.timeout); err != nil {
		return err
	}
	// 解析结果回填:bump 用同一套版本(避免二次解析漂移)。
	o.libVersions = res.versions
	return nil
}

// ensureLibLinePublished 保证每个库线版本**已发布**且**可消费**。
//
// allowCreate 逐键给出「该版本尚未发布时可否由列车自己打 tag」:
//
//	· 显式 --set 指定的版本 ⇒ true(列车负责发布);
//	· 自动跟随/冻结的版本 ⇒ false(它们本来就已发布;没发布 = 真问题,响亮失败)。
func ensureLibLinePublished(env *Env, versions map[string]string, allowCreate map[string]bool, timeout string) error {
	// 四个库**共用一个等待窗口**(逐库各等一轮 ⇒ 最坏 4×窗口)。
	// 等「可消费」的窗口**独立于整趟车的超时**(上限 15 分钟):
	// 代理同步/资产发布是分钟级的事;再久就是真出问题(该仓的 release 流水线挂了)
	// ⇒ 与其占着 runner 等一小时,不如立刻响亮失败让人去查。
	deadline := time.Now().Add(minDuration(parseDuration(timeout, 10*time.Minute), 15*time.Minute))
	for _, lr := range libRepos() {
		v := versions[lr.key]
		if v == "" {
			continue
		}
		if _, err := ensureLibTag(env, lr, v, allowCreate[lr.key]); err != nil {
			return err
		}
		if err := waitLibConsumable(env, lr, v, deadline); err != nil {
			return err
		}
	}
	return nil
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
