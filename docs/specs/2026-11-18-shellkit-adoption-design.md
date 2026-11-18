# shellkit 引入契约（PigeonBox 生态）

- 日期：2026-11-18
- 状态：已落地（本稿是 hub + 平台仓改造的**唯一依据**）
- 上游：shellkit v1.0.0（<https://yi-nology.github.io/shellkit/llms.txt>）
- 范围：hub（`pigeonbox/pigeonbox`）+ `fnos`/`openwrt`/`qnap`/`synology`/`ugreen`/`terramaster`/`p2p`/`charts`
  的**编译 / 部署 / CI 侧** shell 脚本
- 不在范围：`desktop`（Rust/Tauri，仓内零 shell 脚本）、`legacy/FileCodeBox`（冻结快照）

---

## 1. 为什么要做

生态里 ~50 个 shell 脚本各自手写了一遍同样的管道：日志（`echo "✓/✗"`）、退出码（一律 `exit 1`）、
重试（自写 `for try in 1..10; sleep 3`）、下载校验（`curl` + `checksums.txt` + `shasum -c`）、
临时目录（`mktemp` + 手写 `trap`）、参数解析（手写 `--flag value` 循环）。

这些手写件之间**口径不一致**（同一件事在不同仓有三种退出码、三种日志形态、三种重试退避），
且没有一处是「测过的」——每处都是一次性写完就没人再动。shellkit v1.0.0 把这些做成了**有测试、有退出码约定、有禁用语法清单**的库。

本稿要解决的是：**用 shellkit 统一这些管道，同时一个字节的对外行为都不许变**。

---

## 2. 硬约束（先于一切设计）

| # | 约束 | 为什么 |
|---|---|---|
| C1 | **设备侧脚本不引入 shellkit** | 跑在设备上的脚本（QNAP `qpkg/shared/pigeonbox.sh`、群晖 `spk/scripts/*`、OpenWrt `openwrt/pigeonbox.init`）是 `#!/bin/sh`，执行环境是 **busybox ash**；shellkit 库基线是 **bash 3.2+**（内部用数组）⇒ 进不去。设备侧**代码不动**，改用门禁固化边界 + 向上游追 ash 兼容 |
| C2 | **语义等价才替换** | 机械等价（手写重试 ⇄ `retry`、手写下载校验 ⇄ `net_download`）**一律换掉**；只有真会改行为（错误码口径、nil vs 空、分隔符集合、重复即报错 vs 静默去重）才保留手写，且**必须在提交体里逐条写明理由** |
| C3 | **退出码是接口** | 脚本对调用方的退出码契约**不改**。shellkit 的 `SK_*`（0/1/2 用法错/3 前置/4 网络/5 校验）只用于**新增**的语义位；既有契约（例如 `git-fetch-safe.sh` 的「2=超时、3=用法错」）保持原样 |
| C4 | **stdout 契约不变** | 被机器消费的 stdout（冒烟 `PASS=/FAIL=` 汇总）保持原位；shellkit 的 `log_*` 一律走 stderr，与「stdout 只给数据」同向 |
| C5 | **不擅自改 `set` 选项** | 原脚本是 `set -uo pipefail` 的，改完仍是 `set -uo pipefail`。加 `-e` 会让「`grep` 未命中」从「分支」变成「中止」= 语义变更（C2 的例外） |
| C6 | **门禁继续绿** | `check-shfmt.sh`（`-i 2 -ci`）、CI 的 `shellcheck` 步、`check-shell-var-boundary.sh`、`check-shell-trap-exit-code.sh` 全部保持绿；新增两道门禁（见 §7） |
| C7 | **生成物勿手改** | `vendor/shellkit/**` 是上游镜像，只能由 `shellkit vendor` 重新生成；任何「顺手改一下 vendor」都是破坏 |
| C8 | **既有注释是机构记忆** | 脚本里的实录/事故注释**保留**（只改管道，不删教训）；改写时把注释改到对应的新调用点旁边，不丢 |

---

## 3. 引入方式

```
hub（真相源）                     平台仓（各自提交入库）
PigeonBox/vendor/shellkit/   ──物化──▶  fnos/third_party/shellkit/
  （shellkit vendor . 产物）           openwrt/third_party/shellkit/ …
  含 .shellkit-vendor-manifest         qnap/ synology/ ugreen/ terramaster/ p2p/ charts/
```

