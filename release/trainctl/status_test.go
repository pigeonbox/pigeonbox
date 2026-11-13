// status_test.go —— 进度面板的渲染与结论推导(spec 2026-11-13 §5/G5)。
//
// 采集(collectStatus)是网络/ git 胶水,单测只覆盖纯函数:renderStatus /
// deriveConclusion / checksSummary 的计数逻辑。
// 负对照:把 deriveConclusion 的 draft 分支删掉 ⇒ TestDeriveConclusion 转红。
package main

import (
	"errors"
	"strings"
	"testing"
)

func TestDeriveConclusion(t *testing.T) {
	cases := []struct {
		name string
		d    statusData
		want string
	}{
		{"已发货", statusData{state: "shipped"}, "已发货"},
		{"等镜像", statusData{state: "tagged"}, "等镜像(server/frontend/p2p)"},
		{"等产物", statusData{state: "tagged", imagesOK: true, missing: []string{"a", "b"}}, "等产物(2 项)"},
		{"终验中", statusData{state: "tagged", imagesOK: true}, "产物齐,等终验/收尾"},
		{"等 PR", statusData{state: "draft", openCount: 3}, "等 3 个 bump PR 合并"},
		{"等打 tag", statusData{state: "draft"}, "bump 已合,等打 tag"},
		{"未知态", statusData{state: "shipping-x"}, "state=shipping-x"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := deriveConclusion(c.d); got != c.want {
				t.Fatalf("deriveConclusion = %q, want %q", got, c.want)
			}
		})
	}
}

func TestRenderStatus_MarkdownAndPlain(t *testing.T) {
	d := statusData{
		train: "5.9.0", state: "draft", openCount: 2,
		prs:      []statusPR{{name: "frontend#112", checks: "4/4 绿", green: true}},
		imagesOK: false,
		stalled:  []string{"#240 停滞"},
		conclusion: "等 2 个 bump PR 合并",
	}
	md := renderStatus(d, true)
	for _, want := range []string{"## 🚂", "5.9.0", "state=draft", "- **卡点:** 等 2 个 bump PR 合并", "✅ frontend#112", "#240 停滞"} {
		if !strings.Contains(md, want) {
			t.Errorf("markdown 输出缺 %q:\n%s", want, md)
		}
	}
	plain := renderStatus(d, false)
	if strings.Contains(plain, "## ") {
		t.Error("plain 输出不应有 markdown 标题语法")
	}
	if !strings.Contains(plain, "══ 列车 5.9.0") {
		t.Errorf("plain 输出缺标题行:\n%s", plain)
	}
}

// checksSummary:全绿/有未绿/读失败三态(计数逻辑;checksLatest 走 ghRunner 缝)。
// 夹具用大写 conclusion:gh --json statusCheckRollup 走 GraphQL(大写枚举)。
func TestChecksSummary(t *testing.T) {
	prev := ghRunner
	ghRunner = func(args ...string) (string, error) {
		return `{"statusCheckRollup":[
			{"name":"lint","workflowName":"ci","conclusion":"SUCCESS","startedAt":"a","completedAt":"a"},
			{"name":"test","workflowName":"ci","conclusion":"FAILURE","startedAt":"b","completedAt":"b"}]}`, nil
	}
	t.Cleanup(func() { ghRunner = prev })
	s, green := checksSummary("frontend", "7")
	if green || !strings.Contains(s, "1/2") {
		t.Fatalf("有失败必须报未绿,实得 green=%v s=%q", green, s)
	}

	ghRunner = func(args ...string) (string, error) {
		return `{"statusCheckRollup":[{"name":"lint","workflowName":"ci","conclusion":"SUCCESS","startedAt":"a","completedAt":"a"}]}`, nil
	}
	t.Cleanup(func() { ghRunner = prev })
	if s, green := checksSummary("frontend", "7"); !green {
		t.Fatalf("全绿必须 green,实得 %q", s)
	}

	ghRunner = func(args ...string) (string, error) { return "", errors.New("boom") }
	t.Cleanup(func() { ghRunner = prev })
	if s, green := checksSummary("frontend", "7"); green || !strings.Contains(s, "失败") {
		t.Fatalf("读不到必须报失败且不装绿,实得 green=%v s=%q", green, s)
	}
}
