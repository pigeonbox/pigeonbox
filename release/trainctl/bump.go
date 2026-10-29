package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// bumpOpts 是一次 bump 的参数集(bump / run 共用同一套解析)。
type bumpOpts struct {
	train       string
	hotfix      bool
	push        bool
	freezeLibs  bool              // 冻结库线钉版(不自动跟随最新已发布 tag)
	sets        map[string]string // --set k=v(库线消费记录)
	timeout     string            // --timeout=90m(run 用;bump 忽略)
	libVersions map[string]string // train.yaml 全键 → 已解析的库线版本(nil=内部解析)
}

// parseBumpArgs 解析 bump/run 的参数。
//
// 语义与 v1 一致(bump TRAIN=x.y.z --set k=v --hotfix),新增:
//
//	--freeze-libs  库线钉版冻结在 train.yaml 现值(默认=自动跟随各库仓最新已发布 tag)
//	--timeout=90m  run 阶段的等待上限(bump 忽略)
func parseBumpArgs(args []string) bumpOpts {
	o := bumpOpts{sets: map[string]string{}}
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case strings.HasPrefix(a, "TRAIN="):
			o.train = strings.TrimPrefix(a, "TRAIN=")
		case a == "--hotfix":
			o.hotfix = true
		case a == "--push":
			o.push = true
		case a == "--freeze-libs":
			o.freezeLibs = true
		case strings.HasPrefix(a, "--timeout="):
			o.timeout = strings.TrimPrefix(a, "--timeout=")
		case a == "--set":
			i++
			if i >= len(args) {
				die("--set 需要 k=v 参数")
			}
			k, v, ok := strings.Cut(args[i], "=")
			if !ok {
				die("--set 须形如 core=v0.18.0: %q", args[i])
			}
			o.sets[k] = v
		default:
			die("bump: 未知参数 %q", a)
		}
	}
	if o.train == "" {
		die("用法: trainctl bump TRAIN=x.y.z [--set k=v …] [--hotfix] [--push] | trainctl run TRAIN=x.y.z …")
	}
	for _, c := range o.train {
		if !(c == '.' || (c >= '0' && c <= '9')) {
			die("TRAIN 须形如 1.15.0: %q", o.train)
		}
	}
	return o
}

// cmdBump 开新列车:结构化写 15+ 版本点 → 各仓 train/<v> 分支+PR → 自动合并。
// 与 v1 的关键差异:dry-run(缺省)纯内存计算计划、零落盘——v1 的
// 「dry-run 写工作树」曾直接导致 1.14.6 PR 漏建事故。
func cmdBump(env *Env, args []string) {
	runBump(env, parseBumpArgs(args))
}

// runBump 是 bump 的主体(可被 run 复用)。
func runBump(env *Env, o bumpOpts) {
	train := o.train
	hotfix, push := o.hotfix, o.push
	sets := o.sets

	b := &bumper{env: env, train: train, hotfix: hotfix, push: push,
		planned: map[string][]string{}, prDone: map[string]bool{}}

	// 并行列车门禁(v1「并行列车吞提交」事故类):新列车只能从 shipped 态开出;
	// 同列车号重跑(--push 续跑/补漏)豁免。dry-run 是只读演练,不设卡。
	if push {
		if cur, err := LoadTrainFile(env); err == nil {
			if st, curTrain := cur.Get("state"), cur.Get("train"); st != "" && st != "shipped" && curTrain != train {
				die("列车 %s 仍在 %s 态,禁止并行开 %s——先跑 advance 收尾,或确认旧列车放弃后人工把 state 改回 shipped", curTrain, st, train)
			}
		}
	}

	// 基线/默认值一律取 HEAD 版 train.yaml(tget_head 语义,防工作树污染)。
	head, err := env.TrainFileHead()
	if err != nil {
		die("读 HEAD train.yaml 失败: %v", err)
	}
	b.oldServer = head.Get("images.server")
	b.oldFCore = head.Get("lib.frontend-core")
	b.oldTrain = head.Get("train")
	b.p2pcRef = head.Get("terminal.p2pc_ref")
	b.corePin = head.Get("terminal.fnos.core_pin")
	b.chart = head.Get("charts.chart")

	// ── 库线钉版解析(2026-10-27 拍板:库线收进列车)─────────────────────────
	//
	// 旧语义:库线钉版**冻结**在 train.yaml 里,靠人工 `SET="core=vX …"` 传进来
	// ⇒ 发车者必须知道每个库仓该用哪个版本(漏 core_pin 曾把 3.3.16 卡在 draft)。
	//
	// 新语义:默认**自动跟随各库仓最新已发布 tag**(与 `go get -u` 一致):
	// 库线发布了新版本,产品线下一趟车自然跟上,人不用算钉版。
	// 显式 --set <lib>=<ver> 仍最优先(列车负责把它发布出来);
	// --freeze-libs 则冻结在 train.yaml 现值。
	//
	// ⚠️ 解析只升不降:现钉版比最新 tag 还新(本地未同步/预发布)时保持现钉版。
	cur := map[string]string{
		"lib.contracts":     head.Get("lib.contracts"),
		"lib.core":          head.Get("lib.core"),
		"lib.p2p":           head.Get("lib.p2p"),
		"lib.frontend-core": head.Get("lib.frontend-core"),
	}
	libVersions := o.libVersions
	if libVersions == nil {
		res, rerr := resolveLibVersions(env, sets, o.freezeLibs, cur)
		if rerr != nil {
			die("库线钉版解析失败: %v", rerr)
		}
		libVersions = res.versions
		for _, n := range res.notes {
			fmt.Println("  " + n)
		}
	}
	b.contracts = libVersions["lib.contracts"]
	b.core = libVersions["lib.core"]
	b.p2p = libVersions["lib.p2p"]
	b.fcore = libVersions["lib.frontend-core"]
	b.kit = head.Get("lib.kit")

	// 1.17.0 起镜像线并入产品号:server/frontend 镜像 tag、两仓 tag、页脚与各
	// web/ 包体版本全部随列车号(--set server 仅应急口子)。
	b.server = train
	for k, v := range sets {
		switch k {
		case "contracts", "core", "p2p", "frontend-core":
			// 库线四键已由上面的解析处理(显式值优先)——此处不再覆盖。
		case "kit":
			b.kit = v
		case "p2pc_ref":
			b.p2pcRef = v
		case "core_pin":
			b.corePin = v
		case "server":
			b.server = strings.TrimPrefix(v, "v")
			warnf("--set server 覆盖镜像号为 %s(应急口子;产品号联动下镜像线默认=列车号)", b.server)
		default:
			die("未知 --set 键: %q", k)
		}
	}
	// Phase 2②(2026-10-16):Box 包内随带 p2pc(NAS 三端 P2PC_REF + server
	// .p2pc-version)与列车脱钩——独立键 terminal.p2pc_ref,缺省冻结(仅显式
	// --set p2pc_ref 才动,随 p2p 仓安全/相关修复手动 bump)。head 无此键时
	// 首趟迁移为当时 lib.p2p(该趟行为不变),此后不再随 lib.p2p 联动。
	if b.p2pcRef == "" {
		b.p2pcRef = b.p2p
	}

	// core_pin 默认**跟随 lib.core**（2026-10-24 实录修）：
	//
	// 终端打包（server 镜像的 go.mod + NAS 三端 DEPS.env）里带的 core 版本
	// 必须与库线同版——否则 NAS 包/镜像仍带旧 core，本次改动根本不在产物里。
	// 此前 `lib.core` 与 `terminal.*.core_pin` 是**两个独立键** ⇒ 只
	// `--set core=vX` 而漏 `--set core_pin=vX` 时，终端静默留在旧版 ⇒ 直到
	// tag 阶段被「裸奔 tag 拦截」（server go.mod 未钉 core vX）才发现，
	// 列车卡在 draft（3.3.16 实录）。
	//
	// 显式 `--set core_pin=` 仍优先（保留「终端故意滞后于库线」的口子）。
	if _, explicit := sets["core_pin"]; !explicit {
		if next, changed := followCorePin(b.corePin, b.core, b.core != head.Get("lib.core")); changed {
			warnf("lib.core 变更 ⇒ core_pin 自动跟随 %s → %s（显式 --set core_pin= 可覆盖）", b.corePin, next)
			b.corePin = next
		}
	}

	// 库线悬空钉守卫(2026-10-18 2.0.5 实锤事故收口):--set core=v0.24.2 而
	// tag 尚不存在时,bump PR 的 go.sum 无法物化,组件仓 CI 全线
	// missing go.sum entry 红(库线 tag 必须先于 bump 存在——库线 tag 序)。
	// push 模式拒发;dry-run 响亮警告放行。未变的钉版不重查(现状已发运)。
	//
	// 注:走 `trainctl run` 时列车已先把库线发布好(见 libline.go)⇒ 此处必过。
	changedLibs := map[string]string{} // repo → 新钉版
	if old := head.Get("lib.contracts"); old != b.contracts {
		changedLibs["contracts"] = b.contracts
	}
	if old := head.Get("lib.core"); old != b.core {
		changedLibs["core"] = b.core
	}
	if old := head.Get("lib.p2p"); old != b.p2p {
		changedLibs["p2p"] = b.p2p
	}
	if old := b.oldFCore; old != b.fcore {
		changedLibs["frontend-core"] = b.fcore
	}
	if old := head.Get("terminal.fnos.core_pin"); old != b.corePin && b.corePin != "" && changedLibs["core"] == "" {
		changedLibs["core"] = b.corePin // core_pin 独立变更时同样钉 core 仓
	}
	for repo, tag := range changedLibs {
		if tag == "" || env.TagExists(repo, tag) {
			continue
		}
		if push {
			die("库线悬空钉: %s tag %s 远端不存在——先在 %s 仓打 tag 并推送,再 bump(库线 tag 序);或走 `trainctl run` 让列车自己发布库线", repo, tag, repo)
		}
		warnf("库线悬空钉(dry-run 放行): %s tag %s 远端不存在——该趟 PR 的 go.sum 将无法物化,组件 CI 必红", repo, tag)
	}

	b.feTag = "v" + b.server
	b.chartApp = "v" + b.server
	if b.server != b.oldServer {
		b.chart = BumpPatch(b.chart)
	}

	fmt.Printf("══ 列车 bump → %s (hotfix=%v, dry-run=%v)\n", train, hotfix, !push)
	fmt.Printf("   库线: contracts=%s core=%s kit=%s p2p=%s | 镜像: server=%s(前端同号) | 终端: core 钉=%s p2pc_ref=%s\n",
		b.contracts, b.core, b.kit, b.p2p, b.server, b.corePin, b.p2pcRef)

	// 仓存在性前置(dry-run 也要读文件算计划)
	for _, r := range bumpRepos {
		env.MustRepoDir(r)
	}
	if push {
		b.preflight()
	}
	for _, r := range bumpRepos {
		dir, _ := env.RepoDir(r)
		_, _ = Git(dir, "fetch", "-q", "origin")
	}

	// ── 各仓 bump:并行推进 ──
	//
	// 为什么并行(2026-10-27 提速):各仓版本点**互不相干**(各写各的目录/
	// go.mod / package.json),此前**串行**跑 ⇒ 一趟车的 bump 阶段被
	// 「4 次 go mod tidy + 4 次 npm lock 刷新 + 3 次模板物化」这些
	// **网络密集**作业拖成好几分钟。并行后耗时≈最慢的一个仓。
	//
	// 为什么 NAS 打包三仓**不在**并行组里:sync.sh 的模板源是 hub 的
	// **本地工作树**(deploy/nas/*),必须等 hub 编辑完模板 ⇒ 串在 hub 之后。
	//
	// 每仓内部逻辑一行未改(切分支/暂存/三方合并/建 PR 仍是原实现)——
	// 并行只发生在**仓之间**,不碰那几段有事故史的链路。
	var wg sync.WaitGroup
	runRepo := func(fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fn()
		}()
	}
	runRepo(b.hub)
	runRepo(b.frontend)
	runRepo(b.fnos)
	runRepo(func() { b.native("openwrt") })
	runRepo(func() { b.native("qnap") })
	runRepo(b.serverRepo)
	runRepo(b.desktop)
	wg.Wait()
	b.nasPlatforms()

	// 汇总
	if err := printBumpSummary(b); err != nil {
		die("%v", err)
	}

	if push {
		b.restoreBranches()
		fmt.Printf("✓ bump PR 已建齐并开启自动合并(squash)。合并后由 advance(回调/sweep)推 tag → Release → finalize。\n")
	} else {
		fmt.Println("✓ dry-run 结束(零落盘)。确认后加 --push 执行。")
	}
}