- **真相源 = hub 的 `vendor/shellkit/`**：产物由 `shellkit vendor .` 生成，含上游所有权清单
  `.shellkit-vendor-manifest`（上游据此判断「这份副本是不是原装的」）。
- **消费仓落点 = `third_party/shellkit/`（不是 `vendor/shellkit/`）**：
  Go ≥1.14 只要**模块根**下存在 `vendor/` 目录就默认切 vendor 模式 ⇒ 缺 `vendor/modules.txt`
  ⇒ `go build ./...` 报 `inconsistent vendoring`（实测：fnos/openwrt/qnap/p2p 四个 Go 模块仓直接红）。
  ⇒ 副本一律放 `third_party/`，与 Go 的 vendor 语义彻底分开。
  真相源仍留在 hub 的 `vendor/shellkit/`：hub 是 **go.work 工作区**（仓根无 `go.mod`），
  仓根 `vendor/` 目录**不会**触发 vendor 模式（已在 go1.27 上实测 rc=0）。
  ⚠️ 上游 CLI 的项目 vendor 落点是**硬编码**的 `<proj>/vendor/shellkit`（`doctor`/`upgrade`/`repair.sh`
  只认这个路径）⇒ 消费仓**不要**在仓内跑 `shellkit vendor .` / `shellkit upgrade`（会造出 `vendor/`
  目录 ⇒ 重新引入 Go 冲突）；同步统一走 hub 的物化器。该缺口已列入 §9 上游 issue 清单。
- **各仓提交入库**（不是构建时联网下载）：CI 构建 fpk/ipk/apk/qpkg/spk 时**不依赖网络取库**，
  产物可离线复现——与生态既有纪律（`GOWORK=off` 钉版、p2pc 走 sha256 侧车）同向。
- **物化器**：`scripts/vendor-shellkit.sh`（hub → 各平台仓），工作区根**探测**而非推算层数
  （沿用 `deploy/nas/sync.sh` 的「嵌套 / 兄弟两种布局都真实存在」教训）。
- **漂移门禁**：`scripts/check-shellkit-vendor.sh` —— 逐文件 sha256 对账 hub 与各仓的副本；
  缺文件 / 多文件 / 字节不同 ⇒ 判红（退出码 5 = 校验失败，与 shellkit 的 `SK_VERIFY` 同义）。
- **升级流程**：改 hub 的 vendor ⇒ `make vendor-sync` 物化到各仓 ⇒ 各仓分别提 PR ⇒
  门禁在 hub 侧汇总判定「全生态同版本」。

---

## 4. 替换清单（机械等价 → 一律换掉）

| # | 场景 | 原手写 | 换成 | 备注 |
|---|---|---|---|---|
| R1 | 临时目录 + 清理 | `mktemp -d` + 手写 `trap 'rc=$?; rm -rf …'` | `trap_push` / `trap_install` | **连带**：§7 的 trap 门禁要认识新形态 |
| R2 | 有限重试 | `while :; do …; sleep 3; done` | `retry N CMD…` | 例外见 §5-E1 |
| R3 | 下载 + sha256 | `curl` + `checksums.txt` + `shasum -c` | `net_download URL DEST SHA256` | 内建镜像回退；校验失败退出码 5 |
| R4 | 日志 | `echo "✓/✗/⚠ …"` | `log_ok`/`log_error`/`log_warn`/`log_info` | 走 stderr；stdout 契约见 C4 |
| R5 | 失败退出 | `exit 1` | `die CODE MSG`（按语义选 1/2/3/4/5） | 对外契约见 C3 |
| R6 | 子命令 + 长选项 | 手写 `case "$1"` + `--flag value` 循环 | `cli_cmd` + `cli_opt` + `cli_opts` + `cli_run` | `deploy/nas/sync.sh` 是样板 |
| R7 | 等服务就绪 | `while curl -sf /ping; do sleep 1; done` | `net_wait_port` / `net_wait_http` | 超时退出码 4 |
| R8 | 版本比较 | 字符串比较 / `sort -V` | `ver_cmp` / `ver_gt` / `ver_eq` | 非法输入返回 2，不伪装成「相等」 |
| R9 | 配置读取（env 优先） | `VAR="${VAR:-default}"` 链 | `conf_init` + `conf_get_any` | 严格格式下不合规行告警并跳过 |
| R10 | 互斥（并发部署） | 自写 pid 文件 | `lock_acquire NAME [WAIT_SEC]` | 占用返回 3 |
| R11 | 机器可读状态 | 手拼 JSON | `status_emit` + `SHELLKIT_STATUS_MODE=machine` | CI 采集用 |

