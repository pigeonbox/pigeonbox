---
title: 部署 Kubernetes (Helm)
---

# 部署 Kubernetes（Helm）

官方 Helm Chart 位于 [pigeonbox/charts](https://github.com/pigeonbox/charts) 仓库，chart 名 `pigeonbox`：前后端分离两 Deployment（frontend nginx 静态+反代 → server API，Ingress 指向 frontend），可选内置数据面（1.2.x 起 Redis 默认开，MySQL/PostgreSQL 可选；1.3.x 起可一键启用内置 S3 对象存储 SeaweedFS；1.3.4 起可一键部署 P2P 联邦注册中心，1.3.7 起含直传中继开关）、Ingress / PVC / Prometheus ServiceMonitor。

## 安装

方式一：Helm 仓库（GitHub Pages，由 chart-releaser 自动发布）：

```bash
helm repo add pigeonbox https://pigeonbox.github.io/charts
helm repo update
helm install pigeonbox pigeonbox/pigeonbox \
  --namespace pigeonbox --create-namespace
```

方式二：OCI 制品（ghcr.io，与 Pages 同步发布）：

```bash
helm install pigeonbox oci://ghcr.io/pigeonbox/charts/pigeonbox
```

## 内置数据面（可选组件）

chart 可一键部署有状态依赖，全部为单副本 StatefulSet（密码留空则安装时随机生成、存 Secret 并跨升级复用），并通过环境变量自动接线——**env 优先级高于 `config`，但 `config` 里显式配置了对应段（非空）时内置实例自动让位**：

| 组件 | values 键 | 默认 | 说明 |
| --- | --- | --- | --- |
| Redis | `redis.enabled` | `true` | 取件码映射/presign 会话持久化 + 多副本共享面（单机关闭后为内存模式：全功能可用、重启丢映射，core v0.14.0+）；AOF 持久化 1Gi；后端由 init 容器等其就绪 |
| MySQL 8.4 | `mysql.enabled` | `false` | 开启即注入 `PB_DATABASE_*`（driver/host/密码全托管） |
| PostgreSQL 17 | `postgresql.enabled` | `false` | 同上 |
| SeaweedFS(S3) | `s3.enabled` | `false` | 单进程对象存储（master+volume+filer+s3），自动建桶并注入 `PB_STORAGE_S3_*`，同时自动放行 `PB_SSRF_ALLOW_PRIVATE`（集群内端点属私网，core 的 SSRF 防护默认拒绝） |
| P2P 注册中心 | `p2p.enabled` | `false` | 联邦注册中心单副本（节点注册/口令联邦路由），自动注入 `PB_FEDERATION_*`；1.3.7+ 含 `p2p.relay.*` 直传中继开关（需 server 镜像 ≥ 0.10.0） |

**关于内置 S3 的选型**：MinIO 自 2025-06 起停止发布社区容器镜像（Docker Hub / quay.io 均已拒绝匿名拉取，上游仅提供源码自行构建），chart 无法再引用官方镜像，故内置实现选型 [SeaweedFS](https://github.com/seaweedfs/seaweedfs)（Apache-2.0，持续发布多架构镜像）。对后端而言它只是一个标准 S3 端点；如需接入自建 MinIO / 云厂商对象存储，用 `config.storage` 或 `secret.extra` 指向即可，内置实例自动让位。

```bash
# 示例：全内置数据面（对象存储 + 默认 Redis），数据库仍用 SQLite
helm upgrade --install pigeonbox pigeonbox/pigeonbox \
  --namespace pigeonbox --create-namespace \
  --set s3.enabled=true \
  --set secret.adminPassword='<强密码>'
```

## 生产建议

- 管理密码 `secret.adminPassword` 留空即自动随机生成（存 Secret、跨升级复用，弱默认 `admin123` 已废弃）；需要固定值时才显式指定。
- `--set secret.production=true` 开启 secret 强校验；`PB_JWT_SECRET` 全环境强制且要求 ≥32 位强随机（chart 自动生成的随机值已满足，显式传入短值会拒绝启动）。
- **反代 / Ingress 部署必须设置 `trustedProxies`**（如 `--set trustedProxies[0]=10.0.0.0/8`），否则应用不采信 `X-Forwarded-For`，限流/登录失败锁定会按代理地址计数、误伤所有用户。原理见[部署 Docker Compose](./deploy-docker) 的 trusted_proxies 一节。
- SQLite + 本地存储保持 `replicaCount: 1`；切到外部 MySQL/Postgres + S3/WebDAV 后才考虑多副本，多副本建议启用 Redis 并设 `config.rate_limit.use_redis: true` 让限流计数跨实例共享（chart 2.0+ 拆分模式下自动注入）。
- Ingress 挂 TLS 时设置 `config.server.base_url` 为对外完整地址（分享链接生成用）；启用 S3 直传/直下需给存储桶配置 CORS。
- 自接内网 MinIO/WebDAV 场景需设置 `config.security.ssrf.allow_private_networks: true`（或 env `PB_SSRF_ALLOW_PRIVATE=true`）放行私网端点；启用内置 SeaweedFS 时 chart 已自动注入，无需手动设置。

## 多副本拆分（replicaCount > 1）

`replicaCount > 1` 时 chart（2.0+；1.3.22 起支持，需 server 镜像 ≥ 0.14.0）自动从单实例切换为**双平面拓扑**，同一镜像以 `PB_DEPLOY_MODE` 区分运行形态：

- **public 面**（`<release>-pigeonbox`，N 副本）：只提供分享/上传/下载/用户等公开路由，公网入口只指向它；管理路径在其上物理 404，不跑后台任务与 DB 迁移。
- **admin 面**（`<release>-admin`，全局 1 实例）：管理路由（admin/MCP/setup）、后台任务、DB 迁移、配置唯一写者——管理端改配置经 Redis 广播秒级同步到 public 副本（在线切换存储后端同样即时生效）。
- **admin 控制台**（可选，`serverAdmin.ingress.enabled`）：渲染一个反代到 admin 面的 nginx 副本 + 独立 Ingress（建议注解挂 IP 白名单）；不开 Ingress 时可 `kubectl port-forward svc/<release>-admin 12345` 直连 API。

硬约束：MySQL/PostgreSQL + Redis 必配（public 副本检测到 SQLite 拒绝启动）、存储须 S3 或多节点可读写卷（RWX）、federation 与 p2p 设备直传在拆分模式自动降级关闭（节点身份与直传任务态均为进程级，standalone 形态专属）。拆分模式下建议在 config 中设 `ui.show_admin_addr: false`，让公开站点不再展示管理入口。`replicaCount = 1` 时渲染与历史版本完全一致。

> server 镜像自 1.21.0 起随包 p2pc 设备直传二进制（`/app/p2pc`）：standalone 形态下在 admin「系统配置 → P2P 与联邦」分区启用即可，无需额外挂载。

## 参数速查

完整参数表（全局 / 网络 / 存储 / 配置注入 / 探针）见 charts 仓库的 [chart README](https://github.com/pigeonbox/charts/blob/main/charts/pigeonbox/README.md)。常用项：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `replicaCount` | server 副本数（SQLite 部署保持 1） | `1` |
| `frontend.replicaCount` | frontend 副本数（无状态，可独立扩缩） | `1` |
| `containerPort` | server 容器内应用监听端口 | `12345` |
| `redis.enabled` | 内置 Redis（取件码映射持久化；多副本共享/广播依赖；单机关闭后为内存模式，core v0.14.0+；`config.redis` 显式配置时自动让位） | `true` |
| `mysql.enabled` / `postgresql.enabled` | 内置单副本数据库 StatefulSet，开启即自动注入 `PB_DATABASE_*` | `false` |
| `s3.enabled` | 内置 SeaweedFS 对象存储（自动建桶并注入 `PB_STORAGE_S3_*`；需 server 镜像 ≥ 0.9.3） | `false` |
| `persistence.enabled` | 持久化 SQLite + 本地上传文件（容器 `/app/data`） | `true` |
| `ingress.enabled` | Ingress（networking.k8s.io/v1） | `false` |
| `metrics.serviceMonitor.enabled` | Prometheus Operator ServiceMonitor | `false` |
| `config` | server 配置，渲染为 ConfigMap 覆盖 `/app/config/config.yaml`。**注意是整体替换**镜像内置配置，需对照 `config.example.yaml` 提供完整结构 | `{}` |
| `secret.jwtSecret` | JWT 密钥；留空随机生成并跨升级复用 | `""` |
| `secret.adminPassword` | 管理员密码（`PB_ADMIN_PASSWORD`）；留空自动随机生成并跨升级复用 | `""` |
| `secret.extra` | 其他任意 `PB_*` 键值对（如 `PB_PRESIGN_SIGNING_KEY`） | `{}` |
| `trustedProxies` | 可信代理网段 CIDR 列表（`PB_TRUSTED_PROXIES`） | `[]` |

> 环境变量优先级高于配置文件：敏感项一律走 `secret.*`，`config.*` 只放非敏感配置。变量含义见[环境变量参考](./environment)。
