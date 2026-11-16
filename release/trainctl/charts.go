package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// charts.go —— chart 版本号真相源(2026-11-17 新增)。
//
// 背景(5.9.0 发车后审计实录):
//   列车推 charts 版本时,chart 版本号是从 train.yaml 自己的旧钉版 charts.chart
//   **+1** 推算的(bump 的 BumpPatch(b.chart)),而 charts 仓的版本计数器是**独立
//   推进**的——chart 侧自己的修复线会发 2.0.13x/2.0.14x,列车并不知情。
//   旧钉版落后于实况时,+1 得到的版本号会:
//     ① **低于** charts 仓已发布的最高版本 ⇒ 把 charts main 的版本号写退;
//     ② **撞名**已发布的 release ⇒ chart-releaser 无法再发同名 ⇒ 本次 chart 通道空产。
//   实录:5.8.0 钉 charts.chart=2.0.132,而 charts 实况早已 2.0.135 ⇒ 5.9.0 推出
//   2.0.133 ⇒ 撞上 11-14 已发布的 pigeonbox-2.0.133(包内 appVersion=v5.8.0)
//   ⇒ charts main 被写退、**5.9.0 的 chart 包没进通道**(helm repo 最新仍是 2.0.135)。
//
// 改完后的唯一口径:
//   · chart 版本号 = max(charts main 当前版本, charts 已发布 release 最高版本) + 1
//   · 已发布 release 里若已有「**包内** appVersion == 本趟 app」⇒ 复用那个版本(不重复发)
//   · 新版本号**严格大于** charts 已发布最高版本 ⇒ 永不倒退、永不撞名
//   · train.yaml 的 charts.chart 只是「本趟车期望的 chart 版本」的**投影**,不是计数器真相源
//   · 「chart 包已进通道」单独查(发布物存在 + 包内 appVersion 对得上)

const chartReleaseTagPrefix = "pigeonbox-"

// chartRelPath 是 charts 仓里 Chart.yaml 的仓内路径。
const chartRelPath = "charts/pigeonbox/Chart.yaml"

// chartAppScanLimit 限制「找包内 appVersion 匹配的既有 release」时扫描的候选数
// (每个候选一次远端读;命中多半在最近几个 ⇒ 够用且不把 API 打到冒烟)。
const chartAppScanLimit = 8

// chartReality 是 charts 仓的实况(chart 版本号的真相源)。
type chartReality struct {
	MainVer   string // charts/main 的 Chart.yaml version
	MainApp   string // charts/main 的 Chart.yaml appVersion
	PubMax    string // charts 仓已发布 release 的最高版本(空=还没发过)
	PubForApp string // 已发布且**包内** appVersion == 目标 app 的 release 版本(空=没有)
}

// chartPublishedVersions 取 charts 仓已发布的 chart release 版本号(降序)。
func chartPublishedVersions() ([]string, error) {
	out, err := ghRunner("api", "repos/"+ghOrg+"/charts/releases?per_page=100",
		"--jq", `[.[] | select(.tag_name|startswith("`+chartReleaseTagPrefix+`")) | .tag_name]`)
	if err != nil {
		return nil, fmt.Errorf("取 charts 已发布 release 失败: %w", err)
	}
	var vers []string
	for _, ln := range splitLines(out) {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		vers = append(vers, strings.TrimPrefix(ln, chartReleaseTagPrefix))
	}
	sort.Slice(vers, func(i, j int) bool { return compareSemver(vers[i], vers[j]) > 0 })
	return vers, nil
}

// chartPublishedMax 取 charts 仓已发布 chart release 的最高版本(空=还没发过)。
func chartPublishedMax() (string, error) {
	vers, err := chartPublishedVersions()
	if err != nil {
		return "", err
	}
	if len(vers) == 0 {
		return "", nil
	}
	return vers[0], nil
}