## 5. 保留手写清单（会改语义 ⇒ 保留，且提交体写明理由）

| # | 场景 | 保留理由 |
|---|---|---|
| E1 | `git-fetch-safe.sh` 的「超时(2) ≠ 失败(1)」 | `retry` 不区分超时与失败；该脚本的退出码是**对外契约**（调用方据此决定「重试」还是「叫人」）⇒ 语义不可合并 |
| E2 | 全部 git 领域逻辑（默认分支解析、脏仓守卫、浅克隆下取 tag、worktree） | shellkit 无 git 抽象；且「浅克隆无 tag ⇒ `git describe` 退化成哈希」这类教训是本仓专属 |
| E3 | 设备侧脚本全部（busybox ash） | 见 C1 |
| E4 | 判据型脚本（`check-*.sh`）的**判据逻辑** | 只换 R4/R5 的管道，判据本身一个字不改 |
| E5 | 包格式命令行（fpk/ipk/apk/qpkg/spk 打包、签名、ustar 坑） | shellkit 无覆盖；改错一行 = 包装不上 |
| E6 | 冒烟断言本身（49+ 项断言、编号、判定文案） | 断言是验收契约；只换前导工具函数与日志形态 |

---

## 6. 退出码映射

| 语义 | shellkit | PigeonBox 既有 | 本轮处理 |
|---|---|---|---|
| 成功 | 0 | 0 | 一致 |
| 一般失败 | 1 | 1 | 一致 |
| 用法错 | 2 | 2（多数）/ 3（`git-fetch-safe.sh`） | 各脚本**保持既有**；新增路径用 2 |
| 前置条件不满足 | 3 | 3（QNAP `status`=未运行） | 一致 |
| 网络失败 | 4 | 2（`git-fetch-safe.sh`=超时） | 各脚本**保持既有** |
| 校验失败 | 5 | 1 | 漂移门禁用 5；其余保持既有 |

---

## 7. 门禁（新增两道 + 两处收口）

1. **`scripts/check-shellkit-vendor.sh`（新）** —— 全生态 vendor 副本逐字对账；
   零覆盖判红（「没扫到」≠「扫过且通过」，与 `#329` 同口径）；带负对照（注入漂移 ⇒ 必须变红）。
2. **`scripts/check-device-shell-ash.sh`（新）** —— 设备侧脚本的 POSIX 边界：
   - shebang 必须是 `#!/bin/sh`（或等价 ash 解释器），不得依赖 bash；
   - 不得出现 bashism（数组、`[[`、`local -n`、`mapfile`、`${v^^}`…）；
   - 必须能被 `sh -n` 解析；
   - 带负对照（注入一处 bashism ⇒ 必须变红）。
3. **`scripts/check-shell-trap-exit-code.sh`（改）** —— 认识 shellkit 的 `trap_push`/`trap_install`
   形态（函数式 trap 静态判不了 ⇒ 原来只「列出不判红」；现在把 shellkit 形态列为**合规**，
   并要求脚本里**不得同时**保留手写的不合规字面 trap）。负对照同步更新。
4. **`scripts/check-shfmt.sh` + CI 的 shellcheck 步（改）** —— 把 `vendor/**` 与
   `third_party/**` 排除出扫描射程：副本是上游镜像，格式由上游 `make fmt`（同口径 `-i 2 -ci`）保证；
   由 §7.1 的漂移门禁负责其完整性。排除的理由要写进脚本注释：**生成物勿手改**。

---

## 8. 验收标准（每条都要有命令）

```bash
# 1. 语法与静态
bash -n <每个改过的脚本>
shellcheck -S warning -x <每个改过的脚本>      # CI 同款
shfmt -i 2 -ci -l <每个改过的脚本>            # 不得有输出
# 2. 生态既有门禁
bash scripts/check-shfmt.sh
bash scripts/check-shell-var-boundary.sh --selfcheck
bash scripts/check-shell-trap-exit-code.sh --selfcheck
# 3. 新增门禁
bash scripts/check-shellkit-vendor.sh --selfcheck
bash scripts/check-device-shell-ash.sh --selfcheck
# 4. 行为等价（负→正对照，同一台机同一次流程）
#    旧脚本 vs 新脚本：同输入 ⇒ 同输出、同退出码
```

