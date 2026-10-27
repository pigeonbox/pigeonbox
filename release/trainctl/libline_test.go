// libline_test.go —— 库线(contracts/core/p2p/frontend-core)纳入列车的守卫。
//
// 这条链路上有三个「错了就发错版」的口子,每个都要有能变红的用例:
//
//  1. **版本解析**:自动跟随最新已发布 tag,但**只升不降**;显式 --set 最优先;
//     --freeze-libs 冻结在 train.yaml 现值。
//  2. **打 tag 前的断言**:semver 单调性 + 仓内版本声明(package.json / VERSION)
//     ——打错版本 = 把不对的代码发布成公开 API 表面。
//  3. **可消费性**:Go 库等模块代理、npm 库等 Release 的 tgz 资产。
//
// 负对照:
//
//	· 把 compareSemver 的「预发布<正式版」判反 ⇒ 用例红;
//	· 把 ensureLibTag 的版本声明断言去掉 ⇒ 用例红;
//	· 把「只升不降」去掉 ⇒ 用例红。
package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ───────────────────────── 测试脚手架 ─────────────────────────

// gitRun 在 dir 下跑 git 并断言成功。
func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// newRepoWithTags 造一个「裸仓 origin + 本地克隆」,并打上给定的 tag。
//
// tagSpec 形如 "v0.1.0=文件名:内容"——每条在 main 上建文件、打 tag。
func newRepoWithTags(t *testing.T, root, name string, tagSpecs map[string]string) string {
	t.Helper()
	origin := filepath.Join(root, name+"-origin")
	work := filepath.Join(root, name)
	for _, d := range []string{origin, work} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	gitRun(t, origin, "init", "-q", "-b", "main")
	gitRun(t, origin, "config", "user.email", "t@example.com")
	gitRun(t, origin, "config", "user.name", "t")
	// origin 是**非裸**仓且 main 被检出 ⇒ 默认拒绝 push 到当前分支
	// (receive.denyCurrentBranch=refuse)⇒ 测试里放行。
	gitRun(t, origin, "config", "receive.denyCurrentBranch", "ignore")
	writeFile(t, origin, "README.md", name+"\n")
	gitRun(t, origin, "add", "-A")
	gitRun(t, origin, "commit", "-qm", "init")
	for tag, spec := range tagSpecs {
		file, content, ok := strings.Cut(spec, "=")
		if !ok {
			t.Fatalf("tagSpec 须形如 v0.1.0=文件名:内容,实得 %q", spec)
		}
		writeFile(t, origin, file, content)
		gitRun(t, origin, "add", "-A")
		gitRun(t, origin, "commit", "-qm", "tag "+tag)
		gitRun(t, origin, "tag", tag)
	}
	gitRun(t, work, "clone", "-q", origin, ".")
	gitRun(t, work, "config", "user.email", "t@example.com")
	gitRun(t, work, "config", "user.name", "t")
	return work
}

// newLibEnv 造一个含四个库线仓检出的 Env。
func newLibEnv(t *testing.T, tags map[string]map[string]string) *Env {
	t.Helper()
	root := t.TempDir()
	for _, lr := range libRepos() {
		spec, ok := tags[lr.repo]
		if !ok {
			spec = map[string]string{}
		}
		newRepoWithTags(t, root, lr.repo, spec)
	}
	return &Env{Root: root}
}

// libTestRepo 返回 libRepos 里某仓的定义(测试里按 repo 名取)。
func libTestRepo(t *testing.T, repo string) libRepo {
	t.Helper()
	for _, lr := range libRepos() {
		if lr.repo == repo {
			return lr
		}
	}
	t.Fatalf("未知库线仓 %q", repo)
	return libRepo{}
}

// ───────────────────────── semver ─────────────────────────

