# P2P 配对码（四位定时码）设计

> 2026-10-18 拍板执行。PigeonBeam（信鸽直传）两端配对的易用性收口：两台设备经
> 注册中心以**四位数字配对码**完成会话缔结，码几分钟失效。本档是设计与协议真相源，
> 实现落在 p2p 仓（p2pd / p2pc / p2pcweb 三面）。
>
> 决策点 D0-D5 已按建议拍板（见 §7）。

## 1. 问题与目标

现有直传口令是 12 位分组串（`XXXX-XXXX-XXXX`，≈60bit 熵，发送方生成），接收方需
完整转抄——两端都是人手输入时摩擦明显。目标：**4 位数字码 + 几分钟失效**的配对
体验，向 Box 取件码的输入范式看齐。

硬约束：

- **wire 协议零改动**（无 v5，无 N-1 双格式负担）；
- **信令信道协议零改动**（`/v1/channel/{hash}` 帧形态不变）；
- 改动全部压在注册中心 HTTP 面（新增端点为纯增量，旧客户端无感）；
- 4 位码（10⁴ 空间）绝不能进入房间号推导或 PAKE 密码派生——SHA256(4 位码) 可被
  任何看到 hash 的观察者毫秒级破解。

## 2. 核心机制：配对码是门牌号+门铃，不是钥匙

亮码方在注册中心登记一个**高熵会话口令 secret**（复用现有 `GenerateCode`，60bit），
注册中心签发 4 位配对码。对方凭码向注册中心 claim，经亮码方**人工确认**后一次性
兑换 secret。此后双方走完全现有的链路：

```
joinChannel(secret) → negotiateVersion → PAKE(secret) → 候选交换 → 打洞/中继 → QUIC 传输
```

安全根 = **人工接受门**，不是 4 位码本身。码猜中只等于按响门铃；拿不到 secret
进不了 PAKE。secret 只经 TLS 在「注册中心 ↔ 客户端」之间传输，不出现在任何可
离线破解的位置。

### 2.1 会话模型（注册中心内存表，janitor 回收，模式同信令 Hub）

```
PairingSession {
  code        string    // 4 位数字，服务端生成，全局唯一
  secret      string    // 高熵会话口令，create 时提交
  creator     string    // node_id（Ed25519 签名背书，须有效租约）
  claimer     string    // 敲门方 node_id（首个 claim 占位）
  claimerName string    // 敲门方显示名（供接受门展示）
  state       ACTIVE → CLAIMED → GRANTED | DENIED | BURNED | EXPIRED
  createdAt / expiresAt
}
```

状态迁移：

| 迁移 | 触发 |
|---|---|
| ACTIVE → CLAIMED | 首个有效 claim（占住唯一 pending 位；重复 claim 返回 busy） |
| CLAIMED → GRANTED | creator approve；secret **一次性发放**，发放即终结 |
| CLAIMED → DENIED | creator deny；码立即作废（DoS 容忍：攻击者猜中也只能烧掉码，逼重铸） |
| ACTIVE/CLAIMED → BURNED | creator 重铸（旧码作废）或 GC |
| 任意 → EXPIRED | janitor 按 TTL 清扫 |

### 2.2 端点（`/v1/pair/*`）

| 端点 | 调用方 | 准入 | 行为 |
|---|---|---|---|
| `POST /v1/pair` | 亮码方 | 签名（同公告级身份约束）+ 有效租约 | 建会话，返回 `{code, ttl}`；同节点活跃会话数受 `MaxPairingsPerNode` 限制 |
| `POST /v1/pair/claim` | 敲门方 | 签名 + 有效租约（同信令 hello 级约束），per-IP KeyedLimiter 叠加 | 码存在且 ACTIVE → 以 `claim_id` 占 pending 位返回 `{status:"pending"}`；同 `claim_id` 轮询：approve 后返回 `{secret, creator}`（一次性发放）；码错返回 not_found；被他人占用返回 busy |
| `POST /v1/pair/approve` | 亮码方 | 签名 | `{code, decision, claimer}` → GRANTED/DENIED |
| `POST /v1/pair/requests` | 亮码方 | 签名 | 返回 `{code, expires_in, requests:[{node_id,name}]}`——creator 短轮询（2s；POST 因签名走请求体，与 register/announce 的 body-sig 约定一致） |

