package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestTrainFileHasTrain 守卫「bump 静默空转」必须**真的**拦住错列车号。
//
// 场景（2026-10-25 实录）：切分支前把「列车管理文件」的本地改动**只还原不保存**
// ⇒ 把本波刚写好的 train.yaml 抹回 HEAD ⇒ 所有仓报「无列车变更」
// ⇒ **整趟 bump 静默空转**（列车号没推进、PR 没建、tag 没打，却返回 success）。
//
// ⇒ hub() 里加了守卫：train.yaml 必须写上目标列车号，否则响亮失败。
// 本用例是那个守卫的判据本身（负对照：判据写松 ⇒ 用例红）。
func TestTrainFileHasTrain(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, trainFileRel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	cases := []struct {
		name    string
		content string
		train   string
		want    bool
	}{
		{
			name:    "正常命中",
			content: "schema: \"1\"\ntrain: 3.3.28\nstate: draft\n",
			train:   "3.3.28",
			want:    true,
		},
		{
			name:    "旧列车号(编辑被还原)⇒ 不命中",
			content: "schema: \"1\"\ntrain: 3.3.27\nstate: draft\n",
			train:   "3.3.28",
			want:    false,
		},
		{
			// ⚠️ 子串包含的经典陷阱：判据若写成 strings.Contains(content, "train: 3.3.28")
			// ⇒ 这一行 "train: 3.3.280" 会被**误判为命中** ⇒ 守卫形同虚设。
			name:    "列车号多一位 ⇒ 不命中(子串包含会误判)",
			content: "schema: \"1\"\ntrain: 3.3.280\nstate: draft\n",
			train:   "3.3.28",
			want:    false,
		},
		{
			name:    "列车号少一位 ⇒ 不命中",
			content: "schema: \"1\"\ntrain: 3.3.2\nstate: draft\n",
			train:   "3.3.28",
			want:    false,
		},
		{
			name:    "文件缺失 ⇒ 不命中",
			content: "",
			train:   "3.3.28",
			want:    false,
		},
		{
			name:    "只有其它键 ⇒ 不命中",
			content: "schema: \"1\"\nstate: draft\n",
			train:   "3.3.28",
			want:    false,
		},
		{
			name:    "带引号的值 ⇒ 命中(值规范化后比对)",
			content: "schema: \"1\"\ntrain: \"3.3.28\"\nstate: draft\n",
			train:   "3.3.28",
			want:    true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.content == "" {
				_ = os.Remove(path)
			} else {
				write(c.content)
			}
			if got := trainFileHasTrain(dir, c.train); got != c.want {
				t.Fatalf("trainFileHasTrain(%q) = %v, 期望 %v", c.train, got, c.want)
			}
		})
	}
}

// TestRenderedTrainYAML_HasTrain bump **实际渲染**出来的 train.yaml 必须带上目标列车号。
//
// 这就是 hub() 守卫用的那个判据（内容态，非磁盘态）。为什么要单独钉：
//
//	· 守卫防的是「bump 产物与目标不符」⇒ 守卫的判据本身必须可信；
//	· 判据一旦写松（子串包含）⇒ 守卫形同虚设（负对照见上）；
//	· 判据一旦写死（读磁盘）⇒ dry-run 假红（2026-10-25 实录：bump 连预览都做不了）。
//
// 负对照：把 Render 里的 Train 传错 ⇒ 本用例红。
func TestRenderedTrainYAML_HasTrain(t *testing.T) {
	yaml := Render(TrainParams{
		Train: "3.3.28", State: "draft",
		Contracts: "v0.18.7", Core: "v0.32.10", FCore: "v0.11.21",
		Server: "3.3.28", FETag: "v3.3.28", Chart: "2.0.75", ChartApp: "v3.3.28",
		CorePin: "v0.32.10", Platforms: platforms,
	})
	if !trainYAMLHasTrain(yaml, "3.3.28") {
		t.Fatalf("渲染出的 train.yaml 必须声明列车号 3.3.28:\n%s", yaml)
	}
	// 反向：别把别的列车号当命中
	if trainYAMLHasTrain(yaml, "3.3.29") {
		t.Fatal("渲染产物不得被当成别的列车号")
	}
	// 渲染产物必须真的写进磁盘也能读回来（往返一致）
	dir := t.TempDir()
	p := filepath.Join(dir, trainFileRel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	if !trainFileHasTrain(dir, "3.3.28") {
		t.Fatal("往返后仍应识别出列车号 3.3.28")
	}
}
