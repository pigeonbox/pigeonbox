// charts_test.go —— chart 版本号真相源的判据(2026-11-17 新增)。
//
// 口径:**chart 版本跟产品号同号**(本趟产品号 5.9.0 ⇒ chart 5.9.0),不再走
// charts 仓的 2.0.x 独立计数器。
//
// 负对照(实测转红后还原):
//
//	· 换回旧口径「max(main,已发布最高)+1」⇒ TestChartVersion_FollowsProductNumber
//	  转红(旧口径给出 2.0.137,而口径要求 5.9.0);
//	· 拆掉「charts main 版本更高 ⇒ 失败」的写回守卫 ⇒
//	  TestChartVersion_MainAheadFails 转红。
package main

import (
	"fmt"
	"strings"
	"testing"
)

// chart 版本**跟产品号同号**(2026-11-17 用户裁定):本趟 chart 版本 = 本趟产品号。
//
// 负对照(实测转红后还原):把 planChartVersion 换回旧口径「max(main,已发布最高)+1」
// ⇒ 5.9.0 得到 2.0.136 ⇒ TestChartVersion_FollowsProductNumber 转红。
func TestChartVersion_FollowsProductNumber(t *testing.T) {
	real := chartReality{MainVer: "2.0.136", MainApp: "v5.9.0", PubMax: "2.0.136"}
	plan, err := planChartVersion(real, "5.9.0", "v5.9.0", false, "")
	if err != nil {
		t.Fatalf("决策失败: %v", err)
	}
	if plan.Version != "5.9.0" {
		t.Fatalf("chart 版本必须跟产品号同号(=5.9.0),实得 %s", plan.Version)
	}
	if plan.Reuse {
		t.Fatal("还没发布过 ⇒ 不该复用")
	}
}

// 同名 release 已发布且承载本趟 app ⇒ 复用(幂等,不重复发)。
func TestChartVersion_ReuseWhenSameProductPublished(t *testing.T) {
	real := chartReality{MainVer: "5.9.0", MainApp: "v5.9.0", PubMax: "5.9.0"}
	plan, err := planChartVersion(real, "5.9.0", "v5.9.0", true, "v5.9.0")
	if err != nil {
		t.Fatalf("决策失败: %v", err)
	}
	if !plan.Reuse || plan.Version != "5.9.0" {
		t.Fatalf("已发布承载本趟 app ⇒ 必须复用 5.9.0,实得 %+v", plan)
	}
}

// 同名 release 已发布但装的是别的车 ⇒ 响亮失败(已发不重切)。
func TestChartVersion_SameVersionDifferentAppFails(t *testing.T) {
	real := chartReality{MainVer: "5.9.0", MainApp: "v5.9.0", PubMax: "5.9.0"}
	if _, err := planChartVersion(real, "5.9.0", "v5.9.0", true, "v5.8.0"); err == nil {
		t.Fatal("已发布的同名包装的是别的车 ⇒ 必须失败(已发不重切)")
	}
}

// charts main 的版本高于产品号 ⇒ 响亮失败(写回会把版本号改小)。
func TestChartVersion_MainAheadFails(t *testing.T) {
	real := chartReality{MainVer: "5.9.1", MainApp: "v5.9.0", PubMax: "5.9.1"}
	if _, err := planChartVersion(real, "5.9.0", "v5.9.0", false, ""); err == nil {
		t.Fatal("charts main 版本高于产品号 ⇒ 必须失败(写回会把版本号改小)")
	}
}

// 产品号为空 ⇒ 拒绝猜版本号。
func TestChartVersion_EmptyProductFails(t *testing.T) {
	if _, err := planChartVersion(chartReality{}, "", "v5.9.0", false, ""); err == nil {
		t.Fatal("产品号为空时不得猜 chart 版本号")
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
