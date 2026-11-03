package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"testing"
)

// TestLockContractsSingleCopyWired 守卫：单副本收敛必须**真的接进** bump 的三个消费仓
// （frontend 壳 / fnos / native 平台仓），否则 hub#274 的坑会以「代码在、但没接线」
// 的形态复发——这类退化编译器与单测都抓不到（纯函数测的是函数本身）。
//
// 判据按**调用点**统计（不是按函数名出现次数）：函数定义不算调用点。
// 负对照：把 native() 里那行调用删掉 ⇒ 本用例红。
func TestLockContractsSingleCopyWired(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "bump.go", nil, 0)
	if err != nil {
		t.Fatalf("解析 bump.go 失败: %v", err)
	}
	calls := map[string]int{}
	for _, decl := range f.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok {
			continue
		}
		ast.Inspect(fn, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			switch fun := call.Fun.(type) {
			case *ast.Ident:
				if fun.Name == "lockContractsSingleCopy" {
					calls[fn.Name.Name]++
				}
			case *ast.SelectorExpr:
				if fun.Sel.Name == "lockContractsSingleCopy" {
					calls[fn.Name.Name]++
				}
			}
			return true
		})
	}
	// 三个消费仓各一处调用点。
	for _, want := range []string{"frontend", "fnos", "native"} {
		if calls[want] == 0 {
			t.Fatalf("%s() 里没有调 lockContractsSingleCopy ⇒ 单副本收敛没接线（hub#274 会复发）。实测调用点分布: %v", want, calls)
		}
	}
}

// TestLockRefreshIsNotTheOnlyGuard 守卫：lockRefresh（npm install --package-lock-only）
// **不能**被当成单副本的保证——它只会重新生成嵌套条目，不剪。
//
// 背景（2026-11-03 实测）：`npm install --package-lock-only` 在 fc 钉旧 contracts
// 时**照样**产出嵌套条目 ⇒ 只靠 lockRefresh ⇒ 终验必红 ⇒ 列车卡死。
// ⇒ 这条守卫把「实测结论」钉进代码：谁把 lockContractsSingleCopy 摘掉、只留
// lockRefresh，本用例红。
func TestLockRefreshIsNotTheOnlyGuard(t *testing.T) {
	src, err := os.ReadFile("bump.go")
	if err != nil {
		t.Fatalf("读 bump.go 失败: %v", err)
	}
	text := string(src)
	if !containsText(text, "b.lockContractsSingleCopy(") {
		t.Fatalf("bump.go 里没有 b.lockContractsSingleCopy( 调用 ⇒ 单副本收敛没接线")
	}
	if !containsText(text, "func (b *bumper) lockContractsSingleCopy(") {
		t.Fatalf("lockContractsSingleCopy 的实现不见了")
	}
}

func containsText(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
