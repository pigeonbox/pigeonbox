# P1 — 联邦进 admin 后台(federation 运行时热启停)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans(本会话内联执行) task-by-task。Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 federation 开关/配置从纯 yaml/env 收进 SystemConfig `p2p` 指针段,admin 配置页新增「P2P 与联邦」分区,保存即运行时热启停。

**Architecture:** 控制面留进程内(现有 federation 域不动),装配收口成可重入 `federationRuntime`(先立后破);配置走 SystemConfig 自由 JSON 段(零 IDL 改动),overlay 到全局 conf,DB wins、env/yaml 只作首启种子;非 standalone 由运行时硬拒。

**Tech Stack:** Go 1.26 / Hertz / GORM / vue3+Element Plus / vitest。

**Spec:** `PigeonBox/docs/specs/2026-10-14-p2p-peer-integration-design.md`(§5 配置模型、§6 P1、§11 约束、§13 测试)

## Global Constraints

- 生成物勿手改:`core/gen/`、`contracts/gen/`;IDL 注释可改(空 struct 注释不进生成物)。
- env 前缀一律 `PB_`;本任务不新增 env(沿用 `PB_FEDERATION_*` 作首启种子)。
- 新配置段必须是**指针段**(nil=保留现状);勿包 `{config:...}` 壳。
- `SetFederationNotifier(nil)` 必须传**非类型化 nil**(typed-nil 进接口非 nil,调用点判空失效——历史坑)。
- federation 热切换与装配是 standalone 专属;`conf.IsStandalone()` 为真相源。
- Go 测试:`glebarez/sqlite :memory:` 必须 `SetMaxOpenConns(1)`(见 `newTestConfigService`)。
- 前端 i18n:zh-CN.ts 与 en-US.ts **同构同行号**维护。
- 提交规范:每 Task 一 commit(core/frontend-core/contracts 分仓提交;hub 收计划文档)。

---

### Task 1: core 配置模型(P2PSection + json 标签 + 校验)

**Files:**
- Modify: `core/conf/config.go:96-111`(FederationConfig 加 json 标签)
- Modify: `core/app/config/config.go`(SystemConfig 加 P2P 段 + P2PSection 类型 + validateSystemConfig 规则)
- Test: `core/app/config/p2p_test.go`(新建)

**Interfaces:**
- Produces: `config.P2PSection{Federation *conf.FederationConfig \`json:"federation,omitempty"\`}`;`SystemConfig.P2P *P2PSection \`json:"p2p,omitempty"\``;conf.FederationConfig 获得 snake_case json 标签。Task 2 的 overlay/nil-保留/回填都消费这些。

- [ ] **Step 1: 写失败测试** `core/app/config/p2p_test.go`

```go
package config

import (
	"testing"

	"github.com/pigeonbox/core/conf"
)

// TestValidateSystemConfigP2PFederation p2p.federation 段校验:URL 仅 http/https、
// registry 支持逗号多主备、熵门槛范围。写库前最后一道防线(同 notify/oidc 先例)。
func TestValidateSystemConfigP2PFederation(t *testing.T) {
	ok := func() *SystemConfig {
		return &SystemConfig{P2P: &P2PSection{Federation: &conf.FederationConfig{
			Enabled:  true,
			RegistryURL: "http://p2p1:12346,https://p2p2:56788",
			PublicURL:   "https://share.example.com",
		}}}
	}
	if err := validateSystemConfig(ok()); err != nil {
		t.Fatalf("合法配置被拒: %v", err)
	}
	badScheme := ok()
	badScheme.P2P.Federation.RegistryURL = "ftp://p2p:12346"
	if err := validateSystemConfig(badScheme); err == nil {
		t.Fatal("ftp scheme 应被拒")
	}
	badPub := ok()
	badPub.P2P.Federation.PublicURL = "javascript:alert(1)"
	if err := validateSystemConfig(badPub); err == nil {
		t.Fatal("非法 public_url 应被拒")
	}
	badEntropy := ok()
	badEntropy.P2P.Federation.AnnounceMinEntropyBits = -1
	if err := validateSystemConfig(badEntropy); err == nil {
		t.Fatal("负熵门槛应被拒")
	}
	if err := validateSystemConfig(&SystemConfig{P2P: &P2PSection{}}); err != nil {
		t.Fatalf("P2P 段无 federation(nil)应合法: %v", err)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd PigeonBox/core && go test ./app/config/ -run TestValidateSystemConfigP2PFederation -v`
