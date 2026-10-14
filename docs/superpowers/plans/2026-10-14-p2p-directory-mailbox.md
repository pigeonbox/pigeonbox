# P2P 调度层 v2 — 在线名录 + 邀请信箱 实施方案(交新会话执行)

> 执行会话:先读本文档 + 记忆档 `fcb-p2p-p1-federation-admin-2026-10-14`(含 83.5s 墙证据链,与本方案正交可并行)。设计已评审定稿(2026-10-14 与用户对话定稿),直接按 Task 执行。

**Goal:** p2pd 增加「在线名录 + 邀请信箱」,让一台信令服务器上的 N 个实例互相发现并两两进入房间:发起方名录选对端→密封邀请投信箱→接收方一键接收——全程免手抄口令、**接收方可在 NAT 后**(无需公网 URL)。

**现状机制(30 秒背景)**:房间号=SHA256(口令),信道会话/公告/节点租约全在 p2pd 内存(会话 TTL 10min/公告 15min/节点 1h),零持久化;双端持口令自行进房;supervisor(p2px)已实现自动续传环+幽灵看门狗+并发上限(1.22.x 系列)。

**安全不变量(每 Task 违反即打回)**:
1. 口令即授权:信箱条目必须是**密文**(nacl/box,收端节点公钥密封),p2pd 全程只见密文;
2. 名录零敏感:只含 node_id/显示名/URL/公钥/在线时刻,**绝无口令与房间信息**;名录 opt-in(缺省不可发现);
3. 名录条目带节点签名(注册已有签名 scheme);信箱密封体内容含发送方公钥(收端开箱验真);
4. 全部新端点走限流;信箱 TTL 15min/每箱 ≤10 条/单条 ≤4KB;
5. 生成物勿手改;p2pd 是叶子仓——只依赖 x/crypto(新增 nacl/box、curve25519 子包引用,x/crypto 已在 go.mod,零新依赖)。

---

### T1: p2pd — 名录(presence directory)

- `internal/registry/service.go`:Register 增可选字段 `Discoverable bool / PublicURL string / BoxPub string`(签名负载扩展,**服务端双格式验证**:请求含新字段→验扩展负载 `node_id|url|name|version|caps|ttl_seconds|nonce|ts|discoverable|public_url|box_pub`;不含→验旧负载——旧 p2pc 不断;**README 签名负载文档同 commit 更新,客户端逐字节契约**)。**BoxPub=X25519 公钥 hex(自 Ed25519 seed 推导,见 T3 sealed.go;x/crypto 无远端 Ed25519→X25519 公钥转换 API,发端密封只能用名录返回的 box_pub)**;Store 增节点记录字段;Sweep 随租约回收。
- `internal/server/server.go`:`GET /v1/directory`(限流,复用 resolve 桶;仅返回 discoverable && 未过期节点的 `{node_id, name, url, box_pub, online_since}`);注册处理器挂 route(照 resolve 的挂法,server.go:151 附近有 relay_port 先例)。
- 测试:目录仅含 discoverable 节点/租约过期消失/签名伪造拒绝。

### T2: p2pd — 信箱(mailbox)

- `internal/registry/service.go` + store:`map[node_id][]sealedEntry{From, Nonce, Boxed, TS}`,TTL 15min(取件即弹/过期清扫并入 Sweep),每箱 ≤10,单条 ≤4KB。
- `POST /v1/mailbox/{to_node}` body `{from, nonce, boxed}`(base64)——**纯密文投递,p2pd 不验内容**(收端开箱验真);限流(写桶)。
- `GET /v1/mailbox/{to_node}` → 弹出全部密封条目(取后即删;窃取=拒绝服务非泄密,限流兜底,设计注明)——**弹出是写语义,限流走写桶 writeLim(与 POST 同桶;防第三方高频轮询清箱)**。
- 测试:TTL 过期/满箱拒/取后即删/并发投取。

### T3: p2pc — directory/invite/mailbox + 密封原语