签名负载约定（复用 `BuildPayload` 规范化，字段 `\n` 连接）：

```
pair-create:  node_id | secret | ts
pair-claim:   node_id | code | claim_id | ts
pair-approve: node_id | code | decision | claimer | ts
pair-requests: node_id | ts
```

claim 带节点签名的三个理由：①亮码方接受门要展示敲门人身份（node_id + 租约
显示名）；②pending 位与轮询归属绑定 `claim_id`，服务端才能区分「同一敲门方在
轮询」与「第二人抢入」；③与信令 hello 的准入级别一致（claimant 无租约也进不了
后续信道）。错误码不可归因到具体会话，故**无 per-session 尝试计数**——枚举
防线 = claim per-IP 限流 + 拒绝即烧码 + 一次性发放。

### 2.3 配置（p2pd）

```yaml
pairing:
  enabled: true          # 缺省开；false 时端点 404，客户端明确降级
  code_ttl: 5m           # 配对码有效窗
  session_ttl: 10m       # 会话总寿命上限（与信令 SessionTTL 对齐）
  code_len: 4            # 位数（运营遇枚举压力可升 6；客户端不暴露开关）
  max_per_node: 8        # 单节点活跃配对会话上限（对齐信令 MaxSessionsPerNode）
  claim_per_min_per_ip: 30  # claim 限流
```

### 2.4 时序（缺省方向：发送方亮码）

```
发送方(亮码)                      注册中心                          接收方(敲码)
    │ POST /v1/pair {secret, sig}    │                                │
    │◄─────── {code:"4823", ttl:300} ─│                                │
    │ 屏显「配对码 4823 (4:59)」       │                                │
    │ 轮询 /v1/pair/requests(2s) …    │        输入 4823 → POST /claim │
    │                                │◄────── {status:"pending"} ─────│
    │◄── requests: {from: node,name} ─│                                │
    │ 「设备 NAS-客厅 请求连接 [接受]」  │   （轮询 claim 直到批准/拒绝/过期）│
    │──── approve {sig, accept} ─────►│                                │
    │                                │───── {secret, creator} ───────►│
    │ joinChannel(secret) ◄───────────┼──────────► joinChannel(secret) │
    │      此后与现有链路逐字节相同（版本协商→PAKE→候选→打洞→传输）        │
```

身份钉定：配对模式跳过公告/解析（联邦路由不涉入）。接收方以 claim 返回的
`creator` 钉定发送方（替代 resolve 来源核对：`paired.peer_id == creator`）；
亮码方的接受门展示 claimer 身份（node_id + 显示名）。反向（接收方亮码）对称：
claimer 是文件发送方，PAKE 发起方恒为文件发送方，与谁建会话无关。

## 3. 安全分析

| 层 | 防护 |
|---|---|
| 离线破解 | 码只出现在 TLS 请求体；房间号/PAKE 密码均为 60bit secret，观察者无从下手 |
| 时间窗 | TTL 5min、会话总寿命 10min、一次性发放、janitor 清扫 |
| 枚举 | claim per-IP 限流（30/min）；猜中即占 pending 位，须人工批准，拒绝即烧码 |
| DoS | 猜中最坏结果 = 烧码逼重铸；claim/建会话均有配额 |
| MITM | 注册中心持有 secret，理论可冒充任一端（见下） |

**信任模型变化（须写入 README）**：今天的 12 位口令模型里注册中心对口令零知识、
不可 MITM；配对模式下注册中心签发并持有 secret，可主动冒充任一端——这是服务端
签发短码的固有代价（与 Box 取件码同构，公共注册中心运营方信任已在使用前提中）。
自建注册中心 + 双端自查身份可收敛该面。二期扩展点：**SAS 校验**（HKDF 派生
4 位指纹，双方屏显口头比对，MITM 必然指纹不符）——本期不做，协议上留
`DeriveKey(session,"sas")` 路径即可。

