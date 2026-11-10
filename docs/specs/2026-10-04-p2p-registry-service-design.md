# FilesCodeBox P2P 注册服务（p2p 仓）设计方案

- 日期：2026-10-04
- 状态：**M0-M3 全量发布**（p2p v0.1.0 注册中心 → v0.2.0 信令 → **v0.3.0 设备直传**：`p2pc send/recv` 参考客户端（PAKE 2 消息流/UDP 同时开洞/QUIC 指纹钉定/加密中继 12347/断点续传）+ UDP 反射器 + 中继组件，e2e 三例+真机 1MB 回环冒烟全绿，chart 1.3.7 中继开关）；**M4 运营加固已发布**（core v0.9.0：多 registry failover + 心跳 15s 短退避 + 延期/恢复公告重推 + 压测基准；server v0.10.2 同载，注 v0.10.1=并行会话的 core v0.8.1 修复列车）；剩余=215 实机升级（10-05 探测 22 端口仍超时）；desktop Rust 接入已完成（desktop v1.3.0 起内置 p2pc sidecar，v1.3.1 起传输协议 v2）
- 路线：A 联邦注册中心（骨架）+ B 口令式直传（传输增强）；C 全 DHT 去中心化不做
- 决策依据：2026-10-04 调研（croc / magic-wormhole / libp2p / Syncthing / PairDrop 对标），用户拍板"单独服务仓 + 按建议方案"
- 实现期修正：口令哈希由 `HMAC-SHA256(私盐)` 改为 `SHA-256`（见 §4.2 修订理由）
- M2 实施备注：admin 域删除路径独立于 share 域，须单独挂钩（漏挂=管理端删除后联邦公告残留至 TTL）；同机多实例须各自配 `federation.node_key_path`（默认路径相对 CWD，共key=同身份会互相覆盖注册地址）
- M3 信令实施备注：① HTTP 中间件包装层（statusRecorder）必须透传 `http.Hijacker`——嵌入接口只提升该接口自身方法，不透传则 gorilla WS 升级必败且单测裸 mux 无法暴露（真机冒烟抓出）；② 客户端义务=配对后先 PAKE 再传（PAKE 派生密钥加密的）候选地址，接收方以 `paired.peer_id` 与 resolve 源身份交叉核对防换人
- M3 直传实施备注：① **pake v3.2.0 responder 只允许 Update 一次**（每次 Update 以新随机 α 重派生 K，多收一条消息=两侧密钥静默不一致）——2 消息流按角色写死勿泛化；② **QUIC 流由发送方打开并先写 meta**：流在首字节上线前对端 AcceptStream 不返回，方向反了=双向死锁（qlog+协程转储定位）；③ 客户端 UDP 套接字显式 `udp4`（双栈通配下地址族混用致流静默丢失）；④ 中继首行逐字节读（bufio 超读吞掉客户端紧随令牌行的首帧）；⑤ 打洞结果不对称时 QUIC 侧接受预算收紧到 8s 快速对齐中继；⑥ 错口令不报错——两侧密钥必不一致，在首个 AEAD 帧暴露（ErrCorrupt）
- M4 基准（本机 M 系列）：Announce 26μs/op（Ed25519 验签主导）· Resolve 224ns/op · 存储插入 churn 349ns/op · 中继管道 2.58GB/s（本机上限，真实受网络约束）

---

## 1. 背景与目标

现状：每个 FilesCodeBox 部署是孤岛，口令只在单一站点内可取；个人设备（无公网 IP）无法成为分享方。

目标（按优先级）：

1. **联邦取件（P0）**：任一节点创建的口令分享，可在任何接入联邦的节点/前端录码取到；文件始终从源节点直出，不落注册中心、不经中间拷贝。
2. **设备直发（P1）**：没有公网 IP 的设备（desktop 客户端/NAS/命令行）可直接生成口令发文件给对方——注册中心只做握手信令，传输优先打洞直连，失败走端到端加密中继，中心不见明文。

非目标：内容 DHT 去中心化、离线传输、persistence 多副本同步、匿名网络（Tor 类）。

## 2. 需求分层与本期范围

