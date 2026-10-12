package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// cmdBump 开新列车:结构化写 15+ 版本点 → 各仓 train/<v> 分支+PR → 自动合并。
// 与 v1 的关键差异:dry-run(缺省)纯内存计算计划、零落盘——v1 的
// 「dry-run 写工作树」曾直接导致 1.14.6 PR 漏建事故。
func cmdBump(env *Env, args []string) {
	var train string
	var hotfix, push bool
	sets := map[string]string{}
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case strings.HasPrefix(a, "TRAIN="):
			train = strings.TrimPrefix(a, "TRAIN=")
		case a == "--hotfix":
			hotfix = true
		case a == "--push":
			push = true
		case a == "--set":
			i++
			if i >= len(args) {
				die("--set 需要 k=v 参数")
			}
			k, v, ok := strings.Cut(args[i], "=")
			if !ok {
				die("--set 须形如 core=v0.18.0: %q", args[i])
			}
			sets[k] = v
		default:
			die("bump: 未知参数 %q", a)
		}
	}
	if train == "" {
		die("用法: trainctl bump TRAIN=x.y.z [--set k=v …] [--hotfix] [--push]")
	}
	for _, c := range train {
		if !(c == '.' || (c >= '0' && c <= '9')) {
			die("TRAIN 须形如 1.15.0: %q", train)
		}
	}

	b := &bumper{env: env, train: train, hotfix: hotfix, push: push, planned: map[string][]string{}}

	// 基线/默认值一律取 HEAD 版 train.yaml(tget_head 语义,防工作树污染)。
	head, err := env.TrainFileHead()
	if err != nil {
		die("读 HEAD train.yaml 失败: %v", err)
	}
	b.oldServer = head.Get("images.server")
	b.oldFCore = head.Get("lib.frontend-core")
	b.contracts = head.Get("lib.contracts")
	b.core = head.Get("lib.core")
	b.kit = head.Get("lib.kit")
	b.p2p = head.Get("lib.p2p")
	b.p2pc = head.Get("terminal.desktop.p2pc")
	b.fcore = b.oldFCore
	b.corePin = head.Get("terminal.fnos.core_pin")
	b.chart = head.Get("charts.chart")
	// 1.17.0 起镜像线并入产品号:server/frontend 镜像 tag、两仓 tag、页脚与各
	// web/ 包体版本全部随列车号(--set server 仅应急口子)。
	b.server = train
	for k, v := range sets {
		switch k {
		case "contracts":
			b.contracts = v
		case "core":
			b.core = v
		case "kit":
			b.kit = v
		case "p2p":
			b.p2p = v
		case "p2pc":
			b.p2pc = v
		case "core_pin":
			b.corePin = v
		case "frontend-core":
			b.fcore = v
		case "server":
			b.server = strings.TrimPrefix(v, "v")
			warnf("--set server 覆盖镜像号为 %s(应急口子;产品号联动下镜像线默认=列车号)", b.server)
		default:
			die("未知 --set 键: %q", k)
		}
	}
	b.feTag = "v" + b.server
	b.chartApp = "v" + b.server
	if b.server != b.oldServer {
		b.chart = BumpPatch(b.chart)
	}

	fmt.Printf("══ 列车 bump → %s (hotfix=%v, dry-run=%v)\n", train, hotfix, !push)
	fmt.Printf("   库线: contracts=%s core=%s kit=%s p2p=%s | 镜像: server=%s(前端同号) | 终端: core 钉=%s p2pc=%s\n",
		b.contracts, b.core, b.kit, b.p2p, b.server, b.corePin, b.p2pc)

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

	b.hub()
	b.frontend()
	b.fnos()
	b.native("openwrt")
	b.native("qnap")
	b.desktop()
	b.nasPlatforms()

	// 汇总
	fmt.Println("── 计划汇总")
	any := false
	for _, r := range bumpRepos {
		files := b.planned[r]
		if len(files) == 0 {
			continue
		}
		any = true
		if push {
			fmt.Printf("  ✓ %s 已提交 → train/%s(%s)\n", r, train, strings.Join(files, " "))
		} else {
			fmt.Printf("  [dry-run] %s 将变更 → 分支 train/%s + PR(%s)\n", r, train, strings.Join(files, " "))
		}
	}
	if !any {
		fmt.Println("  (无任何版本点变化——检查 TRAIN/--set 是否与现状一致)")
	}

	if push {
		b.restoreBranches()
		fmt.Printf("✓ bump PR 已建齐并开启自动合并(squash)。合并后由 advance(回调/sweep)推 tag → Release → finalize。\n")
	} else {
		fmt.Println("✓ dry-run 结束(零落盘)。确认后加 --push 执行。")
	}
}