- `internal/client/` 新增 `sealed.go`:Ed25519→X25519 密钥转换(pub 直转 `curve25519.X25519`;priv=sha512(seed)[:32] 后 clamp)+ `nacl/box.Seal/Open` 封装;sealed 包格式 `{from_pub, nonce, boxed}`(from_pub 入密文内做来源验真)。
- `cmd/p2pc/main.go` 三支:
  - `directory --registry URL`:JSON 列在线名录(含 box_pub);
  - `mailbox --registry URL --key PATH [--watch] [--interval 5s]`:无 `--watch` 时弹出全部密封条目,**逐条开箱**后 NDJSON 输出 `{"event":"invite","code":...,"from":...,"note":...}`(开箱失败=密文非本节点,跳过);**`--watch` 长驻模式:固定间隔(缺省 5s)轮询 GET,每条开箱成功即输出 invite 事件并立即消费(已弹即删无重复),开箱失败静默跳过;stdout 只出 NDJSON,退出由父进程杀**——T4 supervisor 依赖此形态;
  - `send ... --invite-to <node_id> [--invite-note s]`:公告口令后,从名录取目标 `box_pub`→密封 `{code,from_name,note}`(from_pub 入密文内做来源验真)→投递目标信箱(失败仅 WARN 不影响发送——邀请是便利非通路)。
- 测试:密钥转换往返/密封开箱/篡改检测(mailbox 用测试 registry fixture,照 client_test.go newFixture 先例)。

### T4: core supervisor 集成(信箱喂 P3 收件箱)

- `app/p2px`:init 时(直传 enabled 且二进制在位)spawn 长驻 `/tmp/... p2pc mailbox --watch --registry ... --key <data>/p2p/node.key`(nodeKeyPath 先例 spawn.go:83)→scanLines 解析 `invite` 事件→`AddInvite(from, code, note)`→**P3 待收箱 UI/API 零改动复用**。**watcher 非 Task(不占并发闸、无 specSnapshot):既有重派机制绑 Task 结构不适用,自建轻量守护 goroutine——进程退出即指数退避重启(1s 起、上限 60s、抖动),Stop 时随 supervisor 收(杀进程+停守护)**。
- 测试:stub mailbox 进程吐 2 条事件→AddInvite 收到 2 条;watcher 进程死→守护按退避重启。

### T5: contracts IDL + 前端(对端选择器)

- `contracts/idl/p2p.thrift`:`GET /admin/p2p/directory`(名录透传,api.get 照 status/tasks 先例)+ `AdminP2pSendReq` 加可选 `invite_to/invite_note` → 三条生成链;**core 跑完 gen-router.sh 后必须在 `gen/router/p2p/middleware.go` 补 `_adminp2pdirectoryMw`(挂 `middleware.AdminOrAdminKey()`,照 `_adminp2psendMw` 先例)——手工区 hz 不触碰,漏写=编译失败**;core handler 透传(spawn args 追加)。
- `frontend-core`:`src/views/admin/P2pTransfer.vue` 发送卡加「对端」下拉(名录,近用优先)+ 备注框;邀请条文案更新(「推送邀请到名录对端」)。i18n zh/en。
- 验证:typecheck/build/vitest + 手工走查。

### T6: E2E + 发布

- 本地双实例:名录可见→A 名录选 B→推送(经信箱)→B 待收→接收→100MB sha256 一致;
- 列车:p2p v0.6.8(**T1-T3 全在 p2p 仓,必发,无「若无变更」分支**)/ contracts v0.15.0(IDL 变) / core v0.21.0 / fcore v0.6.0;SET 走 `make train-bump TRAIN=1.23.0 SET="..."`(各版本号执行时重估)。
- 注意(上一趟教训):库 tag 先行不挪动;trainctl goModPin 已自动同钉 contracts;终端打包脚本已支持 P2PC_REF。

## 已知边界(写进 T1/T2 注释)

- 信箱 GET 无鉴权=密文可被第三方抢收(拒绝服务非泄密;收端开箱失败即跳过)——v2 可加节点签名取件;
- 名录显示名可撞(真身=node_id+公钥指纹,UI 建议显示短指纹);
- 不做房间大厅/公开房间列表(破坏口令即授权模型)——名录是"实例名录"不是"房间列表"。

## 验收清单

- [ ] 名录 opt-in:缺省注册不出现在名录
- [ ] 信箱密文投递→开箱验真→喂 P3 收件箱→UI 待收邀请可见
- [ ] NAT 后接收方(无公网 URL)经信箱完成邀请+传输(双实例单机模拟:B 不配 URL)
- [ ] 幽灵/篡改密文被收端跳过;满箱/TTL 清扫正确
- [ ] 全部仓 CI 绿;列车 1.23.0 shipped
