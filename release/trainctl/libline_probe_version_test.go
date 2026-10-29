package main

import (
	"strings"
	"testing"
)

// TestSemverWithV 锁住「探针传给 go / 代理的版本号**必须带 v 前缀**」这一条。
//
// 实测事故（2026-10-29，4.0.8 列车卡死实录）：
//
//	✗ 库线 lib.contracts v0.20.4 待就绪(Go 模块代理),等待中…   ← 连续 10 分钟
//	✗ 库线 lib.contracts v0.20.4 未在 … 内可消费(仍缺:Go 模块代理)
//
// 根因：`waitLibConsumable` 把版本号的 `v` 前缀 **TrimPrefix 掉**再传给探针
// ⇒ `go mod download github.com/pigeonbox/contracts@0.20.4` ⇒ go 报
// `invalid version: unknown revision 0.20.4` ⇒ 退出码非 0 ⇒ 探针把**任何**
// 版本都判成「不可消费」⇒ 库线等待空转到超时 ⇒ 整趟车卡死在阶段 0。
//
// ⇒ 关键：**连已发布很久的版本也探不到**（contracts v0.20.4 早在 10-27 就发布
// 了）⇒ 这不是「代理同步没完成」，是**探针自己测错了对象**。
//
// 交叉验证（同一时刻、真实 GitHub runner）：带 `v` 的版本号探针 0.65 秒即
// 成功（EXIT=0）⇒ 差的就是这个前缀。
func TestSemverWithV(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"0.20.4", "v0.20.4"},
		{"v0.20.4", "v0.20.4"},
		{"0.32.26", "v0.32.26"},
		{"v0.9.6", "v0.9.6"},
		{"1.0.0-rc.1", "v1.0.0-rc.1"},
		{"v1.0.0-rc.1", "v1.0.0-rc.1"},
		{"", ""},
		{"  0.20.4  ", "v0.20.4"},
	}
	for _, c := range cases {
		got := semverWithV(c.in)
		if got != c.want {
			t.Errorf("semverWithV(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

// TestProbeGoToolchain_RejectsUnprefixedVersion 证明「版本号缺 v 前缀 ⇒
// 工具链探针恒假」这条因果链，并锁住修复后的行为。
//
// ⚠️ 用**真实存在的**模块与版本（github.com/pigeonbox/contracts@v0.20.4），
// 因为要验的正是「go 认不认这个版本号」⇒ 单测要碰网络。
// 断网时本用例**跳过**（skip）而不是失败 —— 断网不该被判成「探针坏了」。
//
// 负对照的写法说明：修复**在探针内部**做规范化（semverWithV）⇒ 不管传进来的是
// 带 v 还是不带 v，探针都应判「可消费」（它测的是「go 能不能拉到」）。
// ⇒ 断言「不带 v ⇒ 探针判不可消费」是**错的**（那正是修复前的行为）。
//
// 真正的负对照在**下一条**用例里：直接验「go 认不认缺前缀的版本号」。
func TestProbeGoToolchain_NormalizesMissingVPrefix(t *testing.T) {
	const module = "github.com/pigeonbox/contracts"
	const version = "v0.20.4"

	// 前置：带 v 前缀必须能拉到（若拉不到，多半是网络/代理不可达 ⇒ skip）。
	if !probeGoToolchain(module, version) {
		t.Skipf("环境拉不到 %s@%s（网络/代理不可达）⇒ 跳过本用例", module, version)
	}

	// 修复后：缺前缀的输入也被规范化 ⇒ 同样判「可消费」（而不是恒假）。
	if !probeGoToolchain(module, strings.TrimPrefix(version, "v")) {
		t.Errorf("探针内部未规范化版本号前缀 ⇒ 缺 v 前缀时恒判「不可消费」" +
			"（2026-10-29 让 4.0.8 列车空等 10 分钟的那个 bug）")
	}
}

// TestGoToolchainRejectsUnprefixedVersion_Raw 是**真正的负对照**：直接问 go
// 工具链「缺 v 前缀的版本号算不算合法版本」⇒ 必须被拒。
//
// 这是事故的**根因证明**：go 的模块版本号要求 semver 的 `v` 前缀 ⇒
// `go mod download <mod>@0.20.4` 报 `invalid version: unknown revision 0.20.4`
// ⇒ 修复前的探针对**任何**版本都判「不可消费」。
//
// ⚠️ 同样要碰网络（要 go 真的去解析那个版本号）⇒ 断网时 skip。
func TestGoToolchainRejectsUnprefixedVersion_Raw(t *testing.T) {
	const module = "github.com/pigeonbox/contracts"
	const version = "v0.20.4"

	if !probeGoToolchain(module, version) {
		t.Skipf("环境拉不到 %s@%s（网络/代理不可达）⇒ 跳过本用例", module, version)
	}

	// 负对照：缺 v 前缀 ⇒ go 必须拒绝（这正是修复前探针恒假的原因）。
	if probeGoToolchainRaw(module, strings.TrimPrefix(version, "v")) {
		t.Errorf("go 竟然接受了缺 v 前缀的版本号 %q ⇒ 根因判断错了（"+
			"事故根因是「版本号缺 v 前缀被 go 判 invalid version」）", version)
	}
}
