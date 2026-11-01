package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// cmdVerify 是 v1 release-train.sh verify 十一节的等价移植(语义逐条对齐,
// 输出风格一致以便对拍)。返回进程退出码。
func cmdVerify(env *Env, ci bool) int {
	tf, err := LoadTrainFile(env)
	if err != nil {
		failf("%v", err)
		return 1
	}
	v := &verifier{env: env, tf: tf, ci: ci, state: tf.Get("state")}
	train := tf.Get("train")
	if train == "" {
		failf("train.yaml 解析失败(缺 train)")
		return 1
	}

	// 列车进行中探测:任一仓存在**未合并的 train/* bump PR** ⇒ 主分支版本面
	// 必然落后于 train.yaml(中间态),主分支对账项降级告警;全合并后自动恢复严格。
	//
	// ⚠️ **必须找「任何车次」的 train/* PR**，不能只找 `train/<train.yaml 的车次>`
	// （2026-10-31 实测的假红）：Train Verify 在 PR 上跑时，checkout 到的是
	// 「PR 的 merge commit」⇒ hub 的 train.yaml 可能**还没合这趟车的 bump**
	// ⇒ 读到的车次是**上一趟** ⇒ 只找 `train/<上一趟>` ⇒ **一个都找不到**
	// ⇒ 判定「不在途」⇒ 严格判 ⇒ 而此时组件仓的 bump PR 早已合并、
	// 组件仓 main 已是新车次 ⇒ **拿旧车次比新车次 ⇒ 报一堆假漂移**
	// ⇒ **无关 PR 被红**（实测 pigeonbox#224 被红：期望 4.6.4、实得 4.6.5）。
	// ⇒ 正确口径：**任何开着的 train/* PR** 都说明有车正在开 ⇒ 降级告警。
	for _, repo := range inFlightRepos {
		out, err := Gh("pr", "list", "-R", ghOrg+"/"+repo, "--state", "open",
			"--json", "headRefName", "--jq", "[.[].headRefName]")
		var heads []string
		if err != nil || json.Unmarshal([]byte(strings.TrimSpace(out)), &heads) != nil {
			continue
		}
		if anyTrainBumpPR(heads) {
			v.inFlight = true
			break
		}
	}

	ciMark := ""
	if ci {
		ciMark = "(ci)"
	}
	flightMark := ""
	if v.inFlight {
		flightMark = " [列车进行中:主分支对账降级为告警]"
	}
	headf("══ PigeonBox 发布列车对账 train=%s state=%s %s%s", train, v.state, ciMark, flightMark)

	v.checkoutFreshness()
	v.section1Tags()
	v.section2Charts()
	v.section3HubPins()
	v.section4NAS()
	v.section5GoModPins()
	v.section6Terminals()
	v.section7VersionFiles()
	v.section8FrontendContracts()
	v.section8bContractsCopies()
	v.section8bFrontendVersionMeta()
	v.section9DocsMatrix()
	v.section9bReadmeVersionTable()
	v.section10HubLatest()
	v.section11TagAnchoring()

	headf("══ 结果: %d 处不一致, %d 处告警", v.fails, v.warns)
	if v.fails > 0 {
		fmt.Println("✗ 对账失败——以上 ✗ 项即为「版本不统一」清单")
		return 1
	}
	fmt.Println("✓ 对账通过")
	return 0
}

type verifier struct {
	env      *Env
	tf       *TrainFile
	ci       bool
	state    string
	inFlight bool
	fails    int
	warns    int
}

func (v *verifier) ok(format string, a ...any)   { okf(format, a...) }
func (v *verifier) warn(format string, a ...any) { warnf(format, a...) }
func (v *verifier) fail(format string, a ...any) { failf(format, a...); v.fails++ }
func (v *verifier) warnCount(format string, a ...any) {
	warnf(format, a...)
	v.warns++
}

// softFail 主分支对账项专用:列车进行中 → 告警(等 bump PR 合并),否则硬失败。
func (v *verifier) softFail(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if v.inFlight {
		v.warnCount("列车进行中·%s(等 bump PR 合并)", msg)
	} else {
		failf("%s", msg)
		v.fails++
	}
}

// tagchk draft 列车 tag 未打全属正常 → 缺 tag 只告警;tagged/shipped 缺 tag 即失败。
func (v *verifier) tagchk(repo, tag, desc string) {
	if v.env.TagExists(repo, tag) {
		v.ok("%s %s", desc, tag)
	} else if v.state == "draft" {
		v.warnCount("%s 缺 tag %s(draft 期)", desc, tag)
	} else {
		v.fail("%s 缺 tag %s", desc, tag)
	}
}

var rePin = regexp.MustCompile(`github\.com/pigeonbox/(\S+) v([^\s]+)`)

// pinchk 校验 go.mod 内容中 module 的钉版。
func (v *verifier) pinchk(gomod, module, want, desc string, soft bool) {
	wantNoV := strings.TrimPrefix(want, "v")
	found := ""
	for _, m := range rePin.FindAllStringSubmatch(gomod, -1) {
		if m[1] == module || strings.HasPrefix(m[1], module+"/") {
			found = m[2]
			break
		}
	}
	if found == wantNoV {
		v.ok("%s = %s", desc, want)
		return
	}
	if soft && v.inFlight {
		v.warnCount("列车进行中·%s 期望 %s", desc, want)
		return
	}
	v.fail("%s 期望 %s(实得 %s)", desc, want, orNone(found))
}

func orNone(s string) string {
	if s == "" {
		return "无"
	}
	return s
}

