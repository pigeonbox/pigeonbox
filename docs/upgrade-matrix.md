# N-1/N-2 制品级升级矩阵（L7 升级层）

> 归属：hub 仓（`pigeonbox/pigeonbox`）· 议题 #660 · 分层质量矩阵 **L7 升级层**。
> 本文件只描述**矩阵本身**；仓内规则（门禁纪律、提交约定等）见
> [`docs/rules/`](rules/README.md)，不在此重复。

## 0. 为什么要建这条矩阵

生态此前的升级覆盖只有**一半**：

| 已有 | 缺 |
|---|---|
| 「升级**失败**可恢复」：`scripts/check-upgrade-recoverability.sh` 收编 qnap/synology/fnos 三端既有断言（截断包中止 / 备份失败中止 / 快照轮转+逐字一致 / 换装断言 + C7 负对照） | 「从上一车/上上车的**真实制品**装起来 → 升级到当前车 → 数据完整性对账」这条链（**零覆盖**） |

缺口的后果：N-1 → N 的**制品级**升级路径（真包、真钩子、真数据）没有任何机械判定，
某端把升级钩子改坏、把钉版写错、把产物漏发，都只能等真机踩坑才发现。

## 1. 为什么分两层（不是一条门禁）

真装演练需要**当前车（N）的产物**，而 N 的产物在 N 的 PR/CI 阶段**还不存在**（还没发版）
⇒ 真装演练**不可能**当 PR 门禁 ⇒ 拆成两层：

| 层 | 位置 | 时机 | 挡不挡合并 |
|---|---|---|---|
| **① 静态矩阵** | `scripts/check-upgrade-matrix.sh` + `scripts/upgrade_matrix.py` | PR 期（并进既有 CI job 的一个 step） | 挡（但**不新增 job** ⇒ 不改 required checks 名单） |
| **② 真升级演练** | `scripts/upgrade-drill.sh` + `.github/workflows/upgrade-drill.yml` | 发布后（**快照 tag push** / 每日 cron / 手动） | 不挡（失败只开常驻 issue） |

层 ① 的挂载方式遵守 [`docs/rules/ci-gate-failures.md`](rules/ci-gate-failures.md) 的**门禁四问**：

- 挂在合并路径上吗？—— 是（并进既有的 `upgrade-recoverability` job，该 job 在 required checks 里）；
- 前面失败时还跑吗？—— 该 job 的步骤串行，前面的步骤红了本步就不会跑（形态④ 的自证另起一个 step，见 CI）；
- 依赖网络吗？—— 层 ① 的远端存在性检查**可选**：网络不可用 ⇒ 降级为「未扫描（登记在案）」，真 404 仍判红；
- 判定依赖检出形态吗？—— 依赖**平台仓在位**（判钉版要读平台仓的发布 tag）⇒ CI 用 `UPGRADE_MATRIX_REQUIRE_PLATFORM_REPOS=1` 把「缺仓」判红（缺仓不判绿）。

## 2. 层 ①：静态矩阵的判据清单

锚点：**最后一辆 `state: shipped` 的车**（而不是工作区 `train.yaml` 的车号 —— 在途的 draft 车
产物还没发布，以它为锚点必然假红）。N-1 / N-2 从 **git 历史**解析
（`release/train.yaml` 由 bump 写回，历史提交里就是当时那车；**不新建历史台账**）。

| # | 判据 | 一句话 |
|---|---|---|
| ① | 列车序列可解析 | 必须从 git 历史解析出 N / N-1 / N-2 三辆**已发货车次**，解析不出（不足 3 辆）⇒ 判红 |
| ② | 产物齐备（每车） | 每辆车的 `release/manifest.json` 必须声明 **7 个平台包**（fnos/openwrt/qnap/synology/ugreen/terramaster/desktop）+ **2 个镜像**（server/frontend），缺一即红 |
| ③ | manifest 自洽 | manifest 的 `train` 字段必须等于该车的车号（防「拿上一车的清单冒充本车」） |
| ④ | 钉版声明 == 产物内嵌（fnos/qnap/openwrt） | 平台仓 **发布 tag**（`v<X>`）里的 `DEPS.env`：`CORE_PIN`/`FRONTEND_CORE_PIN`/`P2PC_REF` 必须分别等于该车 `train.yaml` 的 `terminal.<plat>.core_pin`/`terminal.<plat>.frontend_core_pin`/`terminal.p2pc_ref` |
| ⑤ | 钉版声明 == 产物内嵌（synology/ugreen/terramaster） | 平台仓 tag 里的 `env.example` 的 `PB_IMAGE_TAG` 必须等于该车 `images.server` |
| ⑥ | 钉版声明 == 产物内嵌（desktop） | 平台仓 tag（`desktop-v<X>`）里的 `VERSION` 必须等于该车 `terminal.desktop.version` |
| ⑦ | 钉版单调 | `lib.core` / `lib.frontend-core` / `lib.p2p` 必须 **N-2 ≤ N-1 ≤ N**（不许倒退；N 也不许比 N-1 老） |
| ⑧ | 远端产物存在（可选层） | hub Release 上 `v<X>` 与 `<plat>-v<X>` 必须存在且非草稿；**404 ⇒ 红**（产物真缺），**网络不可用/限流 ⇒ 降级为「未扫描（登记在案）」**（不得伪装成通过） |

