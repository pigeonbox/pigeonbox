// verify_manifest_test.go pigeonbox#363 release manifest v1(校验面:verify section12)。
//
// 每条用例只动清单的一个维度,断言结构事实(fails/warns/unavails 计数与
// 关键标记),不依赖其余文案。fixture 全本地(newTaggedRepo),不碰网络。
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loadManifestObj 读盘上清单为对象(篡改用)。
func loadManifestObj(t *testing.T, root string) *Manifest {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, manifestRel))
	if err != nil {
		t.Fatal(err)
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return &m
}

// writeManifestObj 渲染并落盘(篡改回写用)。
func writeManifestObj(t *testing.T, root string, m *Manifest) {
	t.Helper()
	next, err := renderManifest(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, manifestRel), []byte(next), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newSection12Fixture 造 fixture 并写入「正确」的清单,返回 verifier。
func newSection12Fixture(t *testing.T) *verifier {
	t.Helper()
	env, tf := newManifestFixture(t)
	if !refreshManifest(env, tf) {
		t.Fatal("refreshManifest 应成功")
	}
	// state 必须从 train.yaml 带入:section12 的 artifacts 缺失语义按 state
	// 分档(shipped=红 / 非 shipped=告警),与 cmdVerify 的构造保持一致。
	return &verifier{env: env, tf: tf, state: tf.Get("state")}
}

// TestSection12_Green 正确清单 ⇒ 全绿(fails/unavails/warns 皆 0)。
func TestSection12_Green(t *testing.T) {
	v := newSection12Fixture(t)
	out := captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 0 || v.unavails != 0 || v.warns != 0 {
		t.Fatalf("正确清单应全绿,实得 fails=%d unavails=%d warns=%d\n%s",
			v.fails, v.unavails, v.warns, out)
	}
	if !strings.Contains(out, "release manifest") {
		t.Fatalf("输出应有 section12 标题:\n%s", out)
	}
}

// TestSection12_TrainMismatch 清单车次滞后 train.yaml ⇒ 红。
func TestSection12_TrainMismatch(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Train = "8.8.8"
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("车次不一致应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_VersionTamper 条目版本被篡改 ⇒ 红(且不再走 commit 核对)。
func TestSection12_VersionTamper(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Repos {
		if m.Repos[i].Repo == "contracts" {
			m.Repos[i].Version = "v0.99.0"
		}
	}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("版本篡改应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_CommitDrift commit 与远端 tag 指向不等(制品↔清单脱节)⇒ 红。
func TestSection12_CommitDrift(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Repos {
		if m.Repos[i].Repo == "contracts" {
			m.Repos[i].Commit = strings.Repeat("a", 40)
		}
	}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("commit 漂移应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_MissingCommitWarnsOnly commit 留空(生成时 tag 未发布)⇒
// 只告警不判红(tag 存在性归 section1)。
func TestSection12_MissingCommitWarnsOnly(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Repos {
		if m.Repos[i].Repo == "contracts" {
			m.Repos[i].Commit = ""
		}
	}
	writeManifestObj(t, v.env.Root, m)
	out := captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 0 {
		t.Fatalf("commit 留空不得判红,实得 fails=%d\n%s", v.fails, out)
	}
	if v.warns != 1 {
		t.Fatalf("commit 留空应恰 1 处告警,实得 %d", v.warns)
	}
}

// TestSection12_MissingFile 清单缺失 ⇒ 红(派生品没跟上列车文件)。
func TestSection12_MissingFile(t *testing.T) {
	env, tf := newManifestFixture(t)
	v := &verifier{env: env, tf: tf}
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("清单缺失应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_ExtraRepo 清单含 train.yaml 之外的条目 ⇒ 红。
func TestSection12_ExtraRepo(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Repos = append(m.Repos, ManifestEntry{
		Repo: "ghost", Kind: manifestKindLib, Version: "v9.9.9", Tag: "v9.9.9",
		Commit: strings.Repeat("b", 40),
	})
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("多余条目应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_DuplicateEntry 重复条目 ⇒ 红。
func TestSection12_DuplicateEntry(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Repos = append(m.Repos, m.Repos[0])
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("重复条目应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_RegisteredInVerify section12 必须真的挂在 cmdVerify 执行路径上
// (与 TestSection8bRegisteredInVerify 同款源码级钉死:守卫没挂上就是空转)。
func TestSection12_RegisteredInVerify(t *testing.T) {
	src, err := os.ReadFile("verify.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "v.section12ReleaseManifest()") {
		t.Fatal("cmdVerify 里必须调用 section12ReleaseManifest()")
	}
}
