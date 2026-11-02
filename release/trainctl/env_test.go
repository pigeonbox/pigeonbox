package main

import (
	"strings"
	"testing"
	"time"
)

// ───────────────────────── 测试脚手架 ─────────────────────────

// TestGitTimeout 断言 git 操作**有超时上限**。
//
// 为什么要有这道锁（2026-11-02 实录）：git 的网络操作在链路瞬断时**会挂住**
// （ssh 层无进展 ⇒ git 不自行放弃）⇒ 没有上限时：
//
//	· CI 里 fetch 把 job 拖到 6 小时上限（无声卡住）
//	· 本地表现为「命令无输出、一直不返回」
//
// 超时优于挂死：超时是**响亮失败**（几分钟就知道）。
//
// 手法：借 git alias 起一个 sleep 进程当"会挂住的 git"，把上限调到 300ms，
// 断言 ① 返回错误 ② 错误里有超时语义 ③ **实际耗时远小于** sleep 时长
// （证明是真超时，不是等它自己跑完）。
func TestGitTimeout(t *testing.T) {
	old := GitTimeout
	GitTimeout = 300 * time.Millisecond
	defer func() { GitTimeout = old }()

	dir := t.TempDir()
	start := time.Now()
	_, err := Git(dir, "-c", "alias.hang=!sleep 5", "hang")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("期望超时错误，得到 nil（GitTimeout=%s 未生效？）", GitTimeout)
	}
	if !strings.Contains(err.Error(), "超时") {
		t.Fatalf("期望错误含「超时」语义，得到: %v", err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("超时未生效：耗时 %s 远超上限 %s（说明是等它自己跑完的）", elapsed, GitTimeout)
	}
}

// TestGitNormalStillWorks 断言加了超时后**正常路径不受影响**。
//
// 只测超时不够：若上限写错（例如把所有 git 调用都干掉），上面那道锁也会"绿"。
func TestGitNormalStillWorks(t *testing.T) {
	old := GitTimeout
	GitTimeout = 30 * time.Second
	defer func() { GitTimeout = old }()

	dir := t.TempDir()
	out, err := Git(dir, "init", "-q")
	if err != nil {
		t.Fatalf("正常 git 调用不该失败: %v", err)
	}
	_ = out
}