| 层 | 问题 | 本期方案 |
|---|---|---|
| 实例联邦 | 节点发现、口令路由 | registry 注册/心跳/解析（M1-M2） |
| 设备入网 | NAT 打洞 + 中继兜底 | WS 信令 + PAKE + 打洞 + 中继（M3） |
| 浏览器对等 | WebRTC 限制 | 不做浏览器-P2P 直传；浏览器经"全网取件"跳转源节点 HTTP 直下 |

## 3. 总体架构

```
                         ┌────────────────────────────┐
                         │   p2p 服务（新仓 p2p）        │
                         │  ① registry: 注册/心跳/解析   │
                         │  ② signaling: WS 握手信道(M3) │
                         │  ③ relay: 加密中继(M3,默认关) │
                         └───────▲───────────▲─────────┘
                    announce/心跳│           │录码 resolve(core 代理)
              (签名,口令仅存哈希) │           │
     ┌───────────┐        ┌──────┴─────┐     │
     │  节点 A    │◄───────│  节点 B     │─────┘
     │(server/fnos│ 直连下载 │  /desktop) │   文件: B 的用户 ◄──直连── A
     │ /desktop) │────────►│            │   (源节点正常校验口令,无跨节点信任)
     └───────────┘  HTTP   └────────────┘
```

关键原则：

- **registry = 纯发现层**。存 `SHA-256(口令) → 源节点`，不存文件、不存明文口令。
- **校验留在源节点**。解析只回答"这个口令在哪个节点"，取件方直连源节点走正常口令校验流程——零跨节点信任，改动面最小。
- **中继 = 密文搬运工**（M3）。仅当 PAKE 会话建立后才放行转发，默认关闭，开则限额。

## 4. 新仓 p2p：服务设计

### 4.1 命名与端口

| 项 | 值 | 说明 |
|---|---|---|
| 仓/module | `github.com/filescodebox/p2p` | 短名，与 fnos/desktop 命名风格一致 |
| 镜像 | `ghcr.io/filescodebox/p2p` | v* tag 多架构（amd64+arm64） |
| 二进制 | `p2pd` | 单进程单二进制 |
| HTTP/API/WS | **12346** | 12345 已被 server/fnos 占用 |
| relay TCP | **12347** | M3，配置可关 |

### 4.2 技术选型

- **Go 1.26.5，`net/http` 标准库 + gorilla/websocket + viper + prometheus/client_golang**。
  理由：本服务是安全敏感的基础设施叶子仓，不 import 生态任何包（依赖方向最底层，与 contracts 同级哲学），用不到 core 的中间件所以 Hertz 的复用优势不存在；stdlib 路由 + 显式中间件足够且依赖面最小、最易审计。与生态一致的保持：viper 配置、`FCB_P2P_*` 环境变量覆盖、Prometheus /metrics、Apache-2.0。
- **存储**：`Store` 接口，默认内存实现 + TTL 扫描协程；预留 bbolt（重启存活）与 redis（多实例）实现位，M1 只做 memory（节点侧断线自动重注册，registry 重启自愈靠客户端）。
- **口令哈希（实现期修订）**：`SHA-256(code)`，注册中心不接触明文。原设计的 `HMAC-SHA256(私盐)` 在本协议里不成立——公告方与解析方都必须持有口令才能计算哈希，私盐必须下发给他们即不再是私盐，只换来一个"双方都知盐"的伪防护。改为公开确定性哈希后，防线落在：**宣布侧熵门槛**（core 客户端只对熵 ≥40bit 的口令发联邦公告，短数字码不出站）+ 解析接口按 IP 严格限流（在线枚举慢）+ token 模式可切邀请制。
- **节点身份**：每节点 Ed25519 密钥对（首次启动生成，存 `data/federation.key`），注册/公告负载带签名，registry 首次注册即钉 key→node_id，防冒名与替换攻击。
- **PAKE（M3）**：直接依赖 `github.com/schollz/pake`（MIT，croc 同款，引依赖而非抄代码，许可干净）。

### 4.3 API 面（v1）

