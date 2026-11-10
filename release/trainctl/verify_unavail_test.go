// verify_unavail_test.go verify 的「判据不可用 ≠ 真漂移」显式分类回归（pigeonbox#326）。
//
// 事故形态（issue 实测）：section5 三个仓的 go.mod 一条都没拉到 ⇒ 只 warn ⇒
// verify 返回 0 ⇒ 「三个仓的钉版一条没查」被当成「对账通过」。
//
// 断言全部是结构事实（fails/unavails 计数、退出码数值），不依赖文案。
package main

import (
	"path/filepath"
	"testing"
)

// newVerifyScaffold 造最小 hub 根：train.yaml + 若干「fetch 必失败」的仓。
func newVerifyScaffold(t *testing.T, repos ...string) (*Env, *verifier) {
	t.Helper()
	root := t.TempDir()
	writeTrainFile(t, root, "train: 9.9.9\nstate: shipped\nlib.core: v1.0.0\nlib.contracts: v1.0.0\nlib.kit: v1.0.0\n")
	for _, name := range repos {
		repo := filepath.Join(root, name)
		initRepo(t, repo, "main")
		runGitIn(t, repo, "remote", "add", "origin", filepath.Join(root, "no-such-remote.git"))
	}
	env := &Env{Root: root}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Fatal(err)
	}
	return env, &verifier{env: env, tf: tf}
}

// TestVerifyExitCode 退出码显式区分「真漂移」与「判据不可用」。
func TestVerifyExitCode(t *testing.T) {
	cases := []struct {
		drifts, unavails, want int
	}{
		{0, 0, 0}, // 全绿
		{1, 0, 1}, // 真漂移 ⇒ 1
		{0, 1, 2}, // 只有判据不可用 ⇒ 2(未核对 ≠ 通过)
		{0, 5, 2},
		{1, 1, 1}, // 两者都有 ⇒ 漂移优先(要修版本)
	}
	for _, c := range cases {
		if got := verifyExitCode(c.drifts, c.unavails); got != c.want {
			t.Errorf("verifyExitCode(%d, %d) = %d, want %d", c.drifts, c.unavails, got, c.want)
		}
	}
}

// TestSection5_PullFailureIsUnavailableNotDrift 路径 B 的直接反证：
// go.mod 拉取失败 ⇒ 计「判据不可用」并让 verify 非零退出，且不得计成真漂移。
//
// 负对照（回退修复即红）：恢复旧口径 warnCount（只告警）⇒ unavails==0 ⇒ 红。
func TestSection5_PullFailureIsUnavailableNotDrift(t *testing.T) {
	env, v := newVerifyScaffold(t, "server", "core", "p2p")
	_ = env
	v.section5GoModPins()
	if v.unavails != 3 {
		t.Fatalf("三个仓 go.mod 全部拉取失败 ⇒ 应记 3 处判据不可用,实得 %d", v.unavails)
	}
	if v.fails != 0 {
		t.Fatalf("拉取失败不得计为真漂移(未核对 ≠ 不一致),实得 fails=%d", v.fails)
	}
	if code := verifyExitCode(v.fails, v.unavails); code != 2 {
		t.Fatalf("退出码应为 2(判据不可用/未核对),实得 %d", code)
	}
}

// TestSection2_PullFailureIsUnavailableNotDrift 拉取失败不得伪装成漂移:
// 旧口径把「拉取失败」计 fail(漂移),再拿空内容继续比对又产生 2 条假漂移。
func TestSection2_PullFailureIsUnavailableNotDrift(t *testing.T) {
	_, v := newVerifyScaffold(t, "charts")
	v.section2Charts()
	if v.unavails != 1 {
		t.Fatalf("charts 拉取失败 ⇒ 1 处判据不可用,实得 %d", v.unavails)
	}
	if v.fails != 0 {
		t.Fatalf("拉取失败不得计为真漂移(也不得拿空内容继续比对),实得 fails=%d", v.fails)
	}
}