**无门模式如实声明**：`--yes`/`--json`/无 TTY 自动批准时，安全兜底退为
「限流 + TTL + 一次性发放」，猜中码即得会话（每码一次机会 1/10⁴）。CLI 交互
TTY 与 GUI 缺省强制人工门。

## 4. 各端交互

### p2pc CLI

- `p2pc send --pair <文件...>`：创建会话 → 屏显 `配对码: 4823（5 分钟内有效）` →
  轮询敲门 → TTY 问询 `设备 X (node) 请求接收，接受? [Y/n]` → 批准后进入发送流程；
  码过期自动重铸（新码新 secret，屏显新码）。
- `p2pc recv 4823`：纯 4-8 位数字自动识别为配对码（legacy 口令为 12 位分组建制，
  无形状冲突；`--code 1234` 自定义短口令是合法 legacy 流，故识别顺序 = 先 claim，
  not_found 回退 legacy 口令解析并提示）；`--pair` 强制只走配对语义。
- `p2pc recv --pair`（无位置参数）：反向模式——接收方亮码，等待对方敲码后推送文件。
- `--yes`/`--json`：自动批准；JSON 增事件 `pair_code`（code/ttl）、`pair_request`
  （from/name）、`pair_denied`、`pair_expired`。stdout 契约（`口令: ` 行）不动，
  配对模式只新增行/事件，supervisor 旧解析器零影响。

### p2pcweb（PigeonBeam 网页）

- 发送页：大号 4 位码 + 倒计时环；敲门请求卡片（设备名 + 接受/拒绝）；过期自动重铸。
- 接收页：4 格数字输入（与 Box 取件码分格输入同构的品牌范式）；提交后 pending
  态提示「等待对方确认」。
- SSE 事件流新增 pairing 事件；后端 `/api/pair*` 与 `/api/recv` 形状识别对接。

### 降级矩阵

| 客户端 | 注册中心 | 结果 |
|---|---|---|
| 新 | 新 | 配对可用 |
| 新 | 旧（无端点/`pairing.enabled=false`） | 404 → 明确报错「注册中心不支持配对码，请使用口令直传」 |
| 旧 | 新 | 完全无感（端点纯增量） |

## 5. 边界与异常

- **码过期**：CLI 提示/自动重铸；GUI 自动换新码；claim 侧返回明确「已过期」。
- **多注册中心 failover**（`--registries` 链）：配对码是**注册中心本域**的，不做
  联邦路由；客户端 create/claim 固定走主注册中心，不逐节点尝试（码与 registry
  一对一，跨域无意义）。
- **重复使用**：GRANTED/DENIED/BURNED/EXPIRED 后码即死，claim 返回对应错误。
- **并发抢注**：同一码仅一个 pending 位；第二 claim 返回 busy，不覆盖。
- **租约过期**：create 时校验租约；approve 时若 creator 租约已失效拒绝操作。
- **重铸竞态**：亮码方重铸（新码）后旧码立即 BURNED，pending 中的旧 claim 轮询
  返回 expired。

## 6. 实施拆分

- **P1（核心）**：p2pd `internal/registry/pairing.go` + 4 端点 + 配置；p2pc
  `internal/client/pairing.go` + Send/Receive 配对变体 + CLI 接线；单测 + 回环 e2e。
- **P2**：p2pcweb 后端 API + 前端（大码/倒计时/4 格输入/接受卡片）。
- **P3**（后续列车）：desktop sidecar 事件消费、p2px supervisor 接入、
  frontend-core 范式对齐、README/文档站。

## 7. 决策点（已拍板）

| # | 决策 | 结论 |
|---|---|---|
| D0 | PRODUCT.md 维护模式解冻 | 开第二豁免「配对码易用性收口」，修 PRODUCT.md |
| D1 | 谁亮码 | 双向支持；缺省发送方亮码 |
| D2 | TTL | 默认 5min（`pairing.code_ttl`），会话总寿命 10min |
| D3 | 人工接受门 | 缺省开；`--yes`/`--json`/无 TTY 自动放行 |
| D4 | SAS 高安全模式 | 本期不做，留 HKDF 指纹扩展点，README 写明信任模型 |
| D5 | 码位数 | 固定 4 位；服务端留 `code_len` 配置，客户端不暴露 |