// printBumpSummary 打印 bump 汇总，并**守住「静默空转」**。
//
// ⚠️ 汇总必须反映**实况**（prDone），不能照抄 planned 计划。
// 事故（2026-10-25 实录，3.3.28）：bump 静默空转时每个仓都打「无列车变更,跳过」，
// 但汇总照样打印「✓ 已提交 → train/x」⇒ 人看日志以为成功了，实际**一个 PR 都没建**
// ⇒ 列车永远不动（且返回 success）。
//
// ⇒ 两条硬约束：
// ① 汇总行按 prDone 区分「已提交」/「未建 PR」；
// ② push 模式下**一个 PR 都没建** ⇒ 返回 error（绝不沉默）。
//
// 返回 error 而不直接 die —— 便于单测断言（die 会 os.Exit，杀掉测试进程）。
func printBumpSummary(b *bumper) error {
	fmt.Println("── 计划汇总")
	b.mu.Lock()
	defer b.mu.Unlock()
	any := false
	for _, r := range bumpRepos {
		files := b.planned[r]
		if len(files) == 0 {
			continue
		}
		any = true
		if b.push {
			if b.prDone[r] {
				fmt.Printf("  ✓ %s 已提交 → train/%s(%s)\n", r, b.train, strings.Join(files, " "))
			} else {
				fmt.Printf("  ✗ %s **未建 PR**(计划有变更但未落地) %s\n", r, strings.Join(files, " "))
			}
		} else {
			fmt.Printf("  [dry-run] %s 将变更 → 分支 train/%s + PR(%s)\n", r, b.train, strings.Join(files, " "))
		}
	}
	if !any {
		fmt.Println("  (无任何版本点变化——检查 TRAIN/--set 是否与现状一致)")
	}
	// 守卫（2026-10-25 实录）：**至少要有一个仓真的建了 PR**。
	// 否则 = 静默空转（列车号没推进、PR 没建、tag 没打，却返回 success）。
	// ⇒ 响亮失败，绝不沉默。
	if b.push {
		for _, r := range bumpRepos {
			if b.prDone[r] {
				return nil
			}
		}
		return fmt.Errorf("bump 未建任何 PR（静默空转）——列车号未推进、tag 未打。检查各仓「无列车变更,跳过」的根因（多半是切分支时编辑被还原/丢失）")
	}
	return nil
}

type bumper struct {
	env    *Env
	train  string
	hotfix bool
	push   bool

	// mu 保护下面两张表:各仓 bump 现在是**并行**跑的,汇总/记账要加锁。
	mu                              sync.Mutex
	oldServer, oldFCore             string
	oldTrain                        string
	contracts, core, kit, p2p, p2pc string
	p2pcRef                         string
	fcore, corePin                  string
	server, feTag                   string
	chart, chartApp                 string

	planned map[string][]string // repo 名("." = hub)→ 变更文件
	prDone  map[string]bool     // repo 名→ **确实**建了 PR(汇总行必须反映实况)
}

// notePlan 记一笔「本仓将变更的文件」(并行安全)。
func (b *bumper) notePlan(repo string, files ...string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.planned[repo] = append(b.planned[repo], files...)
}

// ───────────────────────── 写入原语 ─────────────────────────

// edit 对 <dir>/<rel> 应用纯函数编辑;内容有变则 push 模式落盘、dry-run 只记录。
// 返回是否变化。文件缺失时 old 视为空串(VERSION/DEPS.env 等生成物首建)。
func (b *bumper) edit(repoName, dir, rel string, fn func(old string) string) bool {
	p := filepath.Join(dir, rel)
	oldB, err := os.ReadFile(p)
	old := string(oldB)
	if err != nil && !os.IsNotExist(err) {
		die("读 %s 失败: %v", p, err)
	}
	if err != nil {
		old = ""
	}
	newS := fn(old)
	if newS == old {
		return false
	}
	if b.push {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			die("建目录失败 %s: %v", p, err)
		}
		if err := os.WriteFile(p, []byte(newS), 0o644); err != nil {
			die("写 %s 失败: %v", p, err)
		}
	}
	b.notePlan(repoName, rel)
	return true
}

// readRef 读工作树文件内容(不存在返回空)。
func readContent(dir, rel string) string {
	b, err := os.ReadFile(filepath.Join(dir, rel))
	if err != nil {
		return ""
	}
	return string(b)
}

// ───────────────────────── 预检与收尾(push 模式) ─────────────────────────

