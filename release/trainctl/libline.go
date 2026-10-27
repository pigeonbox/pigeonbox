package main

import (
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ───────────────────────── 库线(contracts/core/p2p/frontend-core) ─────────────────────────
//
// 库线 = 「产品线吃的东西」:core(业务核心库)、contracts(契约层)、p2p(联邦/直传)、
// frontend-core(公共前端 core)。它们各自独立发 tag,产品线(镜像 + NAS 三端 +
// 桌面端)的 go.mod / package.json 钉到具体版本。
//
// 2026-10-27 拍板:库线发版**收进列车**。此前库线 tag 必须人工先打好,否则 bump
// 撞「库线悬空钉」直接拒发(3.3.16 实录卡在 draft)⇒ 一趟车要人工排两段序,
// 发车慢、且漏一步就整车卡住。
//
// 列车现在自己负责三件事:
//  1. **解析目标版本**:显式 --set > 自动跟随各库仓最新已发布 tag > 冻结现状;
//  2. **目标版本尚未发布时自己打 tag**:带「仓内版本声明」断言 + semver 单调性断言
//     (打错版本 = 把不对的代码发布成公开 API 表面,比晚点发严重得多);
//  3. **等「可消费」落地**:Go 库等模块代理能拉到;npm 库等 Release 的 tgz 资产挂上
//     —— 没就位就 bump ⇒ 产品线的 PR 必红在 npm ci / missing go.sum entry。
//
// 版本真相源(每仓不同,marker 字段声明):
//
//	contracts      → package.json 的 version(发布流水线按 tag 覆写,故打 tag 前必须断言)
//	frontend-core  → VERSION 文件 + package.json
//	core / p2p     → **无仓内声明**(Go 惯例:tag 即版本)⇒ 只做 semver 单调性断言
type libRepo struct {
	key    string // train.yaml 键:lib.contracts / lib.core / lib.p2p / lib.frontend-core
	repo   string // GitHub 仓名
	module string // Go module 路径(空=不是 Go 库)
	pkg    string // npm 包基名(空=无 tgz 资产)
	marker string // 仓内版本声明文件(空=仅以 tag 为版本真相源)
}

// libRepos 是纳入列车的库线仓(kit 已归档并入 oekit,不在其中)。
func libRepos() []libRepo {
	return []libRepo{
		{key: "lib.contracts", repo: "contracts", module: "github.com/pigeonbox/contracts", pkg: "pigeonbox-contracts", marker: "package.json"},
		{key: "lib.core", repo: "core", module: "github.com/pigeonbox/core"},
		{key: "lib.p2p", repo: "p2p", module: "github.com/pigeonbox/p2p"},
		{key: "lib.frontend-core", repo: "frontend-core", pkg: "pigeonbox-frontend-core", marker: "VERSION"},
	}
}

// libRepoByKey 按 train.yaml 键取库线仓定义。
func libRepoByKey(key string) (libRepo, bool) {
	for _, lr := range libRepos() {
		if lr.key == key {
			return lr, true
		}
	}
	return libRepo{}, false
}

// libSetKey 把 --set 的短键(contracts/core/p2p/frontend-core)映射到 train.yaml 全键。
var libSetKey = map[string]string{
	"contracts":     "lib.contracts",
	"core":          "lib.core",
	"p2p":           "lib.p2p",
	"frontend-core": "lib.frontend-core",
}

// ───────────────────────── semver ─────────────────────────

// semverRe 只认 MAJOR.MINOR.PATCH(可带 -预发布/+构建);desktop-v* / v* 这类
// 非 semver tag 一律不参与排序(桌面端另有命名空间)。
var semverRe = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$`)

type semver struct {
	major, minor, patch int
	pre                 string
}

// parseSemver 解析版本号;非 semver 返回 ok=false。
func parseSemver(s string) (semver, bool) {
	m := semverRe.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return semver{}, false
	}
	ma, _ := strconv.Atoi(m[1])
	mi, _ := strconv.Atoi(m[2])
	pa, _ := strconv.Atoi(m[3])
	return semver{ma, mi, pa, m[4]}, true
}

// compareSemver 比较两个版本: a<b 返回 -1,a>b 返回 1,相等返回 0。
//
// 预发布版(带 -rc1 之类)**低于**同号正式版(Go module 语义)。
func compareSemver(a, b string) int {
	sa, oka := parseSemver(a)
	sb, okb := parseSemver(b)
	switch {
	case !oka && !okb:
		return strings.Compare(a, b)
	case !oka:
		return -1
	case !okb:
		return 1
	}
	if sa.major != sb.major {
		return sign(sa.major - sb.major)
	}
	if sa.minor != sb.minor {
		return sign(sa.minor - sb.minor)
	}
	if sa.patch != sb.patch {
		return sign(sa.patch - sb.patch)
	}
	switch {
	case sa.pre == "" && sb.pre == "":
		return 0
	case sa.pre == "":
		return 1 // 正式版 > 预发布版
	case sb.pre == "":
		return -1
	}
	return strings.Compare(sa.pre, sb.pre)
}

func sign(n int) int {
	if n > 0 {
		return 1
	}
	if n < 0 {
		return -1
	}
	return 0
}

// latestRemoteTag 取仓上最新的 semver tag(不含 desktop-v* 这类异命名空间)。
//
// 优先 git ls-remote(本地有检出时,不走 API 配额);**该查询成功即为权威**
// ——远端确实没有 semver tag 时不该再去打 API(否则离线/限流时把「没有 tag」
// 误报成「取不到 tag」)。只有 ls-remote 失败(网络/鉴权)才回落 gh api。
func latestRemoteTag(env *Env, repo string) (string, error) {
	var names []string
	if dir, ok := env.RepoDir(repo); ok {
		out, err := Git(dir, "ls-remote", "--tags", "origin")
		if err == nil {
			for _, ln := range splitLines(out) {
				if i := strings.Index(ln, "refs/tags/"); i >= 0 {
					t := strings.TrimSpace(ln[i+len("refs/tags/"):])
					t = strings.TrimSuffix(t, "^{}") // 剥离 annotated tag 的解引用行
					names = append(names, t)
				}
			}
			return pickLatestSemver(names, repo)
		}
	}
	out, err := Gh("api", "repos/"+ghOrg+"/"+repo+"/tags", "--paginate", "--jq", ".[].name")
	if err != nil {
		return "", fmt.Errorf("取 %s tag 列表失败: %w", repo, err)
	}
	return pickLatestSemver(splitLines(out), repo)
}

// pickLatestSemver 从 tag 名列表里挑出最新的 semver tag。
func pickLatestSemver(names []string, repo string) (string, error) {
	best := ""
	for _, t := range names {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		if _, ok := parseSemver(t); !ok {
			continue
		}
		if best == "" || compareSemver(t, best) > 0 {
			best = t
		}
	}
	if best == "" {
		return "", fmt.Errorf("%s 没有任何 semver tag", repo)
	}
	return best, nil
}

// ───────────────────────── 版本解析 ─────────────────────────

// libResolution 是一次库线解析的结果。
type libResolution struct {
	versions map[string]string // train.yaml 全键 → 版本
	notes    []string          // 人类可读的解析说明(变化/冻结/显式)
	frozen   map[string]bool   // 显式 --set 的键(这些版本由列车负责「发布」)
}

// resolveLibVersions 解析本趟列车的库线钉版。
//
// 三级优先(自上而下):
//  1. 显式 --set <lib>=<ver> —— 列车负责**发布**它(若尚未发布则自己打 tag);
//  2. 自动跟随该库仓**最新已发布 tag**(不冻结)—— 与 `go get -u` 的语义一致:
//     库线发布了新版本,产品线下一趟车自然跟上;pin 只升不降;
//  3. 冻结(--freeze-libs 或解析失败)—— 沿用 train.yaml 里的现钉版。
//
// current = train.yaml(HEAD)里的现钉版,按 train.yaml 全键给出(lib.contracts 等)。
//
// freeze=true 时全部走 3(仍会校验「已发布」,但不由列车创建 tag)。
func resolveLibVersions(env *Env, sets map[string]string, freeze bool, current map[string]string) (*libResolution, error) {
	res := &libResolution{versions: map[string]string{}, frozen: map[string]bool{}}
	for _, lr := range libRepos() {
		short := ""
		for k, full := range libSetKey {
			if full == lr.key {
				short = k
			}
		}
		cur := current[lr.key]
		// 1. 显式指定
		if short != "" {
			if v, ok := sets[short]; ok && v != "" {
				res.versions[lr.key] = v
				res.frozen[lr.key] = true
				res.notes = append(res.notes, fmt.Sprintf("%-14s %s(显式指定,列车负责发布)", lr.key, v))
				continue
			}
		}
		// 3a. 冻结
		if freeze {
			if cur == "" {
				return nil, fmt.Errorf("--freeze-libs 但 train.yaml 无 %s(无法冻结)", lr.key)
			}
			res.versions[lr.key] = cur
			res.notes = append(res.notes, fmt.Sprintf("%-14s %s(冻结)", lr.key, cur))
			continue
		}
		// 2. 自动跟随最新已发布 tag
		latest, err := latestRemoteTag(env, lr.repo)
		if err != nil {
			// 解析失败 ⇒ 回落现钉版(离线/权限不足时不阻断发车)
			if cur == "" {
				return nil, fmt.Errorf("解析 %s 最新 tag 失败且 train.yaml 无现钉版: %w", lr.repo, err)
			}
			res.versions[lr.key] = cur
			res.notes = append(res.notes, fmt.Sprintf("%-14s %s(自动跟随失败,回落现钉版)", lr.key, cur))
			continue
		}
		if cur != "" && compareSemver(latest, cur) < 0 {
			// 只升不降:现钉版比最新 tag 还新(本地未同步/预发布)⇒ 保持现钉版。
			res.versions[lr.key] = cur
			res.notes = append(res.notes, fmt.Sprintf("%-14s %s(保持;最新 tag %s 更旧)", lr.key, cur, latest))
			continue
		}
		if cur != latest {
			res.notes = append(res.notes, fmt.Sprintf("%-14s %s → %s(自动跟随最新已发布 tag)", lr.key, cur, latest))
		} else {
			res.notes = append(res.notes, fmt.Sprintf("%-14s %s(最新已发布 tag)", lr.key, latest))
		}
		res.versions[lr.key] = latest
	}
	return res, nil
}

// ───────────────────────── 发 tag ─────────────────────────

// ensureLibTag 保证目标版本在库仓已发布;未发布且本趟列车负责它时,列车自己打。
//
// 断言(任一不过 ⇒ 响亮失败,绝不静默打错版本):
//
//	· semver 单调性:目标版本必须**高于**该仓现有最新 tag(否则 tag 序列出现空洞/
//	  或版本号被复用);
//	· 仓内版本声明(contracts 的 package.json / frontend-core 的 VERSION):
//	  origin/<默认分支> 上声明的版本必须**等于**目标版本——
//	  发布流水线按 tag 覆写版本号(contracts release.yml)⇒ 不一致就是
//	  「把 A 的代码发布成 B 的版本」。
//
// 返回 true=本次由列车新建了 tag。
func ensureLibTag(env *Env, lr libRepo, version string, allowCreate bool) (bool, error) {
	if version == "" {
		return false, fmt.Errorf("%s 目标版本为空", lr.key)
	}
	tag := "v" + strings.TrimPrefix(version, "v")
	if env.TagExists(lr.repo, tag) {
		return false, nil
	}
	if !allowCreate {
		return false, fmt.Errorf("%s 钉版 %s 尚未发布(%s 仓无 %s tag)——用 --set %s=<版本> 让列车发布它",
			lr.key, version, lr.repo, tag, libShortKey(lr.key))
	}
	latest, err := latestRemoteTag(env, lr.repo)
	if err == nil && compareSemver(version, latest) <= 0 {
		return false, fmt.Errorf("%s 目标版本 %s 不高于该仓最新 tag %s——版本号不可复用/倒退", lr.key, version, latest)
	}
	if lr.marker != "" {
		declared, derr := declaredVersion(env, lr, version)
		if derr != nil {
			return false, derr
		}
		if declared != strings.TrimPrefix(version, "v") {
			return false, fmt.Errorf("%s 仓内版本声明(%s)=%q ≠ 目标 %s——先在 %s 仓 bump 版本号并合并,再发车",
				lr.key, lr.marker, declared, version, lr.repo)
		}
	}
	dir := env.MustRepoDir(lr.repo)
	def := defBranch(lr.repo)
	if _, err := Git(dir, "fetch", "-q", "origin", def); err != nil {
		return false, fmt.Errorf("%s fetch 失败: %w", lr.repo, err)
	}
	sha, err := Git(dir, "rev-parse", "origin/"+def)
	if err != nil {
		return false, fmt.Errorf("%s 解析 origin/%s 失败: %w", lr.repo, def, err)
	}
	if _, err := Git(dir, "tag", tag, sha); err != nil {
		return false, fmt.Errorf("%s 打 tag %s 失败: %w", lr.repo, tag, err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "refs/tags/"+tag); err != nil {
		return false, fmt.Errorf("%s 推 tag %s 失败(检查凭据对 %s 的写权限): %w", lr.repo, tag, lr.repo, err)
	}
	if !env.TagExists(lr.repo, tag) {
		return false, fmt.Errorf("%s tag %s push 后远端不可见(静默失败?),人工核查", lr.repo, tag)
	}
	okf("库线 %s 新发布 %s(tag %s → %s@%s)", lr.key, version, tag, def, shaShort(sha))
	return true, nil
}

// declaredVersion 读库仓默认分支上声明的版本(marker 文件)。
func declaredVersion(env *Env, lr libRepo, version string) (string, error) {
	dir, ok := env.RepoDir(lr.repo)
	if !ok {
		return "", fmt.Errorf("%s 未检出(无法校验版本声明 %s)", lr.repo, lr.marker)
	}
	def := defBranch(lr.repo)
	if _, err := Git(dir, "fetch", "-q", "origin", def); err != nil {
		return "", fmt.Errorf("%s fetch 失败: %w", lr.repo, err)
	}
	content, err := Git(dir, "show", "origin/"+def+":"+lr.marker)
	if err != nil {
		return "", fmt.Errorf("%s 读不到版本声明文件 %s: %w", lr.repo, lr.marker, err)
	}
	if lr.marker == "package.json" {
		return jsonVersion(content), nil
	}
	return strings.TrimSpace(content), nil
}

// jsonVersion 从 package.json 里取顶层 version(复用 editors.go 的 reJSONVersion,
// 避免引一个 JSON 依赖)。
//
// 用正则而非逐行前缀匹配:真实的 package.json 是多行缩进格式,但紧凑格式
// (整行 `{"version":"0.20.4"}`)也必须认得——否则版本声明读成空串 ⇒
// 打 tag 的断言会把「声明读不到」误报成「声明不符」。
func jsonVersion(content string) string {
	loc := reJSONVersion.FindStringIndex(content)
	if loc == nil {
		return ""
	}
	m := reJSONVersion.FindString(content[loc[0]:loc[1]]) // `"version": "0.20.4"`
	i := strings.Index(m, ":")
	if i < 0 {
		return ""
	}
	return strings.Trim(strings.TrimSpace(m[i+1:]), `"`)
}

