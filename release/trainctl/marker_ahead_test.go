// marker_ahead_test.go —— 「仓内已升版、tag 未发」漂移检测的守卫(2026-11-13 收口)。
//
// 事故根因:contracts package.json 已是 0.24.0、最新 tag 还是 v0.23.0,挂了 5 天
// 没有任何信号——库线解析只跟**已发布** tag,「声明 > tag」的未发布漂移无人察觉。
//
// 本文件钉住三条语义边界(marker.go):
//
//  1. 只报「声明 > tag」;「声明 == tag」与「tag ≥ 声明」都不报
//     (发版流水线按 tag 覆写版本是既有设计,声明落后属正常中间态);
//  2. 拿不到远端信息 ⇒ unavail(判据不可用),既不谎报漂移也不算通过;
//  3. verify 侧判红并点名(两条出路 SET=<lib>=<v> 发车 / 先发 tag),
//     unavail 走 failUnavailable(退出码 2 族),不混入真漂移计数。
//
// 负对照(实测转红后还原):
//
//	· ahead() 的 > 改成 >= ⇒ 「声明==tag」用例红(绿判据被污染);
//	· section1b 的 v.fail 改 v.ok ⇒ 判红接线用例红(漂移被静默放行);
//	· checkMarkerAhead 跳过 unavail 归类 ⇒ 不可用用例红(读不到被判成通过)。
package main

import (
	"strings"
	"testing"
)

// bumpMarkerOnOrigin 把 origin 默认分支上的 marker 文件抬到新版本(=「仓内已升版」)。
func bumpMarkerOnOrigin(t *testing.T, env *Env, repo, file, content string) {
	t.Helper()
	origin := env.Root + "/" + repo + "-origin"
	writeFile(t, origin, file, content)
	gitRun(t, origin, "add", "-A")
	gitRun(t, origin, "commit", "-qm", "bump "+file)
}

// alignedLibEnv 造「声明与 tag 对齐」的四仓现场:
// contracts package.json=0.23.0@tag v0.23.0、frontend-core VERSION=0.18.0@tag v0.18.0。
func alignedLibEnv(t *testing.T) *Env {
	t.Helper()
	return newLibEnv(t, map[string]map[string]string{
		"contracts":     {"v0.23.0": "package.json={\"name\":\"@pigeonbox/contracts\",\"version\":\"0.23.0\"}\n"},
		"frontend-core": {"v0.18.0": "VERSION=0.18.0\n"},
	})
}

// 语义边界主用例:== 不报、tag ≥ 声明不报、声明 > tag 才报(且报文点名两条出路)。
func TestMarkerAhead_OnlyDeclaredAheadReports(t *testing.T) {
	env := alignedLibEnv(t)

	// ① 对齐(声明 == tag)⇒ 不报。
	issues := checkMarkerAhead(env)
	if len(issues) != 2 {
		t.Fatalf("只有带 marker 的两仓(contracts/frontend-core)参与,实得 %d 条: %+v", len(issues), issues)
	}
	for _, iss := range issues {
		if iss.unavail != nil {
			t.Fatalf("对齐现场不该判据不可用(%s): %v", iss.lr.repo, iss.unavail)
		}
		if iss.ahead() {
			t.Errorf("声明==tag 不该判漂移(%s): %s", iss.lr.repo, iss.msg())
		}
	}

	// ② 负边界:声明 0.22.0 < tag v0.23.0(tag ≥ 声明)⇒ 不报
	//    (发版流水线按 tag 覆写版本是既有设计,声明落后是正常中间态)。
	bumpMarkerOnOrigin(t, env, "contracts", "package.json",
		"{\"name\":\"@pigeonbox/contracts\",\"version\":\"0.22.0\"}\n")
	for _, iss := range checkMarkerAhead(env) {
		if iss.lr.repo == "contracts" && iss.ahead() {
			t.Errorf("tag ≥ 声明不该报(0.22.0 < v0.23.0): %s", iss.msg())
		}
	}

	// ③ 正判据:声明 0.24.0 > tag v0.23.0(与事故同形)⇒ 报,且报文点名两条出路。
	bumpMarkerOnOrigin(t, env, "contracts", "package.json",
		"{\"name\":\"@pigeonbox/contracts\",\"version\":\"0.24.0\"}\n")
	bumpMarkerOnOrigin(t, env, "frontend-core", "VERSION", "0.19.0\n")
	issues = checkMarkerAhead(env)
	for _, iss := range issues {
		if !iss.ahead() {
			t.Errorf("声明>tag 应判漂移(%s): declared=%s latest=%s err=%v",
				iss.lr.repo, iss.declared, iss.latest, iss.unavail)
			continue
		}
		msg := iss.msg()
		for _, want := range []string{iss.lr.repo, iss.lr.marker, iss.declared, iss.latest,
			"SET=" + libShortKey(iss.lr.key) + "=v" + iss.declared, "先在 " + iss.lr.repo + " 仓发 tag"} {
			if !strings.Contains(msg, want) {
				t.Errorf("漂移报文应点名 %q: %s", want, msg)
			}
		}
	}
}

