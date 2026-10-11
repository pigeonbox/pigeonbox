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

# 2. 生成环境配置（全部项有安全默认，可留空；生产至少设 PB_ADMIN_PASSWORD）
cp .env.example .env

# 3. 启动（拉取 ghcr.io/pigeonbox 的 server + frontend 双镜像，版本由 PB_IMAGE_TAG 同钉）
docker compose up -d
```

验证：

```bash
curl http://localhost:12345/live    # 健康检查
```

浏览器打开 `http://localhost:12345` 即可使用(compose 入口默认仅本机可访问;
**局域网其他设备访问**需在 `.env` 设 `PB_API_BIND=0.0.0.0` 后 `docker compose up -d` 重建)。

## 首次初始化

- **初始化向导**：首次访问按前端引导完成站点初始化；后端接口为 `GET /setup/check`（查询初始化状态）与 `POST /setup`（提交初始化）。
- **管理员账号**：默认 `admin / admin123`。生产环境必须在 `.env` 里用 `PB_ADMIN_PASSWORD` 覆盖（生产模式未覆盖会**拒绝启动** `ErrInsecureDefaultAdmin`；逃生门 `PB_DISABLE_DEFAULT_ADMIN=true` 后走 /setup 向导建号），登录后也请立即改密。
- **JWT 密钥**：`PB_JWT_SECRET` 留空时容器首启自动生成 48 位随机值并持久化到 `./data/.jwt_secret`（权限 600），重启/升级不丢；生产建议显式注入（如 `openssl rand -hex 32`）。

## 端口

| 端口 | 说明 |
| --- | --- |
| `12345` | 对外入口（frontend 容器：静态页面 + API 反代，`.env` 的 `PB_API_PORT` 可改；server 不直接对外） |
| `80` | nginx 反代入口（仅 `--profile nginx` 启用时占用，`PB_HTTP_PORT` 可改） |

## 下一步

- 数据、备份、升级与回滚，及 nginx 反代生产化：[部署 Docker Compose](./deploy-docker)
- Kubernetes 多副本 / Ingress / 监控接入：[部署 Kubernetes (Helm)](./deploy-kubernetes)
- 存储后端、数据库、限流、MCP 等全部配置项：[环境变量参考](./environment)