// libShortKey 取 train.yaml 全键对应的 --set 短键(contracts/core/p2p/frontend-core)。
func libShortKey(full string) string {
	for k, v := range libSetKey {
		if v == full {
			return k
		}
	}
	return full
}

// ───────────────────────── 可消费性 ─────────────────────────

// waitLibConsumable 等库线的产物**可被消费方拿到**:
//
//	· Go 库(core/contracts/p2p):模块代理能拉到该版本(.info 200)
//	  ——否则产品线的 go.sum 物化不出来 ⇒ PR 必红在 missing go.sum entry;
//	· npm 库(contracts/frontend-core):Release 上挂了对应 tgz 资产
//	  ——否则消费仓 npm ci 拒装(1.15.0 实测四仓 main CI 红)。
//
// 两类都可能「晚到」(tag 推上去之后代理/流水线才有)⇒ 轮询等待。
func waitLibConsumable(env *Env, lr libRepo, version, timeout string) error {
	deadline := time.Now().Add(parseDuration(timeout, 10*time.Minute))
	v := strings.TrimPrefix(version, "v")
	for {
		pending := []string{}
		if lr.module != "" && !moduleVersionAvailable(lr.module, v) {
			pending = append(pending, "Go 模块代理")
		}
		if lr.pkg != "" && !releaseHasAsset(lr.repo, "v"+v, lr.pkg+"-"+v+".tgz") {
			pending = append(pending, "npm tgz 资产")
		}
		if len(pending) == 0 {
			okf("库线 %s %s 已可消费", lr.key, version)
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("库线 %s %s 在 %s 内未可消费(仍缺:%s)——查该仓 Release 流水线与模块代理同步",
				lr.key, version, timeout, strings.Join(pending, "、"))
		}
		warnf("库线 %s %s 待就绪(%s),等待中…", lr.key, version, strings.Join(pending, "、"))
		time.Sleep(20 * time.Second)
	}
}