> 负→正对照是硬要求：只在**新环境**跑绿、或只跑通过没复现旧症状，都不构成证据（见
> `docs/topics/incidents/` 的判据布置教训）。

---

## 9. 上游 issue 清单（shellkit 能力缺口）

| # | 缺口 | 影响 |
|---|---|---|
| U1 | **busybox ash / POSIX sh 适配**：库内部用数组 + bash 3.2 语义 ⇒ 无法在 QNAP QTS / 群晖 DSM / OpenWrt 上运行 | 设备侧启动脚本（生态「启动脚本」的主体）完全用不上 shellkit |
| U2 | `retry` 不区分「超时」与「失败」 | `git-fetch-safe.sh` 这类「超时可重试、失败要叫人」的取数脚本无法整段替换 |
| U3 | 无 git 领域抽象（默认分支、脏仓守卫、浅克隆取 tag） | 生态里 6 个仓的 setup/取数脚本要自己写这一层 |
| U4 | 无「进程组/看门狗/后台 setsid 引导」原语 | 设备侧启动脚本的看门狗自愈循环只能手写 |
| U5 | **项目 vendor 落点硬编码 `<proj>/vendor/shellkit`**（`doctor`/`upgrade`/`repair.sh` 都只认这个路径），不可配置 | Go 模块仓里不能在仓根放 `vendor/`（Go ≥1.14 会切 vendor 模式 ⇒ `inconsistent vendoring`）⇒ 副本只能放 `third_party/` ⇒ 上游 CLI 的自检/升级/修复三条路径全部落空 |

U1 是**阻塞级**（决定了设备侧整块能否统一）；U5 是**落地阻塞级**（决定了副本能否放在
Go 仓的合法位置）；U2–U4 是可用性问题。

已提交上游（2026-11-18）：

| # | 上游 issue |
|---|---|
| U5 | https://github.com/yi-nology/shellkit/issues/143 （库副本落点硬编码 `vendor/shellkit` ⇒ Go 仓无法用） |
| U1 | https://github.com/yi-nology/shellkit/issues/144 （busybox ash / POSIX sh 子集模式） |
| U2 | https://github.com/yi-nology/shellkit/issues/145 （`retry` 不区分超时与失败） |
| U3+U4 | https://github.com/yi-nology/shellkit/issues/146 （git 领域抽象 + 进程组/看门狗原语） |

另有两条**设备侧既有缺陷**（非 shellkit 缺口，但被本轮「设备侧脚本盘点」挖出来）：

| 平台 | issue | 问题 |
|---|---|---|
| openwrt | https://github.com/pigeonbox/openwrt/issues/215 | `prewire_beam_box` 是设备侧脚本却 `#!/usr/bin/env bash` + `set -uo pipefail`；OpenWrt rootfs 只有 busybox ash ⇒ 真机上**出厂预接线静默空跑**（CI 只断言文件存在，从未执行） |
| qnap | https://github.com/pigeonbox/qnap/issues/204 | 同源脚本，另有调用点 `nohup bash "$_prewire_script"` 显式依赖 bash；QTS 无 bash ⇒ 同样空跑 |

⇒ 两者的修法一致（shebang 改 `#!/bin/sh`、去掉 `pipefail`、补「设备侧脚本在 ash 下可执行」的门禁）。
本轮**不改设备侧代码**（C1 约束 + 超出本轮范围），故以 issue 交底。

---

## 10. 风险与回滚

| 风险 | 缓解 | 回滚 |
|---|---|---|
| vendor 副本 852KB × 9 仓 ⇒ 仓库变大 | 可复现性换体积，生态已有同类资产（frontend-core tgz、p2pc 二进制） | 单仓 `git revert` 即可，无运行时依赖 |
| 脚本行为漂移（退出码/输出） | §8 的负→正对照 + 各仓自证门禁 | 各仓独立回滚，不牵连其他仓 |
| 上游 shellkit 发新版 ⇒ 全生态需同步 | 漂移门禁会把「版本不齐」显式判红 | 门禁给豁免清单 |
| 设备侧被误改（引入 bash 依赖 ⇒ 设备上直接崩） | §7.2 的 ash 门禁 + C1 | 设备侧脚本本轮**零改动** |