```
# 节点生命周期（全部带 Ed25519 签名负载）
POST   /v1/nodes/register          {node_id,url,name,version,caps,ttl,nonce,sig}
POST   /v1/nodes/{id}/heartbeat    同上（幂等续租）
DELETE /v1/nodes/{id}              签名注销
GET    /v1/nodes/{id}              公开信息查询

# 联邦公告（share 生命周期钩子触发）
POST   /v1/announces               {node_id,code_hash,expires_at,size_hint?,sig}
DELETE /v1/announces/{code_hash}   签名撤销（删分享/过期）
GET    /v1/resolve/{code_hash}     200 {node_id,url,expires_at} | 404；限流最严

# 管理/运维
GET    /health                     显式 GET（生态 HEAD-404 教训）
GET    /metrics                    Prometheus
GET    /v1/admin/stats             管理口令保护：节点/公告/信道统计
DELETE /v1/admin/nodes/{id}        滥用清理

# M3：设备直传
WS     /v1/channel/{code_hash}     信令信道：hello → PAKE 交换(不透明 blob) → 候选地址交换 → 打洞/中继裁决
TCP    :12347                      中继：PAKE 完成后双方持信道凭据接入，仅转发密文帧
```

### 4.4 配置

`configs/config.yaml` + `FCB_P2P_*` env 覆盖（viper，同生态约定）：

```yaml
server:  { port: 12346 }
relay:   { enabled: false, port: 12347, bandwidth_per_channel_mbps: 10, max_conns: 256 }
store:   { type: memory }            # 预留 bbolt/redis
announce:{ entropy_floor_bits: 40, max_per_node: 1000, max_ttl: 168h }
registration: { mode: open }         # open | token(token 为共享注册密钥)
admin:   { password_env: FCB_P2P_ADMIN_PASSWORD }
log:     { level: info }
```

### 4.5 安全与滥用治理

| 风险 | 对策 |
|---|---|
| 弱口令被离线枚举 | **宣布侧熵门槛**：core 宣布前校验口令熵 ≥40bit，数字 6 位取件码继续只在本站有效（不发联邦公告）；resolve 按 IP+全局双限流 |
| 开放中继被滥用 | 默认 `relay.enabled=false`；开启后仅 PAKE 会话凭据放行 + 单信道/全局带宽限额 + 连接数上限 |
| 节点冒名 | Ed25519 签名负载 + key→node_id 首注钉死，换地址需持 key 重签 |
| 注册洪泛 | `registration.mode=token` 可切邀请制；每 IP 注册/公告速率限制 |
| registry 单点 | 客户端失败自动重注册/重公告（指数退避）；联邦整体降级=现状孤岛模式，不影响单站功能 |
| 隐私 | 不存文件/明文口令/取件记录；公告与节点租约全部 TTL 到期即清 |

## 5. 生态集成（M2）

- **core**：新增第 11 个域服务 `federation`（client 角色只出不进，依赖方向不变）：
  - `Register/HeartbeatLoop`：启动注册 + 周期续租 + 失败退避重试；
  - `AnnounceShare/RevokeShare`：share 域服务经**可选回调接口**触发（nil 安全，关闭时零开销零耦合，同 presign→share 的单边依赖风格）；
  - `Resolve` 代理端点：浏览器经本站 API 查 registry，避免跨域与 CORS；
  - 配置：`federation.{enabled,registry_url,public_url,node_key_path}`，`public_url` 必须是外部可达地址。
- **frontend**：取件页新增"全网取件"入口——录码先本站解析，miss 时走 resolve 代理，命中则跳转源节点取件页并预填口令（源节点完成正常校验与下载）。
- **desktop / fnos**：随 core 升级自动获得"节点注册"能力；M3 的设备直传客户端协议语言中立（WS+标准密码学），desktop Rust 侧接入另立计划（联动 desktop roadmap）。
- **charts**：`filecodebox` chart 增加可选组件（`p2p.enabled`，默认 false），独立 Deployment；先不强依赖内置数据面。
- **hub**：`go.work` 增加 `./p2p`；`setup.sh` 默认拉取（`SETUP_P2P=0` 可跳）；Makefile 的 build/test/vet/lint/smoke 列表加 p2p；docs-site 增加 P2P 章节。
- **contracts**：暂不动。p2p API 为自包含 JSON REST + 自有错误包；待出现多语言客户端复用需求再评估 IDL 增补。

## 6. 仓库工程化（对齐 fnos 样板）

