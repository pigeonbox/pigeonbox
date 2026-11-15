// artifacts_test.go pigeonbox#382:manifest artifacts[](制品可验证信息)。
//
// 断言全部是结构事实(字段值/sha 逐字/fails/warns/unavails 计数/退出码),
// 不依赖文案。生成面用假 artifactSource(不碰网络);采集器本身另有
// httptest 假 registry 与 ghRun 假 CLI 两条直接测试。
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeImageMeta 是假 registry 对单个镜像 tag 的回答。
type fakeImageMeta struct {
	digest string
	size   int64
}

// fakeArtifactSource 注入 Env.Artifacts:images/assets 即「远端事实」。
type fakeArtifactSource struct {
	images     map[string]fakeImageMeta // key=name:tag
	assets     map[string][]remoteAsset // key=releaseTag
	imageErr   error
	assetErr   map[string]error
	imageCalls int
	assetCalls int
}

func newFakeArtifactSource() *fakeArtifactSource {
	f := &fakeArtifactSource{
		images:   map[string]fakeImageMeta{},
		assets:   map[string][]remoteAsset{},
		assetErr: map[string]error{},
	}
	for _, name := range []string{"server", "frontend"} {
		f.images[name+":9.9.9"] = fakeImageMeta{
			digest: fakeDigest("image/" + name + ":9.9.9"),
			size:   1000 + int64(len(name)),
		}
	}
	f.assets["fnos-v9.9.9"] = []remoteAsset{fakeAsset("fnos-v9.9.9", "pigeonbox.fpk", 2001)}
	return f
}

func fakeSHA(label string) string {
	sum := sha256.Sum256([]byte(label))
	return hex.EncodeToString(sum[:])
}

func fakeDigest(label string) string { return "sha256:" + fakeSHA(label) }

func fakeAsset(releaseTag, name string, size int64) remoteAsset {
	return remoteAsset{
		Name:   name,
		Size:   size,
		Digest: fakeDigest("asset/" + releaseTag + "/" + name),
		URL:    "https://example.test/" + releaseTag + "/" + name,
	}
}

func (f *fakeArtifactSource) image(name, tag string) (string, int64, error) {
	f.imageCalls++
	if f.imageErr != nil {
		return "", 0, f.imageErr
	}
	m, ok := f.images[name+":"+tag]
	if !ok {
		return "", 0, fmt.Errorf("%w: %s:%s", errArtifactNotPublished, name, tag)
	}
	return m.digest, m.size, nil
}

func (f *fakeArtifactSource) releaseAssets(releaseTag string) ([]remoteAsset, error) {
	f.assetCalls++
	if err := f.assetErr[releaseTag]; err != nil {
		return nil, err
	}
	assets, ok := f.assets[releaseTag]
	if !ok {
		return nil, fmt.Errorf("%w: %s", errArtifactNotPublished, releaseTag)
	}
	return assets, nil
}

func fakeSourceOf(t *testing.T, env *Env) *fakeArtifactSource {
	t.Helper()
	f, ok := env.Artifacts.(*fakeArtifactSource)
	if !ok {
		t.Fatalf("fixture 未注入假 artifactSource,实得 %T", env.Artifacts)
	}
	return f
}

// TestPackageAssetFilter 包体过滤:校验和/SBOM 边车不算包,安装包必须收。
func TestPackageAssetFilter(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"pigeonbox.fpk", true},
		{"pigeonbox_5.8.0-1_x86_64.ipk", true},
		{"pigeonbox-5.8.0-r0_x86_64.apk", true},
		{"pigeonbox_5.8.0-0001.spk", true},
		{"PigeonBox_5.8.0_x86_64.qpkg", true},
		{"pigeonbox-ugreen-5.8.0.zip", true},
		{"PigeonBox_5.8.0_x64_en-US.msi", true},
		{"PigeonBox_5.8.0_amd64.AppImage", true},
		{"PigeonBox_5.8.0_aarch64.dmg", true},
		{"PigeonBox_5.8.0_x64.app.tar.gz", true},
		{"PigeonBox_5.8.0_x86_64.qpkg.md5", false},
		{"pigeonbox.fpk.sha256", false},
		{"p2pc-checksums.txt", false},
		{"pigeonbox-src-v5.8.0.cdx.json", false},
		{"provenance.intoto.jsonl", false},
	}
	for _, c := range cases {
		if got := isPackageAsset(c.name); got != c.want {
			t.Errorf("isPackageAsset(%q)=%v, want %v", c.name, got, c.want)
		}
	}
}