// originBaseBranch 返回「该仓远端默认分支的最新引用」（形如 "origin/main"），
// 供「同车次续跑」时以**最新远端主分支**为基线建列车分支。
//
// 为什么需要它（hub#163，2026-10-28 实录）：上一轮 bump 的 PR 合并后 GitHub 会
// 删除 `train/<v>` 分支 ⇒ 续跑时远端分支不存在 ⇒ 旧实现退化成「从当前 HEAD 建
// 同名分支」⇒ 而当前 HEAD 可能落后 origin/main ⇒ 历史分叉 ⇒ push 被判
// CONFLICTING ⇒ 5 个仓各需人工 rebase + force push。
//
// 两个必做动作：
//
//  1. **先 fetch**：origin/main 的本地引用可能是陈旧的（上一轮 bump 的合并提交
//     只在远端）⇒ 不 fetch 就拿 origin/main 仍是旧基线 ⇒ 分叉照旧。
//  2. **按仓取默认分支**：fnos 的默认分支是 master，其余是 main ⇒ 用统一的
//     "main" 会让 fnos 取到不存在的 origin/main ⇒ 静默退回 HEAD ⇒ 老问题复发。
//
// 取不到时返回错误，由调用方**告警并退回旧行为**（不静默换基线）。
func originBaseBranch(dir string) (string, error) {
	// 从 remote URL 反查仓名（dir 是本地路径，仓名才是默认分支的依据）。
	// 拿不到仓名时退回 "main"：这是绝大多数仓的默认分支，fnos 走下面的
	// remote HEAD 探测兜底。
	repo := repoNameFromDir(dir)
	def := defBranch(repo)
	if repo == "" {
		def = "main"
	}
	// 优先问 remote 自己「默认分支是谁」——最权威，且能覆盖 defBranch 的硬编码
	// （新增仓不必改代码）。问不到（无 origin/HEAD 符号引用）再退回 defBranch。
	if head, err := Git(dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil && head != "" {
		def = strings.TrimPrefix(head, "origin/")
	}
	if _, err := Git(dir, "fetch", "-q", "origin", def); err != nil {
		return "", fmt.Errorf("fetch origin %s: %w", def, err)
	}
	ref := "origin/" + def
	if !GitOK(dir, "rev-parse", "-q", "--verify", ref) {
		return "", fmt.Errorf("远端默认分支 %s 不存在", ref)
	}
	return ref, nil
}

// repoNameFromDir 从本地仓路径反查仓名（用于选默认分支）。
//
// 依据：hub 的仓布局是「hub 根内直接放模块仓」（core/ contracts/ fnos/ …），
// 桌面端与 charts 在兄弟目录。取**目录基名**即可覆盖模块仓；取不到时返回空串。
func repoNameFromDir(dir string) string {
	base := filepath.Base(strings.TrimRight(dir, "/"))
	if base == "" || base == "." || base == "/" {
		return ""
	}
	return base
}

// preflight 每仓默认分支+与远端 ff 对齐(2026-10-09 两起事故同根因:本地陈旧/
// 残留 train 分支)。不对齐就失败,绝不基于陈旧基线切分支。
func (b *bumper) preflight() {
	fmt.Println("── [0] 预检:仓库对齐")
	do := func(name string) {
		dir := b.env.MustRepoDir(name)
		def := defBranch(name)
		if name == "." {
			def = "main"
		}
		cur, err := Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
		if err != nil {
			die("%s 无法确定当前分支: %v", name, err)
		}
		if _, err := Git(dir, "fetch", "-q", "origin", def); err != nil {
			die("%s fetch %s 失败", name, def)
		}
		if cur != def {
			if _, err := Git(dir, "checkout", "-q", def); err != nil {
				die("%s 切回 %s 失败(有未提交改动请先清理)", name, def)
			}
		}
		if st, _ := Git(dir, "status", "--porcelain"); st != "" {
			warnf("%s 有未提交改动(列车文件隔离,不受影响;若涉列车文件请先处理)", name)
		}
		if GitOK(dir, "rev-parse", "-q", "--verify", "origin/"+def) {
			if _, err := Git(dir, "pull", "-q", "--ff-only", "origin", def); err != nil {
				die("%s 本地与 origin/%s 分歧(或有重叠改动),先人工 pull --ff-only", name, def)
			}
		}
		okf("%s@%s 已对齐远端", name, def)
	}
	do(".")
	// frontend 仅在镜像/前端 core 版本变化时参与(hotfix 子集跳过,免碰并行 WIP)
	if b.server != b.oldServer || b.fcore != b.oldFCore {
		do("frontend")
	}
	for _, r := range []string{"fnos", "openwrt", "qnap", "desktop", "synology", "ugreen", "terramaster"} {
		do(r)
	}
}

// snapshotTrainFiles 保存「列车管理的文件」中**已被本波 bump 改动**的当前内容。
//
// 返回 map[相对路径]内容（只含相对 HEAD 有改动的文件）。
func snapshotTrainFiles(dir string, files []string) map[string][]byte {
	out := map[string][]byte{}
	if len(files) == 0 {
		return out
	}
	args := append([]string{"diff", "--name-only", "HEAD", "--"}, files...)
	names, err := Git(dir, args...)
	if err != nil || strings.TrimSpace(names) == "" {
		return out
	}
	for _, name := range strings.Split(names, "\n") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if content, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
			out[name] = content
		}
	}
	return out
}

// snapshotHEADFiles 捕获**切分支前** HEAD（= 本波编辑的基线）里各文件的内容。
//
// 必须在切分支前调用：切分支后 HEAD 指向分支提交 ⇒ 取到的就是分支内容（= ours）
// ⇒ 三方合并的 base 变成 ours ⇒ 必判冲突 ⇒ 分支上的更新被整文件覆盖。
func snapshotHEADFiles(dir string, files []string) map[string][]byte {
	out := map[string][]byte{}
	for _, name := range files {
		content, err := Git(dir, "show", "HEAD:"+name)
		if err != nil {
			continue
		}
		out[name] = []byte(content)
	}
	return out
}

// restoreSavedFiles 把 snapshotTrainFiles 保存的内容写回（切分支之后）。
func restoreSavedFiles(dir string, saved map[string][]byte) {
	for name, content := range saved {
		_ = os.WriteFile(filepath.Join(dir, name), content, 0o644)
	}
}

