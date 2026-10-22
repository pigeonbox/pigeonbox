package main

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
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

	// 列车进行中探测:任一仓存在未合并的 train/<TRAIN> bump PR → 主分支版本面
	// 必然落后于 train.yaml(中间态),主分支对账项降级告警;全合并后自动恢复严格。
	for _, repo := range inFlightRepos {
		out, err := Gh("pr", "list", "-R", ghOrg+"/"+repo, "--head", "train/"+train, "--state", "open", "--json", "number", "--jq", "length")
		if err == nil && strings.TrimSpace(out) != "0" && strings.TrimSpace(out) != "" {
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
	v.section9DocsMatrix()
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
	switch {
	case gotChart == wantChart:
		v.ok("chart version = %s", wantChart)
	case v.state == "draft":
		v.warnCount("chart version ≠ %s(draft 期,等 chart 仓落地)", wantChart)
	default:
		v.fail("chart version ≠ %s(实得 %s)", wantChart, orNone(gotChart))
	}
	switch {
	case gotApp == wantApp:
		v.ok("chart appVersion = %s", wantApp)
	case v.state == "draft":
		v.warnCount("chart appVersion ≠ %s(draft 期,等 chart 仓落地)", wantApp)
	default:
		v.fail("chart appVersion ≠ %s(实得 %s)", wantApp, orNone(gotApp))
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

	if pj, err := v.env.Raw("frontend-core/main/package.json"); err == nil && pj != "" {
		if strings.Contains(pj, tgzContracts) {
			v.ok("frontend-core contracts tgz = %s", contracts)
		} else {
			// 读 main=主分支滞后项:列车进行中(in-flight)降级告警
			v.softFail("frontend-core contracts tgz ≠ %s", contracts)
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
	fcoreNoV := strings.TrimPrefix(fcore, "v")
	if vf, err := v.env.Raw("frontend-core/main/VERSION"); err == nil && strings.TrimSpace(vf) == fcoreNoV {
		v.ok("frontend-core VERSION = %s", fcoreNoV)
	} else {
		v.softFail("frontend-core VERSION ≠ %s", fcoreNoV)
	}
	if pj, err := v.env.Raw("frontend-core/main/package.json"); err == nil && pj != "" {
		if strings.Contains(pj, `"version": "`+fcoreNoV+`"`) {
			v.ok("frontend-core package.json 版本 = %s", fcoreNoV)
		} else {
			v.softFail("frontend-core package.json 版本 ≠ %s", fcoreNoV)
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

func (v *verifier) section10HubLatest() {
	headf("── 10. hub Latest(仅 shipped 态强校验)")
	if v.state != "shipped" && v.state != "shipping" {
		v.ok("state=draft,跳过 Latest 校验")
		return
	}
	latest, err := Gh("api", "repos/"+hubRepo+"/releases/latest", "--jq", ".tag_name")
	if err != nil {
		latest = ""
	}
	want := "v" + v.tf.Get("train")
	if latest == want {
		v.ok("hub Latest = %s", want)
	} else {
		v.fail("hub Latest(%s) ≠ %s", orNone(latest), want)
	}
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