// checkoutFreshness 检出新鲜度守卫(版本幽灵根治):verify 读本地检出,落后即误报。
// 只 fetch 不动工作区。
func (v *verifier) checkoutFreshness() {
	for _, d := range []string{"frontend", "fnos", "openwrt", "qnap", "synology", "ugreen", "terramaster", "p2p", "contracts", "core", "kit", "desktop", "charts"} {
		dir, ok := v.env.RepoDir(d)
		if !ok {
			continue
		}
		_, _ = Git(dir, "fetch", "-q", "--tags", "origin")
		br, err := Git(dir, "rev-parse", "--abbrev-ref", "HEAD")
		if err != nil || br == "?" || br == "HEAD" {
			continue
		}
		out, err := Git(dir, "rev-list", "--count", "HEAD..origin/"+br)
		if err != nil {
			continue
		}
		n, _ := strconv.Atoi(strings.TrimSpace(out))
		if n > 0 {
			v.warnCount("%s 本地检出落后 origin/%s %d 提交——校验读本地,结果可能误报(先 git -C %s pull --ff-only)", d, br, n, d)
		}
	}
}

func (v *verifier) section1Tags() {
	headf("── 1. 库线/服务线 tag")
	v.tagchk("contracts", v.tf.Get("lib.contracts"), "contracts")
	v.tagchk("core", v.tf.Get("lib.core"), "core")
	// kit 已 deprecated 并入 oekit 矩阵(2026-10-16):台账摘除 lib.kit 即整体
	// 跳过 kit 对账(消费方零引用后,kit 无 tag 是终态而非缺失)
	if kitLedger := v.tf.Get("lib.kit"); kitLedger != "" {
		v.tagchk("kit", kitLedger, "kit")
	} else {
		v.ok("kit 已退役,台账无条目——跳过对账")
	}
	v.tagchk("p2p", v.tf.Get("lib.p2p"), "p2p")
	v.tagchk("frontend-core", v.tf.Get("lib.frontend-core"), "frontend-core")
	v.tagchk("server", "v"+v.tf.Get("images.server"), "server")
	if fe := v.tf.Get("frontend.tag"); fe != "" {
		v.tagchk("frontend", fe, "frontend")
	} else {
		v.warnCount("frontend 未打 tag(四处构建拉 main,不可复现;下一列车与 server 同号)")
	}
}

func (v *verifier) section2Charts() {
	headf("── 2. charts 对齐")
	cyaml, err := v.env.Raw("charts/main/charts/pigeonbox/Chart.yaml")
	if err != nil {
		v.fail("charts Chart.yaml 拉取失败")
		cyaml = ""
	}
	wantChart := v.tf.Get("charts.chart")
	wantApp := v.tf.Get("charts.app")
	gotChart := yamlTopKey(cyaml, "version:")
	gotApp := yamlTopKey(cyaml, "appVersion:")
	// charts 的提交被**显式推迟**到 advance（镜像在位后才直提 Chart.yaml，
	// 否则 chart 发版会指向还不存在的镜像 ⇒ install 即 ImagePullBackOff）。
	// ⇒ tagged 态 charts **必然**还是上一车（2026-10-24 实录：3.3.24 的 tagged
	// 态 verify 报「chart version ≠ 2.0.72(实得 2.0.71)」假失败一次）⇒
	// 与「hub Latest」同一口径：**只有 shipped 态才强校验**，其余态告警。
	switch chartAlignVerdict(v.state, gotChart, wantChart) {
	case verdictOK:
		v.ok("chart version = %s", wantChart)
	case verdictFail:
		v.fail("chart version ≠ %s(实得 %s)", wantChart, orNone(gotChart))
	default:
		v.warnCount("chart version ≠ %s(%s 期,等镜像就位后 charts 落地;实得 %s)", wantChart, v.state, orNone(gotChart))
	}
	switch chartAlignVerdict(v.state, gotApp, wantApp) {
	case verdictOK:
		v.ok("chart appVersion = %s", wantApp)
	case verdictFail:
		v.fail("chart appVersion ≠ %s(实得 %s)", wantApp, orNone(gotApp))
	default:
		v.warnCount("chart appVersion ≠ %s(%s 期,等镜像就位后 charts 落地;实得 %s)", wantApp, v.state, orNone(gotApp))
	}
	if wantApp == "v"+v.tf.Get("images.server") {
		v.ok("appVersion 锁 server 镜像(%s)", wantApp)
	} else {
		v.fail("chart appVersion(%s) ≠ v%s", wantApp, v.tf.Get("images.server"))
	}
}

// yamlTopKey 取首个以 prefix 开头的顶层行的值(去引号)。
func yamlTopKey(content, prefix string) string {
	for _, ln := range splitLines(content) {
		if strings.HasPrefix(ln, prefix) {
			return strings.Trim(strings.TrimSpace(strings.TrimPrefix(ln, prefix)), `"`)
		}
	}
	return ""
}

func (v *verifier) section3HubPins() {
	headf("── 3. hub 分发面钉版")
	pin := v.tf.Get("images.server") // ghcr 镜像 tag 无 v 前缀(v-tag 恒 404)
	compose, err1 := os.ReadFile(v.env.Root + "/deploy/nas/compose.yml")
	envx, err2 := os.ReadFile(v.env.Root + "/deploy/nas/env.example")
	if err1 == nil && err2 == nil &&
		strings.Contains(string(compose), "PB_IMAGE_TAG:-"+pin) &&
		strings.Contains(string(envx), "PB_IMAGE_TAG="+pin) {
		v.ok("deploy/nas 模板钉版 = %s", pin)
	} else {
		v.fail("deploy/nas 模板钉版 ≠ %s", pin)
	}
	kust, err := os.ReadFile(v.env.Root + "/deploy/k8s/overlays/prod/kustomization.yaml")
	if err == nil && strings.Contains(string(kust), "newTag: "+pin) {
		v.ok("k8s prod overlay newTag = %s", pin)
	} else {
		v.fail("k8s prod overlay newTag ≠ %s", pin)
	}
	gowork, err := os.ReadFile(v.env.Root + "/go.work")
	if err == nil && regexp.MustCompile(`(?m)^replace `).Match(gowork) {
		v.fail("go.work 仍存在版本化 replace(应纯 use 映射)")
	} else {
		v.ok("go.work 纯 use 映射")
	}
}

