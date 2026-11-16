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
// 改完后的唯一口径(2026-11-17 用户裁定:chart 不再走 2.0.x 独立计数器):
//   · **chart 版本 = 本趟产品号**(如 5.9.0)——与七终端包/镜像 tag 同一套版本面
//     (渠道里「这个包是哪一车」一眼对得上;旧口径让 chart 走自己的 2.0.x 计数器,
//      既与产品号脱节,又因此撞过已发布 release ⇒ 5.9.0 的 chart 包空产)
//   · 已发布同名 release 且**包内** appVersion == 本趟 app ⇒ 复用(幂等,不重复发)
//   · 已发布同名 release 但装的是别的车 ⇒ 响亮失败(已发不重切)
//   · charts main 的版本**严格高于**产品号 ⇒ 响亮失败(写回会把版本号改小)
//   · train.yaml 的 charts.chart 只是「本趟车期望的 chart 版本」的**投影**
//   · 「chart 包已进通道」单独查(发布物存在 + 包内 appVersion 对得上)

const chartReleaseTagPrefix = "pigeonbox-"

// chartRelPath 是 charts 仓里 Chart.yaml 的仓内路径。
const chartRelPath = "charts/pigeonbox/Chart.yaml"

// chartReality 是 charts 仓的实况。
type chartReality struct {
	MainVer string // charts/main 的 Chart.yaml version
	MainApp string // charts/main 的 Chart.yaml appVersion
	PubMax  string // charts 仓已发布 release 的最高版本(空=还没发过)
}

