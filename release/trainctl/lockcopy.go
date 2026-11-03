package main

import (
	"regexp"
	"strings"
)

// 本文件解决「消费仓 lock 里 @pigeonbox/contracts 装出多份」的问题（hub#274）。
//
// ── 现象（4.8.1 列车实录）──
// 终验卡死点：`✗ frontend package-lock.json: @pigeonbox/contracts 有 2 份(应恰好 1 份)`。
// bump 把壳仓钉版四件套（package.json 依赖声明 / fc 消费方 lib.frontend-core /
// lock 里 fc 条目的嵌套依赖声明 / lock 里 contracts 顶层条目 version+resolved+integrity）
// 都改对了，**但没剪掉历史残留的嵌套条目**
// `node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts`（仍钉 v0.20.11）
// ⇒ 单副本判据按 lock 路径计数得 2 ⇒ 终验红 ⇒ 整趟车卡在 tagged、hub 快照不出。
//
// ── 根因 ──
// npm 不去重**不同版本**的同包。frontend-core 的 tgz 自带
// `@pigeonbox/contracts` 依赖声明；而**库线仓自身的 contracts 钉版不在 bump 范围**
// （库线仓要各自单独抬钉版、并发新版本号——见 AGENTS.md「发库线 tag 前的必查项」）
// ⇒ 列车把壳仓的 contracts 抬到新版、而 frontend-core 还没发新版时，
// npm 必然在 fc 底下再装一份旧 contracts ⇒ lock 里两份 ⇒ 消费方装出两份 contracts
// ⇒ 前端 `import type` 解析到旧的那份 ⇒ 类型漂移。
//
// ── 修法（本文件）──
// 把消费仓 lock 收敛成「@pigeonbox/contracts 恰好一份」：
//
//	① 剪除 lock 里 @pigeonbox/contracts 的**嵌套**安装条目（只留顶层那份）；
//	② 把各包条目里对 @pigeonbox/contracts 的**依赖声明**统一到顶层那份的 spec。
//
// ⚠️ **②不可省**（2026-11-03 实测，只做 ① 会假绿）：
//
//	只剪 lock 条目 ⇒ `npm ci` 仍按 fc 的 **tgz manifest** 重新解析该依赖
//	⇒ 实测仍装出两份（顶层 0.21.0 + 嵌在 fc 下的 0.20.11）⇒ 单副本判据照旧红。
//	只有把 fc 条目里的声明一并对齐，`npm ci` 才真的装出单副本（实测：仅顶层 0.21.0）。
//
// ⚠️ 本函数只解「列车被卡住」；**根治仍需 frontend-core 发新版钉住新 contracts**
// （否则 fc 源码用的仍是旧契约的类型）⇒ bump 侧会就此发可操作的告警。

var (
	// lockEntryHeaderRe 匹配 lock 里 "packages" 下的条目头：`    "node_modules/x": {`
	// ⚠️ 键名允许为空（`    "": {` 是根条目）⇒ 用 [^"]* 而非 [^"]+。
	lockEntryHeaderRe = regexp.MustCompile(`^(\s*)"([^"]*)":\s*\{\s*$`)
	// contractsSpecRe 匹配 lock 里的 contracts 依赖声明行：
	// `    "@pigeonbox/contracts": "https://.../pigeonbox-contracts-0.21.0.tgz",`
	contractsSpecRe = regexp.MustCompile(`^(\s*)"@pigeonbox/contracts":\s*"([^"]*)"(\s*,?\s*)$`)
)

// contractsFix 是一次「单副本收敛」的报告。
type contractsFix struct {
	Changed     bool              // 内容是否发生变化
	RootSpec    string            // 顶层（根 package.json）声明的 contracts spec
	Pruned      []string          // 被剪除的嵌套条目路径
	PrunedSpecs map[string]string // 被剪条目当时的 resolved（用于告警说清「旧的钉在哪版」）
	Rewritten   int               // 被对齐声明的条目数
}

// nestedContractsPath 判定某个 lock 条目路径是不是「嵌套的 contracts 副本」。
//
// 只认「安装路径」键：以 node_modules/ 开头、且以 /node_modules/@pigeonbox/contracts
// 结尾 ⇒ 即 fc 底下那一层。顶层那份（node_modules/@pigeonbox/contracts）不剪。
func nestedContractsPath(key string) bool {
	if !strings.HasPrefix(key, "node_modules/") {
		return false
	}
	if !strings.HasSuffix(key, "/node_modules/@pigeonbox/contracts") {
		return false
	}
	return key != "node_modules/@pigeonbox/contracts"
}

// lockEntryHeader 解析 lock 的条目头行，返回（键, 缩进宽度, 是否命中）。
func lockEntryHeader(ln string) (string, int, bool) {
	m := lockEntryHeaderRe.FindStringSubmatch(ln)
	if m == nil {
		return "", 0, false
	}
	return m[2], len(m[1]), true
}

// isObjectClose 判定某行是否是**同缩进**的对象闭合行（`}` 或 `},`）。
//
// 靠缩进相等来配对：嵌套对象的闭合行缩进更深 ⇒ 不会被误判成外层闭合。
func isObjectClose(ln string, indent int) bool {
	t := strings.TrimSpace(ln)
	if t != "}" && t != "}," {
		return false
	}
	return len(ln)-len(strings.TrimLeft(ln, " \t")) == indent
}

