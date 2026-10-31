package main

import (
	"regexp"
	"strconv"
	"strings"
)

// 本文件全部为纯函数编辑器(内容进、内容出),不触盘——bump 的 dry-run
// 零副作用与单测都建立在这一层上。

var (
	reJSONVersion = regexp.MustCompile(`"version"\s*:\s*"[^"]*"`)
	reCargoVer    = regexp.MustCompile(`(?m)^version = "[^"]*"`)
	reComposeTag  = regexp.MustCompile(`PB_IMAGE_TAG:-v?[0-9]+\.[0-9]+\.[0-9]+`)
	reEnvTag      = regexp.MustCompile(`(?m)^PB_IMAGE_TAG=v?[0-9]+\.[0-9]+\.[0-9]+`)
	reNewTag      = regexp.MustCompile(`newTag: [0-9.]+`)
	reManifestVer = regexp.MustCompile(`(?m)^version=.*$`)
	// 硬钉版本的 image 行（生态应用包专用）：
	//   image: docker.io/pigeonbox/server:4.6.3
	//   image: ghcr.io/pigeonbox/frontend:4.6.3
	// ⇒ 只换最后的版本段，**不碰 registry/仓库名**。
	rePinnedImageTag = regexp.MustCompile(`(?m)^(\s*image:\s*\S+):v?[0-9]+\.[0-9]+\.[0-9]+(\s*)$`)
)

// SetPinnedImageTag 改「硬钉版本」的 image 行的版本段。
//
// 为什么单独一套（不走 SetComposeImageTag）：
//
//	NAS 侧 compose 用 `PB_IMAGE_TAG:-<ver>` **变量占位**（同一文件给多车用）；
//	而生态应用包（TOS 7 的 tos7/docker-compose.yml、UPK 的
//	upk/rootfs_common/docker-compose.yaml）是**送审形态**——版本必须**硬钉**
//	（送审材料里不能带变量占位，否则平台侧装到的东西版本不明）。
//	⇒ 两者口径必须分开，否则要么把送审文件改成变量（送审被打回），
//	   要么把 NAS 模板的占位符写死（多车复用崩）。
//
// ⚠️ 只改版本段：registry 与仓库名原样保留 ⇒ 切 Docker Hub 时不会被误改回 ghcr。
func SetPinnedImageTag(content, ver string) string {
	return rePinnedImageTag.ReplaceAllString(content, "${1}:"+ver+"${2}")
}

// SetFirstJSONVersion 替换文件中第一个 "version" 键(package.json/tauri.conf.json;
// v1 perl 同语义:只动首个,深层嵌套不误伤)。
func SetFirstJSONVersion(content, ver string) string {
	loc := reJSONVersion.FindStringIndex(content)
	if loc == nil {
		return content
	}
	return content[:loc[0]] + `"version": "` + ver + `"` + content[loc[1]:]
}

// SetCargoVersion 替换 Cargo.toml 首个顶层 version 行。
func SetCargoVersion(content, ver string) string {
	loc := reCargoVer.FindStringIndex(content)
	if loc == nil {
		return content
	}
	return content[:loc[0]] + `version = "` + ver + `"` + content[loc[1]:]
}

// SetCargoLockVersion 替换 Cargo.lock 中指定包的 version 行。
//
// 为什么需要：列车 bump 只写 Cargo.toml，锁文件里的包版本就永远停在上一趟
// （实测 desktop-v2.2.0 的 Cargo.lock 仍写 2.0.5）——后果是 `cargo build
// --locked` 直接失败（lockfile out of date），且锁文件对实际构建版本说谎。
// 这里只改目标包那一行，不重排整个锁文件（重排需要 cargo 工具链，列车
// 编排环境没有）。
func SetCargoLockVersion(content, pkg, ver string) string {
	lines := splitLines(content)
	inPkg := false
	changed := false
	for i, ln := range lines {
		trimmed := strings.TrimSpace(ln)
		if strings.HasPrefix(trimmed, "[[package]]") {
			inPkg = false
			continue
		}
		if strings.HasPrefix(trimmed, "name = ") {
			name := strings.Trim(strings.TrimSpace(strings.TrimPrefix(trimmed, "name = ")), `"`)
			inPkg = name == pkg
			continue
		}
		if !inPkg || !strings.HasPrefix(trimmed, "version = ") {
			continue
		}
		lines[i] = `version = "` + ver + `"`
		changed = true
		break
	}
	if !changed {
		return content
	}
	return strings.Join(lines, "\n")
}

// ReplaceTGZ 把 <dist>/releases/download/v*/pigeonbox-<dist>-*.tgz 钉到指定版本
// (dist=frontend-core/contracts;消费=Release 源码 tgz,URL 钉版)。
func ReplaceTGZ(content, dist, ver string) string {
	verNoV := strings.TrimPrefix(ver, "v")
	re := regexp.MustCompile(regexp.QuoteMeta(dist) + `/releases/download/v[^/]+/pigeonbox-` + regexp.QuoteMeta(dist) + `-[0-9.]+\.tgz`)
	return re.ReplaceAllString(content, dist+"/releases/download/"+ver+"/pigeonbox-"+dist+"-"+verNoV+".tgz")
}

