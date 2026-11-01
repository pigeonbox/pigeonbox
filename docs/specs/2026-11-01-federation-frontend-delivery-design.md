# 联邦前台化设计：跨站投递（URL 口径）

> 2026-11-01 落纸。承接 `docs/specs/2026-10-30-capability-evolution-roadmap.md` §4.2。
> **用户已拍板**：寻址口径 = **对方站点基址 URL**；范围 = 全部真欠项，分多趟车。
> 本稿只设计**第一件事**：让匿名访客能把文件投到**另一个柜子**。

## 1. 现状（2026-11-01 核过代码，不是推测）

| 事实 | 出处 | 对本设计的影响 |
|---|---|---|
| 公开收件端点 `POST /api/v1/p2p/invite` **已存在** | contracts `P2PPublicService.PostP2PInvite` | 对方柜「收邀请」这半边**不用造** |
| 但它收的 `code` 是**调用方给的** | `idl/p2p.thrift` `PostP2PInviteReq{code, from_name, note}` | ⇒ **对方柜不铸码** ⇒ 跨站取件码归属仍未解决 |
| 邀请收件箱是**内存态**（cap 20 / TTL 10 分钟 / 重启即丢） | `core/app/federation/invite.go` 文件头注释 | 它是「配对窗口」语义，**不适合当长期投递通道** |
| 现有联邦信任模型 = **口令 bearer**（同手工交接信任级） | `idl/p2p.thrift` 文件头注释 | ⇒ 本设计**沿用**，不引入新认证机制 |
| 联邦节点密钥是 **Ed25519 私钥**，`node_id` 即公钥 hex；`box_pub` 是同 seed 派生的 X25519 公钥 | `core/app/federation/keys.go` · `p2p/internal/store/store.go` | 对端公钥**可从联邦目录取到**（身份可验） |
| 出站推送走 SSRF 守卫，**私网目标需 `security.ssrf.allow_private_networks`** | `core/pkg/security/ssrf.go:62` | ⚠️ **默认会把跨站投递的真实用例挡掉**（自托管场景对方就在局域网） |
| 寄件码域（反向收件）**整条链已存在** | `idl/request.thrift` | 见下表 |
| 对方柜铸 6 位取件码的能力 | `core/app/share` 的 `PickupCodeMinter` | 落成分享时才铸 ⇒ **归属天然正确** |

### 寄件码域的现有端点（本设计的地基）

| 端点 | 权限 | 作用 |
|---|---|---|
| `POST /api/v1/user/requests` | 登录用户 | 铸一个投递链接（token = crypto/rand 32 hex，**不是 6 位取件码**） |
| `GET /request/:token` | **公开** | 查投递链接信息 |
| `POST /api/v1/request/:token/upload` | **公开** | **访客投递文件**（multipart `files[]`） |

⇒ **访客投到对方柜后，文件落成「链接属主名义的分享」⇒ 对方柜的 share 域才铸 6 位取件码**
⇒ ⇒ **「跨站取件码由谁铸」的答案是：对方柜铸**（不需要跨柜共享码空间，这是关键的好消息）。

## 2. 形态（URL 口径）

```
访客 ──① 在 A 柜前台填「对方柜 URL」+ 选文件
        │
A 柜服务端 ──② 校验目标 ∈ 管理员登记的「可投递对端」
        │
        ──③ 用共享口令向 B 柜铸槽位（POST /api/v1/federation/delivery-slot）
        │        B 柜验口令 ⇒ 铸一个寄件码 token ⇒ 回 {token}
        │
        ──④ 转发文件到 B 柜 POST /api/v1/request/:token/upload
        │        B 柜落库（属主名义）⇒ B 铸 6 位取件码 ⇒ 回 {pickup_code}
        │
        └──⑤ 把 B 的 6 位取件码回给访客展示（访客转告取件人）
取件人 ──⑥ 在 **B 柜** 用 6 位码取件
```

### 为什么「文件转发」而不是「跳转对方柜上传」