func (v *verifier) section4NAS() {
	headf("── 4. NAS 打包三仓物化(qnap 已切原生走第 6/7 节)")
	pin := v.tf.Get("images.server")
	if !v.ci {
		// 本地:直接跑 hub 的 sync.sh check --all(单一实现)
		out, err := shellCombined(v.env.Root, "bash", "deploy/nas/sync.sh", "check", "--all")
		if err != nil {
			v.fail("NAS 四仓与 hub 模板漂移(跑 make nas-sync)")
			for _, ln := range splitLines(out) {
				fmt.Printf("      %s\n", ln)
			}
			return
		}
		v.ok("sync.sh check --all 一致")
		return
	}
	// ⚠️ CI 分支**只查镜像钉版计数**（不查逐字漂移），这是刻意保持「轻」：
	//   本分支在 bump PR 阶段就跑，那时物化还没合进 main ⇒ 读 main 必然是
	//   上一车内容（见下面 inFlight 降级）。
	//   逐字漂移另有两处覆盖：① NAS 三仓各自 CI 的「共享资产与 hub 模板对齐」
	//   （sync.sh **单仓模式** --dir）；② advance 终验的 ci=false 分支
	//   （sync.sh **check --all**，见 advance.go 的注释）。
	cpath := map[string]string{"synology": "spk/package/compose.yml", "qnap": "qpkg/shared/compose.yml"}
	for _, p := range platforms {
		cp := cpath[p]
		if cp == "" {
			cp = "deploy/compose.yml"
		}
		content, err := v.env.Raw(p + "/main/" + cp)
		n := strings.Count(content, "PB_IMAGE_TAG:-"+pin)
		if err == nil && n == 2 {
			v.ok("%s compose 钉版 = %s", p, pin)
		} else if v.inFlight {
			// CI 从 main 读物化产物,bump PR 未合并时必然旧值——主分支对账项降级
			// (v1 此处恒 fail,bump PR 的 train-verify 一直红着无人管;v2 advance
			// 以 checks 绿合并 PR,必须修,否则列车卡死)
			v.warnCount("列车进行中·%s compose 钉版漂移(期望 %s×2,实得 %d;等 bump PR 合并)", p, pin, n)
		} else {
			v.fail("%s compose 钉版漂移(期望 %s×2,实得 %d)", p, pin, n)
		}
	}
}

func (v *verifier) section5GoModPins() {
	headf("── 5. go.mod 钉版(main)")
	check := func(repo, ref string, pins [][2]string) {
		gm, err := v.env.Raw(repo + "/" + ref + "/go.mod")
		if err != nil || gm == "" {
			v.warnCount("%s go.mod 拉取失败", repo)
			return
		}
		for _, p := range pins {
			v.pinchk(gm, p[0], p[1], repo+"→"+p[0], true)
		}
	}
	check("server", "main", [][2]string{
		{"core", v.tf.Get("lib.core")},
		{"contracts", v.tf.Get("lib.contracts")},
		{"kit", v.tf.Get("lib.kit")},
	})
	check("core", "main", [][2]string{
		{"contracts", v.tf.Get("lib.contracts")},
		{"kit", v.tf.Get("lib.kit")},
	})
	check("p2p", "main", [][2]string{{"kit", v.tf.Get("lib.kit")}})
}

func (v *verifier) section6Terminals() {
	headf("── 6. 终端仓钉版与双写面")
	kit := v.tf.Get("lib.kit")
	for _, t := range []string{"fnos", "openwrt", "qnap"} {
		corePin := v.tf.Get("terminal." + t + ".core_pin")
		tag := v.tf.Get("terminal." + t + ".tag")
		br := defBranch(t)
		v.tagchk(t, tag, t)
		if gm, err := v.env.Raw(t + "/" + br + "/go.mod"); err == nil && gm != "" {
			v.pinchk(gm, "core", corePin, t+"→core", true)
			v.pinchk(gm, "kit", kit, t+"→kit", true)
		} else {
			v.warnCount("%s go.mod 拉取失败", t)
		}
		// 悬空钉版守卫(fnos v1.2.7 教训):tag 上的 go.mod 也必须钉对
		if v.env.TagExists(t, tag) {
			if gm, err := v.env.Raw(t + "/" + tag + "/go.mod"); err == nil && gm != "" {
				v.pinchk(gm, "core", corePin, t+"@tag→core(fnos v1.2.7 悬空钉版守卫)", false)
			} else {
				v.warnCount("%s tag 上 go.mod 拉取失败", t)
			}
		}
	}
	// fnos manifest / openwrt tag(v1 第 6 节余项)
	fv := v.tf.Get("terminal.fnos.version")
	if mani, err := v.env.Raw("fnos/master/fnos/manifest"); err == nil && manifestVersion(mani) == fv {
		v.ok("fnos manifest = %s", fv)
	} else {
		v.softFail("fnos manifest ≠ %s", fv)
	}
	ov := v.tf.Get("terminal.openwrt.version")
	if v.env.TagExists("openwrt", "v"+ov) {
		v.ok("openwrt tag v%s", ov)
	} else if v.state == "draft" {
		v.warnCount("openwrt tag v%s 缺", ov)
	} else {
		v.fail("openwrt tag v%s 缺", ov)
	}

	dv := v.tf.Get("terminal.desktop.version")
	v.tagchk("desktop", v.tf.Get("terminal.desktop.tag"), "desktop")
	if dt, err := v.env.Raw("desktop/main/src-tauri/tauri.conf.json"); err == nil && dt != "" {
		if strings.Contains(dt, `"version": "`+dv+`"`) {
			v.ok("desktop tauri.conf.json = %s", dv)
		} else {
			v.softFail("desktop tauri.conf.json ≠ %s", dv)
		}
	} else {
		v.warnCount("desktop tauri.conf.json 拉取失败")
	}
	// desktop sidecar 的 p2pc 钉版校验（2026-10-22 Wave B' 随 sidecar 退役一并移除：
	// 桌面端不再随包 p2pc 直传 sidecar，直传改由独立应用 PigeonBeam 提供；
	// 桌面端只做 Box 纯客户端。desktop 侧的 p2pc 完整性校验责任随之移交 p2p 仓的
	// 自身发布链（那里才有 checksums 清单）。
	// 锁文件版本必须与列车同号：只写 Cargo.toml 会让 Cargo.lock 永远停在
	// 上一趟(实测 desktop-v2.2.0 的锁文件仍写 2.0.5)——`cargo build --locked`
	// 直接失败。
	if lock, err := v.env.Raw("desktop/main/src-tauri/Cargo.lock"); err == nil && lock != "" {
		if strings.Contains(lock, `name = "pigeonbox-desktop"`+"\nversion = \""+dv+"\"") {
			v.ok("desktop Cargo.lock 版本 = %s", dv)
		} else {
			v.softFail("desktop Cargo.lock 版本 ≠ %s(--locked 构建会失败)", dv)
		}
	} else {
		v.warnCount("desktop Cargo.lock 拉取失败")
	}
}

