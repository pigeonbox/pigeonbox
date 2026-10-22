# NAS 部署（飞牛 / OpenWrt·iStoreOS / 群晖 / 威联通 / 绿联 / 铁威马）

PigeonBox 在 NAS 上的六种交付形态。**飞牛 / OpenWrt·iStoreOS / 威联通为原生单进程应用**（包内自带二进制与前端，免 Docker）；**群晖 / 绿联 / 铁威马为官方镜像的 docker-compose 编排壳**（零 Go 代码），行为与 Docker Compose 部署（`docs/DEPLOY-COMPOSE.md`）完全一致：双容器免 Redis（core v0.14.0 起单机内存模式全功能）、JWT 密钥首启自动生成持久化、默认关闭开放注册、默认端口 `12345`。

**3.0.0 起两处行为变了**（存量实例不受影响）：

- **不再有 `admin/admin123`**。所有形态都改为「打开站点走 `/setup` 首启向导当场建号」——装完打开 `http://NAS的IP:12345` 就能用，不需要先想好管理员密码。想无人值守再在 `.env` 预置 `PB_ADMIN_PASSWORD`。
- **设备直传（P2P 直传）已从 Box 拆出为独立应用 [PigeonBeam](https://github.com/pigeonbox/p2p)**（信鸽直传）。Box 侧只保留**联邦面**（跨站取件、邀请信封）。原生三包（fnos/qnap/openwrt）仍随包带 p2pc 二进制，那是给 PigeonBeam 用的。

管理后台「系统配置 → 联邦」分区可热启停跨站联邦（standalone 部署专属）。

| 平台 | 形态 | 系统要求 | 安装入口 |
|---|---|---|---|
| 飞牛 fnOS | fpk 原生应用（fnos 仓） | fnOS（应用中心/手动安装） | [pigeonbox/fnos](https://github.com/pigeonbox/fnos/releases) |
| OpenWrt / iStoreOS | ipk / apk 原生包（openwrt 仓） | OpenWrt 22.03+ / 25.12+ | [pigeonbox/openwrt](https://github.com/pigeonbox/openwrt/releases) |
| 群晖 DSM | SPK 套件·compose 壳（synology 仓） | **DSM 7.2+** 且已装 Container Manager 24.0.2+ | [pigeonbox/synology](https://github.com/pigeonbox/synology/releases) |
| 威联通 QTS | QPKG 原生应用（qnap 仓） | **QTS 4.5+**，免 Container Station/Docker | [pigeonbox/qnap](https://github.com/pigeonbox/qnap/releases) |
| 绿联 UGOS Pro | compose 导入部署包（ugreen 仓） | UGOS Pro（Docker 应用可用） | [pigeonbox/ugreen](https://github.com/pigeonbox/ugreen/releases) |
| 铁威马 TOS | compose 导入部署包（terramaster 仓） | TOS 5/6/7（Docker 应用可用） | [pigeonbox/terramaster](https://github.com/pigeonbox/terramaster/releases) |

所有应用包随各自组件仓发版，并统一回挂[生态主仓 Releases](https://github.com/pigeonbox/pigeonbox/releases)（`fnos-v*` / `openwrt-v*` / `synology-v*` / `qnap-v*` / `ugreen-v*` / `terramaster-v*` tag）。

## 群晖 DSM（SPK）

1. 套件中心 → **手动安装** → 上传 `pigeonbox_<版本>.spk`；未签名包提示「发布者无法验证」，确认继续（DSM 7.x 无信任级别设置，属预期）
2. 向导三步：**端口**（默认 12345）、**数据目录**（默认 `/volume1/docker/pigeonbox`，建议放 docker 共享文件夹下）、**管理员密码**（**必填**——安全生产模式，留空容器拒绝启动；首次启动以此建号，遗失可卸载重装、数据目录保留）
3. 装完自动启动，访问 `http://NAS的IP:12345`（或套件详情页「打开」）

- 配置集中在 `数据目录/.env`，改完在套件中心**停用→启用**生效
- 升级套件自动对齐镜像版本；卸载默认保留数据目录
- 数据目录属主需为 uid 1000（安装时自动处理；异常时 SSH 执行 `sudo chown -R 1000:1000 <数据目录>`）

## 威联通 QTS（QPKG，原生应用）

自 v1.14.4 起为**原生进程模式**（对齐飞牛 fnOS）：包内自带双架构静态二进制与前端，单进程单端口直接运行——免 Container Station、免 Docker、免在线拉镜像，**QTS 4.5+ 即可安装**（老机型可用）。

1. App Center → 设置 → General → 勾选**允许安装没有有效数字签名的应用**（社区包一次性设置）
2. App Center 右上角**手动安装** → 上传对应架构的 `PigeonBox_<版本>_<架构>.qpkg`（x86_64 / arm_64）
3. 装完自动启动，主菜单/桌面点图标直达 `http://NAS的IP:12345`；**打开站点走 `/setup` 首启向导当场建号**（无默认口令）。要无人值守就先在 `.env` 预置 `PB_ADMIN_PASSWORD`

- 看门狗自愈：进程崩溃自动拉起，`/ping` 连续 3 次无响应自动重启；开机自启
- 配置在存储卷根 `pigeonbox/.env`（File Station 可编辑，改完 App Center 停止→启动生效）；App Center 图标端口自动跟随
- 数据在卷根 `pigeonbox/` 目录，**卸载应用保留**；Docker 旧版同名升级即原地切原生，数据无缝延续
- **QTS 原生集成**：NAS 账号 SSO 免登录（复用浏览器 QTS 会话，后端经本机 `authLogin.cgi` 实时校验）+ 系统信息；排障可 `PB_QNAP_DISABLED=1` 关闭联动

## 绿联 UGOS Pro / 铁威马 TOS（compose 项目导入）

1. 下载部署包 zip 解压（绿联提供 ghcr 原版与 `ghcr.nju.edu.cn` 加速版两份编排）
2. 打开 Docker 管理器 → **项目** → 创建/添加：
   - 绿联：项目名 `pigeonbox`（小写）→ 粘贴 compose YAML → 部署
   - 铁威马：项目路径选数据卷 → 配置来源「你的电脑」上传 yml（或粘贴）→ **验证 YAML** → 应用
3. 访问 `http://NAS的IP:12345`，**打开站点走 `/setup` 首启向导当场建号**（无默认口令）

- 端口/数据目录/管理员密码在导入前直接改 YAML（绿联默认数据目录 `/volume1/docker/pigeonbox/data`，铁威马建议改到数据卷如 `/Volume1/Docker/pigeonbox/data`）
- 升级 = 改 YAML 里两处镜像 tag → 重新部署；数据目录不动
- 铁威马注意保留端口 22/80/443/8181/5050（默认 12345 合规）；两平台都建议把 Docker 应用设为开机自启

## ghcr 镜像拉取（国内网络）

群晖/绿联/铁威马三平台 compose 壳均从 ghcr.io 拉官方镜像（public 可匿名；飞牛/威联通/OpenWrt 原生包内自带二进制，不拉镜像）。直连失败时的通用兜底：

- 镜像前缀替换：`ghcr.io/pigeonbox/server` → `ghcr.nju.edu.cn/pigeonbox/server`（绿联包已内置加速版编排）
- 离线导入：任意外网机器 `docker pull` + `docker save` 出 tar，上传 NAS 后在各家 Docker 界面导入镜像，再启动应用

## 与 Docker Compose 部署的关系

三平台 compose 壳内的编排与生态主仓 `docker-compose.yml` 同源裁剪（去 redis、绑 0.0.0.0、`.env` 由安装器生成，模板在 hub `deploy/nas/`）；高级配置（Redis、S3/网盘存储、反代、联邦、设备直传）直接参考环境变量文档（`docs/ENVIRONMENT_VARIABLES.md`）在 `.env` 追加即可。绿联 UPK 应用中心形态与铁威马 TOS 7 官方应用包为二期路线（见各自仓库 `upk/`、`tos7/` 目录说明）。