- 访客在 A 柜完成投递 ⇒ 符合「邀到别人的柜」的产品意图（A 柜是入口）
- 6 位码由 **B 柜**铸并返回 ⇒ 访客拿到的是**在 B 柜真的能用的**码
- 取件人站在 B 柜取件 ⇒ **链接稳定性**（取件码与链接属于 B 柜）

⚠️ 代价：**大文件要过 A 柜中转**（带宽 + 内存）⇒ 必须**流式转发**（不得整文件读进内存），
且 A 柜的体积上限对「转发」这条路径要单独算（见 §5 风险）。

## 3. 信任模型与安全面

### 3.1 对端登记（admin ↔ admin，事先配）

新增配置段 `p2p.federation.delivery_peers[]`：

```yaml
p2p:
  federation:
    delivery_peers:
      - url: http://10.10.30.253:12345   # 对方柜基址（URL 口径）
        token: <共享口令>                 # 口令 bearer（同手工交接信任级）
        name: 张三的柜子                  # 前台展示名
        allow_private: true              # 允许该对端落在私网（自托管场景必需）
```

**双向登记**才允许投递：
- A 柜登记 B ⇒ A 可以往 B 投递
- B 柜登记 A ⇒ B 才认 A 的铸槽位请求

⇒ **误投面**：访客填一个未登记的 URL ⇒ A 柜直接拒（不是「发出去后发现错」）
⇒ **SSRF 面**：出站 URL **只来自 admin 配置**，不是访客任意输入 ⇒ 攻击面从「任意 URL」收窄到「admin 配的 URL」
⇒ **私网面**：`allow_private` **按对端粒度**开，而不是全局 `security.ssrf.allow_private_networks`
（全局开关一开，所有出站点位都放行私网 ⇒ 面太大；按对端粒度只放行 admin 明确配的那几个）

### 3.2 口令 bearer（沿用现有联邦信任模型）

- A 柜调 B 柜铸槽位时带 `X-Federation-Token`（= 登记的共享口令）
- B 柜比对登记对端的口令 ⇒ 匹配才铸槽位
- 口令即权限（与现有邀请信封同信任级）⇒ **不做**「口令 = 管理员口令」这种高价值复用

⚠️ 口令比对用**常数时间比较**（防时序侧信道）。

### 3.3 铸槽位端点的滥用面

`POST /api/v1/federation/delivery-slot` 是**公开端点**（否则 A 柜无法匿名调用）⇒ 必须防护：

| 防护 | 理由 |
|---|---|
| 必须带**匹配的对端口令** | 否则任何人可让 B 柜无限铸槽位（资源消耗面） |
| **每对端速率限制** | 沿用既有 `download` 限流桶（`/api/v1/p2p/invite` 同款） |
| 铸出的 token 有**短 TTL** | 寄件码 token 本身有 `expire_*` ⇒ 不新增 TTL 语义 |
| **不返回任何敏感信息** | 只回 `{token}`（投递链接令牌）⇒ 不回 6 位码（此时还没有文件） |

### 3.4 取件码回传的可信度

④ 的转发响应带 `pickup_code`（B 柜铸的）⇒ A 柜展示给访客。
⚠️ **A 柜不铸码、只透传** ⇒ 6 位码的真实性由 **B 柜**保证
⇒ A 柜若被攻陷，能返回**假码**给访客 ⇒ 但访客在 B 柜取件时会失败 ⇒ **误投不成立**
⇒ ⇒ A 柜的回传**不需要额外签名**（它是「便利展示」，不是「授权凭据」）。

### 3.5 多副本下的行为（与既有降级一致）

`core/bootstrap/deployment.go:72-74` 已有既有降级：

```go
if cfg.Federation.Enabled && !conf.FederationAllowedInMode(mode) {
    cfg.Federation.Enabled = false
    logger.Warn("federation disabled: node identity is process-level (Ed25519), multi-replica semantics undefined")
}
```

