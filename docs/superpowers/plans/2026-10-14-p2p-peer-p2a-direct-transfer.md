# P2a — 设备直传 supervisor 域 + admin 操作页 + server 镜像随包 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans(本会话内联执行)。Steps use checkbox (`- [ ]`) syntax.

**Goal:** 每台 server 实例内嵌 p2pc 直传能力:core 新增 supervisor 域(spawn/取消/配额/清扫),admin 新增「设备直传」操作页,配置页 P2P 分区补「直传」子段,server 镜像随包 p2pc 二进制。

**Architecture:** 数据面走子进程(每任务 spawn p2pc,进程组 kill 取消);控制面 supervisor 在 core 进程内;配置走 SystemConfig `p2p.direct` 子段(与 `p2p.federation` 并列,nil 保留下沉一层);「发布为分享」复用 `share.ImportLocalFile` 铸链(与本地导入同链路,配额/审核同权)。

**Tech Stack:** Go 1.26 / hertz / thrift IDL(hz gen 链) / Vue3+Element Plus。

**Spec:** `PigeonBox/docs/specs/2026-10-14-p2p-peer-integration-design.md`(§5/§7/§8/§10/§11/§13)

## Global Constraints

- IDL 真相源 `contracts/idl/`;改路由必走 gen-model.sh → gen-router.sh,`bootstrap/routes_guard_test.go` 必须绿。
- 生成物勿手改:`contracts/gen/`、`core/gen/router/`;`gen/handler/` 为手写区,但 hz 会为**新 service** 生成桩文件——新 service 直接用桩文件改实现即可(与 admin_service.go 历史坑不同,新文件无 redeclared 风险)。
- SystemConfig 新子段:指针段 + `UpdateConfig` 子段 nil 保留(与 Federation 同款);校验进 `validateSystemConfig`。
- 棘轮规则 8:不新增 `conf.GetGlobalConfig()` 直读——supervisor 的配置经 `config domain Default().GetConfig(ctx)` 取(DB 段),standalone 判定构造注入(与 fedRT 同款)。
- p2pc 输出解析:`口令: XXXX-XXXX-XXXX` 行锁定;stderr 原样透传进任务日志。
- 全链路 admin-only(路由全挂 AdminMiddleware);非 standalone 在任务创建期响亮拒绝。
- i18n zh/en 同构同行号;改 .vue 后必跑 `npm run build`(v-if 链教训)。

---

### Task 1: contracts IDL — p2p.thrift + 生成链

**Files:**
- Create: `contracts/idl/p2p.thrift`
- Regenerate: `contracts/gen/p2p/`、`contracts/openapi/openapi.json`、`contracts/gen/ts/`
- Test: `core/bootstrap/routes_guard_test.go`(加新路由断言)

**Interfaces:**
- Produces: gen/p2p 模型(`P2pTask`/`AdminP2pStatusData` 等)+ `/admin/p2p/*` 路由供 core gen-router 生成。

- [ ] **Step 1: 写 IDL** `contracts/idl/p2p.thrift`

