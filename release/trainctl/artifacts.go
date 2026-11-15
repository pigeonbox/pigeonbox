// artifacts.go —— release manifest 的制品可验证信息(pigeonbox#382)。
//
// manifest v1 只证「源码头在哪」;本文件补最后一公里:「用户装到的字节就是
// 那份源码编出来的产物」。artifacts[] 记两类可复验事实:
//
//   - image  : ghcr 镜像的 manifest/index digest(Docker-Content-Digest)
//   - package: hub Release 资产的逐包 sha256(GitHub API 的 digest 字段)
//
// 数据源一律是「远端事实」,不做本地推断:
//   - 镜像:ghcr registry HTTP API(匿名 pull token + HEAD manifest)——与
//     advance.go 的 registryHasTagAt 同一通道,但这里要的是 digest 而不只是
//     存在性;
//   - 包:hub Release(<platform>-v<version>)的 assets;sha256 取 GitHub 对
//     资产计算的 digest(发布后回填,不在本地重算几十 MB 包体)。
//
// 生成(buildManifest)与校验(verify section12)共用 collectManifestArtifacts
// 与同一个 artifactSource 接口 ⇒ 两侧口径永不漂移;测试用假 source 注入,
// 不碰网络。
//
// 生命周期:只在 tagged/shipped 态采集。draft/bump 阶段新版本镜像与包尚未
// 发布,采集必然是空 ⇒ 不采集也避免 bump 阶段无谓的网络等待;finalize 在
// state=shipped 后经 commitHubTrainFile 再生成 ⇒ 完整 artifacts 随 hub 快照
// 提交,hub tag 指向该提交。
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

const (
	manifestKindImage   = "image"
	manifestKindPackage = "package"
)

// packagePlatforms 是 hub Release 里挂平台包的七端(顺序=清单渲染顺序)。
// p2p 不在列:它是库线镜像/独立二进制,不随终端包发布。
var packagePlatforms = []string{"fnos", "openwrt", "qnap", "synology", "ugreen", "terramaster", "desktop"}

// ManifestArtifact 是单个产物条目(字段序=JSON 序,渲染确定)。
//
// image 用 Digest(sha256:<hex>);package 用 SHA256(裸 hex,便于 sha256sum
// 直接对拍)。SizeBytes 对 image 是 manifest/index 字节数,对 package 是资产
// 字节数。URL:镜像=ghcr 包页面,包=Release 资产下载地址。
type ManifestArtifact struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Platform  string `json:"platform,omitempty"`
	Ref       string `json:"ref"`
	Digest    string `json:"digest,omitempty"`
	SHA256    string `json:"sha256,omitempty"`
	SizeBytes int64  `json:"sizeBytes,omitempty"`
	URL       string `json:"url"`
}

// remoteAsset 是 GitHub Release 资产的远端事实(只保留清单需要的字段)。
type remoteAsset struct {
	Name   string
	Size   int64
	Digest string // sha256:<hex>;旧资产可能为空
	URL    string
}

// artifactSource 抽象制品的远端读取口:生产实现走 registry/GitHub API,
// 单测注入假实现(Env.Artifacts)。
type artifactSource interface {
	image(name, tag string) (digest string, size int64, err error)
	releaseAssets(releaseTag string) ([]remoteAsset, error)
}

// errArtifactNotPublished 区分「产物还没发布」与「判据读取失败」:
// 前者在 shipped 态是漂移(清单记了、远端没有),在非 shipped 态只是还没到;
// 后者一律 failUnavailable(没核对 ≠ 通过 ≠ 漂移)。
var errArtifactNotPublished = errors.New("artifact not published")

type remoteArtifactSource struct{}

func (remoteArtifactSource) image(name, tag string) (string, int64, error) {
	return registryImageDigestAt("https://ghcr.io", ghOrg, name, tag)
}

func (remoteArtifactSource) releaseAssets(releaseTag string) ([]remoteAsset, error) {
	return hubReleaseAssets(hubRepo, releaseTag)
}

// artifactSource 返回本次运行的制品读取口(Env.Artifacts 为测试注入缝)。
func (e *Env) artifactSource() artifactSource {
	if e.Artifacts != nil {
		return e.Artifacts
	}
	return remoteArtifactSource{}
}

