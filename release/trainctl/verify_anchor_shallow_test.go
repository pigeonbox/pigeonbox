package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// anchorGitOut 在 dir 下跑 git 并返回 stdout（失败即测试失败）。
//
// 注：trainctl 是**零第三方依赖**的工具（发布流水线要在最小镜像里跑）⇒
// 这里用标准库断言，不用 testify。
func anchorGitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v (dir=%s): %v\n%s", args, dir, err, out)
	}
	return strings.TrimSpace(string(out))
}

// anchorGitAllowFail 跑 git 并允许失败（用于断言「确实失败」的场景）。
func anchorGitAllowFail(t *testing.T, dir string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// anchorMakeOrigin 造一个 origin 仓：main 上 n 个提交；tagTag 打在第 tagAt 个提交上。
// 返回 origin 目录路径与该 tag 的提交 sha。
func anchorMakeOrigin(t *testing.T, dir, branch, tagTag string, nCommits, tagAt int) (string, string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	anchorGitOut(t, dir, "init", "-q", "-b", branch)
	anchorGitOut(t, dir, "config", "user.email", "t@example.com")
	anchorGitOut(t, dir, "config", "user.name", "t")
	var tagged string
	for i := 1; i <= nCommits; i++ {
		if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte(strings.Repeat("x", i)), 0o644); err != nil {
			t.Fatal(err)
		}
		anchorGitOut(t, dir, "add", "-A")
		anchorGitOut(t, dir, "commit", "-qm", "commit")
		if i == tagAt {
			anchorGitOut(t, dir, "tag", tagTag)
			tagged = anchorGitOut(t, dir, "rev-parse", "HEAD")
		}
	}
	return dir, tagged
}

// TestTagAnchorVerdict_ShallowCloneNoFalseNegative 复现 pigeonbox#467。
//
// 场景（2026-11-20 实录）：独立检出里各平台仓是 shallow clone，
// trainctl verify 第 11 节报「p2p tag v0.10.0 不在 origin/main 上（孤儿/错位
// tag——删 tag 重打到主线提交）」，而**同一时刻同一车次** CI 侧（完整 checkout）
// 是「0 处不一致」；加深历史后同一条命令返回 0 ——
// tag 确实落在主线上，是检出形态造成的假阴性。
//
// ⚠️ 危害不是「多一条告警」：文案让人「删 tag 重打」，照做会**删掉一个正确的
// tag** ⇒ 假红升级成真事故（已发布产物失去 tag 锚点）。
//
// 断言必须能变红（负对照）：把 tagAnchorVerdict 里的「浅克隆加深」分支去掉
// ⇒ 本用例红（verdict 变 notAnchored）。
func TestTagAnchorVerdict_ShallowCloneNoFalseNegative(t *testing.T) {
	base := t.TempDir()
	origin, _ := anchorMakeOrigin(t, filepath.Join(base, "origin"), "main", "v1.0.0", 5, 2)

	// ⚠️ 本地路径克隆会忽略 --depth ⇒ 必须走 file:// 传输才真的是浅克隆。
	shallow := filepath.Join(base, "shallow")
	anchorGitOut(t, base, "clone", "-q", "--depth", "1", "file://"+origin, shallow)

	// 与生产路径一致：先 fetch --tags（**不会**补齐被 graft 截断的主线历史）。
	anchorGitOut(t, shallow, "fetch", "-q", "--tags", "origin")
	tc := anchorGitOut(t, shallow, "rev-parse", "-q", "--verify", "refs/tags/v1.0.0^{commit}")
	if tc == "" {
		t.Fatal("tag 未取到")
	}

	// 负对照前提：此刻**裸** merge-base 必须判「不是祖先」——
	// 否则说明浅克隆没生效，本用例没复现 #467 的陷阱。
	if _, err := anchorGitAllowFail(t, shallow, "merge-base", "--is-ancestor", tc, "origin/main"); err == nil {
		t.Fatal("前提不成立：浅克隆下裸 merge-base 竟判定为祖先 ⇒ 用例没复现 pigeonbox#467")
	}

	verdict, err := tagAnchorVerdict(shallow, tc, "main")
	if verdict != anchorVerdictAnchored {
		t.Fatalf("浅克隆下明明在主线上的 tag 应判 anchored，实得 %q（err=%v）", verdict, err)
	}
}