// sortedKeys 返回 map 的键（排序后）——用于可读日志。
func sortedKeys(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// restoreTrainManagedFiles 把「列车管理的文件」中被本地改动（已跟踪文件的修改）
// 还原到 HEAD，返回被还原的文件列表（相对仓根）。
//
// 为什么需要（2026-10-25 实录）：同一车次重跑 bump 时，工作树里可能还留着
// **前一波** bump 写下的改动 ⇒ 随后的 `git checkout -b train/<v> …` 直接失败
// （"Your local changes … would be overwritten by checkout"）⇒ 整个 bump 死掉。
//
// 边界（重要）：
//
//	· **只**还原传入的列车管理文件清单 ⇒ 其它本地改动（用户的在制品）不受影响；
//	· **只**处理已跟踪文件的修改（` M`/`M ` 等）；未跟踪文件（`??`）不动
//	  （bump 的文件本来就在仓里，未跟踪只可能是用户自己的新文件）；
//	· 还原是**可见的**（调用方会打印还原了哪些文件），不静默吞改动。
func restoreTrainManagedFiles(dir string, files []string) []string {
	if len(files) == 0 {
		return nil
	}
	// 用 `git diff --name-only HEAD` 而不是 `git status --porcelain`：
	//   · porcelain 的状态列靠**前导空格**对齐，而 Git 助手会 TrimSpace 输出
	//     ⇒ 解析错位（实测把 " M VERSION" 截成 "M VERSION" ⇒ 路径读成 "ERSION"）；
	//   · diff 输出**纯路径**，无对齐问题；
	//   · diff 天然**不含未跟踪文件**（`??`）⇒ 用户的在制品不会被碰到。
	args := append([]string{"diff", "--name-only", "HEAD", "--"}, files...)
	out, err := Git(dir, args...)
	if err != nil || strings.TrimSpace(out) == "" {
		return nil
	}
	var restored []string
	for _, line := range strings.Split(out, "\n") {
		path := strings.TrimSpace(line)
		if path == "" {
			continue
		}
		if _, err := Git(dir, "checkout", "--", path); err != nil {
			continue
		}
		restored = append(restored, path)
	}
	return restored
}

// switchTrainBranch 切到（或新建）列车分支，**保住本波 bump 写下的编辑**。
//
// 为什么需要它（2026-10-25 实录，两个真实故障）：
//
//	A. 同一车次**重跑** bump（要把 pin 改指向新版本）时，工作树里还留着
//	   **前一波** bump 写下的改动 ⇒ `git checkout -b …` 直接失败
//	   （"Your local changes … would be overwritten by checkout"）⇒ 整个 bump 死掉。
//	B. 自踩：切分支前**只还原不保存** ⇒ 把**本波刚写好的**编辑抹回 HEAD
//	   ⇒ 所有仓报「无列车变更」⇒ **整趟 bump 静默空转**（还返回 success）。
//
// ⇒ 正确顺序：**保存 → 还原（让 checkout 能过）→ 切分支 → 写回**。
// 还原范围限定在**列车管理的文件**（不碰用户其它在制品）。
//
// 返回被保存（并已写回）的文件列表。
func switchTrainBranch(dir, branch, remoteBranch string, files []string) ([]string, error) {
	saved := snapshotTrainFiles(dir, files)
	// ⚠️ 基线必须在**切分支之前**捕获：切分支后 HEAD 就是**分支**的提交 ⇒
	//   `git show HEAD:<file>` 拿到的是分支内容（= ours）⇒ 三方合并的 base 错了
	//   ⇒ 判成冲突 ⇒ 整文件取「本波的值」⇒ **分支上的更新又被覆盖**
	//   （2026-10-25 实测：版本号又退回 3.3.30）。
	base := snapshotHEADFiles(dir, files)
	if len(saved) > 0 {
		restoreTrainManagedFiles(dir, files)
	}
	var err error
	switch {
	case GitOK(dir, "rev-parse", "-q", "--verify", "refs/heads/"+branch):
		if _, err = Git(dir, "checkout", "-q", branch); err != nil {
			return nil, err
		}
		// 本地同名分支可能落后远端 ⇒ 快进（分叉则响亮失败，不静默覆盖）
		if GitOK(dir, "rev-parse", "-q", "--verify", "refs/remotes/"+remoteBranch) {
			if _, err = Git(dir, "merge", "-q", "--ff-only", remoteBranch); err != nil {
				return nil, err
			}
		}
	case GitOK(dir, "rev-parse", "-q", "--verify", "refs/remotes/"+remoteBranch):
		if _, err = Git(dir, "checkout", "-q", "-b", branch, remoteBranch); err != nil {
			return nil, err
		}
	default:
		// ⚠️ 远端列车分支**不存在** ⇒ 上一轮 bump 的 PR 已合并（GitHub 合并后删分支）
		//   ⇒ 这是「同车次续跑」最常见的场景（2026-10-28 实录：4.0.7 列车改钉版
		//   p2p v0.9.4→v0.9.5，5 个仓的 PR 全部 CONFLICTING，需人工 rebase）。
		//
		//   根因：**基线用错了**。此处旧实现走「从当前 HEAD 建同名分支」⇒ 而当前
		//   HEAD（本地 main）**落后于 origin/main**（origin/main 里已含上一轮 bump
		//   的合并提交）⇒ 历史分叉 ⇒ push 时 GitHub 判 CONFLICTING。
		//
		//   ⇒ 正解：以 **origin/<该仓默认分支>**（fnos 是 master，其余是 main）为
		//   基线建分支 ⇒ 续跑产出的分支天然基于最新 main ⇒ 无冲突、无需人工介入。
		//
		//   为什么不用 `git checkout -b branch`（当前 HEAD）：本地 HEAD 可能比
		//   origin/main 旧**任意多个提交**（工作区长期不 pull、或上一轮 bump 的
		//   合并提交只在远端）⇒ 分叉是必然而非偶然。
		//
		//   为什么不是「fetch 后用 origin/main」就完事：还要**先更新**本地
		//   origin/main 引用，否则读到的仍是陈旧的 origin/main。
		//
		//   兜底：若 fetch 失败（离线/权限）⇒ 退回「从当前 HEAD 建分支」并**告警**
		//   （不静默换基线：发车者能看见这次可能需要人工 rebase）。
		base, baseErr := originBaseBranch(dir)
		if baseErr != nil {
			warnf("%s 取远端默认分支基线失败(%v),退回当前 HEAD 建分支(可能需人工 rebase)", dir, baseErr)
			if _, err = Git(dir, "checkout", "-q", "-b", branch); err != nil {
				return nil, err
			}
		} else {
			if _, err = Git(dir, "checkout", "-q", "-b", branch, base); err != nil {
				return nil, err
			}
		}
	}
	// 切分支完成后**写回**本波编辑（场景 B 的正解：编辑不能被还原抹掉）。
	// ⚠️ 但**不能直接覆盖**：分支上可能已经有**上一趟 bump 的更新**（同一列车号
	// 重跑时最典型：前一趟把 frontend 的 package.json 版本抬到 3.3.31，本趟
	// 因为「server 未变」跳过版本编辑 ⇒ 补丁里**没有**版本那一行；补丁的 base 取自
	// **main**（此时前一趟的 PR 还没合 ⇒ main 上版本还是 3.3.30）⇒ 直接写回 =
	// 用 main 的内容**盖掉**分支上的 3.3.31 ⇒ 版本退回 3.3.30，而 VERSION 文件
	// 不在本波编辑里 ⇒ 幸免于难 ⇒ **两处版本元数据分叉**（2026-10-25 实录：
	// 3.3.31 终判「frontend 源码版本(3.3.30)与 tag(v3.3.31)不同号」⇒ 镜像构建
	// 被硬门拦下——这道门禁是有效的）。
	// ⇒ 写回改成**打补丁**：`git apply --3way` 把「本波编辑相对 HEAD 的增量」打到
	//   **分支当前内容**上 ⇒ 两边的改动都在；真冲突 ⇒ **响亮失败**（不静默覆盖）。
	if err := mergeSavedIntoBranch(dir, files, saved, base); err != nil {
		return nil, err
	}
	return sortedKeys(saved), nil
}

// mergeSavedIntoBranch 把本波编辑（saved）三方合并到**分支当前内容**上。
//
// base = HEAD（切分支前的工作树基线）、ours = 分支上该文件的当前内容、
// theirs = 本波编辑后的内容。
//
//	· 分支没动过该文件（ours == base）⇒ 直接写 theirs；
//	· 两边都动过 ⇒ 三方合并（`git merge-file`）：
//	    - 改的是**不同位置** ⇒ 两边改动都在（正是 3.3.31 实录场景：分支抬了
//	      版本号、本波抬了 tgz 钉版 ⇒ 合并后两者都在）；
//	    - 改的是**同一处** ⇒ 取 **theirs（本波的值）**：列车的版本/钉版是**本波
//	      声明的权威值**，分支上的旧值只是上一趟的残留 ⇒ 本波为准，并**告警**
//	      （不静默：告警里能看到「分支上的改动被本波覆盖」这件事）。
func mergeSavedIntoBranch(dir string, files []string, saved map[string][]byte, base map[string][]byte) error {
	for _, name := range sortedKeys(saved) {
		theirs := string(saved[name])
		p := filepath.Join(dir, name)
		ours, err := os.ReadFile(p)
		if err != nil {
			// 分支上该文件不存在（如新增）⇒ 直接写本波编辑
			if werr := os.WriteFile(p, []byte(theirs), 0o644); werr != nil {
				return fmt.Errorf("写 %s 失败: %w", name, werr)
			}
			continue
		}
		baseContent := string(base[name])
		if string(ours) == baseContent {
			// 分支没动过这个文件 ⇒ 本波编辑直接落地
			if werr := os.WriteFile(p, []byte(theirs), 0o644); werr != nil {
				return fmt.Errorf("写 %s 失败: %w", name, werr)
			}
			continue
		}
		merged, conflicted, merr := mergeFileContents(dir, string(ours), baseContent, theirs)
		if merr != nil {
			return fmt.Errorf("合并 %s 失败: %w", name, merr)
		}
		if conflicted {
			warnf("%s: 分支上已有改动与本波编辑冲突 ⇒ 以**本波**的值为准（列车的版本/钉版以本波声明为准）", name)
		}
		if werr := os.WriteFile(p, []byte(merged), 0o644); werr != nil {
			return fmt.Errorf("写 %s 失败: %w", name, werr)
		}
	}
	return nil
}

// mergeFileContents 三方文本合并（base/ours/theirs）。
//
// 冲突时取 **theirs（本波的值）**（`git merge-file --theirs`）：列车的版本与钉版是
// 本波声明的权威值 ⇒ 冲突处以本波为准；`git merge-file` 仍会返回非 0（表示有
// 冲突），由调用方据实告警（不静默）。
func mergeFileContents(dir, ours, base, theirs string) (string, bool, error) {
	tmp, err := os.MkdirTemp("", "trainctl-merge-")
	if err != nil {
		return "", false, err
	}
	defer os.RemoveAll(tmp)
	fo := filepath.Join(tmp, "ours")
	fb := filepath.Join(tmp, "base")
	ft := filepath.Join(tmp, "theirs")
	for path, content := range map[string]string{fo: ours, fb: base, ft: theirs} {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return "", false, err
		}
	}
	// ⚠️ 不能用 Git() 助手：它对 stdout 做 TrimSpace ⇒ **末尾换行被吃掉**
	//   ⇒ 合并结果写回后文件少一个 "\n"（实测：VERSION 变成 "3.3.31" 而非
	//   "3.3.31\n"）⇒ 这里直接取原始 stdout。
	cmd := exec.Command("git", "-C", dir, "merge-file", "-p", "--theirs", fo, fb, ft)
	var buf strings.Builder
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	gerr := cmd.Run()
	out := buf.String()
	hadConflict := gerr != nil
	if hadConflict && strings.TrimSpace(out) == "" {
		return "", true, gerr
	}
	if strings.Contains(out, "<<<<<<<") {
		return "", true, fmt.Errorf("合并仍有冲突标记")
	}
	return out, hadConflict, nil
}

