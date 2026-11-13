// cigate.go —— 打 tag 前的 CI 门禁判据(单一来源;spec 2026-11-13 §4.1)。
//
// 为什么存在:列车此前只做版本对账、不看 CI 状态 ⇒ 库线仓带着红 CI 照样发版
// (core gofmt 连续红/contracts 生成链红均实录发出过),「发版前人工 gh run list」
// 是一条靠人记的规则(AGENTS.md·门禁与发布流水线的失效形态节;2026-11-13 重构后
// 该节全文在 PigeonBox/docs/rules/ci-gate-failures.md)。本判据机械化它:
//
//	落点三处(禁止内联第二套判定,spec §6 不变量 6):
//	  preflight 基线(preflight.go) / ensureLibTag(libline.go) / runTag+pushTag(tag.go)
//
// 判定语义(「查不到 ≠ 放行」,spec §6 不变量 7):
//   - 该仓无 workflow          ⇒ pass(无 CI 可查,注记原因)
//   - 默认分支从不跑 push CI   ⇒ pass(**有证据**的放行:内容已由 bump PR checks 把关)
//   - 目标 sha 有失败 run      ⇒ 立即 red(失败不会自愈,不等)
//   - 在跑 / run 未创建        ⇒ 有界等待(cigPollEvery 轮询,cigWaitLimit 超时即红)
//   - API 错误                 ⇒ 按「等」重试,超时把最后错误带出(瞬时网络抖动不误杀)
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// 时序参数做成变量:测试覆盖为毫秒级(负对照不许真等 20s)。
var (
	cigPollEvery = 20 * time.Second
	cigWaitLimit = 10 * time.Minute
)

type cigVerdict int

const (
	cigPass cigVerdict = iota
	cigRed
	cigWait
)

// ciReq 是一条「仓 → 待打 tag 的提交」门禁请求。
type ciReq struct {
	repo, sha string
}

// assertRepoCIGreen 单仓单 sha 的门禁(waitAllCIGreen 的单元素特化)。
func assertRepoCIGreen(repo, sha string) error {
	return waitAllCIGreen([]ciReq{{repo: repo, sha: sha}})
}

// cigGate 是门禁判据的**可替换缝**(默认=assertRepoCIGreen)。
//
// 为什么需要:库线版本语义测试(libline_test)用**本地 fixture sha** 真跑
// ensureLibTag —— 真判据对 GitHub 上不存在的 sha 会「run 尚未创建」等满
// cigWaitLimit(2026-11-13 实录:全量测试 300s 超时)⇒ 这些测试在
// libTestRepo 里把缝换成直通(门禁自身由 cigate_test 全组合覆盖 +
// TestCIGateSeamDefault 钉住默认值)。
var cigGate = assertRepoCIGreen

// waitAllCIGreen 并行等待全部请求绿:单轮询共享时钟(spec §3 决策 3 —— runTag
// 对本趟全部待 tag 仓一次等齐,净增 ≤ 一轮 CI,不是 N 轮串联)。
// 任一红立即整批失败并点名;全部 pass 才返回 nil。
func waitAllCIGreen(reqs []ciReq) error {
	if len(reqs) == 0 {
		return nil
	}
	deadline := time.Now().Add(cigWaitLimit)
	pending := make(map[int]ciReq, len(reqs))
	detail := make(map[int]string, len(reqs))
	lastErr := make(map[int]error, len(reqs))
	for i, r := range reqs {
		pending[i] = r
	}
	for {
		for i, r := range pending {
			v, d, err := cigState(r.repo, defBranch(r.repo), r.sha)
			if err != nil {
				lastErr[i] = err
				detail[i] = "API 错误: " + err.Error()
				continue
			}
			lastErr[i] = nil
			detail[i] = d
			switch v {
			case cigPass:
				delete(pending, i)
				if d != "" {
					fmt.Printf("  ✓ CI 门禁 %s: %s\n", r.repo, d)
				}
			case cigRed:
				return fmt.Errorf("%s@%s CI 红——拒绝打 tag:%s(修复后重跑,列车/sweep 会接力)",
					r.repo, shaShort(r.sha), d)
			}
		}
		if len(pending) == 0 {
			return nil
		}
		if time.Now().After(deadline) {
			var lines []string
			for i := range pending {
				r := pending[i]
				if lastErr[i] != nil {
					lines = append(lines, fmt.Sprintf("%s@%s 等待超时(%v)", r.repo, shaShort(r.sha), lastErr[i]))
				} else {
					lines = append(lines, fmt.Sprintf("%s@%s 等待超时(%s)", r.repo, shaShort(r.sha), detail[i]))
				}
			}
			sort.Strings(lines)
			return fmt.Errorf("CI 门禁等待超时(%s):\n  %s", cigWaitLimit, strings.Join(lines, "\n  "))
		}
		time.Sleep(cigPollEvery)
	}
}

// cigState 单仓单 sha 的一次性判定(不等待;等待在 waitAllCIGreen 的循环里)。
func cigState(repo, def, sha string) (cigVerdict, string, error) {
	full := ghOrg + "/" + repo
	// 1) 该仓有没有 workflow
	out, err := ghRunner("api", "repos/"+full+"/actions/workflows", "--jq", ".total_count")
	if err != nil {
		return cigWait, "", err
	}
	if strings.TrimSpace(out) == "0" {
		return cigPass, "无 workflow(纯脚本仓)", nil
	}
	// 2) 默认分支有没有 push CI 先例(没有 ⇒ PR-only 仓,有证据放行)
	out, err = ghRunner("api", fmt.Sprintf("repos/%s/actions/runs?branch=%s&per_page=5", full, def), "--jq", ".total_count")
	if err != nil {
		return cigWait, "", err
	}
	if strings.TrimSpace(out) == "0" {
		return cigPass, "默认分支从不跑 push CI(PR-only,内容由 bump PR checks 把关)", nil
	}
	// 3) 目标 sha 的 run 结论(按 commit 查,不按「最新一次 run」——squash 合并
	//    到 main 是新 commit,bump PR 绿的是 PR head)
	out, err = ghRunner("api", fmt.Sprintf("repos/%s/actions/runs?head_sha=%s", full, sha),
		"--jq", `[.workflow_runs[] | {s: .status, c: (.conclusion // "")}]`)
	if err != nil {
		return cigWait, "", err
	}
	var runs []struct {
		S string `json:"s"`
		C string `json:"c"`
	}
	if err := json.Unmarshal([]byte(out), &runs); err != nil {
		return cigWait, "", fmt.Errorf("解析 %s 的 runs 失败: %w", repo, err)
	}
	if len(runs) == 0 {
		return cigWait, "run 尚未创建", nil
	}
	// 失败优先:失败不会自愈,立即红(不等在跑的那个)
	for _, r := range runs {
		switch r.C {
		case "failure", "cancelled", "timed_out", "action_required", "startup_failure":
			return cigRed, fmt.Sprintf("存在失败 run(conclusion=%s)", r.C), nil
		}
	}
	for _, r := range runs {
		if r.S != "completed" {
			return cigWait, "run 在跑", nil
		}
		switch r.C {
		case "success", "skipped", "neutral", "stale":
			// 通过(stale=被重跑取代的旧记录,不拦)
		default:
			// 未知结论:响亮判红(spec §6 不变量 7),不静默放行
			return cigRed, fmt.Sprintf("未知 run 结论 %q(按「查不到≠放行」判红)", r.C), nil
		}
	}
	return cigPass, "", nil
}
