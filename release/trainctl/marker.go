package main

import "fmt"

// ───────────────────────── marker-ahead:仓内已升版、tag 未发 ─────────────────────────
//
// 背景(2026-11-13 收口,contracts v0.24.0 挂 main 5 天无信号的根因):
// resolveLibVersions 只「自动跟随**已发布** tag」——仓内 package.json/VERSION
// 已抬到 0.24.0、最新 tag 还是 v0.23.0 时,解析照常跟随 v0.23.0,
// 「版本已升、tag 未发」的漂移没有任何信号,发车者也不知道该先发哪个版本。
//
// 本文件把该漂移变成显式判据:
//
//	· verify:判红并点名(带 marker 的仓**不能由列车代发 tag** ⇒ 只给人工路径:
//	  在仓内确认/抬到目标版本并合并 → 打 tag → 等资产可消费 → 再 SET=<lib>=v<版本> 钉版;
//	  #415:旧文案在这里写「用 SET=… 发车让列车发布它」⇒ 对 marker 仓是死路。
//	· run 的 [0] 阶段与 run --dry-run:同样亮出该警告(warn 不拦截——
//	  真执行路径还有 ensureLibTag 的声明断言兜底)。
//
// 语义边界:
//
//   - **只报「声明 > tag」的未发布漂移**;
//   - 「tag ≥ 声明」不报——发版流水线按 tag 覆写版本是既有设计(release.yml),
//     声明落后于 tag 属正常中间态;
//   - 拿不到远端信息(读不到声明/取不到 tag)⇒ unavail 非 nil,调用方按
//     verify 既有 failUnavailable 口径处理(读不到 ≠ 不漂移,也 ≠ 不一致)。
//
// 参与者 = 有 marker(仓内版本声明)的库线仓:contracts(package.json)与
// frontend-core(VERSION);core/p2p 无仓内声明(Go 惯例 tag 即版本)不参与。

// markerAheadIssue 是一个带 marker 的库线仓的「声明 vs 最新已发布 tag」比对结果。
type markerAheadIssue struct {
	lr       libRepo
	declared string // 仓内默认分支声明的版本(去 v 前缀)
	latest   string // 最新已发布 semver tag(带 v)
	unavail  error  // 判据不可用(读声明/取 tag 失败)——非 nil 时不算漂移也不算通过
}

// ahead 判定「声明 > 最新 tag」的未发布漂移。
func (i markerAheadIssue) ahead() bool {
	return i.unavail == nil && i.declared != "" && compareSemver("v"+i.declared, i.latest) > 0
}

// msg 构造判红/告警报文:点名仓、marker 文件、声明值、最新 tag 与**唯一可行的人工路径**。
//
// ⚠️ 本函数只服务**带 marker 的库线仓**(contracts/frontend-core)。
// 对这类仓,「用 SET=… 发车让列车代发 tag」**从来不可行**(#415):
//
//	· ensureLibTag 要求「仓内声明 == 目标版本」(libline.go)⇒ 声明没抬到目标 ⇒ 拒绝;
//	· 而声明一旦抬到目标(> 最新已发布 tag)⇒ 本判据先判红 ⇒ preflight 根本放行不了。
//
// ⇒ 两条判据夹在一起,中间没有可行区间 ⇒ 文案不能把用户往代发路径上引。
func (i markerAheadIssue) msg() string {
	return fmt.Sprintf("%s 仓内版本声明(%s)=%s > 最新已发布 tag %s——版本已升、tag 未发(未发布漂移):该仓带版本 marker(仓内声明),列车**不能代发 tag**(代发要求仓内声明==目标版本,而声明已超前于最新 tag ⇒ preflight 会先判红);请人工处理:在 %s 仓确认/抬到目标版本并合并 → 打 tag → 等资产可消费 → 再用 SET=%s=v%s 发车钉版",
		i.lr.repo, i.lr.marker, i.declared, i.latest, i.lr.repo, libShortKey(i.lr.key), i.declared)
}

// checkMarkerAhead 对每个带 marker 的库线仓做一次比对(保持 libRepos 顺序)。
func checkMarkerAhead(env *Env) []markerAheadIssue {
	var out []markerAheadIssue
	for _, lr := range libRepos() {
		if lr.marker == "" {
			continue // core/p2p:无仓内声明,无从漂移
		}
		out = append(out, checkMarkerAheadOne(env, lr))
	}
	return out
}

// checkMarkerAheadOne 比对单仓;任何一步取不到判据都归入 unavail(不吞错、不谎报)。
func checkMarkerAheadOne(env *Env, lr libRepo) markerAheadIssue {
	iss := markerAheadIssue{lr: lr}
	declared, err := declaredVersion(env, lr, "")
	if err != nil {
		iss.unavail = err
		return iss
	}
	if declared == "" {
		iss.unavail = fmt.Errorf("%s 版本声明 %s 解析为空(格式变了?)", lr.repo, lr.marker)
		return iss
	}
	latest, err := latestRemoteTag(env, lr.repo)
	if err != nil {
		iss.unavail = err
		return iss
	}
	iss.declared, iss.latest = declared, latest
	return iss
}

// printMarkerAhead 把 marker-ahead 漂移亮给 run 的 [0] 阶段与 run --dry-run 预览。
//
// 判据不可用也亮(warn):静默正是这条链路的病根——「拿不到信息」与「没有漂移」
// 必须可区分。verify 侧走 failUnavailable(退出码 2),不在此重复计数。
func printMarkerAhead(env *Env) {
	for _, iss := range checkMarkerAhead(env) {
		switch {
		case iss.unavail != nil:
			warnf("marker-ahead 判据不可用(%s): %v", iss.lr.repo, iss.unavail)
		case iss.ahead():
			warnf("%s", iss.msg())
		}
	}
}