// resolveChartReality 读 charts 仓实况(main 的 Chart.yaml + 已发布 release 清单)。
// 查不到 ⇒ 返回错误(判据不可用):**不猜版本号**。
func resolveChartReality(env *Env, wantApp string) (chartReality, error) {
	var r chartReality
	cyaml, err := env.Raw("charts/main/" + chartRelPath)
	if err != nil {
		return r, fmt.Errorf("读 charts/main 的 Chart.yaml 失败: %w", err)
	}
	r.MainVer = yamlTopKey(cyaml, "version:")
	r.MainApp = yamlTopKey(cyaml, "appVersion:")
	if r.MainVer == "" {
		return r, fmt.Errorf("charts/main 的 Chart.yaml 没有 version 字段")
	}
	vers, err := chartPublishedVersions()
	if err != nil {
		return r, err
	}
	for i, v := range vers {
		if r.PubMax == "" {
			r.PubMax = v
		}
		if wantApp == "" || i >= chartAppScanLimit {
			break
		}
		app, aerr := chartReleaseAppVersion(env, v)
		if aerr != nil || app == "" {
			continue
		}
		if app == wantApp {
			r.PubForApp = v
			break
		}
	}
	return r, nil
}

// chartReleaseAppVersion 读某个已发布 chart release **包内** Chart.yaml 的 appVersion
// (读的是该 release tag 处的文件 ⇒ 是「通道里那个包」的真实内容,不是 main 的)。
func chartReleaseAppVersion(env *Env, ver string) (string, error) {
	out, err := env.Raw("charts/" + chartReleaseTagPrefix + ver + "/" + chartRelPath)
	if err != nil {
		return "", err
	}
	return yamlTopKey(out, "appVersion:"), nil
}

// chartReleaseExists charts 仓是否已有该 release。
func chartReleaseExists(ver string) bool {
	out, err := ghRunner("api", "repos/"+ghOrg+"/charts/releases/tags/"+chartReleaseTagPrefix+ver, "--jq", ".tag_name")
	return err == nil && strings.TrimSpace(out) != ""
}

// nextChartVersion 按 charts 仓实况推算下一个 chart 版本号。
//
//	· 已有承载本趟 app 的 release ⇒ 复用它(不重复发同名)。
//	· 否则 = max(main 当前版本, 已发布最高版本) + 1 ⇒ 严格大于已发布最高版本。
func nextChartVersion(real chartReality, wantApp string) (string, error) {
	if real.PubForApp != "" {
		return real.PubForApp, nil
	}
	base := real.PubMax
	if compareSemver(real.MainVer, base) > 0 {
		base = real.MainVer
	}
	if base == "" {
		return "", fmt.Errorf("charts 实况不可用(main=%q 已发布最高=%q)——拒绝猜版本号", real.MainVer, real.PubMax)
	}
	next := BumpPatch(base)
	if compareSemver(next, base) <= 0 {
		return "", fmt.Errorf("chart 版本推算异常:%s 不大于 %s", next, base)
	}
	return next, nil
}

// decideChartVersion 决定「本趟车该用哪个 chart 版本」。**纯函数**(便于表驱动单测)。
//
// 返回:ver=要用的版本号;reuse=true 表示「该 release 已存在且承载本趟 app ⇒ 不重复发」。
//
// 口径:
//
//	· 已有承载本趟 app 的 release ⇒ 复用它(不重复发同名);
//	· 钉版 ≤ charts 已发布最高版本(撞名/落后)⇒ 按实况重算(绝不写退、绝不撞名);
//	· 否则沿用钉版(列车 bump 已按实况算好)。
func decideChartVersion(real chartReality, wantApp, pin string) (ver string, reuse bool, err error) {
	if real.PubForApp != "" {
		return real.PubForApp, true, nil
	}
	if real.PubMax != "" && compareSemver(pin, real.PubMax) <= 0 {
		v, verr := nextChartVersion(real, wantApp)
		if verr != nil {
			return "", false, verr
		}
		return v, false, nil
	}
	return pin, false, nil
}