```thrift
// p2p.thrift — P2P 设备直传管理端 API（2026-10-14 对称节点 spec §7/§8）。
// 全部端点挂 /admin 组（AdminMiddleware）；数据面=supervisor spawn p2pc 子进程，
// 本 API 只做任务编排，不代理文件流量。
namespace go p2p

// ---- 任务模型 ----
struct P2pTask {
    1: string id           (api.body = "id")
    2: string kind         (api.body = "kind")      // send | recv
    3: string state        (api.body = "state")     // waiting|running|done|failed|canceled|expired
    4: string code         (api.body = "code")      // send 任务配对口令（recv 为输入码）
    5: list<string> paths  (api.body = "paths")     // send=发送源路径 recv=收件相对路径
    6: i64    bytes_done   (api.body = "bytes_done")
    7: string error        (api.body = "error")
    8: string created_at   (api.body = "created_at")
    9: string finished_at  (api.body = "finished_at")
}

// ---- 状态 ----
struct AdminP2pStatusData {
    1: bool   available     (api.body = "available")     // p2pc 二进制探测到
    2: string binary_path   (api.body = "binary_path")
    3: bool   enabled       (api.body = "enabled")       // 配置开关（p2p.direct.enabled）
    4: string registry_url  (api.body = "registry_url")  // 生效注册中心（含缺省回填）
    5: string recv_dir      (api.body = "recv_dir")
    6: i64    inbox_used    (api.body = "inbox_used")
    7: i64    inbox_quota   (api.body = "inbox_quota")
    8: bool   deploy_allowed(api.body = "deploy_allowed") // standalone 才允许
}
struct AdminP2pStatusReq {}
struct AdminP2pStatusResp {
    1: required i32  code    (api.body = "code")
    2: required string message (api.body = "message")
    3: AdminP2pStatusData data (api.body = "data")
}

// ---- 任务列表 ----
struct AdminP2pTasksReq {}
struct AdminP2pTasksResp {
    1: required i32 code (api.body = "code")
    2: required string message (api.body = "message")
    3: AdminP2pTasksData data (api.body = "data")
}
struct AdminP2pTasksData {
    1: list<P2pTask> tasks (api.body = "tasks")
}

// ---- 发起发送 ----
struct AdminP2pSendReq {
    1: list<string> paths (api.body = "paths") // 服务器本地路径,须命中 send_roots 白名单
}
struct AdminP2pSendResp {
    1: required i32 code (api.body = "code")
    2: required string message (api.body = "message")
    3: AdminP2pTaskData data (api.body = "data")
}
struct AdminP2pTaskData {
    1: P2pTask task (api.body = "task")
}

// ---- 发起接收 ----
struct AdminP2pRecvReq {
    1: string code (api.body = "code") // 12 位连字符口令,大小写不敏感
}
struct AdminP2pRecvResp {
    1: required i32 code (api.body = "code")
    2: required string message (api.body = "message")
    3: AdminP2pTaskData data (api.body = "data")
}

// ---- 取消 ----
struct AdminP2pCancelReq {
    1: string task_id (api.body = "task_id")
}
struct AdminP2pCancelResp {
    1: required i32 code (api.body = "code")
    2: required string message (api.body = "message")
}

// ---- 收件发布为分享（复用 share.ImportLocalFile 铸链,配额/审核同权） ----
struct AdminP2pPublishReq {
    1: string task_id     (api.body = "task_id")
    2: i64    expire_value (api.body = "expire_value")
    3: string expire_style (api.body = "expire_style") // day|hour|minute|count|forever
    4: bool   require_auth (api.body = "require_auth")
    5: string password     (api.body = "password")
    6: string custom_code  (api.body = "custom_code")
}
struct AdminP2pPublishResp {
    1: required i32 code (api.body = "code")
    2: required string message (api.body = "message")
    3: AdminP2pPublishData data (api.body = "data")
}
struct AdminP2pPublishData {
    1: list<string> share_codes (api.body = "share_codes") // 每文件一个分享
}

service AdminP2PService {
    AdminP2pStatusResp  AdminP2pStatus (1: AdminP2pStatusReq req)   (api.get  = "/admin/p2p/status")
    AdminP2pTasksResp   AdminP2pTasks  (1: AdminP2pTasksReq req)    (api.get  = "/admin/p2p/tasks")
    AdminP2pSendResp    AdminP2pSend   (1: AdminP2pSendReq req)     (api.post = "/admin/p2p/send")
    AdminP2pRecvResp    AdminP2pRecv   (1: AdminP2pRecvReq req)     (api.post = "/admin/p2p/recv")
    AdminP2pCancelResp  AdminP2pCancel (1: AdminP2pCancelReq req)   (api.post = "/admin/p2p/cancel")
    AdminP2pPublishResp AdminP2pPublish(1: AdminP2pPublishReq req)  (api.post = "/admin/p2p/publish")
}
```

- [ ] **Step 2: 跑生成链,三重 CHECK 必须绿**

```bash
cd PigeonBox/contracts
./scripts/gen-model.sh            # 生成 gen/p2p/
go run ./cmd/gen-openapi          # openapi.json 合入
go run ./cmd/gen-ts               # gen/ts/p2p.d.ts
git diff --stat | tail -3         # 确认只有预期文件
```

- [ ] **Step 3: Commit**

```bash
cd PigeonBox/contracts && git add idl/p2p.thrift gen/p2p/ openapi/openapi.json gen/ts/
git commit -m "feat(idl): AdminP2PService 六端点(设备直传管理面,spec §7)"
```

