# 跨平台升级兼容矩阵（pigeonbox#386）

> 机器可读真相源：`release/compat-matrix.json`。
> 一览命令：`trainctl compat`（红灯/缺口/未验计数 + 平台 × 跨度表）。
> 发车闸：`trainctl preflight` 的第六道闸——**红灯格点与缺格拒绝发车**，
> 未验只报黄（诚实登记即可发车）。

## 为什么要这张表

六平台适配仓（fnOS / OpenWrt+iStoreOS / Synology DSM / QNAP QTS / UGREEN UGOS /
TeraMaster TOS）+ desktop 的升级路径、数据布局、包格式各不相同。此前验证靠发版时
逐仓真机冒烟，结论散落在 issue 与发布说明里 ⇒ **「谁验过哪条路径、哪些跨度根本
没人走过」无法回答**。

矩阵把「验过 / 没验过 / 验出问题 / 不适用」变成一等状态：没验过的格点必须**显式
登记为 `unverified`**——从表里消失比红灯更危险（缺口看不见，红灯至少有人负责）。

## 维度

| 维度 | 取值 |
|---|---|
| 平台 | `train.yaml` 的 `terminal.<name>.tag` 清单（与列车单源）：desktop / fnos / openwrt / qnap / synology / terramaster / ugreen |
| 版本跨度 | `N-1`（相邻版）/ `N-2`（隔一版）/ `major-cross`（跨大版本） |
| 架构 | `amd64` / `arm64` / `armv7`（格点内声明覆盖集合） |
| 部署形态 | `native`（NAS 原生包）/ `compose` / `k8s` |
| 跨度声明 | `from` / `to`（产品版本 `X.Y.Z`，不带 v）＝**实际验过的跨度**（schema 2 起；`verified`/`failed` 必填） |

> ⚠️ **`N-1` / `N-2` 是相对「当前车」的相对跨度，不是固定版本号。**
> 当前车 N=6.8.0 时 N-1=6.7.0、N-2=6.6.0；发到 6.9.0 后同一格分别指 6.8.0 / 6.7.0。
> ⇒ **发新车会让旧证据的跨度语义整体漂移**：一格写着「6.5.0→6.6.0」的 `verified`
> 证据，到 N=6.8.0 时已不覆盖它该覆盖的路径。
> ⇒ 回写或复核证据时**必须核对跨度与当前车对齐**。
>
> **schema 2 起（2026-11-18）跨度已结构化并机判**：每格可写 `from` / `to`（产品版本
> `X.Y.Z`，不带 v 前缀）＝**实际验过的跨度**。`compat --check` 现在判：
>
> ① `verified` / `failed` 格点**必填** from/to（没有跨度声明就没有可核对的跨度主张）；
> ② **跨度类别 ↔ 实际距离一致**：`N-1` = 同大版本内相邻 minor、`N-2` = 同大版本内隔一个 minor、
>    `major-cross` = 跨大版本（`N-1`/`N-2` 跨大版本 ⇒ 判红，要求改登记为 `major-cross`）；
> ③ `from` 必早于 `to`（方向倒置 ⇒ 判红）；
> ④ **相对当前车**：`to` 晚于当前车 ⇒ **判红**（证据不可能覆盖尚未发车的版本 ⇒ 假绿）；
>    `to` 停在更早版本 ⇒ **报黄**（陈旧：发车后的演练尚未跑完，需刷新，但不阻断发车）。
>
> ⇒ 「标 N-1、证据其实跨了两版」这类错位（实测 synology 两格出现过）从此**机判**，不再靠人读文本。

每个格点至少一条可执行验收路径：**安装 → 首次分享 → 升级 → 取件 → 回滚**，
结果（耗时 / 失败点）写进 `evidence`；失败还要写 `repro`（最小复现步骤，
进下一次回归）。

## 状态语义（判据）

| 状态 | 含义 | 判定 |
|---|---|---|
| `verified` | 真机验过且通过 | **必须**带 `evidence`（issue/PR/run 链接） |
| `failed` | 验出失败 | **必须**带 `evidence` + `repro`（最小复现步骤）；发车闸判红 |
| `unverified` | 从未验证 | 必须是显式登记（缺格判红）；发车闸报黄不阻断 |
| `unsupported` | 该平台该跨度整体不适用 | `arches` 可空；需在 evidence 说明理由 |

为什么 `unverified` 不判红：要求「全绿」才能发车，在矩阵刚建立时等价于永远发
不了车——那会逼人填假绿。诚实登记 + 缺口判红，才是可持续的口径。

## 当前矩阵（2026-11-16 首版）