// 拿不到远端信息 ⇒ unavail(判据不可用),既不谎报漂移、也不算通过。
func TestMarkerAhead_UnavailableNotSilent(t *testing.T) {
	// contracts 的 main 上没有 package.json、frontend-core 没有 VERSION ⇒ 读不到声明。
	env := newLibEnv(t, map[string]map[string]string{
		"contracts": {"v0.23.0": "other.txt=x\n"},
	})
	issues := checkMarkerAhead(env)
	if len(issues) != 2 {
		t.Fatalf("应有两仓的比对结果,实得 %d", len(issues))
	}
	for _, iss := range issues {
		if iss.unavail == nil {
			t.Errorf("%s 读不到版本声明应归入 unavail(读不到 ≠ 不漂移)", iss.lr.repo)
		}
		if iss.ahead() {
			t.Errorf("unavail 不得判漂移(没拿到判据,不是拿到了内容): %s", iss.msg())
		}
	}
}

// verify 接线:漂移 ⇒ fails 计数(判红);对齐 ⇒ 全绿;不可用 ⇒ unavails(不混入真漂移)。
func TestSection1b_VerifyWiring(t *testing.T) {
	// ① 漂移现场:两仓都判红。
	drift := alignedLibEnv(t)
	bumpMarkerOnOrigin(t, drift, "contracts", "package.json",
		"{\"name\":\"@pigeonbox/contracts\",\"version\":\"0.24.0\"}\n")
	bumpMarkerOnOrigin(t, drift, "frontend-core", "VERSION", "0.19.0\n")
	v := &verifier{env: drift, tf: &TrainFile{m: map[string]string{"train": "5.8.0"}}, state: "shipped"}
	v.section1bLibMarkerAhead()
	if v.fails != 2 {
		t.Errorf("两仓漂移都应判红: fails=%d unavails=%d", v.fails, v.unavails)
	}
	if v.unavails != 0 {
		t.Errorf("漂移是真失败,不该混入判据不可用: unavails=%d", v.unavails)
	}

	// ② 对齐全绿。
	green := alignedLibEnv(t)
	gv := &verifier{env: green, tf: &TrainFile{m: map[string]string{"train": "5.8.0"}}, state: "shipped"}
	gv.section1bLibMarkerAhead()
	if gv.fails != 0 || gv.unavails != 0 {
		t.Errorf("对齐现场应全绿: fails=%d unavails=%d", gv.fails, gv.unavails)
	}

	// ③ 判据不可用 ⇒ unavails(退出码 2 族),不谎报成真漂移、也不静默通过。
	bad := newLibEnv(t, map[string]map[string]string{
		"contracts": {"v0.23.0": "other.txt=x\n"},
	})
	bv := &verifier{env: bad, tf: &TrainFile{m: map[string]string{"train": "5.8.0"}}, state: "shipped"}
	bv.section1bLibMarkerAhead()
	if bv.unavails != 2 {
		t.Errorf("读不到判据应计 2 处 failUnavailable,实得 unavails=%d fails=%d", bv.unavails, bv.fails)
	}
	if bv.fails != 0 {
		t.Errorf("读不到判据不得计真漂移: fails=%d", bv.fails)
	}
}
