package main

import (
	"fmt"
	"strings"
	"testing"
)

// 哨兵 issue 的「单 issue 追加」与「发货即回收」两个行为的判据。
//
// 背景（2026-10-27 清账实录）：哨兵此前**只开不关** ⇒ 每个出过停滞的列车都留
// 一个悬账（hub 悬着 3.3.3 / 1.25.1 / 1.23.0 三条 + 一条 10-07 的漂移哨兵，
// 而这些列车早已发货）；且查找用的是**标题搜索**（GitHub 搜索索引有延迟，刚建/
// 刚改的 issue 可能搜不到）⇒ 会重复新建。
//
// 负对照：把「按 label 查」写回「按标题搜」/ 去掉回收调用 ⇒ 本用例红。

// fakeGH 记录 gh 调用并按调用形态返回预设输出。
type fakeGH struct {
	calls [][]string
	// listOut 是 issue list 的返回（按 --label 命中哪个 label 返回哪段）。
	listOut map[string]string
	// listErr 非空时 issue list 直接报错。
	listErr bool
}

func (f *fakeGH) run(args ...string) (string, error) {
	f.calls = append(f.calls, args)
	if len(args) >= 2 && args[0] == "issue" && args[1] == "list" {
		if f.listErr {
			return "", fmt.Errorf("fake: list failed")
		}
		for k, v := range f.listOut {
			if hasArg(args, "--label") && hasArg(args, k) {
				return v, nil
			}
		}
		return "", nil
	}
	return "", nil
}

func hasArg(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func (f *fakeGH) has(substrs ...string) bool {
	for _, c := range f.calls {
		joined := strings.Join(c, " ")
		ok := true
		for _, s := range substrs {
			if !strings.Contains(joined, s) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

func (f *fakeGH) count(pred func([]string) bool) int {
	n := 0
	for _, c := range f.calls {
		if pred(c) {
			n++
		}
	}
	return n
}

func withFakeGH(t *testing.T, f *fakeGH) {
	t.Helper()
	prev := ghRun
	ghRun = f.run
	t.Cleanup(func() { ghRun = prev })
}

// TestStalledSentinelReusesSingleIssue：常驻哨兵必须**复用同一条** issue 追加，
// 且查找走 label（精确匹配，无搜索索引延迟）⇒ 不再按列车号增殖。
func TestStalledSentinelReusesSingleIssue(t *testing.T) {
	f := &fakeGH{listOut: map[string]string{"train-stalled": "42"}}
	withFakeGH(t, f)

	reportStalledIssue("4.0.5", []string{"fnos#120 train: bump to 4.0.5"})

	if !f.has("issue", "comment", "42") {
		t.Errorf("应对已有常驻 issue #42 追加评论，实际调用: %v", f.calls)
	}
	if f.has("issue", "create") {
		t.Errorf("不应新建 issue（常驻单条），实际调用: %v", f.calls)
	}
	if f.has("--search", "train-stalled in:title") {
		t.Errorf("查找不得用标题搜索（索引延迟会漏检→重复新建），实际调用: %v", f.calls)
	}
	if !f.has("--label", "train-stalled") {
		t.Errorf("查找应按 label 精确匹配，实际调用: %v", f.calls)
	}
}

// TestStalledSentinelCreatesWhenAbsent：没有常驻 issue 时才建一条，且标题固定
// （列车号放正文）⇒ 标题不会停在首个列车的号上。
func TestStalledSentinelCreatesWhenAbsent(t *testing.T) {
	f := &fakeGH{listOut: map[string]string{}}
	withFakeGH(t, f)

	reportStalledIssue("4.0.5", []string{"fnos#120 train: bump to 4.0.5"})

	if !f.has("issue", "create") {
		t.Errorf("无既有常驻 issue 时应新建一条，实际调用: %v", f.calls)
	}
	if f.has("--title", "🚂 train-stalled: 4.0.5 列车停滞") {
		t.Errorf("标题应固定（列车号放正文），实际调用: %v", f.calls)
	}
}

// TestCloseSentinelIssuesOnShip：列车发货时**两类**哨兵都要被关掉
// （train-stalled + train-drift）—— 这是"只开不关"缺陷的判据。
func TestCloseSentinelIssuesOnShip(t *testing.T) {
	f := &fakeGH{listOut: map[string]string{
		"train-stalled": "41\n42",
		"train-drift":   "28",
	}}
	withFakeGH(t, f)

	closeSentinelIssues("4.0.4")

	closed := f.count(func(c []string) bool { return len(c) >= 2 && c[0] == "issue" && c[1] == "close" })
	if closed != 3 {
		t.Errorf("应关闭 3 个哨兵 issue（2 停滞 + 1 漂移），实际关闭 %d 个: %v", closed, f.calls)
	}
	for _, want := range []string{"41", "42", "28"} {
		if !f.has("issue", "close", want) {
			t.Errorf("未关闭哨兵 issue #%s，实际调用: %v", want, f.calls)
		}
	}
	if !f.has("--comment") {
		t.Errorf("关闭时应带一句说明（为何可关），实际调用: %v", f.calls)
	}
}

// TestCloseSentinelIssuesTolerant：列表失败/关闭失败都只告警不阻断发车
// （issue 写权限是 best-effort：本地无 token 或 CI token 权限不足时，
// 不该拦住一次已经跑完的发布）。
func TestCloseSentinelIssuesTolerant(t *testing.T) {
	f := &fakeGH{listErr: true}
	withFakeGH(t, f)

	closeSentinelIssues("4.0.4") // 不得 panic

	f2 := &fakeGH{listOut: map[string]string{"train-stalled": "41"}}
	withFakeGH(t, f2)
	closeSentinelIssues("4.0.4") // 关闭失败也只是告警
}