func manifestVersion(content string) string {
	for _, ln := range splitLines(content) {
		if strings.HasPrefix(ln, "version=") {
			return strings.TrimPrefix(ln, "version=")
		}
	}
	return ""
}

func (v *verifier) section7VersionFiles() {
	headf("── 7. 终端 VERSION/DEPS.env(灰度开关)")
	if v.tf.Get("features.version_files") != "true" {
		v.warnCount("features.version_files=false:各仓 VERSION/DEPS.env 尚未启用(首次列车 bump 自动开启)")
		return
	}
	for _, t := range []string{"fnos", "openwrt", "desktop", "synology", "qnap", "ugreen", "terramaster"} {
		want := v.tf.Get("terminal." + t + ".version")
		got, err := v.env.Raw(t + "/" + defBranch(t) + "/VERSION")
		if err == nil && strings.TrimSpace(got) == want {
			v.ok("%s VERSION = %s", t, want)
		} else {
			v.softFail("%s VERSION ≠ %s(发版走 train bump,勿手改)", t, want)
		}
	}
	for _, t := range []string{"fnos", "openwrt", "qnap"} {
		de, err := v.env.Raw(t + "/" + defBranch(t) + "/DEPS.env")
		if err != nil {
			de = ""
		}
		if depsValue(de, "CORE_PIN") == v.tf.Get("terminal."+t+".core_pin") {
			v.ok("%s DEPS CORE_PIN", t)
		} else {
			v.softFail("%s DEPS CORE_PIN ≠ train.yaml", t)
		}
	}
	// fnos/qnap/openwrt web 自包含,钉版=frontend-core tgz
	fcore := v.tf.Get("lib.frontend-core")
	for _, t := range []string{"fnos", "qnap", "openwrt"} {
		de, err := v.env.Raw(t + "/" + defBranch(t) + "/DEPS.env")
		if err != nil {
			de = ""
		}
		if depsValue(de, "FRONTEND_CORE_PIN") == fcore {
			v.ok("%s DEPS FRONTEND_CORE_PIN = %s", t, fcore)
		} else {
			v.softFail("%s DEPS FRONTEND_CORE_PIN ≠ %s", t, fcore)
		}
	}
	// p2pc 终端钉版(Phase 2② 2026-10-16):**NAS 三端** DEPS.env P2PC_REF =
	// terminal.p2pc_ref(随带 p2pc 独立钉版,缺省冻结不随列车,仅显式
	// --set p2pc_ref 才动;旧 yaml 无此键回退 lib.p2p 保兼容)。
	// 2026-10-22 Wave B':server 镜像不再随包 p2pc(.p2pc-version 钉版点退休)、
	// desktop 不再随包 sidecar(terminal.desktop.p2pc 键退休)——两处校验同步移除。
	p2pcPin := v.tf.Get("terminal.p2pc_ref")
	if p2pcPin == "" {
		p2pcPin = v.tf.Get("lib.p2p")
	}
	for _, t := range []string{"fnos", "openwrt", "qnap"} {
		de, err := v.env.Raw(t + "/" + defBranch(t) + "/DEPS.env")
		if err != nil {
			de = ""
		}
		if depsValue(de, "P2PC_REF") == p2pcPin {
			v.ok("%s DEPS P2PC_REF = %s", t, p2pcPin)
		} else {
			v.softFail("%s DEPS P2PC_REF ≠ %s(terminal.p2pc_ref)", t, p2pcPin)
		}
	}
}

func depsValue(content, key string) string {
	for _, ln := range splitLines(content) {
		if strings.HasPrefix(ln, key+"=") {
			return strings.TrimSpace(strings.TrimPrefix(ln, key+"="))
		}
	}
	return ""
}

// anyTrainBumpPR 判定：一批 open PR 的 head 分支里，是否存在**列车 bump PR**。
//
// 判据只看 `train/` 前缀，**不绑定具体车次**——因为在途窗口里
// train.yaml 可能还停在**上一趟车**（hub 的 bump PR 未合），
// 而组件仓的 bump PR 已是**下一趟**（train/4.6.5）⇒
// 只认 `train/<train.yaml 的车次>` 会**一个都找不到** ⇒ 漏判在途 ⇒
// 拿旧车次比新车次 ⇒ 报一堆**假漂移** ⇒ 无关 PR 被红
// （2026-10-31 实测：pigeonbox#224 被 Train Verify 判红，
//
//	期望 4.6.4 / 实得 4.6.5 —— 那时 hub 的 train/4.6.5 bump PR 还开着）。
func anyTrainBumpPR(heads []string) bool {
	for _, h := range heads {
		if strings.HasPrefix(strings.TrimSpace(h), "train/") {
			return true
		}
	}
	return false
}

