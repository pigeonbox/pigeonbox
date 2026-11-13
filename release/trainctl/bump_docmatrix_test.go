// bump_docmatrix_test.go —— architecture.md 文档矩阵行表与真实文件对齐守卫。
//
// 背景（2026-11-13 实录）：bump 回写 docs/architecture.md 的 cells 表按
// SetTableCell3 **首格全等**匹配，而 architecture.md 的 kit 行 2026-10-16 归档时
// 改名成「kit(已归档)」⇒ 每趟车 warn+skip（发车日志噪音），且行表一旦再改名
// 就会静默漏更新（版本格冻结在旧值却无人知晓）。
//
// 守卫：cells 表的每个首格必须能在**真实** docs/architecture.md 里全等命中——
// 行改名或删行而 bump 行表没跟 ⇒ 本测试红。
//
// 负对照（实测转红后还原）：把 {"kit", b.kit} 放回 archCells ⇒
// 首格 "kit" vs 行 "kit(已归档)" 全等不中 ⇒ 本测试红。
package main

import (
	"os"
	"testing"
)

func TestArchCellsAlignWithRealArchitectureMD(t *testing.T) {
	arch, err := os.ReadFile("../../docs/architecture.md")
	if err != nil {
		t.Fatalf("读 docs/architecture.md 失败: %v", err)
	}
	// 值全用哑元——本测试只验**首格命中**，值随列车动态生成由既有 dry-run 覆盖。
	b := &bumper{
		train: "9.9.9", contracts: "v0.0.0", core: "v0.0.0", fcore: "v0.0.0",
		server: "0.0.0", feTag: "v9.9.9", p2p: "v0.0.0", kit: "v0.0.0",
		corePin: "v0.0.0", chart: "0.0.0",
	}
	for _, c := range b.archCells() {
		if _, hit := SetTableCell3(string(arch), c[0], c[1]); !hit {
			t.Errorf("首格全等未命中: %q —— architecture.md 行改名/删行后 bump 会每趟 warn+skip（2026-11-13 kit 实录）",
				c[0])
		}
	}
}
