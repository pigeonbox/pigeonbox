# 升级指南

怎么把运行中的 PigeonBox 升到新版本，以及哪些版本之间**不兼容**。

> 本文是升级路径的**唯一真相源**；文档站的「升级指南」页直接引用本文件，不在页面里另写一份。
> 各版本的完整变更（组件矩阵、破坏性变更清单）见 [生态主仓 Releases](https://github.com/pigeonbox/pigeonbox/releases) 与文档站「版本发布说明」。

## 升级前必做的三件事

**① 备份数据目录。** 业务库（SQLite）与上传文件都在同一个数据目录里，整目录拷走最省事：

```bash
cp -a data /backup/pigeonbox-data-$(date +%F)
# 不停机的一致性快照（只拷库）：
sqlite3 data/fileCodeBox.db ".backup '/backup/fileCodeBox.db.bak'"
```

匿名取件码的映射在 Redis（compose 默认用命名卷 `redisdata`）；单机内存模式下它在进程内，
重启即失效——**跨机迁移**时两者都要一并带走。

**② 读这次的破坏性变更。** Release 页开头的「破坏性变更」表 = 你必须逐条核对的东西。
标「需检查」的项是**行为变了但不报错**的那一类，漏看不会有任何提示。

**③ 记下回滚点。** 记下当前镜像 tag / 包文件名。回滚靠的就是它——
4.0.0 这类含**删列**与**磁盘布局上提**的版本一旦跑过启动迁移，回滚前必须先恢复到①的备份。

## Docker Compose

```bash
# 1. 备份（见上）
# 2. .env 钉住新版本（server/frontend 两镜像同 tag 一起更新，写具体版本而不是 latest）
vi .env    # PB_IMAGE_TAG=5.3.0
# 3. 拉镜像并重建容器（必须 force-recreate；数据卷不动）
docker compose pull && docker compose up -d --force-recreate
# 4. 验真
curl -s http://localhost:12345/live
docker compose logs --tail=50 pigeonbox
```

**回滚**：把 `.env` 的 `PB_IMAGE_TAG` 改回旧版本号，再走第 3 步重建即可（数据卷不动）。
若新版本已发生不可逆迁移，回滚前先恢复第 1 步的备份。

国内网络拉不动 ghcr.io 时，把镜像前缀换成 `ghcr.nju.edu.cn`（`docker tag` 回原名再重建），
或在别的机器 `docker save` 后导入。

## Kubernetes（Helm）

```bash
helm repo update pigeonbox
helm upgrade <release> pigeonbox/pigeonbox --version <chart 版本> -n <命名空间>
```

镜像 tag 跟随 chart 的 `appVersion`；要单独钉镜像版本就设 `image.tag`。
**回滚**：`helm rollback <release> <revision>`。PVC 不会随回滚变化——含删列的版本同样要先备份。

## 飞牛 fnOS（fpk 原生）

**能从应用中心升级就走应用中心**（托管启停、升级、回滚）。

应用中心装不了原生第三方包时，用仓内的原地换装脚本——它会把 `target/{www,bin,ui}`、
`cmd/`、`manifest`、`wizard/` 一起换掉，并**保留**面板 `config/`：

```bash
sudo bash upgrade-inplace.sh pigeonbox-<版本>.fpk
# 验真
curl -s http://127.0.0.1:12345/version.txt
```

::: danger 不要用 `appcenter-cli install-local`
它是**卸载→安装**语义：会先删光 `@appdata`（含业务库）与注册表行，原生包装不进去还会报 10237。
真机实录过一次数据全灭，只能靠动手前的备份救回。
:::

- 升级窗口内框架会调 `cmd/upgrade_callback` **自动快照业务库**：
  `data/fileCodeBox.db.bak-<时间戳>`，轮转保留最近 3 份。手动恢复＝应用设置里停止应用 →
  用备份覆盖 `data/fileCodeBox.db` → 启动。
- 生命周期脚本必须随包一起换（`cmd/`）。只换二进制不换 `cmd/` = **静默半升级**：
  新版本新增的启动逻辑不会生效。换装脚本已覆盖这一步，有守卫脚本盯它。

## OpenWrt / iStoreOS（ipk / apk）

覆盖安装即升级（无需先卸载，数据与配置保留在 `/etc/pigeonbox/`）：

```bash
# opkg 系（OpenWrt / iStoreOS 22.03、23.05）
wget -O /tmp/pigeonbox.ipk https://github.com/pigeonbox/openwrt/releases/download/v<版本>/pigeonbox_<版本>-1_<arch>.ipk
opkg install /tmp/pigeonbox.ipk

# apk 系（OpenWrt 25.12+）
wget -O /tmp/pigeonbox.apk https://github.com/pigeonbox/openwrt/releases/download/v<版本>/pigeonbox-<版本>-r0_<arch>.apk
apk add /tmp/pigeonbox.apk      # 未预置签名公钥时加 --allow-untrusted
```

安装/升级会重启 rpcd 使 ACL 生效——**重新登录 LuCI** 才能看到菜单。

## 群晖 DSM（SPK）

套件中心 → **手动安装** → 上传新的 `pigeonbox_<版本>.spk`（DSM 会走 `preupgrade` / `postupgrade`）。
未签名包提示「发布者无法验证」，确认继续（DSM 7.x 无信任级别设置，属预期）。

- `postupgrade` 会把 `.env` 的 `PB_IMAGE_TAG` **对齐到包内 `env.example`**（包自带的真相源），
  再重启容器按新版本重建；数据目录不变。
- 1.14.3 及更早的包把向导值写成 `FCB_*` 前缀，升级到此版会自动迁移成 `PB_*`，
  不迁移＝端口 / 数据目录 / 管理员密码全部丢失。迁移是自动的，但**备份仍然要留**。
- 卸载默认保留数据目录；数据目录属主需为 uid 1000（安装时自动处理）。

## 威联通 QTS（QPKG 原生）

App Center → 右上角**手动安装** → 上传新的 `PigeonBox_<版本>_<架构>.qpkg`。
同名覆盖安装＝升级，包脚本负责停进程、换包、再起；卷根 `pigeonbox/` 下的数据
（SQLite 库与上传文件）**不在安装目录里**，升级不碰。

从 Docker 旧版（≤1.14.3）升级：直接装新 QPKG，原地切原生进程，数据无缝延续；
升级钩子会清掉旧编排遗留的死配置行（`PB_IMAGE_TAG` / `FCB_API_PORT` 等）。

## 绿联 UGOS Pro / 铁威马 TOS（compose 项目导入）

**升级 = 改 YAML 里两处镜像 tag → 重新部署**，数据目录不动：

```yaml
services:
  pigeonbox:
    image: ghcr.io/pigeonbox/server:5.3.0     # ← 改成新版本
  pigeonbox-frontend:
    image: ghcr.io/pigeonbox/frontend:5.3.0   # ← 两处要同号
```

绿联：Docker 管理器 → 项目 → 编辑 compose → 重新部署。
铁威马：项目 → 编辑 YAML → **验证 YAML** → 应用。铁威马要保留端口 22/80/443/8181/5050。

## 回滚

| 形态 | 回滚做法 |
|---|---|
| Docker Compose / 群晖 / 绿联 / 铁威马 | `PB_IMAGE_TAG`（或 YAML 的 `image:`）改回旧版本号，重建容器 |
| Kubernetes | `helm rollback <release> <revision>` |
| 飞牛 fnOS / 威联通 QTS / OpenWrt | 重新安装旧版本的包（历史包在 [生态主仓 Releases](https://github.com/pigeonbox/pigeonbox/releases) 的 `fnos-v*` / `qnap-v*` / `openwrt-v*` tag 下） |

**回滚的限制**：所有形态的回滚都**不还原数据**。4.0.0 的删列与磁盘布局上提是不可逆的，
跑过启动迁移之后要回滚，必须先恢复到升级前的备份。

## 升级后验真

```bash
curl -s http://<地址>:<端口>/live        # 存活探针，返回 200
curl -s http://<地址>:<端口>/readyz      # 就绪探针（DB/存储就位）
```

配置了 API Key 的话，跑一次 `pb doctor` 做完整自检（DB / 存储 / Redis / 版本 / 站点地址 /
首启 / 时钟），退出码 **0=健康 · 1=有待处置项或故障 · 2=用法错误**，可以直接进 CI。
管理台「诊断」页是同一份数据的网页版。

## 跨版本兼容矩阵

| 起点 | 目标 | 可否直接升 | 说明 |
|---|---|---|---|
| 4.x / 5.x | 5.x | ✅ 直接升 | 3.0.0 与 4.0.0 两个破坏性节点已经在身上发生过；此后各趟车零破坏 |
| 3.x | 5.x | ✅ 直接升，**必须先整目录备份** | 跨过 4.0.0：会**删列**并**上提磁盘布局**，不可逆 |
| 1.x / 2.x | 5.x | ⚠️ 建议逐节点推进 | 跨度太大时先升到 3.x 最新、再升 4.x、再升 5.x，每跳前都备份 |

**破坏性节点只有两个**（其余各趟车都是零破坏，直接升即可）：

| 节点 | 变了什么 | 不可逆的部分 |
|---|---|---|
| **3.0.0** | 设备直传拆出为独立应用 PigeonBeam；直传端点 / MCP 工具 / CLI 子命令 / 镜像随包 p2pc 全部移除；首启不再播种 `admin/admin123` | 无（纯能力面移除，数据不动） |
| **4.0.0** | 旧版本兼容层整轮退役：删 `file_codes.prefix`/`suffix` 两列、删契约字段、`file_path` 语义统一、磁盘双层布局上提 | **删列**与**布局上提**不可逆 |

**PigeonBeam 的双端一致性**：直传 wire 协议有版本（当前 v4）。升级 Box 时若同时用 PigeonBeam，
两端要按同一趟车的钉子对齐（NAS 三端随包 p2pc，版本见 Release 矩阵的 `lib.p2p`）。

## 版本变更要点（历史列车）

### 4.0.0（旧版本兼容层退役 · 破坏性）

- **为「旧客户端 / 旧后端 / 旧链接 / 旧字段 / 旧形态」保留的兼容分支整轮移除**。升级即生效，多数项是**自动迁移**（启动时幂等执行，无需人工介入）；下面标「需检查」的两项请逐条核对。
- **接口成功码不变**：仍是 `code: 0`（见错误码对照表）。本次只收敛了**官方前端内部**的成功码判定（视图层统一认 `200`，由请求层把服务端的 `0` 归一化而来）——**集成方请继续只认 `0`**。
- **退役项一览**：

| 退役项 | 表现 | 处理 |
|---|---|---|
| `file_codes.prefix` / `file_codes.suffix` 两列 | 列被删除；分享列表不再下发这两个字段 | 自动迁移（启动期删列；全库恒空、无写入方） |
| 契约字段 `UserShareItemData.prefix` / `UserFileItem.prefix`+`suffix` | 响应体不再含这两个键 | 自动（前后端同版本升级即可）；自研客户端请改用 `file_name` |
| 旧直传开关 `download.presign_anonymous_enabled` | 该键不再被读取 | 自动迁移（读配置时并入 `download.presign_policy`）；**需检查**：曾用该键关闭匿名直传的站点，请确认 `presign_policy` 取值符合预期 |
| 旧文件清单形态（「虚拟行 id=0」） | 取件页文件清单不再出现 id=0 的合成项 | 自动迁移（启动期回填子表） |
| `file_path` 列双语义（「目录 + UUID 文件名」/「完整相对路径」） | 统一为「完整相对路径」 | 自动迁移（启动期归一存量行）；**需检查**：若有自研脚本按旧形态拼路径，请改按完整相对路径 |
| 存储磁盘历史双层布局（`<root>/uploads/uploads/…`） | 读路径不再回退到双层位置 | 自动迁移（启动期同盘 rename 上提一层，冲突跳过不覆盖）；**需检查**：若有脚本直接读 `data/uploads/uploads/`，请改读 `data/uploads/` |

- **取件计数失败改为 fail-closed**：计次（owner 设的「最多取 N 次」）写库失败时**不再照常交付文件**，而是返回 500 提示稍后重试——避免数据库抖动期间「最多 N 次」承诺失效。
- **库线版本**：contracts v0.19.0 · core v0.32.15 · frontend-core v0.11.30。壳仓与 NAS 包的 tgz/二进制钉版由列车统一抬升。

::: warning 升级到 4.0.0 前请确认
① 备份 `data/`（见上方清单）——本次有**删列**与**磁盘布局上提**两类不可逆变更；② 核对上表两项「需检查」；③ 若有自研客户端读取被删的 `prefix`/`suffix` 字段，需先改用 `file_name`。
:::

### 3.0.0（设备直传拆出列车 · 破坏性）

- **设备直传拆为独立应用 PigeonBeam（信鸽直传）**：Box 侧不再编排直传数据面。`core` 的 `p2px` 域、contracts 的 9 个直传管理端点、MCP 直传四工具、`pb p2p` 的 5 支直传子命令、server 镜像随包 p2pc、desktop 的 p2pc sidecar **全部移除**。直传请用 [PigeonBeam](https://github.com/pigeonbox/p2p)。
- **Box 侧保留联邦面**：4 个 `/admin/p2p/*` 端点（待收邀请 / 认领信封 / 推送 / 在线名录）、MCP 3 个联邦工具、`pb p2p` 4 支子命令。`POST /admin/p2p/invites/accept` 的返回体从「直传任务」改为**纯信封**——认领只出信封，文件接收由 PigeonBeam 完成。
- **首启行为变了（升级后需确认）**：不再播种弱口令 `admin/admin123`。`PB_ADMIN_PASSWORD` 留空 → 走 `/setup` 首启向导（浏览器打开站点建号）；已设则按该密码建 admin。**存量实例不受影响**（库中已有 admin，core 直接返回）。
- **陈旧配置会响亮提示**：若你的 `SystemConfig` 里还留着 `p2p.direct.*`（旧直传段），启动日志会明确告警「检测到陈旧配置 p2p.direct.*，已忽略；请把 registry_url 改配到 p2p.federation.registry_url」——**不是静默失效**，请照提示改。
- **管理台左导航改名**：「P2P 与联邦」分区改为「联邦」，直传控制台页移除（联邦面板独立成页）。
- **库线版本**：contracts v0.18.0 · core v0.27.0 · frontend-core v0.9.0。壳仓与 NAS 包的 tgz/二进制钉版由列车统一抬升。

::: warning 升级到 3.0.0 前请确认
① 备份 `data/`（见上方清单）；② 若你用过设备直传，**先确认 PigeonBeam 侧的替代路径**，本次升级会移除 Box 内的直传编排；③ NAS 端升级会顺带更新内嵌前端，旧的直传控制台页会消失（预期行为）。
:::

### 1.22.0（P2P 邀请推送列车）

- **联邦实例间推送邀请**：已建立联邦关系的站点间可在管理后台直接推送传输邀请（对方待收/认领），免手工口令交接；公开收件端点 `POST /api/v1/p2p/invite`（限流归桶，口令=bearer 信任级同手工交接）。
- **pb CLI 扩展**：新增 `pb p2p` 八支子命令（status/tasks/send/recv/cancel/invites/accept/push），admin API Key 通道。
- **p2pc `--json`**：NDJSON 事件流输出（code/done/error），供脚本/自动化消费；缺省纯文本输出不变。
- 直传双端协议仍为 wire v4：随列车把各端 p2pc 一并升级即可（server 镜像/NAS 包/desktop sidecar 均已随包钉版）。

### 1.21.0（P2P 对称节点列车）

- **P2P 联邦与设备直传收进管理后台**：「系统配置 → P2P 与联邦」分区热启停，保存即生效无需重启；旧 env/yaml 配置作为首启种子自动迁移，之后以数据库配置为准。
- **设备直传开箱可用**：server 镜像与 fnos/qnap/openwrt 包自本版起随包 p2pc 二进制，无需额外安装；管理后台新增「设备直传」控制台（发送/接收/发布为分享）。
- **standalone 专属**：多副本拆分部署（`PB_DEPLOY_MODE=public/admin`）下 P2P 能力自动降级关闭。
- **p2p wire 协议 v4**（p2p v0.6.x）：与 v3 之前互不兼容，直传双端（含 desktop sidecar、各端随包 p2pc）须同版升级——全端随本列车同号发布，一起升级即可。
- 取件输入锁定 6 格（超长粘贴自动转分享码链路）；管理后台配置页改左导航 7 分区。

### 1.17.0（产品版本统一列车）

- **版本号口径变化**：server/frontend 镜像 tag 由 `0.15.x` 形态并入产品号（`1.17.0` 起，无 `v` 前缀）；升级时把 `PB_IMAGE_TAG` / chart `image.tag` 直接写新版本号即可，存量 0.15.x 钉版镜像仍可拉取。
- 七终端应用包（desktop/fnos/openwrt/synology/qnap/ugreen/terramaster）同号发布，包内页脚版本与镜像一致。
- **秒传去重**：同账号重复上传同内容文件命中去重免落盘；删除分享按引用计数保护物理文件（被其他分享引用的文件不随删除消失）。

### 0.12.x（会话 Cookie 化列车）

- **浏览器会话迁 HttpOnly Cookie**：前端不再持久化令牌；第三方脚本/桌面端继续走 `Authorization: Bearer` 与 API Key，零改动。Cookie 认证的写请求须携带 `X-Requested-With: XMLHttpRequest`（CSRF 防御，前端已内置）。
- **密码分享取件页修复**：业务性 401（需要密码/密码错误）不再触发会话刷新，匿名取件人不再被跳转登录页。
- **p2p 直传协议 v2**（p2p v0.4 / desktop v1.3.1）：与旧版互不兼容，双端须同版升级。
- **CSP**：前端 nginx 层下发 `script-src 'self' 'unsafe-eval'`（vue-i18n 运行时编译需要；自建反代如自行收紧 CSP 需保留 eval，否则 i18n 白屏）。
