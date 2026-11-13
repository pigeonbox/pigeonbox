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
	"net/http"
	"net/http/httptest"
	"path/filepath"
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

// breakMarkerRemotes 把带 marker 的库线仓 origin 指向不存在的路径 ⇒ Raw 的 fetch 必败。
//
// 为什么不用旧 fixture 的「main 上缺 marker 文件」构造不可用:Raw 的语义是
// 「fetch 成功但读不到该 ref 上的文件 ⇒ 走 CDN 兜底」,而 fixture 用的是**真实仓名**
// ⇒ CDN 会打到 raw.githubusercontent 上的真实仓并读到**真内容** ⇒ 测试既打真网络
// 又测不到「读不到」。fetch 失败才是 hermetic 的「拿不到远端信息」。
//
// (「远端 ref 上真没这个文件」在生产里同样落到 CDN → 404 → unavail,行为等价;
// 只是测试无法在不打真网络的前提下构造它。)
func breakMarkerRemotes(t *testing.T, env *Env) {
	t.Helper()
	for _, lr := range libRepos() {
		if lr.marker == "" {
			continue
		}
		dir, ok := env.RepoDir(lr.repo)
		if !ok {
			t.Fatalf("%s 检出缺失(脚手架坏了)", lr.repo)
		}
		gitRun(t, dir, "remote", "set-url", "origin", filepath.Join(env.Root, lr.repo+"-origin-missing"))
	}
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
//
// 不可用态由**坏远端**(fetch 必败)构造——适配 Raw 的远端语义,见 breakMarkerRemotes。
func TestMarkerAhead_UnavailableNotSilent(t *testing.T) {
	env := newLibEnv(t, map[string]map[string]string{
		"contracts": {"v0.23.0": "other.txt=x\n"},
	})
	breakMarkerRemotes(t, env)
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
	breakMarkerRemotes(t, bad)
	bv := &verifier{env: bad, tf: &TrainFile{m: map[string]string{"train": "5.8.0"}}, state: "shipped"}
	bv.section1bLibMarkerAhead()
	if bv.unavails != 2 {
		t.Errorf("读不到判据应计 2 处 failUnavailable,实得 unavails=%d fails=%d", bv.unavails, bv.fails)
	}
	if bv.fails != 0 {
		t.Errorf("读不到判据不得计真漂移: fails=%d", bv.fails)
	}
}

// ───────────────── CI 布局回归锁(2026-11-13 PR #348 首跑红) ─────────────────
//
// 真实事故:CI 的 train-verify 布局**没有** contracts/frontend-core 本地检出,
// 旧 declaredVersion 按「未检出即报错」退出 ⇒ marker-ahead 判据恒「不可用」
// ⇒ verify 必红(✗ [判据不可用] contracts 未检出…)。修法=与兄弟节一致的远端
// 抓取(env.Raw:无检出回落 CDN)。这两条锁钉住该路径,且用 httptest 假 CDN
// ——不打真网络、不依赖真仓内容。

// stubBaseRaw 把 Env.Raw 的 CDN 兜底根指到测试假 CDN(用后即还原)。
func stubBaseRaw(t *testing.T, handler http.HandlerFunc) {
	t.Helper()
	srv := httptest.NewServer(handler)
	old := baseRaw
	baseRaw = srv.URL + "/pigeonbox"
	t.Cleanup(func() {
		baseRaw = old
		srv.Close()
	})
}

// 正判据:无任何本地检出(CI train-verify 布局)⇒ 声明仍经 CDN 读到。
func TestMarkerAhead_NoLocalCheckoutReadsRemote(t *testing.T) {
	stubBaseRaw(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/pigeonbox/contracts/main/package.json":
			w.Write([]byte("{\"name\":\"@pigeonbox/contracts\",\"version\":\"0.24.0\"}"))
		case "/pigeonbox/frontend-core/main/VERSION":
			w.Write([]byte("0.19.0\n"))
		default:
			http.NotFound(w, r)
		}
	})
	env := &Env{Root: t.TempDir()} // 无任何仓检出 = CI train-verify 布局
	want := map[string]string{"contracts": "0.24.0", "frontend-core": "0.19.0"}
	for _, lr := range libRepos() {
		if lr.marker == "" {
			continue
		}
		got, err := declaredVersion(env, lr, "")
		if err != nil {
			t.Errorf("%s 无本地检出应经 CDN 读到版本声明(旧「未检出即报错」= CI 恒红): %v", lr.repo, err)
			continue
		}
		if got != want[lr.repo] {
			t.Errorf("%s 声明 = %q,期望 %q", lr.repo, got, want[lr.repo])
		}
	}
}

// fetch 与本地都拿不到(CDN 404)⇒ unavail 接线:不谎报漂移、也不算通过。
// 走 checkMarkerAheadOne 而非全量 checkMarkerAhead:declared 失败即提前返回,
// 不会落到 latestRemoteTag 的 gh api(那会打真网络)。
func TestMarkerAhead_NoCheckoutCDNFailIsUnavailable(t *testing.T) {
	stubBaseRaw(t, func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	env := &Env{Root: t.TempDir()}
	iss := checkMarkerAheadOne(env, libTestRepo(t, "contracts"))
	if iss.unavail == nil {
		t.Fatal("CDN 读不到声明应归入 unavail(failUnavailable 接线;读不到 ≠ 不漂移 ≠ 通过)")
	}
	if iss.ahead() {
		t.Errorf("unavail 不得判漂移(没拿到判据): %s", iss.msg())
	}
}
