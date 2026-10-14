# P2b — 终端随包 p2pc + trainctl 钉版 + MCP 工具 + 口令硬化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans(本会话内联执行)。Steps use checkbox (`- [ ]`)。

**Goal:** fnos/qnap/openwrt 三端发行物内嵌 p2pc(双架构);trainctl 把 `lib.p2p` 下沉为各端 P2PC_REF 钉版并 verify;p2pc 支持 env 传码(消除 argv 口令暴露)并发 v0.6.2;MCP 直传四工具;本地双 server 实例互传 E2E。

**Architecture:** 打包线统一「读 DEPS.env P2PC_REF → gh/curl 下载 p2p Releases 资产 → checksums 校验 → 落包内 bin」;运行期经 `PB_P2PC_PATH` env 或 supervisor 内置候选序定位;MCP 工具=supervisor 服务层薄包装(admin 作用域)。

**Spec:** `PigeonBox/docs/specs/2026-10-14-p2p-peer-integration-design.md` §10(打包/列车)、§15(硬化留位)

## Global Constraints

- p2pc 资产命名 = Tauri triple(`p2pc-x86_64-unknown-linux-gnu` / `p2pc-aarch64-unknown-linux-gnu`),sha256 侧车 `p2pc-checksums.txt`,**下载必校验**。
- 本机到 github.com 直连超时:下载顺序 curl → 失败回退 `gh release download -R pigeonbox/p2p`(api.github.com 可达)。
- GOWORK=off 纪律:三端打包构建不依赖本地未发布代码;p2pc 是预编译资产不受影响。
- 版本真相源 = hub `release/train.yaml` `lib.p2p`;DEPS.env/.p2pc-version 勿手改(trainctl 接管后)。
- wire 协议 v4:双端须同版——列车内所有终端随 `lib.p2p` 同升。

---

### Task 1: p2p 仓 — env 传码 + 口令行格式锁 + tag v0.6.2

**Files:**
- Modify: `p2p/cmd/p2pc/main.go`(recv 支持 `p2pc recv -` 从 `PB_P2P_CODE` env 读码)
- Create: `p2p/cmd/p2pc/main_test.go`(口令行格式锁 + env 传码)
- Modify: `core/app/p2px/spawn.go`(recv 改 env 传码)

**Interfaces:**
- Produces: p2pc 新形态 `recv -`(env `PB_P2P_CODE`);stdout `口令: XXXX-XXXX-XXXX` 行由单测锁定。

- [ ] **Step 1: 写测试** `p2p/cmd/p2pc/main_test.go`

```go
package main

import (
	"os"
	"testing"
)

// TestRecvCodeFromEnv "p2pc recv -" 从 PB_P2P_CODE 读口令(argv 不留码,
// 同机 ps 不可见——server supervisor 硬化项)。
func TestRecvCodeFromEnv(t *testing.T) {
	t.Setenv("PB_P2P_CODE", "kj8y-wcyz-e249")
	got, err := resolveRecvCode([]string{"-"})
	if err != nil || got != "KJ8Y-WCYZ-E249" {
		t.Fatalf("got=%q err=%v", got, err)
	}
	// 位置参数直传兼容(desktop/CLI 现状)
	t.Setenv("PB_P2P_CODE", "")
	got, err = resolveRecvCode([]string{"abcd-efgh-jkmn"})
	if err != nil || got != "ABCD-EFGH-JKMN" {
		t.Fatalf("positional got=%q err=%v", got, err)
	}
	// "-" 但 env 空 → 报错
	if _, err = resolveRecvCode([]string{"-"}); err == nil {
		t.Fatal("env 空应报错")
	}
}

// TestPrintCodeFormat 口令行格式锁——server supervisor 与 desktop sidecar
// 都按 "口令: XXXX-XXXX-XXXX" 解析 stdout,此格式即契约,变更必须同步。
func TestPrintCodeFormat(t *testing.T) {
	got := captureStdout(t, func() { printCode("ABCD-1234-WXYZ") })
	if !strings.Contains(got, "口令: ABCD-1234-WXYZ\n") {
		t.Fatalf("口令行格式漂移: %q", got)
	}
}
```