// PruneNestedContractsEntries 剪除 lock 里 @pigeonbox/contracts 的嵌套安装条目，
// 只留顶层那份。返回（剪除后的内容, 被剪条目的 path → resolved）。
//
// 纯文本实现（不反序列化再序列化）：package-lock.json 的 "packages" 是个大对象，
// 用 encoding/json 读写会把整个文件重排 ⇒ diff 变成全文件 ⇒ 不可接受。
// ⇒ 按行做**外科手术**：命中条目头就吃掉它的整个对象体。
//
// ⚠️ 剪的是**最后一项**时要连带去掉前一项的尾逗号（否则 JSON 非法、npm ci 直接炸）。
func PruneNestedContractsEntries(content string) (string, map[string]string) {
	lines := splitLines(content)
	out := make([]string, 0, len(lines))
	pruned := map[string]string{}
	for i := 0; i < len(lines); {
		key, indent, ok := lockEntryHeader(lines[i])
		if !ok || !nestedContractsPath(key) {
			out = append(out, lines[i])
			i++
			continue
		}
		// 吃掉对象体：直到同缩进的闭合行
		j := i + 1
		resolved := ""
		for ; j < len(lines); j++ {
			if v, ok := lockResolvedOf(lines[j]); ok {
				resolved = v
			}
			if isObjectClose(lines[j], indent) {
				break
			}
		}
		noComma := j < len(lines) && strings.TrimSpace(lines[j]) == "}"
		if noComma && len(out) > 0 {
			out[len(out)-1] = strings.TrimSuffix(strings.TrimRight(out[len(out)-1], " \t"), ",")
		}
		pruned[key] = resolved
		if j < len(lines) {
			j++ // 吃掉闭合行
		}
		i = j
	}
	return strings.Join(out, "\n"), pruned
}

// lockResolvedOf 从一行里取 "resolved" 字段的值。
func lockResolvedOf(ln string) (string, bool) {
	t := strings.TrimSpace(ln)
	const prefix = `"resolved":`
	if !strings.HasPrefix(t, prefix) {
		return "", false
	}
	rest := strings.TrimSpace(strings.TrimPrefix(t, prefix))
	if !strings.HasPrefix(rest, `"`) {
		return "", false
	}
	rest = rest[1:]
	if i := strings.Index(rest, `"`); i >= 0 {
		return rest[:i], true
	}
	return "", false
}

// rootContractsSpec 取根条目（键 ""）里声明的 contracts spec，
// 并返回根条目的闭合行下标（用于区分「根里的声明」与「各包自己的声明」）。
//
// 必须按根条目定位而不是「全文件第一处」：根条目是 "packages" 里的第一个键
// （npm 固定这样写），但第一处声明也可能落在别的字段组合上 ⇒ 用根条目的范围来划界更稳。
func rootContractsSpec(lines []string) (string, int) {
	start, indent := -1, 0
	for i, ln := range lines {
		if key, ind, ok := lockEntryHeader(ln); ok && key == "" {
			start, indent = i, ind
			break
		}
	}
	if start < 0 {
		return "", -1
	}
	end := start + 1
	for end < len(lines) && !isObjectClose(lines[end], indent) {
		end++
	}
	for i := start; i < end && i < len(lines); i++ {
		if m := contractsSpecRe.FindStringSubmatch(lines[i]); m != nil {
			return m[2], end
		}
	}
	return "", end
}

// AlignContractsSpecs 把根条目**之后**各包条目里对 @pigeonbox/contracts 的声明
// 统一成 rootSpec。返回（对齐后的内容, 改写条数）。
//
// 为什么必须改：只剪嵌套条目时，npm ci 仍会按 fc 的 **tgz manifest** 重新解析出
// 嵌套依赖并装出第二份（2026-11-03 实测）⇒ 声明不对齐 = 假绿。
func AlignContractsSpecs(content string, rootSpec string) (string, int) {
	if rootSpec == "" {
		return content, 0
	}
	lines := splitLines(content)
	_, rootEnd := rootContractsSpec(lines)
	if rootEnd < 0 {
		return content, 0
	}
	n := 0
	for i := rootEnd + 1; i < len(lines); i++ {
		m := contractsSpecRe.FindStringSubmatch(lines[i])
		if m == nil || m[2] == rootSpec {
			continue
		}
		lines[i] = m[1] + `"@pigeonbox/contracts": "` + rootSpec + `"` + m[3]
		n++
	}
	return strings.Join(lines, "\n"), n
}

// FixContractsSingleCopy 把消费仓 package-lock.json 收敛成
// 「@pigeonbox/contracts 恰好一份」：剪嵌套条目 + 对齐各包的依赖声明。
//
// 返回（收敛后的内容, 报告）。Changed=false 表示本来就没问题（幂等）。
func FixContractsSingleCopy(content string) (string, contractsFix) {
	rep := contractsFix{PrunedSpecs: map[string]string{}}
	prunedContent, pruned := PruneNestedContractsEntries(content)
	rep.Pruned = make([]string, 0, len(pruned))
	for k, v := range pruned {
		rep.Pruned = append(rep.Pruned, k)
		rep.PrunedSpecs[k] = v
	}
	lines := splitLines(prunedContent)
	rootSpec, rootEnd := rootContractsSpec(lines)
	rep.RootSpec = rootSpec
	if rootEnd >= 0 {
		aligned, n := AlignContractsSpecs(strings.Join(lines, "\n"), rootSpec)
		rep.Rewritten = n
		prunedContent = aligned
	}
	rep.Changed = len(rep.Pruned) > 0 || rep.Rewritten > 0
	return prunedContent, rep
}
