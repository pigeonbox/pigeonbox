package main

import (
	"strings"
	"testing"
)

func TestSetFirstJSONVersion(t *testing.T) {
	in := "{\n  \"name\": \"x\",\n  \"version\": \"1.18.0\",\n  \"deps\": {\"a\": {\"version\": \"9.9.9\"}}\n}"
	got := SetFirstJSONVersion(in, "1.19.0")
	if !strings.Contains(got, `"version": "1.19.0"`) {
		t.Fatalf("首 version 未替换: %s", got)
	}
	if !strings.Contains(got, `"version": "9.9.9"`) {
		t.Fatalf("深层 version 被误伤: %s", got)
	}
}

func TestReplaceTGZ(t *testing.T) {
	in := `"@pigeonbox/frontend-core": "https://github.com/pigeonbox/frontend-core/releases/download/v0.2.9/pigeonbox-frontend-core-0.2.9.tgz"`
	got := ReplaceTGZ(in, "frontend-core", "v0.3.0")
	want := "https://github.com/pigeonbox/frontend-core/releases/download/v0.3.0/pigeonbox-frontend-core-0.3.0.tgz"
	if !strings.Contains(got, want) {
		t.Fatalf("tgz URL 未钉到 v0.3.0: %s", got)
	}
}

func TestSetCargoVersion(t *testing.T) {
	in := "[package]\nname = \"pigeonbox-desktop\"\nversion = \"1.18.0\"\nedition = \"2021\"\n\n[dependencies]\nfoo = { version = \"2.0\" }\n"
	got := SetCargoVersion(in, "1.19.0")
	if !strings.Contains(got, "\nversion = \"1.19.0\"\n") {
		t.Fatalf("Cargo 顶层 version 未替换: %s", got)
	}
	if !strings.Contains(got, `foo = { version = "2.0" }`) {
		t.Fatalf("依赖 version 被误伤: %s", got)
	}
}

func TestManifestVersionAndChangelog(t *testing.T) {
	in := "name=pigeonbox\nversion=1.18.0\ndesc=PigeonBox\nicon=x\n"
	got := SetManifestVersion(in, "1.19.0")
	if !strings.Contains(got, "\nversion=1.19.0\n") {
		t.Fatalf("manifest version 未替换: %s", got)
	}
	got = EnsureManifestChangelog(got, "1.19.0", "v0.18.0", "v1.19.0")
	if !strings.Contains(got, "desc=PigeonBox\nchangelog=1.19.0:") {
		t.Fatalf("changelog 未插在 desc 后: %s", got)
	}
	again := EnsureManifestChangelog(got, "1.19.0", "v0.18.0", "v1.19.0")
	if again != got {
		t.Fatalf("changelog 重复插入(幂等失效)")
	}
}

func TestComposeEnvNewTag(t *testing.T) {
	if got := SetComposeImageTag("image: x\nPB_IMAGE_TAG:-v1.18.0\n", "1.19.0"); !strings.Contains(got, "PB_IMAGE_TAG:-1.19.0") {
		t.Fatalf("compose 钉版失败: %s", got)
	}
	if got := SetComposeImageTag("PB_IMAGE_TAG:-1.18.0", "1.19.0"); !strings.Contains(got, "PB_IMAGE_TAG:-1.19.0") {
		t.Fatalf("compose 无 v 前缀钉版失败: %s", got)
	}
	if got := SetEnvImageTag("# c\nPB_IMAGE_TAG=1.18.0\n", "1.19.0"); !strings.Contains(got, "\nPB_IMAGE_TAG=1.19.0\n") {
		t.Fatalf("env 钉版失败: %s", got)
	}
	got := SetNewTag("a:\n  newTag: 1.18.0\nb:\n  newTag: 1.18.0\n", "1.19.0")
	if strings.Count(got, "newTag: 1.19.0") != 2 {
		t.Fatalf("newTag 未全替换: %s", got)
	}
}