- [ ] **Step 2: 跑测试确认失败** — `undefined: resolveRecvCode / printCode`

- [ ] **Step 3: 实现** `cmd/p2pc/main.go`

a) `send()` 里打印口令的两行抽为:

```go
// printCode 口令行格式契约:supervisor(server)与 desktop sidecar 均按此行解析,
// 变更必须同步并 bump wire 说明。单测锁定(main_test.go)。
func printCode(code string) {
	fmt.Printf("口令: %s\n接收方执行: p2pc recv %s\n等待对端接入...\n", code, code)
}
```

b) `receive()` 入口码解析改走:

```go
// resolveRecvCode 口令来源:位置参数直传;"-" = 从 PB_P2P_CODE env 读
// (argv 不留码,同机 ps 不可见——server supervisor 硬化通道)。
func resolveRecvCode(args []string) (string, error) {
	if len(args) == 0 || args[0] == "-" {
		code := strings.ToUpper(strings.TrimSpace(os.Getenv("PB_P2P_CODE")))
		if code == "" {
			return "", fmt.Errorf("口令缺失:位置参数或 PB_P2P_CODE env 二选一")
		}
		return code, nil
	}
	return strings.ToUpper(args[0]), nil
}
```

receive() 用 `resolveRecvCode(fs.Args())`,usage 补一行 `- = 从 PB_P2P_CODE 读`。

c) `core/app/p2px/spawn.go` Recv 的 args 改:`{"recv", "-", "--out", outDir, "--yes", ...}`,spawnPrepared 里 recv 任务 `cmd.Env = append(os.Environ(), "PB_P2P_CODE="+code)`。

- [ ] **Step 4: 测试 + 构建**

```bash
cd PigeonBox/p2p && go test ./cmd/p2pc/ -v && go build ./cmd/... && cd ../core && go test ./app/p2px/ -count=1
```

- [ ] **Step 5: Commit + tag v0.6.2 + push**(CI 出六平台二进制+checksums,供打包线下载)

```bash
cd PigeonBox/p2p && git add cmd/p2pc/ && git commit -m "feat(p2pc): recv 支持 env 传码(recv - + PB_P2P_CODE)+口令行格式锁" && git tag v0.6.2 && git push origin main v0.6.2
```

---

### Task 2: 三端打包脚本随包 p2pc

**Files:**
- Modify: `fnos/scripts/build-native.sh`、`fnos/fnos/cmd/main`(PB_P2PC_PATH per arch)
- Modify: `qnap/scripts/build-native.sh`、`qnap/qpkg/shared/pigeonbox.sh`
- Modify: `openwrt/scripts/build-ipk.sh`(dist/p2pc→usr/bin/p2pc,可选存在)、`openwrt/Makefile`(本地下载)、`openwrt/.github/workflows/release.yml`(matrix 下载)

**Interfaces:**
- Consumes: DEPS.env `P2PC_REF`(Task 3 trainctl 写入;当前手工值 `v0.6.2`)。
- Produces: 包内 p2pc 双架构;supervisor 候选序 `/usr/bin/p2pc`(openwrt)或 `PB_P2PC_PATH` 显式指向(fnos/qnap)。

- [ ] **Step 1: 共享下载片段(三脚本同一形态)**

```bash
# 入参:P2PC_REF(如 v0.6.2) 目标目录 期望 arch 列表
fetch_p2pc() {
  local ref="$1" dest="$2" triple="$3"  # triple=x86_64-unknown-linux-gnu 等
  local asset="p2pc-${triple}" base="https://github.com/pigeonbox/p2p/releases/download/${ref}"
  local tmp; tmp="$(mktemp -d)"
  # checksums 侧车校验(供应链:资产完整性)
  if curl -fsSL -m 60 -o "$tmp/checksums.txt" "${base}/p2pc-checksums.txt" 2>/dev/null \
     && curl -fsSL -m 300 -o "$tmp/${asset}" "${base}/${asset}" 2>/dev/null; then
    (cd "$tmp" && grep " ${asset}\$" checksums.txt | shasum -a 256 -c - >/dev/null)
  else
    # 本机 github 直连被断时回退 gh(api.github.com 可达)
    gh release download "$ref" -R pigeonbox/p2p -p "${asset}" -O "$tmp/${asset}" --clobber
    gh release download "$ref" -R pigeonbox/p2p -p p2pc-checksums.txt -O "$tmp/checksums.txt" --clobber
    (cd "$tmp" && grep " ${asset}\$" checksums.txt | shasum -a 256 -c - >/dev/null)
  fi || { echo "✗ p2pc ${asset}@${ref} 下载/校验失败"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/${asset}" "$dest"
  rm -rf "$tmp"
  echo "    ✓ p2pc ${triple} @ ${ref}"
}
```