> ⑧ 的降级口径与 `check-docs-consistency.sh` 的 `DOCS_GATE_*` 覆盖范式同源：
> 「没扫到」≠「扫过且通过」，输出里必须能看到 `⏳ 未扫描：…`。

## 3. 层 ②：真升级演练的覆盖面

### 3.1 触发机制（2026-11-18 重构：原路径**结构性不可达**）

原触发是 `release: types: [published]` + job 级 `if: github.event_name != 'release' ||
!contains(github.event.release.tag_name, '-')`（只让「hub 快照 release」跑）。实测：

- hub 快照 release（`v6.6.0`）由 **GITHUB_TOKEN** 创建 ⇒ GitHub **不为
  GITHUB_TOKEN 造的事件起新 run** ⇒ 该事件**永远不触发**；
- 组件 release（`<plat>-v6.6.0`）由**用户 PAT** 创建 ⇒ 会触发 workflow，但一列车
  触发 8 次 ⇒ 被上面的 `if` 全部排除；
- ⇒ 「能触发的全被排除、该触发的永远不触发」⇒ 历史 8 次 run 全部 `skipped`，
  **这个工作流从未真正跑过**。

现在的主触发是 **hub 快照 tag 的 push**（`on: push: tags: ['v[0-9]*']`）：

- 列车由用户 PAT（`PB_BOT_TOKEN`）推快照 tag ⇒ **push 事件必然触发**，且每车恰好一次；
- 触发不再取决于「谁创建了 release」（快照 release 仍由 GITHUB_TOKEN 建，不影响触发）；
- 组件 tag（`fnos-v6.6.0` 等）无 `v` 前缀 ⇒ **不匹配**该过滤器 ⇒ 不会再触发 8 趟。

配套三件事：

| 机制 | 做什么 | 为什么 |
|---|---|---|
| **按车次去重** | cron / 手工路径：若该车次已有**成功**的演练 run ⇒ 跳过（响亮打印，非静默） | 兜底路径不重复跑大体积下载；push 路径不去重（重推 tag 允许重跑） |
| **等产物就位** | `scripts/upgrade_matrix.py wait-artifacts`：轮询 hub 的平台包 release（`<plat>-v<车号>`）直到**资产齐**或超时；**超时 ⇒ 响亮失败** | 快照 tag 推上去的瞬间平台包可能还没发布完 ⇒ 演练会一头撞 404；**静默跳过 = 没门禁** |
| **pipefail** | 真演练那一步 `set -o pipefail` | 管道默认只取 `tee` 的退出码 ⇒ 演练失败会被吞掉（失败不报错 = 没门禁） |

每日 cron 是兜底：它解析「最后一辆**已发货**车次」（`upgrade_matrix.py plan`），
该车次若已成功演练过 ⇒ 去重跳过；没演练过（或演练失败）⇒ 补跑。

### 3.2 每一格演练的链

每一格演练的链（`scripts/upgrade-drill.sh`）：

1. 下载 N-1 / N-2 的**真实产物**（hub Release 资产），按当车 manifest 的 **sha256 逐字校验**；
2. 解包到**隔离目录**（不进真机路径，不碰任何真实数据）；
3. 在**该平台真实的数据目录口径**上植入业务数据（一个 DB 文件 + 一个上传文件）；
4. 走该平台**既有的升级钩子**（产物内自带）⇒ 生成回滚点；
5. 用 **N 的产物**覆盖升级；
6. 断言三条：**业务数据逐字未变**（DB + 上传文件 sha256）、**版本号已更新为 N**、**回滚点存在且逐字等于升级前的库**。

| 平台 | 产物形态 | 隔离钩子 | 做到了哪一步 | 矩阵 `level` |
|---|---|---|---|---|
| synology | `.spk` = 普通 tar | 产物内 `scripts/preupgrade`（`SYNOPKG_PKGVAR` 可覆盖） | **全链**（数据/版本/回滚点三条断言） | `hook` |
| qnap | `.qpkg` = 自解压壳 + tar 载荷 | 产物内 `package_routines` 的 `pkg_pre_install`（`FCB_GETCFG` 可 mock） | **全链** | `hook` |
| openwrt | `.ipk` = tar.gz{control,data} | 包内 `preupgrade_backup`（`PB_PREUPGRADE_DB` 可覆盖） | **全链** | `hook` |
| fnos | `.fpk` = tar.gz | —— | **制品级**（解包/换版/数据未变/版本已更新；无回滚点断言） | `artifact` |
| ugreen / terramaster | `.zip` 编排壳 | —— | **制品级**（同上） | `artifact` |
| desktop | dmg/msi/exe/deb/rpm/AppImage | —— | **不做**，原因见下 | `device`（只能人工真机） |

