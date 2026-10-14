# P3 留位清零 — 联邦推送邀请 + p2pc --json + pb CLI 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans(内联执行)。checkbox 跟踪。

**Goal:** 清零 spec §14 全部留位:实例间推送邀请(免口令交接)、p2pc NDJSON 输出、pb CLI 直传子命令;随列车 1.22.0 发版。

**Spec:** `docs/specs/2026-10-14-p2p-peer-integration-design.md` §14(P3 推送语义)/§12(错误处理)

## Global Constraints

- API key 边界:`UserOrAPIKey` 绝不挂 /admin(apikey.go §4.1);pb 通道用新 `AdminOrAdminKey`(admin JWT **或** admin 用户的 API key)。
- 公开端点必须归限流桶 + routes_guard/ratelimit_bucket 双守卫。
- 邀请=口令 bearer(与手工交接同信任级);推送目标 URL 走 `security.ValidateEndpointURL`(SSRF);收件箱内存态 cap 20 + TTL 10min(口令有效窗)。
- IDL 新路由 → contracts 版本升 → core/go.mod 与 frontend tgz 钉版随列车(trainctl 自动)。

---

### T1: p2pc `--json` NDJSON(p2p 仓)
- `cmd/p2pc/main.go`:send/recv 加 `--json`;事件行 `{"event":"code","code":"..."}` `{"event":"log","line":"..."}` `{"event":"done","files":N}` `{"event":"error","msg":"..."}`;缺省纯文本不变(desktop 零影响)。
- 测试:`--json` 事件形态锁;纯文本格式锁不回归。
- tag **v0.6.3**。

### T2: core 推送邀请(P3 主体)
- `app/p2px/invite.go`:`Invite{ID,Code,FromName,Note,ReceivedAt}`;`AddInvite/TakeInvite/ListInvites/expireSweep`;`PushInvite(ctx,targetURL,payload)`(10s 超时,URL 校验)。
- `contracts/idl/p2p.thrift` 四端点:
  - `POST /api/v1/p2p/invite`(公开;body {code,from_name,note})——归 `download` 限流桶
  - `GET /admin/p2p/invites` / `POST /admin/p2p/invites/accept{invite_id}` / `POST /admin/p2p/invite-push{code,target_url,note}`
- `pkg/middleware/auth.go`:`AdminOrAdminKey()`(API key→admin 角色校验;否则 AdminMiddleware);`gen/router/p2p/middleware.go` 改挂。
- handler 四支;`bootstrap/middleware.go` bucket + `ratelimit_bucket_test.go` 同步;`routes_guard_test.go` 四条;notify 通知 admin(复用 CreateForUserSimple,best-effort)。

### T3: 前端(P2pTransfer.vue)
- 「待收邀请」卡:列表(来自/口令/剩余时间)+ 一键接收 + 过期消失。
- 发送任务行加「推送口令」:dialog(目标实例 URL+备注)→ 成功 toast。

### T4: pb CLI(server/cmd/pb)
- `pb p2p status|tasks|send|recv|cancel|invite-push`,Authorization 复用现有 API key 头形态。

### T5: 验证
- core 全测 -race + lint;contracts 三重 CHECK;p2p 测试;契约守卫绿。
- E2E:双实例 A invite-push → B 邀请箱 → accept → sha256 一致。

### T6: 列车 1.22.0
- 库线 tag:p2p v0.6.3 / contracts v0.14.0 / core v0.20.0 / frontend-core v0.5.0(fcore tgz+lock SRI 同步)。
- `make train-bump TRAIN=1.22.0 SET=...` → advance → shipped。