注:checksums 行形态 `sha256  name`(sha256sum/shasum 兼容);grep 锚 ` name$` 防前缀撞名(p2pc-web-*)。

- [ ] **Step 2: fnos**

`build-native.sh` 二进制循环后加:

```bash
echo "==> 随包 p2pc(设备直传;版本=P2PC_REF@DEPS.env)"
P2PC_REF=$(grep '^P2PC_REF=' "$ROOT/DEPS.env" | cut -d= -f2)
if [ -n "$P2PC_REF" ]; then
  for arch in amd64 arm64; do
    case "$arch" in amd64) triple=x86_64-unknown-linux-gnu ;; arm64) triple=aarch64-unknown-linux-gnu ;; esac
    fetch_p2pc "$P2PC_REF" "$BIN_DIR/p2pc-linux-${arch}" "$triple"
  done
else
  echo "    (DEPS.env 无 P2PC_REF,跳过——直传功能在包内不可用,优雅降级)"
fi
```

`fnos/fnos/cmd/main` arch 分支后加(运行期注入,覆盖候选查找):

```bash
  case "$(uname -m)" in
    x86_64)        export PB_P2PC_PATH="$APP_ROOT/target/bin/p2pc-linux-amd64" ;;
    aarch64|arm64) export PB_P2PC_PATH="$APP_ROOT/target/bin/p2pc-linux-arm64" ;;
  esac
```

- [ ] **Step 3: qnap**(同构:qpkg/{x86_64,arm_64}/bin/p2pc-linux-{goarch};`shared/pigeonbox.sh` 的 arch→BIN 分支旁加 PB_P2PC_PATH 导出)。

- [ ] **Step 4: openwrt**

`build-ipk.sh` 数据树区加(可选存在,缺则跳过):

```bash
# p2pc 设备直传随包(P2b;dist/p2pc 存在才装,缺失优雅降级)
if [ -f "$ROOT/dist/p2pc" ]; then
	install -m 0755 "$ROOT/dist/p2pc" "$DATA/usr/bin/p2pc"
fi
```

`Makefile` native 目标前加 `dist/p2pc` 下载目标(读 DEPS.env P2PC_REF);`release.yml` matrix 构建段加下载步骤(goarch→triple 映射 amd64→x86_64 / arm64→aarch64)。supervisor 候选序已含 `/usr/bin/p2pc`,init 脚本零改动。

- [ ] **Step 5: 本地验证**(下载链路真实跑通;产物为 linux 二进制本机不执行,验证存在性+校验逻辑)

```bash
cd fnos && P2PC_REF=v0.6.2 bash -c 'source scripts/build-native.sh' # 太重——改为单独跑 fetch 片段单测:
# 以函数库方式验证:source 脚本中的 fetch_p2pc 后,对 amd64 triple 执行一次并 file 检查
```

- [ ] **Step 6: 各仓 commit + push**

---

### Task 3: trainctl — lib.p2p 下沉为终端 P2PC_REF

**Files:**
- Modify: `PigeonBox/release/trainctl/bump.go`(fnos/qnap/openwrt DEPS.env 追加 P2PC_REF;server `.p2pc-version` 写入)
- Modify: `PigeonBox/release/trainctl/verify.go`(断言 DEPS P2PC_REF == lib.p2p;server .p2pc-version == lib.p2p)
- Test: `PigeonBox/release/trainctl/` 既有测试形态延续(读 trainfile fixture 断言 bump 输出)