func TestCompareSemver(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"v1.2.3", "v1.2.3", 0},
		{"v1.2.4", "v1.2.3", 1},
		{"v1.3.0", "v1.2.9", 1},
		{"v2.0.0", "v1.99.99", 1},
		{"v1.10.0", "v1.9.0", 1}, // 数字段按数值比,不是字符串比
		{"v0.32.21", "v0.32.9", 1},
		{"v1.0.0-rc1", "v1.0.0", -1}, // 预发布 < 正式版
		{"v1.0.0", "v1.0.0-rc1", 1},
		{"v1.0.0-rc1", "v1.0.0-rc2", -1},
	}
	for _, c := range cases {
		if got := compareSemver(c.a, c.b); got != c.want {
			t.Fatalf("compareSemver(%q,%q)=%d, 期望 %d", c.a, c.b, got, c.want)
		}
	}
}

// 负对照:预发布与正式版的次序判反 ⇒ 用例红。
func TestCompareSemver_PrereleaseBelowRelease(t *testing.T) {
	if compareSemver("v1.0.0-rc1", "v1.0.0") >= 0 {
		t.Fatal("预发布版必须低于同号正式版(Go module 语义)")
	}
}

func TestParseSemverRejectsNonSemver(t *testing.T) {
	for _, s := range []string{"desktop-v4.0.5", "fnos-v1.2.3", "v4.0", "latest", ""} {
		if _, ok := parseSemver(s); ok {
			t.Fatalf("%q 不该被当作 semver", s)
		}
	}
	if _, ok := parseSemver("v4.0.5"); !ok {
		t.Fatal("v4.0.5 应被识别为 semver")
	}
}

// ───────────────────────── 版本解析 ─────────────────────────

func TestLatestRemoteTag_PicksHighestSemver(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"core": {"v0.9.3": "a=1", "v0.10.0": "b=2", "v0.9.10": "c=3"},
	})
	got, err := latestRemoteTag(env, "core")
	if err != nil {
		t.Fatalf("latestRemoteTag 失败: %v", err)
	}
	if got != "v0.10.0" {
		t.Fatalf("最新 tag 应是 v0.10.0,实得 %q", got)
	}
}

// 非 semver 的 tag(如桌面端的 desktop-v4.0.5)不参与排序。
func TestLatestRemoteTag_IgnoresNonSemver(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"core": {"v0.9.3": "a=1", "desktop-v9.9.9": "b=2"},
	})
	got, err := latestRemoteTag(env, "core")
	if err != nil {
		t.Fatalf("latestRemoteTag 失败: %v", err)
	}
	if got != "v0.9.3" {
		t.Fatalf("异命名空间 tag 不该参与排序,实得 %q", got)
	}
}

func TestResolveLibVersions_AutoFollowsLatest(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"contracts":     {"v0.20.3": "package.json={\"version\":\"0.20.3\"}\n"},
		"core":          {"v0.32.21": "a=1"},
		"p2p":           {"v0.9.3": "a=1"},
		"frontend-core": {"v0.11.35": "VERSION=0.11.35\n"},
	})
	current := map[string]string{
		"lib.contracts": "v0.20.1", "lib.core": "v0.32.19",
		"lib.p2p": "v0.9.2", "lib.frontend-core": "v0.11.34",
	}
	res, err := resolveLibVersions(env, map[string]string{}, false, current)
	if err != nil {
		t.Fatalf("resolveLibVersions 失败: %v", err)
	}
	for k, want := range map[string]string{
		"lib.contracts": "v0.20.3", "lib.core": "v0.32.21",
		"lib.p2p": "v0.9.3", "lib.frontend-core": "v0.11.35",
	} {
		if res.versions[k] != want {
			t.Fatalf("%s 应解析为 %s,实得 %s", k, want, res.versions[k])
		}
	}
	// 自动跟随的版本**不由列车负责发布**(它本来就已发布)。
	if res.frozen["lib.core"] {
		t.Fatal("自动跟随的版本不该标记为「列车负责发布」")
	}
}