---

### Task 2: core 配置 — p2p.direct 子段

**Files:**
- Modify: `core/app/config/config.go`(P2PSection 加 Direct + 校验)
- Modify: `core/app/config/service.go`(子段 nil 保留下沉到 Direct)
- Test: `core/app/config/p2p_test.go`(追加)

**Interfaces:**
- Produces: `config.DirectTransferConfig` 结构(Task 3 supervisor 消费);`P2PSection.Direct *DirectTransferConfig`。

- [ ] **Step 1: 写失败测试**(追加 `p2p_test.go`)

```go
// TestUpdateConfigP2PDirectSubsection p2p.direct 子段:保存直传参数不冲掉
// federation(子段 nil 保留);校验拒绝坏值(负配额/根目录白名单)。
func TestUpdateConfigP2PDirectSubsection(t *testing.T) {
	svc := newTestConfigService(t)
	ctx := context.Background()
	withGlobalConf(t)

	// 先存联邦
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Federation: &conf.FederationConfig{Enabled: true, RegistryURL: "http://p2p:12346"}},
	}))
	// 再存直传(不带 federation)→ 联邦保留
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Direct: &DirectTransferConfig{Enabled: true, SendRoots: []string{"/data/in"}, RecvDir: "/data/inbox"}},
	}))
	got, _ := svc.GetConfig(ctx)
	require.True(t, got.P2P.Federation.Enabled, "直传保存不得冲掉 federation 子段")
	require.True(t, got.P2P.Direct.Enabled)
	require.Equal(t, []string{"/data/in"}, got.P2P.Direct.SendRoots)

	// 反向:存联邦不冲直传
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Federation: &conf.FederationConfig{Enabled: false}},
	}))
	got, _ = svc.GetConfig(ctx)
	require.True(t, got.P2P.Direct.Enabled, "联邦保存不得冲掉 direct 子段")

	// 校验:send_roots 必须绝对路径且禁 "/"
	require.Error(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Direct: &DirectTransferConfig{SendRoots: []string{"relative/path"}}},
	}))
	require.Error(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Direct: &DirectTransferConfig{SendRoots: []string{"/"}}},
	}))
	// 校验:配额非负
	require.Error(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Direct: &DirectTransferConfig{MaxTaskBytes: -1}},
	}))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd PigeonBox/core && go test ./app/config/ -run TestUpdateConfigP2PDirectSubsection`
Expected: FAIL(`DirectTransferConfig undefined`)

- [ ] **Step 3: 实现**

`core/app/config/config.go` P2PSection 扩展:

```go
// P2PSection P2P 能力配置段(spec 2026-10-14 §5)。
type P2PSection struct {
	// Federation 联邦控制面(overlay → conf.Federation;nil = 保留现状)
	Federation *conf.FederationConfig `json:"federation,omitempty"`
	// Direct 设备直传数据面(p2pc;nil = 保留现状)
	Direct *DirectTransferConfig `json:"direct,omitempty"`
}

// DirectTransferConfig 设备直传参数(supervisor 域消费;admin-only)。
type DirectTransferConfig struct {
	// Enabled 直传能力总开关(缺省 false)
	Enabled bool `json:"enabled"`
	// RegistryURL p2pd 基址,留空 = 官方公共注册中心(与 federation 缺省同源)
	RegistryURL string `json:"registry_url"`
	// RelayAddr 显式中继,留空 = 经 /health 自发现
	RelayAddr string `json:"relay_addr"`
	// SendRoots 发送路径白名单(绝对路径,空=拒绝所有发送;仿 local_import 校验)
	SendRoots []string `json:"send_roots"`
	// RecvDir 收件暂存目录,留空 = <data>/p2p-inbox
	RecvDir string `json:"recv_dir"`
	// MaxTaskBytes 单任务字节上限(0 = 缺省 50 GiB)
	MaxTaskBytes int64 `json:"max_task_bytes"`
	// InboxQuotaBytes 收件区总配额(0 = 缺省 200 GiB)
	InboxQuotaBytes int64 `json:"inbox_quota_bytes"`
	// BinaryPath p2pc 路径,留空 = 查找序(PB_P2PC_PATH env > 候选路径)
	BinaryPath string `json:"binary_path"`
}
```