// chartPackageVerdict 判定「已发布的 chart 包是否承载本趟 app」。**纯函数**。
//
// 返回 "ok" | "missing" | "mismatch" | "pending":
//
//	· ok       = 包在通道里且包内 appVersion 对得上;
//	· missing  = 包没发布(硬失败口径);
//	· mismatch = 包在但装的是别的车(硬失败口径);
//	· pending  = 钉版落后于 charts 已发布最高版本 ⇒ chart 侧已向前发版 ⇒ 待 bump,不阻断。
func chartPackageVerdict(releaseExists bool, gotApp, wantApp, pin, pubMax string) string {
	pinLatest := pin == "" || pubMax == "" || compareSemver(pin, pubMax) >= 0
	if !releaseExists {
		if pinLatest {
			return "missing"
		}
		return "pending"
	}
	if gotApp == wantApp {
		return "ok"
	}
	if pinLatest {
		return "mismatch"
	}
	return "pending"
}

// pushChartVersion 把 charts/Chart.yaml(version=ver, appVersion=app)推到 main,
// 由 chart-releaser(push main 触发)发版。返回是否真的推了。
func pushChartVersion(env *Env, ver, app, train string) (bool, error) {
	dir, ok := env.RepoDir("charts")
	if !ok {
		return false, fmt.Errorf("charts 检出缺失")
	}
	if _, err := Git(dir, "fetch", "-q", "origin", "main"); err != nil {
		return false, fmt.Errorf("charts fetch 失败: %w", err)
	}
	cur, err := Git(dir, "show", "origin/main:"+chartRelPath)
	if err != nil {
		return false, fmt.Errorf("charts 读 origin/main:%s 失败: %w", chartRelPath, err)
	}
	if yamlTopKey(cur, "version:") == ver && yamlTopKey(cur, "appVersion:") == app {
		return false, nil // 已对齐
	}
	if st, _ := Git(dir, "status", "--porcelain"); st != "" {
		return false, fmt.Errorf("charts 工作树不干净,拒绝提交(先人工处理):\n%s", st)
	}
	if _, err := Git(dir, "checkout", "-q", "-B", "main", "origin/main"); err != nil {
		return false, fmt.Errorf("charts 对齐 origin/main 失败: %w", err)
	}
	edited := replaceYamlTopKey(cur, "version:", ver)
	edited = replaceYamlTopKey(edited, "appVersion:", app)
	if err := os.WriteFile(filepath.Join(dir, chartRelPath), []byte(edited), 0o644); err != nil {
		return false, fmt.Errorf("charts 写 Chart.yaml 失败: %w", err)
	}
	if _, err := Git(dir, "add", chartRelPath); err != nil {
		return false, fmt.Errorf("charts add 失败: %w", err)
	}
	if _, err := Git(dir, "commit", "-qm", fmt.Sprintf("train: chart %s for v%s (app %s)", ver, train, app)); err != nil {
		return false, fmt.Errorf("charts commit 失败: %w", err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "main"); err != nil {
		return false, fmt.Errorf("charts push 失败(检查凭据): %w", err)
	}
	return true, nil
}

// waitChartRelease 等 charts 仓发布该 chart release 且**包内** appVersion 对得上。
// release 已存在但 appVersion 不符 ⇒ 立即报错(重等不会变)。
func waitChartRelease(env *Env, ver, app string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if chartReleaseExists(ver) {
			got, err := chartReleaseAppVersion(env, ver)
			if err == nil {
				if got == app {
					return nil
				}
				return fmt.Errorf("chart release %s%s 已发布但包内 appVersion=%s ≠ %s", chartReleaseTagPrefix, ver, orNone(got), app)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("等 chart release %s%s 超时(%v)(未发布)", chartReleaseTagPrefix, ver, timeout)
		}
		time.Sleep(15 * time.Second)
	}
}
