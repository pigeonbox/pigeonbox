# 取件计次语义重构（2026-10-24）

> 状态：已实现（core 工作区）｜破坏性变更｜随下一次发布列车发版
> 触发：2026-10-23 口径收口后的第三轮审计（独立代理 + 自查复核）

## 1. 一句话

**「一次取件」= 一次内容交付 = 一个下载令牌（取件会话）；同一个令牌至多扣 1 次取件次数。**

扣次从「每个下载请求」移到「内容交付前」，并与令牌绑定；「次数耗尽」不再混作「过期」。

## 2. 修的是什么（缺陷清单）

| # | 缺陷 | 症状 | 严重度 |
|---|---|---|---|
| D1 | 匿名取件 retrieve 自己扣次，随它下发的直链下载又扣一次 | 一次取件扣 2 次，count 样式下对方可用次数直接减半 | 高 |
| D2 | 扣次点在**每个下载请求** | 多文件逐个下载逐个扣 ⇒「取件次数=1 的多文件分享只能下载第一个文件」，而打包 zip 只扣 1 次 ⇒ 两条 UI 路径不可比 | 高 |
| D3 | 「次数耗尽」混在 `IsExpired` 里 | **按取件次数的分享，走取件码通道时最后一次取件必然 404 拿不到文件**（retrieve 扣到 0 ⇒ 判过期 ⇒ 下载被拒）；分享页通道却能拿到 ⇒ 两条通道结论相反 | 事故级 |
| D4 | 扣次早于子文件归属校验与 zip 组装 | `file=` 不属于该分享 / zip 组装失败 ⇒ 404/500 但次数已被吃掉（白扔一次取件机会） | 高 |
| D5 | 文本分享在 select 即交付正文，却从不扣次、不记取件人、不写传输日志 | owner 设的「按取件次数」上限对文本分享形同虚设；传输日志对文本分享失明 | 高 |
| D6 | 令牌签发按**规范码**、校验按**请求原始码** | 用户把下载 URL 的 code 换成 6 位取件码 ⇒ 401「令牌无效」（令牌本身是好的） | 中 |
| D7 | 锁定「预检键=原始码 / 记账键=规范码」分叉 | 6 位码入口的 429 预检恒不命中（只有深层闸门拦得住） | 中 |
| D8 | `security.download_token.validity_seconds` 从未被读取 | 运维改配置无效（硬编码 1000s） | 低 |
| D9 | `ErrDownloadToken` 定义了从不使用 | 死代码 | 低 |
| D10 | 匿名取件结果页 `remaining_count` 恒发 0 | 页面显示「剩余可取次数 0」，用户以为文件已失效 | 低 |

附带收口：`pkg/codex` 违反架构守卫规则 1（pkg 不得 import repo）⇒ 解析器下沉到
`repo/db/dao.ResolveByCode`，占位判定 `IsNotReady` 迁到 `model`（此前 core main
的架构棘轮就是红的，会挡住发版列车）。

## 3. 新语义（不变量）

1. **扣次点 = 内容交付前**：
   - 文件分享：`GET /share/download` 交付时扣；
   - 文本分享：`GET /share/select` 交付正文时扣（select 就是交付面）；
   - 匿名取件：`POST /anonymous/retrieve` **只发凭证，不扣次**。
2. **一个下载令牌 = 一次取件会话**：同一令牌下的多次交付（多文件逐个下载、打包
   zip、断点续传 Range、重复点击）**只扣 1 次**，只记 1 个取件人。
3. **次数耗尽 ≠ 过期**：`IsExpired()` 只判时间；`IsCountExhausted()` 独立判定。
   耗尽 ⇒ 拒绝**发起新的取件**（`20004` 超过取件次数 / 匿名通道 `20007`），
   **已扣次的那一次取件仍可完成交付**（D3 的正解）。
4. **失败不消耗次数**：归属校验、zip 组装等前置校验全部在扣次之前完成。
5. **令牌校验按规范码**：下载端点先解析码（6 位取件码 / 8 位分享码都能用），
   再按规范码验签。
6. **锁定键统一用规范码**：预检与失败记账同一把钥匙（6 位码入口与 8 位码入口
   共享爆破预算，预检真正生效）。

## 4. 实现要点

| 层 | 落点 |
|---|---|
| 模型 | `model.FileCode.IsExpired()` 只判时间；新增 `IsCountExhausted()` / `IsPickupAvailable()` / `IsNotReady()` / `PickupCodeLength` |
| 计次 | 新表 `pickup_charges`（唯一索引 `(code, token_hash)`）：`dao.ChargePickupOnce` ⇒ 登记（ON CONFLICT DO NOTHING）+ 原子扣减；扣减失败**撤销登记**（否则该令牌被误判成「已计次」而免费放行） |
| 令牌 | `pkg/security`：形态 `exp.nonce.sig`（nonce 保证同秒签发的令牌互不相同 ⇒ 计次键可靠）；计次指纹 = `HMAC(secret,"fp|"+token)`（**单向**，落库的不是令牌本身 ⇒ DB 泄漏不等于泄漏下载凭证）；TTL 接配置 |
| 编排 | `app/share.Service.ChargePickup` → handler `chargePickup`（扣次 + 记取件人同点） |
| 迁移 | `000004_pickup_charge`（版本化）+ `AutoMigrate` 兜底；`janitor.CleanupPickupCharges` 按令牌 TTL 清理 |

## 5. 破坏性变更清单