`validateSystemConfig` 的 p2p 校验块内补 direct:

```go
	if cfg.P2P != nil && cfg.P2P.Direct != nil {
		d := cfg.P2P.Direct
		for _, root := range d.SendRoots {
			root = strings.TrimSpace(root)
			if root == "" {
				continue
			}
			if !filepath.IsAbs(root) {
				return fmt.Errorf("p2p.direct.send_roots 需为绝对路径: %s", root)
			}
			if filepath.Clean(root) == "/" {
				return errors.New("p2p.direct.send_roots 禁止配置根目录 /")
			}
		}
		if d.RecvDir != "" && !filepath.IsAbs(d.RecvDir) {
			return fmt.Errorf("p2p.direct.recv_dir 需为绝对路径: %s", d.RecvDir)
		}
		if d.MaxTaskBytes < 0 || d.InboxQuotaBytes < 0 {
			return errors.New("p2p.direct 配额参数必须 >= 0")
		}
		if u := strings.TrimSpace(d.RegistryURL); u != "" {
			if err := security.ValidateEndpointURL(u); err != nil {
				return fmt.Errorf("p2p.direct.registry_url 校验失败: %w", err)
			}
		}
	}
```

`service.go` UpdateConfig 子段保留(P2P 保留块改写):

```go
	if newConfig.P2P == nil && s.config != nil {
		newConfig.P2P = s.config.P2P
	} else if newConfig.P2P != nil && s.config != nil && s.config.P2P != nil {
		// 子段 nil 保留下沉一层(联邦/直传同挂 p2p 下,互不冲)
		if newConfig.P2P.Federation == nil {
			newConfig.P2P.Federation = s.config.P2P.Federation
		}
		if newConfig.P2P.Direct == nil {
			newConfig.P2P.Direct = s.config.P2P.Direct
		}
	}
```

- [ ] **Step 4: 测试通过 + 回归**

Run: `cd PigeonBox/core && go test ./app/config/ -v -run "TestUpdateConfigP2P|TestOverlay" && go test ./app/config/`
Expected: 全 PASS(含既有 7 个 p2p 用例不回归)

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add app/config/
git commit -m "feat(config): p2p.direct 子段(直传参数+校验+子段nil保留)"
```

---

### Task 3: core supervisor 域(app/p2px)

**Files:**
- Create: `core/app/p2px/p2px.go`(Service/任务模型/配置读取)
- Create: `core/app/p2px/spawn.go`(spawn/取消/输出解析/配额监控/孤儿清扫)
- Test: `core/app/p2px/p2px_test.go`

**Interfaces:**
- Consumes: Task 2 的 `config.P2PSection`/`DirectTransferConfig`;config 域 `Default().GetConfig(ctx)`。
- Produces(Task 4 handler 消费):

```go
type Service struct{ /* 见下 */ }
func NewService(deps Deps) *Service
type Deps struct {
	Standalone  func() bool                                   // 部署形态(构造注入,棘轮规则8)
	DataDir     string                                        // 默认收件区/清扫工作区基准
	Now         func() time.Time                              // 测试可注入
}
type Task struct {
	ID, Kind, State, Code string
	Paths []string
	BytesDone int64
	Error string
	CreatedAt, FinishedAt time.Time
}
func (s *Service) Status(ctx context.Context) (Status, error)   // Status{Available,BinaryPath,Enabled,RegistryURL,RecvDir,InboxUsed,InboxQuota,DeployAllowed}
func (s *Service) Send(ctx context.Context, paths []string) (*Task, error)
func (s *Service) Recv(ctx context.Context, code string) (*Task, error)
func (s *Service) Cancel(ctx context.Context, taskID string) error
func (s *Service) List(ctx context.Context) []*Task
func (s *Service) PublishPaths(ctx context.Context, taskID string) ([]string, error) // 收件任务的可发布绝对路径(白名单校验后)
func (s *Service) Stop() error // Cleanup 调用:杀全部子进程
```

- [ ] **Step 1: 写失败测试** `core/app/p2px/p2px_test.go`(用 shell stub 假 p2pc)

stub 二进制 = 临时 shell 脚本:`send` 打出口令行后 sleep,`recv` 写文件到 --out 目录后退出 0。

```go
// 测试骨架(完整断言):
// 1. LocateBinary 查找序(config.BinaryPath > PB_P2PC_PATH > 候选)
// 2. Send 任务:stub 打 "口令: ABCD-1234-WXYZ" → Task.Code 被解析、state=waiting
// 3. Cancel:进程组被杀、state=canceled
// 4. Recv 配额:stub 写超 max_task_bytes 文件 → 任务被 ticker 杀、state=failed(配额)
// 5. 非 standalone → Send/Recv 直接返回错误
// 6. Stop() 幂等,杀光子进程
```

- [ ] **Step 2: 跑测试确认失败** — `undefined: p2px` 包不存在。

- [ ] **Step 3: 实现** `core/app/p2px/p2px.go` 与 `spawn.go`(完整骨架):

```go
// Package p2px P2P 设备直传 supervisor(2026-10-14 对称节点 spec §7)。
// 数据面走子进程:每任务 spawn p2pc(Setpgid 进程组,kill 即取消);
// 控制面进程内:任务编排/输出解析/配额监控/孤儿清扫。standalone 专属。
package p2px

