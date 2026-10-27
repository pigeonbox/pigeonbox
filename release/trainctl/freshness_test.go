package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestNewestSourceTime 源码目录的「最新修改时间」判定。
func TestNewestSourceTime(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, age time.Duration) {
		t.Helper()
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("package x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		old := time.Now().Add(-age)
		if err := os.Chtimes(p, old, old); err != nil {
			t.Fatal(err)
		}
	}
	write("a.go", 2*time.Hour)
	write("b.go", time.Hour)
	write("go.mod", 3*time.Hour)
	// 非源码文件不参与
	write("README.md", time.Minute)

	newest, ok := newestSourceTime(dir)
	if !ok {
		t.Fatal("应有可参与的文件")
	}
	// 最新的是 b.go（1 小时前）
	if delta := time.Since(newest); delta < 55*time.Minute || delta > 65*time.Minute {
		t.Fatalf("最新时间判定不对: %v（期望约 1 小时前）", newest)
	}
}

// TestNewestSourceTimeMissingDir 源码目录不在旁边 ⇒ 跳过（ok=false）。
func TestNewestSourceTimeMissingDir(t *testing.T) {
	if _, ok := newestSourceTime(filepath.Join(t.TempDir(), "nope")); ok {
		t.Fatal("目录不存在时应返回 ok=false（跳过检查，不误伤）")
	}
}

// TestNewestSourceTimeEmptyDir 空目录 ⇒ 跳过。
func TestNewestSourceTimeEmptyDir(t *testing.T) {
	if _, ok := newestSourceTime(t.TempDir()); ok {
		t.Fatal("空目录应返回 ok=false")
	}
}