⇒ **多副本（public×N + admin×1）下联邦被强制关闭** ⇒ 本设计的两个新端点
在多副本下**不可用** ⇒ 能力位 `federation_delivery` 自然为 false ⇒ 前端自动隐藏入口。

⚠️ 这与本设计的**路由落点**不矛盾：两个端点落 `publicapi` 域
（⇒ **只在 public 副本注册**），但**联邦运行时在多副本下整体关闭** ⇒ 端点存在但无对端可谈。
⇒ 二者是**两道独立的闸**，都关才不可用。

⇒ 本设计是旧稿「多副本下的直传/联邦（Q1 选项 2）：Phase 3 目标」的**第一步**：
先把公开面端点与前台入口做出来（standalone 可用），
多副本下要把联邦打开，还需解决「node identity 进程级 ⇒ 多副本语义未定义」这个更根本的问题。

### 3.6 能力位（前端显隐的真相源）

`/api/config` 的 `capabilities` 段**公开面**新增一位：

```json
{ "federation_delivery": true }
```

语义 = **联邦启用**（生效值）**且** **登记了至少一个可投递对端**。

- 公开面下发它**不泄露对端身份**（访客不知道对端是谁、在哪）⇒ 无害
- 对照：`storage_backend` / `redis_mode` / `federation` 仍**只在管理面**
  （它们泄露部署形态）
- ⚠️ 「缺字段 ≠ false」：老后端不下发这一位 ⇒ 前端按**未知**处理 ⇒ **不得据此隐藏入口**
  （宁可多给入口，也别给坏入口）

## 4. 契约增量（contracts，两段式发布）

### 4.1 新增公开端点（B 柜侧：铸槽位）

```thrift
// 跨站投递槽位（联邦前台化，2026-11-01）
//
// 语义：对面柜（A 柜）请求在本站（B 柜）铸一个「访客投递槽位」，
// 拿到 token 后用它往本站投递文件（POST /api/v1/request/:token/upload）。
// 授权 = 共享口令 bearer（同手工交接信任级，见文件头说明）。
// 落成后由本站 share 域铸 6 位取件码 ⇒ 码归属 = 本站（取件人在本站取件）。
struct PostFederationDeliverySlotReq {
    1: optional string from_name (api.body = "from_name")  // 发起柜展示名
    2: optional string note      (api.body = "note")       // 留言
    3: optional string title     (api.body = "title")      // 投递链接标题
}
struct PostFederationDeliverySlotResp {
    1: required i32    code    (api.body = "code")
    2: required string message (api.body = "message")
    3: optional string token   (api.body = "token")   // 寄件码 token（投递链接令牌）
}
```

### 4.2 访客投递响应带取件码（B 柜侧）

```thrift
struct GuestUploadData {
    1: required i32 file_count (api.body = "file_count")
    2: optional string pickup_code (api.body = "pickup_code")  // 新增：落成分享的 6 位取件码
}
```

⚠️ **非破坏**：新增 optional 字段 ⇒ 老消费方不受影响。

### 4.3 A 柜侧公开端点（访客发起投递）

```thrift
struct PostFederationDeliverReq {
    1: required string target_url (api.body = "target_url")  // 对方柜基址（须在登记对端内）
    2: optional string title      (api.body = "title")
    3: optional string note       (api.body = "note")
    // 文件通过 multipart/form-data 上传（字段名 files，兼容 file）
}
struct PostFederationDeliverData {
    1: required i32    file_count   (api.body = "file_count")
    2: optional string pickup_code (api.body = "pickup_code")  // 对方柜铸的 6 位码
    3: optional string target_url  (api.body = "target_url")
}
struct PostFederationDeliverResp {
    1: required i32    code    (api.body = "code")
    2: required string message (api.body = "message")
    3: optional PostFederationDeliverData data (api.body = "data")
}
```

