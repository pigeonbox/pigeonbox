package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// 夹具复用 verify_contracts_copies_test.go 里的 lockTwoCopies / lockOneCopy
// （3.3.28 壳仓真实形态：根一份 0.18.7 + fc 底下嵌套一份 0.18.6）⇒ 两份真相源不合。

// lockTwoCopiesWithTail 在嵌套条目**后面**再挂一项 ⇒ 剪的是「中间一项」，
// 用来验证剪除不误伤后续条目、也不留下悬空逗号。
var lockTwoCopiesWithTail = strings.Replace(
	lockTwoCopies,
	`    "node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {
      "version": "0.18.6",
      "resolved": "https://example/contracts-0.18.6.tgz"
    }`,
	`    "node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {
      "version": "0.18.6",
      "resolved": "https://example/contracts-0.18.6.tgz"
    },
    "node_modules/vue": {
      "version": "3.5.44",
      "resolved": "https://registry.npmjs.org/vue/-/vue-3.5.44.tgz"
    }`, 1)

// contractsPathsOf 数 lock 里 @pigeonbox/contracts 的安装路径（与 verify 侧口径一致：
// 只认以 node_modules/@pigeonbox/contracts 结尾的键）。
func contractsPathsOf(t *testing.T, content string) []string {
	t.Helper()
	var doc struct {
		Packages map[string]json.RawMessage `json:"packages"`
	}
	if err := json.Unmarshal([]byte(content), &doc); err != nil {
		t.Fatalf("lock 不是合法 JSON: %v\n%s", err, content)
	}
	var out []string
	for k := range doc.Packages {
		if k == "node_modules/@pigeonbox/contracts" ||
			strings.HasSuffix(k, "/node_modules/@pigeonbox/contracts") {
			out = append(out, k)
		}
	}
	return out
}

// TestPruneNestedContractsEntries_两份剪成一份：核心判据。
func TestPruneNestedContractsEntries_两份剪成一份(t *testing.T) {
	got, pruned := PruneNestedContractsEntries(lockTwoCopies)
	paths := contractsPathsOf(t, got)
	if len(paths) != 1 {
		t.Fatalf("剪除后应有 1 份 contracts，实际 %d 份: %v", len(paths), paths)
	}
	if paths[0] != "node_modules/@pigeonbox/contracts" {
		t.Fatalf("留下的不是顶层那份: %v", paths)
	}
	if len(pruned) != 1 {
		t.Fatalf("应剪除 1 条嵌套条目，实际 %d: %v", len(pruned), pruned)
	}
	// 剪掉的应当是旧版本那一份（告警要说清「旧的钉在哪版」）。
	if !strings.Contains(pruned["node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts"], "0.18.6") {
		t.Fatalf("被剪条目的 resolved 不对: %v", pruned)
	}
	// 其余内容不能被动过。
	for _, keep := range []string{`frontend-core-0.11.21.tgz`, `contracts-0.18.7.tgz`} {
		if !strings.Contains(got, keep) {
			t.Fatalf("剪除误伤了别处: 缺 %s", keep)
		}
	}
}

// TestPruneNestedContractsEntries_剪中间一项不误伤后续：后续条目与 JSON 合法性。
func TestPruneNestedContractsEntries_剪中间一项不误伤后续(t *testing.T) {
	got, pruned := PruneNestedContractsEntries(lockTwoCopiesWithTail)
	if len(pruned) != 1 {
		t.Fatalf("应剪 1 条，实际 %d", len(pruned))
	}
	if !strings.Contains(got, `"node_modules/vue"`) {
		t.Fatalf("剪除误伤了后续条目:\n%s", got)
	}
	if len(contractsPathsOf(t, got)) != 1 {
		t.Fatalf("剪除后副本数不对")
	}
}

