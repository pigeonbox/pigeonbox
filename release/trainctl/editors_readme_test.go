package main

import (
	"strings"
	"testing"
)

// README 版本表归列车管（2026-10-23）。
//
// 此前 bump 只改 architecture.md 与 AGENTS.md 的版本表，**README 漏了** ⇒
// 版本表靠人记得改 ⇒ 实测落后两列车（且宣称已退役能力）⇒ 每次发车再漂一次。
func TestSetReadmeVersionCell(t *testing.T) {
	readme := `| 仓库 | 角色 | 版本 |
|------|------|------|
| [contracts](https://github.com/pigeonbox/contracts) | 契约层 | v0.18.1 |
| [core](https://github.com/pigeonbox/core) | 业务核心库 | v0.30.2 |
| [charts](https://github.com/pigeonbox/charts) | Helm Chart | pigeonbox-2.0.49 |
`
	out, hit := SetReadmeVersionCell(readme, "contracts", "v0.18.5")
	if !hit {
		t.Fatal("未命中 contracts 行")
	}
	if !strings.Contains(out, "| v0.18.5 |") {
		t.Fatalf("版本列未改写: %s", out)
	}
	if !strings.Contains(out, "v0.30.2") || !strings.Contains(out, "pigeonbox-2.0.49") {
		t.Fatalf("误改其它行: %s", out)
	}
	// 行首是链接 ⇒ 不得误伤同名子串（如 core 不应命中 frontend-core）
	out2, hit2 := SetReadmeVersionCell(readme+"| [frontend-core](https://github.com/pigeonbox/frontend-core) | 前端 core | v0.11.2 |\n", "core", "v0.31.4")
	if !hit2 {
		t.Fatal("未命中 core 行")
	}
	if !strings.Contains(out2, "| v0.31.4 |") {
		t.Fatalf("core 版本列未改写: %s", out2)
	}
}
