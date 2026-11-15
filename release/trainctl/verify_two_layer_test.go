// verify_two_layer_test.go pigeonbox#363 train verify 两层判据(L-A 已发布快照 / L-B main 开发态)。
//
// 背景:单层对账把「main 正常消费已发布的更高库线版本」误报成 failure ⇒
// 连红 5 次(hub#379/#353)⇒ 告警疲劳,红了没人当真。
//
// 两层口径:
//   - L-B(soft=true,读 main go.mod):消费**已发布**的更高版本 ⇒ DRIFT_PENDING_BUMP,
//     exit 0;消费**未发布**版本或真不一致(更低) ⇒ exit 1。
//   - L-A(soft=false,读 tag 快照 go.mod):钉版 tag/SHA 矛盾 ⇒ 恒红(exit 1),
//     **不做**待 bump 降级(已发布快照必须与 train.yaml 逐字一致)。
//
// 断言全部是结构事实(pendingBumps/fails 计数、退出码、DRIFT_PENDING_BUMP 标记),
// 不依赖其余文案。
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newTaggedRepo 造一个带指定 tag 的仓:<root>/<name> 为检出,origin 指向可达裸仓
// (TagExists 走 git ls-remote origin 成功 ⇒ 不依赖网络/gh api)。
func newTaggedRepo(t *testing.T, root, name string, tags ...string) {
	t.Helper()
	origin := filepath.Join(root, name+"-origin.git")
	seed := filepath.Join(root, name+"-seed")
	runGitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
	initRepo(t, seed, "main")
	runGitIn(t, seed, "remote", "add", "origin", origin)
	runGitIn(t, seed, "push", "-q", "-u", "origin", "main")
	for _, tag := range tags {
		runGitIn(t, seed, "tag", tag)
		runGitIn(t, seed, "push", "-q", "origin", tag)
	}
	// 生产布局:<root>/<repo> 为检出(RepoDir 命中)
	runGitIn(t, root, "clone", "-q", origin, filepath.Join(root, name))
}

// newLayerVerifier 造带 train.yaml + contracts 仓的 verifier。
func newLayerVerifier(t *testing.T, contractsTags ...string) *verifier {
	t.Helper()
	root := t.TempDir()
	writeTrainFile(t, root, "train: 9.9.9\nstate: shipped\nlib.contracts: v0.23.0\nlib.core: v1.0.0\nlib.kit: v1.0.0\n")
	if len(contractsTags) > 0 {
		newTaggedRepo(t, root, "contracts", contractsTags...)
	}
	env := &Env{Root: root}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Fatal(err)
	}
	return &verifier{env: env, tf: tf}
}

// TestTwoLayer_PendingBumpIsExit0 L-B:main 消费**已发布**的更高库线版本
// (实例:core/go.mod contracts v0.24.0 vs train.yaml v0.23.0,v0.24.0 tag 已存在)
// ⇒ 输出 DRIFT_PENDING_BUMP 且整体 exit 0(不是发布不一致)。
//
// 负对照(回退修复即红):恢复旧口径 v.fail ⇒ fails==1 ⇒ 退出码 1 ⇒ 本用例红。
func TestTwoLayer_PendingBumpIsExit0(t *testing.T) {
	v := newLayerVerifier(t, "v0.23.0", "v0.24.0") // v0.24.0 已发布
	gomod := "module m\n\nrequire github.com/pigeonbox/contracts v0.24.0\n"
	out := captureStdout(t, func() {
		v.pinchk(gomod, "contracts", "v0.23.0", "core→contracts", true)
	})
	if v.pendingBumps != 1 {
		t.Fatalf("已发布的更高版本应记 1 处待 bump,实得 pendingBumps=%d fails=%d", v.pendingBumps, v.fails)
	}
	if v.fails != 0 {
		t.Fatalf("待 bump 不得计为真漂移,实得 fails=%d", v.fails)
	}
	if code := verifyExitCode(v.fails, v.unavails); code != 0 {
		t.Fatalf("整体退出码应为 0(待 bump ≠ 发布不一致),实得 %d", code)
	}
	if !strings.Contains(out, "DRIFT_PENDING_BUMP") {
		t.Fatalf("输出须含机器可识别标记 DRIFT_PENDING_BUMP,实得:\n%s", out)
	}
}

// TestTwoLayer_UnpublishedOrLowerIsExit1 L-B:消费**未发布**版本 或 真不一致(更低)
// ⇒ exit 1(不得被待 bump 放行)。
func TestTwoLayer_UnpublishedOrLowerIsExit1(t *testing.T) {
	cases := []struct {
		name, gomod, want string
	}{
		// 更高但**未发布**(contracts 仓无 v0.99.0 tag)⇒ 不是「已发布的更高版本」⇒ 红
		{"未发布更高版本", "module m\n\nrequire github.com/pigeonbox/contracts v0.99.0\n", "v0.23.0"},
		// 更低(真不一致)⇒ 红
		{"更低版本", "module m\n\nrequire github.com/pigeonbox/contracts v0.22.0\n", "v0.23.0"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := newLayerVerifier(t, "v0.23.0") // 只发布到 v0.23.0
			v.pinchk(c.gomod, "contracts", c.want, "core→contracts", true)
			if v.fails != 1 {
				t.Fatalf("应记 1 处真漂移,实得 fails=%d pendingBumps=%d", v.fails, v.pendingBumps)
			}
			if v.pendingBumps != 0 {
				t.Fatalf("未发布/更低版本不得降级为待 bump,实得 pendingBumps=%d", v.pendingBumps)
			}
			if code := verifyExitCode(v.fails, v.unavails); code != 1 {
				t.Fatalf("退出码应为 1,实得 %d", code)
			}
		})
	}
}

