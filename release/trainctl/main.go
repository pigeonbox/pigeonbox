// trainctl 是 PigeonBox 发布列车 v2 的状态机编排器。
//
// 真相源: release/train.yaml;设计稿: docs/specs/2026-10-12-release-train-v2-design.md。
// 取代 scripts/release-train.sh(v1 bash 巨石,过渡期保留作回退路径)。
//
// 子命令:
//
//	get <key>                     读 train.yaml 单键(工作流取值)
//	notes [v<train>]              渲染 hub Release 说明(组件矩阵)
//	verify [--ci]                 全生态对账(漂移即非零退出)
//	bump TRAIN=x.y.z [opts]       开新列车: 结构化写版本点 → 各仓 train/<v> 分支+PR → 自动合并
//	  [--set core=v0.18.0 ...]      库线消费记录(contracts/core/kit/p2p/p2pc/core_pin/frontend-core/server)
//	  [--hotfix]                    子集列车(train.yaml 记 hotfix=true)
//	  [--freeze-libs]               库线钉版冻结在 train.yaml 现值(默认=自动跟随最新已发布 tag)
//	  [--dry-run]                   纯内存输出计划,不落盘(与 v1 相反:dry-run 零副作用)
//	  [--push]                      实际执行(建分支/提交/push/PR/自动合并);缺省即 dry-run
//	run TRAIN=x.y.z [opts]        **一条命令开完一趟车**(2026-10-27 起):
//	  库线(解析→发 tag→等可消费) → bump → 自轮询等 PR 合并 → tag →
//	  自轮询等产物齐 → charts → 全量 verify → 出 hub 快照;全程单次运行内完成。
//	  已开出(state≠shipped)的列车重跑**跳过 bump**,直接接着推。
//	  [--set ...] [--hotfix] [--freeze-libs] [--timeout=90m]
//	tag                           bump PR 全合并后按依赖序推 tag + charts 提交 + state=tagged
//	advance [--finalize]          状态机推进: draft→tagged→shipped(回调/sweep/手动唤醒,幂等可重入)
//
// 语义约定(继承 v1,勿破坏):
//   - ghcr 镜像 tag 无 v 前缀;release/git tag 带 v(desktop 为 desktop-v 前缀)
//   - hub Release 回挂 tag = <组件名>-v<版本>(desktop-v*/fnos-v*/p2p-v*…)
//   - 判"最新"一律 semver 排序,禁用 tag creatordate
//   - 组件回挂恒 --latest=false;Latest 只属于 hub v<train> 快照
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "用法: trainctl <get|notes|verify|bump|run|tag|advance> [args…](详见 -h)")
		os.Exit(2)
	}
	env, err := NewEnv()
	if err != nil {
		die("%v", err)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "get":
		if len(args) != 1 {
			die("用法: trainctl get <key>")
		}
		tf := mustTrain(env)
		fmt.Println(tf.Get(args[0]))
	case "notes":
		tf := mustTrain(env)
		tag := ""
		if len(args) == 1 {
			tag = args[0]
		}
		fmt.Print(cmdNotes(tf, tag))
	case "verify":
		ci := len(args) > 0 && args[0] == "--ci"
		os.Exit(cmdVerify(env, ci))
	case "bump":
		cmdBump(env, args)
	case "run":
		cmdRun(env, args)
	case "tag":
		cmdTag(env)
	case "advance":
		cmdAdvance(env, args)
	case "-h", "--help", "help":
		fmt.Print(helpText)
	default:
		die("未知子命令 %q(try: trainctl help)", cmd)
	}
}

const helpText = `trainctl — PigeonBox 发布列车 v2 状态机编排器(真相源 release/train.yaml)

用法:
  trainctl get <key>                  读 train.yaml 单键
  trainctl notes [v<train>]           渲染 hub Release 说明
  trainctl verify [--ci]              全生态对账(漂移即非零退出)
  trainctl bump TRAIN=x.y.z [--set k=v …] [--hotfix] [--freeze-libs] [--push]
                                      开列车(缺省 dry-run 零副作用;--push 建 PR+自动合并)
  trainctl run TRAIN=x.y.z [--set k=v …] [--hotfix] [--freeze-libs] [--timeout=90m]
                                      **一条命令开完一趟车**:库线(发 tag+等可消费)→
                                      bump→等 PR 合并→tag→等产物齐→终验→出 hub 快照
  trainctl tag                        bump PR 齐合并后按依赖序推 tag+charts 提交
  trainctl advance [--finalize]       状态机推进 draft→tagged→shipped(幂等可重入)

库线钉版:默认**自动跟随各库仓最新已发布 tag**(与 go get -u 同语义);
          --set core=vX 可显式钉版(未发布则由列车自己打 tag);
          --freeze-libs 冻结在 train.yaml 现值。

设计稿: docs/specs/2026-10-12-release-train-v2-design.md
         docs/specs/2026-10-27-release-train-v3-one-command-design.md
`

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "✗ "+format+"\n", a...)
	os.Exit(1)
}

func mustTrain(env *Env) *TrainFile {
	tf, err := LoadTrainFile(env)
	if err != nil {
		die("%v", err)
	}
	return tf
}