Expected: FAIL(`P2P undefined` / `P2PSection undefined`)

- [ ] **Step 3: 最小实现**

`core/conf/config.go` FederationConfig 五个字段各追加 json 标签(与 mapstructure 同值):
`json:"enabled"`、`json:"registry_url"`、`json:"public_url"`、`json:"node_key_path"`、`json:"announce_min_entropy_bits"`。

`core/app/config/config.go` SystemConfig 在 `APIToken` 字段后加:

```go
	// P2P P2P 能力段(2026-10-14 对称节点 spec §5):Federation 控制面在线开关;
	// 直传数据面参数(enabled/send_roots/…)随 P2a 落地。nil = 未在线设置。
	P2P *P2PSection `json:"p2p,omitempty"`
```

文件尾部加类型与校验:

```go
// P2PSection P2P 能力配置段(spec 2026-10-14 §5)。
type P2PSection struct {
	// Federation 联邦控制面(overlay → conf.Federation;nil = 保留现状)
	Federation *conf.FederationConfig `json:"federation,omitempty"`
}
```

`validateSystemConfig` 在 local_import 循环之后、`return nil` 之前加:

```go
	if cfg.P2P != nil && cfg.P2P.Federation != nil {
		f := cfg.P2P.Federation
		if u := strings.TrimSpace(f.RegistryURL); u != "" {
			for _, one := range strings.Split(u, ",") {
				one = strings.TrimSpace(one)
				if one == "" {
					continue
				}
				if err := security.ValidateEndpointURL(one); err != nil {
					return fmt.Errorf("p2p.federation.registry_url 校验失败: %w", err)
				}
			}
		}
		if u := strings.TrimSpace(f.PublicURL); u != "" {
			if err := security.ValidateEndpointURL(u); err != nil {
				return fmt.Errorf("p2p.federation.public_url 校验失败: %w", err)
			}
		}
		if f.AnnounceMinEntropyBits < 0 || f.AnnounceMinEntropyBits > 256 {
			return errors.New("p2p.federation.announce_min_entropy_bits out of range (0-256)")
		}
	}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd PigeonBox/core && go test ./app/config/ -run TestValidateSystemConfigP2PFederation -v`
Expected: PASS。再跑全包防连坐:`go test ./app/config/ ./conf/`

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add conf/config.go app/config/config.go app/config/p2p_test.go
git commit -m "feat(config): SystemConfig 新增 p2p 段(P2PSection)+ federation json 标签与写库校验"
```

---

### Task 2: config 域持久化语义(nil 保留 + overlay + 热切换钩子 + 回填)

**Files:**
- Modify: `core/app/config/service.go`(ReconfigureHooks 加字段;UpdateConfig nil-保留与钩子触发;applySystemConfigOverlayLocked 加分支;ensureConfigLoaded 加回填)
- Test: `core/app/config/p2p_test.go`(追加)

**Interfaces:**
- Consumes: Task 1 的 `P2PSection`。
- Produces: `ReconfigureHooks.OnP2PFederationChanged func(f *conf.FederationConfig)`(Task 3 的 wiring 注册它);overlay 把 `sc.P2P.Federation` 写进 `conf.GetGlobalConfig().Federation`。

- [ ] **Step 1: 写失败测试**(追加到 `p2p_test.go`)

```go
// TestUpdateConfigP2PPartialPreserveAndOverlay 局部保存不清零 p2p 段;
// overlay 把 federation 写进全局 conf;未提交 p2p 的保存保留现状。
func TestUpdateConfigP2PPartialPreserveAndOverlay(t *testing.T) {
	svc := newTestConfigService(t)
	ctx := context.Background()
	g := conf.GetGlobalConfig()
	if g == nil {
		g = &conf.AppConfiguration{}
		conf.SetGlobalConfig(g)
		t.Cleanup(func() { conf.SetGlobalConfig(&conf.AppConfiguration{}) })
	}
	fedBefore := g.Federation

	// 1) 提交 p2p.federation → 全局 conf 即刻热生效
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Federation: &conf.FederationConfig{Enabled: true, RegistryURL: "http://p2p:12346"}},
	}))
	require.True(t, g.Federation.Enabled)
	require.Equal(t, "http://p2p:12346", g.Federation.RegistryURL)

	// 2) 局部保存(只带 oidc)→ p2p 段保留,不回弹
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{OIDC: &conf.OIDCConfig{}}))
	got, err := svc.GetConfig(ctx)
	require.NoError(t, err)
	require.NotNil(t, got.P2P)
	require.True(t, got.P2P.Federation.Enabled)
	require.True(t, g.Federation.Enabled)

	// 3) 显式改回关闭 → overlay 跟随
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Federation: &conf.FederationConfig{Enabled: false}},
	}))
	require.False(t, g.Federation.Enabled)
	_ = fedBefore
}