// TestTwoLayer_SnapshotContradictionIsRed L-A:已发布快照(tag 上 go.mod)与
// train.yaml 钉版矛盾 ⇒ 恒红(exit 1),**即使**该版本更高且已发布也不做待 bump
// 降级(快照必须逐字一致)。
//
// 这是分层的关键负对照:soft=false(L-A)与 soft=true(L-B)走不同判据。
func TestTwoLayer_SnapshotContradictionIsRed(t *testing.T) {
	v := newLayerVerifier(t, "v0.23.0", "v0.24.0")
	gomod := "module m\n\nrequire github.com/pigeonbox/contracts v0.24.0\n"
	// soft=false ⇒ L-A 快照层:不走待 bump,直接红
	v.pinchk(gomod, "contracts", "v0.23.0", "fnos@tag→contracts", false)
	if v.fails != 1 {
		t.Fatalf("L-A 快照矛盾应记 1 处真漂移,实得 fails=%d", v.fails)
	}
	if v.pendingBumps != 0 {
		t.Fatalf("L-A 不得降级为待 bump(快照须逐字一致),实得 pendingBumps=%d", v.pendingBumps)
	}
	if code := verifyExitCode(v.fails, v.unavails); code != 1 {
		t.Fatalf("L-A 快照矛盾退出码应为 1,实得 %d", code)
	}
}

// TestPinchk_ExactMatchIsOK 钉版逐字一致 ⇒ ok,不进任何失败/待 bump 计数。
func TestPinchk_ExactMatchIsOK(t *testing.T) {
	v := newLayerVerifier(t, "v0.23.0")
	gomod := "module m\n\nrequire github.com/pigeonbox/contracts v0.23.0\n"
	v.pinchk(gomod, "contracts", "v0.23.0", "core→contracts", true)
	if v.fails != 0 || v.pendingBumps != 0 || v.unavails != 0 {
		t.Fatalf("逐字一致应全绿,实得 fails=%d pendingBumps=%d unavails=%d", v.fails, v.pendingBumps, v.unavails)
	}
}

// TestTwoLayer_ChartsAheadIsPendingBump L-B charts(charts 与库线同族):
// charts main 的 Chart.yaml version **严格高于** train.yaml(chart-only PR
// 自 bump version、push 即已发布)⇒ 待 bump 且 exit 0;**严格更低** ⇒
// 真不一致(charts 没落地/回退)exit 1。
// (2026-11-15 实录:charts#25/#26/#29 把 main 推到 2.0.135,单层判据把
// 正常向前发版判红——与 #363 库线漂移同一误报族。)
func TestTwoLayer_ChartsAheadIsPendingBump(t *testing.T) {
	cases := []struct {
		name    string
		mainVer string
		pending int
		fails   int
	}{
		{"main 更高(向前发版)", "2.0.135", 1, 0},
		{"main 更低(没落地/回退)", "2.0.131", 0, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			writeTrainFile(t, root, "train: 5.8.0\nstate: shipped\ncharts.chart: \"2.0.132\"\n"+
				"charts.app: v5.8.0\nimages.server: 5.8.0\nlib.contracts: \nlib.core: \n"+
				"lib.kit: \nlib.p2p: \nlib.frontend-core: \nfrontend.tag: \n")
			// charts 仓:main 上 Chart.yaml 的 version = c.mainVer(裸仓+克隆,
			// Raw 走 FETCH_HEAD 真值,与生产同通道)
			origin := filepath.Join(root, "charts-origin.git")
			seed := filepath.Join(root, "charts-seed")
			runGitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
			initRepo(t, seed, "main")
			if err := os.MkdirAll(filepath.Join(seed, "charts", "pigeonbox"), 0o755); err != nil {
				t.Fatal(err)
			}
			writeFile(t, seed, filepath.Join("charts", "pigeonbox", "Chart.yaml"),
				"version: \""+c.mainVer+"\"\nappVersion: \"v5.8.0\"\n")
			runGitIn(t, seed, "add", "-A")
			runGitIn(t, seed, "commit", "-qm", "chart "+c.mainVer)
			runGitIn(t, seed, "remote", "add", "origin", origin)
			runGitIn(t, seed, "push", "-q", "-u", "origin", "main")
			runGitIn(t, root, "clone", "-q", origin, filepath.Join(root, "charts"))
			env := &Env{Root: root}
			tf, err := LoadTrainFile(env)
			if err != nil {
				t.Fatal(err)
			}
			v := &verifier{env: env, tf: tf, state: "shipped"}
			out := captureStdout(t, func() { v.section2Charts() })
			if v.pendingBumps != c.pending || v.fails != c.fails {
				t.Fatalf("pendingBumps/fails 应为 %d/%d,实得 %d/%d\n%s",
					c.pending, c.fails, v.pendingBumps, v.fails, out)
			}
			if code := verifyExitCode(v.fails, v.unavails); code != c.fails {
				t.Fatalf("退出码应为 %d,实得 %d", c.fails, code)
			}
			if c.pending > 0 && !strings.Contains(out, "DRIFT_PENDING_BUMP") {
				t.Fatalf("待 bump 须带机器可识别标记:\n%s", out)
			}
		})
	}
}
