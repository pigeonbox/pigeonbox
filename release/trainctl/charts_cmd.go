package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// charts_cmd.go —— chart 补发/校正命令 + hub 侧钉版同步(2026-11-17 新增)。
//
// 场景(5.9.0 发车后审计实录):5.9.0 的 chart 版本被算成 2.0.133,撞上 11-14 已发布
// 的同名 release ⇒ 通道里没有 5.9.0 的包、charts main 的版本号还被写退。
// ⇒ 本命令按 charts 仓实况重算版本(max(main,已发布最高)+1)、推 Chart.yaml、
// 等 chart-releaser 发版、并把 hub 侧钉版(train.yaml/architecture.md/README×2)
// 同步到该版本 —— **train.yaml 仍由列车工具写**(不是人手改版本号)。

// syncChartPins 把 hub 侧的 chart 版本投影同步到 ver:
//
//	release/train.yaml 的 charts.chart + docs/architecture.md + README(.en-US) 的版本表行。
//
// ⚠ train.yaml 的 charts.chart 带引号写入(字节形态与 Render 一致 ⇒ TestRenderParity 不红)。
func syncChartPins(env *Env, ver, app, train string) error {
	dir := env.Root
	var addPaths []string

	// 1) train.yaml 的 charts.chart
	tf, err := LoadTrainFile(env)
	if err != nil {
		return err
	}
	if tf.Get("charts.chart") != ver {
		tf.Set("charts.chart", `"`+ver+`"`)
		if err := tf.Save(); err != nil {
			return fmt.Errorf("写 train.yaml 失败: %w", err)
		}
		addPaths = append(addPaths, trainFileRel)
	}

	// 2) docs/architecture.md 的 charts 行
	if arch := readContent(dir, "docs/architecture.md"); arch != "" {
		next, hit := SetTableCell3(arch, "charts", "chart "+ver+"(app v"+strings.TrimPrefix(app, "v")+")")
		if hit && next != arch {
			if err := os.WriteFile(filepath.Join(dir, "docs/architecture.md"), []byte(next), 0o644); err != nil {
				return fmt.Errorf("写 docs/architecture.md 失败: %w", err)
			}
			addPaths = append(addPaths, "docs/architecture.md")
		}
	}

	// 3) README.md / README.en-US.md 的版本表 charts 行
	for _, fname := range []string{"README.md", "README.en-US.md"} {
		content := readContent(dir, fname)
		if content == "" {
			continue
		}
		next, hit := SetReadmeVersionCell(content, "charts", chartReleaseTagPrefix+ver)
		if hit && next != content {
			if err := os.WriteFile(filepath.Join(dir, fname), []byte(next), 0o644); err != nil {
				return fmt.Errorf("写 %s 失败: %w", fname, err)
			}
			addPaths = append(addPaths, fname)
		}
	}

	if len(addPaths) == 0 {
		return nil
	}
	if _, err := Git(dir, append([]string{"add"}, addPaths...)...); err != nil {
		return fmt.Errorf("hub add 失败: %w", err)
	}
	if GitOK(dir, "diff", "--cached", "--quiet") {
		return nil
	}
	msg := fmt.Sprintf("train: chart %s for v%s (app %s)", ver, train, app)
	if _, err := Git(dir, "commit", "-qm", msg); err != nil {
		return fmt.Errorf("hub commit 失败: %w", err)
	}
	if _, err := Git(dir, "push", "-q", "origin", "main"); err != nil {
		return fmt.Errorf("hub push 失败(检查凭据): %w", err)
	}
	return nil
}

// cmdCharts 是 chart 补发/校正命令(trainctl charts TRAIN=x.y.z)。
//
// 幂等:已发布承载本趟 app 的 release ⇒ 只同步 hub 侧钉版,不重复发。
func cmdCharts(env *Env, args []string) {
	train := ""
	timeout := 15 * time.Minute
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "TRAIN="):
			train = strings.TrimPrefix(a, "TRAIN=")
		case strings.HasPrefix(a, "--timeout="):
			d, err := time.ParseDuration(strings.TrimPrefix(a, "--timeout="))
			if err != nil {
				die("--timeout 须形如 15m: %v", err)
			}
			timeout = d
		default:
			die("charts: 未知参数 %q", a)
		}
	}
	if train == "" {
		die("用法: trainctl charts TRAIN=x.y.z [--timeout=15m]")
	}
	tf, err := env.TrainFileHead()
	if err != nil {
		die("读 HEAD train.yaml 失败: %v", err)
	}
	if cur := tf.Get("train"); cur != train {
		die("train.yaml 的列车号是 %s ≠ %s(本命令只校正该列车自己的 chart)", orNone(cur), train)
	}
	app := tf.Get("charts.app")
	if app == "" {
		die("train.yaml 没有 charts.app")
	}
	real, err := resolveChartReality(env, app)
	if err != nil {
		die("charts 实况读取失败: %v", err)
	}
	headf("══ chart 校正 → %s(app %s)", train, app)
	okf("charts main: version=%s appVersion=%s", orNone(real.MainVer), orNone(real.MainApp))
	okf("charts 已发布最高: %s", orNone(real.PubMax))
	want, err := nextChartVersion(real, app)
	if err != nil {
		die("chart 版本推算失败: %v", err)
	}
	if real.PubForApp != "" {
		want = real.PubForApp
		okf("已发布 release %s%s 承载 app %s ⇒ 复用(不重复发)", chartReleaseTagPrefix, want, app)
	} else {
		okf("按实况推算: chart 版本 = %s", want)
		pushed, perr := pushChartVersion(env, want, app, train)
		if perr != nil {
			die("charts 提交失败: %v", perr)
		}
		if pushed {
			okf("charts Chart.yaml → version %s / appVersion %s 已推 main", want, app)
		} else {
			okf("charts Chart.yaml 已是 version %s / appVersion %s", want, app)
		}
		if err := waitChartRelease(env, want, app, timeout); err != nil {
			die("%v", err)
		}
		okf("chart release %s%s 已发布且包内 appVersion=%s", chartReleaseTagPrefix, want, app)
	}
	if err := syncChartPins(env, want, app, train); err != nil {
		die("同步 hub 侧 chart 钉版失败: %v", err)
	}
	okf("hub 侧 chart 钉版已同步到 %s(train.yaml/architecture.md/README)", want)
}
