// Command nobarego 扫出各仓生产代码里的**裸 `go` 语句**（机械守卫的判定核心）。
//
// 为什么要有这道门禁（2026-10-27 实录）：
//
//	裸 goroutine 的 panic **无人接** ⇒ 直接带走整个进程。PigeonBox 的三个进程
//	（p2pd 注册/信令、p2pc 直传、p2pcweb 网页直传）与 core 都是**长驻**服务
//	⇒ 一个后台协程里的 nil 解引用就能把整站/整个节点打挂。
//
//	修法不是"记得 recover"，而是用 oekit/concurrency/async 的 GoSafe 家族
//	（panic 收编 + 经全局 handler 上报，不静默）。
//
// 判定口径：**AST 级**（go/ast 的 *ast.GoStmt）——文本 grep 会把注释、字符串、
// 以及 `//go:xxx` 指令误判，也认不出 `go someFunc()` 这种非字面量形态。
//
// 用法: nobarego -root <dir> [-allow <file>:<func> …] [-skip <子目录> …]
//
//	-allow  放行项：<相对路径>:<所在函数名>，可重复（每个放行项只允许 1 处）。
//	-skip   跳过的目录名（默认跳过 vendor / node_modules / .git）。
//
// 退出码: 0 = 无裸 go；1 = 有（逐条打印）；2 = 用法/参数错。
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type allowKey struct{ file, fn string }

func main() {
	var root string
	var allows, skips multiFlag
	flag.StringVar(&root, "root", "", "仓根目录（必填）")
	flag.Var(&allows, "allow", "放行项 <相对路径>:<函数名>（可重复）")
	flag.Var(&skips, "skip", "跳过的目录名（可重复）")
	flag.Parse()
	if root == "" {
		fmt.Fprintln(os.Stderr, "用法: nobarego -root <dir> [-allow file:fn]…")
		os.Exit(2)
	}
	skipSet := map[string]bool{".git": true, "vendor": true, "node_modules": true, "bin": true, "data": true}
	for _, s := range skips {
		skipSet[s] = true
	}
	allowSet := map[allowKey]int{}
	for _, a := range allows {
		i := strings.LastIndex(a, ":")
		if i <= 0 {
			fmt.Fprintf(os.Stderr, "-allow 格式应为 <相对路径>:<函数名>，得到 %q\n", a)
			os.Exit(2)
		}
		allowSet[allowKey{file: a[:i], fn: a[i+1:]}] = 0
	}

	var violations []string
	used := map[allowKey]int{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if skipSet[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}
		rel, rerr := filepath.Rel(root, path)
		if rerr != nil {
			return nil
		}
		rel = filepath.ToSlash(rel)
		fset := token.NewFileSet()
		f, perr := parser.ParseFile(fset, path, nil, 0)
		if perr != nil {
			return nil // 解析不了的文件不判（不是本门禁的职责）
		}
		ast.Inspect(f, func(n ast.Node) bool {
			gs, ok := n.(*ast.GoStmt)
			if !ok {
				return true
			}
			fn := enclosingFunc(f, gs)
			key := allowKey{file: rel, fn: fn}
			if _, allowed := allowSet[key]; allowed {
				used[key]++
				if used[key] <= 1 {
					return true
				}
			}
			violations = append(violations, fmt.Sprintf("%s:%d  函数 %s  ⇒ 改用 async.GoSafe/GoSafeLabeled（panic 收编 + 全局 handler 上报，不静默）",
				rel, fset.Position(gs.Pos()).Line, fn))
			return true
		})
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "扫描失败: %v\n", err)
		os.Exit(2)
	}
	sort.Strings(violations)
	for _, v := range violations {
		fmt.Println(v)
	}
	if len(violations) > 0 {
		fmt.Fprintf(os.Stderr, "\n✗ 发现 %d 处裸 go 语句（裸 goroutine 的 panic 无人接 ⇒ 带走整个长驻进程）\n", len(violations))
		os.Exit(1)
	}
	fmt.Println("✓ 未发现裸 go 语句")
}

// enclosingFunc 返回节点所在的最内层函数名（取不到返回空串）。
func enclosingFunc(f *ast.File, node ast.Node) string {
	name := ""
	ast.Inspect(f, func(n ast.Node) bool {
		if name != "" {
			return false
		}
		if fd, ok := n.(*ast.FuncDecl); ok && fd.Body != nil &&
			fd.Pos() <= node.Pos() && node.End() <= fd.End() {
			name = fd.Name.Name
			return false
		}
		return true
	})
	return name
}

// multiFlag 支持重复的字符串 flag。
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}