// stageTrainFiles 把列车文件暂存到列车分支上，返回「切分支时被保存并写回的
// 文件」与「暂存区是否有变更」。
//
// ⚠️ 这里是 2026-10-25「静默空转」事故的**真正根因**（3.3.28 实录）：
// 原 commit() 在调 switchTrainBranch **之前**自己做了一次「快照 + 还原到 HEAD」，
// 而 switchTrainBranch 内部**又**做了一次「快照 + 还原 + 切 + 写回」
// ⇒ 外层把编辑还原掉后，内层快照到的是**已还原**的内容（空的）⇒
// 写回时什么也没写 ⇒ 编辑彻底丢失 ⇒ `git add` 暂存的是 HEAD 内容 ⇒
// `git diff --cached --quiet` 恒真 ⇒ 「无列车变更,跳过」⇒ **不 push、不建 PR**，
// 却仍然打印「✓ 已提交 → train/x」⇒ **整趟 bump 静默空转**（还返回 success）。
//
// ⇒ 正确做法：**只做一次**「保存 → 还原 → 切分支 → 写回」（switchTrainBranch 内），
// 切完再 `git add`。本函数是这条链路的唯一入口（便于单测端到端复现）。
func stageTrainFiles(dir, branch, remoteBranch string, files []string) (switched []string, hasDiff bool, err error) {
	// 切分支（**保住本波编辑**：保存 → 还原 → 切 → 写回；见 switchTrainBranch 注释）
	switched, err = switchTrainBranch(dir, branch, remoteBranch, files)
	if err != nil {
		return nil, false, err
	}
	// 切分支**之后**再暂存列车文件（顺序要点见 commit 里的注释）⇒ 暂存内容基于目标基线。
	args := append([]string{"add", "--"}, files...)
	if _, err := Git(dir, args...); err != nil {
		return switched, false, fmt.Errorf("git add 失败: %w", err)
	}
	return switched, !GitOK(dir, "diff", "--cached", "--quiet"), nil
}

// commit 在 push 模式提交列车文件并建 PR + 开启自动合并;dry-run 无操作
// (计划已在 edit() 收集)。files 中不存在的路径自动忽略。
func (b *bumper) commit(repoName, dir, msg string, files []string) {
	if !b.push {
		return
	}
	exist := []string{}
	for _, f := range files {
		if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
			exist = append(exist, f)
		}
	}
	branch := "train/" + b.train
	// ⚠️ 远端可能**已有**该列车分支（前几轮推进已推过：bump → 合并 → advance
	// 推 state 变更）。CI 上是 fresh clone ⇒ 本地没有 refs/heads/<branch> ⇒
	// 旧逻辑走「checkout -b」⇒ **基于当前 HEAD(main) 新建同名分支** ⇒ 其历史与
	// 远端列车分支分叉 ⇒ push 时 non-fast-forward 被拒 ⇒ **列车卡死**。
	// 实录：2026-10-24 的 3.3.16（bump PR 已合并后再次推进）就是这样失败的。
	// ⇒ 先 fetch 远端同名分支：存在则在其上继续（快进），不存在才从当前 HEAD 建。
	//
	// ⚠️ 顺序要点：**先切分支，再 git add 列车文件**。反过来的话，checkout 会把
	// 工作树切到目标基线 ⇒ 暂存区里「基于 main 的列车文件改动」可能被覆盖/
	// 丢失（实测：checkout 到 origin/train/x 后 main 上的新增文件消失 ⇒
	// commit 变成「nothing to commit」⇒ 列车变更静默丢失）。
	Git(dir, "fetch", "-q", "origin", branch)
	remoteBranch := "origin/" + branch
	// 暂存列车文件（保存 → 还原 → 切 → 写回 → add；**只做一次**快照/还原，
	// 见 stageTrainFiles 注释里的事故复盘）
	switched, hasDiff, err := stageTrainFiles(dir, branch, remoteBranch, exist)
	if err != nil {
		die("%s 切列车分支 %s 失败: %v", repoName, branch, err)
	}
	if len(switched) > 0 {
		warnf("%s 工作树里下列列车文件有改动（已保存、切分支后写回）: %s",
			repoName, strings.Join(switched, ", "))
	}
	// hadEdits = 本仓**确实有版本点变化**（edit() 记下的计划）。
	// 区分两种「无 diff」：① 仓本来就无需变（跳过合理）② 列车分支上**已有**
	// 同样的内容（重跑场景：内容对但 PR 可能还没建 ⇒ 仍须 push + 确保 PR）。
	hadEdits := len(b.planned[repoName]) > 0
	if !hasDiff {
		if !hadEdits {
			okf("%s 无列车变更,跳过", repoName)
			return
		}
		warnf("%s 列车分支上已是相同内容(重跑?),继续 push 并确保 PR 存在", repoName)
	}
	if hasDiff {
		if _, err := Git(dir, "commit", "-qm", msg); err != nil {
			die("%s commit 失败: %v", repoName, err)
		}
	}
	if _, err := Git(dir, "push", "-q", "-u", "origin", branch); err != nil {
		die("%s push %s 失败: %v", repoName, branch, err)
	}
	repo := repoName
	if repo == "." {
		repo = "pigeonbox"
	}
	base := defBranch(repo)
	prOut, err := ghRunner("pr", "create", "-R", ghOrg+"/"+repo, "--base", base, "--head", branch,
		"--title", "train: bump to "+b.train,
		"--body", "发布列车 "+b.train+" 自动 bump(hub release/trainctl 生成,仅含列车文件)。合并后由 hub train-orchestrator 打 tag 并触发 Release 流水线;回调/sweep 推进 finalize。")
	if err != nil {
		if strings.Contains(strings.ToLower(prOut+err.Error()), "already exists") {
			fmt.Printf("  (PR 已存在,跳过创建) %s\n", repoName)
		} else {
			// 吞错会把网络抖动误报成「已存在」(1.15.2 fnos 幻影 PR 根因)——响亮失败,重跑幂等
			die("%s gh pr create 失败: %v(%s)", repoName, err, prOut)
		}
	} else {
		okf("PR: %s", prOut)
	}
	// 自动合并:checks 绿即 squash(仓未开 auto-merge 时由 advance 在 checks 绿后直接合并)
	if _, err := ghRunner("pr", "merge", branch, "--auto", "--squash", "--repo", ghOrg+"/"+repo); err != nil {
		warnf("%s auto-merge 未开启(%v 摘要),advance 将在 checks 绿后合并", repoName, firstLine(err.Error()))
	}
	// 记账：**确实**建了 PR 的仓（汇总行必须反映实况，不能照抄 planned 计划）。
	b.mu.Lock()
	b.prDone[repoName] = true
	b.mu.Unlock()
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// restoreBranches 真还原各仓默认分支(v1 只 echo 提示不执行的教训:
// bump 后 hub 停在列车分支,后续手工提交极易落错分支)。
func (b *bumper) restoreBranches() {
	pairs := map[string]string{".": "main", "frontend": "main", "fnos": "master", "openwrt": "main",
		"qnap": "main", "synology": "main", "ugreen": "main", "terramaster": "main", "desktop": "main"}
	for _, r := range bumpRepos {
		dir, ok := b.env.RepoDir(r)
		if !ok {
			continue
		}
		def := pairs[r]
		cur, _ := Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
		if cur == def {
			continue
		}
		if _, err := Git(dir, "checkout", "-q", def); err == nil {
			fmt.Printf("    restore %s → %s\n", r, def)
		} else {
			warnf("%s 还原 %s 失败(需人工 checkout)", r, def)
		}
	}
}