// TestTagAnchorVerdict_RealOrphanStillNotAnchored 真孤儿 tag 仍必须判红。
//
// 这是三态改造的另一半：把「不可判定」单独拎出来，**不能**把「真漂移」
// 一起降级成不可用（否则真事故被静默放过）。
func TestTagAnchorVerdict_RealOrphanStillNotAnchored(t *testing.T) {
	base := t.TempDir()
	origin, _ := anchorMakeOrigin(t, filepath.Join(base, "origin"), "main", "v1.0.0", 3, 2)

	// 另开一条分支并在其上打 tag ⇒ 该 tag 不在 main 的历史上（真孤儿）。
	anchorGitOut(t, origin, "checkout", "-q", "-b", "orphan")
	anchorGitOut(t, origin, "config", "user.email", "t@example.com")
	anchorGitOut(t, origin, "config", "user.name", "t")
	if err := os.WriteFile(filepath.Join(origin, "orphan.txt"), []byte("o"), 0o644); err != nil {
		t.Fatal(err)
	}
	anchorGitOut(t, origin, "add", "-A")
	anchorGitOut(t, origin, "commit", "-qm", "orphan")
	anchorGitOut(t, origin, "tag", "v9.9.9")
	anchorGitOut(t, origin, "checkout", "-q", "main")

	// 完整克隆（不浅克隆）⇒ 判据可判定。
	full := filepath.Join(base, "full")
	anchorGitOut(t, base, "clone", "-q", "file://"+origin, full)
	anchorGitOut(t, full, "fetch", "-q", "--tags", "origin")
	tc := anchorGitOut(t, full, "rev-parse", "-q", "--verify", "refs/tags/v9.9.9^{commit}")

	verdict, err := tagAnchorVerdict(full, tc, "main")
	if verdict != anchorVerdictNotAnchored {
		t.Fatalf("真孤儿 tag 应判 notAnchored（判红），实得 %q（err=%v）", verdict, err)
	}
}

// TestTagAnchorVerdict_DeepenInsufficientIsUndetermined 加深成功但仍补不满历史。
//
// 这是「不可判定」的第二个来源：tag 比加深窗口还老 ⇒ 加深跑完了、历史仍被截断
// ⇒ 祖先关系依然判不出来。此时若判红，运维会去「删 tag 重打」⇒ 真事故。
//
// 用可调小的加深窗口（var 而非 const）精确构造这条路径。
func TestTagAnchorVerdict_DeepenInsufficientIsUndetermined(t *testing.T) {
	origRounds, origStep := shallowDeepenRounds, shallowDeepenStep
	shallowDeepenRounds, shallowDeepenStep = 1, 1
	defer func() { shallowDeepenRounds, shallowDeepenStep = origRounds, origStep }()

	base := t.TempDir()
	origin, _ := anchorMakeOrigin(t, filepath.Join(base, "origin"), "main", "v1.0.0", 5, 2)
	shallow := filepath.Join(base, "shallow")
	anchorGitOut(t, base, "clone", "-q", "--depth", "1", "file://"+origin, shallow)
	anchorGitOut(t, shallow, "fetch", "-q", "--tags", "origin")
	tc := anchorGitOut(t, shallow, "rev-parse", "-q", "--verify", "refs/tags/v1.0.0^{commit}")

	verdict, err := tagAnchorVerdict(shallow, tc, "main")
	if verdict != anchorVerdictUndetermined {
		t.Fatalf("加深补不满历史时应判 undetermined（判据不可用），实得 %q（err=%v）", verdict, err)
	}
}

// TestTagAnchorVerdict_UnreachableOriginIsUndetermined 远端不可达 ⇒ 不可判定。
//
// 「没核对成」≠「不一致」：此时若判红，运维会去「删 tag 重打」——
// 而真相只是网络不通 ⇒ 制造真事故。
func TestTagAnchorVerdict_UnreachableOriginIsUndetermined(t *testing.T) {
	base := t.TempDir()
	origin, _ := anchorMakeOrigin(t, filepath.Join(base, "origin"), "main", "v1.0.0", 3, 2)

	shallow := filepath.Join(base, "shallow")
	anchorGitOut(t, base, "clone", "-q", "--depth", "1", "file://"+origin, shallow)
	anchorGitOut(t, shallow, "fetch", "-q", "--tags", "origin")
	tc := anchorGitOut(t, shallow, "rev-parse", "-q", "--verify", "refs/tags/v1.0.0^{commit}")

	// 把 origin 挪走 ⇒ fetch --deepen 必然失败。
	if err := os.Rename(origin, filepath.Join(base, "origin-gone")); err != nil {
		t.Fatal(err)
	}

	verdict, err := tagAnchorVerdict(shallow, tc, "main")
	if verdict != anchorVerdictUndetermined {
		t.Fatalf("远端不可达时应判 undetermined（判据不可用），实得 %q（err=%v）", verdict, err)
	}
}