// moduleVersionAvailable 探测 Go 模块代理是否已能提供该版本。
//
// 探测源按序:GOPROXY 里第一个 http(s) 代理 → proxy.golang.org → goproxy.cn。
// (本机直连 proxy.golang.org 常不可达,goproxy.cn 可用;CI 侧两者皆可。)
func moduleVersionAvailable(module, version string) bool {
	for _, base := range proxyBases() {
		url := base + "/" + module + "/@v/" + version + ".info"
		client := &http.Client{Timeout: 15 * time.Second}
		resp, err := client.Get(url)
		if err != nil {
			continue
		}
		code := resp.StatusCode
		resp.Body.Close()
		if code == 200 {
			return true
		}
	}
	return false
}

// proxyBases 返回要探测的模块代理基址(去重、保持顺序)。
//
// GOPROXY **已设置**时只探它(尊重调用方的显式配置:企业代理 / GOPROXY=off /
// 只用 goproxy.cn 等)⇒ 探测口径与消费方(go mod tidy)完全一致,不会出现
// 「代理 A 同步了、代理 B 没同步」的假阴性。未设置时用默认两档(官方 + goproxy.cn)。
func proxyBases() []string {
	var out []string
	add := func(s string) {
		s = strings.TrimSuffix(strings.TrimSpace(s), "/")
		if s == "" || !strings.HasPrefix(s, "http") {
			return
		}
		for _, e := range out {
			if e == s {
				return
			}
		}
		out = append(out, s)
	}
	if p := envProxy(); strings.TrimSpace(p) != "" {
		for _, e := range strings.Split(p, ",") {
			add(e)
		}
		return out
	}
	add("https://proxy.golang.org")
	add("https://goproxy.cn")
	return out
}

// releaseHasAsset 探测某个仓的某个 Release 是否已挂上指定资产。
func releaseHasAsset(repo, tag, asset string) bool {
	out, err := Gh("api", "repos/"+ghOrg+"/"+repo+"/releases/tags/"+tag, "--jq", ".assets[].name")
	if err != nil {
		return false
	}
	for _, ln := range splitLines(out) {
		if strings.TrimSpace(ln) == asset {
			return true
		}
	}
	return false
}

// ───────────────────────── 杂项 ─────────────────────────

// parseDuration 解析时长(支持 "90m"/"1h"/"30s");非法值回落 def。
func parseDuration(s string, def time.Duration) time.Duration {
	s = strings.TrimSpace(s)
	if s == "" {
		return def
	}
	if d, err := time.ParseDuration(s); err == nil && d > 0 {
		return d
	}
	return def
}

// envProxy 读 GOPROXY 环境变量(模块代理源清单,逗号分隔)。
func envProxy() string {
	return os.Getenv("GOPROXY")
}