// 关键实现点:
// - LocateBinary:cfg.BinaryPath > env PB_P2PC_PATH > [exeDir/p2pc, ./p2pc, /usr/bin/p2pc]
// - spawn:exec.CommandContext(兜底)+ syscall.SysProcAttr{Setpgid:true};取消=kill(-pgid)
// - stdout 扫描:`口令:` 行 → Task.Code;其余 stdout/stderr 行进 256 行环形日志
// - 配额:recv 任务落盘目录 5s ticker 超 MaxTaskBytes → kill;收件区总量超 InboxQuotaBytes → kill
// - 孤儿清扫:启动时读 <data>/p2p-tasks/*.pid,kill 遗留进程组并删除 pid 文件
// - 收件落 <recv_dir>/<taskID>/,发布时经 PublishPaths 做三层防穿越(abs/.. /EvalSymlinks)
// - p2pc 无 ctx 取消(协议层),进程组 kill 是唯一取消面——与 desktop sidecar 语义一致
```

- [ ] **Step 4: 测试通过**

Run: `cd PigeonBox/core && go test ./app/p2px/ -v -race`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add app/p2px/
git commit -m "feat(p2px): 直传 supervisor 域(spawn/取消/配额/孤儿清扫/standalone门)"
```

---

### Task 4: core handler + 路由接线

**Files:**
- Create: `core/gen/handler/p2p/p2p_service.go`(hz 生成桩→填实现)
- Regenerate: `core/gen/router/p2p/`
- Modify: `core/bootstrap/wiring.go`(装配 p2px + SetService 注入)、`core/bootstrap/bootstrap.go` Cleanup(fedRT.stop() 旁加 p2pxSvc.Stop())
- Modify: `core/bootstrap/routes_guard_test.go`(六端点断言)

**Interfaces:**
- Consumes: Task 3 `p2px.Service` 全接口;`share.ImportLocalFile` 发布链。
- Produces: `/admin/p2p/*` 六端点(AdminMiddleware),Publish 走 `shareSvc.ImportLocalFile(ctx, ImportLocalOpts{AbsPath, ...})`——与本地导入同链路(配额/审核/审计同权)。

- [ ] **Step 1: gen-router**

```bash
cd PigeonBox/core && ./scripts/gen-router.sh
# hz 为新 service 生成 gen/router/p2p/ + gen/handler/p2p/p2p_service.go 桩
go build ./... 2>&1 | head -5   # 桩应可编译(若 redeclared 噪音:git checkout -- gen/handler/p2p/ 后手写单文件)
```

- [ ] **Step 2: 实现 handler** `gen/handler/p2p/p2p_service.go`

模式照抄 `gen/handler/admin/localfiles_ops.go`(包级 `var p2pxSvc *p2px.Service` + `SetService` 注入 + `getP2pxService()` fail-fast;错误走 gen 模型 Resp{Code:400,...})。六 handler:

- `AdminP2pStatus` → `svc.Status(ctx)`
- `AdminP2pTasks` → `svc.List(ctx)`
- `AdminP2pSend` → 校验 paths 非空 → `svc.Send(ctx, req.Paths)`
- `AdminP2pRecv` → code 去连字符大写化 → `svc.Recv(ctx, code)`
- `AdminP2pCancel` → `svc.Cancel(ctx, req.TaskID)`
- `AdminP2pPublish` → `svc.PublishPaths` 得绝对路径(已白名单校验)→ 对每个文件调 `getOpsShareService().ImportLocalFile(ctx, ImportLocalOpts{...})`(复用 localfiles_ops 的 expireStyle/password 处理代码,抽共享小函数防复制) → 返回 share_codes 列表

wiring 装配顺序(在 federation 块后):`p2pxSvcInstance = p2px.NewService(...)` + `p2pGenHandler.SetService(p2pxSvcInstance)`;Cleanup:`p2pxSvcInstance.Stop()` 在 `fedRT.stop()` 旁。

- [ ] **Step 3: 路由守卫断言** `routes_guard_test.go` 补六条 `/admin/p2p/*`。

- [ ] **Step 4: 测试**

Run: `cd PigeonBox/core && go test ./bootstrap/ -run "Route|Guard" -v && go test ./... 2>&1 | grep -vE "^ok|no test" | head -5`
Expected: 守卫绿 + 无 FAIL

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add gen/router/p2p gen/handler/p2p bootstrap/ ../contracts/idl/
git commit -m "feat(p2p): /admin/p2p/* 六端点接线(supervisor+发布复用本地导入铸链)"
```

---

### Task 5: 前端 — 操作页 + 配置分区补直传子段

**Files:**
- Create: `frontend-core/src/api/p2p.ts`、`frontend-core/src/views/admin/P2pTransfer.vue`
- Modify: `frontend-core/src/router/index.ts`(admin 子路由)、`views/admin/index.vue`(侧栏项+面包屑)、`views/admin/Config.vue`(p2p 分区加直传子段)、`i18n/locales/zh-CN.ts`+`en-US.ts`
- Test: typecheck + build + vitest

**Interfaces:**
- Consumes: `adminApi` 同款 request 封装;后端六端点。
- Produces: `#/admin/p2p` 页面(深链 `?tab=send|recv`)。

- [ ] **Step 1: api/p2p.ts**

```ts
import { request } from '@/utils/request'
// 类型与 contracts gen/ts/p2p.d.ts 对齐;code 判定复用 res.code===0||200
export const p2pApi = {
  status: () => request.get('/admin/p2p/status'),
  tasks: () => request.get('/admin/p2p/tasks'),
  send: (paths: string[]) => request.post('/admin/p2p/send', { paths }),
  recv: (code: string) => request.post('/admin/p2p/recv', { code }),
  cancel: (taskId: string) => request.post('/admin/p2p/cancel', { task_id: taskId }),
  publish: (taskId: string, opts: {...}) => request.post('/admin/p2p/publish', { task_id: taskId, ...opts }),
}
```

- [ ] **Step 2: P2pTransfer.vue**(整页):

```
引导态优先级:binary 不可用 > 直传未启用(链到配置页 ?section=p2p) > 正常
- 状态横幅:registry/收件区配额用量/standalone
- 发送卡:路径 textarea(每行一个,须命中白名单)+ 发起按钮 → 任务行显示口令(大号等宽+复制按钮+10分钟窗口提示)
- 接收卡:口令输入(自动格式化连字符)+ 接收按钮
- 任务表:kind/state/口令/字节/progress 日志展开/取消按钮/done 收件任务显示「发布为分享」
- 轮询:有活跃任务时 2s 轮询 tasks
```

- [ ] **Step 3: Config.vue p2p 分区加「设备直传」子段**(federation 分隔线后):

```html
<el-divider content-position="left">{{ t('admin.configPage.sections.directTransfer') }}</el-divider>
<el-form-item :label="t('admin.configPage.p2p.dtEnabled')"><el-switch v-model="exForm.p2p.direct.enabled" /><span class="field-hint">...</span></el-form-item>
<el-form-item :label="t('admin.configPage.p2p.sendRoots')"><el-input v-model="p2pSendRootsText" type="textarea" :rows="3" /></el-form-item>
<el-form-item :label="t('admin.configPage.p2p.recvDir')"><el-input v-model="exForm.p2p.direct.recv_dir" style="width:360px" /></el-form-item>
<el-form-item :label="t('admin.configPage.p2p.maxTaskMB')"><el-input-number v-model="maxTaskMB" :min="0" /></el-form-item>
```
exForm.p2p 加 `direct: { enabled: false, registry_url: '', relay_addr: '', send_roots: [], recv_dir: '', max_task_bytes: 0, inbox_quota_bytes: 0, binary_path: '' }`;fetchExSections 归一;saveCurrent 'p2p' case 的 payload 加 `direct: { ...exForm.p2p.direct }`;save 成功后 hint 引导到操作页。

