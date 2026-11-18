#!/usr/bin/env bash
# sdk-demo.sh —— 官方 Go/TS SDK 对真实 server 的全链路冒烟：寄件 → 取件 → 删除。
#
# 背景（hub#367 验收）：「SDK demo 在 CI 里对真实 server 冒烟：寄件 → 取件 → 删除
# 全链路」。本脚本挂在 ci.yml 的 smoke job（跑完 smoke-full 之后）：复用 smoke-full
# 留下的 $SMOKE/server-bin + config.yaml + 数据库（smoker 用户在库里），自起实例，
# 分别跑 sdk/go/cmd/demo 与 sdk/ts 的 dist/demo.js。
#
# 两种形态：
#   1) 外置模式：SDK_DEMO_BASE（或默认 127.0.0.1:${SDK_DEMO_PORT}）已有健康实例
#      ⇒ 直接打，不接管生命周期（本地调试用）；
#   2) 内置模式：自起 $SMOKE/server-bin（+ 临时 redis，端口被占则视为外部实例不接管），
#      跑完只回收自己起的进程。
#
# 凭据：默认 smoker/smoke12345（smoke-full 注册的用户）；可 SDK_DEMO_USER /
# SDK_DEMO_PASSWORD 覆盖；或 SDK_DEMO_API_KEY 直接给 Key（跳过登录）。
#
# 退出码：0 = 两个 demo 全过；非 0 = 失败（CI 判红）。缺产物/缺工具一律判红，
# 不静默跳过——门禁空转比没有门禁更糟。
set -uo pipefail

# ── shellkit（冒烟侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK_BOOTSTRAP="$ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=../vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"
SMOKE="${SMOKE:-/tmp/fcb-smoke}"
PORT="${SDK_DEMO_PORT:-18777}"
BASE="${SDK_DEMO_BASE:-http://127.0.0.1:${PORT}}"
REDIS_PORT=16379
SRV=""
RPID=""

# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原函数式 trap 等价。
# ⚠️ 原函数式 trap 还带「成功哨兵」（OK≠1 ⇒ 没跑到结尾 ⇒ 判失败）：本脚本的
#    失败路径全部走 die（退 1），成功路径唯一（末尾置 OK=1 后自然结束）⇒
#    不存在「落到文件尾却 exit 0」的路径 ⇒ 哨兵拆掉后行为等价。
#    （函数式 trap 本来也**脱离** scripts/check-shell-trap-exit-code.sh 的覆盖
#      —— 门禁静态判不了 ⇒ 换成清理栈形态后重新进入退出码保障的射程。）
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'if [ -n "${RPID:-}" ]; then kill "$RPID" 2>/dev/null || true; fi'
trap_push 'if [ -n "${SRV:-}" ]; then kill "$SRV" 2>/dev/null || true; fi'
trap_install

health_ok() { curl -sf --max-time 3 "$BASE/health" >/dev/null 2>&1; }

boot_if_needed() {
  if health_ok; then
    log_info "外置模式：$BASE 已有健康实例"
    return 0
  fi
  [ -x "${SMOKE}/server-bin" ] ||
    die 1 "sdk-demo: 缺 ${SMOKE}/server-bin（先跑 scripts/smoke-full.sh，或设 SDK_DEMO_BASE 指向健康实例）"
  [ -f "${SMOKE}/config.yaml" ] ||
    die 1 "sdk-demo: 缺 ${SMOKE}/config.yaml（先跑 scripts/smoke-full.sh，或设 SDK_DEMO_BASE 指向健康实例）"

  # redis：能起就起（smoke-full 的 config 指向 127.0.0.1:16379）；
  # 端口已被占（外部 redis / 上一轮残留）⇒ 不接管（RPID 留空，退出时不杀）。
  if command -v redis-server >/dev/null 2>&1; then
    redis-server --port "$REDIS_PORT" --daemonize no --save '' --appendonly no >"${SMOKE}/sdk-demo-redis.log" 2>&1 &
    RPID=$!
    sleep 0.3
    if ! kill -0 "$RPID" 2>/dev/null; then RPID=""; fi
  fi

  # JWT secret 启动期定死（≥32 字符才过配置校验）；demo 登录发的 token 同源即可。
  PB_JWT_SECRET="sdk-demo-jwt-secret-000000000000000000" "${SMOKE}/server-bin" --config "${SMOKE}/config.yaml" >"${SMOKE}/sdk-demo-server.log" 2>&1 &
  # shellcheck disable=SC2034  # SRV 只在 trap 清理串里被读（shellcheck 看不见单引号串）
  SRV=$!
  for _ in $(seq 1 30); do
    health_ok && break
    sleep 0.5
  done
  if ! health_ok; then
    tail -20 "${SMOKE}/sdk-demo-server.log" >&2 2>/dev/null || true
    die 1 "sdk-demo: server 未能就绪（日志：${SMOKE}/sdk-demo-server.log）"
  fi
  log_info "内置模式：已自起 $BASE"
}

demo_auth_args() {
  # 输出到调用方数组：有 Key 用 Key，否则登录凭据。
  if [ -n "${SDK_DEMO_API_KEY:-}" ]; then
    printf '%s\n' "key"
  else
    printf '%s\n' "cred"
  fi
}

run_go_demo() {
  log_info "── Go SDK demo（sdk/go）"
  local mode args
  mode="$(demo_auth_args)"
  args=(-base "$BASE")
  if [ "$mode" = "key" ]; then
    args+=(-api-key "$SDK_DEMO_API_KEY")
  else
    args+=(-user "${SDK_DEMO_USER:-smoker}" -password "${SDK_DEMO_PASSWORD:-smoke12345}")
  fi
  (cd "${ROOT}/sdk/go" && GOWORK=off go run ./cmd/demo "${args[@]}") ||
    die 1 "sdk-demo: Go demo 失败"
}

run_ts_demo() {
  log_info "── TS SDK demo（sdk/ts）"
  command -v node >/dev/null 2>&1 || die 1 "sdk-demo: 缺 node（TS demo 需要 Node ≥18）"
  command -v npm >/dev/null 2>&1 || die 1 "sdk-demo: 缺 npm"
  local mode args
  mode="$(demo_auth_args)"
  args=(--base "$BASE")
  if [ "$mode" = "key" ]; then
    args+=(--api-key "$SDK_DEMO_API_KEY")
  else
    args+=(--user "${SDK_DEMO_USER:-smoker}" --password "${SDK_DEMO_PASSWORD:-smoke12345}")
  fi
  (
    cd "${ROOT}/sdk/ts"
    if [ ! -d node_modules ]; then
      npm ci --no-audit --no-fund || die 1 "sdk-demo: npm ci 失败"
    fi
    npm run build || die 1 "sdk-demo: sdk/ts 构建失败"
    node dist/demo.js "${args[@]}" || die 1 "sdk-demo: TS demo 失败"
  ) || exit 1
}

boot_if_needed
run_go_demo
run_ts_demo
log_ok "sdk-demo: PASS（寄件 → 取件 → 删除，Go + TS 双 SDK 对真实 server 全链路）"
