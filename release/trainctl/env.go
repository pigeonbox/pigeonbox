package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ───────────────────────── 常量(v1 语义继承) ─────────────────────────

const (
	ghOrg   = "pigeonbox"
	hubRepo = "pigeonbox/pigeonbox"
	baseRaw = "https://raw.githubusercontent.com/pigeonbox"
)

// platforms 是纯 compose 物化的 NAS 打包仓(qnap 已切原生,走终端仓路径)。
var platforms = []string{"synology", "ugreen", "terramaster"}

// bumpRepos 是 bump 阶段要检出/预检的仓(hub 自身用 "." 表示)。
var bumpRepos = []string{".", "frontend", "fnos", "openwrt", "qnap", "synology", "ugreen", "terramaster", "desktop", "server"}

// defBranch 返回仓库默认分支(fnos 历史原因用 master,其余 main)。
func defBranch(repo string) string {
	if repo == "fnos" {
		return "master"
	}
	return "main"
}

// ───────────────────────── Env ─────────────────────────

// Env 是一次 trainctl 调用的运行环境:hub 根目录 + git/gh 执行器。
type Env struct {
	Root string // hub 仓根目录(含 release/train.yaml)
}

// NewEnv 从 cwd 向上探测 hub 根(含 release/train.yaml 的目录)。
// 本地布局: 模块仓在 hub 根内、desktop/charts 在兄弟目录;
// CI 布局: hub=workspace 根、其余检出到 modules/<name>。RepoDir 统一解析两种。
func NewEnv() (*Env, error) {
	wd, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	for d := wd; ; {
		if _, err := os.Stat(filepath.Join(d, "release", "train.yaml")); err == nil {
			return &Env{Root: d}, nil
		}
		parent := filepath.Dir(d)
		if parent == d {
			return nil, fmt.Errorf("未找到 hub 根(含 release/train.yaml);请在 hub 检出内运行")
		}
		d = parent
	}
}

// RepoDir 按约定解析仓库目录: <name> → ../<name> → modules/<name>。
// name="." 或 "pigeonbox"(hub 自身)返回 Root。
func (e *Env) RepoDir(name string) (string, bool) {
	if name == "." || name == "pigeonbox" {
		if isGitDir(e.Root) {
			return e.Root, true
		}
		return "", false
	}
	for _, cand := range []string{
		filepath.Join(e.Root, name),
		filepath.Join(e.Root, "..", name),
		filepath.Join(e.Root, "modules", name),
	} {
		if isGitDir(cand) {
			abs, _ := filepath.Abs(cand)
			return abs, true
		}
	}
	return "", false
}

// MustRepoDir 解析失败即退出(bump 前置要求全仓检出)。
func (e *Env) MustRepoDir(name string) string {
	d, ok := e.RepoDir(name)
	if !ok {
		die("缺 %s 检出(本地先 make setup;CI 检查 modules/ 检出步骤)", name)
	}
	return d
}

func isGitDir(d string) bool {
	st, err := os.Stat(filepath.Join(d, ".git"))
	return err == nil && (st.IsDir() || st.Mode().IsRegular()) // worktree 的 .git 是文件
}

// ───────────────────────── git / gh 执行器 ─────────────────────────

// GitTimeout 是单次 git 操作的**超时上限**。
//
// 为什么必须有（2026-11-02 实录）：git 的网络操作在链路瞬断时**会挂住**
// （ssh 层无进展 ⇒ git 不自行放弃）⇒ 没有上限时，CI 里的 fetch 会把整个
// job 拖到 6 小时上限；本地则表现为「命令无输出、一直不返回」。
// 超时优于挂死：超时是**响亮失败**（几分钟就知道），挂死是**无声卡住**。
var GitTimeout = 10 * time.Minute

// Git 在 dir 下执行 git,返回 trim 后的 stdout;失败携带 stderr。
//
// ⚠️ 带超时（GitTimeout）：见上面的说明——git 网络操作会挂住。
func Git(dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), GitTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	// ⚠️ WaitDelay 必设：CommandContext 杀掉的是 **git 本身**，但 git 起的
	// **孙子进程**（alias 里的 shell 等）仍持有 stdout/stderr 管道 ⇒
	// cmd.Wait() 会一直等这些管道关闭 ⇒ **超时形同虚设**
	// （实录：回归锁当场抓到「上限 300ms 却耗时 5.11s」——等的是孙子进程跑完）。
	// WaitDelay 让 Wait 在 ctx 结束后最多再等这么久就强行收尾返回。
	cmd.WaitDelay = 2 * time.Second
	var out, errb strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return strings.TrimSpace(out.String()), fmt.Errorf("git %s: 超时(%s)", strings.Join(args, " "), GitTimeout)
		}
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return strings.TrimSpace(out.String()), fmt.Errorf("git %s: %s", strings.Join(args, " "), msg)
	}
	return strings.TrimSpace(out.String()), nil
}

// GitOK 执行 git 只关心成功与否。
func GitOK(dir string, args ...string) bool {
	_, err := Git(dir, args...)
	return err == nil
}

