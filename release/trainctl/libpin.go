// libpin.go —— 库线 tag 钉版对账闸（发车前早失败；2026-11-18 实录 6.5.0 列车）。
//
// ── 要解决的问题 ──────────────────────────────────────────────
//
// lib.* 随车自动跟到「各库仓最新已发布 tag」（只升不降）。当 contracts 发了新版本，
// 而 core（**库线依赖库线**）的自身 go.mod 钉版没被抬时：
//
//	· bump 只会更新「消费型仓」（server/fnos/openwrt/qnap）的钉版——
//	  core 不在 bumpPRRepos（它无仓内版本声明，版本由 tag 决定）⇒ 它的钉版无人抬；
//	· 错位**只在终验**（verify §5 读 core main 的 go.mod）暴露——那时镜像、组件
//	  Release、平台包**全已发布**，返工代价最高。
//
// 6.5.0 实录：contracts v0.26.0 发布后随车抬版，core 仍钉 v0.25.0 ⇒ 终验报
// 「core→contracts 期望 v0.26.0(实得 0.25.0)」⇒ 列车卡在 tagged 收不了尾。
//
// ── 本闸的口径 ────────────────────────────────────────────────
//
// 落点：**库线 tag 落地的那一刻**（打 tag 前），不是终验。
// 判据：**逐字相等**——库线 tag 上声明的依赖钉版必须等于本趟解析出的库线版本。
//
//	· 更旧 ⇒ 本趟宣称的 lib.* 与产物实际声明的对不上（MVS 按消费方并集取版本，
//	  声明与事实脱节）⇒ 判红；
//	· 更新 ⇒ MVS 会把**更新版**带进最终构建 ⇒ 本趟宣称的 lib.* 是假的 ⇒ 同样判红。
//
// ⇒ 方向不是「不更旧」，是**逐字相等**。这是 AGENTS.md「库线仓自身钉版不在 bump
// 范围 ⇒ 单独提交抬钉版并发新版本号」那条规则的机器表达。
//
// ⚠️ 期望值取自**本趟解析出的库线版本**（versions map，键形如 lib.contracts），
// 不是 train.yaml：stage 0 跑在 bump 之前，train.yaml 里还写着**上一趟**的
// lib.*（用旧期望比新钉版 ⇒ 假红/假绿两头都占）。
package main

import (
	"fmt"
	"sort"
	"strings"
)

// declaredPigeonboxPins 解析 go.mod 里声明的 pigeonbox 依赖 → 版本（不带 v）。
//
// 只认**顶层**模块名（github.com/pigeonbox/<name>）。带子路径的（如
// github.com/pigeonbox/core/gen）是本仓自己的子模块，不是「对另一个库线的
// 依赖」⇒ 不并入同名顶层键（否则会把自己的子模块版本当成对 lib.core 的声明）。
func declaredPigeonboxPins(gomod string) map[string]string {
	out := map[string]string{}
	for _, m := range rePin.FindAllStringSubmatch(gomod, -1) {
		name := m[1]
		if strings.Contains(name, "/") {
			continue // 子模块路径 ⇒ 不是库线依赖
		}
		out[name] = strings.TrimPrefix(m[2], "v")
	}
	return out
}

// libPinMismatch 比对 go.mod 声明的库线依赖与本趟解析出的库线版本。
// 返回不一致描述（空串 = 一致）。
//
// 「本趟没有该库线」的依赖（如 kit 已归档 ⇒ 本趟不解析 kit）不判——不是错位，
// 是这条依赖已不在列车面内。versions 为空 ⇒ 无期望 ⇒ 全不判（只读预览路径）。
func libPinMismatch(versions map[string]string, repo, gomod string) string {
	declared := declaredPigeonboxPins(gomod)
	var bad []string
	for name, got := range declared {
		key := "lib." + name
		want := strings.TrimPrefix(versions[key], "v")
		if want == "" {
			continue // 本趟不涉及该库线（kit 已归档等）⇒ 不判
		}
		if got != want {
			bad = append(bad, fmt.Sprintf("%s 声明 %s v%s ≠ 本趟 %s=v%s", repo, name, got, key, want))
		}
	}
	if len(bad) == 0 {
		return ""
	}
	sort.Strings(bad)
	return strings.Join(bad, "; ")
}