// collectManifestArtifacts 采集当前列车的制品事实。只认 tagged/shipped 态;
// 任一项读取失败只告警并跳过(清单缺项由 verify 在 shipped 态判红兜底——
// 生成期不因网络抖动中断状态推进,但绝不把失败静默成「已核对」)。
func collectManifestArtifacts(env *Env, tf *TrainFile) []ManifestArtifact {
	out := []ManifestArtifact{}
	state := tf.Get("state")
	if state != "tagged" && state != "shipped" {
		return out
	}
	src := env.artifactSource()
	for _, name := range []string{"server", "frontend"} {
		tag := tf.Get("images." + name)
		if tag == "" {
			continue
		}
		digest, size, err := src.image(name, tag)
		if err != nil {
			if !errors.Is(err, errArtifactNotPublished) {
				warnf("manifest 镜像 %s:%s digest 读取失败(清单留空,verify 兜底): %v", name, tag, err)
			}
			continue
		}
		if digest == "" {
			continue
		}
		out = append(out, ManifestArtifact{
			Kind: manifestKindImage, Name: name, Platform: "linux/amd64,linux/arm64",
			Ref: "ghcr.io/" + ghOrg + "/" + name + ":" + tag, Digest: digest,
			SizeBytes: size, URL: imagePackageURL(name),
		})
	}
	for _, p := range packagePlatforms {
		tag := tf.Get("terminal." + p + ".tag")
		if tag == "" {
			continue
		}
		rel := packageReleaseTag(p, tag)
		assets, err := src.releaseAssets(rel)
		if err != nil {
			if !errors.Is(err, errArtifactNotPublished) {
				warnf("manifest %s 包资产读取失败(清单留空,verify 兜底): %v", rel, err)
			}
			continue
		}
		for _, a := range assets {
			if !isPackageAsset(a.Name) || a.Digest == "" {
				continue
			}
			out = append(out, ManifestArtifact{
				Kind: manifestKindPackage, Name: a.Name, Platform: p, Ref: rel,
				SHA256: strings.TrimPrefix(a.Digest, "sha256:"), SizeBytes: a.Size, URL: a.URL,
			})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return artifactKindRank(out[i].Kind) < artifactKindRank(out[j].Kind)
		}
		if out[i].Platform != out[j].Platform {
			return artifactPlatformRank(out[i].Platform) < artifactPlatformRank(out[j].Platform)
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func artifactKindRank(kind string) int {
	if kind == manifestKindImage {
		return 0
	}
	return 1
}

func artifactPlatformRank(platform string) int {
	if platform == "linux/amd64,linux/arm64" {
		return 0
	}
	for i, p := range packagePlatforms {
		if p == platform {
			return i + 1
		}
	}
	return len(packagePlatforms) + 1
}

// packageReleaseTag 是平台包所在的 hub Release tag:desktop 的 tag 本身已带
// desktop- 前缀(desktop-v5.8.0),其余平台是 <platform>-v<version>。
func packageReleaseTag(platform, tag string) string {
	if platform == "desktop" {
		return tag
	}
	return platform + "-" + tag
}

// isPackageAsset 判定 Release 资产是不是用户可安装的包体。排除校验和/签名
// 边车(.md5/.sha256/.txt/.json 等)与 SBOM——它们是「包的证据」,不是包本身。
func isPackageAsset(name string) bool {
	lower := strings.ToLower(name)
	for _, bad := range []string{".md5", ".sha1", ".sha256", ".sha512", ".sig", ".asc", ".txt", ".json", ".jsonl"} {
		if strings.HasSuffix(lower, bad) {
			return false
		}
	}
	for _, ext := range []string{
		".fpk", ".ipk", ".apk", ".spk", ".qpkg", ".upk", ".tos",
		".dmg", ".msi", ".exe", ".deb", ".rpm", ".appimage", ".tar.gz", ".zip",
	} {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}

// imagePackageURL 是 ghcr 包页面(稳定可读;镜像的规范引用见 Ref)。
func imagePackageURL(name string) string {
	return "https://github.com/orgs/" + ghOrg + "/packages/container/package/" + name
}

// registryImageDigestAt 读 ghcr 镜像 tag 当前 manifest/index 的 digest 与字节数。
//
// 必须按 registry 协议先取匿名 pull token 再 HEAD manifest(ghcr 对匿名裸请求
// 回 401,不是「不存在」;口径与 advance.go 的 registryHasTagAt 一致)。
// 404 ⇒ errArtifactNotPublished(镜像还没推);其他非 200 ⇒ 判据不可用。
func registryImageDigestAt(baseURL, org, name, tag string) (string, int64, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	repo := org + "/" + name
	tok, ok := registryPullToken(client, baseURL, repo)
	if !ok {
		return "", 0, fmt.Errorf("ghcr 匿名 pull token 获取失败(%s)", repo)
	}
	req, err := http.NewRequest("HEAD", baseURL+"/v2/"+repo+"/manifests/"+tag, nil)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", strings.Join([]string{
		"application/vnd.oci.image.index.v1+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
		"application/vnd.oci.image.manifest.v1+json",
		"application/vnd.docker.distribution.manifest.v2+json",
	}, ", "))
	resp, err := client.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "", 0, fmt.Errorf("%w: %s/%s:%s", errArtifactNotPublished, org, name, tag)
	}
	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("ghcr manifest 探测 HTTP %d(%s:%s)", resp.StatusCode, repo, tag)
	}
	digest := resp.Header.Get("Docker-Content-Digest")
	if !isSHA256Digest(digest) {
		return "", 0, fmt.Errorf("ghcr 未返回合法 Docker-Content-Digest(%q)", digest)
	}
	size := resp.ContentLength
	if size < 0 { // 个别代理/HTTP2 不回 Content-Length ⇒ 记 0(不渲染负数)
		size = 0
	}
	return digest, size, nil
}

