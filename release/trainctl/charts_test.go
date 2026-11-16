// charts_test.go —— chart 版本号真相源的判据(2026-11-17 新增)。
//
// 负对照(实测转红后还原):把 decideChartVersion 换成「train.yaml 旧钉版 +1」
// (旧口径 BumpPatch(pin))⇒ TestChartVersionDecision_RecomputeWhenPinBehindReality
// 转红(旧口径给出 2.0.134/2.0.133,而实况要求 2.0.136)。
package main

import (
	"fmt"
	"strings"
	"testing"
)

// 5.9.0 实录的实况:main 被写退到 2.0.133、charts 已发布最高 2.0.135、钉版 2.0.133。
func TestChartVersionDecision_RecomputeWhenPinBehindReality(t *testing.T) {
	real := chartReality{MainVer: "2.0.133", MainApp: "v5.9.0", PubMax: "2.0.135"}
	ver, reuse, err := decideChartVersion(real, "v5.9.0", "2.0.133")
	if err != nil {
		t.Fatalf("决策失败: %v", err)
	}
	if reuse {
		t.Fatal("没有承载本趟 app 的既有 release ⇒ 不该复用")
	}
	if ver != "2.0.136" {
		t.Fatalf("必须按 charts 实况重算成 2.0.136(> 已发布最高 2.0.135),实得 %s", ver)
	}
	if compareSemver(ver, real.PubMax) <= 0 {
		t.Fatalf("新版本必须严格大于 charts 已发布最高版本(%s)", real.PubMax)
	}
}

// 已有承载本趟 app 的 release ⇒ 复用(不重复发同名)。
func TestChartVersionDecision_ReuseExistingForApp(t *testing.T) {
	real := chartReality{MainVer: "2.0.136", MainApp: "v5.9.0", PubMax: "2.0.136", PubForApp: "2.0.136"}
	ver, reuse, err := decideChartVersion(real, "v5.9.0", "2.0.133")
	if err != nil {
		t.Fatalf("决策失败: %v", err)
	}
	if !reuse {
		t.Fatal("已有承载本趟 app 的 release ⇒ 必须复用(不重复发)")
	}
	if ver != "2.0.136" {
		t.Fatalf("必须指向既有 release 2.0.136,实得 %s", ver)
	}
}

// 钉版已经向前 ⇒ 沿用钉版,不重算。
func TestChartVersionDecision_KeepPinWhenAhead(t *testing.T) {
	real := chartReality{MainVer: "2.0.140", MainApp: "v5.9.0", PubMax: "2.0.139"}
	ver, reuse, err := decideChartVersion(real, "v5.9.0", "2.0.140")
	if err != nil {
		t.Fatalf("决策失败: %v", err)
	}
	if reuse {
		t.Fatal("没有既有 release ⇒ 不该复用")
	}
	if ver != "2.0.140" {
		t.Fatalf("钉版已向前 ⇒ 应沿用 2.0.140,实得 %s", ver)
	}
}

// 版本号永不倒退、永不撞名。
func TestNextChartVersion_NeverRegress(t *testing.T) {
	cases := []struct {
		main, pub, want string
	}{
		{"2.0.133", "2.0.135", "2.0.136"}, // 5.9.0 实录
		{"2.0.135", "2.0.135", "2.0.136"},
		{"2.0.140", "2.0.139", "2.0.141"},
	}
	for _, c := range cases {
		real := chartReality{MainVer: c.main, PubMax: c.pub}
		got, err := nextChartVersion(real, "v5.9.0")
		if err != nil {
			t.Fatalf("推算失败(main=%s pub=%s): %v", c.main, c.pub, err)
		}
		if got != c.want {
			t.Errorf("main=%s pub=%s: 实得 %s 期望 %s", c.main, c.pub, got, c.want)
		}
		if compareSemver(got, c.main) <= 0 || compareSemver(got, c.pub) <= 0 {
			t.Errorf("新版本必须严格大于 main(%s) 与已发布最高(%s),实得 %s", c.main, c.pub, got)
		}
	}
}

// 查不到实况 ⇒ 响亮失败(不猜版本号)。
func TestNextChartVersion_NoEvidenceFails(t *testing.T) {
	if _, err := nextChartVersion(chartReality{}, "v5.9.0"); err == nil {
		t.Fatal("charts 实况查不到时不得猜版本号")
	}
}

