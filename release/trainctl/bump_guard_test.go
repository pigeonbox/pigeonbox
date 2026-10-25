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