// hubReleaseAssets 读 hub Release 的资产列表。用 ghRun(可测缝)执行 gh api;
// Release 不存在(404)= errArtifactNotPublished,其他错误=判据不可用。
func hubReleaseAssets(repo, releaseTag string) ([]remoteAsset, error) {
	out, err := ghRun("api", "repos/"+repo+"/releases/tags/"+releaseTag)
	if err != nil {
		if isNotFoundErr(err) {
			return nil, fmt.Errorf("%w: %s@%s", errArtifactNotPublished, repo, releaseTag)
		}
		return nil, err
	}
	var rel struct {
		Assets []struct {
			Name   string `json:"name"`
			Size   int64  `json:"size"`
			Digest string `json:"digest"`
			URL    string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.Unmarshal([]byte(out), &rel); err != nil {
		return nil, fmt.Errorf("Release %s 资产 JSON 解析失败: %w", releaseTag, err)
	}
	assets := make([]remoteAsset, 0, len(rel.Assets))
	for _, a := range rel.Assets {
		assets = append(assets, remoteAsset{Name: a.Name, Size: a.Size, Digest: a.Digest, URL: a.URL})
	}
	return assets, nil
}

// isNotFoundErr 识别 gh CLI 的 404 文案(gh api 对不存在 Release 回
// "gh: Not Found (HTTP 404)")。只用于区分「没发布」与「读失败」。
func isNotFoundErr(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "Not Found") || strings.Contains(msg, "HTTP 404")
}

// manifestArtifactsChk 校验 artifacts 面(pigeonbox#382)。
//
// 与 verify 现有口径一致的三层判据:
//   - 结构:kind/name/ref/digest|sha256/sizeBytes/url 必须齐全,重复键判红;
//   - 镜像:digest/size/ref 与 registry 当前 manifest 逐字一致;
//   - 包:manifest 的 {name,sha256,sizeBytes,url} 与 hub Release 资产逐项一致,
//     且「远端有/清单无」「清单有/远端无」都判漂移(改一个字节 sha256 即变)。
//
// 缺失语义按 state:shipped 态强校验(缺失/不匹配=红);非 shipped 态(产物
// 尚在陆续发布)缺失只告警,但**已记录值不匹配仍判红**(错值不是「还没到」)。
// 判据读取失败一律 failUnavailable(没核对 ≠ 通过 ≠ 漂移),保留 L-A/L-B 的
// 两层结论不放松。
func (v *verifier) manifestArtifactsChk(m *Manifest) {
	strict := isShippedPhase(v.state)
	if len(m.Artifacts) == 0 {
		// schema 1 老清单(issue #363 已发列车)按兼容口径只告警:这些列车
		// 发版时产物信息还没被采集,不能因格式升级追溯判红。
		if m.Schema == manifestSchemaV1 {
			v.warnCount("manifest schema=1 无 artifacts(老口径;下趟车/重跑 trainctl manifest 升级 schema 2)")
			return
		}
		if strict {
			v.fail("manifest 无 artifacts——shipped 列车必须回填镜像 digest 与平台包 sha256(重跑 trainctl manifest)")
		} else {
			v.warnCount("manifest 无 artifacts(非 shipped 态容忍;shipped 前必须回填)")
		}
		return
	}

	images := map[string]ManifestArtifact{}              // name → artifact
	packages := map[string]map[string]ManifestArtifact{} // platform → name → artifact
	bad := false
	for _, a := range m.Artifacts {
		switch a.Kind {
		case manifestKindImage:
			if a.Name == "" {
				v.fail("manifest 含无名 image artifact")
				bad = true
				continue
			}
			if _, dup := images[a.Name]; dup {
				v.fail("manifest 含重复 image artifact %s", a.Name)
				bad = true
				continue
			}
			if !isSHA256Digest(a.Digest) {
				v.fail("manifest image %s digest=%q 非法(需 sha256:<64hex>)", a.Name, a.Digest)
				bad = true
			}
			if a.Ref == "" || a.URL == "" {
				v.fail("manifest image %s 缺 ref/url", a.Name)
				bad = true
			}
			images[a.Name] = a
		case manifestKindPackage:
			if a.Name == "" || a.Platform == "" {
				v.fail("manifest 含无名/无平台 package artifact")
				bad = true
				continue
			}
			if packages[a.Platform] == nil {
				packages[a.Platform] = map[string]ManifestArtifact{}
			}
			if _, dup := packages[a.Platform][a.Name]; dup {
				v.fail("manifest 含重复 package artifact %s/%s", a.Platform, a.Name)
				bad = true
				continue
			}
			if !isHexSHA256(a.SHA256) {
				v.fail("manifest package %s/%s sha256=%q 非法(需 64 位小写 hex)", a.Platform, a.Name, a.SHA256)
				bad = true
			}
			if a.Ref == "" || a.URL == "" || a.SizeBytes <= 0 {
				v.fail("manifest package %s/%s 缺 ref/url/sizeBytes", a.Platform, a.Name)
				bad = true
			}
			packages[a.Platform][a.Name] = a
		default:
			v.fail("manifest artifact kind=%q 不识别(只允许 image|package)", a.Kind)
			bad = true
		}
	}
	if bad {
		return
	}

	src := v.env.artifactSource()
	for _, name := range []string{"server", "frontend"} {
		tag := v.tf.Get("images." + name)
		if tag == "" {
			continue
		}
		a, ok := images[name]
		if !ok {
			v.artifactMissing(strict, "manifest 缺 image artifact %s:%s", name, tag)
			continue
		}
		delete(images, name)
		wantRef := "ghcr.io/" + ghOrg + "/" + name + ":" + tag
		if a.Ref != wantRef {
			v.fail("manifest image %s ref=%s ≠ %s", name, a.Ref, wantRef)
		}
		if a.URL != imagePackageURL(name) {
			v.fail("manifest image %s url=%s ≠ %s", name, a.URL, imagePackageURL(name))
		}
		digest, size, err := src.image(name, tag)
		switch {
		case errors.Is(err, errArtifactNotPublished) || (err == nil && digest == ""):
			v.artifactMissing(strict, "ghcr.io/%s/%s:%s 远端不可见(清单记有 digest)", ghOrg, name, tag)
		case err != nil:
			v.failUnavailable("manifest image %s:%s 远端 digest 读取失败: %v", name, tag, err)
		case a.Digest != digest:
			v.fail("manifest image %s:%s digest=%s ≠ 远端 %s", name, tag, shaShort(a.Digest), shaShort(digest))
		case a.SizeBytes > 0 && size > 0 && a.SizeBytes != size:
			v.fail("manifest image %s:%s sizeBytes=%d ≠ 远端 %d", name, tag, a.SizeBytes, size)
		default:
			v.ok("manifest image %s:%s digest=%s", name, tag, shaShort(digest))
		}
	}
	for _, name := range sortedArtifactKeys(images) {
		v.artifactMissing(strict, "manifest 含 train.yaml 之外的 image artifact %s", name)
	}

	known := map[string]bool{}
	for _, p := range packagePlatforms {
		known[p] = true
		tag := v.tf.Get("terminal." + p + ".tag")
		if tag == "" {
			for _, n := range sortedArtifactKeys(packages[p]) {
				v.artifactMissing(strict, "train.yaml 无 terminal.%s.tag,manifest 却记了包 %s", p, n)
			}
			continue
		}
		rel := packageReleaseTag(p, tag)
		local := packages[p]
		assets, err := src.releaseAssets(rel)
		switch {
		case errors.Is(err, errArtifactNotPublished):
			v.artifactMissing(strict, "hub Release %s 不存在(平台 %s)", rel, p)
			continue
		case err != nil:
			v.failUnavailable("hub Release %s 资产读取失败: %v", rel, err)
			continue
		}
		remote := map[string]remoteAsset{}
		for _, a := range assets {
			if isPackageAsset(a.Name) {
				remote[a.Name] = a
			}
		}
		if len(remote) == 0 {
			v.artifactMissing(strict, "hub Release %s 无平台包资产", rel)
			continue
		}
		for _, n := range sortedArtifactKeys(remote) {
			ra := remote[n]
			a, ok := local[n]
			if !ok {
				v.artifactMissing(strict, "manifest 缺 %s 包 %s", p, n)
				continue
			}
			delete(local, n)
			if ra.Digest == "" {
				v.failUnavailable("%s 资产 %s 无 sha256 digest(GitHub 未计算,无从核对)", rel, n)
				continue
			}
			wantSHA := strings.TrimPrefix(ra.Digest, "sha256:")
			switch {
			case a.Ref != rel:
				v.fail("manifest %s 包 %s ref=%s ≠ %s", p, n, a.Ref, rel)
			case a.SHA256 != wantSHA:
				v.fail("manifest %s 包 %s sha256=%s ≠ 远端 %s", p, n, shaShort(a.SHA256), shaShort(wantSHA))
			case a.SizeBytes != ra.Size:
				v.fail("manifest %s 包 %s sizeBytes=%d ≠ 远端 %d", p, n, a.SizeBytes, ra.Size)
			case a.URL != ra.URL:
				v.fail("manifest %s 包 %s url=%s ≠ %s", p, n, a.URL, ra.URL)
			default:
				v.ok("manifest package %s/%s sha256=%s", p, n, shaShort(wantSHA))
			}
		}
		for _, n := range sortedArtifactKeys(local) {
			v.artifactMissing(strict, "manifest 含远端不存在的 %s 包 %s", p, n)
		}
	}
	for p, entries := range packages {
		if known[p] {
			continue
		}
		for _, n := range sortedArtifactKeys(entries) {
			v.artifactMissing(strict, "manifest 含未知平台 %s 的包 %s", p, n)
		}
	}
}

// artifactMissing 按 state 落「缺项」:shipped=真漂移(红),其余=告警。
func (v *verifier) artifactMissing(strict bool, format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if strict {
		failf("%s", msg)
		v.fails++
		return
	}
	v.warnCount("%s(非 shipped 态容忍;shipped 前必须回填)", msg)
}

// sortedArtifactKeys 返回 map 键的字典序切片(渲染/输出确定性)。
func sortedArtifactKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// isSHA256Digest 判定 "sha256:<64 位小写 hex>"(镜像 digest 格式)。
func isSHA256Digest(s string) bool {
	return strings.HasPrefix(s, "sha256:") && isHexSHA256(strings.TrimPrefix(s, "sha256:"))
}

// isHexSHA256 判定 64 位小写 hex(包 sha256 的裸格式)。
func isHexSHA256(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