type bumper struct {
	env   *Env
	train string
	hotfix bool
	push  bool

	oldServer, oldFCore                 string
	contracts, core, kit, p2p, p2pc     string
	fcore, corePin                      string
	server, feTag                       string
	chart, chartApp                     string

	planned map[string][]string // repo 名("." = hub)→ 变更文件
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
	b.planned[repoName] = append(b.planned[repoName], rel)
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
	args := append([]string{"add", "--"}, exist...)
	if _, err := Git(dir, args...); err != nil {
		die("%s git add 失败: %v", repoName, err)
	}
	if GitOK(dir, "diff", "--cached", "--quiet") {
		okf("%s 无列车变更,跳过", repoName)
		return
	}
	branch := "train/" + b.train
	if GitOK(dir, "rev-parse", "-q", "--verify", "refs/heads/"+branch) {
		if _, err := Git(dir, "checkout", "-q", branch); err != nil {
			die("%s checkout %s 失败: %v", repoName, branch, err)
		}
	} else {
		if _, err := Git(dir, "checkout", "-q", "-b", branch); err != nil {
			die("%s 建分支 %s 失败: %v", repoName, branch, err)
		}
	}
	// 重跑/分支复用:checkout 到已含相同变更的分支后索引与 HEAD 一致,无可提即跳过
	if !GitOK(dir, "diff", "--cached", "--quiet") {
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
	prOut, err := Gh("pr", "create", "-R", ghOrg+"/"+repo, "--base", base, "--head", branch,
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
	if _, err := Gh("pr", "merge", branch, "--auto", "--squash", "--repo", ghOrg+"/"+repo); err != nil {
		warnf("%s auto-merge 未开启(%v 摘要),advance 将在 checks 绿后合并", repoName, firstLine(err.Error()))
	}
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
	b.edit(".", dir, trainFileRel, func(string) string {
		return Render(TrainParams{
			Train: b.train, State: "draft", Hotfix: b.hotfix,
			Contracts: b.contracts, Core: b.core, Kit: b.kit, P2P: b.p2p, FCore: b.fcore,
			Server: b.server, FETag: b.feTag, Chart: b.chart, ChartApp: b.chartApp,
			P2PC: b.p2pc, CorePin: b.corePin, Platforms: platforms,
		})
	})
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
			{"`PigeonBox/kit/`", b.kit},
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

	b.commit(".", dir, "train: bump to "+b.train, []string{
		trainFileRel, "deploy/nas/compose.yml", "deploy/nas/env.example",
		"deploy/k8s/overlays/prod/kustomization.yaml", "docs/architecture.md",
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
	changed = b.edit("frontend", dir, "package.json", func(o string) string {
		return ReplaceTGZ(o, "frontend-core", b.fcore)
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
		return RenderDepsEnv([][2]string{{"CORE_PIN", b.corePin}, {"FRONTEND_CORE_PIN", b.fcore}})
	})
	// web/package.json:版本=前端列车号(页脚「前端版本」);tgz URL 跟随 lib.frontend-core
	pjChanged := b.edit("fnos", dir, "web/package.json", func(o string) string {
		return ReplaceTGZ(SetFirstJSONVersion(o, strings.TrimPrefix(b.feTag, "v")), "frontend-core", b.fcore)
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

// native openwrt/qnap 同构:VERSION+DEPS.env+web/(+go.mod 钉版)。
func (b *bumper) native(name string) {
	fmt.Printf("── [%s]\n", name)
	dir := b.env.MustRepoDir(name)
	oldVer := strings.TrimSpace(readContent(dir, "VERSION"))
	b.edit(name, dir, "VERSION", func(string) string { return b.train + "\n" })
	b.edit(name, dir, "DEPS.env", func(string) string {
		return RenderDepsEnv([][2]string{{"CORE_PIN", b.corePin}, {"FRONTEND_CORE_PIN", b.fcore}})
	})
	pjChanged := b.edit(name, dir, "web/package.json", func(o string) string {
		return ReplaceTGZ(SetFirstJSONVersion(o, strings.TrimPrefix(b.feTag, "v")), "frontend-core", b.fcore)
	})
	files := []string{"VERSION", "DEPS.env", "web/package.json", "web/package-lock.json"}
	if pjChanged {
		b.lockRefresh(filepath.Join(dir, "web"))
	}
	if b.goModPin(dir, name, oldVer != b.train) {
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
		b.planned[name] = append(b.planned[name], "go.mod", "go.sum")
		fmt.Printf("  [dry-run] %s go.mod 将钉 core@%s\n", name, b.corePin)
		return true
	}
	if err := Run(dir, []string{"GOWORK=off"}, "go", "mod", "edit", "-require=github.com/pigeonbox/core@"+b.corePin); err != nil {
		warnf("%s go mod edit 失败,人工检查: %v", name, err)
		return false
	}
	if err := Run(dir, []string{"GOWORK=off"}, "go", "mod", "tidy"); err != nil {
		warnf("%s go mod tidy 失败,人工检查 go.mod/go.sum: %v", name, err)
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
	b.edit("desktop", dir, "DEPS.env", func(string) string {
		return RenderDepsEnv([][2]string{{"P2PC_REF", b.p2pc}})
	})
	b.edit("desktop", dir, "src-tauri/tauri.conf.json", func(o string) string { return SetFirstJSONVersion(o, b.train) })
	b.edit("desktop", dir, "src-tauri/Cargo.toml", func(o string) string { return SetCargoVersion(o, b.train) })
	b.commit("desktop", dir, "train: bump to "+b.train, []string{
		"VERSION", "DEPS.env", "src-tauri/tauri.conf.json", "src-tauri/Cargo.toml",
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
			// sync 物化的文件计入计划(compose/env 模板带镜像钉版)
			for _, f := range commitFiles[p][1:] {
				b.noteIfChanged(p, dir, f)
			}
		} else {
			// dry-run:近似检测——物化后平台 compose/env 的镜像钉版=server
			b.edit(p, dir, composePath(p), func(o string) string { return SetComposeImageTag(o, b.server) })
			b.edit(p, dir, envPath(p), func(o string) string { return SetEnvImageTag(o, b.server) })
			if p == "ugreen" {
				b.edit(p, dir, "deploy/compose.ghcr-mirror.yml", func(o string) string { return SetComposeImageTag(o, b.server) })
			}
		}
		b.edit(p, dir, "VERSION", func(string) string { return b.train + "\n" })
		b.commit(p, dir, fmt.Sprintf("train: bump to %s(镜像 v%s)", b.train, b.server), commitFiles[p])
	}
}

// noteIfChanged push 模式下把 sync.sh 已改动的文件补记入计划(git diff 判定)。
func (b *bumper) noteIfChanged(repo, dir, rel string) {
	if !GitOK(dir, "diff", "--quiet", "--", rel) {
		b.planned[repo] = append(b.planned[repo], rel)
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