// ───────────────────────── 各仓写入 ─────────────────────────

func (b *bumper) hub() {
	fmt.Println("── [1] hub")
	dir := b.env.MustRepoDir(".")
	b.edit(".", dir, "deploy/nas/compose.yml", func(o string) string { return SetComposeImageTag(o, b.server) })
	b.edit(".", dir, "deploy/nas/env.example", func(o string) string { return SetEnvImageTag(o, b.server) })
	b.edit(".", dir, "deploy/k8s/overlays/prod/kustomization.yaml", func(o string) string { return SetNewTag(o, b.server) })
	// train.yaml 的内容**先算出来**（不落盘）⇒ 在写入前就能校验它。
	//
	// 守卫（2026-10-25 自踩引入）：切分支前把「列车管理文件」的本地改动**只还原
	// 不保存** ⇒ 把本波刚写好的 train.yaml 抹回 HEAD ⇒ 所有仓报「无列车变更」⇒
	// **整趟 bump 静默空转**：列车号没推进、PR 没建、tag 没打，却返回 success。
	// ⇒ 这里响亮失败：bump 的产物与目标列车号不一致 ⇒ 绝不沉默。
	//
	// ⚠️ 校验的是**即将写入的内容**，不是磁盘上的文件：
	// dry-run 模式下 edit 不落盘 ⇒ 读磁盘永远读到旧列车号 ⇒ 守卫会假红。
	trainYAML := Render(TrainParams{
		Train: b.train, State: "draft", Hotfix: b.hotfix,
		Contracts: b.contracts, Core: b.core, Kit: b.kit, P2P: b.p2p, FCore: b.fcore,
		Server: b.server, FETag: b.feTag, Chart: b.chart, ChartApp: b.chartApp,
		P2PCRef: b.p2pcRef, CorePin: b.corePin, Platforms: platforms,
	})
	if !trainYAMLHasTrain(trainYAML, b.train) {
		die("hub 的 train.yaml 产物未写上列车号 %s（bump 产物与目标不符——绝不沉默通过）", b.train)
	}
	b.edit(".", dir, trainFileRel, func(string) string { return trainYAML })

	// 文档矩阵(architecture.md 入库;AGENTS.md 为工作区文件不入库,dry-run 不落盘)
	arch := readContent(dir, "docs/architecture.md")
	cells := [][2]string{
		{"contracts", b.contracts}, {"core", b.core}, {"frontend-core", b.fcore},
		{"server", "v" + b.server}, {"frontend", b.feTag + "(随列车产品号)"},
		{"fnos", "v" + b.train + "(内置 core " + b.corePin + ")"},
		{"openwrt", "v" + b.train + "(内置 core " + b.corePin + ")"},
		{"qnap", "v" + b.train + "(原生,内置 core " + b.corePin + ")"},
		{"NAS 打包三仓", "v" + b.train + "(钉 server/frontend 镜像 v" + b.server + ")"},
		{"p2p", b.p2p}, {"kit", b.kit}, {"desktop", "desktop-v" + b.train},
		{"charts", "chart " + b.chart + "(app v" + b.server + ")"},
	}
	for _, c := range cells {
		next, hit := SetTableCell3(arch, c[0], c[1])
		if !hit {
			warnf("architecture.md 未找到表格行(跳过): %s", c[0])
			continue
		}
		arch = next
	}
	b.edit(".", dir, "docs/architecture.md", func(string) string { return arch })

	// README 版本表（2026-10-23 补）：此前只改 architecture.md 与 AGENTS.md，
	// **README 的版本表漏了** ⇒ 靠人记得改 ⇒ 实测落后两列车（且宣称已退役能力）
	// ⇒ 每次发车就再漂一次。归列车管：bump 同步改写，verify section9b 兜底。
	readmeCells := [][2]string{
		{"contracts", b.contracts}, {"core", b.core}, {"frontend-core", b.fcore},
		{"server", "v" + b.server}, {"desktop", "desktop-v" + b.train},
		{"fnos", "v" + b.train}, {"openwrt", "v" + b.train}, {"qnap", "v" + b.train},
		{"synology", "v" + b.train}, {"ugreen", "v" + b.train}, {"terramaster", "v" + b.train},
		{"p2p", b.p2p}, {"charts", "pigeonbox-" + b.chart},
	}
	for _, fname := range []string{"README.md", "README.en-US.md"} {
		content := readContent(dir, fname)
		if content == "" {
			continue
		}
		next := content
		for _, c := range readmeCells {
			updated, hit := SetReadmeVersionCell(next, c[0], c[1])
			if !hit {
				warnf("%s 未找到版本表行(跳过): %s", fname, c[0])
				continue
			}
			next = updated
		}
		if next != content {
			b.edit(".", dir, fname, func(string) string { return next })
		}
	}

	// 文档站 CLI 页的版本引用（2026-10-26 补）：scripts/check-docs-consistency.sh ③
	// 断言「页内 vX.Y.Z == 当前列车号」⇒ **若 bump 不改这一页，每趟车该门禁必红**
	// （实测 4.0.2 列车 PR 上就红了：train.yaml 已抬到 4.0.2，CLI 页还写 v4.0.1）
	// ⇒ 归列车管（与 README/architecture 同款思路：靠人记得改 = 每次发车再漂一次）。
	//
	// 只替换**旧列车号**的引用：页内「首发版本 v3.3.15」这类历史说明必须原样保留
	// （门禁对含「首发/历史/已退役」标注的行放行）。
	//
	// ⚠️ 边界：页内出现形式是「**v4.0.2**」与「download/v4.0.2/」⇒ 后面跟的是
	// `*` / `/` 而不是「.」⇒ 用 `v<旧>([^.0-9])` 匹配（保留分隔符），**不能**用
	// 朴素的 "v<旧>." ⇒ 否则一行都替换不到（实测 4.0.3 列车上就是这个坑：
	// 文档仍写 v4.0.2 ⇒ 文档对账门禁红）。
	if b.oldTrain != "" && b.oldTrain != b.train {
		cliDoc := "docs-site/guide/cli.md"
		if content := readContent(dir, cliDoc); content != "" {
			re := regexp.MustCompile(`v` + regexp.QuoteMeta(b.oldTrain) + `([^.0-9])`)
			next := re.ReplaceAllString(content, `v`+b.train+`${1}`)
			if next != content {
				b.edit(".", dir, cliDoc, func(string) string { return next })
			}
		}
	}

	if ag, err := os.ReadFile(filepath.Join(dir, "..", "AGENTS.md")); err == nil {
		agents := string(ag)
		rows := [][2]string{
			{"`PigeonBox/`", "v" + b.train},
			{"`PigeonBox/contracts/`", b.contracts},
			{"`PigeonBox/core/`", b.core},
			{"`PigeonBox/frontend-core/`", b.fcore},
			{"`PigeonBox/server/`", "v" + b.server + " / core " + b.core},
			{"`PigeonBox/frontend/`", b.feTag + "(VERSION 真相源,随产品号)"},
			{"`PigeonBox/fnos/`", "v" + b.train + " / core " + b.corePin},
			{"`PigeonBox/openwrt/`", "v" + b.train + " / core " + b.corePin},
			{"`PigeonBox/qnap/`", "v" + b.train + " / core " + b.corePin},
			{"`PigeonBox/p2p/`", b.p2p},
			// kit 已归档（2026-10-16，并入 oekit）⇒ 版本台账无此条目 ⇒ 不再改它的
			// 版本单元格（此前会把 AGENTS.md 里的 v0.3.1 抹成空）。
			{"`desktop/`", "desktop-v" + b.train},
			{"`charts/`", "chart " + b.chart + " / app v" + b.server},
		}
		for _, p := range platforms {
			rows = append(rows, [][2]string{{"`PigeonBox/" + p + "/`", "v" + b.train + " / images v" + b.server}}...)
		}
		for _, r := range rows {
			next, hit := SetTableLastCell(agents, r[0], r[1])
			if !hit {
				warnf("AGENTS.md 未找到表格行(跳过): %s", r[0])
				continue
			}
			agents = next
		}
		if b.push {
			if err := os.WriteFile(filepath.Join(dir, "..", "AGENTS.md"), []byte(agents), 0o644); err != nil {
				warnf("AGENTS.md 写入失败: %v", err)
			} else {
				okf("AGENTS.md 版本矩阵已更新(工作区文件,不入库)")
			}
		} else if agents != string(ag) {
			fmt.Println("  [dry-run] ../AGENTS.md 版本矩阵将更新(工作区文件,不入库)")
		}
	}

	// ⚠️ 提交文件清单是**硬编码**的：b.edit 写了的文件若不在此列表 ⇒ 不会被
	// git add ⇒ 改动留在工作树不进提交（2026-10-23 实弹：README 版本表
	// 自动改写"看着生效"却从没进过 PR —— planned 里有、提交里没有）。
	b.commit(".", dir, "train: bump to "+b.train, []string{
		trainFileRel, "deploy/nas/compose.yml", "deploy/nas/env.example",
		"deploy/k8s/overlays/prod/kustomization.yaml", "docs/architecture.md",
		"README.md", "README.en-US.md",
		// CLI 文档页：check-docs-consistency.sh ③ 断言它等于当前列车号 ⇒ 必须随车改
		"docs-site/guide/cli.md",
	})
}