// Gh 执行 gh CLI(鉴权走环境 GH_TOKEN / 本机登录态),返回 trim 后 stdout。
// ghRun 是 gh 调用的可替换缝（默认=Gh）。哨兵 issue 的开/关路径走它，
// 使「同一条常驻 issue 追加」与「发货即回收」这两个行为可被离线单测断言
// （真调 GitHub API 的行为没法在 CI 里可靠复现）。
var ghRun = Gh

func Gh(args ...string) (string, error) {
	cmd := exec.Command("gh", args...)
	var out, errb strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return strings.TrimSpace(out.String()), fmt.Errorf("gh %s: %s", strings.Join(args, " "), msg)
	}
	return strings.TrimSpace(out.String()), nil
}

// ghRunner 是 Gh 的**可替换**入口（测试用）。
//
// 为什么需要它：bump 的 commit() 会调 `gh pr create` / `gh pr merge`（真网络）
// ⇒ 端到端复现「静默空转」时无法直接驱动 commit() ⇒ 只能测它的内层
// stageTrainFiles ⇒ **双还原回归（外层再快照+还原一次）测不出来**（2026-10-25 实录：
// 内层链路单测全绿，真实 CI 仍空转）。
// ⇒ 用这个 seam 把 gh 换成桩，commit() 整条链路可在本地裸仓上真跑。
var ghRunner = Gh

// GhOK 执行 gh 只关心成功与否(如 tag 存在性探测)。
func GhOK(args ...string) bool {
	_, err := Gh(args...)
	return err == nil
}

// Run 执行任意命令(目录+环境),流式透传输出(npm/go mod tidy 等长任务)。
func Run(dir string, envExtra []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), envExtra...)
	return cmd.Run()
}

// shellCombined 在 dir 下执行命令并捕获 stdout+stderr(sync.sh check 等)。
func shellCombined(dir, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	var out strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

// runQuiet 静默执行(docker pull 兜底探测等),只关心退出码。
func runQuiet(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = nil, nil
	return cmd.Run()
}

// TagExists 探测远端 tag(git ls-remote 单点查询,不依赖本地 fetch 保鲜;
// 无本地检出回落 gh api,与 v1 tag_exists 一致)。
func (e *Env) TagExists(repo, tag string) bool {
	if dir, ok := e.RepoDir(repo); ok {
		out, err := Git(dir, "ls-remote", "--tags", "origin", "refs/tags/"+tag)
		if err == nil {
			return strings.TrimSpace(out) != ""
		}
	}
	return GhOK("api", fmt.Sprintf("repos/%s/%s/git/ref/tags/%s", ghOrg, repo, tag))
}

// Raw 读取 <repo>/<ref>/<path> 的文件内容。
// git 直读优先(origin/<ref> → <ref>),无本地检出才回落 CDN——
// raw.githubusercontent 有 ~5 分钟缓存,刚推的版本会被读成旧值(v1「版本幽灵」实锤)。
func (e *Env) Raw(spec string) (string, error) {
	repo, ref, path, err := splitRawSpec(spec)
	if err != nil {
		return "", err
	}
	if dir, ok := e.RepoDir(repo); ok {
		// ⚠️ 必须先 fetch（2026-10-23 审计）：否则读的是**本地远端引用**，
		// 对方刚落库的改动看不到 ⇒ 对账给出**假绿**（实测：contracts 钉版已从
		// v0.18.1 抬到 v0.18.4，而对账仍报「frontend-core contracts tgz =
		// v0.18.1 ✓」—— 读的是拉齐前的 origin/main）。
		// fetch 失败不阻断（离线时退回本地引用，行为同旧）。
		_, _ = Git(dir, "fetch", "-q", "origin", ref)
		if out, err := Git(dir, "show", "origin/"+ref+":"+path); err == nil {
			return out, nil
		}
		if out, err := Git(dir, "show", ref+":"+path); err == nil {
			return out, nil
		}
	}
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Get(baseRaw + "/" + repo + "/" + ref + "/" + path)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("raw %s: HTTP %d", spec, resp.StatusCode)
	}
	b := make([]byte, 0, 4096)
	buf := make([]byte, 4096)
	for {
		n, rerr := resp.Body.Read(buf)
		b = append(b, buf[:n]...)
		if rerr != nil {
			break
		}
	}
	return strings.TrimRight(string(b), "\n"), nil
}

func splitRawSpec(spec string) (repo, ref, path string, err error) {
	i := strings.Index(spec, "/")
	j := strings.Index(spec[i+1:], "/")
	if i < 0 || j < 0 {
		return "", "", "", fmt.Errorf("raw spec 须形如 repo/ref/path: %q", spec)
	}
	return spec[:i], spec[i+1 : i+1+j], spec[i+1+j+1:], nil
}

// ───────────────────────── 输出 ─────────────────────────

func okf(format string, a ...any)   { fmt.Printf("  ✓ "+format+"\n", a...) }
func warnf(format string, a ...any) { fmt.Printf("  ⚠ "+format+"\n", a...) }
func failf(format string, a ...any) { fmt.Printf("  ✗ "+format+"\n", a...) }
func headf(format string, a ...any) { fmt.Printf(format+"\n", a...) }

func splitLines(s string) []string { return strings.Split(s, "\n") }