// TestUpdateConfigP2PFederationHook 热切换钩子只在 p2p.federation 非 nil 时触发。
func TestUpdateConfigP2PFederationHook(t *testing.T) {
	svc := newTestConfigService(t)
	ctx := context.Background()
	var got *conf.FederationConfig
	svc.SetReconfigureHooks(&ReconfigureHooks{
		OnP2PFederationChanged: func(f *conf.FederationConfig) { got = f },
	})
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{OIDC: &conf.OIDCConfig{}}))
	require.Nil(t, got, "未提交 p2p 段不应触发")
	require.NoError(t, svc.UpdateConfig(ctx, &SystemConfig{
		P2P: &P2PSection{Federation: &conf.FederationConfig{Enabled: true}},
	}))
	require.NotNil(t, got)
	require.True(t, got.Enabled)
}
```

注意:若 `conf` 包没有 `SetGlobalConfig`,改用 `conf.InitConfig`/现有测试注入法——先 `grep -n "func SetGlobalConfig\|GlobalConfig =" PigeonBox/core/conf/*.go` 确认;若全局 conf 在测试里本就非 nil(bootstrap 未跑则为 nil),直接用返回值。overlay 对 `g == nil` 直接 return(service.go 现有行为),测试必须先保证 g 非 nil。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd PigeonBox/core && go test ./app/config/ -run "TestUpdateConfigP2P" -v`
Expected: FAIL(`got.P2P` nil / overlay 未生效 / hook 未触发)

- [ ] **Step 3: 实现**(全部在 `core/app/config/service.go`)

a) `ReconfigureHooks` 结构加字段(注释随风格):

```go
	// OnP2PFederationChanged federation 运行时热切换(bootstrap 注册;P1 对称节点 spec §6)
	OnP2PFederationChanged func(f *conf.FederationConfig)
```

b) `UpdateConfig` 的 APIToken nil-保留块之后加:

```go
	if newConfig.P2P == nil && s.config != nil {
		newConfig.P2P = s.config.P2P
	}
```

c) `UpdateConfig` 中 `notifyCfg, oidcCfg := ...` 行改为三元捕获(锁内):

```go
	notifyCfg, oidcCfg := newConfig.Notify, newConfig.OIDC
	var p2pFedCfg *conf.FederationConfig
	if newConfig.P2P != nil {
		p2pFedCfg = newConfig.P2P.Federation
	}
	s.configMu.Unlock()
```

钩子触发热 `if hooks != nil {` 块尾追加:

```go
		if p2pFedCfg != nil && hooks.OnP2PFederationChanged != nil {
			hooks.OnP2PFederationChanged(p2pFedCfg)
		}
```

d) `applySystemConfigOverlayLocked` 的 `sc.APIToken` 分支后加:

```go
	if sc.P2P != nil && sc.P2P.Federation != nil {
		g.Federation = *sc.P2P.Federation
	}
```

e) `ensureConfigLoaded` 的 UploadEx 回填块(:207-212)之后加(同理:管理后台看到真实生效值,整段保存不把 env 种子冲成零值):

```go
	// P2P 段从未在线保存过时回填全局 conf 生效值(与 UploadEx 同理)
	if s.config.P2P == nil {
		if g := conf.GetGlobalConfig(); g != nil {
			fed := g.Federation
			s.config.P2P = &P2PSection{Federation: &fed}
		}
	}
```

- [ ] **Step 4: 跑测试确认通过 + 全包回归**

Run: `cd PigeonBox/core && go test ./app/config/ -v && go test ./app/... ./conf/... | tail -20`
Expected: 全 PASS(既有 TestUpdateConfigPartialPreservesValueSections 不回归)

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add app/config/
git commit -m "feat(config): p2p.federation 段持久化语义(nil保留/overlay热生效/热切换钩子/env种子回填)"
```

---

### Task 3: bootstrap federation 运行时(fedRT 可重入 + Cleanup 收口)

**Files:**
- Create: `core/bootstrap/federation_runtime.go`
- Modify: `core/bootstrap/wiring.go:161-179`(装配块替换)、`:126-144`(钩子注册加一条)、`:266`(实例读取改 fedRT.instance())、`:301-302`(删包级 var)
- Modify: `core/bootstrap/bootstrap.go:371-374`(Cleanup 收口)
- Test: `core/bootstrap/federation_runtime_test.go`(新建)

**Interfaces:**
- Consumes: Task 2 的 `OnP2PFederationChanged`。
- Produces: `fedRT.apply(conf.FederationConfig)`(启动与热切换唯一入口)、`fedRT.instance() *federationApp.Service`、`fedRT.stop()`(Cleanup);删除 `federationSvcInstance` 包级 var。

- [ ] **Step 1: 写失败测试** `core/bootstrap/federation_runtime_test.go`

```go
package bootstrap

import (
	"errors"
	"path/filepath"
	"testing"

	federationApp "github.com/pigeonbox/core/app/federation"
	"github.com/pigeonbox/core/conf"
)

func fedTestCfg(t *testing.T, enabled bool) conf.FederationConfig {
	t.Helper()
	return conf.FederationConfig{
		Enabled:      enabled,
		RegistryURL:  "http://127.0.0.1:1", // 不可达:单元测试不断言网络,只断言装配状态机
		NodeKeyPath:  filepath.Join(t.TempDir(), "node.key"),
	}
}

// TestFederationRuntimeSwitch 状态机:启用→装配+attach;关闭→stop+detach;
// 新配置装配失败→维持原状(回滚语义,不留半态)。
func TestFederationRuntimeSwitch(t *testing.T) {
	r := &federationRuntime{}
	attached, detached := 0, 0
	var lastSvc *federationApp.Service
	r.init("t", federationApp.NewService,
		func(s *federationApp.Service) { attached++; lastSvc = s },
		func() { detached++ },
	)

	r.apply(fedTestCfg(t, true))
	if r.instance() == nil || attached != 1 {
		t.Fatalf("启用后应有实例并 attach: svc=%v attached=%d", r.instance() != nil, attached)
	}
	first := r.instance()

	// 同配置重配:新实例替换旧实例(先立后破),attach 再次触发
	r.apply(fedTestCfg(t, true))
	if r.instance() == nil || r.instance() == first || attached != 2 {
		t.Fatalf("重配应换新实例: same=%v attached=%d", r.instance() == first, attached)
	}

	// 装配失败:维持旧实例(回滚)
	badStart := *r
	badStart.current = r.instance()
	fail := func(cfg conf.FederationConfig, _ string) (*federationApp.Service, error) {
		return nil, errors.New("boom")
	}
	keep := r.instance()
	rWithFail := &federationRuntime{start: fail, current: keep, attach: r.attach, detach: r.detach}
	rWithFail.apply(fedTestCfg(t, true))
	if rWithFail.instance() != keep {
		t.Fatal("装配失败应维持旧实例")
	}

	// 关闭:stop + detach
	r.apply(fedTestCfg(t, false))
	if r.instance() != nil || detached != 1 {
		t.Fatalf("关闭后应清空并 detach: svc=%v detached=%d", r.instance() != nil, detached)
	}
	_ = lastSvc
	r.stop() // 幂等
}
```

注:`fedTestCfg` 的 RegistryURL 不可达会让 `Start()` 的后台循环打错误日志——可接受;`Stop()` 的注销是 best-effort。`federationApp.NewService` 签名 `(cfg conf.FederationConfig, nodeName string) (*Service, error)` 直接当 `fedStartFunc` 用。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd PigeonBox/core && go test ./bootstrap/ -run TestFederationRuntimeSwitch -v`
Expected: FAIL(`undefined: federationRuntime`)

- [ ] **Step 3: 实现** `core/bootstrap/federation_runtime.go` 全文:

```go
package bootstrap

// P1(2026-10-14 对称节点 spec §6):federation 装配收口为可重入运行时——
// 启动种子(env/yaml;RestoreAdminSettings 已 overlay DB 值)与 admin 后台
// 热切换走同一条路径。先立后破:新实例装配成功才停旧;失败维持原状。
// 多副本硬约束运行时化:节点身份是进程级 Ed25519,standalone 专属。

import (
	"sync"

	"go.uber.org/zap"

	federationApp "github.com/pigeonbox/core/app/federation"
	"github.com/pigeonbox/core/conf"
	"github.com/pigeonbox/core/pkg/logger"
)

// fedStartFunc 生产工厂 = federationApp.NewService;测试注入可控工厂。
type fedStartFunc func(cfg conf.FederationConfig, nodeName string) (*federationApp.Service, error)

type federationRuntime struct {
	mu      sync.Mutex
	start   fedStartFunc
	attach  func(*federationApp.Service) // 挂注入点(share/admin/customHandler/MCP)
	detach  func()                        // 摘注入点(全部置非类型化 nil——typed-nil 进接口非 nil 的历史坑)
	current *federationApp.Service
	cfg     conf.FederationConfig
	nodeName string
}

// fedRT 包级单例(initThriftIDLServices 装配;Cleanup 停机)。
var fedRT = &federationRuntime{}

// init 注入工厂与注入点(装配期调用一次)。
func (r *federationRuntime) init(nodeName string, start fedStartFunc,
	attach func(*federationApp.Service), detach func()) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nodeName, r.start, r.attach, r.detach = nodeName, start, attach, detach
}

// apply 按新配置切换 federation(启动路径与热路径共用;串行化)。
func (r *federationRuntime) apply(cfg conf.FederationConfig) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cfg = cfg
	if !cfg.Enabled {
		r.stopLocked()
		return
	}
	if g := conf.GetGlobalConfig(); g != nil && !g.IsStandalone() {
		logger.Warn("federation 启用被拒:多副本部署语义未定义(standalone 专属)")
		r.stopLocked()
		return
	}
	svc, err := r.start(cfg, r.nodeName)
	if err != nil {
		// 回滚语义:新配置装配失败维持原状,不留半态
		logger.Error("federation 新配置装配失败,维持原配置", zap.Error(err))
		return
	}
	if r.current != nil {
		r.current.Stop()
		if r.detach != nil {
			r.detach()
		}
	}
	r.current = svc
	svc.Start()
	if r.attach != nil {
		attach := r.attach
		attach(svc)
	}
	logger.Info("federation enabled",
		zap.String("registry", cfg.RegistryURL),
		zap.String("public_url", cfg.PublicURL),
		zap.String("node_id", svc.NodeID()))
}

// stopLocked 停并摘注入点(调用方持锁)。
func (r *federationRuntime) stopLocked() {
	if r.current != nil {
		r.current.Stop()
		r.current = nil
	}
	if r.detach != nil {
		r.detach()
	}
}

// stop 停机(Cleanup 调用;幂等)。
func (r *federationRuntime) stop() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.stopLocked()
}

// instance 当前联邦实例(nil=未启用)。
func (r *federationRuntime) instance() *federationApp.Service {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.current
}
```

`wiring.go` 三处改:

1. `:161-179` 装配块整体替换为:

```go
	// 2.4.2 P2P 联邦(spec 2026-10-14 §6):装配收口 fedRT——启动种子(env/yaml,
	// RestoreAdminSettings 已 overlay DB 值)与 admin 后台热切换同一条路径。
	// 初始化失败降级为非联邦模式;resolve 代理路由恒注册,未启用时返回 available:false。
	fedRT.init(config.App.Name, federationApp.NewService,
		func(svc *federationApp.Service) {
			shareSvc.SetFederationNotifier(svc)
			// admin 删除路径独立于 share 域,须单独挂钩(管理端删除即联邦撤销)
			adminApp.Default().SetFederationNotifier(svc)
			customHandler.SetFederationService(svc)
			// MCP 在后续相位才创建;运行时热切换须重挂(初装配由其相位自取 instance())
			if mcpService != nil {
				mcpService.SetFederationService(mcpFederationAdapter{svc: svc})
			}
		},
		func() {
			// 非类型化 nil:typed-nil 传进接口字段非 nil,调用点判空失效(历史坑)
			shareSvc.SetFederationNotifier(nil)
			adminApp.Default().SetFederationNotifier(nil)
			customHandler.SetFederationService(nil)
			if mcpService != nil {
				mcpService.SetFederationService(mcpFederationAdapter{svc: nil})
			}
		},
	)
	fedRT.apply(config.Federation)
```

(注意闭包捕获的 `shareSvc` 是本函数前文的局部变量——保持在同一函数作用域内。)

2. `:126-144` `SetReconfigureHooks` 块内 `OnOIDCChanged` 之后追加:

```go
			OnP2PFederationChanged: func(f *conf.FederationConfig) {
				if f == nil {
					return
				}
				fedRT.apply(*f)
			},
```

3. `:266` `mcpService.SetFederationService(mcpFederationAdapter{svc: federationSvcInstance})` 改 `svc: fedRT.instance()`;`:301-302` 的 `federationSvcInstance` 包级 var 与其注释删除(改前先 `grep -rn federationSvcInstance --include="*.go" .` 确认仅剩预期点)。

`bootstrap.go:371-374` 替换:

```go
	// 联邦服务先于数据库停:注销节点(best-effort),停心跳循环(P1 走运行时单点)
	fedRT.stop()
```

- [ ] **Step 4: 跑测试 + 全包守卫**

Run: `cd PigeonBox/core && go test ./bootstrap/ -v && go test ./bootstrap/ -race -run TestFederationRuntimeSwitch && go build ./... && go vet ./bootstrap/`
Expected: 全 PASS;`routes_guard_test` 绿(未动路由);无 vet 报错。

- [ ] **Step 5: Commit**

```bash
cd PigeonBox/core && git add bootstrap/
git commit -m "feat(bootstrap): federation 装配收口 fedRT 运行时(先立后破/热切换/standalone 硬约束/Cleanup 收口)"
```

---

### Task 4: 前端「P2P 与联邦」第 7 分区

**Files:**
- Modify: `frontend-core/src/views/admin/Config.vue`(SECTION_IDS/navItems/exForm/fetchExSections/表单块/saveCurrent/图标 import)
- Modify: `frontend-core/src/i18n/locales/zh-CN.ts`、`en-US.ts`(nav/navDesc/sections/p2p 四处)

**Interfaces:**
- Consumes: Task 2 落地的 `PUT /admin/config` body `{p2p:{federation:{…}}}`(自由 JSON,契约零改动)。
- Produces: 配置页 `?section=p2p` 深链可用。

- [ ] **Step 1: Config.vue 六处接线**

a) 图标 import(:327)追加 `Connection`:
`import { Picture, Upload, Download, User, Lock, Message, Connection } from '@element-plus/icons-vue'`

b) `SECTION_IDS`(:338)末尾加 `'p2p'`;`navItems`(:341-348)末尾加:
`{ id: 'p2p', labelKey: 'admin.configPage.nav.p2p', descKey: 'admin.configPage.navDesc.p2p', icon: Connection },`

c) `exForm`(:441-462)加段:

```ts
  p2p: {
    federation: { enabled: false, registry_url: '', public_url: '', node_key_path: '', announce_min_entropy_bits: 40 },
  },
```

d) `fetchExSections`(:479-513)尾部(api_token 行后)加:

```ts
  if (sec.p2p?.federation) {
    Object.assign(exForm.p2p.federation, sec.p2p.federation)
    // 旧库无 p2p 段/缺键 null 归一(后端 nil 回填见 ensureConfigLoaded)
    if (exForm.p2p.federation.enabled == null) exForm.p2p.federation.enabled = false
    if (!exForm.p2p.federation.announce_min_entropy_bits) exForm.p2p.federation.announce_min_entropy_bits = 40
  }
```

e) notify 表单 `</el-form>`(:310)与保存条(:312)之间插表单块:

```html
          <!-- ============ P2P 与联邦(p2p.federation;直传操作页随 P2a) ============ -->
          <el-form v-else-if="activeSection === 'p2p'" label-width="180px" class="config-form">
            <el-divider content-position="left">{{ t('admin.configPage.sections.federation') }}</el-divider>
            <el-form-item :label="t('admin.configPage.p2p.fedEnabled')">
              <el-switch v-model="exForm.p2p.federation.enabled" />
              <span class="field-hint">{{ t('admin.configPage.p2p.fedEnabledHint') }}</span>
            </el-form-item>
            <el-form-item :label="t('admin.configPage.p2p.registryUrl')">
              <el-input
                v-model="exForm.p2p.federation.registry_url"
                :placeholder="t('admin.configPage.p2p.registryUrlPlaceholder')"
                style="width: 360px"
              />
              <span class="field-hint">{{ t('admin.configPage.p2p.registryUrlHint') }}</span>
            </el-form-item>
            <el-form-item :label="t('admin.configPage.p2p.publicUrl')">
              <el-input
                v-model="exForm.p2p.federation.public_url"
                :placeholder="t('admin.configPage.p2p.publicUrlPlaceholder')"
                style="width: 360px"
              />
              <span class="field-hint">{{ t('admin.configPage.p2p.publicUrlHint') }}</span>
            </el-form-item>
            <el-form-item :label="t('admin.configPage.p2p.minEntropy')">
              <el-input-number v-model="exForm.p2p.federation.announce_min_entropy_bits" :min="0" :max="256" />
              <span class="field-hint">{{ t('admin.configPage.p2p.minEntropyHint') }}</span>
            </el-form-item>
            <el-form-item :label="t('admin.configPage.p2p.nodeKeyPath')">
              <el-input
                v-model="exForm.p2p.federation.node_key_path"
                :placeholder="t('admin.configPage.p2p.nodeKeyPathPlaceholder')"
                style="width: 360px"
              />
              <span class="field-hint">{{ t('admin.configPage.p2p.nodeKeyPathHint') }}</span>
            </el-form-item>
          </el-form>
```

f) `saveCurrent` switch(:562-591)在 `case 'notify'` 前加:

```ts
      case 'p2p':
        await putConfig({ p2p: { federation: { ...exForm.p2p.federation } } })
        break
```

- [ ] **Step 2: i18n zh-CN.ts**(`configPage.nav`/`navDesc`/`sections` 各加一键;`p2p` 子块加在 `upload` 子块前)

```ts
      nav: { ..., p2p: 'P2P 与联邦' },
      navDesc: { ..., p2p: '设备直传与跨站联邦(口令直达,流量不过服务器)' },
      sections: { ..., federation: '联邦注册' },
      p2p: {
        fedEnabled: '启用联邦',
        fedEnabledHint: '本站注册进联邦注册中心,口令分享跨站可达;保存即热生效(多副本部署下自动禁用)',
        registryUrl: '注册中心地址',
        registryUrlPlaceholder: 'https://p2p.example.com:56788',
        registryUrlHint: '留空使用官方公共注册中心;逗号分隔多主备;信令端口 56788,中继端口经 /health 自发现',
        publicUrl: '本站对外地址',
        publicUrlPlaceholder: 'https://share.example.com',
        publicUrlHint: '公告给取件方直连下载用,须公网/局域网可达;一般与站点地址一致',
        minEntropy: '口令公告熵门槛(位)',
        minEntropyHint: '低于此熵的口令不出站(6 位取件码默认仅本站有效,防注册中心侧枚举);0 = 默认 40',
        nodeKeyPath: '节点密钥路径',
        nodeKeyPathPlaceholder: 'data/federation.key',
        nodeKeyPathHint: 'Ed25519 节点身份,首次启动生成;变更即联邦身份更换',
      },
```

- [ ] **Step 3: i18n en-US.ts 同构镜像**

```ts
      nav: { ..., p2p: 'P2P & Federation' },
      navDesc: { ..., p2p: 'Device direct transfer & cross-site federation (code-based, traffic bypasses the server)' },
      sections: { ..., federation: 'Federation registry' },
      p2p: {
        fedEnabled: 'Enable federation',
        fedEnabledHint: 'Register this instance into a federation registry so code shares resolve cross-site; takes effect on save (auto-disabled in multi-replica mode)',
        registryUrl: 'Registry URL',
        registryUrlPlaceholder: 'https://p2p.example.com:56788',
        registryUrlHint: 'Leave empty for the official public registry; comma-separated for multi-registry failover; signaling port 56788, relay port auto-discovered via /health',
        publicUrl: 'Public URL',
        publicUrlPlaceholder: 'https://share.example.com',
        publicUrlHint: 'Announced to receivers for direct download; must be publicly reachable; usually same as the site URL',
        minEntropy: 'Announce entropy threshold (bits)',
        minEntropyHint: 'Codes below this entropy stay local (6-digit pickup codes are site-local by default); 0 = default 40',
        nodeKeyPath: 'Node key path',
        nodeKeyPathPlaceholder: 'data/federation.key',
        nodeKeyPathHint: 'Ed25519 node identity, auto-generated on first start; changing it changes the federation identity',
      },
```

- [ ] **Step 4: typecheck + 单测**

Run: `cd PigeonBox/frontend-core && npm run typecheck && npm test`
Expected: 零类型错误;既有测试全绿。

- [ ] **Step 5: 本地联验(单进程全栈,记忆里的验证路径)**

Run: `cd PigeonBox/frontend-core && npm run dev`,浏览器开 `http://localhost:3000/#/admin/config?section=p2p`:分区可见、开关/表单渲染;开启联邦(留空 registry=公共)保存 → 后端日志出现 `federation enabled`;再关闭保存 → 出现 stop 路径无报错。后端起法(core 独立 dev):`cd PigeonBox/core && PB_ADMIN_PASSWORD=test123456 go run ./cmd/server`(若 cmd 在 server 仓则用 hub `make smoke` 的起法)。

- [ ] **Step 6: Commit**

```bash
cd PigeonBox/frontend-core && git add src/views/admin/Config.vue src/i18n/locales/
git commit -m "feat(admin): 系统配置新增 P2P 与联邦分区(第7分区,联邦在线开关/注册中心/熵门槛)"
```

---

### Task 5: 契约注释同步 + 文档 + 全量验证

**Files:**
- Modify: `contracts/idl/admin.thrift:153-155、:166-167`(段清单注释加 p2p;空 struct 注释不进生成物)
- Modify: `PigeonBox/server/configs/config.example.yaml` federation 段注释(加一行:可在管理后台在线覆盖)
- Test: 全量

- [ ] **Step 1: thrift 注释** — `AdminConfigData` 与 `AdminUpdateConfigReq` 注释里的段清单各插入 `p2p`(位置:`api_token/` 之后):
  - `:153-155` → `…oidc/api_token/p2p/runtime_storage 等段…`
  - `:166-167` → `…oidc/api_token/p2p/runtime_storage…`
  然后 `cd contracts && ./scripts/gen-model.sh CHECK=1 && go run ./cmd/gen-openapi --check` 必须零 diff(注释不影响生成物,防手滑)。

- [ ] **Step 2: example yaml** — federation 段顶部加注释行:
`# 在线覆盖:管理后台「P2P 与联邦」分区保存后以 DB 值为准(SystemConfig overlay);本文件/env 仅作首启默认。`

- [ ] **Step 3: 全量验证**

```bash
cd PigeonBox/core && go test ./... 2>&1 | grep -v "^ok\|no test files" | head -20   # 期望无 FAIL
cd PigeonBox/frontend-core && npm run typecheck && npm test
cd PigeonBox && make vet 2>/dev/null | tail -5
```

- [ ] **Step 4: Commit(两仓)**

```bash
cd PigeonBox/contracts && git add idl/admin.thrift && git commit -m "docs(idl): AdminConfig 段清单注释补 p2p(自由JSON段,零生成物变化)"
cd PigeonBox/server && git add configs/config.example.yaml && git commit -m "docs(config): federation 段注明后台在线覆盖语义"
```

---

## 验收清单(spec §13 回归项)

- [ ] 存量部署(DB 无 p2p 段)行为与今日一致:启动装配走 env/yaml 种子,零行为变化。
- [ ] 后台开启联邦 → 日志 `federation enabled` + `/api/v1/federation/resolve` 返回 available:true;关闭即停。
- [ ] 局部保存任一分区不冲掉 p2p 段;反之保存 p2p 不冲其他段。
- [ ] 非 standalone 下 apply 拒绝并 Warn(可单测注入 global conf 验证)。
- [ ] `go test ./...`(core)全绿、frontend typecheck+vitest 全绿、contracts CHECK=1 零 diff。