// inFlightRepos 列车在途探测的仓表：任一仓存在未合并的 train/<TRAIN> bump PR
// 即视为"列车进行中"，主分支对账项降级告警。
//
// server 必须在列——它同样有 bump PR（advance.go 的 bumpPRRepos）。漏列会让
// server 的 bump 未合并时 verify 硬红（在途态被当终态），与 1.24.0/1.24.1
// 那次"列表漏项"事故同型，只是方向相反：那次是失明（该查的没查），这次是
// 假红（不该红的红了）。两表必须一致，由 test 钉住。
var inFlightRepos = []string{
	"pigeonbox", "frontend", "server", "fnos", "openwrt",
	"desktop", "synology", "qnap", "ugreen", "terramaster",
}

func (v *verifier) section8FrontendContracts() {
	headf("── 8. 前端双仓契约消费(core 拆分后: contracts→core→壳)")
	fcore := v.tf.Get("lib.frontend-core")
	contracts := v.tf.Get("lib.contracts")
	serverV := v.tf.Get("images.server")
	tgzCore := "pigeonbox-frontend-core-" + strings.TrimPrefix(fcore, "v") + ".tgz"
	tgzContracts := "pigeonbox-contracts-" + strings.TrimPrefix(contracts, "v") + ".tgz"

	// frontend-core 的 contracts 钉版：同样量**tag**（消费方拿到的就是它）
	if pj, err := v.env.Raw("frontend-core/" + fcore + "/package.json"); err == nil && pj != "" {
		if strings.Contains(pj, tgzContracts) {
			v.ok("frontend-core contracts tgz = %s（tag %s）", contracts, fcore)
		} else {
			// 读 tag=已发布内容:列车进行中(in-flight)降级告警
			v.softFail("frontend-core contracts tgz ≠ %s（tag %s）", contracts, fcore)
		}
	} else {
		v.warnCount("frontend-core package.json 拉取失败")
	}
	if pj, err := v.env.Raw("frontend/main/package.json"); err == nil && pj != "" {
		if strings.Contains(pj, tgzCore) {
			v.ok("frontend(壳) frontend-core tgz = %s", fcore)
		} else {
			v.softFail("frontend(壳) frontend-core tgz ≠ %s", fcore)
		}
		// 同上：仅当声明了 @pigeonbox/contracts 才查
		if strings.Contains(pj, "@pigeonbox/contracts") {
			if strings.Contains(pj, tgzContracts) {
				v.ok("frontend(壳) contracts tgz = %s", contracts)
			} else {
				v.softFail("frontend(壳) contracts tgz ≠ %s", contracts)
			}
		}
	} else {
		v.warnCount("frontend package.json 拉取失败")
	}
	// frontend-core 自身的版本元数据必须与 lib.frontend-core 一致——三处版本源
	// (VERSION / package.json / tag)此前互相打架(0.3.0 / 0.7.3 / v0.8.1)，
	// 而列车既不写它们也不查它们，漂移无人发现。
	//
	// ⚠️ 量**钉版的 tag**，不是 main（2026-10-23 修）：库线 main 的版本元数据会
	// **先于发版**被抬高（「chore: 版本 X → Y（发布 vY 的前置）」是既定流程，
	// tag 随后才打）⇒ 读 main 时，任何「别的库线发版在制品」都会让**与它无关
	// 的车**判红。实测：3.3.6 钉 v0.11.9（已发布、含修复），而 main 已被下一版
	// 0.11.10 抬高 ⇒ 假红，且车永远进不了 shipped（还挡住下一趟车开）。
	// 消费方拿到的是 **tag 的内容**（tgz 从 tag 构建）⇒ 对账必须量 tag。
	fcoreNoV := strings.TrimPrefix(fcore, "v")
	if vf, err := v.env.Raw("frontend-core/" + fcore + "/VERSION"); err == nil && strings.TrimSpace(vf) == fcoreNoV {
		v.ok("frontend-core VERSION = %s（tag %s）", fcoreNoV, fcore)
	} else {
		v.softFail("frontend-core VERSION ≠ %s（tag %s）", fcoreNoV, fcore)
	}
	if pj, err := v.env.Raw("frontend-core/" + fcore + "/package.json"); err == nil && pj != "" {
		if strings.Contains(pj, `"version": "`+fcoreNoV+`"`) {
			v.ok("frontend-core package.json 版本 = %s（tag %s）", fcoreNoV, fcore)
		} else {
			v.softFail("frontend-core package.json 版本 ≠ %s（tag %s）", fcoreNoV, fcore)
		}
	}
	// 平台仓 web/:tgz 钉版 + 包体版本=前端列车号(页脚「前端版本」)
	for _, t := range []string{"fnos", "qnap", "openwrt"} {
		pj, err := v.env.Raw(t + "/" + defBranch(t) + "/web/package.json")
		if err != nil || pj == "" {
			v.warnCount("%s/web package.json 拉取失败", t)
			continue
		}
		if strings.Contains(pj, tgzCore) {
			v.ok("%s/web frontend-core tgz = %s", t, fcore)
		} else {
			v.softFail("%s/web frontend-core tgz ≠ %s", t, fcore)
		}
		// contracts tgz 同样要钉在列车号上(此前只查 frontend-core 那条，
		// 消费方的 contracts 钉版常年停在旧版且不可见)。
		// 仅当该 manifest 确实声明了 @pigeonbox/contracts 才查——有的平台
		// web/ 只消费 frontend-core tgz（类型随其传递），不直接依赖 contracts，
		// 对这类仓查 contracts tgz 是假阳性。
		if strings.Contains(pj, "@pigeonbox/contracts") {
			if strings.Contains(pj, tgzContracts) {
				v.ok("%s/web contracts tgz = %s", t, contracts)
			} else {
				v.softFail("%s/web contracts tgz ≠ %s", t, contracts)
			}
		}
		if strings.Contains(pj, `"version": "`+serverV+`"`) {
			v.ok("%s/web 版本 = %s(前端列车号)", t, serverV)
		} else {
			v.softFail("%s/web 版本 ≠ %s(页脚「前端版本」应随列车)", t, serverV)
		}
	}
}