// lockRefresh package.json 的任何写点都同步记录在 package-lock.json,只改 json
// 不刷 lock = 消费仓 npm ci 拒装(1.15.0 实测四仓 main CI 红)。push 模式才执行。
func (b *bumper) lockRefresh(dir string) {
	if !b.push {
		return
	}
	if err := Run(dir, nil, "npm", "install", "--package-lock-only", "--no-audit", "--no-fund"); err != nil {
		warnf("%s package-lock 刷新失败,人工检查(否则 npm ci 拒装)", dir)
	}
}

func (b *bumper) frontend() {
	fmt.Println("── [2] frontend(壳)")
	dir := b.env.MustRepoDir("frontend")
	changed := false
	if b.server != b.oldServer {
		changed = b.edit("frontend", dir, "package.json", func(o string) string {
			return SetFirstJSONVersion(o, strings.TrimPrefix(b.feTag, "v"))
		}) || changed
		changed = b.edit("frontend", dir, "VERSION", func(string) string {
			return strings.TrimPrefix(b.feTag, "v") + "\n"
		}) || changed
	} else {
		okf("server 未变(v%s),frontend 版本跳过", b.server)
	}
	// frontend-core tgz 钉版跟随:无条件幂等写(v1「FCORE 变才写」的条件块
	// 在重跑/基线已抬场景静默跳过,1.15.0 实测四处 tgz 全漏写)
	// tgz 钉版跟随:frontend-core 与 contracts 都无条件幂等写。contracts 此前
	// 只在 contracts 仓自己的 release 产物里更新,消费方的 package.json 常年
	// 停在旧版(实测 fnos/qnap 的 web 仍钉 v0.10.1,列车要求 v0.17.0)——
	// 消费方拿到的是过期 wire 类型,且列车对账查不到(只查 frontend-core 那条)。
	changed = b.edit("frontend", dir, "package.json", func(o string) string {
		return ReplaceTGZ(ReplaceTGZ(o, "frontend-core", b.fcore), "contracts", b.contracts)
	}) || changed
	if changed {
		b.lockRefresh(dir)
		b.commit("frontend", dir, "train: bump to "+b.train, []string{"package.json", "VERSION", "package-lock.json"})
	}
}

func (b *bumper) fnos() {
	fmt.Println("── [3] fnos")
	dir := b.env.MustRepoDir("fnos")
	b.edit("fnos", dir, "VERSION", func(string) string { return b.train + "\n" })
	b.edit("fnos", dir, "DEPS.env", func(string) string {
		return RenderDepsEnv([][2]string{{"CORE_PIN", b.corePin}, {"FRONTEND_CORE_PIN", b.fcore}, {"P2PC_REF", b.p2pcRef}})
	})
	// web/package.json:版本=前端列车号(页脚「前端版本」);tgz URL 跟随 lib.frontend-core
	pjChanged := b.edit("fnos", dir, "web/package.json", func(o string) string {
		return ReplaceTGZ(
			ReplaceTGZ(SetFirstJSONVersion(o, strings.TrimPrefix(b.feTag, "v")), "frontend-core", b.fcore),
			"contracts", b.contracts)
	})
	// manifest version 无条件写(幂等)——1.14.4 教训:条件跳过会把 manifest 漏出 PR
	b.edit("fnos", dir, "fnos/manifest", func(o string) string {
		return EnsureManifestChangelog(SetManifestVersion(o, b.train), b.train, b.corePin, b.feTag)
	})
	files := []string{"VERSION", "DEPS.env", "fnos/manifest", "web/package.json", "web/package-lock.json"}
	if pjChanged {
		b.lockRefresh(filepath.Join(dir, "web"))
	}
	if b.goModPin(dir, "fnos", true) {
		files = append(files, "go.mod", "go.sum")
	}
	b.commit("fnos", dir, "train: bump to "+b.train, files)
}

// server 镜像仓:版本=tag 同号(无 VERSION 文件)。
// 2026-10-22 Wave B':镜像**不再随包 p2pc**(直传拆为独立应用 PigeonBeam),
// .p2pc-version 钉版点随之退休(此前它是本仓唯一钉版点)。
func (b *bumper) serverRepo() {
	fmt.Println("── [server]")
	dir := b.env.MustRepoDir("server")
	files := []string{}
	// go.mod 钉版随库线(1.21.0 教训:此前每趟手工"补 bump tidy 缺口",漏了就镜像带旧 core)
	if b.goModPin(dir, "server", true) {
		files = append(files, "go.mod", "go.sum")
	}
	b.commit("server", dir, "train: bump to "+b.train, files)
}

// native openwrt/qnap 同构:VERSION+DEPS.env+web/(+go.mod 钉版)。
func (b *bumper) native(name string) {
	fmt.Printf("── [%s]\n", name)
	dir := b.env.MustRepoDir(name)
	oldVer := strings.TrimSpace(readContent(dir, "VERSION"))
	// ⚠️ 旧 CORE_PIN 必须在**编辑 DEPS.env 之前**读（2026-10-24 实录修）：
	// 原实现在 edit 之后才读 ⇒ 读到的已是本轮新值 ⇒ 「仓内旧钉 ≠ 本轮 core_pin」
	// 的强制对齐条件恒为假 ⇒ goModPin 被跳过 ⇒ **DEPS.env 声称新钉、go.mod 漏升**
	// ⇒ NAS 包里嵌的 core 仍是旧版（3.3.16 实录：openwrt/qnap 的 v3.3.16 tag 里
	// core 仍是 v0.31.9，而 train.yaml 期望 v0.32.0 ⇒ verify 拦下）。
	// 仓内注释提到的「2.1.0 二波 bump 坑」修复因读错时机而从未生效。
	oldCorePin := depsValue(readContent(dir, "DEPS.env"), "CORE_PIN")
	b.edit(name, dir, "VERSION", func(string) string { return b.train + "\n" })
	b.edit(name, dir, "DEPS.env", func(string) string {
		return RenderDepsEnv([][2]string{{"CORE_PIN", b.corePin}, {"FRONTEND_CORE_PIN", b.fcore}, {"P2PC_REF", b.p2pcRef}})
	})
	pjChanged := b.edit(name, dir, "web/package.json", func(o string) string {
		return ReplaceTGZ(
			ReplaceTGZ(SetFirstJSONVersion(o, strings.TrimPrefix(b.feTag, "v")), "frontend-core", b.fcore),
			"contracts", b.contracts)
	})
	files := []string{"VERSION", "DEPS.env", "web/package.json", "web/package-lock.json"}
	if pjChanged {
		b.lockRefresh(filepath.Join(dir, "web"))
	}
	// 二波 bump 坑(2.1.0 实锤):首波已改 VERSION→本波 oldVer==train,但 CORE_PIN
	// 升级只落 DEPS.env,goModPin 被 force=false 跳过→DEPS 声称新钉而 go.mod 漏升,
	// openwrt Release 断言拦截、qnap 缺断言静默不一致。force 追加:仓内 DEPS 旧
	// CORE_PIN ≠ 本轮 core_pin 时同样强制对齐检查。
	// （oldCorePin 已在上方**编辑前**读取——读编辑后的值会让条件恒假。）
	if b.goModPin(dir, name, oldVer != b.train || (oldCorePin != "" && oldCorePin != b.corePin)) {
		files = append(files, "go.mod", "go.sum")
	}
	b.commit(name, dir, "train: bump to "+b.train, files)
}