// libGomodAt 读某仓某 ref 上的 go.mod 内容。
//
// 三态返回（内容 / 是否存在 / 错误）：
//
//	· 内容非空 ⇒ 该 ref 上有 go.mod；
//	· 不存在   ⇒ 该 ref 上**确实没有** go.mod ⇒ 这个仓不是 Go 模块（如
//	            frontend-core 是 npm 包）⇒ 没有库线依赖可对账 ⇒ 跳过；
//	· 错误     ⇒ 读不到（ref 不存在/网络故障）⇒ 判据不可用 ⇒ 必须失败
//	            （pigeonbox#326：没核对 ≠ 通过）。
//
// ref 可以是 tag 或 commit sha：本地已有该对象 ⇒ 直接读（离线可跑）；
// 否则走 env.Raw 远端抓取（本地检出缺失时用 CDN 兜底）。
func libGomodAt(env *Env, repo, ref string) (string, bool, error) {
	if dir, ok := env.RepoDir(repo); ok {
		if GitOK(dir, "cat-file", "-e", ref) {
			if !GitOK(dir, "cat-file", "-e", ref+":go.mod") {
				return "", false, nil // 该提交上没有 go.mod ⇒ 不是 Go 模块
			}
			out, err := Git(dir, "show", ref+":go.mod")
			if err != nil {
				return "", true, fmt.Errorf("读 %s %s 的 go.mod 失败: %w", repo, ref, err)
			}
			return out, true, nil
		}
	}
	out, err := env.Raw(repo + "/" + ref + "/go.mod")
	if err == nil {
		return out, true, nil
	}
	if strings.Contains(err.Error(), "HTTP 404") {
		// 远端 fetch 成功但该 ref 上没有 go.mod ⇒ 不是 Go 模块 ⇒ 跳过。
		return "", false, nil
	}
	return "", false, fmt.Errorf("读 %s %s 的 go.mod 失败: %w", repo, ref, err)
}

// assertLibPinsAt 核对「某提交/某 tag 上的 go.mod 钉版」与本趟解析出的库线版本一致。
//
// 读不到 go.mod ⇒ 响亮失败（没核对 ≠ 通过）：这正是「判据不可用必须计入失败」
// 那条纪律（pigeonbox#326）。
func assertLibPinsAt(env *Env, versions map[string]string, lr libRepo, ref string) error {
	if lr.module == "" {
		return nil // 不是 Go 模块（frontend-core 是 npm 包）⇒ 无 go.mod 可对账
	}
	gomod, exists, err := libGomodAt(env, lr.repo, ref)
	if err != nil {
		return fmt.Errorf("%s %s 的 go.mod 读不到(%v)——无法核对库线钉版对账", lr.repo, ref, err)
	}
	if !exists {
		return nil // 该 ref 上没有 go.mod ⇒ 不是 Go 模块 ⇒ 无依赖可对账
	}
	msg := libPinMismatch(versions, lr.repo, gomod)
	if msg == "" {
		return nil
	}
	return fmt.Errorf("库线钉版对账失败:%s\n"+
		"  ⇒ 本趟 lib.* 必须与库线 tag 上声明的依赖钉版逐字一致"+
		"（更旧=MVS 取并集后声明与事实脱节;更新=本趟宣称的 lib.* 是假的）\n"+
		"  ⇒ 修法:在 %s 仓抬该依赖钉版并**发新版本**（不重切旧 tag——模块代理按版本号"+
		"缓存,重打喂陈旧内容）,再 --set %s=<新版本> 重跑本趟车",
		msg, lr.repo, libSetKeyForRepo(lr.repo))
}

// libSetKeyForRepo 按仓名取 --set 的短键（contracts/core/p2p/frontend-core）；
// 取不到 ⇒ 返回空串（提示语里就不给具体键）。
func libSetKeyForRepo(repo string) string {
	for _, lr := range libRepos() {
		if lr.repo == repo {
			return libShortKey(lr.key)
		}
	}
	return ""
}