// section8bContractsCopies 校验「消费仓的 node_modules 里只有一份 @pigeonbox/contracts」。
//
// 2026-10-25 实录（3.3.28 终验）：frontend-core v0.11.21 的 package.json 仍钉
// contracts v0.18.6，而壳钉 v0.18.7 ⇒ 壳仓装出来是**两份** contracts：
//
//	node_modules/@pigeonbox/contracts                              → 0.18.7（壳的钉版）
//	node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts → 0.18.6
//
// npm 不去重不同版本 ⇒ frontend-core 源码的 `import type` 从 nested 那份解析，
// 壳里存在**两份类型定义**。本次 contracts 的 TS 载荷逐字节相同，所以 typecheck
// 绿、页面正常——但下次 contracts 改 TS 载荷就会真炸（壳里两份类型不兼容）。
// 「没炸」不等于「对」，而根因（库线钉版滞后）只能靠机械守卫常态化拦截。
//
// 判据取 **lock 的 packages 安装路径**，不用文本计数：嵌套副本的键是
// `node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts`，
// 与根副本的键前缀不同，文本子串计数极易漏判（漏判=守卫形同虚设）。
func (v *verifier) section8bContractsCopies() {
	headf("── 8b. 消费仓 @pigeonbox/contracts 副本唯一性")
	for _, t := range []struct{ repo, path string }{
		{"frontend", "package-lock.json"},
		{"fnos", "web/package-lock.json"},
		{"qnap", "web/package-lock.json"},
		{"openwrt", "web/package-lock.json"},
	} {
		raw, err := v.env.Raw(t.repo + "/" + defBranch(t.repo) + "/" + t.path)
		if err != nil || raw == "" {
			// 拉取失败=网络/瞬时问题 ⇒ 告警（不硬失败，别让列车的死结卡在网络抖动上）
			v.warnCount("%s %s 拉取失败", t.repo, t.path)
			continue
		}
		n, err := countContractsCopies(raw)
		if err != nil {
			// 解析口径坏了 ⇒ **硬失败**（守卫自身失灵时不能沉默：那正是「假绿」的温床）
			v.fail("%s %s 解析失败(%v)——无法确认 contracts 副本数", t.repo, t.path, err)
			continue
		}
		if n == 1 {
			v.ok("%s %s: @pigeonbox/contracts 恰好 1 份", t.repo, t.path)
		} else {
			v.softFail("%s %s: @pigeonbox/contracts 有 %d 份(应恰好 1 份)——库线钉版与消费方不一致", t.repo, t.path, n)
		}
	}
}

// countContractsCopies 数 lock 文件里 @pigeonbox/contracts 的安装副本数。
// 只认「安装路径」键（以 node_modules/@pigeonbox/contracts 结尾），
// 不把 dependencies 段的声明当成副本（那是同一个包的引用，不是第二份实体）。
func countContractsCopies(lockJSON string) (int, error) {
	var lk struct {
		Packages map[string]json.RawMessage `json:"packages"`
	}
	if err := json.Unmarshal([]byte(lockJSON), &lk); err != nil {
		return 0, err
	}
	if lk.Packages == nil {
		return 0, errors.New("lock 无 packages 段(格式变了或内容不是 lock)")
	}
	n := 0
	for k := range lk.Packages {
		if k == "node_modules/@pigeonbox/contracts" ||
			strings.HasSuffix(k, "/node_modules/@pigeonbox/contracts") {
			n++
		}
	}
	return n, nil
}

// section8bFrontendVersionMeta 校验壳仓（frontend）的**两处版本元数据**一致，
// 且与列车号同号：package.json 的 version（npm 包版本）＋ VERSION 标记文件。
//
// 2026-10-25 实录（列车 3.3.31）：重跑 bump 时 trainctl 的「写回快照」用 main 的旧
// 内容盖掉了分支上**已抬**的版本 ⇒ package.json 停在 3.3.30 而 VERSION 已是 3.3.31
// ⇒ 两处分叉 ⇒ server 构建的「frontend 源码版本与 tag 同号」硬门拦下（那一车作废）。
//
// ⇒ 这里把「两处一致 + 与列车号同号」变成**对账项**：分叉在列车收尾前就被发现，
// 而不是等到镜像构建失败才知。
func (v *verifier) section8bFrontendVersionMeta() {
	headf("── 8b. 壳仓(frontend)版本元数据一致性")
	train := v.tf.Get("train")
	pj, err := v.env.Raw("frontend/main/package.json")
	if err != nil || strings.TrimSpace(pj) == "" {
		v.warnCount("frontend package.json 拉取失败")
		return
	}
	vf, err := v.env.Raw("frontend/main/VERSION")
	if err != nil || strings.TrimSpace(vf) == "" {
		v.warnCount("frontend VERSION 拉取失败")
		return
	}
	pkgVer := firstJSONVersion(pj)
	fileVer := strings.TrimSpace(vf)
	if pkgVer == "" {
		v.softFail("frontend package.json 里读不到 version 字段")
		return
	}
	if pkgVer == fileVer {
		v.ok("frontend 版本元数据一致(%s)", pkgVer)
	} else {
		v.softFail("frontend 版本元数据分叉(package.json=%s / VERSION=%s)", pkgVer, fileVer)
	}
	if train != "" && fileVer != "" && fileVer != train {
		v.softFail("frontend VERSION(%s)与列车号(%s)不同号", fileVer, train)
	}
}