| 平台 | N-1 | N-2 | major-cross |
|---|---|---|---|
| desktop | ⬜ | ⬜ | ⬜ |
| fnos | ✅（5.7.0→5.8.0 原地换装，需 appcenter-cli stop/start；pigeonbox#240） | ⬜ | ⬜ |
| openwrt | ⬜ | ⬜ | ⬜ |
| qnap | ⬜ | ⬜ | ⬜ |
| synology | ⬜ | ⬜ | ⬜ |
| terramaster | ⬜ | ⬜ | ⬜ |
| ugreen | ⬜ | ⬜ | ⬜ |

图例：✅ verified · ❌ failed · ⬜ unverified · — unsupported。
（本表以 `trainctl compat --markdown` 的输出为准，手改不落盘。）

## 证据从哪来（`level` 三档的取证手段）

`level` 是**证据强度**，不是平台属性：同一平台在不同跨度上可以取到不同强度的证据。

| level | 取证手段 | 判什么 |
|---|---|---|
| `hook` | 制品级升级演练实跑（`scripts/upgrade-drill.sh`，真实包 + 平台自带升级钩子） | 业务数据逐字未变 + 版本已更新 + 回滚点在位且逐字一致 |
| `artifact` | 同上演练，但该平台是 compose 编排壳、**没有隔离可跑的钩子** ⇒ 验到制品级（解包/换版/数据未变/版本已更新） | 同上，去掉回滚点断言 |
| `device` | 真机：NAS 原生包**原地换装**（含应用中心注册表、网关能力、随包组件的真实版本）或桌面客户端真机安装 | 端到端可用 + 数据零丢失 + 跨升级不变量逐字未变 |

演练的触发与覆盖面见 [`upgrade-matrix.md`](upgrade-matrix.md)；device 级的真机
流程与坑位见各平台仓（fnOS 的换装脚本在 `fnos/scripts/upgrade-inplace.sh`）。

⚠️ **fnOS 真机三坑**（2026-11-18 真机实录）：

1. **启停必须走 `appcenter-cli` 框架托管**（`stop`/`start`）——手工拉起进程拿不到
   `TRIM_APPDEST`/`TRIM_API_TOKEN` ⇒ `capabilities` 回报 `gateway=false/sso=false`
   ⇒ 统一网关免登录**静默失效**，而退出码与 `/version` 自证全绿；
2. **验收脚本必须以 root 跑**——非 root 时 `appcenter-cli list` 读不到应用中心注册表
   ⇒「注册表版本」那条**假红**（同一脚本 root 下是绿的）；
3. **换装脚本要连 `third_party/shellkit` 一起拷到设备**——6.8.0 版的
   `upgrade-inplace.sh` 会硬检查它，缺库直接退出。

## 怎么登记一条结果

1. 在真机（或对应平台环境）按「安装 → 首次分享 → 升级 → 取件 → 回滚」走完；
2. 编辑 `release/compat-matrix.json` 对应格点：
   - 通过：`status: "verified"` + `evidence`（issue/PR/run 链接）+ `updated`；
   - 失败：`status: "failed"` + `evidence` + `repro`（最小步骤）+ `updated`；
   - 不适用：`status: "unsupported"` + `evidence` 写理由；
3. 本地验证：`cd release/trainctl && go run . compat --check`（红灯/缺格非零退出）；
4. 随 PR 提交。**同一平台同一跨度可以有多条格点**（不同架构/部署形态），
   一屏聚合显示最坏状态（绿不能盖住红）。

> `evidence` 里请**写清实际走过的版本跨度**（如 `6.7.0→6.8.0`）与证据出处
> （issue / PR / run 链接）——跨度相对当前车会漂移，写清跨度才能在下一车核对
> 「这格还覆盖得住吗」。

## 命令

```bash
cd release/trainctl
go run . compat              # 一屏：计数 + 平台×跨度表 + 红灯格点复现清单
go run . compat --check      # 红灯/缺口 ⇒ exit 1；未验 ⇒ 黄（exit 0）
go run . compat --markdown   # 渲染 Markdown 表（贴 docs / 发布说明）
go run . preflight TRAIN=x.y.z   # 发车六道闸（第六道 = 本矩阵）
```

CI：`.github/workflows/ci.yml` 的 trainctl job 跑 `compat --check`（自洽 +
无红灯），矩阵文件改坏即红。

## 与其它门禁的关系

- **#365/平台能力契约**：能力声明回答「平台声明支持什么」，本矩阵回答
  「哪些升级路径真的验过」——声明与验收背书互补；
- **#240 生态债清单**：真机验收项的**结果**逐渐迁入矩阵（清单继续做总览）；
- **charts HA 演练**（`docs/HA-DRILLS.md`）：部署形态为 `k8s` 的格点可用
  演练脚本作为证据来源。