⇒ **域归属**：三个端点全在 **publicapi 域**（公开面 ⇒ 匿名可达）
⚠️ 遵循 v0.20.3 起的「域 = 副本可见性」规则：**不能**挂在挂了 `UserOrAPIKey` 的 /api 组下
（否则匿名访问被误加登录门槛）⇒ 但 A 柜的 `/api/v1/federation/deliver` 路径在 `/api` 前缀下
⇒ **需要确认 hz 的路由分组是按路径前缀还是按 service 声明** ⇒ 若按前缀，
则需要放到不在 `/api` 下的路径（如 `/federation/deliver`），否则要调整分组规则。

## 5. 风险与待定

| 风险 | 说明 | 处置 |
|---|---|---|
| **大文件中转** | A 柜转发大文件占带宽与内存 | **流式转发**（`io.Copy` + `io.Pipe`），不整文件读入；A 柜对「转发」路径单独限体积 |
| **SSRF（私网）** | 对端常在局域网 | **按对端粒度** `allow_private`，不改全局开关 |
| **公开铸槽位端点被滥用** | 任何人可让 B 柜铸槽位 | 必须口令 + 限流 + 只回 token |
| **口令泄露** | 共享口令在两侧配置 | 文档明写「等同手工交接信任级」；管理台不回显明文 |
| **A 柜被攻陷** | 可伪造给访客的取件码 | 但访客在 B 柜取件会失败 ⇒ 误投不成立（§3.4） |
| **投递失败的一致性** | ③ 成功但 ④ 失败 ⇒ B 柜留了空槽位 | 槽位有 TTL ⇒ 自然过期；A 柜回「对方柜收件失败，请重试」 |
| **取件码语义** | 访客拿到的码是 B 柜的 | **UI 必须说清**「此码在对方柜使用」⇒ 否则用户在本柜试 ⇒ 以为坏了 |

## 6. 验收判据

- [ ] 访客在 A 柜前台填已登记的 B 柜 URL ⇒ 投递成功 ⇒ 拿到 **B 柜的** 6 位码
- [ ] 取件人**在 B 柜**用该码取件成功
- [ ] 填**未登记**的 URL ⇒ A 柜明确拒绝（「对方柜不在可投递名单」），**不发出去**
- [ ] B 柜**未登记 A** ⇒ A 的铸槽位请求被拒（B 回 403 类错误）⇒ 双向前提成立
- [ ] 铸槽位端点**无口令** ⇒ 拒绝
- [ ] **私有地址对端**在 `allow_private: true` 下可投递；`false` ⇒ 明确报「目标在私网，未允许」
- [ ] **100MB 文件**转发：流式、不整文件读入内存（A 柜 RSS 不线性增长）
- [ ] 三个新端点在**三副本部署模式**下的可见性符合预期（`routes_visibility_guard_test.go` 登记）
- [ ] 鉴权契约登记（`router_auth_guard_test.go`）：三个端点都是**公开面**
- [ ] 契约 wire 形状回归锁（`route_response_shape_test.go` 形态）
- [ ] **端到端真机**：两个实例（本机 + 另一台）互投 ⇒ 对方站取件成功

## 7. 落点

| 仓 | 内容 |
|---|---|
| **contracts** | §4 的三段增量（`idl/federation.thrift` 或扩 `idl/p2p.thrift`；`GuestUploadData` 加字段） |
| **core** | `app/federation/` 铸槽位 + 转发 + 对端配置 + 私网粒度；`app/request/` 回传取件码；`bootstrap/` 装配与守卫登记 |
| **frontend-core** | 前台寄件台：新增「投递到别人的柜」路径 + 对端选择 + 结果展示（含「此码在对方柜使用」的提示） |
| **hub** | 本设计稿 + 路线稿 §4.2 销账 |

## 8. 明确不做（本轮）

- 跨站**取件**（本轮只做投递；取件仍在本柜）
- 跨站的**到件通知**回传本柜（访客在本柜看不到对方柜的通知）
- 多对端并发投递的批量语义
- 联邦目录的「可投递对端」发现（对端靠 admin 手工登记）