// TestSection8b_PullFailureIsUnavailable 8b 节同口径:「别让列车卡在网络抖动上」
// 的旧告警口径 = 判据不可用被静默放行。
func TestSection8b_PullFailureIsUnavailable(t *testing.T) {
	_, v := newVerifyScaffold(t, "frontend", "fnos", "qnap", "openwrt")
	v.section8bContractsCopies()
	if v.unavails != 4 {
		t.Fatalf("四个 lock 全部拉取失败 ⇒ 4 处判据不可用,实得 %d", v.unavails)
	}
	if v.fails != 0 {
		t.Fatalf("拉取失败不得计为真漂移,实得 fails=%d", v.fails)
	}
}

// TestCheckoutFreshness_FetchFailureIsUnavailable 新鲜度核实自身失败
// (fetch 不动 ⇒ 无从核实) ⇒ 判据不可用,不得静默当「不落后」。
//
// 负对照（回退修复即红）：恢复 `_, _ =` 吞 fetch 错误 ⇒ unavails==0 ⇒ 红。
func TestCheckoutFreshness_FetchFailureIsUnavailable(t *testing.T) {
	_, v := newVerifyScaffold(t, "charts")
	v.checkoutFreshness()
	if v.unavails < 1 {
		t.Fatalf("fetch 失败 ⇒ 新鲜度无从核实 ⇒ 至少 1 处判据不可用,实得 %d", v.unavails)
	}
}

// TestCheckoutFreshness_HubBehindIsUnavailable hub 的判据取自**工作树**
// (deploy/nas 模板、docs、README) ⇒ 检出落后 = 判据陈旧 ⇒ 判「判据不可用」。
func TestCheckoutFreshness_HubBehindIsUnavailable(t *testing.T) {
	root, _, work := newBehindClone(t, "x", 1)
	_ = root
	v := &verifier{env: &Env{Root: work}}
	v.checkoutFreshness()
	if v.unavails != 1 {
		t.Fatalf("hub 落后 1 提交 ⇒ 1 处判据不可用,实得 unavails=%d", v.unavails)
	}
	if v.warns != 0 {
		t.Fatalf("hub 落后不得降级为告警,实得 warns=%d", v.warns)
	}
}

// TestCheckoutFreshness_ComponentBehindIsWarnOnly 组件仓的判据一律读 fetch 后
// 的远端真值(Raw=FETCH_HEAD / sync.sh 读远端),本地落后**不污染判据** ⇒ 只告警。
//
// ⚠️ 不得升级为失败:列车流程里组件仓本地检出**必然**落后(bump PR 在 GitHub 侧
// squash 合并、restoreBranches 不 pull),升级 = 每趟车终验恒红。
func TestCheckoutFreshness_ComponentBehindIsWarnOnly(t *testing.T) {
	root, _, _ := newBehindClone(t, "charts", 2)
	v := &verifier{env: &Env{Root: root}}
	v.checkoutFreshness()
	if v.warns < 1 {
		t.Fatalf("组件仓落后 ⇒ 告警,实得 warns=%d", v.warns)
	}
	if v.unavails != 0 || v.fails != 0 {
		t.Fatalf("组件仓落后不得判红(判据读远端不受影响),实得 unavails=%d fails=%d", v.unavails, v.fails)
	}
}

// newBehindClone 造「远端领先本地 behind 提交」的 origin(裸仓)+clone,
// clone 位于 <root>/<name>,返回 (root, origin, clone)。
func newBehindClone(t *testing.T, name string, behind int) (string, string, string) {
	t.Helper()
	root := t.TempDir()
	origin := filepath.Join(root, "origin.git")
	work := filepath.Join(root, name)
	runGitIn(t, root, "init", "-q", "--bare", "-b", "main", origin)
	seed := filepath.Join(root, "seed")
	initRepo(t, seed, "main")
	runGitIn(t, seed, "remote", "add", "origin", origin)
	runGitIn(t, seed, "push", "-q", "-u", "origin", "main")
	runGitIn(t, root, "clone", "-q", origin, work)
	for i := 0; i < behind; i++ {
		writeFile(t, seed, "f.txt", string(rune('a'+i))+"\n")
		runGitIn(t, seed, "add", "-A")
		runGitIn(t, seed, "commit", "-qm", "advance")
	}
	runGitIn(t, seed, "push", "-q", "origin", "main")
	return root, origin, work
}
