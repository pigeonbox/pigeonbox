package main

// verify_freshness.go 检出新鲜度的**正确口径**（2026-11-18 两处真洞的修法）。
//
// ## 洞一：浅克隆下「落后 N 提交」这个数字是假的
//
// CI 的 actions/checkout 默认 fetch-depth: 1 ⇒ 工作区是**浅克隆**。旧口径用
//
//	git rev-list --count HEAD..origin/<br>
//
// 判「检出落后」⇒ 浅边界让 git 不知道 HEAD 的祖先 ⇒ git 只能把 origin/<br>
// 的**整条主线历史**当成「HEAD 没有的提交」⇒ 该数字退化成「主线全历史长度」
// （2026-11-18 实录：986 / 991，而真值只有 5 / 15）⇒ 拿它当判据 = 拿假数字判红。
//
// 关键：**浅克隆里任何「从 HEAD 往回数」的计数都不可靠**（含 merge-base..origin/<br>
// ——排除侧同样被浅边界截断）。⇒ 提交数要么是**真值**（非浅克隆），要么
// 明确标「不可核实」，**绝不输出假数字**。
//
// ## 洞二：CI 里拿会移动的 origin/<br> 当基准本身就是竞态
//
// CI 检出的就是**本次被验证的那次提交**（事件 SHA）⇒ 主线在作业运行期间前进
// （列车发车时尤其频繁：bump / 组件 tag / ship 三个提交接连落 main）
// ⇒ 「检出落后」在 CI 下**不成立**，判红即假红。
//
// ⇒ CI 改核「检出的就是被触发的那次提交」（GITHUB_SHA）：无竞态，
// 且检出形态异常时立刻报出来。

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// behindVerdict 检出相对 origin/<br> 的落后核实结论。
type behindVerdict struct {
	// behind:工作树确实不在远端真值上（HEAD 是 origin/<br> 的**严格祖先**）。
	behind bool
	// count:落后提交数（仅 countKnown 为 true 时有效）。
	count int
	// countKnown:提交数是否可核实（浅克隆 ⇒ 不可核实 ⇒ 不得输出数字）。
	countKnown bool
	// err:核实本身失败（读不到 ≠ 一致 ⇒ 交调用方判「判据不可用」）。
	err error
}

// checkBehind 核实工作树相对 origin/<br> 是否落后。
//
// 口径（相对旧口径的三处修正）：
//
//  1. 同一 SHA ⇒ 同步（countKnown=true, behind=false）。浅克隆下也精确。
//  2. 祖先关系用 merge-base 判（走 origin/<br> 的完整历史 ⇒ 浅克隆下仍可核实）：
//     HEAD 不是 origin/<br> 的祖先（本地领先 / 分叉）⇒ 不按「落后」判
//     （与旧口径 n<=0 一致）。
//  3. 提交数只在**非浅克隆**时计算；浅克隆 ⇒ countKnown=false（见文件头洞一）。
func checkBehind(dir, br string) behindVerdict {
	ref := "origin/" + br
	head, err := Git(dir, "rev-parse", "HEAD")
	if err != nil {
		return behindVerdict{err: fmt.Errorf("rev-parse HEAD: %w", err)}
	}
	tip, err := Git(dir, "rev-parse", ref)
	if err != nil {
		return behindVerdict{err: fmt.Errorf("rev-parse %s: %w", ref, err)}
	}
	head = strings.TrimSpace(head)
	if head == strings.TrimSpace(tip) {
		return behindVerdict{countKnown: true}
	}
	mb, err := Git(dir, "merge-base", "HEAD", ref)
	if err != nil || strings.TrimSpace(mb) == "" {
		// 无共同祖先（分叉）或读不到 ⇒ 不按「落后」判。
		return behindVerdict{countKnown: true}
	}
	if strings.TrimSpace(mb) != head {
		// HEAD 不是 origin/<br> 的祖先（本地领先 / 分叉）⇒ 不是「落后」。
		return behindVerdict{countKnown: true}
	}
	// 严格落后成立。提交数是否可核实取决于仓库是否浅克隆。
	if isShallowRepo(dir) {
		return behindVerdict{behind: true}
	}
	out, err := Git(dir, "rev-list", "--count", "HEAD.."+ref)
	if err != nil {
		return behindVerdict{behind: true, err: fmt.Errorf("rev-list --count: %w", err)}
	}
	n, cerr := strconv.Atoi(strings.TrimSpace(out))
	if cerr != nil {
		return behindVerdict{behind: true, err: fmt.Errorf("rev-list 计数不可解析(%q): %w", strings.TrimSpace(out), cerr)}
	}
	return behindVerdict{behind: n > 0, count: n, countKnown: true}
}

// isShallowRepo 该仓是否为浅克隆（浅 ⇒ 落后提交数不可核实）。
func isShallowRepo(dir string) bool {
	out, err := Git(dir, "rev-parse", "--is-shallow-repository")
	return err == nil && strings.TrimSpace(out) == "true"
}

// ciCheckoutSubject CI 模式下的检出新鲜度口径。
//
// CI 的检出 = **本次被验证的那次提交**（actions/checkout 检出的就是事件 SHA）
// ⇒ 拿会移动的 origin/<br> 当基准是竞态 ⇒ 「落后」不成立、不得据此判红。
// 旧口径在这里既踩了「浅克隆假数字」（洞一）又踩了「拿会移动的 ref 当基准」
// （洞二）⇒ 6.6.0 期那次 Train Verify 就是这样红的：报「本地检出落后
// origin/main 986 提交」⇒ 1 处判据不可用 ⇒ 退出码 2 ⇒ 还误开了常驻
// train-drift issue。
//
// CI 下改核「检出的就是被触发的那次提交」（GITHUB_SHA）——无竞态；
// origin/<br> 领先只作提示（说明主线在本次作业期间前进过，不是判据问题）。
func (v *verifier) ciCheckoutSubject(dir, name, br string) {
	head, err := Git(dir, "rev-parse", "HEAD")
	if err != nil {
		return
	}
	head = strings.TrimSpace(head)
	if want := strings.TrimSpace(os.Getenv("GITHUB_SHA")); want != "" && want != head {
		v.warnCount("%s 检出的不是本次触发提交(HEAD=%s ≠ GITHUB_SHA=%s)——请确认检出形态", name, head, want)
		return
	}
	if bv := checkBehind(dir, br); bv.behind {
		v.warnCount("%s origin/%s 已领先检出(CI 检出=本次被验证的提交,不影响本次判据)", name, br)
	}
}
