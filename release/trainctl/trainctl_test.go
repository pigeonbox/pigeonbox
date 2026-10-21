package main

import (
	"strings"
	"testing"
)

// TestInFlightReposCoverBumpRepos 在途探测表必须覆盖 bump PR 全集。
// 漏一个仓 = 该仓的 bump 未合并时 verify 把"在途态"当"终态"硬红
// （1.24.0/1.24.1 那次列表漏项事故同型，方向相反：那次失明，这次假红）。
func TestInFlightReposCoverBumpRepos(t *testing.T) {
	have := map[string]bool{}
	for _, r := range inFlightRepos {
		have[r] = true
	}
	for _, r := range bumpPRRepos {
		if !have[r] {
			t.Errorf("在途探测表缺 %q（bumpPRRepos 有它）——该仓 bump 未合并时 verify 会假红", r)
		}
	}
	for _, r := range inFlightRepos {
		if !contains(bumpPRRepos, r) {
			t.Errorf("在途探测表多出 %q（bumpPRRepos 没有它）", r)
		}
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// TestSetCargoLockVersion 锁文件版本必须与 Cargo.toml 同步。
// 只写 Cargo.toml 会让 Cargo.lock 永远停在上一趟（实测 desktop-v2.2.0 的
// 锁文件仍写 2.0.5）——`cargo build --locked` 直接失败。
func TestSetCargoLockVersion(t *testing.T) {
	lock := `version = 4

[[package]]
name = "pigeonbox-desktop"
version = "2.0.5"
dependencies = [
 "tauri",
]

[[package]]
name = "tauri"
version = "2.8.0"
`
	got := SetCargoLockVersion(lock, "pigeonbox-desktop", "2.2.0")
	if !strings.Contains(got, `name = "pigeonbox-desktop"
version = "2.2.0"`) {
		t.Errorf("未替换目标包版本:\n%s", got)
	}
	if !strings.Contains(got, `name = "tauri"
version = "2.8.0"`) {
		t.Errorf("误改了别的包:\n%s", got)
	}
	if got == lock {
		t.Error("内容未变化")
	}
	// 目标包不存在时原样返回（不制造垃圾）
	if SetCargoLockVersion(lock, "not-exist", "2.2.0") != lock {
		t.Error("目标包不存在时应原样返回")
	}
}

// TestReplaceTGZContracts 消费方的 contracts tgz 钉版必须跟着列车走。
// 此前列车只写 frontend-core 的 tgz，contracts 那条常年停在旧版
// （实测 fnos/qnap 的 web 仍钉 v0.10.1，列车要求 v0.17.0）。
func TestReplaceTGZContracts(t *testing.T) {
	in := `{
  "dependencies": {
    "@pigeonbox/contracts": "https://github.com/pigeonbox/contracts/releases/download/v0.10.1/pigeonbox-contracts-0.10.1.tgz",
    "@pigeonbox/frontend-core": "https://github.com/pigeonbox/frontend-core/releases/download/v0.8.1/pigeonbox-frontend-core-0.8.1.tgz"
  }
}`
	got := ReplaceTGZ(ReplaceTGZ(in, "frontend-core", "v0.9.0"), "contracts", "v0.17.0")
	if !strings.Contains(got, "pigeonbox-contracts-0.17.0.tgz") ||
		!strings.Contains(got, "releases/download/v0.17.0/") {
		t.Errorf("contracts tgz 未更新:\n%s", got)
	}
	if !strings.Contains(got, "pigeonbox-frontend-core-0.9.0.tgz") {
		t.Errorf("frontend-core tgz 未更新:\n%s", got)
	}
	if strings.Contains(got, "0.10.1") {
		t.Errorf("旧 contracts 钉版残留:\n%s", got)
	}
}