func TestResolveLibVersions_ExplicitWins(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"core": {"v0.32.21": "a=1"},
	})
	res, err := resolveLibVersions(env, map[string]string{"core": "v0.33.0"}, false, map[string]string{
		"lib.contracts": "v0.20.3", "lib.core": "v0.32.19",
		"lib.p2p": "v0.9.3", "lib.frontend-core": "v0.11.35",
	})
	if err != nil {
		t.Fatalf("resolveLibVersions 失败: %v", err)
	}
	if res.versions["lib.core"] != "v0.33.0" {
		t.Fatalf("显式 --set 应最优先,实得 %s", res.versions["lib.core"])
	}
	if !res.frozen["lib.core"] {
		t.Fatal("显式指定的版本应由列车负责发布")
	}
}

func TestResolveLibVersions_FreezeKeepsCurrent(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"core": {"v0.32.21": "a=1"},
	})
	res, err := resolveLibVersions(env, map[string]string{}, true, map[string]string{
		"lib.contracts": "v0.20.3", "lib.core": "v0.32.19",
		"lib.p2p": "v0.9.3", "lib.frontend-core": "v0.11.35",
	})
	if err != nil {
		t.Fatalf("resolveLibVersions 失败: %v", err)
	}
	if res.versions["lib.core"] != "v0.32.19" {
		t.Fatalf("--freeze-libs 应保持现钉版,实得 %s", res.versions["lib.core"])
	}
}

// 只升不降:现钉版比最新 tag 还新时不得回退。
func TestResolveLibVersions_NeverDowngrades(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"core": {"v0.32.21": "a=1"},
	})
	res, err := resolveLibVersions(env, map[string]string{}, false, map[string]string{
		"lib.contracts": "v0.20.3", "lib.core": "v9.9.9",
		"lib.p2p": "v0.9.3", "lib.frontend-core": "v0.11.35",
	})
	if err != nil {
		t.Fatalf("resolveLibVersions 失败: %v", err)
	}
	if res.versions["lib.core"] != "v9.9.9" {
		t.Fatalf("不得把钉版降级,实得 %s", res.versions["lib.core"])
	}
}

// ───────────────────────── 打 tag ─────────────────────────

// 显式指定且尚未发布 ⇒ 列车自己打 tag(推进到 origin/main)。
//
// 注意前置:库线仓必须**先**把版本声明抬到目标版本(operator 改 package.json
// 并合并),列车才允许打对应 tag——否则就是「把 0.20.3 的代码发布成 0.20.4」。
func TestEnsureLibTag_CreatesTag(t *testing.T) {
	root := t.TempDir()
	work := newRepoWithTags(t, root, "contracts", map[string]string{
		"v0.20.3": "package.json={\"version\":\"0.20.3\"}\n",
	})
	// 模拟「operator 把版本声明抬到 0.20.4 并合并」
	writeFile(t, work, "package.json", "{\"version\":\"0.20.4\"}\n")
	gitRun(t, work, "add", "-A")
	gitRun(t, work, "commit", "-qm", "bump to 0.20.4")
	gitRun(t, work, "push", "-q", "origin", "main")

	env := &Env{Root: root}
	lr := libTestRepo(t, "contracts")

	created, err := ensureLibTag(env, lr, "v0.20.4", true)
	if err != nil {
		t.Fatalf("ensureLibTag 失败: %v", err)
	}
	if !created {
		t.Fatal("未发布的显式版本应由列车打 tag")
	}
	if !env.TagExists("contracts", "v0.20.4") {
		t.Fatal("tag v0.20.4 应已推到 origin")
	}
}

