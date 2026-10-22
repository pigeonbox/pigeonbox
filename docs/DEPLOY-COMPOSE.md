# Docker Compose 部署指南

前后端分离自托管(frontend 入口 + server API + Redis)的推荐路径。三种部署形态,按需选择:

| 形态 | 命令 | 适用 |
|---|---|---|
| 直连体验 | `docker compose up -d` | 本机快速试用,`http://localhost:12345`(入口=frontend 容器);**默认仅本机可访问**,局域网访问在 .env 设 `PB_API_BIND=0.0.0.0` |
| nginx 反代 | `docker compose --profile nginx up -d` | 正式对外:统一 80/443 入口、TLS、缓存与超时治理 |
| Kubernetes | `charts/` 仓库 `pigeonbox` chart | 多副本、Ingress、监控接入(见 charts 仓库 README) |

## 快速开始

```bash
cp .env.example .env      # 不改也能起:管理员留空 ⇒ 启动后打开站点走 /setup 首启向导建号
docker compose up -d
curl http://localhost:12345/live    # 健康检查
```

> **局域网访问**:入口默认绑定 `127.0.0.1`(仅部署机本机可用,安全默认——防绕过反代直连)。
> 局域网其他设备访问时,在 `.env` 里设 `PB_API_BIND=0.0.0.0` 后 `docker compose up -d` 重建即可。

**管理员账号:两种走法,都不需要"照抄某段配置"**

1. **首启向导(默认,零配置)**——`.env` 里什么都不填即可。编排入口在检测到 `PB_ADMIN_PASSWORD` 为空时自动切到向导模式,浏览器打开 `http://localhost:12345` 走完 `/setup` 就建好管理员(站点名、管理员密码、有效期策略一页配完)。
2. **预设密码(无人值守/批量部署用)**——`.env` 里设 `PB_ADMIN_PASSWORD=<强密码>`,首个管理员就是 `admin / <该密码>`,省掉一次交互。

两条路**都不会播种弱口令 `admin/admin123`**(3.0.0 起)。⚠️ 公网部署再加一道:未初始化实例的 `/setup` 无鉴权(谁先访问谁建号),请设 `PB_SETUP_TOKEN=<任意非空值>`;建号必须带上它,未带或带错按 IP 锁定 10 分钟。首次建号后令牌即刻失效,可从 `.env` 移除。

内置 redis 密码:.env 设 `PB_REDIS_PASSWORD=<随机串>` 即 server 与 redis 两端同时生效(未设时编排内网无密码,端口不对宿主发布;生产建议设置)。

server 与 frontend 两镜像同版本列车(`PB_IMAGE_TAG` 一变量同钉),均已 public 可匿名拉取;若仍 403 再 `docker login ghcr.io`。

本地构建(需先 `make setup` 拉齐模块仓):

```bash
BUILD=1 make compose-up       # = docker compose up -d --build
```

## JWT 密钥机制

core 自 v0.3 起对密钥做 fail-fast 校验(空值或已知默认值拒绝启动),**必须提供一个强随机密钥**,两种方式:

1. **自动生成(默认)**:`PB_JWT_SECRET` 留空时,容器首启生成 48 位随机值并持久化到 `./data/.jwt_secret`(权限 600),重启/升级沿用,所有已登录会话不失效。
2. **显式注入(生产建议)**:在 `.env` 设 `PB_JWT_SECRET=$(openssl rand -hex 32)`。注入后容器直接使用该值,不读写密钥文件。

轮换:改 `.env` 后 `docker compose up -d` 重建容器即可;旧 JWT 全部失效(用户需重新登录,已发出的取件令牌不受影响)。注意自动生成模式下 `./data/.jwt_secret` 属于敏感文件,备份/传输数据目录时同样要保密。

## nginx 反代部署(profile nginx)

```bash
cp .env.example .env
# .env 中两项必设:
#   PB_TRUSTED_PROXIES=<compose 容器网段 CIDR>
#   PB_SERVER_BASE_URL=https://<对外完整地址>
docker compose --profile nginx up -d     # 占用宿主 80(PB_HTTP_PORT 可改)
```

