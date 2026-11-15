// manifest_test.go pigeonbox#363 release manifest v1(生成侧:构建/渲染/子命令)。
//
// 断言全部是结构事实(字段值、SHA 逐字、确定性渲染、退出码),不依赖文案。
// fixture 的每个 manifest 条目仓都建本地裸仓(newTaggedRepo)⇒ TagSHA 走
// 本地 ls-remote,不碰网络。
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// manifestFixtureTrainYaml 覆盖 lib+component 两类条目。**每个被引用的仓
// 都在 fixture 里建带 tag 的本地仓**,否则 TagSHA 走 URL 回落碰网络。
const manifestFixtureTrainYaml = "train: 9.9.9\n" +
	"state: shipped\n" +
	"lib.contracts: v0.23.0\n" +
	"lib.core: v1.0.0\n" +
	"lib.kit: \n" +
	"lib.p2p: v0.9.7\n" +
	"lib.frontend-core: v0.18.0\n" +
	"images.server: 9.9.9\n" +
	"images.frontend: 9.9.9\n" +
	"frontend.tag: v9.9.9\n" +
	"terminal.fnos.tag: v9.9.9\n" +
	"terminal.fnos.version: 9.9.9\n"

// newManifestFixture 造 train.yaml + 全部条目仓(带 tag)的 fixture。
// manifestSpecs 覆盖:contracts/core/p2p/frontend-core/server/frontend/fnos。
func newManifestFixture(t *testing.T) (*Env, *TrainFile) {
	t.Helper()
	root := t.TempDir()
	writeTrainFile(t, root, manifestFixtureTrainYaml)
	for repo, tags := range map[string][]string{
		"contracts":     {"v0.23.0"},
		"core":          {"v1.0.0"},
		"p2p":           {"v0.9.7"},
		"frontend-core": {"v0.18.0"},
		"server":        {"v9.9.9"},
		"frontend":      {"v9.9.9"},
		"fnos":          {"v9.9.9"},
	} {
		newTaggedRepo(t, root, repo, tags...)
	}
	env := &Env{Root: root}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Fatal(err)
	}
	return env, tf
}

// localTagSHA 读 fixture 仓本地 tag 指向的 commit(断言期望值)。
func localTagSHA(t *testing.T, root, repo, tag string) string {
	t.Helper()
	sha, err := Git(filepath.Join(root, repo), "rev-parse", "refs/tags/"+tag+"^{commit}")
	if err != nil {
		t.Fatal(err)
	}
	return sha
}

// TestManifest_BuildAndRender 构建面:字段来自 train.yaml、commit 来自远端
// tag、渲染确定(两次逐字节相等且是合法 JSON)。
func TestManifest_BuildAndRender(t *testing.T) {
	env, tf := newManifestFixture(t)
	m := buildManifest(env, tf)
	if m.Schema != manifestSchema || m.Train != "9.9.9" || m.Contract != "v0.23.0" {
		t.Fatalf("结构字段错: schema=%q train=%q contract=%q", m.Schema, m.Train, m.Contract)
	}
	if m.Images["server"] != "9.9.9" || m.Images["frontend"] != "9.9.9" {
		t.Fatalf("镜像 tag 错: %v", m.Images)
	}
	if len(m.Repos) != 7 {
		t.Fatalf("应有 7 条(lib4+server+frontend+fnos),实得 %d: %+v", len(m.Repos), m.Repos)
	}
	byRepo := map[string]ManifestEntry{}
	for _, e := range m.Repos {
		byRepo[e.Repo] = e
	}
	contracts := byRepo["contracts"]
	if contracts.Kind != manifestKindLib || contracts.Version != "v0.23.0" || contracts.Tag != "v0.23.0" {
		t.Fatalf("contracts 条目错: %+v", contracts)
	}
	if want := localTagSHA(t, env.Root, "contracts", "v0.23.0"); contracts.Commit != want {
		t.Fatalf("contracts commit 应为本地 tag SHA %s,实得 %q", want, contracts.Commit)
	}
	srv := byRepo["server"]
	if srv.Kind != manifestKindComponent || srv.Tag != "v9.9.9" || srv.Version != "9.9.9" {
		t.Fatalf("server 条目错: %+v", srv)
	}
	if srv.Commit == "" {
		t.Fatal("server commit 不应为空(tag 已在 fixture 建出)")
	}
	// kit 归档(空版本)不得进清单
	if _, ok := byRepo["kit"]; ok {
		t.Fatal("kit 已归档,不得进 manifest")
	}
	a, err := renderManifest(m)
	if err != nil {
		t.Fatal(err)
	}
	b, err := renderManifest(buildManifest(env, tf))
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Fatal("渲染不确定:同一输入两次输出不等")
	}
	if !json.Valid([]byte(a)) || !strings.HasSuffix(a, "\n") {
		t.Fatal("渲染结果须是合法 JSON 且以换行结尾")
	}
}

// TestManifest_BuildBestEffortWhenTagMissing 无检出/无 tag ⇒ 生成不失败:
// 只留 contracts 一个条目保证全程本地(其余键置空 ⇒ specs 跳过)。
func TestManifest_BuildBestEffortWhenTagMissing(t *testing.T) {
	root := t.TempDir()
	writeTrainFile(t, root, "train: 9.9.9\nstate: draft\nlib.contracts: v0.23.0\nlib.core: \nlib.kit: \nlib.p2p: \nlib.frontend-core: \nimages.server: \nimages.frontend: \nfrontend.tag: \n")
	newTaggedRepo(t, root, "contracts", "v0.23.0")
	env := &Env{Root: root}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Fatal(err)
	}
	m := buildManifest(env, tf)
	if len(m.Repos) != 1 || m.Repos[0].Repo != "contracts" {
		t.Fatalf("应只有 contracts 一条,实得 %+v", m.Repos)
	}
	if m.Repos[0].Commit == "" {
		t.Fatal("contracts tag 已发布,commit 不应为空")
	}
	if len(m.Images) != 0 {
		t.Fatalf("images 空值不得落键,实得 %v", m.Images)
	}
}

// TestCmdManifest_WriteAndCheck 子命令面:生成落盘 → --check 绿;篡改 → 1。
func TestCmdManifest_WriteAndCheck(t *testing.T) {
	env, _ := newManifestFixture(t)
	path := filepath.Join(env.Root, manifestRel)
	if _, err := os.Stat(path); err == nil {
		t.Fatal("fixture 起点不应已有 manifest")
	}
	if code := cmdManifest(env, nil); code != 0 {
		t.Fatalf("生成应 exit 0,实得 %d", code)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("生成后文件应存在: %v", err)
	}
	if code := cmdManifest(env, []string{"--check"}); code != 0 {
		t.Fatalf("刚生成的清单 --check 应绿,实得 %d", code)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	old := "\"train\": \"9.9.9\""
	if !strings.Contains(string(raw), old) {
		t.Fatalf("清单里找不到待篡改串: %s", string(raw))
	}
	tampered := strings.Replace(string(raw), old, "\"train\": \"8.8.8\"", 1)
	if err := os.WriteFile(path, []byte(tampered), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := cmdManifest(env, []string{"--check"}); code != 1 {
		t.Fatalf("篡改后 --check 应 exit 1,实得 %d", code)
	}
}