演练每格结束会打印**机器可读**的层级结论（与兼容矩阵 `release/compat-matrix.json`
的 `level` **同一套词表与口径**）：

```
  ✓ synology：业务数据逐字未变 + 版本已更新为 6.6.0-0001 + 回滚点在位且逐字一致
  DRILL_LEVEL platform=synology level=hook
```

⚠️ **矩阵不由演练自动回写**：演练只产出结论，兼容矩阵仍由人工按证据登记
（登记口径见 [`docs/COMPAT-MATRIX.md`](COMPAT-MATRIX.md)）。

**fnos 为什么只到制品级**：它的升级回调是 fnOS 运行时二进制（`cmd/upgrade_callback`），
只在 fnOS 应用中心的环境里跑，没有「指向隔离目录」的入口 ⇒ CI 里无法脚本化。
（它的数据目录本身就在共享卷里，不在制品内 ⇒ 制品级换版天然不碰数据。）

**desktop 为什么做不了**：产物是**各操作系统**的安装包（dmg/msi/exe/deb/rpm/AppImage），
既没有「解包即安装目录」的统一形态（每个平台的安装布局与提权模型都不同），
应用数据目录也由操作系统托管 ⇒ CI（Linux runner）里无法脚本化。
要覆盖只能靠真机验收，属人工验收范畴。

## 4. 层 ③：迁移中途失败（矩阵里的「失败注入」这一格）

最危险的一格不是「升级成功」，而是「升级**中途**失败」：数据搬迁/快照写到一半失败时，
旧版本必须**仍可启动**、业务数据必须**无损**、失败必须**可见**、且**不留半份快照**
（半份快照比没快照更坏 —— 它看着像回滚点，实际残缺，真回滚会把用户数据搞坏）。

实现：`scripts/check-upgrade-migration-failure.sh` —— 跑各平台**真实**的升级钩子
（不是复刻逻辑），用注入的 `cp` 失败模拟「写一半失败」，逐端判定四条 + 退出码语义：

| 平台 | 钩子 | 失败语义 |
|---|---|---|
| qnap | `qpkg/package_routines` 的 `pkg_pre_install` | **中止型**：失败 ⇒ 中止升级（退出码非 0） |
| synology | `spk/scripts/preupgrade` | **中止型**：失败 ⇒ 中止升级（退出码非 0） |
| openwrt | `openwrt/preupgrade_backup` | **best-effort 型**：失败 ⇒ **不得**中止安装（退出码恒 0；它跑在新文件已就位之后，abort 只会把服务留在停机状态），但必须响亮报错 + 不留残缺快照 |

该形态已并入 `scripts/check-upgrade-recoverability.sh` 的统一入口（形态④），
并进了 `--selfcheck` 的负对照列表（七形态）。

## 5. 怎么在本地跑

```bash
# 层 ① 静态矩阵（自证 + 判定）
bash scripts/check-upgrade-matrix.sh --selfcheck
bash scripts/check-upgrade-matrix.sh

# 层 ③ 迁移中途失败（需要平台仓在位；否则打印「跳过形态」）
UPGRADE_MIGRATION_ROOT=<生态仓根> bash scripts/check-upgrade-migration-failure.sh
bash scripts/check-upgrade-migration-failure.sh --selfcheck

# 层 ② 真升级演练（会下载真产物；--selfcheck 用本地假制品替身，不联网）
bash scripts/upgrade-drill.sh --selfcheck
bash scripts/upgrade-drill.sh --platforms synology

# 等产物就位（发布后演练的前置闸；超时响亮失败）
bash scripts/upgrade-drill.sh --wait-artifacts
python3 scripts/upgrade_matrix.py wait-artifacts --root . --train 6.6.0 --timeout 1800
```

env 覆盖见各脚本头部注释（`UPGRADE_MATRIX_*` / `UPGRADE_MIGRATION_*` / `UPGRADE_DRILL_*`）。

## 6. 与既有门禁的关系

- 层 ① 并进既有 `upgrade-recoverability` job 的 step（**不新开 job** ⇒ required checks 名单不变）；
- 层 ③ 并进 `scripts/check-upgrade-recoverability.sh`（同一统一入口，**七形态**自证）；
- 层 ② 是独立 workflow（`upgrade-drill.yml`），**不在合并路径上** ⇒ 失败只开/更新常驻 issue
  `🛠 upgrade-drill-fail`（与 `train-verify` 的 `🎯 train-drift` 同范式）。
