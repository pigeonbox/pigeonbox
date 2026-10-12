# NAS 打包模板真相源（deploy/nas/）

[pigeonbox/synology](https://github.com/pigeonbox/synology) · [qnap](https://github.com/pigeonbox/qnap) · [ugreen](https://github.com/pigeonbox/ugreen) · [terramaster](https://github.com/pigeonbox/terramaster) 四仓 **90% 内容同源**（编排/env/图标/回挂模式各四份），且永绑同一发版列车。本目录是共享资产的**唯一真相源**，四仓只是物化结果——不合并仓库（各仓独立 CI/发版/用户入口不变），用「模板 + 同步 + 漂移门禁」消除四处手改。

## 文件

| 文件 | 作用 |
|---|---|
| `compose.yml` | 四仓共享编排模板。首行 `#__NAS_PLATFORM_HEADER__` 占位，物化时替换为各平台说明；其余内容四仓逐字一致（镜像钉版默认值也在这里） |
| `env.example` | 四仓逐字一致的 .env 模板 |
| `sync.sh` | 同步/校验引擎（见下） |
| `gen-icons.sh` | 品牌图标派生器（macOS sips/qlmanage，极少变动，再生成依据存档） |

四仓各自的**平台专属内容不入本目录**：包格式壳（SPK 的 INFO/scripts/WIZARD、QPKG 的 cfg/routines/服务脚本、zip 打包脚本）、生命周期测试（`tests/run-tests.sh`）、平台 README。

## sync.sh

```sh
bash deploy/nas/sync.sh check --all            # 工作区四仓全量校验(hub 检出内,离线)
bash deploy/nas/sync.sh sync  --all            # 模板 → 四仓物化
bash deploy/nas/sync.sh check --platform ugreen --dir ../ugreen   # 单仓(ugreen 额外校验 ghcr 加速版=compose 的镜像源替换)
```

模板来源：优先脚本同目录（hub 检出内），否则抓 `raw.githubusercontent.com/pigeonbox/pigeonbox/main/deploy/nas/`——**适配器 CI 因此可以只带自身仓库跑漂移门禁**：

- 四仓 `ci.yml` 的 lint job 各有一步「共享资产与 hub 模板对齐」：拉取本脚本对自身仓 `check`，模板一动、未同步的仓全部变红，杜绝"改了三处漏一处"。
- 同步统一用本脚本，禁止手改四仓的 compose/env.example（改了 CI 会红）。

## 发版列车(v2,release/trainctl)

跟随列车自动走:hub `train-orchestrator` 的 bump 会改本目录模板钉版,并调本脚本把
物化结果写进各仓 `train/<v>` PR;合并后编排器推 tag,各仓 CI 自动组包并回挂 hub。
手改模板后物化/校验:

```sh
bash deploy/nas/sync.sh sync --all   # 物化三仓
bash deploy/nas/sync.sh check --all  # 漂移校验(三仓 CI lint 同款)
```

## 约定

- 模板改动（编排行为/默认值/注释）→ hub 提交 → `sync --all` → 四仓各自提交（可随下次发版列车），**不要**绕过模板直接改仓内文件。
- 平台专属逻辑永远只改对应仓；hub 模板只放"四仓必须一致"的内容。
