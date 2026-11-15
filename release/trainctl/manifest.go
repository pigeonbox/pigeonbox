// manifest.go —— 机器可读 release manifest v1(pigeonbox#363)。
//
// release/manifest.json 是一趟列车的机器可读清单:每仓 commit SHA/版本/
// 镜像 tag/契约版本。数据源 = release/train.yaml(版本面)+ 远端 tag
// (commit 面,ls-remote 与 verify 的 TagExists 同通道)⇒ 制品生产与验收
// 引用同一份清单(评审稿 §四「发布工程的版本一致性缺口」修复方向之一)。
//
// 生命周期(生成点必须跟着列车走,否则下趟车 verify section12 必假红):
//   - `trainctl manifest` 生成/覆写;`--check` 与磁盘逐字比对;
//   - bump 随 train.yaml 同步再生成(此刻新车产品 tag 未打 ⇒ commit 留空);
//   - 状态推进时 commitHubTrainFile 再生成(tagged/shipped 时 tag 已齐,
//     补齐 commit);
//   - verify section12 校验:结构/版本面 vs train.yaml,commit 面 vs 远端。
//   - 只服务当前列车,**不回填历史制品**(issue #363 口径)。
package main

import (
	"encoding/json"
	"os"
)

const (
	manifestRel    = "release/manifest.json"
	manifestSchema = "1"
)

// Manifest 是 release/manifest.json 的内存映像(字段序=JSON 序,渲染确定)。
type Manifest struct {
	Schema   string            `json:"schema"`
	Train    string            `json:"train"`
	Contract string            `json:"contract"` // 契约版本(lib.contracts)单列,消费方一眼可读
	Images   map[string]string `json:"images"`   // 镜像 tag(ghcr,无 v 前缀)
	Repos    []ManifestEntry   `json:"repos"`    // 按 manifestSpecs 序(库线在前)
}

// ManifestEntry 是单仓条目。Kind: lib=库线, component=组件仓(镜像与终端包)。
// Commit 为 tag 指向的 commit SHA(注解 tag 已剥壳);生成时 tag 未发布则省略。
type ManifestEntry struct {
	Repo    string `json:"repo"`
	Kind    string `json:"kind"`
	Version string `json:"version"`
	Tag     string `json:"tag"`
	Commit  string `json:"commit,omitempty"`
}

const (
	manifestKindLib       = "lib"
	manifestKindComponent = "component"
)

// manifestSpec 是清单条目规格:仓 + train.yaml 的版本/tag 值。
// 构建(buildManifest)与校验(section12)共用同一规格 ⇒ 两侧永不对不齐。
type manifestSpec struct {
	repo    string
	kind    string
	version string
	tag     string
}

// manifestSpecs 从 train.yaml 导出应有条目(与 verify section1/6 对账面同源:
// 清单是它们的机器可读投影)。kit 已归档(空版本)不进清单;charts 无 git tag
// (Chart.yaml 直推发版)不进清单。
func manifestSpecs(tf *TrainFile) []manifestSpec {
	var out []manifestSpec
	for _, s := range []struct{ repo, key string }{
		{"contracts", "lib.contracts"},
		{"core", "lib.core"},
		{"p2p", "lib.p2p"},
		{"frontend-core", "lib.frontend-core"},
	} {
		if v := tf.Get(s.key); v != "" {
			out = append(out, manifestSpec{repo: s.repo, kind: manifestKindLib, version: v, tag: v})
		}
	}
	if v := tf.Get("images.server"); v != "" {
		out = append(out, manifestSpec{repo: "server", kind: manifestKindComponent, version: v, tag: "v" + v})
	}
	if tag := tf.Get("frontend.tag"); tag != "" {
		out = append(out, manifestSpec{repo: "frontend", kind: manifestKindComponent,
			version: tf.Get("images.frontend"), tag: tag})
	}
	for _, p := range append([]string{"fnos", "openwrt", "qnap", "desktop"}, platforms...) {
		if tag := tf.Get("terminal." + p + ".tag"); tag != "" {
			out = append(out, manifestSpec{repo: p, kind: manifestKindComponent,
				version: tf.Get("terminal." + p + ".version"), tag: tag})
		}
	}
	return out
}

// buildManifest 从 train.yaml + 远端 tag 构建清单。commit 解析 best-effort:
// tag 未发布或拉取失败 ⇒ 留空(bump 时新车产品 tag 就是还没有;section12 对
// 空值只告警,tag 存在性由 section1 权威把守,不在此重复判)。
func buildManifest(env *Env, tf *TrainFile) *Manifest {
	m := &Manifest{
		Schema:   manifestSchema,
		Train:    tf.Get("train"),
		Contract: tf.Get("lib.contracts"),
		Images:   map[string]string{},
	}
	for _, k := range []string{"server", "frontend"} {
		if v := tf.Get("images." + k); v != "" {
			m.Images[k] = v
		}
	}
	for _, sp := range manifestSpecs(tf) {
		sha, _ := env.TagSHA(sp.repo, sp.tag)
		m.Repos = append(m.Repos, ManifestEntry{
			Repo: sp.repo, Kind: sp.kind, Version: sp.version, Tag: sp.tag, Commit: sha,
		})
	}
	return m
}

// renderManifest 渲染确定性 JSON(结构体字段序固定、map 键排序、两空格缩进)。
func renderManifest(m *Manifest) (string, error) {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b) + "\n", nil
}

// refreshManifest 重新生成并落盘 release/manifest.json(状态推进等再生成点用)。
// 返回是否写盘成功;失败只告警不中断调用方(状态推进 > 清单补齐——
// section12 会对缺/旧清单判红兜底,不会静默放行)。
func refreshManifest(env *Env, tf *TrainFile) bool {
	next, err := renderManifest(buildManifest(env, tf))
	if err != nil {
		warnf("manifest 渲染失败(跳过再生成): %v", err)
		return false
	}
	if err := os.WriteFile(env.Root+"/"+manifestRel, []byte(next), 0o644); err != nil {
		warnf("manifest 写入失败(跳过再生成): %v", err)
		return false
	}
	return true
}

// cmdManifest 生成/校验 release/manifest.json。--check 只读逐字比对(0/1)。
func cmdManifest(env *Env, args []string) int {
	check := false
	for _, a := range args {
		switch a {
		case "--check":
			check = true
		default:
			die("用法: trainctl manifest [--check]")
		}
	}
	tf := mustTrain(env)
	m := buildManifest(env, tf)
	next, err := renderManifest(m)
	if err != nil {
		die("manifest 渲染失败: %v", err)
	}
	path := env.Root + "/" + manifestRel
	if check {
		cur, err := os.ReadFile(path)
		if err != nil {
			failf("release/manifest.json 读取失败: %v", err)
			return 1
		}
		if string(cur) != next {
			failf("release/manifest.json 与 train.yaml/远端 tag 不一致——重跑 trainctl manifest 更新")
			return 1
		}
		okf("manifest 一致(train=%s, repos=%d, 已记 commit %d)", m.Train, len(m.Repos), countManifestCommits(m))
		return 0
	}
	if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
		die("写 %s 失败: %v", manifestRel, err)
	}
	okf("manifest 已写 %s(train=%s, repos=%d, 已记 commit %d)",
		manifestRel, m.Train, len(m.Repos), countManifestCommits(m))
	return 0
}

// countManifestCommits 统计已记 commit 的条目数(生成输出的摘要字段)。
func countManifestCommits(m *Manifest) int {
	n := 0
	for _, e := range m.Repos {
		if e.Commit != "" {
			n++
		}
	}
	return n
}