// goModPin 终端仓 go.mod 的 core 钉版(默认保持现状——升钉是显式列车动作,
// fnos v1.2.7 教训)。force=false 且版本未变时跳过(v1 openwrt/qnap 语义);
// fnos 恒检查(force=true)。返回是否有(或将有)变更。
// 判定读 require 行实态(v1 用 `core@ver` 字面 grep 恒不中,每次 bump 空转
// edit+tidy 且计划误报);push 模式跑完 edit+tidy 后以 git diff 定案。
func (b *bumper) goModPin(dir, name string, force bool) bool {
	if !force {
		return false
	}
	gm := readContent(dir, "go.mod")
	if pinchkHas(gm, "core", b.corePin) {
		return false
	}
	if !b.push {
		b.notePlan(name, "go.mod", "go.sum")
		fmt.Printf("  [dry-run] %s go.mod 将钉 core@%s\n", name, b.corePin)
		return true
	}
	if err := Run(dir, []string{"GOWORK=off"}, "go", "mod", "edit", "-require=github.com/pigeonbox/core@"+b.corePin); err != nil {
		warnf("%s go mod edit 失败,人工检查: %v", name, err)
		return false
	}
	// contracts 同钉(MVS 抬底):core 消费 contracts 新类型时,消费方显式 require
	// 是编译通过的下限——1.22.0 列车断链教训(库 tag 勿挪,抬底先行)
	if err := Run(dir, []string{"GOWORK=off"}, "go", "mod", "edit", "-require=github.com/pigeonbox/contracts@"+b.contracts); err != nil {
		warnf("%s contracts go mod edit 失败: %v", name, err)
	}
	// go mod tidy **重试**：库线 tag 是刚推的，**模块代理还没同步该版本**
	// （proxy.golang.org / goproxy.cn 都有同步延迟）⇒ 第一次 tidy 会报
	// "unknown revision" ⇒ go.sum 缺新版本的哈希 ⇒ 该趟 PR 的组件 CI 全红在
	// 「missing go.sum entry」（实测 4.0.2 列车：fnos 的 test/package/govulncheck
	// 三个 job 同时红在这条）。
	// ⇒ 重试几次（间隔 20s，代理同步通常在分钟内完成）；仍失败则**响亮中止**：
	//   产出一个 go.sum 缺哈希的 PR ＝ 把必红的门禁留给下一个人，不如现在就停。
	//   bump 可重跑（--push 续跑），代理同步后重跑即可。
	var tidyErr error
	for attempt := 1; attempt <= 3; attempt++ {
		if tidyErr = Run(dir, []string{"GOWORK=off"}, "go", "mod", "tidy"); tidyErr == nil {
			break
		}
		warnf("%s go mod tidy 第 %d/3 次失败（模块代理可能尚未同步刚推的库线 tag）: %v", name, attempt, tidyErr)
		if attempt < 3 {
			time.Sleep(20 * time.Second)
		}
	}
	if tidyErr != nil {
		die("%s go mod tidy 连续 3 次失败 ⇒ go.sum 会缺哈希 ⇒ 该趟 PR 的组件 CI 必红（missing go.sum entry）。等模块代理同步后重跑 bump: %v", name, tidyErr)
	}
	return !GitOK(dir, "diff", "--quiet", "--", "go.mod", "go.sum")
}

// pinchkHas go.mod 内容中 module 是否已钉 want(与 verify pinchk 同判据)。
func pinchkHas(gomod, module, want string) bool {
	wantNoV := strings.TrimPrefix(want, "v")
	for _, m := range rePin.FindAllStringSubmatch(gomod, -1) {
		if m[1] == module || strings.HasPrefix(m[1], module+"/") {
			return m[2] == wantNoV
		}
	}
	return false
}

func (b *bumper) desktop() {
	fmt.Println("── [6] desktop")
	dir := b.env.MustRepoDir("desktop")
	b.edit("desktop", dir, "VERSION", func(string) string { return b.train + "\n" })
	// 2026-10-22 Wave B':desktop 不再随包 p2pc sidecar(直传改由 PigeonBeam
	// 提供),DEPS.env 的 P2PC_REF 钉版点随之退休 ⇒ 本仓不再写该文件。
	b.edit("desktop", dir, "src-tauri/tauri.conf.json", func(o string) string { return SetFirstJSONVersion(o, b.train) })
	b.edit("desktop", dir, "src-tauri/Cargo.toml", func(o string) string { return SetCargoVersion(o, b.train) })
	// 锁文件同步：只写 Cargo.toml 会让 Cargo.lock 的包版本永远停在上一趟
	// （实测 desktop-v2.2.0 的锁文件仍写 2.0.5）——`cargo build --locked` 直接
	// 失败，且锁文件对实际构建版本说谎。
	b.edit("desktop", dir, "src-tauri/Cargo.lock", func(o string) string {
		return SetCargoLockVersion(o, "pigeonbox-desktop", b.train)
	})
	b.commit("desktop", dir, "train: bump to "+b.train, []string{
		"VERSION", "src-tauri/tauri.conf.json", "src-tauri/Cargo.toml",
		"src-tauri/Cargo.lock",
	})
}

func (b *bumper) nasPlatforms() {
	fmt.Println("── [7] NAS 打包三仓(模板→物化→VERSION)")
	commitFiles := map[string][]string{
		"synology":    {"VERSION", "spk/package/compose.yml", "spk/package/env.example"},
		"ugreen":      {"VERSION", "deploy/compose.yml", "deploy/env.example", "deploy/compose.ghcr-mirror.yml"},
		"terramaster": {"VERSION", "deploy/compose.yml", "deploy/env.example"},
	}
	for _, p := range platforms {
		dir := b.env.MustRepoDir(p)
		if b.push {
			if err := Run(b.env.Root, nil, "bash", "deploy/nas/sync.sh", "sync", "--platform", p, "--dir", dir); err != nil {
				die("sync.sh sync %s 失败: %v", p, err)
			}
		}
		// 物化后**按本车镜像 tag 归位**（2026-10-23 实弹）：
		// sync.sh 的物化源是 GitHub 上的 main（bump 运行时 hub 的模板还没提交，
		// ⇒ 物化出来的是**上一车**的镜像 tag）⇒ NAS 仓的 compose/env 停在旧车号，
		// 而漂移门禁比的是 train/<v> 分支的模板（本车）⇒ 差一版 ⇒ lint 红、
		// bump PR 合不进去。故：物化后统一把镜像 tag 钉到本车号。
		b.edit(p, dir, composePath(p), func(o string) string { return SetComposeImageTag(o, b.server) })
		b.edit(p, dir, envPath(p), func(o string) string { return SetEnvImageTag(o, b.server) })
		if p == "ugreen" {
			b.edit(p, dir, "deploy/compose.ghcr-mirror.yml", func(o string) string { return SetComposeImageTag(o, b.server) })
		}
		if b.push {
			// sync 物化的文件计入计划(compose/env 模板带镜像钉版)
			for _, f := range commitFiles[p][1:] {
				b.noteIfChanged(p, dir, f)
			}
		}
		b.edit(p, dir, "VERSION", func(string) string { return b.train + "\n" })
		b.commit(p, dir, fmt.Sprintf("train: bump to %s(镜像 v%s)", b.train, b.server), commitFiles[p])
	}
}

// noteIfChanged push 模式下把 sync.sh 已改动的文件补记入计划(git diff 判定)。
func (b *bumper) noteIfChanged(repo, dir, rel string) {
	if !GitOK(dir, "diff", "--quiet", "--", rel) {
		b.notePlan(repo, rel)
	}
}

func composePath(p string) string {
	if p == "synology" {
		return "spk/package/compose.yml"
	}
	return "deploy/compose.yml"
}

func envPath(p string) string {
	if p == "synology" {
		return "spk/package/env.example"
	}
	return "deploy/env.example"
}

// followCorePin 终端 core 钉版的派生规则（2026-10-24）：
//
//	显式 --set core_pin= → 调用方直接采用（终端故意滞后于库线的口子）；
//	lib.core 变更且未显式指定 ⇒ 终端钉版**跟随 lib.core**；
//	lib.core 未变 ⇒ 保持现状（不产生无关 diff）。
//
// 为什么必须跟随：终端产物（server 镜像的 go.mod + NAS 三端 DEPS.env）里带的
// core 版本若与库线不同版，本次库线改动根本不在产物里 ⇒ 只 --set core= 而漏
// --set core_pin= 时会静默留下旧钉版，直到 tag 阶段被「裸奔 tag 拦截」才发现
// （3.3.16 实录：列车卡 draft）。
func followCorePin(curPin, libCore string, libCoreChanged bool) (string, bool) {
	if !libCoreChanged || libCore == "" {
		return curPin, false
	}
	if curPin == libCore {
		return curPin, false
	}
	return libCore, true
}