| 变更 | 影响面 |
|---|---|
| 下载令牌形态 `exp.sig` → `exp.nonce.sig` | 升级瞬间在途令牌失效（窗口 ≤ TTL，取件页重新取一次即可） |
| 匿名取件 retrieve 不再扣次 | 依赖「取件即扣次」的集成需改为在下载后观察 used_count |
| 「次数耗尽」错误码 `10003`（无权限）→ `20004`（超过取件次数）/ `20007` | 前端 i18n 已有 20004/20007 文案，无需改动 |
| `pkg/codex` 下沉（公开包消失） | 仓内 5 个域已同步；外部依赖方（若有）需改用 `repo/db/dao.ResolveByCode` |
| `share.Service.GetFileWithUsage` 去掉 `recordViewer` 布尔位 | 记取件人改由计次点触发 |
| `model.FileCode.IsExpired()` 不再含次数语义 | 依赖「次数=0 ⇒ 过期」的下游判定需改用 `IsCountExhausted()` |

## 6. 验证

- **单测**：DAO 计次语义（同一令牌只扣一次 / 不同令牌各扣一次 / 耗尽不扣且撤销
  登记 / 不限次 / 无令牌指纹退化）；handler 端到端（多文件逐文件下载只扣 1 次、
  失败请求不消耗次数、末次取件拿得到文件、文本 select 扣次、令牌按规范码校验、
  跨分享令牌不可用）；匿名通道端到端（取件→下载全链路、耗尽给 20007）。
- **负对照**（断言必须能变红）：抽掉「同一令牌只扣一次」⇒ 多文件用例红；把扣次
  挪回归属校验之前 ⇒ 失败请求用例红；还原「retrieve 自己扣次」⇒ 末次取件用例红。
- **冒烟**：`scripts/smoke-full.sh` S20a/S20b（两条通道各扣 1 次）+ 新增 S20c
  （文本分享 select 扣次）、S20d（末次取件必须拿到文件）。
- **门禁**：core 全量 43 包测试绿、go vet 干净、架构棘轮绿；全仓 67 包测试绿；
  frontend-core typecheck + 184 单测绿；frontend 壳 typecheck 绿；反代体积上限
  与 shell 变量边界门禁绿。

## 7. 后续（已做/待做）

### 7.1 本轮已补齐

- 无令牌部署（`security.download_token.enabled=false`）的**兜底会话键**：
  `security.DownloadSessionKey(code, ip)` = HMAC(secret, "ip|"+code+"|"+ip)
  ⇒ 关闭令牌时多文件逐个下载仍只扣 1 次（负对照已覆盖）。
- `pkg/security.ErrDownloadToken`（定义了从不使用的死代码）已删。

### 7.2 待做：owner 侧的逐条取件历史（**跨一次列车**，别仓促动手）

**缺口**：`file_codes.viewer_ip/viewer_at/viewer_count` 只有「最后一次 IP + 累计
次数」⇒ owner 在「取件历史」页看不到逐条记录（他只能靠到件通知逐条得知）。

**关键发现：明细数据已经存在，不必新表** —— `transfer_logs` 逐条记录了每次下载
（IP / 时间 / 操作码），且本轮给文本分享补了写入（`logTextView`）。
⇒ 缺的只是「**owner 自己的视图**」（目前只有管理端的传输日志页能看到明细）。

**实施计划（下一趟列车 3.3.17）**：

1. **contracts**（先行，代码必须先推）：`idl/share.thrift` 的
   `UserShareItemData` 加 `22: optional list<PickupRecord> pickups`，
   `PickupRecord { picked_at, ip, channel }`；跑 `scripts/gen-model.sh`
   （CI 用 `CHECK=1` 对账）+ `cmd/gen-openapi` + `cmd/gen-ts`。
   ⚠️ **前端只吃 contracts 的发布 tgz** ⇒ contracts 的代码必须**先于 bump 推上去**，
   否则前端构建时钉的还是旧 tgz。
2. **core**：从 `transfer_logs` 按 `file_code` 组装最近 N 条明细（复用既有 DAO，
   不新增表）；`UserShareItemData.pickups` 映射；计次点同时写一条明细
   （与扣次同点 ⇒ 明细与次数天然对齐）。
3. **frontend-core**：取件历史页（`views/user/History.vue`）加一列「取件明细」
   （可展开看 IP/时间/通道），并把 contracts 的 tgz 钉版抬到新版本。
4. **列车**：`make train-bump TRAIN=3.3.17 SET="contracts=v0.18.6 core=v0.32.1"`。
   顺序约束：bump（改钉版）→ 合并 → **tag 阶段发 contracts 的 tgz** →
   release 阶段构建前端镜像（此时前端才能拿到新 tgz）→ finalize。

**为什么本轮不做**：它要动 contracts 的生成链 + 跨一次列车的发布顺序
（contracts 的 tgz 只有在 tag 阶段才发布 ⇒ 前端必须等下一趟才能消费），
在一次「修复 + 发版」的窗口里塞进去，失败模式是**把发布线搞挂**（前端钉了
尚不存在的 tgz ⇒ 构建失败 ⇒ 列车卡住）。明细数据本身已经在库里，不急。

### 7.3 其它已知项

- 计数与取件人明细仍只有「最后一次 IP + 累计次数」——见 7.2。
- `mcp` 的 `get_share_content` / `download_share_file` 仍不消耗取件次数
  （管理面工具的有意设计，见 `docs/MCP-README.md`）。