**为什么 trusted_proxies 必填**:后端对 `X-Forwarded-For` 做 CIDR 可信校验,只有直连对端落在可信网段内才采信 XFF。不配置则限流/登录失败锁定全部按 nginx 的 IP 计数——所有用户共享一个限流桶,一人触发全员受限,且失败锁定会误伤。compose 默认网络落在 `172.16.0.0/12` 池内,`.env.example` 给了这个宽值;要收窄就用 `docker network inspect <项目目录名>_default | grep Subnet` 查精确网段。

启用反代后建议再设 `PB_API_BIND=127.0.0.1` 把对外入口(frontend 容器)收进回环:部分宿主防火墙/NAT 会把外部直连流量 SNAT 成 docker 网关地址(恰好在可信网段内),此时直连客户端可伪造 XFF 绕过按 IP 的限流与锁定;收进回环后所有流量必须走反代,来源 IP 全部可信解析。

HTTPS / 子路径部署:模板 `deploy/nginx/nginx.conf` 内置了 443 server 块与 `/pb/` 子路径前缀改写的完整注释示例,取消注释、挂载证书即可,此处不重复。该文件头部还有 `client_max_body_size` 与后端 `upload.upload_size / max_file_size / chunk_size` 的三处配平说明,调上传上限前先读。

数据面路径相关的路由(下载/分片/预签名)已在模板中关闭缓冲并放宽超时,大文件不再占用 nginx 缓冲区,慢速客户端不会被 60s 默认超时切断。

## 数据、备份与升级

- 应用状态在 `./data`:SQLite 库、上传文件、`.jwt_secret`。容器本身无状态,可随时销毁重建。
- **取件码的真相源是数据库**:`file_codes.pickup_code` 列(与分享码同表)。Redis 只是匿名取件码→分享码映射的**加速 KV 层**,未启用 Redis 时回落到进程内 + 回源 DB(功能完整,只是重启后未命中的映射需回源)。因此"只导 `./data` 就丢取件码"是误解;Redis 卷(`redisdata`)仅在需要保留跨机缓存命中时才导出。
- 备份:停机窗口内直接拷贝 `./data`(跨机迁移如需保留 Redis 缓存另按上行导出 redisdata);不停机则用 `sqlite3 data/fileCodeBox.db ".backup '...'"` 做一致性快照(上传文件目录另行拷贝)。注意库文件名是镜像内置 config.yaml 写死的 `fileCodeBox.db`(驼峰);管理后台在线改过的站点配置也在这份库里(`system_configs` 表),备库即备份全部配置。
- 升级:`.env` 钉住 `PB_IMAGE_TAG`(建议具体版本而非 latest)→ 改 tag → `docker compose pull && docker compose up -d --force-recreate`(server/frontend 两镜像同 tag 一起更新,数据卷不动)。⚠️ **`--force-recreate` 不能省**——只 `up -d` 而配置未变时,compose 认为容器无需重建,会继续跑旧镜像的旧行为(表现为"升了版本但行为没变")。回滚即把 tag 改回旧版本后同样带 `--force-recreate` 重建。
- 容器日志已配 json-file 轮转(单容器 10MB×3),无担心无限增长。

## P2P 联邦(可选)

compose 部署可热启停**跨站联邦**:管理后台「系统配置 → 联邦」分区启用即可(registry 留空=官方公共注册中心)。启用后本站注册进联邦注册中心,创建分享时使用**高熵自定义取件码**(如 `fede2e-xxxxxxxxxxxxxxxx`),其他接入同一注册中心的站点可凭该码解析到来源站点并完成取件——内容始终留在源站,注册中心只存哈希路由。1.22.0 起支持联邦实例间推送邀请(免手工口令交接;认领只出信封,文件接收由 PigeonBeam 完成)。