// 仓内版本声明与目标版本不一致 ⇒ 响亮失败(发错版比晚点发严重得多)。
//
// 负对照:把 declaredVersion 断言去掉 ⇒ 用例红。
func TestEnsureLibTag_RefusesMarkerMismatch(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "contracts", map[string]string{
		"v0.20.3": "package.json={\"version\":\"0.20.3\"}\n",
	})
	env := &Env{Root: root}
	lr := libTestRepo(t, "contracts")

	if _, err := ensureLibTag(env, lr, "v0.20.4", true); err == nil {
		t.Fatal("仓内版本声明(0.20.3)≠ 目标(0.20.4)时必须失败")
	}
	if env.TagExists("contracts", "v0.20.4") {
		t.Fatal("断言失败时不得留下 tag")
	}
}

// 版本号不可复用/倒退 ⇒ 拒绝打 tag。
func TestEnsureLibTag_RefusesNonMonotonic(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{"v0.32.21": "a=1"})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")
	if _, err := ensureLibTag(env, lr, "v0.30.0", true); err == nil {
		t.Fatal("目标版本低于现有最新 tag 时必须失败")
	}
}

// 未被显式指定(=不由列车发布)且尚未发布 ⇒ 响亮失败,提示用 --set。
func TestEnsureLibTag_RefusesUnpublishedWhenNotOurs(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{"v0.32.21": "a=1"})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")
	_, err := ensureLibTag(env, lr, "v0.32.22", false)
	if err == nil {
		t.Fatal("非列车负责发布的版本不该由列车打 tag")
	}
	if !strings.Contains(err.Error(), "--set") {
		t.Fatalf("错误信息应给出 --set 指引,实得 %v", err)
	}
}

// 已发布 ⇒ 幂等跳过。
func TestEnsureLibTag_IdempotentWhenExists(t *testing.T) {
	root := t.TempDir()
	newRepoWithTags(t, root, "core", map[string]string{"v0.32.21": "a=1"})
	env := &Env{Root: root}
	lr := libTestRepo(t, "core")
	created, err := ensureLibTag(env, lr, "v0.32.21", true)
	if err != nil {
		t.Fatalf("ensureLibTag 失败: %v", err)
	}
	if created {
		t.Fatal("已发布的版本不该重复打 tag")
	}
}

// ───────────────────────── 可消费性 ─────────────────────────

// 模块代理探测:命中 /@v/<ver>.info 即视为可消费。
//
// 用 httptest 顶替代理 ⇒ 不打真实网络(可重复、离线可跑)。
func TestModuleVersionAvailable_UsesProxyOverride(t *testing.T) {
	var hit string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = r.URL.Path
		if strings.HasSuffix(r.URL.Path, "/@v/v0.32.21.info") {
			w.Write([]byte(`{"Version":"v0.32.21"}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	t.Setenv("GOPROXY", srv.URL)

	if !moduleVersionAvailable("github.com/pigeonbox/core", "v0.32.21") {
		t.Fatal("代理已提供该版本,应判为可消费")
	}
	if hit != "/github.com/pigeonbox/core/@v/v0.32.21.info" {
		t.Fatalf("探测路径不对: %s", hit)
	}
	if moduleVersionAvailable("github.com/pigeonbox/core", "v0.0.1") {
		t.Fatal("代理没有该版本,不应判为可消费")
	}
}

func TestJSONVersion(t *testing.T) {
	got := jsonVersion("{\n  \"name\": \"x\",\n  \"version\": \"0.20.3\",\n  \"x\": 1\n}\n")
	if got != "0.20.3" {
		t.Fatalf("jsonVersion 应取到 0.20.3,实得 %q", got)
	}
	// 紧凑格式也要认得(否则版本声明读成空串 ⇒ 打 tag 断言误报)。
	if got := jsonVersion(`{"version":"0.20.4"}`); got != "0.20.4" {
		t.Fatalf("紧凑 JSON 的 version 应取到 0.20.4,实得 %q", got)
	}
	if jsonVersion("{\n  \"name\": \"x\"\n}\n") != "" {
		t.Fatal("无 version 字段时应返回空串")
	}
}