// TestPruneNestedContractsEntries_剪最后一项不留尾逗号：JSON 合法性。
func TestPruneNestedContractsEntries_剪最后一项不留尾逗号(t *testing.T) {
	// lockTwoCopies 里嵌套条目就是 packages 的最后一项 ⇒ 剪掉后前一项的尾逗号必须去掉。
	got, _ := PruneNestedContractsEntries(lockTwoCopies)
	if strings.Contains(got, `0.18.7.tgz",`) {
		t.Fatalf("剪掉最后一项后前一项的尾逗号没去掉:\n%s", got)
	}
	if err := json.Unmarshal([]byte(got), &map[string]any{}); err != nil {
		t.Fatalf("剪除后 JSON 非法: %v\n%s", err, got)
	}
}

// TestAlignContractsSpecs_各包声明对齐到顶层：②（不可省的那一半）。
func TestAlignContractsSpecs_各包声明对齐到顶层(t *testing.T) {
	const top = "https://example/contracts-0.18.7.tgz"
	got, n := AlignContractsSpecs(lockTwoCopies, top)
	if n != 1 {
		t.Fatalf("应改写 1 处声明，实际 %d", n)
	}
	if strings.Contains(got, `"@pigeonbox/contracts": "https://example/contracts-0.18.6.tgz"`) {
		t.Fatalf("fc 的旧声明没被对齐:\n%s", got)
	}
	if !strings.Contains(got, top) {
		t.Fatalf("顶层 spec 不见了")
	}
}

// TestFixContractsSingleCopy_端到端收敛。
func TestFixContractsSingleCopy_端到端收敛(t *testing.T) {
	got, rep := FixContractsSingleCopy(lockTwoCopies)
	if !rep.Changed {
		t.Fatalf("两份形态应报告 Changed=true")
	}
	if len(rep.Pruned) != 1 {
		t.Fatalf("应剪 1 条，实际 %d", len(rep.Pruned))
	}
	if rep.Rewritten != 1 {
		t.Fatalf("应改写 1 处声明，实际 %d", rep.Rewritten)
	}
	if len(contractsPathsOf(t, got)) != 1 {
		t.Fatalf("收敛后副本数不对:\n%s", got)
	}
	// ⚠️ 负对照：只剪条目、**不改声明** ⇒ npm ci 会按 fc 的 tgz manifest 重新解析出
	// 嵌套依赖并装出第二份（2026-11-03 实测）⇒ 判据必须能区分这两种形态。
	if strings.Contains(got, "contracts-0.18.6.tgz") {
		t.Fatalf("fc 条目里的旧声明没对齐 ⇒ 只剪 lock 条目是假绿:\n%s", got)
	}
}

// TestFixContractsSingleCopy_只剪不改是假绿：把「只剪」与「剪+改」分开断言。
func TestFixContractsSingleCopy_只剪不改是假绿(t *testing.T) {
	prunedOnly, _ := PruneNestedContractsEntries(lockTwoCopies)
	// 只剪：路径数达标，但声明还指着旧版 ⇒ npm ci 仍会装出第二份。
	if len(contractsPathsOf(t, prunedOnly)) != 1 {
		t.Fatalf("只剪后路径数应为 1")
	}
	if !strings.Contains(prunedOnly, "contracts-0.18.6.tgz") {
		t.Fatalf("只剪不该动声明（负对照失效）")
	}
	// 剪+改：声明被对齐 ⇒ 真的单副本。
	full, rep := FixContractsSingleCopy(lockTwoCopies)
	if rep.Rewritten == 0 {
		t.Fatalf("完整修法应改写声明")
	}
	if strings.Contains(full, "contracts-0.18.6.tgz") {
		t.Fatalf("完整修法后旧声明应消失")
	}
}

// TestFixContractsSingleCopy_幂等：已经是单副本的 lock 不该被改动。
func TestFixContractsSingleCopy_幂等(t *testing.T) {
	got, rep := FixContractsSingleCopy(lockOneCopy)
	if rep.Changed {
		t.Fatalf("干净 lock 不该报告变更: %+v", rep)
	}
	if got != lockOneCopy {
		t.Fatalf("干净 lock 内容被改了")
	}
}