- [ ] **Step 4: 验证**

```bash
cd PigeonBox/frontend-core && npm run typecheck && npm run build && npm test
```

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/frontend-core && git add src/
git commit -m "feat(admin): 设备直传操作页+P2P分区直传子段"
```

---

### Task 6: server 镜像随包 p2pc

**Files:**
- Modify: `PigeonBox/server/Dockerfile`
- Modify: `PigeonBox/server/.github/workflows/release.yml`(下载 p2pc 资产+校验)
- Create: `PigeonBox/server/.p2pc-version`(P2b 由 trainctl 接管钉版;本期手工)

**Interfaces:**
- Consumes: p2p Releases 的 `p2pc-x86_64-unknown-linux-gnu` / `p2pc-aarch64-unknown-linux-gnu` + `p2pc-checksums.txt`。

- [ ] **Step 1: Dockerfile**(Stage2,TARGETARCH 映射,缺省不阻塞本地构建):

```dockerfile
# ---- p2pc 设备直传随包(2026-10-14 对称节点 P2a;缺省时功能优雅降级) ----
ARG TARGETARCH
ARG P2PC_URL=""
RUN if [ -n "$P2PC_URL" ]; then \
      wget -q -O /app/p2pc "$P2PC_URL" && chmod +x /app/p2pc; \
    fi
```
镜像内 p2pc 落 `/app/p2pc`(supervisor 候选序命中);release CI 传 `P2PC_URL=https://github.com/pigeonbox/p2p/releases/download/v<lib.p2p>/p2pc-<triple>` 并按 checksums.txt 校验后构建。

- [ ] **Step 2: release.yml** 在镜像构建步骤前加:读 `.p2pc-version` → 拼 URL → `gh release download`/curl 拉 checksums → `docker buildx build --build-arg P2PC_URL=...`(双架构 matrix 按 TARGETARCH 映射)。

- [ ] **Step 3: 本地构建验证**

```bash
cd PigeonBox/server && docker build --build-arg P2PC_URL=file:///tmp/p2pc-sizetest ...  # 或先无参构建确认回归
```

- [ ] **Step 4: Commit + push**

---

### Task 7: 全量 E2E(真 p2pc + 本地 p2pd 双任务互传)

```bash
# 起本地 p2pd(12346)+ server(12345,PB_SSRF_ALLOW_PRIVATE=true)
# admin 配置:p2p.direct{enabled:true, registry_url:http://127.0.0.1:12346, send_roots:[/tmp/p2p-e2e], recv_dir:/tmp/p2p-e2e/inbox}
# POST /admin/p2p/send {paths:["/tmp/p2p-e2e/hello.txt"]} → 轮询 tasks 得口令
# POST /admin/p2p/recv {code} → 等 done → inbox 下有文件,sha256 一致
# POST /admin/p2p/publish {task_id, expire_style:day, expire_value:7} → 得取件码 → 匿名 GET /share/<code> 可下
# Cancel 路径:大文件 send 不配对 → cancel → state=canceled 进程退出
```

### Task 8: hub 勘误与文档

- `AGENTS.md` 端口区:「12347 未转=公网直传缺口」→ 更正为「56788 信令/56787 中继(公网已通,经 /health 自发现;12347 仅本地兼容映射)」。
- spec §16 分期表 P2a 标记完成。

## 验收清单

- [ ] `go test ./...`(core)全绿含 routes_guard;-race 干净
- [ ] contracts 三重 CHECK 零 diff
- [ ] 前端 typecheck/build/117 单测绿 + 操作页手动走查(发送→口令→接收→发布→取件)
- [ ] 本地双任务互传 sha256 一致;cancel 立即生效
- [ ] 镜像带 p2pc 启动,admin status 报 available:true;不带则引导态不崩
- [ ] 多副本模式下任务创建响亮拒绝