// SetComposeImageTag 改 compose 模板的 PB_IMAGE_TAG:-<ver>(可含 v 前缀,统一去掉)。
func SetComposeImageTag(content, ver string) string {
	return reComposeTag.ReplaceAllString(content, "PB_IMAGE_TAG:-"+ver)
}

// SetEnvImageTag 改 env.example 的 ^PB_IMAGE_TAG=<ver>。
func SetEnvImageTag(content, ver string) string {
	return reEnvTag.ReplaceAllString(content, "PB_IMAGE_TAG="+ver)
}

// SetNewTag 改 kustomization 的全部 newTag: <ver>。
func SetNewTag(content, ver string) string {
	return reNewTag.ReplaceAllString(content, "newTag: "+ver)
}

// SetManifestVersion 改 fnos fpk manifest 的 version= 行。
func SetManifestVersion(content, ver string) string {
	return reManifestVer.ReplaceAllString(content, "version="+ver)
}

// EnsureManifestChangelog 在 desc= 行后插入本列车 changelog(已存在则原样返回)。
func EnsureManifestChangelog(content, train, corePin, feRef string) string {
	if strings.Contains(content, "\nchangelog="+train+":") || strings.HasPrefix(content, "changelog="+train+":") {
		return content
	}
	entry := "changelog=" + train + ": 发布列车 " + train + "(底层 core " + corePin + ";前端 " + feRef + ";详见 Release notes)。"
	lines := splitLines(content)
	for i, ln := range lines {
		if strings.HasPrefix(ln, "desc=") {
			out := append(append([]string{}, lines[:i+1]...), entry)
			out = append(out, lines[i+1:]...)
			return strings.Join(out, "\n")
		}
	}
	return content + "\n" + entry + "\n"
}

// SetTableCell3 改管道表「| 名 | 版本 | 说明 |」第三列(v1 set_table_cell3;
// 按字段语义比较,不做动态正则——BSD awk "illegal primary" 教训)。
// 返回是否命中。
func SetTableCell3(content, name, val string) (string, bool) {
	lines := splitLines(content)
	hit := false
	for i, ln := range lines {
		f := strings.Split(ln, "|")
		if len(f) < 4 {
			continue
		}
		if strings.TrimSpace(f[1]) == name {
			f[2] = " " + val + " "
			lines[i] = strings.Join(f, "|")
			hit = true
		}
	}
	return strings.Join(lines, "\n"), hit
}

// SetReadmeVersionCell 把 README 版本表里某个仓那一行的**版本列**（最后一列）
// 改为 val（按 "| [name](" 定位行）。
//
// README 的版本表列是 | 仓库 | 角色 | 版本 | ⇒ 首格是链接文本
// （"[contracts](...)"）而不是纯名字 ⇒ SetTableCell3（按首格全等匹配）匹配不到，
// 故单列一个助手。
//
// 为什么要它：**版本表归列车管**。此前 README 的版本表靠人记得改
// （实测落后两列车 + 宣称已退役能力）⇒ 每次发车就再漂一次；本助手让
// trainctl bump 与 train.yaml 同步改写它，verify 的 section9b 再兜底。
func SetReadmeVersionCell(content, name, val string) (string, bool) {
	lines := splitLines(content)
	hit := false
	for i, ln := range lines {
		if !strings.Contains(ln, "| ["+name+"](") {
			continue
		}
		f := strings.Split(ln, "|")
		if len(f) < 4 {
			continue
		}
		f[len(f)-2] = " " + val + " "
		lines[i] = strings.Join(f, "|")
		hit = true
	}
	return strings.Join(lines, "\n"), hit
}

// SetTableLastCell 把首个含 prefix 的表格行的最后一个非空单元格改为 val
// (v1 set_table_last_cell,AGENTS.md 末列=版本)。
func SetTableLastCell(content, prefix, val string) (string, bool) {
	lines := splitLines(content)
	for i, ln := range lines {
		if !strings.Contains(ln, prefix) {
			continue
		}
		f := strings.Split(ln, "|")
		for j := len(f) - 2; j >= 1; j-- {
			if strings.TrimSpace(f[j]) != "" {
				f[j] = " " + val + " "
				lines[i] = strings.Join(f, "|")
				return strings.Join(lines, "\n"), true
			}
		}
		return strings.Join(lines, "\n"), false
	}
	return content, false
}

// BumpPatch 语义化版本 patch+1("2.0.16"→"2.0.17";带引号/前缀容忍)。
func BumpPatch(ver string) string {
	v := strings.Trim(strings.TrimSpace(ver), `"`)
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return v
	}
	n, err := strconv.Atoi(parts[2])
	if err != nil {
		return v
	}
	return parts[0] + "." + parts[1] + "." + strconv.Itoa(n+1)
}

// RenderDepsEnv 生成 DEPS.env(发布列车依赖钉版,勿手改)。
func RenderDepsEnv(pairs [][2]string) string {
	var b strings.Builder
	b.WriteString("# 发布列车依赖钉版(真相源=hub release/train.yaml,由 trainctl bump 写入;勿手改)\n")
	for _, p := range pairs {
		b.WriteString(p[0] + "=" + p[1] + "\n")
	}
	return b.String()
}
