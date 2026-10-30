---
title: 快速开始
---

# 快速开始

用 Docker Compose 三步把 PigeonBox 跑起来：前后端分离双容器部署（frontend 静态入口 + server API，外加 Redis），全部状态落在本机 `./data` 目录。

## 前置要求

- Docker 20.10+ 与 Docker Compose v2
- 对外正式服务建议再读[部署 Docker Compose](./deploy-docker)（nginx 反代 / 数据备份 / 升级回滚）

## 三步部署

```bash
# 1. 克隆 hub 装配仓（compose 编排与 .env 模板都在这里）
git clone https://github.com/pigeonbox/pigeonbox.git
cd pigeonbox

# 2. 生成环境配置（**无需改任何一行也能起**，见下方说明）
cp .env.example .env

# 3. 启动（拉取 ghcr.io/pigeonbox 的 server + frontend 双镜像，版本由 PB_IMAGE_TAG 同钉）
docker compose up -d
```

::: tip 管理员账号：两种走法，都不需要"照抄某段配置"
3.0.0 起**不再播种弱口令 `admin/admin123`**。装完打开 `http://localhost:12345` 就能用：

1. **首启向导（默认，零配置）** —— `.env` 里**什么都不填**即可。compose 入口在检测到 `PB_ADMIN_PASSWORD` 为空时自动切到向导模式，浏览器打开站点走完 `/setup` 就建好管理员（站点名、管理员密码、有效期策略一页配完）。
2. **预设密码（无人值守/批量部署用）** —— `.env` 里设 `PB_ADMIN_PASSWORD=<强密码>`，首个管理员就是 `admin / <该密码>`，省掉一次交互。

两条路**互斥且等价安全**：都不会落到弱口令；向导建的是你自设的密码。
:::

::: warning 首启令牌：默认已自动开启
未初始化的实例上，`/setup` 建号本身不需要登录——**谁先访问谁建号**（setup-race）。因此服务启动时会**自动生成一次性令牌**并打印在启动日志里，建号必须带上它：

```bash
docker compose logs server | grep 首启令牌
# 首启令牌已生成（一次性，仅本次进程有效）：3f9a…
# setup_url: http://127.0.0.1:12345/?token=3f9a…#/setup
```

两种拿令牌的方式：① 直接打开日志里的 `setup_url`（链接自带 `?token=`，前端会自动带上）；② 在向导页把令牌粘进「首启令牌」输入框。令牌也写在数据目录的 `.setup_token`（权限 600）里，NAS 部署不必翻日志。

- **想自己指定口令**：`.env` 设 `PB_SETUP_TOKEN=<任意非空值>`（优先于自动生成）。
- **想完全关掉这道门**：`.env` 设 `PB_SETUP_TOKEN_AUTO=0`（仅建议内网自托管；此时启动会有一条暴露面告警）。
- **输错会被按 IP 锁定**（复用 `security.lockout`，Redis 共享计数）；**没带令牌不算失败**（那是还没提交凭据的正常流程，不会把你锁在门外）。

首次建号完成后，令牌即刻失效（系统已初始化），可从 `.env` 移除、`.setup_token` 也被清掉。
:::

验证：

```bash
curl http://localhost:12345/live    # 健康检查
```

浏览器打开 `http://localhost:12345` 即可使用(compose 入口默认仅本机可访问;
**局域网其他设备访问**需在 `.env` 设 `PB_API_BIND=0.0.0.0` 后 `docker compose up -d` 重建)。

## 首次初始化

- **初始化向导**：首次访问按前端引导完成站点初始化；后端接口为 `GET /setup/check`（查询初始化状态）与 `POST /setup`（提交初始化）。
- **管理员账号**：`.env` 里 `PB_ADMIN_PASSWORD` **留空**（默认）→ 无预置账号，打开站点走 `/setup` 向导建号；**填了** → 首个管理员为 `admin / <该密码>`。两种都不会回落成弱口令 `admin/admin123`。
- **JWT 密钥**：`PB_JWT_SECRET` 留空时容器首启自动生成 48 位随机值并持久化到 `./data/.jwt_secret`（权限 600），重启/升级不丢；生产建议显式注入（如 `openssl rand -hex 32`）。
- **站点公网地址**：`SystemConfig.base.public_url`（管理台「系统配置 → 基础」）填你的对外地址（域名或 `http://NAS_IP:12345`）。**不填的话，分享链接会按请求来源生成**，内网部署把内网地址发给外网用户就打不开——这是自建部署最常见的"能用但链接发不出去"。

## 端口

| 端口 | 说明 |
| --- | --- |
| `12345` | 对外入口（frontend 容器：静态页面 + API 反代，`.env` 的 `PB_API_PORT` 可改；server 不直接对外） |
| `80` | nginx 反代入口（仅 `--profile nginx` 启用时占用，`PB_HTTP_PORT` 可改） |

## 下一步

- 数据、备份、升级与回滚，及 nginx 反代生产化：[部署 Docker Compose](./deploy-docker)
- Kubernetes 多副本 / Ingress / 监控接入：[部署 Kubernetes (Helm)](./deploy-kubernetes)
- 存储后端、数据库、限流、MCP 等全部配置项：[环境变量参考](./environment)