```
p2p/
├─ cmd/p2pd/main.go
├─ internal/
│  ├─ server/        # http 装配、中间件(日志/限流/recover)
│  ├─ registry/      # 节点与公告域逻辑、签名校验
│  ├─ store/         # Store 接口 + memory 实现
│  ├─ relay/         # M3 中继
│  ├─ signaling/     # M3 WS 信道
│  └─ config/
├─ configs/config.yaml (+example)
├─ Dockerfile        # CGO_ENABLED=0 静态 alpine，uid 1000，HEALTHCHECK 显式 GET /health
├─ .github/workflows/ci.yml    # golangci-lint(同门禁) + go test
├─ .github/workflows/release.yml # v* tag → ghcr 多架构（沿用 fnos metadata/provenance=false 等已验证写法）
├─ LICENSE(Apache-2.0)  README.md(门面：徽章/生态导航/License 章节)
└─ go.mod             # go 1.26.5；依赖仅 gorilla/websocket、viper、prometheus、pake(M3)
```

发布链路：`v*` tag → ghcr.io/filescodebox/p2p。**首个 release 后必须手动把 ghcr 包 flip 为 public**（fnos 教训：新包默认 private）。无 fpk/无跨仓回挂（服务器形态走镜像，与 server 仓一致）。

## 7. 里程碑

| 里程碑 | 内容 | 验收 | 预估 |
|---|---|---|---|
| **M0 脚手架** | 建仓+工程化全套接线 | CI 绿；打 v0.1.0 → ghcr 镜像可匿名拉取（flip public 后） | 0.5-1 天 |
| **M1 注册中心** | 4.3 节点+公告+resolve API、TTL 清扫、限流、admin、单测+集成测试 | compose 起 2 个模拟节点：注册→公告→resolve 命中→registry 重启自愈 | 2-3 天 |
| **M2 生态接线** | core federation 域服务+share 钩子+resolve 代理；frontend 全网取件；chart 可选组件；docs；发版（contracts→core→server→frontend→chart 顺序，防版本列车竞态） | 215 或 k3s 实环境：A 站发码 → B 站录码 → 直连 A 站取到文件 | 2-3 天 |
| **M3 设备直传** | WS 信令+PAKE+打洞+中继（默认关）+续传；`p2pd send/recv` 子命令先行验证 | 同机回环协议 e2e 通过 + 中继兜底路径断言；跨网真机打洞实测记录成功率 | 3-5 天 |
| **M4 加固运营** | 压测（announce/resolve QPS、relay 吞吐）、滥用调参、多 registry failover、文档 | 指标面板齐全；故障演练（registry 宕机/重启）通过 | 1-2 天 |

## 8. 测试计划

- 单元：store TTL/并发、签名验证失败面、限流、熵门槛、config 覆盖优先级。
- 集成：docker compose（registry + 2 模拟节点）跑通 announce→resolve→直连取件；registry 重启自愈；公告过期清扫。
- M3：回环 e2e（PAKE→打洞→传输→断点续传）+ 强制中继路径（禁直连环境变量）；可选 iptables 模拟 NAT。
- CI 门禁与生态一致：golangci-lint + go test；release 产多架构镜像。

## 9. 风险登记

| 风险 | 等级 | 对策 |
|---|---|---|
| 打洞成功率仅 60-70%（libp2p 生产数据） | 中 | 中继兜底为必选设计；直发功能明示"部分网络走中继" |
| ghcr 新包默认 private | 低 | release 后手动 flip（已入清单） |
| M2 触及 5 仓发版 | 中 | 严格按依赖序发版；每仓 tag 前确认上游 main 收敛（版本列车竞态两次踩实的教训） |
| 中继合规/滥用 | 中 | 默认关闭 + 凭据放行 + 限额；运营侧 admin 清理工具 |
| core share 域耦合回潮 | 低 | 可选回调接口 + nil 安全，评审时盯住单向边 |

## 10. 已定默认项（可在评审时推翻）

1. 仓名 `p2p`（备选：relay / mesh / rendezvous）。
2. 框架 stdlib 而非 Hertz（理由见 4.2）；配置/环境变量/metrics 习惯与生态一致。
3. `registration.mode` 默认 `open`（个人部署即可加入），运营期可切 `token`。
4. relay 默认关闭，M3 交付但出厂不启用。
5. M1 交付 memory store；bbolt/redis 视 M4 运营数据决定。