// chartPublishedVersions 取 charts 仓已发布的 chart release 版本号(降序)。
//
// ⚠ 解析必须能吃两种形态:gh 的 --jq 对**数组**结果会整体打成一行 JSON
// (实测:["pigeonbox-2.0.135",…] 是一行!)⇒ 只按行解析会把整串当成一个版本号,
// pubMax 变垃圾串 ⇒ 后续比较全错(2026-11-17 实录:CI 的 verify 因此误判红)。
// ⇒ jq 过滤成逐行输出,解析再兼容逗号/引号/方括号分隔。
func chartPublishedVersions() ([]string, error) {
	out, err := ghRunner("api", "repos/"+ghOrg+"/charts/releases?per_page=100",
		"--jq", `.[] | select(.tag_name|startswith("`+chartReleaseTagPrefix+`")) | .tag_name`)
	if err != nil {
		return nil, fmt.Errorf("取 charts 已发布 release 失败: %w", err)
	}
	var vers []string
	for _, part := range strings.FieldsFunc(out, func(r rune) bool {
		return r == '\n' || r == ',' || r == '"' || r == '[' || r == ']'
	}) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		vers = append(vers, strings.TrimPrefix(part, chartReleaseTagPrefix))
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
func resolveChartReality(env *Env) (chartReality, error) {
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
	if len(vers) > 0 {
		r.PubMax = vers[0]
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

// chartReleaseExists charts 仓是否已有该 release。返回 (存在, 错)。
//
// ⚠ **404 与「查不到」必须分开**(2026-11-17 实录):旧实现把任何错误都当成
// 「不存在」⇒ 一次鉴权/网络抖动就会被报成「通道里没有本趟 chart 包」的假红;
// 而「查不到」既不是「存在」也不是「不存在」⇒ 属于「未核对」,不该阻断。
//
//	· 404 / Not Found ⇒ 确实不存在(事实);
//	· 其它错误         ⇒ 判据不可用(未核对)。
func chartReleaseExists(ver string) (bool, error) {
	out, err := ghRunner("api", "repos/"+ghOrg+"/charts/releases/tags/"+chartReleaseTagPrefix+ver, "--jq", ".tag_name")
	if err != nil {
		msg := err.Error()
		if strings.Contains(msg, "404") || strings.Contains(msg, "Not Found") {
			return false, nil
		}
		return false, fmt.Errorf("查 chart release %s%s 失败: %w", chartReleaseTagPrefix, ver, err)
	}
	return strings.TrimSpace(out) != "", nil
}

// chartPlan 是「本趟 chart 版本」的决策结果。
type chartPlan struct {
	Version string // 本趟要用的 chart 版本(= 本趟产品号)
	Reuse   bool   // 已发布同名 release 且承载本趟 app ⇒ 不重复发
}

// chartReleaseStateAt 取「某个版本号的 chart release」的状态:是否存在 + 包内 appVersion。
//
// 不存在 ⇒ (false, "", nil);存在但读不到包内内容 ⇒ (true, "", err)
// ——读不到是「未核对」,不能当成「装的是别的车」(那是两种结论)。
func chartReleaseStateAt(env *Env, ver string) (bool, string, error) {
	exists, err := chartReleaseExists(ver)
	if err != nil {
		return false, "", err
	}
	if !exists {
		return false, "", nil
	}
	app, err := chartReleaseAppVersion(env, ver)
	if err != nil {
		return true, "", err
	}
	return true, app, nil
}

// planChartVersion 决定「本趟车该用哪个 chart 版本」。**纯函数**(便于表驱动单测)。
//
// 口径(2026-11-17 用户裁定:chart 版本**跟产品号同号**,不再走 2.0.x 独立计数器):
//
//	· 本趟 chart 版本 = 本趟产品号(如 5.9.0);
//	· 已发布同名 release 且**包内** appVersion == 本趟 app ⇒ 复用(幂等,不重复发);
//	· 已发布同名 release 但装的是别的车 ⇒ 响亮失败(已发不重切);
//	· charts main 的版本**严格高于**产品号 ⇒ 响亮失败(写回会把版本号改小)。
func planChartVersion(real chartReality, productVer, wantApp string, relExists bool, relApp string) (chartPlan, error) {
	if productVer == "" {
		return chartPlan{}, fmt.Errorf("产品号为空——拒绝猜 chart 版本号")
	}
	if relExists {
		if relApp == wantApp {
			return chartPlan{Version: productVer, Reuse: true}, nil
		}
		return chartPlan{}, fmt.Errorf("已发布的 chart release %s%s 装的是 %s ≠ %s(已发不重切)——请换产品号或人工裁决",
			chartReleaseTagPrefix, productVer, orNone(relApp), wantApp)
	}
	if real.MainVer != "" && compareSemver(real.MainVer, productVer) > 0 {
		return chartPlan{}, fmt.Errorf("charts main 的版本(%s)已高于本趟产品号(%s)——写回会把 charts main 的版本号改小;请人工裁决",
			real.MainVer, productVer)
	}
	return chartPlan{Version: productVer}, nil
}

// chartPackageVerdict 判定「已发布的 chart 包是否承载本趟 app」。**纯函数**。
//
// 返回 "ok" | "missing" | "mismatch" | "pending" | "unknown":
//
//	· ok       = 包在通道里且包内 appVersion 对得上;
//	· missing  = 包没发布(硬失败口径);
//	· mismatch = 包在但装的是别的车(硬失败口径);
//	· pending  = 钉版落后于 charts 已发布最高版本 ⇒ chart 侧已向前发版 ⇒ 待 bump,不阻断;
//	· unknown  = **证据不足**(清单/包内内容读不到)⇒ 只告警,**不阻断**。
//
// ⚠ 「未核对」≠「核对不通过」(2026-11-17 实录):旧实现把「拿不到证据」升格成
// 硬失败 ⇒ 一次网络抖动就把 verify 打成 exit 2,而被它盖住的是真判据。
func chartPackageVerdict(releaseExists bool, gotApp, wantApp, pin, pubMax string, evidenceKnown bool) string {
	if !evidenceKnown {
		return "unknown"
	}
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
		// ⚠ 查不到(鉴权/网络)≠ 不存在 ⇒ 不当失败,继续等到超时再报。
		if exists, xerr := chartReleaseExists(ver); xerr == nil && exists {
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
