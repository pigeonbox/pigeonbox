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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE="${SMOKE:-/tmp/fcb-smoke}"
PORT="${SDK_DEMO_PORT:-18777}"
BASE="${SDK_DEMO_BASE:-http://127.0.0.1:${PORT}}"
REDIS_PORT=16379
SRV=""
RPID=""
OK=0

log() { printf '%s\n' "$*"; }
die() {
  printf 'sdk-demo: %s\n' "$*" >&2
  exit 1
}

# 成功哨兵形态（check-shell-trap-exit-code 口径）：跑到结尾才置 OK=1；
# trap 里 rc≠0 原样保留；rc=0 但没跑到结尾 ⇒ 判失败。
on_exit() {
  _rc=$?
  if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null || true; fi
  if [ -n "$RPID" ]; then kill "$RPID" 2>/dev/null || true; fi
  if [ "$_rc" -ne 0 ]; then exit "$_rc"; fi
  if [ "$OK" != 1 ]; then exit 1; fi
  exit 0
}
trap on_exit EXIT

health_ok() { curl -sf --max-time 3 "$BASE/health" >/dev/null 2>&1; }

boot_if_needed() {
  if health_ok; then
    log "外置模式：$BASE 已有健康实例"
    return 0
  fi
  [ -x "${SMOKE}/server-bin" ] ||
    die "缺 ${SMOKE}/server-bin（先跑 scripts/smoke-full.sh，或设 SDK_DEMO_BASE 指向健康实例）"
  [ -f "${SMOKE}/config.yaml" ] ||
    die "缺 ${SMOKE}/config.yaml（先跑 scripts/smoke-full.sh，或设 SDK_DEMO_BASE 指向健康实例）"

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
  SRV=$!
  for _ in $(seq 1 30); do
    health_ok && break
    sleep 0.5
  done
  if ! health_ok; then
    tail -20 "${SMOKE}/sdk-demo-server.log" >&2 2>/dev/null || true
    die "server 未能就绪（日志：${SMOKE}/sdk-demo-server.log）"
  fi
  log "内置模式：已自起 $BASE"
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
  log "── Go SDK demo（sdk/go）"
  local mode args
  mode="$(demo_auth_args)"
  args=(-base "$BASE")
  if [ "$mode" = "key" ]; then
    args+=(-api-key "$SDK_DEMO_API_KEY")
  else
    args+=(-user "${SDK_DEMO_USER:-smoker}" -password "${SDK_DEMO_PASSWORD:-smoke12345}")
  fi
  (cd "${ROOT}/sdk/go" && GOWORK=off go run ./cmd/demo "${args[@]}") ||
    die "Go demo 失败"
}

run_ts_demo() {
  log "── TS SDK demo（sdk/ts）"
  command -v node >/dev/null 2>&1 || die "缺 node（TS demo 需要 Node ≥18）"
  command -v npm >/dev/null 2>&1 || die "缺 npm"
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
      npm ci --no-audit --no-fund || die "npm ci 失败"
    fi
    npm run build || die "sdk/ts 构建失败"
    node dist/demo.js "${args[@]}" || die "TS demo 失败"
  ) || exit 1
}

boot_if_needed
run_go_demo
run_ts_demo
OK=1
log "sdk-demo: PASS（寄件 → 取件 → 删除，Go + TS 双 SDK 对真实 server 全链路）"