// 已发布 release 清单的解析(取最高版本)。
func TestChartPublishedMax(t *testing.T) {
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "releases?per_page=100") {
			return "pigeonbox-2.0.135\npigeonbox-2.0.134\npigeonbox-2.0.133\n", nil
		}
		return "", fmt.Errorf("未路由: %s", joined)
	}
	t.Cleanup(func() { ghRunner = prev })
	vers, err := chartPublishedVersions()
	if err != nil {
		t.Fatalf("取已发布清单失败: %v", err)
	}
	if len(vers) != 3 || vers[0] != "2.0.135" {
		t.Fatalf("应按版本降序取到 3 个,实得 %v", vers)
	}
	max, err := chartPublishedMax()
	if err != nil || max != "2.0.135" {
		t.Fatalf("最高版本应是 2.0.135,实得 %s(err=%v)", max, err)
	}
}

// verify 的「已发布包」判据:包在但装的是别的车 ⇒ 钉版落后时待 bump、钉版最新时硬失败;
// 证据不足 ⇒ unknown(只告警,不阻断——「未核对」≠「核对不通过」)。
func TestChartPackageVerdict(t *testing.T) {
	cases := []struct {
		name                      string
		exists                    bool
		gotApp, wantApp, pin, pub string
		known                     bool
		want                      string
	}{
		{"包在且 app 对", true, "v5.9.0", "v5.9.0", "2.0.136", "2.0.136", true, "ok"},
		{"5.9.0 实录:包在但装的是别的车(钉版落后)", true, "v5.8.0", "v5.9.0", "2.0.133", "2.0.135", true, "pending"},
		{"钉版最新但包里是别的车", true, "v5.8.0", "v5.9.0", "2.0.135", "2.0.135", true, "mismatch"},
		{"钉版最新但包没发", false, "", "v5.9.0", "2.0.136", "2.0.136", true, "missing"},
		{"钉版落后且包没发", false, "", "v5.9.0", "2.0.133", "2.0.135", true, "pending"},
		{"证据不足(读不到包内内容)⇒ 不阻断", true, "", "v5.9.0", "2.0.136", "2.0.136", false, "unknown"},
	}
	for _, c := range cases {
		got := chartPackageVerdict(c.exists, c.gotApp, c.wantApp, c.pin, c.pub, c.known)
		if got != c.want {
			t.Errorf("%s: 实得 %s 期望 %s", c.name, got, c.want)
		}
	}
}

// 已发布清单的解析必须同时吃两种形态:
//
//	① 逐行输出(当前 jq 表达式);② gh --jq 对**数组**结果的整行 JSON。
//
// ⚠ 这是 2026-11-17 CI 假红的真凶:旧解析只按行切 ⇒ 把整行当成一个版本号
// ⇒ pubMax 成垃圾串 ⇒ compareSemver 失真 ⇒ 误判「钉版已是最新」⇒ 硬失败。
func TestChartPublishedVersions_ParsesOneLineJSONArray(t *testing.T) {
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		return `["pigeonbox-2.0.135","pigeonbox-2.0.134","pigeonbox-2.0.133"]`, nil
	}
	t.Cleanup(func() { ghRunner = prev })
	vers, err := chartPublishedVersions()
	if err != nil {
		t.Fatalf("取已发布清单失败: %v", err)
	}
	if len(vers) != 3 {
		t.Fatalf("整行 JSON 数组应解析出 3 个版本,实得 %v", vers)
	}
	if vers[0] != "2.0.135" {
		t.Fatalf("应按版本降序,实得 %v", vers)
	}
	for _, v := range vers {
		if !strings.HasPrefix(v, "2.0.") || strings.ContainsAny(v, "[]\"") {
			t.Fatalf("版本号被整行污染: %q", v)
		}
	}
}

// 存在性探测:404 = 不存在(事实);其它错误 = **判据不可用**(未核对,不是「不存在」)。
// 旧实现把任何错误都当成「不存在」⇒ 一次网络抖动就报「通道里没有本趟 chart 包」。
func TestChartReleaseExists_404VsError(t *testing.T) {
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "releases/tags/pigeonbox-2.0.135") {
			return "pigeonbox-2.0.135", nil
		}
		if strings.Contains(joined, "releases/tags/pigeonbox-2.0.999") {
			return "", fmt.Errorf("gh api: Not Found (HTTP 404)")
		}
		return "", fmt.Errorf("gh api: boom")
	}
	t.Cleanup(func() { ghRunner = prev })
	if ok, err := chartReleaseExists("2.0.135"); !ok || err != nil {
		t.Fatalf("已发布的 2.0.135 应为存在且无错,实得 %v/%v", ok, err)
	}
	if ok, err := chartReleaseExists("2.0.999"); ok || err != nil {
		t.Fatalf("404 ⇒ 不存在且**不算错**,实得 %v/%v", ok, err)
	}
	if ok, err := chartReleaseExists("2.0.888"); ok || err == nil {
		t.Fatalf("查不到(非 404)⇒ 必须是「未核对」(须带错),实得 %v/%v", ok, err)
	}
}
