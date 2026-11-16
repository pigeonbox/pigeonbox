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

## 怎么登记一条结果

1. 在真机（或对应平台环境）按「安装 → 首次分享 → 升级 → 取件 → 回滚」走完；
2. 编辑 `release/compat-matrix.json` 对应格点：
   - 通过：`status: "verified"` + `evidence`（issue/PR/run 链接）+ `updated`；
   - 失败：`status: "failed"` + `evidence` + `repro`（最小步骤）+ `updated`；
   - 不适用：`status: "unsupported"` + `evidence` 写理由；
3. 本地验证：`cd release/trainctl && go run . compat --check`（红灯/缺格非零退出）；
4. 随 PR 提交。**同一平台同一跨度可以有多条格点**（不同架构/部署形态），
   一屏聚合显示最坏状态（绿不能盖住红）。

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