func TestSetTableCell3(t *testing.T) {
	in := "| 组件 | 版本 | 说明 |\n|---|---|---|\n| core | v0.17.0 | 业务核心 |\n| core-x | v9 | 不应命中 |\n"
	got, hit := SetTableCell3(in, "core", "v0.18.0")
	if !hit {
		t.Fatal("未命中 core 行")
	}
	if !strings.Contains(got, "| core | v0.18.0 |") {
		t.Fatalf("第三列未替换: %s", got)
	}
	if !strings.Contains(got, "| core-x | v9 |") {
		t.Fatalf("core-x 被误伤: %s", got)
	}
	if _, hit := SetTableCell3(in, "nope", "x"); hit {
		t.Fatal("不应命中")
	}
}

func TestSetTableLastCell(t *testing.T) {
	in := "| 目录 | 仓库 | 说明 | 版本 |\n|---|---|---|---|\n| `PigeonBox/` | [hub](u) | 装配仓库 | v1.18.0 |\n"
	got, hit := SetTableLastCell(in, "`PigeonBox/`", "v1.19.0")
	if !hit || !strings.Contains(got, "| v1.19.0 |") {
		t.Fatalf("末列未替换(hit=%v): %s", hit, got)
	}
	if strings.Contains(got, "v1.18.0") {
		t.Fatalf("旧值残留: %s", got)
	}
}

func TestBumpPatch(t *testing.T) {
	if got := BumpPatch("2.0.16"); got != "2.0.17" {
		t.Fatalf("2.0.16 → %s", got)
	}
	if got := BumpPatch(`"2.0.9"`); got != "2.0.10" {
		t.Fatalf("带引号 → %s", got)
	}
}

func TestRenderDepsEnv(t *testing.T) {
	got := RenderDepsEnv([][2]string{{"CORE_PIN", "v0.18.0"}, {"FRONTEND_CORE_PIN", "v0.3.0"}})
	if !strings.Contains(got, "CORE_PIN=v0.18.0\nFRONTEND_CORE_PIN=v0.3.0\n") {
		t.Fatalf("DEPS.env 渲染错误: %s", got)
	}
	if !strings.HasPrefix(got, "# 发布列车依赖钉版") {
		t.Fatalf("缺头注释: %s", got)
	}
}

// TestRenderParity 规范渲染须与在库 train.yaml(1.19.0 shipped)逐行一致,
// 仅 state 与设计稿注释行允许差异——保证 bump 幂等/对拍可信。
func TestRenderParity(t *testing.T) {
	env, err := NewEnv()
	if err != nil {
		t.Skip("非 hub 检出内运行,跳过对拍:", err)
	}
	tf, err := LoadTrainFile(env)
	if err != nil {
		t.Skipf("读 train.yaml 失败: %v", err)
	}
	rendered := Render(TrainParams{
		Train: tf.Get("train"), State: tf.Get("state"), Hotfix: tf.Get("hotfix") == "true",
		Contracts: tf.Get("lib.contracts"), Core: tf.Get("lib.core"), Kit: tf.Get("lib.kit"),
		P2P: tf.Get("lib.p2p"), FCore: tf.Get("lib.frontend-core"),
		Server: tf.Get("images.server"), FETag: tf.Get("frontend.tag"),
		Chart: tf.Get("charts.chart"), ChartApp: tf.Get("charts.app"),
		P2PC: tf.Get("terminal.desktop.p2pc"), CorePin: tf.Get("terminal.fnos.core_pin"),
		Platforms: platforms,
	})
	wantLines := splitLines(strings.TrimRight(rendered, "\n"))
	gotLines := tf.lines
	for i := 0; i < len(wantLines) || i < len(gotLines); i++ {
		var w, g string
		if i < len(wantLines) {
			w = wantLines[i]
		}
		if i < len(gotLines) {
			g = gotLines[i]
		}
		if w == g {
			continue
		}
		if strings.HasPrefix(w, "# 设计稿") && strings.HasPrefix(g, "# 设计稿") {
			continue // 设计稿行 v2 有意更新
		}
		t.Errorf("第 %d 行不一致:\n  render: %q\n  在库:   %q", i+1, w, g)
	}
}

func TestTrainFileSetState(t *testing.T) {
	tf := &TrainFile{lines: []string{"schema: \"1\"", "train: 1.19.0", "state: draft"}, m: map[string]string{"state": "draft"}}
	tf.SetState("tagged")
	if tf.Get("state") != "tagged" || tf.lines[2] != "state: tagged" {
		t.Fatalf("SetState 失败: %v", tf.lines)
	}
}