::: warning 设备直传已从 PigeonBox 拆出
3.0.0 起设备直传(P2P 直传)是**独立应用 PigeonBeam**(信鸽直传)——Box 侧不再编排直传数据面,镜像也不再随包 p2pc,`SystemConfig` 的 `p2p.direct` 子段已删除(存量配置里的该段会在启动日志里被明确提示「检测到陈旧配置 p2p.direct.*,已忽略」,请把 registry_url 改配到 `p2p.federation.registry_url`)。直传请用 [PigeonBeam](https://github.com/pigeonbox/p2p)。
:::

注意:联邦为 standalone 部署专属,多副本拆分(`PB_DEPLOY_MODE=public/admin`)下自动降级。协议细节见 [architecture.md §5.3](https://github.com/pigeonbox/pigeonbox/blob/main/docs/architecture.md)。

## 本地双实例联调（联邦/P2P）

一台机上起两个互相独立的实例 + 一个本地 p2pd 注册中心，验证联邦口令路由（A 建分享、B 跨站取件）：

```bash
HUB=/path/to/pigeonbox        # 本仓路径
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}')  # 宿主局域网 IP

# 1) 本地注册中心 p2pd（来自 p2p 仓,起法详见 PigeonBox/p2p/README.md;
#    12346=HTTP/WS 信令+UDP 反射,12347=加密中继）
cd "$HUB/p2p" && make build && ./bin/p2pd &

# 2) 实例 A/B:同一 compose 模板各起一个项目。
#    必须 grep -v 去掉 container_name 行(模板写死了 pigeonbox/pigeonbox-frontend/pigeonbox-redis,
#    不去掉的话 -p 项目名隔离无效,第二个实例会撞容器名),数据目录 ./data 与 redisdata 卷随项目名天然隔离。
port=12445
for n in a b; do
  mkdir -p ~/pb-lab/$n && cd ~/pb-lab/$n
  grep -v 'container_name:' "$HUB/docker-compose.yml" > docker-compose.yml
  cat > .env <<EOF
PB_IMAGE_TAG=latest
PB_API_PORT=$port
PB_ADMIN_PASSWORD=admin-pass-$n
PB_FEDERATION_ENABLED=true
PB_FEDERATION_REGISTRY_URL=http://$HOST_IP:12346
PB_FEDERATION_PUBLIC_URL=http://$HOST_IP:$port
PB_SSRF_ALLOW_PRIVATE=true
EOF
  docker compose -p pb-$n up -d
  port=$((port+1))
done
```

约束与注意：

- **部署模式**：P2P 联邦与设备直传仅 `PB_DEPLOY_MODE=standalone`（缺省即 standalone）可用；public/admin 多副本拆分下自动降级关闭，别用双实例实验多副本。
- **私网注册中心**：`PB_FEDERATION_REGISTRY_URL` 指向宿主私网地址会被存储端点 SSRF 守卫拦截，必须 `PB_SSRF_ALLOW_PRIVATE=true`。
- **env 只是首启种子**：1.21.0 起 P2P 配置收进管理后台「系统配置 → P2P 与联邦」分区，一旦在后台保存过，以 DB 配置为准，再改 `PB_FEDERATION_*` env 不生效（去后台改，或删库重来）。
- 容器访问宿主服务走宿主局域网 IP（上面 `$HOST_IP`）；若机器无局域网网段，可改用 `host.docker.internal`（Mac/Windows Docker Desktop 自带，Linux 需给服务加 `extra_hosts: ["host.docker.internal:host-gateway"]`）。

验收（A 建分享 → B 联邦取件）：

```bash
CODE=$(curl -s -X POST http://localhost:12445/share/text/ -H 'Content-Type: application/json' \
  -d '{"text":"fed-hello","expire_value":1,"expire_style":"day"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["code"])')
curl -s "http://localhost:12446/share/select/?code=$CODE" | grep fed-hello   # 命中=联邦路由通了
```

收尾：`docker compose -p pb-a down -v && docker compose -p pb-b down -v`，p2pd 进程 `kill` 即可（注册中心不落盘）。

## 常见问题

| 现象 | 原因与处理 |
|---|---|
| 容器反复重启,日志 `a secure user.jwt_secret is required` | 数据目录不可写导致密钥文件写不进(Linux 裸 Docker 常见):`mkdir -p data && sudo chown 1000:1000 data` 后重启 |
| 限流"误伤"(一人超限全员受限)/ 登录错误锁定所有人 | 反代部署未配 `PB_TRUSTED_PROXIES`,见上节 |
| ghcr 镜像拉取 `unauthorized` | `docker login ghcr.io`,或换可用 `PB_IMAGE_TAG` |
| 80/12345 端口被占 | `.env` 改 `PB_HTTP_PORT` / `PB_API_PORT` |
| 想临时关掉反代 | `docker compose --profile nginx up -d` 只重排 pigeonbox;彻底停 nginx:`docker compose stop nginx` |

完整环境变量(存储后端/Redis/限流/审核/MCP 等)见 [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md)。