// TestRegistryImageDigestAt 直接测采集器:匿名 token → HEAD manifest →
// Docker-Content-Digest;404 必须归类 errArtifactNotPublished,5xx 判据不可用。
func TestRegistryImageDigestAt(t *testing.T) {
	const wantDigest = "sha256:" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"token":"test-token"}`))
	})
	mux.HandleFunc("/v2/pigeonbox/server/manifests/9.9.9", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("manifest 探测必须用 HEAD,实得 %s", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("必须带匿名 pull token,实得 %q", got)
		}
		w.Header().Set("Docker-Content-Digest", wantDigest)
		w.Header().Set("Content-Length", "647")
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/v2/pigeonbox/missing/manifests/9.9.9", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	mux.HandleFunc("/v2/pigeonbox/broken/manifests/9.9.9", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	digest, size, err := registryImageDigestAt(srv.URL, "pigeonbox", "server", "9.9.9")
	if err != nil || digest != wantDigest || size != 647 {
		t.Fatalf("digest/size 读取错: digest=%q size=%d err=%v", digest, size, err)
	}
	if _, _, err := registryImageDigestAt(srv.URL, "pigeonbox", "missing", "9.9.9"); !errors.Is(err, errArtifactNotPublished) {
		t.Fatalf("404 必须归类 errArtifactNotPublished,实得 %v", err)
	}
	if _, _, err := registryImageDigestAt(srv.URL, "pigeonbox", "broken", "9.9.9"); err == nil || errors.Is(err, errArtifactNotPublished) {
		t.Fatalf("5xx 必须是一般错误(判据不可用),实得 %v", err)
	}
}

// TestHubReleaseAssets 直接测 Release 资产解析:digest 原样保留(可为空),
// 404 归类 errArtifactNotPublished。
func TestHubReleaseAssets(t *testing.T) {
	prev := ghRun
	t.Cleanup(func() { ghRun = prev })

	ghRun = func(args ...string) (string, error) {
		if len(args) != 2 || args[0] != "api" || args[1] != "repos/pigeonbox/pigeonbox/releases/tags/fnos-v9.9.9" {
			t.Fatalf("gh 调用不符合预期: %v", args)
		}
		return `{"assets":[
			{"name":"pigeonbox.fpk","size":123,"digest":"sha256:` + fakeSHA("fpk") + `","browser_download_url":"https://example.test/fpk"},
			{"name":"old.zip","size":7,"digest":null,"browser_download_url":"https://example.test/old.zip"}
		]}`, nil
	}
	assets, err := hubReleaseAssets(hubRepo, "fnos-v9.9.9")
	if err != nil {
		t.Fatal(err)
	}
	if len(assets) != 2 || assets[0].Name != "pigeonbox.fpk" || assets[0].Digest == "" ||
		assets[0].Size != 123 || assets[0].URL != "https://example.test/fpk" {
		t.Fatalf("资产解析错: %+v", assets)
	}
	if assets[1].Digest != "" {
		t.Fatalf("旧资产无 digest 必须保持空,实得 %q", assets[1].Digest)
	}

	ghRun = func(...string) (string, error) {
		return "", errors.New("gh api repos/x/y/releases/tags/z: gh: Not Found (HTTP 404)")
	}
	if _, err := hubReleaseAssets("x/y", "z"); !errors.Is(err, errArtifactNotPublished) {
		t.Fatalf("Release 404 必须归类 errArtifactNotPublished,实得 %v", err)
	}
}

// TestCollectManifestArtifactsStates 只在 tagged/shipped 态采集;draft 不碰
// 网络(计数为 0),shipped 采集镜像+包且字段逐字正确。
func TestCollectManifestArtifactsStates(t *testing.T) {
	const base = "train: 9.9.9\n" +
		"images.server: 9.9.9\nimages.frontend: 9.9.9\n" +
		"terminal.fnos.tag: v9.9.9\n"
	for _, state := range []string{"draft", "shipped"} {
		t.Run(state, func(t *testing.T) {
			env := &Env{Artifacts: newFakeArtifactSource()}
			tf := trainFileFromContent("(test)", base+"state: "+state+"\n")
			got := collectManifestArtifacts(env, tf)
			src := fakeSourceOf(t, env)
			if state == "draft" {
				if len(got) != 0 || src.imageCalls != 0 || src.assetCalls != 0 {
					t.Fatalf("draft 态不得采集: artifacts=%d imageCalls=%d assetCalls=%d",
						len(got), src.imageCalls, src.assetCalls)
				}
				return
			}
			if len(got) != 3 {
				t.Fatalf("shipped 态应有 2 镜像 + 1 包,实得 %d: %+v", len(got), got)
			}
			byName := map[string]ManifestArtifact{}
			for _, a := range got {
				byName[a.Kind+"/"+a.Name] = a
			}
			srv := byName["image/server"]
			if srv.Digest != fakeDigest("image/server:9.9.9") || srv.Ref != "ghcr.io/pigeonbox/server:9.9.9" ||
				srv.URL == "" || srv.SizeBytes == 0 {
				t.Fatalf("server 镜像 artifact 字段错: %+v", srv)
			}
			pkg := byName["package/pigeonbox.fpk"]
			if pkg.Platform != "fnos" || pkg.Ref != "fnos-v9.9.9" ||
				pkg.SHA256 != fakeSHA("asset/fnos-v9.9.9/pigeonbox.fpk") || pkg.SizeBytes != 2001 {
				t.Fatalf("fnos 包 artifact 字段错: %+v", pkg)
			}
		})
	}
}

// TestManifest_Schema2RendersEmptyArtifacts schema 2 即使无制品也要显式写
// "artifacts": [](不是省略/ null),让「无制品信息」可见。
func TestManifest_Schema2RendersEmptyArtifacts(t *testing.T) {
	root := t.TempDir()
	writeTrainFile(t, root, "train: 9.9.9\nstate: draft\nlib.contracts: \nlib.core: \nlib.kit: \nlib.p2p: \nlib.frontend-core: \nimages.server: \nimages.frontend: \nfrontend.tag: \n")
	env := &Env{Root: root, Artifacts: newFakeArtifactSource()}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Fatal(err)
	}
	out, err := renderManifest(buildManifest(env, tf))
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		t.Fatal(err)
	}
	if got := string(raw["artifacts"]); got != "[]" {
		t.Fatalf("schema 2 空 artifacts 必须渲染为 [],实得 %q\n%s", got, out)
	}
}

// TestCmdManifest_CheckDetectsArtifactDrift 生成后远端 digest 变了(同名 tag
// 重推/包体替换)⇒ --check 必须变红。
func TestCmdManifest_CheckDetectsArtifactDrift(t *testing.T) {
	env, _ := newManifestFixture(t)
	if code := cmdManifest(env, nil); code != 0 {
		t.Fatalf("生成应 exit 0,实得 %d", code)
	}
	if code := cmdManifest(env, []string{"--check"}); code != 0 {
		t.Fatalf("刚生成的清单 --check 应绿,实得 %d", code)
	}
	src := fakeSourceOf(t, env)
	src.images["server:9.9.9"] = fakeImageMeta{digest: fakeDigest("image/server:moved"), size: 999}
	if code := cmdManifest(env, []string{"--check"}); code != 1 {
		t.Fatalf("镜像 digest 漂移后 --check 应 exit 1,实得 %d", code)
	}
}

// TestSection12_ArtifactDigestDrift 清单里的镜像 digest 被改成错值 ⇒ shipped
// 态判红(制品↔清单脱节)。
func TestSection12_ArtifactDigestDrift(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Artifacts {
		if m.Artifacts[i].Kind == manifestKindImage && m.Artifacts[i].Name == "server" {
			m.Artifacts[i].Digest = fakeDigest("tampered")
		}
	}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("镜像 digest 漂移应恰 1 处红,实得 fails=%d unavails=%d", v.fails, v.unavails)
	}
}

// TestSection12_ArtifactMissing 清单缺一个 image artifact ⇒ shipped 态判红。
func TestSection12_ArtifactMissing(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	out := m.Artifacts[:0]
	for _, a := range m.Artifacts {
		if a.Kind == manifestKindImage && a.Name == "server" {
			continue
		}
		out = append(out, a)
	}
	m.Artifacts = out
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("缺 image artifact 应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_PackageSHA256Drift 改一个字节的包 sha256 ⇒ 判红。
func TestSection12_PackageSHA256Drift(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Artifacts {
		if m.Artifacts[i].Kind == manifestKindPackage {
			m.Artifacts[i].SHA256 = fakeSHA("tampered-package")
		}
	}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("包 sha256 漂移应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_RemotePackageExtra 远端 Release 多出一个清单没记的包 ⇒ 判红
// (包体被替换/追加,清单必须同步)。
func TestSection12_RemotePackageExtra(t *testing.T) {
	v := newSection12Fixture(t)
	src := fakeSourceOf(t, v.env)
	src.assets["fnos-v9.9.9"] = append(src.assets["fnos-v9.9.9"],
		fakeAsset("fnos-v9.9.9", "pigeonbox-extra.fpk", 3001))
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("远端多包应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_ArtifactExtra 清单记了远端不存在的包 ⇒ 判红。
func TestSection12_ArtifactExtra(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Artifacts = append(m.Artifacts, ManifestArtifact{
		Kind: manifestKindPackage, Name: "ghost.fpk", Platform: "fnos", Ref: "fnos-v9.9.9",
		SHA256: fakeSHA("ghost"), SizeBytes: 1, URL: "https://example.test/ghost.fpk",
	})
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("清单多包应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_SchemaV1NoArtifactsWarnsOnly 老 schema 1 清单(无 artifacts)
// 必须只告警不判红(pigeonbox#363 已发列车不因格式升级假红)。
func TestSection12_SchemaV1NoArtifactsWarnsOnly(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Schema = manifestSchemaV1
	m.Artifacts = nil
	writeManifestObj(t, v.env.Root, m)
	out := captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 0 {
		t.Fatalf("schema 1 无 artifacts 不得判红,实得 fails=%d\n%s", v.fails, out)
	}
	if v.warns != 1 {
		t.Fatalf("schema 1 无 artifacts 应恰 1 处告警,实得 %d", v.warns)
	}
}

// TestSection12_ShippedNoArtifactsFails schema 2 + shipped + 空 artifacts ⇒ 红。
func TestSection12_ShippedNoArtifactsFails(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	m.Artifacts = []ManifestArtifact{}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("shipped 空 artifacts 应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_NonShippedMissingArtifactsWarns 非 shipped 态缺 artifacts
// 只告警(产物尚在陆续发布),不判红。
func TestSection12_NonShippedMissingArtifactsWarns(t *testing.T) {
	v := newSection12Fixture(t)
	v.state = "tagged"
	m := loadManifestObj(t, v.env.Root)
	m.Artifacts = nil
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 0 || v.warns != 1 {
		t.Fatalf("非 shipped 缺 artifacts 应 0 红 1 告警,实得 fails=%d warns=%d", v.fails, v.warns)
	}
}

// TestSection12_MalformedArtifactFails 结构非法(sha256 不是 64 hex)⇒ 红;
// 不因坏条目继续做远端比对(避免噪声)。
func TestSection12_MalformedArtifactFails(t *testing.T) {
	v := newSection12Fixture(t)
	m := loadManifestObj(t, v.env.Root)
	for i := range m.Artifacts {
		if m.Artifacts[i].Kind == manifestKindPackage {
			m.Artifacts[i].SHA256 = "not-a-sha"
		}
	}
	writeManifestObj(t, v.env.Root, m)
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 1 {
		t.Fatalf("非法 sha256 应恰 1 处红,实得 %d", v.fails)
	}
}

// TestSection12_ArtifactCriteriaUnavailable 远端读取失败 ⇒ 计判据不可用
// (exit 2 路径),不得谎报成通过或漂移。
func TestSection12_ArtifactCriteriaUnavailable(t *testing.T) {
	v := newSection12Fixture(t)
	src := fakeSourceOf(t, v.env)
	src.imageErr = errors.New("registry timeout")
	captureStdout(t, func() { v.section12ReleaseManifest() })
	if v.fails != 0 || v.unavails != 2 {
		t.Fatalf("两个镜像都读失败应 0 红 2 处不可用,实得 fails=%d unavails=%d", v.fails, v.unavails)
	}
	if code := verifyExitCode(v.fails, v.unavails); code != 2 {
		t.Fatalf("判据不可用退出码应为 2,实得 %d", code)
	}
}

// TestManifestArtifacts_FileDriftOnDisk 直接改盘上清单的 artifacts 字节 ⇒
// --check 必须红(逐字比对覆盖 artifacts)。
func TestManifestArtifacts_FileDriftOnDisk(t *testing.T) {
	env, _ := newManifestFixture(t)
	if code := cmdManifest(env, nil); code != 0 {
		t.Fatalf("生成应 exit 0,实得 %d", code)
	}
	path := filepath.Join(env.Root, manifestRel)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	tampered := strings.Replace(string(raw), `"sizeBytes": 2001`, `"sizeBytes": 2002`, 1)
	if tampered == string(raw) {
		t.Fatalf("清单里找不到待篡改的 sizeBytes: %s", raw)
	}
	if err := os.WriteFile(path, []byte(tampered), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := cmdManifest(env, []string{"--check"}); code != 1 {
		t.Fatalf("artifacts 字节漂移后 --check 应 exit 1,实得 %d", code)
	}
}