// reJSONVersionValue 取 JSON 里第一个 "version" 字段的**值**（带捕获组）。
var reJSONVersionValue = regexp.MustCompile(`"version"\s*:\s*"([^"]*)"`)

// firstJSONVersion 取 JSON 里**第一个** "version" 字段的值（找不到返回空串）。
func firstJSONVersion(content string) string {
	m := reJSONVersionValue.FindStringSubmatch(content)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

func (v *verifier) section9DocsMatrix() {
	headf("── 9. 文档版本矩阵(hub docs/architecture.md)")
	arch, err := os.ReadFile(v.env.Root + "/docs/architecture.md")
	if err != nil {
		v.fail("docs/architecture.md 读取失败")
		return
	}
	rows := [][2]string{
		{"contracts", v.tf.Get("lib.contracts")},
		{"core", v.tf.Get("lib.core")},
		{"frontend-core", v.tf.Get("lib.frontend-core")},
		{"server", "v" + v.tf.Get("images.server")},
		{"frontend", v.tf.Get("frontend.tag")},
		{"fnos", v.tf.Get("terminal.fnos.version")},
		{"openwrt", v.tf.Get("terminal.openwrt.version")},
		{"qnap", v.tf.Get("terminal.qnap.version")},
		{"p2p", v.tf.Get("lib.p2p")},
		{"kit", v.tf.Get("lib.kit")},
		{"desktop", v.tf.Get("terminal.desktop.tag")},
	}
	content := string(arch)
	for _, r := range rows {
		if r[1] == "" {
			// 归档库线(kit)在 train.yaml 留空:无版本可对,跳过而非误报滞后
			continue
		}
		re := regexp.MustCompile(`(?m)^\| ` + regexp.QuoteMeta(r[0]) + ` \|.*$`)
		m := re.FindString(content)
		if m != "" && strings.Contains(m, r[1]) {
			v.ok("architecture.md %s 含 %s", r[0], r[1])
		} else {
			v.softFail("architecture.md %s 版本滞后(期望含 %s)", r[0], r[1])
		}
	}
}

// section9bReadmeVersionTable README 版本表必须与 train.yaml 一致。
//
// 背景（2026-10-23 文档审计）：hub README 的版本表长期落后（实测落后两列车），
// 而且**没人拦** —— 列车只做版本对账、不看文档 ⇒ 每发一车就再漂一次。
// 本节把 README 版本表纳入门禁：表里每个仓的版本必须等于 train.yaml 的声明。
//
// 例外：版本列不是具体版本号的行（如 frontend 的「随 server 同 v*」）不查。
func (v *verifier) section9bReadmeVersionTable() {
	headf("── 9b. README 版本表与 train.yaml 一致")
	readme, err := os.ReadFile(v.env.Root + "/README.md")
	if err != nil {
		v.fail("README.md 读取失败: %v", err)
		return
	}
	expect := []struct{ name, version string }{
		{"contracts", v.tf.Get("lib.contracts")},
		{"core", v.tf.Get("lib.core")},
		{"frontend-core", v.tf.Get("lib.frontend-core")},
		{"p2p", v.tf.Get("lib.p2p")},
		{"server", "v" + v.tf.Get("images.server")},
		{"desktop", v.tf.Get("terminal.desktop.tag")},
		{"fnos", v.tf.Get("terminal.fnos.tag")},
		{"openwrt", v.tf.Get("terminal.openwrt.tag")},
		{"qnap", v.tf.Get("terminal.qnap.tag")},
		{"synology", v.tf.Get("terminal.synology.tag")},
		{"ugreen", v.tf.Get("terminal.ugreen.tag")},
		{"terramaster", v.tf.Get("terminal.terramaster.tag")},
		{"charts", "pigeonbox-" + v.tf.Get("charts.chart")},
	}
	for _, e := range expect {
		if e.version == "" {
			continue
		}
		line, ok := findReadmeRow(string(readme), e.name)
		if !ok {
			v.fail("README.md 缺 %s 的表格行", e.name)
			continue
		}
		if !strings.Contains(line, e.version) {
			v.fail("README.md %s 版本 ≠ %s（行：%s）", e.name, e.version, strings.TrimSpace(line))
		} else {
			v.ok("README.md %s = %s", e.name, e.version)
		}
	}
}

// findReadmeRow 在 README 表格里定位某个仓所在的行（按 "| [name](" 匹配）。
func findReadmeRow(readme, name string) (string, bool) {
	for _, line := range strings.Split(readme, "\n") {
		if strings.Contains(line, "| ["+name+"](") {
			return line, true
		}
	}
	return "", false
}

func (v *verifier) section10HubLatest() {
	headf("── 10. hub Latest(仅 shipped 态强校验)")
	if !isShippedPhase(v.state) {
		v.ok("state=%s,跳过 Latest 校验（hub 的 v%s Release 由 finalize 推 tag 后触发 release.yml 才创建）",
			v.state, v.tf.Get("train"))
		return
	}
	want := "v" + v.tf.Get("train")
	latest := v.hubLatestWithRetry(want)
	if latest == want {
		v.ok("hub Latest = %s", want)
	} else {
		v.fail("hub Latest(%s) ≠ %s", orNone(latest), want)
	}
}

// 对齐检查的三态结论。
const (
	verdictOK   = "ok"
	verdictWarn = "warn"
	verdictFail = "fail"
)

// chartAlignVerdict 判定 charts 字段对齐在某 state 下的结论。
//
// 与「hub Latest」同一口径：跨仓产物只在 shipped 态强校验（charts 的提交被
// 显式推迟到镜像就位之后 ⇒ tagged 态必然还是上一车）；其余态告警。
//
// 抽成纯函数 ⇒ 可单测、负对照可实测（内联在 handler 里就没法证明「改回旧写法
// 会变红」）。
func chartAlignVerdict(state, got, want string) string {
	switch {
	case got == want:
		return verdictOK
	case isShippedPhase(state):
		return verdictFail
	default:
		return verdictWarn
	}
}

// isShippedPhase 判定「是否处于最终态（该强校验跨仓产物了）」。
//
// 列车状态机里，**下游产物不是与 state 同时到位的**，因此「非 shipped 态就强
// 校验」= 必然假失败（2026-10-24 实录，3.3.24 列车 tagged/shipped 两阶段各假红
// 一次）：
//
//   - **hub Latest**：v<train> Release 是 finalize 推 tag **之后**才由 release.yml
//     创建的（finalize 先提交 state=shipped ⇒ 那个 push 就触发了本工作流 ⇒
//     校验跑在 Release 建好之前，实测约 40 秒的窗口）；
//   - **charts**：Chart.yaml 的提交被**显式推迟**到 advance（镜像在位后才直提，
//     否则 chart 发版会指向还不存在的镜像 ⇒ install 即 ImagePullBackOff）
//     ⇒ tagged 态 charts **必然**还是上一车。
//
// ⇒ 跨仓产物只在 **shipped 态**强校验；其余态一律告警（draft/tagged/shipping）。
// 组件 tag 不在此列：tag 阶段是**先推全部组件 tag、再提交 state=tagged**
// ⇒ tagged 态 tag 必然已存在，严格校验是安全的。
func isShippedPhase(state string) bool {
	return state == "shipped"
}

// hubLatestWithRetry 取 hub 的 Latest release，**有界重试**。
//
// finalize 的时序（2026-10-24 实录）：先提交 state=shipped（**这个 push 触发
// 本工作流**）⇒ **之后**才推 hub tag ⇒ tag 才触发 release.yml 建 Release 并标
// Latest ⇒ 校验跑在 tag 推之前时 Latest 必然还是上一车（实测 release.yml 建
// Release 约需 40 秒）。
//
// ⇒ 给一个有界重试窗口：窗口内 Latest 到位即通过；窗口耗尽仍不符 ⇒ 真不一致
// （真的漏推 tag / Release 建失败）⇒ 照常判红（不削弱门禁）。
//
// 本地跑（make train-verify）用短窗口（快速反馈），CI 用长窗口（覆盖
// release.yml 的建 Release 时长）。可用环境变量覆盖。
func (v *verifier) hubLatestWithRetry(want string) string {
	attempts, interval := 6, 20*time.Second // CI 默认：6×20s = 2 分钟
	if !v.ci {
		attempts, interval = 3, 5*time.Second // 本地：3×5s = 15 秒
	}
	if s := os.Getenv("PB_LATEST_RETRY_ATTEMPTS"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			attempts = n
		}
	}
	if s := os.Getenv("PB_LATEST_RETRY_INTERVAL"); s != "" {
		if d, err := time.ParseDuration(s); err == nil && d > 0 {
			interval = d
		}
	}
	var latest string
	for i := 0; i < attempts; i++ {
		if out, err := Gh("api", "repos/"+hubRepo+"/releases/latest", "--jq", ".tag_name"); err == nil {
			latest = out
			if latest == want {
				return latest
			}
		}
		if i < attempts-1 {
			v.warn("hub Latest 暂为 %s（期望 %s）——release.yml 可能仍在建 Release，%s 后重试",
				orNone(latest), want, interval)
			time.Sleep(interval)
		}
	}
	return latest
}