**Interfaces:**
- Consumes: `b.p2p`(lib.p2p,已读)。
- Produces: `fnos/qnap/openwrt DEPS.env` 多一行 `P2PC_REF=vX.Y.Z`;`server/.p2pc-version` 内容 `vX.Y.Z`。

- [ ] **Step 1: 改 bump.go**

fnos 段(:472 附近 `b.edit("fnos", dir, "DEPS.env", ...)`)与 native 段(:499)的 DEPS.env 重写生成器末尾追加一行 `P2PC_REF=<b.p2p>`;新增 server 仓处理:写 `.p2pc-version` 内容为 `b.p2p`(files 列表追加)。

- [ ] **Step 2: verify.go** 仿 desktop P2PC_REF 断言(:363/:425 先例)对三端 DEPS.env + server .p2pc-version 各加一条。

- [ ] **Step 3: 测试 + commit**

```bash
cd PigeonBox/release/trainctl && go test ./... && cd .. && git add release/trainctl && git commit -m "feat(trainctl): lib.p2p 下沉为 fnos/qnap/openwrt P2PC_REF 与 server .p2pc-version 钉版+verify"
```

---

### Task 4: MCP 直传四工具(admin 作用域)

**Files:**
- Modify: `core/app/mcp/mcp.go`(tools 注册表 + dispatch case)
- Modify: `core/bootstrap/adapters.go`(p2pMcpAdapter:Status/Send/Recv/Cancel/List 桥到 p2px)
- Modify: `core/bootstrap/wiring.go`(`mcpService.SetP2pService(...)`)
- Test: `core/app/mcp/mcp_test.go`(权限门:游客拒绝;admin 可调用;参数校验)

**Interfaces:**
- Consumes: Task 3(p2a) 的 `p2px.Service`。
- Produces: MCP 工具 `p2p_status` / `p2p_send{paths}` / `p2p_recv{code}` / `p2p_tasks`;游客与登录用户被拒(admin-only,不受 allow_guest 影响)。

- [ ] **Step 1: 失败测试** — 未注入时 `p2p_status` 返回「直传未启用/不可用」;注入 stub 后 admin 调用成功;guest 作用域工具列表不含四工具。
- [ ] **Step 2: 实现**——mcp.go 加 `P2pAPI` 窄接口(`Status()(...)`,`Send/Recv/Cancel/List`),`SetP2pService` setter(带锁,同 fedMu 先例);dispatch case 四支;tools/list 四条 schema(admin 级);wiring 装配 + adapters.go 桥。
- [ ] **Step 3: `go test ./app/mcp/ ./bootstrap/ -race` + commit push**

---

### Task 5: 本地双 server 实例互传 E2E

```bash
# p2pd 12346;serverA 12345;serverB 12445(PB_SERVER_PORT/PB_DATABASE_DB_NAME/数据目录隔离)
# A 后台开直传(send_roots=/tmp/p2p-e2e) → A 发送 hello2.txt → 口令
# B 后台开直传(recv_dir=/tmp/p2p-e2e/inboxB) → B 接收 → sha256 一致
# B 发布为分享 → 匿名下载校验
# 归档:/tmp/p2p-e2e 全清
```

### Task 6: 文档与收口

- `docs/ENVIRONMENT_VARIABLES.md` 加 `PB_P2PC_PATH`、`PB_P2P_CODE`(p2pc)说明
- spec §16:P2b 标记完成;§14 硬化留位核销(env 传码已做)
- hub AGENTS.md 生态表无改动项(端口勘误 P2a 已做)
- 全仓 push + CI 绿

## 验收清单

- [ ] fnos/qnap/openwrt 打包产物内均含双架构 p2pc(checksums 校验通过)
- [ ] `trainctl verify` 绿(三端 P2PC_REF + server .p2pc-version == lib.p2p)
- [ ] MCP 四工具 admin 可调、游客不可见
- [ ] 双实例互传 sha256 一致;env 传码后 `ps` 不见口令
- [ ] 全仓 CI 绿
