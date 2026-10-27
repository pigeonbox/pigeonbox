package main

// trainctl 产物新鲜度守卫（2026-10-27）。
//
// ## 为什么要有这道闸
//
// `bin/trainctl` 是**未入库的本地产物**（仓根 .gitignore 里有 `/bin/`）⇒ 直接跑
// `./bin/trainctl` 可能用到**陈旧二进制**。实录（2026-10-27 发 4.0.4 列车时）：
// 12:46 编译的产物**缺了**「bump 同步改写文档站 CLI 页版本」的功能与随后的正则
// 修复 ⇒ bump 静默漏改 `docs-site/guide/cli.md` ⇒ 文档对账门禁红、那趟车卡住。
// 且失败形态是「CI 绿、PR 卡住」，很难第一眼联想到「二进制陈旧」。
//
// ## 判据：产物 mtime vs 源码 mtime
//
// 源码里最新的 .go / go.mod 比二进制还新 ⇒ 产物是旧的 ⇒ 拒绝执行并提示重建。
//
// 为什么用 mtime 而不是内容指纹：
//   - 内容指纹要额外维护「构建时指纹 ↔ 源码目录」的对应关系（stamp 文件或
//     -ldflags 注入），两者都要**改 Makefile**——而本仓的 Makefile 与 main.go
//     正被别的改动占用（本守卫刻意不碰它们，见下）；
//   - mtime 的「假阳性」是**保守方向**：切分支/拉代码后源码 mtime 变新 ⇒ 提示
//     重建 ⇒ 而此时重建本来就是对的（源码确实动过）。
// ⇒ 判据宁可多提示一次重建，不放过一次「静默漏做步骤」。
//
// ## 边界
//
//   - 找不到源码目录（容器里只拷了二进制、或别的布局）⇒ **跳过检查**（不误伤）；
//   - 二进制比源码新 ⇒ 放行；
//   - 判定为「陈旧」时只给**可执行的修复提示**，不自行重建（重建是构建期的事）。
//
// ## 为什么自成一个文件
//
// 本仓的 main.go / advance.go / bump.go 可能正被别的改动占用 ⇒ 守卫用 init()
// 挂钩（不改 main.go 的命令分发）⇒ 零冲突面。

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// srcDirName 源码目录名（相对产物所在目录的上一级）。
const srcDirName = "release/trainctl"

// init 挂钩：命令分发前先做产物新鲜度检查。
//
// 用 init() 而不改 main() 的命令分发 ⇒ 本守卫自成一个文件、与其它改动零冲突面。
func init() {
	checkSourceFreshness()
}

// checkSourceFreshness 产物新鲜度检查：源码比产物新 ⇒ 拒绝执行。
func checkSourceFreshness() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	exePath, err := filepath.EvalSymlinks(exe)
	if err != nil {
		exePath = exe
	}
	binDir := filepath.Dir(exePath)
	// <repo>/bin/trainctl ⇒ <repo>/release/trainctl
	srcDir := filepath.Join(filepath.Dir(binDir), filepath.FromSlash(srcDirName))
	newest, ok := newestSourceTime(srcDir)
	if !ok {
		return // 源码目录不在旁边 ⇒ 跳过
	}
	binInfo, err := os.Stat(exePath)
	if err != nil {
		return
	}
	if !newest.After(binInfo.ModTime()) {
		return // 产物不比源码旧 ⇒ 放行
	}
	fmt.Fprintf(os.Stderr,
		"\n[trainctl] 产物比源码旧（trainctl 是未入库的本地产物）\n"+
			"  产物: %s（%s）\n"+
			"  源码: %s（最新 %s）\n"+
			"  修法: make trainctl（重建产物）后重跑\n"+
			"  ⚠️ 陈旧产物会让 bump/advance 静默漏做某些步骤（实录：漏改文档站 CLI 页版本 ⇒ 文档对账门禁红、那趟车卡住）。\n",
		binDir, binInfo.ModTime().Format(time.RFC3339),
		srcDir, newest.Format(time.RFC3339))
	os.Exit(2)
}

// newestSourceTime 返回源码目录里最新的 .go / go.mod 的修改时间。
// 目录不存在或没有可参与的文件 ⇒ ok=false（⇒ 跳过检查）。
func newestSourceTime(dir string) (time.Time, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return time.Time{}, false
	}
	var newest time.Time
	found := false
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() {
			continue
		}
		if name != "go.mod" && !strings.HasSuffix(name, ".go") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if !found || info.ModTime().After(newest) {
			newest = info.ModTime()
			found = true
		}
	}
	return newest, found
}