func (v *verifier) section11TagAnchoring() {
	headf("── 11. tag 锚定主线(远端硬对账:tag 提交必须在默认分支上)")
	// 2026-10-12 实锤:手工重打 tag 落到孤儿提交(本地检出陈旧+push 静默失败)。
	specs := [][3]string{
		{"frontend", v.tf.Get("frontend.tag"), "main"},
		{"fnos", v.tf.Get("terminal.fnos.tag"), "master"},
		{"openwrt", v.tf.Get("terminal.openwrt.tag"), "main"},
		{"qnap", v.tf.Get("terminal.qnap.tag"), "main"},
		{"synology", v.tf.Get("terminal.synology.tag"), "main"},
		{"ugreen", v.tf.Get("terminal.ugreen.tag"), "main"},
		{"terramaster", v.tf.Get("terminal.terramaster.tag"), "main"},
		{"desktop", v.tf.Get("terminal.desktop.tag"), "main"},
		{"p2p", v.tf.Get("lib.p2p"), "main"},
		// server 的 tag 名取镜像号(images.server),不是列车号——两者只在
		// 「--set server=」应急口子下才不等;按列车号对账会在该口子上
		// 锚一个不存在的 tag(真 tag 反而不受锚定检查)。
		{"server", "v" + v.tf.Get("images.server"), "main"},
	}
	for _, s := range specs {
		repo, tag, br := s[0], s[1], s[2]
		dir, ok := v.env.RepoDir(repo)
		if !ok {
			continue
		}
		_, _ = Git(dir, "fetch", "-q", "--tags", "origin")
		tc, err := Git(dir, "rev-parse", "-q", "--verify", "refs/tags/"+tag+"^{commit}")
		if err != nil || tc == "" {
			v.warnCount("%s tag %s 缺失(draft 期容忍;shipped 态应存在)", repo, tag)
			continue
		}
		if GitOK(dir, "merge-base", "--is-ancestor", tc, "origin/"+br) {
			v.ok("%s tag %s 锚定 origin/%s", repo, tag, br)
		} else {
			v.fail("%s tag %s 不在 origin/%s 上(孤儿/错位 tag——删 tag 重打到主线提交)", repo, tag, br)
		}
	}
}
