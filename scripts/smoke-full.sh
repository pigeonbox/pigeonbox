#!/bin/sh
# shellcheck disable=SC2015
# POSIX sh 兼容（bash / dash / busybox ash 都能跑）——QNAP 的 QTS 只有 busybox
# ash 没有 bash，为了让**真机 NAS 也能跑全量冒烟**（2026-10-22 fnOS/QNAP 实测），
# 脚本不使用任何 bash 专属语法。
# ⚠️ 这条自述曾经是**假的**：脚本里两处 bash 扩展（${X:0:4} 字符串切片、
#    mkdir 的 {a,b} brace expansion）在 **dash（Debian/Ubuntu 的 /bin/sh）上
#    是坏语法**——前者报 "Bad substitution" 让脚本当场崩、后者建出字面量目录
#    `{data,uploads,...}`。2026-10-23 shellcheck 门禁（SC3057/SC3009）把它逼
#    出来，真机实测（Ubuntu 24.04 /bin/sh=dash）复现了崩溃。两处均已改成
#    POSIX 写法（case 前缀匹配 / 显式 mkdir），并在 dash + busybox ash 上实测通过。
# 断言形态统一为「A && ok || bad」：ok/bad 两个助手都以 exit 0 收尾，
# 故不存在 SC2015 担心的「B 失败导致 C 误跑」路径（此处 B 恒为 ok/bad）。
# 反向形态「A && bad || ok」（泄露类断言）同理：B 恒为 bad。
#
# PigeonBox 全能力真机冒烟（49 项断言）：健康面/openapi 运行时生成/api config/admin 登录/
# 文本+密码分享/元数据不泄露/select 不扣次数/文件分享+Range/多文件+zip/chunk 完成+秒传/
# 本地文件管理(穿越防护，目标需启用 local_import)/寄件码全链路/MCP/二维码/匿名码(需 Redis)/robots。
#
# 用法一(默认):bash scripts/smoke-full.sh
#   自动编译 server、起临时实例(含临时 Redis,端口 18777)、跑完即清理。
# 用法二(外置实例):SMOKE_BASE=http://host:port bash scripts/smoke-full.sh
# 用法三(现成二进制,真机跑发布产物):SMOKE_BIN=/path/to/pigeonbox bash scripts/smoke-full.sh
#   ——NAS 上没有 go 编译器时用这个:装包里的静态二进制就是**发布产物**,直接拿来跑。
#   不编译不起服务,直接对已有实例跑全部断言——用于 Docker/compose/K8s 部署验证。
#   注意:外置实例需启用 local_import(roots 需包含本机 /tmp/fcb-smoke/import
#   的容器内挂载路径)且 Redis 可用,否则 S12/S16 两域会失败。
set -u
SMOKE=${SMOKE:-/tmp/fcb-smoke}
BASE=${SMOKE_BASE:-http://127.0.0.1:18777}
PORT=18777
# 脚本自身目录（绝对路径）：内置模式会 cd 到 ../server ⇒ 相对路径全废
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; throttle; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1  [$2]"; throttle; }
# skip：断言域因**环境前置条件不足**无法执行（如外置实例没开 local_import）——
# 这不是产品缺陷，记 SKIP 而不是 FAIL。否则一轮真机冒烟里永远带着几个假红，
# 久了就没人看结果了（2026-10-22 真机跑全量冒烟时暴露）。
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1  [$2]"; throttle; }
J() { "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(eval(sys.argv[1], {'d': d}))
except Exception as e:
    print('JERR:'+str(e))
" "$1" 2>/dev/null; }
# J() 解析失败时回传 "JERR:…" 前缀。判定"是否解析失败"用 POSIX 前缀匹配（case），
# 不用 ${X:0:4}：字符串切片是 bash/busybox 扩展，**dash 会报 Bad substitution**
# ⇒ 脚本在 Debian/Ubuntu 的 /bin/sh 上当场崩（真机实测复现）。
is_jerr() { case "$1" in JERR*) return 0 ;; *) return 1 ;; esac; }

# ── 请求节流（2026-10-30 NAS 真机实录）────────────────────────────────────
# 冒烟一次要打**几百个**请求，而实例默认全局限流 GlobalQPS=100 / Burst=20
# ⇒ **连着跑两遍必撞 429**，满屏假红（429 不是产品缺陷，是测试自己打爆了预算）。
# ⇒ 每条断言后让出一点时间（所有请求几乎都对应一条 ok/bad ⇒ 一处生效）。
SMOKE_THROTTLE="${SMOKE_THROTTLE:-0.05}"
throttle() { [ -n "$SMOKE_THROTTLE" ] && sleep "$SMOKE_THROTTLE" || true; }

# ── 还原守卫（2026-10-26 审计 P0）──────────────────────────────────────────
# 冒烟对目标实例做过**降级改动**（开放注册 + 上传上限 50MB + 存储配额 1GB）
# ⇒ 任何退出路径（正常结束 / Ctrl-C / 超时 / 中途报错）都必须还原，
#   且**还原失败必须计入 FAIL**（旧实现三条静默逃逸口全都不影响 FAIL 计数
#   ⇒ 绿冒烟却把生产实例留在降级态）。
USER_CFG_SNAP="$SMOKE/user-config-before.json"
USER_CFG_RESTORE_PENDING=0

# 快照校验:必须是可解析 JSON 且 data 带齐那 4 个键
# （读原值失败 ⇒ 快照空/解析失败 ⇒ **绝不允许改配置**：改了还原不回来）
user_cfg_snapshot_ok() {
  "$PY" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
data = d.get('data') if isinstance(d, dict) else None
need = ('allowuserregistration','useruploadsize','userstoragequota','sessionexpiryhours')
sys.exit(0 if isinstance(data, dict) and all(k in data for k in need) else 1)
" "$1" 2>/dev/null
}

# ── 冒烟用的**临时（降级）配置值**：必须"病态到正常实例绝不会是它" ──────
# 2026-10-30 实录（NAS 真机）：旧实现用 {注册开, 上传上限 50MB, 配额 1GB,
# 会话 168h} 当临时值 —— 而 50MB/1GB/168h **恰好就是不少实例的正常默认值**
# ⇒ 上一次冒烟还原失败留下的降级态，会被下一次冒烟当成"原值"快照，
#    再"还原"成降级态还报「还原并回读校验通过」⇒ **绿灯掩盖降级态**。
# ⇒ 临时值改成病态值（2MB 上限 / 2MB 配额 / 1h 会话）：正常配置绝不含这些。
SMOKE_CFG_REG=true
SMOKE_CFG_UPLOAD=2097152
SMOKE_CFG_QUOTA=2097152
SMOKE_CFG_SESSION=1

# user_cfg_snapshot_is_degraded 快照**本身**就是上次冒烟残留的降级态。
# **命中 ⇒ 退出码 0**（与调用处 `if user_cfg_snapshot_is_degraded …` 的语义对齐；
#   ⚠️ 2026-10-30 实录：初版这里写成"命中 ⇒ exit 1" ⇒ 与 if 语义相反 ⇒
#   残留快照没被识别、正常快照反被误报 ⇒ 修复时**必须**让命中返回 0）。
# 命中 ⇒ 上一轮还原失败过（目标实例被留在降级态）⇒ 必须报 FAIL 并**拒绝继续**
# （否则会把坏状态当原值保存、又"还原"成坏状态，继续绿）。
#
# 判据两条（任一命中即算残留）：
#   ① allowuserregistration == true —— **正常实例不该开着开放注册**
#      （脚本自己写的临时值就是 true；NAS 场景默认关闭）⇒ 这条能识别**旧版
#      临时值**留下的残留，不依赖"病态数值"恰好不与正常默认值重合；
#   ② 命中本次的病态临时值（2MB 上限 / 2MB 配额 / 1h 会话）。
# 保守取向：宁可 FAIL 拒绝改配置，也不把降级态当原值继续。
user_cfg_snapshot_is_degraded() {
  "$PY" -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
data = d.get('data') if isinstance(d, dict) else None
if not isinstance(data, dict):
    sys.exit(1)
# ① 病态临时值（2026-10-30 起）：2MB 上限 / 2MB 配额 / 1h 会话 —— 正常配置绝不含
if (data.get('useruploadsize') == 2097152 or data.get('userstoragequota') == 2097152
        or data.get('sessionexpiryhours') == 1):
    sys.exit(0)
# ② 旧版临时值（{注册开, 50MB, 1GB, 168h}）：必须**四键全中**才算残留。
# ⚠️ 单看 allowuserregistration==true **不能**判残留 —— **全新库的默认值就是 true**
#    （2026-10-30 CI 实录：fresh instance 的快照 {true,0,0,168} 被误判成残留 ⇒ 假红）。
if (data.get('allowuserregistration') is True and data.get('useruploadsize') == 52428800
        and data.get('userstoragequota') == 1073741824 and data.get('sessionexpiryhours') == 168):
    sys.exit(0)
sys.exit(1)
" "$1" 2>/dev/null
}

# 还原:写回 + **回读比对**（逻辑在 scripts/smoke-user-config-restore.sh：
# 读原值失败/解析失败/PUT 失败 三条路径全部返回非零退出码）。
# 失败 ⇒ bad() ⇒ 计入 FAIL ⇒ 退出码非 0（不再只 print WARNING 后继续）。
# 幂等:PENDING 在**尝试前**清零 ⇒ trap 与尾部各调一次也只还原一次
# （还原失败不重试：重试掩盖首次失败的真因，且退出码已非 0）。
#
# 还原脚本缺失时的**内联兜底**（2026-10-30 NAS 真机实录）：
#   只把 smoke-full.sh **单文件**拷到机器上跑（NAS 上最常见的拷法）⇒ 同目录
#   没有 smoke-user-config-restore.sh ⇒ 还原调用找不到脚本 ⇒ 目标实例被留在
#   「开放注册开着 + 配额压到 1GB」的降级态（脚本自己的失败提示就是这句）。
#   ⇒ 内联兜底与独立脚本**同一判据**（写回 + 回读比对，任一环节失败即非零）。
RESTORE_SCRIPT="$SCRIPT_DIR/smoke-user-config-restore.sh"

# restore_capable 还原能力自检：**改配置之前**就要过。
# 没有还原手段 ⇒ 宁可**不改**（fail-fast），也别把目标实例留在降级态。
restore_capable() {
  [ -f "$RESTORE_SCRIPT" ] && return 0
  [ -n "${PY:-}" ] && return 0
  return 1
}

# restore_inline 内联还原（判据与 scripts/smoke-user-config-restore.sh 完全一致：
# 快照可解析且 4 键齐全 → 写回 → 回读比对；失败一律非零退出码）。
restore_inline() {
  [ -n "${PY:-}" ] || return 1
  "$PY" - "$BASE" "${TOK:-}" "$USER_CFG_SNAP" <<'PYEOF'
import json, sys, urllib.request

base, token, snap_path = sys.argv[1], sys.argv[2], sys.argv[3]
KEYS = ('allowuserregistration', 'useruploadsize', 'userstoragequota', 'sessionexpiryhours')


def die(code, msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


try:
    with open(snap_path, 'r') as f:
        doc = json.loads(f.read())
except Exception as e:
    die(2, "快照不可解析: %s" % e)
if not isinstance(doc, dict):
    die(2, "快照不是 JSON 对象")
data = doc.get('data') or {}
if not isinstance(data, dict):
    die(2, "快照 data 不是对象")
missing = [k for k in KEYS if k not in data]
if missing:
    die(2, "快照缺键: %s（读原值不完整 ⇒ 不得写回）" % ",".join(missing))
orig = dict((k, data[k]) for k in KEYS)


def http(method, path, payload=None):
    url = base.rstrip('/') + path
    req = urllib.request.Request(
        url,
        data=None if payload is None else json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token},
        method=method)
    resp = urllib.request.urlopen(req, timeout=15)
    try:
        return resp.getcode(), resp.read().decode('utf-8', 'replace')
    finally:
        resp.close()


try:
    st, body = http('PUT', '/admin/config/user', orig)
except Exception as e:
    die(3, "写回失败: %s" % e)
if st < 200 or st >= 300:
    die(3, "写回 HTTP %s: %s" % (st, body[:200]))
try:
    st, body = http('GET', '/admin/config/user')
except Exception as e:
    die(4, "回读失败: %s" % e)
if st < 200 or st >= 300:
    die(4, "回读 HTTP %s" % st)
try:
    now = json.loads(body)
except Exception as e:
    die(4, "回读不可解析: %s" % e)
now = (now.get('data') or {}) if isinstance(now, dict) else {}
if not isinstance(now, dict):
    die(4, "回读 data 不是对象")
diff = [k for k in KEYS if now.get(k) != orig[k]]
if diff:
    die(4, "回读不一致: %s（期望 %s / 实际 %s）" % (
        ",".join(diff), json.dumps(orig, ensure_ascii=False), json.dumps(now, ensure_ascii=False)))
print("user config restored & verified: " + json.dumps(orig, ensure_ascii=False))
PYEOF
}

restore_user_config() {
  [ "${USER_CFG_RESTORE_PENDING:-0}" = "1" ] || return 0
  USER_CFG_RESTORE_PENDING=0
  if [ -f "$RESTORE_SCRIPT" ]; then
    if sh "$RESTORE_SCRIPT" \
         --base "$BASE" --token "${TOK:-}" --snapshot "$USER_CFG_SNAP"; then
      ok "S13-还原 用户配置已还原并回读校验通过"
      return 0
    fi
  else
    if restore_inline; then
      ok "S13-还原 用户配置已还原并回读校验通过（内联兜底：同目录无独立还原脚本）"
      return 0
    fi
  fi
  bad "S13-还原 用户配置还原失败" "**目标实例仍处于降级态**(开放注册/配额下调),须手工还原"
  return 1
}

# 退出钩子:顺序不可换 —— **先还原**(要打服务端 API)再杀本地 server。
# shellcheck disable=SC2317,SC2329  # 由 trap 间接调用（不同 shellcheck 版本报不同码：旧版 SC2317「命令不可达」/ 新版 SC2329「函数从未被调用」）
on_exit() {
  _want="${1:-$?}"
  restore_user_config
  # 用显式 if 而不是 `[ -n "$X" ] && kill …`：后者的复合状态在 X 为空时是 1
  # （旧版 shellcheck 判其后语句「不可达」⇒ SC2317；且读起来像「exit 走不到」）。
  if [ -n "${SRV:-}" ]; then kill "$SRV" 2>/dev/null || true; fi
  if [ -n "${RPID:-}" ]; then kill "$RPID" 2>/dev/null || true; fi
  if [ "$FAIL" -gt 0 ]; then exit "$FAIL"; fi
  exit "$_want"
}
trap on_exit EXIT
trap 'on_exit 130' INT
trap 'on_exit 143' TERM

# 显式列目录，不用 mkdir 的 {a,b} brace expansion（dash 下会建出字面量目录
# "{data,uploads,import,src}" ⇒ 后续写 $SMOKE/import/... 全部失败）。
mkdir -p "$SMOKE/data" "$SMOKE/uploads" "$SMOKE/import" "$SMOKE/src"
echo "smoke-local-content-$(date +%s)" > "$SMOKE/import/local-nas.txt"
printf 'hello-pigeonbox-range' > "$SMOKE/src/smoke-range.txt"
# ⚠️ 分片测试文件的内容**必须每轮唯一**（2026-10-30 真机实录）：
#   分片会话的键 = 文件内容的 sha256 ⇒ 内容固定 ⇒ upload_id 固定 ⇒
#   上一轮留下的会话（**归属上一轮的来源 IP**，且未 complete 时状态仍是 pending）
#   会让本轮的 init 撞「他人进行中的会话」⇒ 409 ⇒ upload_id 取空 ⇒
#   后续分片请求打到 /chunk/upload/chunk//0 ⇒ 报 400/404 ⇒ 一串**假红**。
#   （S11b/S11b2 的「同 hash 二次 init」断言是**轮内**语义 ⇒ 每轮唯一不影响它们。）
#   ⇒ 用 20 位定长 run 标记做前缀，**保持字节数不变**（300000 / 1024）。
RUN_TAG=$(printf '%020d' $(( $(date +%s) * 1000 + $$ % 1000 )))
{ printf 'smoke-run-%s' "$RUN_TAG"; head -c 299970 /dev/zero | tr '\0' 'A'; } > "$SMOKE/src/big-a.txt"
{ printf 'smoke-run-%s' "$RUN_TAG"; head -c 994 /dev/zero | tr '\0' 'B'; } > "$SMOKE/src/bad-chunk.bin"
echo "multi-file-one" > "$SMOKE/src/m1.txt"
echo "multi-file-two" > "$SMOKE/src/m2.txt"

# python:断言解析用。python3 优先,退化到 python（部分 NAS 只有 python2;
# 断言里没用 f-string,py2 可跑）。
# ⚠️ 必须放在**顶层**（两种模式都要用）：此前定义在内置模式分支内 ⇒
# 外置模式（SMOKE_BASE）下 PY 未定义 ⇒ set -u 直接报 "PY: unbound variable"
# ⇒ 所有 JSON 解析断言全红（2026-10-22 murphy-server 真机跑时抓到）。
PY="${SMOKE_PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "需要 python3（断言解析用）;请先安装"; exit 1; }

if [ -z "${SMOKE_BASE:-}" ]; then
  # ===== 内置模式:起临时实例 =====
  # redis:有 redis-server 就起临时实例;没有就让服务端走**单机内存模式**
  # (redis.host 空 = memkv + 回源 DB,匿名取件/限流仍可用)——真机 NAS 上跑
  # 全量冒烟时本机往往没有 redis-server（2026-10-22 fnOS 实测）。
  HAVE_REDIS=0
  command -v redis-server >/dev/null 2>&1 && HAVE_REDIS=1
  REDIS_HOST='127.0.0.1'
  REDIS_PORT=16379
  if [ "$HAVE_REDIS" != 1 ]; then REDIS_HOST=''; fi
  # 数据卫生:$SMOKE 是固定路径(/tmp/fcb-smoke),陈旧 DB 会跨轮累积同哈希
  # 过期分享,把秒传断言(S11b)打成确定性失败(2026-10-10 实锤:10-08 轮次
  # 遗留的过期记录永久遮蔽新分享——产品侧 GetByHashAndSize 同轮已修,
  # 测试侧每轮干净起库双保险)。
  rm -rf "$SMOKE/data" "$SMOKE/uploads"
  mkdir -p "$SMOKE/data" "$SMOKE/uploads"
cat > "$SMOKE/config.yaml" <<EOF
server:
  host: "127.0.0.1"
  port: $PORT
  mode: "dev"
  base_url: "$BASE"
redis:
  host: "$REDIS_HOST"
  port: $REDIS_PORT
  password: ""
  db: 0
database:
  driver: "sqlite"
  db_name: "$SMOKE/data/fcb.db"
app:
  name: "PigeonBox-Smoke"
  datapath: "$SMOKE/data"
upload:
  open_upload: true
  upload_size: 104857600
  enable_chunk: true
  chunk_size: 1048576
  max_file_size: 104857600
  local_import:
    enabled: true
    roots: ["$SMOKE/import"]
storage:
  type: "local"
  storage_path: "$SMOKE/uploads"
log:
  level: "warn"
user:
  allow_user_registration: true
observability:
  metrics:
    enabled: false
EOF

  # 取服务端二进制:SMOKE_BIN 给了就用现成的（**真机上跑发布产物**——NAS 安装包
  # 里的静态二进制就是发布产物,不必在 NAS 上编译);否则从 ../server 源码编译。
  if [ -n "${SMOKE_BIN:-}" ]; then
    [ -x "$SMOKE_BIN" ] || { echo "SMOKE_BIN 不可执行: $SMOKE_BIN"; exit 1; }
    cp -f "$SMOKE_BIN" "$SMOKE/server-bin"
    chmod +x "$SMOKE/server-bin"
    echo "  使用现成二进制: $SMOKE_BIN"
  else
    command -v go >/dev/null 2>&1 || { echo "需要 go（编译服务端）或用 SMOKE_BIN 指定现成二进制"; exit 1; }
    cd "$(dirname "$0")/../server" || exit 1
    go build -o "$SMOKE/server-bin" ./cmd/server || { echo "BUILD FAILED"; exit 1; }
  fi
  PB_JWT_SECRET=smoke-secret-$(date +%s) "$SMOKE/server-bin" --config "$SMOKE/config.yaml" > "$SMOKE/server.log" 2>&1 &
  SRV=$!
  if [ "$HAVE_REDIS" = 1 ]; then
    redis-server --port 16379 --daemonize no --save '' --appendonly no > "$SMOKE/redis.log" 2>&1 &
    RPID=$!
  else
    RPID=""
    echo "  (无 redis-server ⇒ 服务端走单机内存模式)"
  fi
  # ⚠️ 退出清理统一由顶层 on_exit trap 负责（还原用户配置 + 杀本地 server）
  #    ——此前这里只有一条 kill trap，**用户配置的还原没有任何 trap 保护**。
  for _ in $(seq 1 30); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -sf "$BASE/health" >/dev/null || { echo "SERVER NOT UP"; tail -20 "$SMOKE/server.log"; exit 1; }
fi

# ── 限流预检（2026-10-30 NAS 真机实录）────────────────────────────────────
# 冒烟一次要打**几百个**请求，而实例默认全局限流 GlobalQPS=100 / Burst=20
# ⇒ **连着跑两遍必撞 429**，满屏假红（429 不是产品缺陷，是测试自己打爆了预算）。
# ⇒ 开跑前探一次；命中 429 就等预算恢复（限流窗口秒级）再跑；等不到就放弃本轮
#    并说清「不是产品缺陷」，而不是甩一屏假红。
SMOKE_RL_WAIT="${SMOKE_RL_WAIT:-90}"
_rl_try=0
while :; do
  _rl_code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/config" 2>/dev/null || echo 000)
  [ "$_rl_code" = "429" ] || break
  _rl_try=$((_rl_try+1))
  if [ "$_rl_try" -gt 18 ]; then
    echo "限流预算未恢复(429，已等 $((_rl_try*5))s) ⇒ 本轮放弃（**不是产品缺陷**：上一轮冒烟的请求还在限流窗口内，稍后重跑即可）"
    exit 1
  fi
  sleep 5
done
[ "$_rl_try" -gt 0 ] && echo "（限流预算已恢复：等了 $((_rl_try*5))s）"

# S1 健康面
[ -n "$(curl -s "$BASE/live")" ] && ok "S1a live" || bad "S1a live" "$(curl -s "$BASE/live")"
curl -s "$BASE/readyz" | grep -qi 'ok\|ready\|true' && ok "S1b readyz" || bad "S1b readyz" "$(curl -s "$BASE/readyz" | head -c 120)"
# S1c /version 已收归管理员（2026-10-06 攻击面收缩：版本披露辅助 CVE 匹配），
# 未认证应为 401；带 admin token 可读（TOK 在 S3 段取得，此处先做未认证断言）
V=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/version")
[ "$V" = "401" ] && ok "S1c version 未认证 401" || bad "S1c version 未认证 401" "$V"

# S2 openapi.json 运行时生成
OA=$(curl -s "$BASE/openapi.json")
printf '%s\n' "$OA" | grep -q '"/share/metadata/{code}"' && ok "S2a openapi 含 metadata 端点" || bad "S2a openapi metadata" "-"
printf '%s\n' "$OA" | grep -q '"/admin/local-files"' && ok "S2b openapi 含 local-files 端点" || bad "S2b openapi local-files" "-"
N=$(printf '%s\n' "$OA" | J "len(d['paths'])")
case "$N" in JERR*|"") bad "S2c openapi paths 数" "$N";; [0-9]*) [ "$N" -ge 90 ] && ok "S2c openapi paths=$N" || bad "S2c openapi paths=$N" "<90";; esac

# S3 /api/config
AC=$(curl -s "$BASE/api/config")
printf '%s\n' "$AC" | J "d['data']['expireStyle']" | grep -q week && ok "S3 api/config 下发 expireStyle" || bad "S3 api/config" "$(printf '%s\n' "$AC" | head -c 100)"
printf '%s\n' "$AC" | J "'showAdminAddr' in d['data']" | grep -q True && ok "S3b showAdminAddr 字段下发" || bad "S3b showAdminAddr" "-"
# S3c/S3d 能力位下发（2026-10-30 能力自描述）：/api/config 必须带 capabilities 段，
# 且 deployment_mode 是三种部署模式之一 —— 前端据此显隐入口，不再各面各写条件判断。
printf '%s\n' "$AC" | J "'capabilities' in d['data']" | grep -q True && ok "S3c api/config 下发 capabilities" || bad "S3c api/config capabilities" "-"
printf '%s\n' "$AC" | J "d['data']['capabilities']['deployment_mode']" | grep -qE '^(standalone|public|admin)$' && ok "S3d capabilities.deployment_mode" || bad "S3d capabilities.deployment_mode" "$(printf '%s\n' "$AC" | head -c 120)"

# S4 admin 登录
# 管理员用户名可覆盖(SMOKE_ADMIN_USER):首启向导允许自定义管理员名,
# 冒烟若硬编码 admin 就测不了非默认用户名(2026-10-22 真机验证踩到)。
TOK=$(curl -s -X POST "$BASE/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"${SMOKE_ADMIN_USER:-admin}\",\"password\":\"${SMOKE_ADMIN_PASSWORD:-admin123}\"}" | J "d['data']['token']")
[ -n "$(curl -s "$BASE/version" -H "Authorization: Bearer $TOK")" ] && ok "S3a0 version admin 可读" || bad "S3a0 version admin 可读" "-"
[ -n "$TOK" ] && [ "${TOK#JERR}" = "$TOK" ] && ok "S4 admin 登录" || bad "S4 admin 登录" "$TOK"
AH="Authorization: Bearer $TOK"
SMOKE_ADMIN_TOKEN="$TOK"; export SMOKE_ADMIN_TOKEN

# S4a/S4b 部署自检端点（2026-10-30）：/admin/diagnostics 是**管理面**端点 ——
# 未认证必须 401（不能给公网开新的信息面）；带 admin token 必须可读且带回
# database/storage 等运行事实（官方 CLI `pb doctor` 消费的就是这一份）。
D_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/admin/diagnostics")
[ "$D_CODE" = "401" ] && ok "S4a /admin/diagnostics 未认证 401" || bad "S4a /admin/diagnostics 未认证 401" "$D_CODE"
D=$(curl -s "$BASE/admin/diagnostics" -H "$AH")
printf '%s\n' "$D" | J "'database' in d['data'] and 'storage' in d['data'] and 'capabilities' in d['data']" | grep -q True && ok "S4b /admin/diagnostics 含 database/storage/capabilities" || bad "S4b /admin/diagnostics 字段" "$(printf '%s\n' "$D" | head -c 120)"
SMOKE_BASE="$BASE"; export SMOKE_BASE

# S4c~S4g API Key 权限范围（scopes，2026-10-30）：受限 Key 访问超范围路径必须 403。
#
# ⚠️ 这是**安全面**的回归守卫：scope 强制一旦被改坏（改成静默放行），后果是
# 「只给寄件权限的 Key 能读用户面」⇒ 用户以为签发的是受限 Key，实际拿到全权。
# 而这种退化**没有任何编译期信号**，只能靠行为断言盯着。
#
# ⚠️ **必须挑真正接受 API Key 的面**（实测踩过）：/admin/config、/user/api-keys
# 是 **JWT-only**（Key 进不去 ⇒ 恒 401），拿它们测 scope 是**测不到 scope 的**。
# API Key 真正能到的面只有三类：
#   · UserOrAPIKey：/api/v1/notifies/**、/api/v1/user/shares/**
#   · AdminOrAdminKey：/admin/p2p/**
#   · OptionalIdentity（带了 Key 就用它鉴权）：/share/**、/chunk/**、/api/v1/presign/**
# 另：/admin/p2p/directory 会去问联邦对端（本地无 p2pd ⇒ 502），只用来断言 403。
SCOPE_KEY=$(curl -s -X POST "$BASE/user/api-keys" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"name":"smoke-scope","scopes":["share"]}' | J "d['data']['key']")
if [ -n "$SCOPE_KEY" ] && ! is_jerr "$SCOPE_KEY"; then
  SC_HDR="X-API-Key: $SCOPE_KEY"
  # ① 缺 user 范围 ⇒ 用户自己的通知面必须 403
  S4C=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/notifies/mine" -H "$SC_HDR")
  [ "$S4C" = "403" ] && ok "S4c 受限 Key 访问用户面 403" || bad "S4c 受限 Key 访问用户面 403" "$S4C"
  # ② 缺 admin 范围 ⇒ 联邦管理面必须 403
  S4D=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/admin/p2p/directory" -H "$SC_HDR")
  [ "$S4D" = "403" ] && ok "S4d 受限 Key 访问联邦管理面 403" || bad "S4d 受限 Key 访问联邦管理面 403" "$S4D"
  # ③ 范围外的路径不受限制（否则受限 Key 连公开面都读不到，范围就失去意义）
  S4E=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/config" -H "$SC_HDR")
  [ "$S4E" = "200" ] && ok "S4e 受限 Key 访问公开面 200（范围外不受限）" || bad "S4e 受限 Key 访问公开面 200" "$S4E"
  # ④ 范围内放行（这把 Key 该能干的活要能干成）
  S4F=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/share/text/" -H "$SC_HDR" \
    -H 'Content-Type: application/json' -d '{"text":"smoke-scope-share","expire_value":1,"expire_style":"day","require_auth":false}')
  [ "$S4F" = "200" ] && ok "S4f 受限 Key 访问寄件面 200（范围内放行）" || bad "S4f 受限 Key 访问寄件面 200" "$S4F"
  # 清理：立刻吊销这把测试 Key（不留凭据在库里的 Test 机器上）
  # ⚠️ 判据必须是「这把 Key **真的被撤销了**」——原先只判「拿得到 id」= 无牙：
  #    删除端点 404 / 权限不对 / 字段改名时照样绿，而库里多留一把**有效的**
  #    share scope Key（真机实录：库里确实攒了几把没被吊销的 smoke-scope）。
  # ⇒ 吊销后**回读列表**按 id 断言 revoked=true（列表**含**已撤销 Key 是设计如此：
  #    软撤销 + 审计留痕，DAO 的 ListByUser 明确「包含已撤销」）。
  SC_ID=$(curl -s "$BASE/user/api-keys" -H "$AH" | J "[k['id'] for k in d['keys'] if k['name']=='smoke-scope'][0]" 2>/dev/null)
  if [ -n "$SC_ID" ] && ! is_jerr "$SC_ID"; then
    curl -s -X DELETE "$BASE/user/api-keys/$SC_ID" -H "$AH" >/dev/null
    SC_REVOKED=$(curl -s "$BASE/user/api-keys" -H "$AH" | J "next((k['revoked'] for k in d['keys'] if k['id']==$SC_ID), None)" 2>/dev/null)
    [ "$SC_REVOKED" = "True" ] && ok "S4g 测试用受限 Key 已吊销（回读 revoked=true）" \
      || bad "S4g 测试用受限 Key 已吊销" "id=$SC_ID 回读 revoked=${SC_REVOKED}（期望 True）"
  else
    bad "S4g 测试用受限 Key 已吊销" "拿不到 id"
  fi
else
  bad "S4c 受限 Key 创建" "拿不到 key（服务端未实现 scopes？）"
fi

# S5 文本分享
CODE_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-hello","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['code']")
[ -n "$CODE_T" ] && ! is_jerr "$CODE_T" && ok "S5 文本分享 code=$CODE_T" || bad "S5 文本分享" "$CODE_T"
# S5b 文本分享响应必须带 6 位取件码（文本/文件同权铸造；前端快捷取件卡依赖，2026-10-15 回归守卫）
PICKUP_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-pickup","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['pickup_code']")
printf '%s\n' "$PICKUP_T" | grep -qE "^[A-Z0-9]{6}$" && ok "S5b 文本分享铸 pickup_code=$PICKUP_T" || bad "S5b 文本分享 pickup_code 缺失" "$PICKUP_T"
# S5c 取件响应文本分享必须回传 share_code（前端跳详情页展示文本依赖，2026-10-15 回归守卫）
SC_T=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_T\"}" | J "d['data']['share_code']")
[ "$SC_T" != "None" ] && [ -n "$SC_T" ] && ! is_jerr "$SC_T" && ok "S5c 取件回传 share_code=$SC_T" || bad "S5c 取件 share_code 缺失" "$SC_T"

# S5d 分享链接形态守卫（2026-10-22 真机定位的「死链」修复）：
# 页面链接必须是 hash 路由 {base}/#/share/{code}——前端是 createWebHashHistory，
# 路径形态 {base}/share/{code} 在浏览器里打不开（docker 端 nginx 反代后端→后端
# 无此路由→404；原生端 SPA 回退的相对资源路径解析错→白屏）。此前后端下发的
# 是路径形态 ⇒ MCP/脚本/IM 机器人拿到的分享链接全是死链（前端有转换兜底，后端没有）。
SHARE_URL_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-url","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['url']")
printf '%s\n' "$SHARE_URL_T" | grep -qE "/#/share/[A-Za-z0-9_-]+$" && ok "S5d 分享链接为 hash 路由形态" || bad "S5d 分享链接形态（须 {base}/#/share/CODE）" "$SHARE_URL_T"

# S5e 取件码可直接当分享页链接用（2026-10-23 新能力）
# 此前取件码（6 位）只能走匿名通道 /anonymous/retrieve 取件，**没有页面链接**——
# 分享页路由 /share/:code → /share/select/?code= 只认 8 位分享码（file_codes.code），
# 拿取件码去查必然 404。现在分享域「按码取分享」同时认 6 位取件码（真相源
# file_codes.pickup_code 列）⇒ /#/share/{取件码} 可直接打开取件页。
PSEL=$(curl -s "$BASE/share/select/?code=$PICKUP_T")
PSHARE=$(printf '%s\n' "$PSEL" | J "d['data'].get('code')")
[ -n "$PSHARE" ] && [ "$PSHARE" != "None" ] && [ ${#PSHARE} -eq 8 ] \
  && ok "S5e 取件码可当分享页链接（归一为 8 位分享码 ${PSHARE}）" \
  || bad "S5e 取件码应能经分享域解析" "$(printf '%s\n' "$PSEL" | head -c 120)"

# S6 metadata（text）
MD=$(curl -s "$BASE/share/metadata/$CODE_T")
[ "$(printf '%s\n' "$MD" | J "d['data']['type']")" = "text" ] && ok "S6a metadata type=text" || bad "S6a metadata text" "$MD"
[ "$(printf '%s\n' "$MD" | J "d['data']['has_password']")" = "False" ] && ok "S6b metadata has_password=false" || bad "S6b metadata" "$MD"
printf '%s\n' "$MD" | grep -q "smoke-text-hello" && bad "S6c metadata 泄露文本内容!" "$MD" || ok "S6c metadata 不外泄内容"

# S7 select 查询不扣次数 + 下载（次数=1 的分享，查询 3 次后仍可下载）
CODE_1=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"once-only","expire_value":1,"expire_style":"count","require_auth":false}' | J "d['data']['code']")
SEL=$(curl -s "$BASE/share/select/?code=$CODE_1")
DL=$(printf '%s\n' "$SEL" | J "d['data']['download_url']"); case "$DL" in /*) DL="$BASE$DL";; esac
for _ in 1 2 3; do curl -s "$BASE/share/select/?code=$CODE_1" >/dev/null; done
BODY=$(curl -s "$DL")
printf '%s\n' "$BODY" | grep -q "once-only" && ok "S7 select 不扣次数+令牌下载" || bad "S7 下载" "$(printf '%s\n' "$BODY" | head -c 80)"

# S8 密码分享
CODE_P=$(curl -s -X POST "$BASE/share/text/" -F "text=secret-pwd" -F "expire_value=1" -F "expire_style=day" -F "require_auth=true" -F "password=pw123" | J "d['data']['code']")
[ "$(curl -s "$BASE/share/metadata/$CODE_P" | J "d['data']['has_password']")" = "True" ] && ok "S8a 密码分享 metadata has_password" || bad "S8a has_password" "-"
# S8b 无密码查询被拒：**必须断 HTTP 401 + 业务码 20003**。
# ⚠️ 2026-10-26 审计：原断言是 `grep -q "密码\|password"` —— 成功响应里也有
# `has_password` 字段、拒答响应里也有 ⇒ **两种情形都命中 ⇒ 断言恒 PASS**
# ⇒ 密码面被整体绕过时冒烟仍全绿。判据改为状态码 + 业务码。
S8B_HTTP=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/share/select/?code=$CODE_P")
S8B_BIZ=$(curl -s "$BASE/share/select/?code=$CODE_P" | J "d.get('code')")
[ "$S8B_HTTP" = "401" ] && [ "$S8B_BIZ" = "20003" ] && ok "S8b 无密码查询被拒(401/20003)" || bad "S8b 无密码查询未拒" "http=${S8B_HTTP} biz=${S8B_BIZ}（期望 401/20003）"
# S8c 带密码取件：密码经 X-Share-Password 请求头传（core v0.24.0 起的唯一通道）
curl -s -H "X-Share-Password: pw123" "$BASE/share/select/?code=$CODE_P" | grep -q "download_url" && ok "S8c 带密码头查询通过" || bad "S8c 带密码头查询" "-"
# S8d 旧 ?password= 通道必须已废：query 形态有访问日志/浏览器历史/Referer 泄漏面
OLD=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/share/select/?code=$CODE_P&password=pw123")
[ "$OLD" = "401" ] && ok "S8d 旧 ?password= 通道已废(401)" || bad "S8d 旧密码通道应拒" "$OLD"
# S8e 密码分享的两种入口（8 位分享码 / 6 位取件码）**共享同一把爆破预算**
# 缺陷（2026-10-23 审计）：失败记账曾用**用户原始入参** ⇒ 两种入口各有一把钥匙
# ⇒ 同一个分享的密码爆破预算翻倍（把 6 位码打满锁定，8 位码仍是全新预算）。
# 判据：把 6 位取件码的预算打满（阈值 10）⇒ 8 位分享码必须已被锁（429）。
LOCKRESP=$(curl -s -X POST "$BASE/share/text/" -F "text=secret-lock" -F "expire_value=1" -F "expire_style=day" -F "require_auth=true" -F "password=pw123")
LOCKC=$(printf '%s\n' "$LOCKRESP" | J "d['data']['code']")
LOCKP=$(printf '%s\n' "$LOCKRESP" | J "d['data']['pickup_code']")
if [ -n "$LOCKC" ] && [ "$LOCKC" != "None" ] && [ -n "$LOCKP" ] && [ "$LOCKP" != "None" ]; then
  _i=0
  while [ $_i -lt 12 ]; do
    curl -s -o /dev/null -H "X-Share-Password: wrong-$_i" "$BASE/share/select/?code=$LOCKP"
    _i=$((_i + 1))
  done
  LOCKH=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Share-Password: wrong-x" "$BASE/share/select/?code=$LOCKC")
  [ "$LOCKH" = "429" ] && ok "S8e 两入口共享密码爆破预算（8 位码随 6 位码被锁）" || bad "S8e 两入口爆破预算未共享" "http=$LOCKH"
else
  skip "S8e 爆破预算共享（未取到密码分享的两种码）" "-"
fi

# S9 文件上传 + metadata + Range
CODE_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" | J "d['data']['code']")
[ -n "$CODE_F" ] && ! is_jerr "$CODE_F" && ok "S9a 文件分享 code=$CODE_F" || bad "S9a 文件分享" "$CODE_F"
# S9a2 文件分享响应带 6 位取件码 + select 带 download 令牌（契约字段齐套回归守卫）
PICKUP_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" | J "d['data']['pickup_code']")
printf '%s\n' "$PICKUP_F" | grep -qE "^[A-Z0-9]{6}$" && ok "S9a2 文件分享铸 pickup_code=$PICKUP_F" || bad "S9a2 文件分享 pickup_code" "$PICKUP_F"
# S9a3 文件分享取件 share_code 恒空（契约：share_code 仅文本分享回传，文件走 download_url）
# 注意用 .get()：文件分享的响应里该键是「不存在」而非 null，取不到时 J 助手返回
# "None"（旧写法 d['data']['share_code'] 遇缺键抛 KeyError → 断言恒假）
[ "$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_F\"}" | J "d.get('data',{}).get('share_code')")" = "None" ] && ok "S9a3 文件取件 share_code 恒空(契约)" || bad "S9a3 文件取件不应回传 share_code" "-"
[ "$(curl -s "$BASE/share/metadata/$CODE_F" | J "d['data']['name']")" = "smoke-range.txt" ] && ok "S9b metadata 文件名" || bad "S9b metadata name" "-"
DLF=$(curl -s "$BASE/share/select/?code=$CODE_F" | J "d['data']['download_url']"); case "$DLF" in /*) DLF="$BASE$DLF";; esac
R=$(curl -s -H "Range: bytes=0-4" -o /dev/null -w "%{http_code}" "$DLF")
[ "$R" = "206" ] && ok "S9c Range 206" || bad "S9c Range" "$R"
PART=$(curl -s -H "Range: bytes=0-4" "$DLF")
[ "$PART" = "hello" ] && ok "S9d Range 内容正确" || bad "S9d Range 内容" "$PART"

# S10 多文件直传 + zip
CODE_M=$(curl -s -X POST "$BASE/api/v1/share/multi-direct" -F "files=@$SMOKE/src/m1.txt" -F "files=@$SMOKE/src/m2.txt" -F "expire_value=1" -F "expire_style=day" | J "d['data']['code']")
[ -n "$CODE_M" ] && ! is_jerr "$CODE_M" && ok "S10a 多文件分享 code=$CODE_M" || bad "S10a 多文件" "$CODE_M"
# S10a2 select 的 download_url 必须带签名令牌（缺令牌直链 401——历史事故回归守卫）
curl -s "$BASE/share/select/?code=$CODE_M" | grep -q "token=" && ok "S10a2 select 带下载令牌" || bad "S10a2 下载令牌缺失" "-"
DLM=$(curl -s "$BASE/share/select/?code=$CODE_M" | J "d['data']['download_url']"); case "$DLM" in /*) DLM="$BASE$DLM";; esac
curl -s "$DLM" -o "$SMOKE/dl.zip"
"$PY" -c "
import zipfile,sys
z = zipfile.ZipFile('$SMOKE/dl.zip')
names = z.namelist()
assert len(names) == 2, names
assert z.read(names[0]).rstrip(b'\n') in (b'multi-file-one', b'multi-file-two')
print('ZIP-OK')
" 2>/dev/null && ok "S10b 多文件 zip 2 entries" || bad "S10b zip" "$("$PY" -c "import sys;d=open(sys.argv[1],'rb').read(4);print('PK-magic-ok' if d[:2]==b'PK' else repr(d))" "$SMOKE/dl.zip" 2>/dev/null | head -c 80)"

# S11 chunk 分片上传完整闭环 + 完成后秒传
# 随机 upload_id：od 在部分 busybox 环境缺失 ⇒ 用 sha256sum 取前 32 位十六进制
UPID=$(head -c 16 /dev/urandom | sha256sum | cut -c1-32)
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
INIT=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
UPID=$(printf '%s\n' "$INIT" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UPID/0" -F "chunk=@$SMOKE/src/big-a.txt" > /dev/null
CMP=$(curl -s -X POST "$BASE/chunk/upload/complete/$UPID" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}')
CMP_CODE=$(printf '%s\n' "$CMP" | J "d['data']['share_code']")
case "$CMP_CODE" in
  JERR*|"") CMP_CODE=$(printf '%s\n' "$CMP" | J "d['data']['code']") ;;
esac
[ -n "$CMP_CODE" ] && ! is_jerr "$CMP_CODE" && ok "S11a 分片完成→建分享 code=$CMP_CODE" || bad "S11a chunk complete" "$(printf '%s\n' "$CMP" | head -c 120)"
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
QI=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
# S11b 秒传限「同用户内」去重（2026-10-12 D1 拍板）：跨用户匹配是存在性 oracle
# （持候选文件者可撞库探测"本站是否有人传过该文件"），故匿名上传不可能命中——
# 匿名侧断言"不命中"，同用户命中放到 S13e（那里有登录态）。
# S11b 秒传限同用户内：匿名侧**不命中**，且 **init 本身必须成功**。
# ⚠️ 2026-10-26 审计：原断言是「结果 != True」——init 报错时 d['data'] 抛 KeyError
# ⇒ J 返回 "JERR:…" ⇒ 「!= True」成立 ⇒ **报错也算 PASS ⇒ 恒真**。
# ⇒ 真实事故：core v0.32.15 修的「同一文件在会话被清理后必然无法分片上传」
#   （init 撞唯一索引报 10008）就是被这条恒真断言放过的。
#   改判后：**重跑冒烟撞上已清理的旧会话 ⇒ init 失败 ⇒ 本条变红**（可复现）。
S11B_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
S11B_UID=$(printf '%s\n' "$QI" | J "d['data'].get('upload_id')")
S11B_QUICK=$(printf '%s\n' "$QI" | J "d['data'].get('is_quick_upload')")
if [ "$S11B_CODE" = "200" ] && [ -n "$S11B_UID" ] && ! is_jerr "$S11B_UID" && [ "$S11B_QUICK" != "True" ]; then
  ok "S11b 秒传限同用户(匿名不命中) 且 init 成功 upload_id=$(printf '%s' "$S11B_UID" | cut -c1-12)…"
else
  bad "S11b 秒传判定/init" "http=${S11B_CODE} uid=${S11B_UID} quick=${S11B_QUICK}（期望 200/非空/非 True）"
fi
# S11b2 同一 file_hash 二次 init（= 同一 upload_id）必须**仍可用**：
# 分片会话「复活」语义（core v0.32.15）——同一文件重传走同一会话键，
# 旧会话被清理后须能复活而不是撞唯一索引。此处断言「拿到的 upload_id 非空且
# 该会话仍能继续收分片」。
S11B2_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
[ "$S11B2_HTTP" = "200" ] && ok "S11b2 同一 file_hash 二次 init 成功(会话可复用)" || bad "S11b2 二次 init" "http=${S11B2_HTTP}（期望 200；10008=撞唯一索引⇒会话复活失效）"

# S11c/d 分片期望哈希强校验（hash 参数：不符 422 可重试 / 相符放行）
# ⚠️ bad-chunk.bin 已在文件准备段生成（**每轮唯一内容**）——此处不要再覆写，
#   否则会话键又变回固定值 ⇒ 跨轮次撞「他人进行中的会话」⇒ 假红。
HBAD=$(printf 'a%.0s' $(seq 1 64))
INIT2=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"bad-chunk.bin\",\"file_size\":1024,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$(sha256sum "$SMOKE/src/bad-chunk.bin" | cut -d' ' -f1)\"}")
UP2=$(printf '%s\n' "$INIT2" | J "d['data']['upload_id']")
BADR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HBAD" -F "chunk=@$SMOKE/src/bad-chunk.bin")
[ "$BADR" = 422 ] && ok "S11c 期望哈希不符拒收(422)" || bad "S11c 哈希校验" "$BADR"
HOK=$(sha256sum "$SMOKE/src/bad-chunk.bin" | cut -d' ' -f1)
OKR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HOK" -F "chunk=@$SMOKE/src/bad-chunk.bin")
[ "$OKR" = 200 ] && ok "S11d 正确 SHA-256 放行" || bad "S11d 正确哈希" "$OKR"

# S11f/g 分片通道下发的分享链接形态守卫（2026-10-23 跨仓审计）。
# 缺陷实录：complete 与秒传两个出口都把下载令牌拼在 hash 形态链接之后 ⇒
# 产出 {base}/#/share/CODE?token=xx —— 令牌落进 fragment：服务端收不到
# （'#' 之后不在请求行里）、分享页前端也不读 route.query.token ⇒ 令牌形同
# 虚设却让集成方以为「带令牌能直下」。
# 判据：页面链接是 hash 路由形态，且**不带任何 query**。
CMP_URL=$(printf '%s\n' "$CMP" | J "d['data'].get('share_url')")
case "$CMP_URL" in
  *'/#/share/'*) ok "S11f 分片分享链接为 hash 路由形态" ;;
  *) bad "S11f 分片分享链接形态（须 {base}/#/share/CODE）" "$CMP_URL" ;;
esac
case "$CMP_URL" in
  *'?'*) bad "S11g 分片分享链接不得带 query（令牌会落进 fragment）" "$CMP_URL" ;;
  *) ok "S11g 分片分享链接不带 query" ;;
esac

# S12 管理端本地文件
#
# 幂等化（2026-10-22 真机反复跑暴露）：S12d 会删掉被测文件 local-nas.txt，
# 脚本重跑时该文件已不存在 ⇒ S12a/b/c 全线假红（"根目录不可访问"），
# 看起来像产品坏了，其实是被测数据被上一轮删了。
# ⇒ 跑之前自己把被测文件准备好。
# SMOKE_IMPORT_DIR = 宿主机上挂进容器 import 根的目录（默认 $SMOKE/import）。
# 外置实例且该目录不可写时，会明确提示前置条件，而不是让断言误导。
SMOKE_IMPORT_DIR="${SMOKE_IMPORT_DIR:-$SMOKE/import}"
SMOKE_IMPORT_WROTE=0
LF=$(curl -s "$BASE/admin/local-files?root=0" -H "$AH")
# ★ 客户端写入目录**必须与服务端声明的 roots 是同一个目录** —— 否则服务端看不到
#   文件 ⇒ import 报"路径不可访问" ⇒ 一串假红。
#   2026-10-30 fnOS 真机实录：脚本写自己的 $SMOKE/import，服务端 roots 却是
#   /vol1/@appshare/... 之类 ⇒ 两侧不是同一目录 ⇒ S12b/c/d 三个假红
#   （本机 local_import 明明是开着的、列表接口明明正常）。
#
# ⚠️⚠️ 2026-10-30 真机实录（隔离实例）——「直接采用服务端 roots[0]」有**同名路径
#   陷阱**：roots[0] 是**容器内**路径（如 /data/import），而宿主上**恰好有同名
#   目录**（= 生产实例的 import 挂载点！）⇒ 脚本把测试文件写进了**生产实例的
#   目录**，隔离实例当然看不到 ⇒ S12 四条假红，**且污染了生产数据目录**
#   （真机实测残留 /data/import/local-nas.txt）。
# ⇒ 改成**两个候选都试，判据是「服务端是否真的能看到这个文件」**（不猜路径）：
#   ① 显式声明的 SMOKE_IMPORT_DIR（操作者给的宿主路径，**优先**）
#   ② 服务端声明的 roots[0]（兜底）
#   写完一律回读列表校验；看不到就**清掉刚写的文件**（不留测试文件在别人目录里）
#   再试下一个；两侧都看不到 ⇒ 明确报「客户端目录 ≠ 服务端 roots」。
SRV_ROOT=$(printf '%s\n' "$LF" | J "((d.get('data') or {}).get('roots') or [''])[0]" 2>/dev/null)
case "$SRV_ROOT" in ''|None|null) SRV_ROOT="" ;; esac
SMOKE_IMPORT_TRIED=""
for SMOKE_CAND in "$SMOKE_IMPORT_DIR" "$SRV_ROOT"; do
  [ -n "$SMOKE_CAND" ] || continue
  case " $SMOKE_IMPORT_TRIED " in *" $SMOKE_CAND "*) continue ;; esac
  SMOKE_IMPORT_TRIED="$SMOKE_IMPORT_TRIED $SMOKE_CAND"
  [ -d "$SMOKE_CAND" ] && [ -w "$SMOKE_CAND" ] || continue
  printf 'smoke local import test content\n' > "$SMOKE_CAND/local-nas.txt" 2>/dev/null || continue
  # ⚠️ 必须**重取一次**列表：上面的 $LF 是写文件**之前**的快照 ⇒ 拿它断言
  #   「列表里有刚写的文件」在目录原本为空时必然失败。
  #   2026-10-30 10.10.10.3 真机实录：S12a 恒红（entries 恒为空），而 S12b/c/d
  #   全绿（服务端确实看得到那个文件）⇒ 是判据取样错误，不是产品缺陷。
  LF=$(curl -s "$BASE/admin/local-files?root=0" -H "$AH")
  if printf '%s\n' "$LF" | J "'local-nas.txt' in [e.get('name') for e in ((d.get('data') or {}).get('entries') or [])]" | grep -qx True; then
    SMOKE_IMPORT_WROTE=1
    SMOKE_IMPORT_DIR="$SMOKE_CAND"
    break
  fi
  # 这一侧服务端看不到 ⇒ 清掉刚写的文件（别把测试文件留在别人的目录里），换下一个
  rm -f "$SMOKE_CAND/local-nas.txt" 2>/dev/null
done
# 前置条件判据（2026-10-22 真机全量冒烟时暴露）：
#   ① local_import 能力不可用（未启用/不支持）  → 环境没开该能力 ⇒ SKIP
#   ② 客户端写不进 import 目录（与服务端 root 不可写/不同）⇒ SKIP
#   ③ 客户端与服务端同目录、写入成功，服务端仍看不到 → **真缺陷** ⇒ FAIL
#
# ⚠️ 2026-10-30 真机实录（fnOS 生产实例）：「未启用」原先是**中文串匹配**
# （grep -q "未启用"）⇒ 服务端换措辞/换实现就匹配不上 ⇒ 明明能力不可用
# 却走进断言分支 ⇒ 报 3 个 FAIL（假红），把真缺陷淹没在噪声里。
# ⇒ 改成**结构化探测**：列表接口返回里有没有 entries 键（能力可用就一定有）。
if printf '%s\n' "$LF" | J "'entries' in (d.get('data') or {})" | grep -qx True; then
  if [ "$SMOKE_IMPORT_WROTE" = 0 ]; then
    skip "S12 本地文件导入" "客户端目录与服务端 roots 不是同一个目录（已试：${SMOKE_IMPORT_TRIED:-无}；服务端 roots=$(printf '%s\n' "$LF" | J "((d.get('data') or {}).get('roots') or [])" 2>/dev/null)）——用 SMOKE_IMPORT_DIR 指定该实例在宿主上的 import 目录"
  else
[ "$(printf '%s\n' "$LF" | J "len(d['data']['entries'])")" -ge 1 ] && ok "S12a local-files 列表" || bad "S12a 列表" "$(printf '%s\n' "$LF" | head -c 100)"
CODE_L=$(curl -s -X POST "$BASE/admin/local-files/import" -H "$AH" -H 'Content-Type: application/json' -d "{\"root\":0,\"path\":\"local-nas.txt\",\"expire_value\":1,\"expire_style\":\"day\"}" | J "d['data']['code']")
[ -n "$CODE_L" ] && ! is_jerr "$CODE_L" && ok "S12b 本地文件生成提取码 code=$CODE_L" || bad "S12b 导入" "$CODE_L"
DLL=$(curl -s "$BASE/share/select/?code=$CODE_L" | J "d['data']['download_url']"); case "$DLL" in /*) DLL="$BASE$DLL";; esac
DLHTTP=$(curl -s -o /tmp/dl-s12.txt -w "%{http_code}" "$DLL")
[ "$DLHTTP" = 200 ] && [ -s /tmp/dl-s12.txt ] && ok "S12c 导入分享可下载" || bad "S12c 下载" "$DLHTTP"
DEL=$(curl -s -X DELETE "$BASE/admin/local-files?root=0&path=local-nas.txt" -H "$AH")
printf '%s\n' "$DEL" | J "d['code']" | grep -qxE "0|200" && ok "S12d 本地文件删除" || bad "S12d 删除" "$DEL"
curl -s "$BASE/admin/local-files?root=0&dir=../../etc" -H "$AH" | grep -qi "非法\|越界\|不在" && ok "S12e 路径穿越被拒" || bad "S12e 穿越防护" "-"
  fi
elif printf '%s\n' "$LF" | grep -q "未启用"; then
    skip "S12 本地文件导入" "local_import 未启用（外置实例前置条件）"
else
  skip "S12 本地文件导入" "local_import 能力不可用（列表接口未返回 entries）"
fi

# S13 寄件码（管理端开注册→用户注册→建链接→访客投递）
# 生产模板默认关注册(安全默认)，故先走管理端配置 API 开启——顺带真测该端点
#
# ⚠️ 2026-10-26 审计（P0，已修）：本段会**改动目标实例的用户配置**
# （开放注册 + 上传上限压到 50MB + 存储配额压到 1GB）⇒ 必须「读原值 → 改 →
# 断言 → 还原原值」，且**还原失败必须计入 FAIL**。
# 三条约束（缺一即事故，2026-10-26 审计实录）：
#   ① 读原值失败/缺键 ⇒ **不许改**（改了还原不回来）⇒ FAIL 并跳过改动；
#   ② 还原走 scripts/smoke-user-config-restore.sh：写回后**回读比对**，
#      不一致即 FAIL（旧实现三条静默逃逸口：读失败→return 0 / 解析失败→
#      sys.exit(0) / PUT 失败→只 print WARNING，**都不影响 FAIL 计数**）；
#   ③ 还原挂进 trap EXIT/INT/TERM ⇒ Ctrl-C / 超时中断也会还原。
USER_CFG_SNAP="$SMOKE/user-config-before.json"
curl -s "$BASE/admin/config/user" -H "$AH" > "$USER_CFG_SNAP"
if user_cfg_snapshot_ok "$USER_CFG_SNAP"; then
  ok "S13-0a 读取原用户配置(4 键齐全,可安全还原)"
  # 2026-10-30：**改配置之前**先确认两件事——
  #   ① "改完能还原"（restore_capable）：没有还原手段 ⇒ 宁可**不改**，
  #      也不把目标实例留在降级态（开放注册开着 + 配额压到 1GB）。
  #   ② "快照本身不是上次残留"（user_cfg_snapshot_degraded）：快照命中冒烟的
  #      病态临时值 ⇒ 上一轮冒烟还原失败过 ⇒ 报 FAIL 并拒绝继续
  #      （否则会把坏状态当原值，又"还原"成坏状态还报绿）。
  if user_cfg_snapshot_is_degraded "$USER_CFG_SNAP"; then
    bad "S13-0b 快照疑似上次冒烟的降级残留" "$(head -c 160 "$USER_CFG_SNAP")——**不改配置**；请先手工把用户配置恢复到正常值（开放注册应为 false、配额/上传上限按业务定），否则冒烟会把降级态当原值反复固化"
  elif ! restore_capable; then
    bad "S13-0c 还原能力不可用" "同目录无 smoke-user-config-restore.sh 且无 python 内联兜底 ⇒ **不改配置**(改了就还原不回来)"
  else
    USER_CFG_RESTORE_PENDING=1
    UCFG=$(curl -s -X PUT "$BASE/admin/config/user" -H "$AH" -H 'Content-Type: application/json' \
      -d "{\"allowuserregistration\":$SMOKE_CFG_REG,\"useruploadsize\":$SMOKE_CFG_UPLOAD,\"userstoragequota\":$SMOKE_CFG_QUOTA,\"sessionexpiryhours\":$SMOKE_CFG_SESSION}")
    printf '%s\n' "$UCFG" | J "d['code']" | grep -qxE "0|200" && ok "S13-0 管理端开启注册(用户配置 API)" || bad "S13-0 用户配置 API" "$(printf '%s\n' "$UCFG" | head -c 100)"
  fi
else
  bad "S13-0a 读取原用户配置失败(不可解析/缺键)" "$(head -c 120 "$USER_CFG_SNAP")——**不改配置**(改了就还原不回来)"
fi
curl -s -X POST "$BASE/user/register" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345","nickname":"smoker","email":"smoker@example.com"}' >/dev/null
UTOK=$(curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345"}' | J "d['data']['token']")
[ -n "$UTOK" ] && ! is_jerr "$UTOK" && ok "S13a 用户注册登录" || bad "S13a 用户登录" "$UTOK"
REQ=$(curl -s -X POST "$BASE/api/v1/user/requests" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"title":"smoke-req","expire_value":1,"expire_style":"day"}')
RTOK=$(printf '%s\n' "$REQ" | J "d['data']['token']")
[ -n "$RTOK" ] && ! is_jerr "$RTOK" && ok "S13b 建寄件链接 token" || bad "S13b 寄件链接" "$REQ"
# S13c 访客可取链接信息：断**标题的实际取值**（原断言 grep "title" 只是键名，
# 键恒在 ⇒ 恒真）+ 断业务码为成功。
S13C_BODY=$(curl -s "$BASE/request/$RTOK")
S13C_BIZ=$(printf '%s\n' "$S13C_BODY" | J "d.get('code')")
if printf '%s\n' "$S13C_BODY" | grep -q "smoke-req" && [ "$S13C_BIZ" = "0" ]; then
  ok "S13c 访客可取链接信息"
else
  bad "S13c 访客取链接" "biz=${S13C_BIZ}（期望 0 且含标题值 smoke-req）"
fi
GUP=$(curl -s -X POST "$BASE/api/v1/request/$RTOK/upload" -F "files=@$SMOKE/src/m1.txt")
printf '%s\n' "$GUP" | grep -q "投递成功" && ok "S13d 访客投递" || bad "S13d 投递" "$(printf '%s\n' "$GUP" | head -c 100)"

# S13e 同用户秒传命中（秒传去重限「同用户内」——匿名侧见 S11b，这里验命中侧）
# 用独立内容：上传会话按文件 hash 键控，复用 S11 的内容会拿到同一个 upload_id
# （那是会话去重，不是分享秒传），且那份分享属匿名用户(user_id=0)，
# 对登录用户不可见——去重源必须是自己名下的分享。
printf 'u-dedup-%s' "$(date +%s)" > "$SMOKE/src/u-dedup.txt"
UH=$(sha256sum "$SMOKE/src/u-dedup.txt" | cut -d' ' -f1)
USIZE=$(wc -c < "$SMOKE/src/u-dedup.txt" | tr -d ' ')
UUPID=$(curl -s -X POST "$BASE/chunk/upload/init/" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d "{\"file_name\":\"u-dedup.txt\",\"file_size\":$USIZE,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$UH\"}")
UUID=$(printf '%s\n' "$UUPID" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UUID/0" -H "Authorization: Bearer $UTOK" -F "chunk=@$SMOKE/src/u-dedup.txt" > /dev/null
curl -s -X POST "$BASE/chunk/upload/complete/$UUID" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}' > /dev/null
UQI=$(curl -s -X POST "$BASE/chunk/upload/init/" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d "{\"file_name\":\"u-dedup.txt\",\"file_size\":$USIZE,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$UH\",\"expire_value\":1,\"expire_style\":\"day\"}")
[ "$(printf '%s\n' "$UQI" | J "d['data'].get('is_quick_upload')")" = "True" ] && ok "S13e 同用户秒传命中" || bad "S13e 同用户秒传" "$(printf '%s\n' "$UQI" | head -c 120)"

# S14 MCP（Streamable HTTP；官方 SDK 要求 Accept 同时含 application/json 与 text/event-stream）
MCP=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
NT=$(printf '%s\n' "$MCP" | J "len(d['result']['tools'])")
case "$NT" in [0-9]*) [ "$NT" -ge 8 ] && ok "S14 MCP tools=$NT" || bad "S14 MCP tools=$NT" "<8";; *) bad "S14 MCP" "$(printf '%s\n' "$MCP" | head -c 100)";; esac
# S14b MCP 工具调用：结构化出参（structuredContent）应含分享码与分享链接
MCPC=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"share_text","arguments":{"text":"smoke-mcp-check"}}}')
MCODE=$(printf '%s\n' "$MCPC" | J "d['result']['structuredContent']['code']")
MURL=$(printf '%s\n' "$MCPC" | J "d['result']['structuredContent']['share_url']")
[ -n "$MCODE" ] && [ "$MCODE" != "None" ] && [ -n "$MURL" ] && [ "$MURL" != "None" ] \
  && ok "S14b MCP share_text code=$MCODE" || bad "S14b MCP share_text" "$(printf '%s\n' "$MCPC" | head -c 160)"
# S14c MCP 下发的分享链接必须是 hash 路由形态（2026-10-22 真机定位的死链修复）。
# MCP 是这条死链最大的受害者：agent 把 markdown 链接直接甩给人点，路径形态
# （{base}/share/{code}）在浏览器里打不开——docker 端 404、原生端白屏。
case "$MURL" in
  *'/#/share/'*) ok "S14c MCP 分享链接为 hash 路由形态" ;;
  *) bad "S14c MCP 分享链接形态（须 {base}/#/share/CODE）" "$MURL" ;;
esac

# S15 二维码(return_base64 为契约必填;断言=code 精确+PNG base64 魔数 iVBOR)
QR=$(curl -s -X POST "$BASE/qrcode/generate" -H 'Content-Type: application/json' -d "{\"data\":\"$BASE/#/share/$CODE_T\",\"size\":200,\"return_base64\":true}")
{ printf '%s\n' "$QR" | J "d['code']" | grep -qxE "0|200"; } && printf '%s\n' "$QR" | J "d['data']['base64_data']" | grep -qE "^(data:image/png;base64,)?iVBOR" && ok "S15 二维码生成" || bad "S15 二维码" "$(printf '%s\n' "$QR" | head -c 80)"

# S16 匿名口令分享
AG=$(curl -s -X POST "$BASE/anonymous/generate" -H 'Content-Type: application/json' -d '{"file_name":"anon.txt","file_size":12,"expire_value":"1","expire_style":"day"}')
ACODE=$(printf '%s\n' "$AG" | J "d['data']['code']")
[ -n "$ACODE" ] && ! is_jerr "$ACODE" && ok "S16a 匿名码 code=$ACODE" || bad "S16a 匿名生成" "$AG"
curl -s "$BASE/anonymous/search/$ACODE" | grep -qi "anon.txt\|file_name" && ok "S16b 匿名码可检索" || bad "S16b 匿名检索" "-"
# S16c 未上传检索优雅拒绝：断**业务码**（占位分享未绑定文件 ⇒ 20001 分享不存在
# /「分享未完成上传，暂时无法取件」）
# 且**响应体不得回显文件名**。
# ⚠️ 2026-10-26 审计：原断言 grep "...\|code" —— 任何 JSON 包络都含 "code" 键
# ⇒ 成功与失败都命中 ⇒ 恒真。
S16C_BODY=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$ACODE\"}")
S16C_BIZ=$(printf '%s\n' "$S16C_BODY" | J "d.get('code')")
if [ "$S16C_BIZ" = "20001" ] && ! printf '%s\n' "$S16C_BODY" | grep -q "anon.txt"; then
  ok "S16c 未上传检索优雅拒绝(20001 且不回显文件名)"
else
  bad "S16c 未上传检索未优雅拒绝" "biz=${S16C_BIZ}（期望 20001）body=$(printf '%s\n' "$S16C_BODY" | head -c 80)"
fi

# S16d/e 匿名码响应的 url 必须是**分享页链接**（hash 路由形态，与其它端点同口径）
# 演进：① "/share/select/?code={取件码}" ⇒ 坏链 404（select 只认 8 位分享码）
#       ② "/anonymous/search/{取件码}" ⇒ 能访问但是 API 路径（不是给人点的页面）
#       ③ 分享域已认 6 位取件码 ⇒ 取件码有了页面链接 ⇒ 统一给页面链接。
AURL=$(printf '%s\n' "$AG" | J "d['data'].get('url')")
case "$AURL" in
  *'/#/share/'*) ok "S16d 匿名码 url 指向分享页链接" ;;
  *) bad "S16d 匿名码 url 形态（须 {base}/#/share/{code}）" "$AURL" ;;
esac
# 页面链接里的码必须真能在分享域解析（打不开就是死链）：占位分享（文件还没
# 传上来）返回 20001「未完成上传」，已上传返回 0 ⇒ 两者都算"解析到了"。
ACODE2=$(printf '%s\n' "$AURL" | sed 's|.*/#/share/||')
ASELCODE=$(curl -s "$BASE/share/select/?code=$ACODE2" | J "d.get('code')")
{ [ "$ASELCODE" = "0" ] || [ "$ASELCODE" = "20001" ]; } \
  && ok "S16e 匿名码页面链接的码能解析（code=${ASELCODE}）" \
  || bad "S16e 匿名码页面链接解析不到" "$ASELCODE"

# S17 robots
curl -s "$BASE/robots.txt" | grep -q "User-agent" && ok "S17 robots.txt" || bad "S17 robots" "-"

# S18 presign 匿名取件码绑定通道：页面链接形态 + 直链派生
# 缺陷实录（2026-10-23 跨仓审计）：该通道把 **API 路径** "/share/select/?code=XXX"
# 当页面链接返回 ⇒ 前端兜底转成 origin/#/share/select/?code=XXX ⇒ vue-router 把
# "select" 当成分享码 ⇒ 打开就是「分享不存在」；且 presign complete 由此派生出的
# download_url 是垃圾串（"/share/select/?code=XXX/share/download?code=…"）。
# 判据：页面链接 = hash 路由形态 {base}/#/share/{分享码}；直链 = {base}/share/download?code=…
AG2=$(curl -s -X POST "$BASE/anonymous/generate" -H 'Content-Type: application/json' -d '{"file_name":"smoke-presign.bin","file_size":16,"expire_value":"1","expire_style":"day"}')
PCODE=$(printf '%s\n' "$AG2" | J "d['data']['code']")
PINIT=$(curl -s -X POST "$BASE/api/v1/presign/upload" -H 'Content-Type: application/json' -d "{\"file_name\":\"smoke-presign.bin\",\"file_size\":16,\"content_type\":\"application/octet-stream\",\"pickup_code\":\"$PCODE\"}")
PUPID=$(printf '%s\n' "$PINIT" | J "d['data']['upload_id']")
PUURL=$(printf '%s\n' "$PINIT" | J "d['data']['upload_url']")
PUTK=$(printf '%s\n' "$PINIT" | J "d['data']['headers']['X-Upload-Token']")
PPTOK=$(printf '%s\n' "$PINIT" | J "d['data']['token']")
if [ -n "$PUPID" ] && [ -n "$PUURL" ] && [ -n "$PPTOK" ]; then
  # 字节数须与申报一致（服务端校验申报大小）：恰好 16 字节
  printf 'smoke-presign-16' > "$SMOKE/src/presign.bin"
  curl -s -X PUT "$PUURL" -H "X-Upload-Token: $PUTK" --data-binary "@$SMOKE/src/presign.bin" > /dev/null
  PCMP=$(curl -s -X POST "$BASE/api/v1/presign/complete" -H 'Content-Type: application/json' -d "{\"upload_id\":\"$PUPID\",\"token\":\"$PPTOK\"}")
  PURL=$(printf '%s\n' "$PCMP" | J "d['data']['url']")
  PDL=$(printf '%s\n' "$PCMP" | J "d['data']['download_url']")
  case "$PURL" in
    *'/#/share/'*) ok "S18a presign 页面链接为 hash 路由形态" ;;
    *) bad "S18a presign 页面链接形态（须 {base}/#/share/CODE）" "$PURL" ;;
  esac
  case "$PURL" in
    *'/share/select/'*) bad "S18b presign 页面链接不得是 API 路径" "$PURL" ;;
    *) ok "S18b presign 页面链接不是 API 路径" ;;
  esac
  case "$PDL" in
    *'/share/download?code='*) ok "S18c presign 直链可正确派生" ;;
    *) bad "S18c presign 直链形态（须 {base}/share/download?code=…）" "$PDL" ;;
  esac

# S19：管理端配置 PUT 必须按**字段级**合并（2026-10-23 真机实测的静默失效）
# 缺陷实录：PUT {"upload_ex":{"max_file_size":N}} 会把 upload_ex 其余字段清零
# （open_upload=false ⇒ 匿名上传被"关闭"，/share/file/ 立刻 10012）⇒ 看起来只
# 改了一个字段，实际把整段配置弄没了。
S19_MAX_BEFORE=$(curl -s "$BASE/admin/config" -H "$AH" | J "d['data'].get('upload_ex',{}).get('max_file_size',0)")
S19_OPEN_BEFORE=$(curl -s "$BASE/admin/config" -H "$AH" | J "d['data'].get('upload_ex',{}).get('open_upload')")
# ⚠️ S19 前置（2026-10-30 CI 实录）：**upload_ex 段必须已落库**。
# 段不存在时，PUT {"upload_ex":{"max_file_size":N}} 只会**建出你给的字段** ⇒ 其余取零值
# ⇒ open_upload 被"清零" ⇒ 看起来像字段级合并失效，实为**段不存在**的边界
# （真机上该段早已落库 ⇒ 一直 PASS；CI 的全新实例上才暴露 ⇒ 假红）。
# ⇒ 先把 upload_ex 段原样整段回写一次（让它落库），再测字段级合并。
"$PY" - "$BASE" "$TOK" <<'PY'
import json, sys, urllib.request
base, tok = sys.argv[1], sys.argv[2]
H = {'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json'}
try:
    cfg = json.load(urllib.request.urlopen(
        urllib.request.Request(base.rstrip('/') + '/admin/config', headers=H), timeout=15)).get('data') or {}
    up = cfg.get('upload_ex') or {}
    if up:
        urllib.request.urlopen(urllib.request.Request(
            base.rstrip('/') + '/admin/config', data=json.dumps({'upload_ex': up}).encode(),
            headers=H, method='PUT'), timeout=15).read()
except Exception:
    pass
PY
curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' -d '{"upload_ex":{"max_file_size":1024}}' > /dev/null
S19_OPEN_AFTER=$(curl -s "$BASE/admin/config" -H "$AH" | J "d['data'].get('upload_ex',{}).get('open_upload')")
if [ "$S19_OPEN_BEFORE" = "$S19_OPEN_AFTER" ]; then
  ok "S19a 配置 PUT 字段级合并（同段其余字段保留）"
else
  bad "S19a 配置 PUT 清零了同段其它字段" "open_upload before=$S19_OPEN_BEFORE after=$S19_OPEN_AFTER"
fi
# 复原（字段级合并 ⇒ 只动 max_file_size 一个字段）
curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' -d "{\"upload_ex\":{\"max_file_size\":$S19_MAX_BEFORE}}" > /dev/null
S19_MAX_AFTER=$(curl -s "$BASE/admin/config" -H "$AH" | J "d['data'].get('upload_ex',{}).get('max_file_size',0)")
[ "$S19_MAX_BEFORE" = "$S19_MAX_AFTER" ] && ok "S19b 配置 PUT 可按字段复原" || bad "S19b 配置复原失败" "before=$S19_MAX_BEFORE after=$S19_MAX_AFTER"
else
  skip "S18 presign 通道（预签名不可用）" "$(printf '%s\n' "$PINIT" | head -c 120)"
fi

# S20：取件次数**只扣一次** —— 一次取件 = 一个下载令牌（取件会话）（2026-10-24）
# 缺陷实录（两代）：
#   ① 6 位取件码经匿名取件通道取件时，retrieve 自身扣 1 次，随它下发的
#      download_url 下载时又扣 1 次 ⇒ 一次取件扣 2 次（count 样式下次数减半）；
#   ② 扣次点在「每个下载请求」⇒ 多文件分享逐个下载逐个扣 ⇒ 取件次数=1 的多文件
#      分享只能下载第一个文件，而「打包下载」同一个 zip 只扣 1 次。
# 修法（现行语义）：扣次统一发生在**内容交付时**，且**一个下载令牌至多扣 1 次**
#   （多文件逐个下载 / 断点续传 / 重复点击 = 同一次取件）；retrieve 只发凭证不扣次。
# 判据：count=3 的分享，取件+下载后 used_count 必须是 1（修前是 2）。
used_count_of() {
  curl -s "$BASE/admin/files/filter?page=1&page_size=20&keyword=$1" -H "$AH" \
    | J "([x['used_count'] for x in d['data']['items'] if x['code']=='$1'] or ['NA'])[0]"
}

S20A=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"count-once-via-pickup","expire_value":3,"expire_style":"count","require_auth":false}')
S20A_CODE=$(printf '%s\n' "$S20A" | J "d['data']['code']")
S20A_PICK=$(printf '%s\n' "$S20A" | J "d['data'].get('pickup_code')")
S20A_RET=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$S20A_PICK\"}")
S20A_RCODE=$(printf '%s\n' "$S20A_RET" | J "d.get('code')")
S20A_DL=$(printf '%s\n' "$S20A_RET" | J "(d.get('data') or {}).get('download_url') or ''")
if [ "$S20A_RCODE" = "10002" ] || [ "$S20A_RCODE" = "10003" ]; then
  skip "S20a 匿名取件通道（本机要求登录下载）" "code=$S20A_RCODE"
elif [ -n "$S20A_DL" ]; then
  curl -s -o /dev/null "$BASE$S20A_DL"
  S20A_USED=$(used_count_of "$S20A_CODE")
  [ "$S20A_USED" = "1" ] \
    && ok "S20a 6 位取件码取件只扣 1 次（used=${S20A_USED}）" \
    || bad "S20a 取件扣次异常" "used_count=${S20A_USED}（期望 1；修前双扣为 2）"
else
  bad "S20a 匿名取件未下发 download_url" "code=$S20A_RCODE"
fi

# S20b 对照组：8 位分享码路径（select 不扣 + download 扣 1）——不得被本次改动带歪
S20B=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"count-once-via-share","expire_value":3,"expire_style":"count","require_auth":false}')
S20B_CODE=$(printf '%s\n' "$S20B" | J "d['data']['code']")
S20B_DL=$(curl -s "$BASE/share/select/?code=$S20B_CODE" | J "d['data'].get('download_url')")
if [ -n "$S20B_DL" ]; then
  curl -s -o /dev/null "$BASE$S20B_DL"
  S20B_USED=$(used_count_of "$S20B_CODE")
  [ "$S20B_USED" = "1" ] \
    && ok "S20b 8 位分享码取件只扣 1 次（used=${S20B_USED}）" \
    || bad "S20b 分享码扣次异常" "used_count=${S20B_USED}（期望 1）"
else
  bad "S20b select 未下发 download_url" "-"
fi

# S21b 取件明细在**留存期内**必须查得到（2026-10-24 修「明细只存在 1 小时」）
# 缺陷：取件记录表的清理窗口跟着下载令牌 TTL 走（TTL+1h ≈ 1 小时 17 分）⇒
# owner 第二天打开取件历史，明细全空 ⇒ 「逐条取件历史」形同虚设。
# 判据：取件一次后，明细里必须有 1 条（IP 非空）。
S21B_CODE=$(printf '%s\n' "$S20A" | J "d['data']['code']")
S21B_INFO=$(curl -s "$BASE/api/v1/user/shares?page=1&page_size=20&search=$S21B_CODE" -H "$AH" \
  | J "(lambda p: ('%d|%s' % (len(p), p[0].get('ip','') if p else '')))((d['data']['items'][0].get('pickups') or []) if (d.get('data') or {}).get('items') else [])")
S21B_N=${S21B_INFO%%|*}
S21B_IP=${S21B_INFO#*|}
if [ "$S21B_N" -ge 1 ] 2>/dev/null && [ -n "$S21B_IP" ]; then
  ok "S21b 取件明细留存期内可见（n=${S21B_N} ip=${S21B_IP}）"
else
  bad "S21b 取件明细缺失" "n=${S21B_N:-0} ip=${S21B_IP:-}（明细应可查）"
fi

# S22 文本分享：刷新页面**不重复扣次**（2026-10-24 回归修复）
# 缺陷：文本分享改成「交付即扣次」后计次键取的是每次 select 新签发的令牌指纹 ⇒
# 刷新一次 = 一次新令牌 = 扣一次 ⇒ 收件人刷新两次就把额度吃光、第三次直接
# 403「超过取件次数」——**正文都看不到**（改动前 select 从不扣次）。
# 修复：文本交付面的计次键 = (分享码, 取件人 IP) ⇒ 同一取件人重复打开只扣 1 次。
S22=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"text-refresh-once","expire_value":2,"expire_style":"count","require_auth":false}')
S22_CODE=$(printf '%s\n' "$S22" | J "d['data']['code']")
curl -s -o /dev/null "$BASE/share/select/?code=$S22_CODE"
curl -s -o /dev/null "$BASE/share/select/?code=$S22_CODE"
S22_USED=$(used_count_of "$S22_CODE")
[ "$S22_USED" = "1" ] \
  && ok "S22 文本分享刷新两次只扣 1 次（used=${S22_USED}）" \
  || bad "S22 文本分享重复扣次" "used_count=${S22_USED}（期望 1；修前为 2）"

# S21 逐条取件明细（2026-10-24 新增）：owner 侧能看到逐条取件记录
# 判据：一次取件 = 一行（IP + 时间 + 交付面）；多文件逐个下载/断点续传属同一次取件
# ⇒ 不会被显示成「取件 N 次」（此前只有「最后 IP + 计数」⇒ 看不出来）。
# 单次 J 调用取两个值（J 的输出是 Python repr，不能再喂回 JSON 解析）
S21_INFO=$(curl -s "$BASE/api/v1/user/shares?page=1&page_size=20&search=$S20B_CODE" -H "$AH" \
  | J "(lambda p: ('%d|%s' % (len(p), p[0].get('ip','') if p else '')))((d['data']['items'][0].get('pickups') or []) if (d.get('data') or {}).get('items') else [])")
S21_N=${S21_INFO%%|*}
S21_IP=${S21_INFO#*|}
if [ "$S21_N" = "1" ] && [ -n "$S21_IP" ]; then
  ok "S21 逐条取件明细：一次取件 = 一行（n=${S21_N} ip=${S21_IP}）"
else
  bad "S21 逐条取件明细异常" "n=${S21_N}（期望 1）ip=${S21_IP}"
fi

# S20c 文本分享：select 交付正文 ⇒ 扣 1 次（此前 select 全文返回却从不扣次
# ⇒ owner 设的「按取件次数」上限对文本分享形同虚设）
S20C=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"count-once-text-share","expire_value":3,"expire_style":"count","require_auth":false}')
S20C_CODE=$(printf '%s\n' "$S20C" | J "d['data']['code']")
curl -s -o /dev/null "$BASE/share/select/?code=$S20C_CODE"
S20C_USED=$(used_count_of "$S20C_CODE")
[ "$S20C_USED" = "1" ] \
  && ok "S20c 文本分享取件扣 1 次（used=${S20C_USED}）" \
  || bad "S20c 文本分享扣次异常" "used_count=${S20C_USED}（期望 1；修前恒为 0）"

# S20d 末次取件必须拿得到文件（count=1）：走取件码通道
# 缺陷实录：retrieve 先把次数扣到 0 ⇒ IsExpired 判过期 ⇒ 随后的下载 404 ⇒
# **按取件次数的分享，最后一次取件永远拿不到文件**（分享页通道却能拿到）。
S20D=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"last-pickup-delivers","expire_value":1,"expire_style":"count","require_auth":false}')
S20D_CODE=$(printf '%s\n' "$S20D" | J "d['data']['code']")
S20D_PICK=$(printf '%s\n' "$S20D" | J "d['data'].get('pickup_code')")
S20D_RET=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$S20D_PICK\"}")
S20D_RCODE=$(printf '%s\n' "$S20D_RET" | J "d.get('code')")
S20D_DL=$(printf '%s\n' "$S20D_RET" | J "(d.get('data') or {}).get('download_url') or ''")
if [ "$S20D_RCODE" = "10002" ] || [ "$S20D_RCODE" = "10003" ]; then
  skip "S20d 末次取件（本机要求登录下载）" "code=$S20D_RCODE"
elif [ -n "$S20D_DL" ]; then
  S20D_HTTP=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$S20D_DL")
  S20D_USED=$(used_count_of "$S20D_CODE")
  [ "$S20D_HTTP" = "200" ] && [ "$S20D_USED" = "1" ] \
    && ok "S20d 末次取件拿到文件（http=${S20D_HTTP} used=${S20D_USED}）" \
    || bad "S20d 末次取件异常" "http=${S20D_HTTP}（期望 200；修前为 404 已过期）used=${S20D_USED}（期望 1）"
else
  bad "S20d 匿名取件未下发 download_url" "code=$S20D_RCODE"
fi

# ===== S23 「次数耗尽」的四个面闸门（2026-10-24，core v0.32.4）=====
# 缺陷：model.FileCode.IsExpired() 拆分前含次数语义 ⇒ 以它为闸的门同时挡着
# 「次数耗尽」；拆分后四个面漏了这道闸 ⇒ owner 的「取件 N 次」上限被绕过：
#   · /share/metadata     仍回显文件名/大小（旧口径 404）
#   · /anonymous/search   仍回显文件名/大小（旧口径 404）
#   · MCP get_share_content / download_share_file 仍回传正文/文件内容
# 判据：额度用完后这些面必须**拒绝**（并给独立错误码，不再伪装「不存在/已过期」）。

# S23a /share/metadata：count=1 的文本分享，取件一次耗尽额度 ⇒ metadata 必须拒
S23A=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"meta-after-exhausted","expire_value":1,"expire_style":"count","require_auth":false}')
S23A_CODE=$(printf '%s\n' "$S23A" | J "d['data']['code']")
# 先查一次（额度未用完 ⇒ 应正常）
S23A_BEFORE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/share/metadata/$S23A_CODE")
# 取件一次 ⇒ 额度耗尽
curl -s -o /dev/null "$BASE/share/select/?code=$S23A_CODE"
S23A_AFTER=$(curl -s "$BASE/share/metadata/$S23A_CODE")
S23A_CODE_BIZ=$(printf '%s\n' "$S23A_AFTER" | J "d.get('code')")
if [ "$S23A_BEFORE" = "200" ] && [ "$S23A_CODE_BIZ" = "20004" ]; then
  ok "S23a metadata 面：额度耗尽后拒（20004 超过取件次数）"
else
  bad "S23a metadata 面未守次数闸" "before_http=${S23A_BEFORE} biz=${S23A_CODE_BIZ}（期望 20004；修前 200 回显元信息）"
fi
if printf '%s\n' "$S23A_AFTER" | grep -q "meta-after-exhausted"; then
  bad "S23a metadata 面泄露文本内容" "$S23A_AFTER"
else
  ok "S23a metadata 面额度耗尽后不回显内容"
fi

# S23b /anonymous/search：同上（取件码通道）
S23B=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"search-after-exhausted","expire_value":1,"expire_style":"count","require_auth":false}')
S23B_CODE=$(printf '%s\n' "$S23B" | J "d['data']['code']")
S23B_PICK=$(printf '%s\n' "$S23B" | J "d['data'].get('pickup_code')")
S23B_BEFORE=$(curl -s "$BASE/anonymous/search/$S23B_PICK")
S23B_BEFORE_CODE=$(printf '%s\n' "$S23B_BEFORE" | J "d.get('code')")
# 消耗掉额度（分享页 select 扣次）
curl -s -o /dev/null "$BASE/share/select/?code=$S23B_CODE"
S23B_AFTER=$(curl -s "$BASE/anonymous/search/$S23B_PICK")
S23B_AFTER_CODE=$(printf '%s\n' "$S23B_AFTER" | J "d.get('code')")
if [ "$S23B_BEFORE_CODE" = "0" ] && [ "$S23B_AFTER_CODE" = "20007" ]; then
  ok "S23b 匿名 search 面：额度耗尽后拒（20007 取件码已用完）"
else
  bad "S23b 匿名 search 面未守次数闸" "before=${S23B_BEFORE_CODE} after=${S23B_AFTER_CODE}（期望 0 → 20007；修前 after 仍为 0 并回显文件名）"
fi

# S23c 预览面：额度耗尽后必须拒（预览也是「拿内容」的面 ⇒ 摘要不该再可见）
# 判据：预览面对耗尽分享回 20004「超过取件次数」（不是 404「不存在/已过期」）。
S23C=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"preview-after-exhausted","expire_value":1,"expire_style":"count","require_auth":false}')
S23C_CODE=$(printf '%s\n' "$S23C" | J "d['data']['code']")
# 消耗掉额度（分享页 select 扣次）
curl -s -o /dev/null "$BASE/share/select/?code=$S23C_CODE"
S23C_RESP=$(curl -s "$BASE/preview/$S23C_CODE")
S23C_CODE_BIZ=$(printf '%s\n' "$S23C_RESP" | J "d.get('code')")
if [ "$S23C_CODE_BIZ" = "20004" ]; then
  ok "S23c 预览面：额度耗尽后拒（20004 超过取件次数）"
else
  bad "S23c 预览面未守次数闸" "biz=${S23C_CODE_BIZ}（期望 20004；修前回落 404/20001）"
fi

# ── S24 存储迁移（4.4.0 旗舰能力：POST /admin/storage/migrate）──────────────
#
# 语义（contracts v0.20.6 + core app/storage/migrate.go）：
#   ① 取件码与分享链接**不变**（只换对象所在后端，DB 一个字节不动）；
#   ② **全部复制成功才切换**（任一失败 ⇒ 不切换 ⇒ 源后端继续在用）；
#   ③ **可中断可续**（目标已存在 ⇒ 跳过）。
#
# 断言分层：
#   S24a/b/c/d —— **无副作用**（同源拒绝 / 不支持类型 / target_path 越界 /
#                dry-run 只算计划）⇒ 对任何实例（含生产）都可跑；
#   S24e      —— **真迁移**（local→local 换目录 ⇒ 搬对象 + 切换）⇒ 会改目标实例的
#                存储后端 ⇒ **只在隔离实例上跑**，用 SMOKE_ALLOW_STORAGE_MIGRATE=1 显式开。
#   判据一律读**结构化字段**（code / data.switched / data.objects），不匹配中文报错文案
#   ——服务端改措辞不该把冒烟打成假红（与 S12 段同纪律）。
CUR_TYPE=$(curl -s "$BASE/admin/storage" -H "$AH" | J "(d.get('data') or {}).get('current') or ''")
MIG_A=$(curl -s -X POST "$BASE/admin/storage/migrate" -H "$AH" -H 'Content-Type: application/json' \
  -d "{\"target_type\":\"${CUR_TYPE}\"}")
MIG_A_CODE=$(printf '%s\n' "$MIG_A" | J "d.get('code')")
if [ -n "$MIG_A_CODE" ] && ! is_jerr "$MIG_A_CODE" && [ "$MIG_A_CODE" != "0" ] && [ "$MIG_A_CODE" != "200" ]; then
  ok "S24a 同源迁移被拒（搬到自己身上无意义）"
else
  bad "S24a 同源迁移应被拒" "code=${MIG_A_CODE} current=${CUR_TYPE}"
fi
MIG_B=$(curl -s -X POST "$BASE/admin/storage/migrate" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"target_type":"__no_such_backend__"}')
MIG_B_CODE=$(printf '%s\n' "$MIG_B" | J "d.get('code')")
if [ -n "$MIG_B_CODE" ] && ! is_jerr "$MIG_B_CODE" && [ "$MIG_B_CODE" != "0" ] && [ "$MIG_B_CODE" != "200" ]; then
  ok "S24b 不支持的存储类型被拒"
else
  bad "S24b 不支持的存储类型应被拒" "code=${MIG_B_CODE}"
fi
MIG_C=$(curl -s -X POST "$BASE/admin/storage/migrate" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"target_type":"s3","target_path":"/tmp/should-be-rejected"}')
MIG_C_CODE=$(printf '%s\n' "$MIG_C" | J "d.get('code')")
if [ -n "$MIG_C_CODE" ] && ! is_jerr "$MIG_C_CODE" && [ "$MIG_C_CODE" != "0" ] && [ "$MIG_C_CODE" != "200" ]; then
  ok "S24c target_path 只对 local 有效（非 local 目标带路径被拒）"
else
  bad "S24c 非 local 目标带 target_path 应被拒" "code=${MIG_C_CODE}"
fi
# dry-run：只算计划不搬 ⇒ switched 必须为 false，且计划里有对象数/字节数
MIG_D=$(curl -s -X POST "$BASE/admin/storage/migrate" -H "$AH" -H 'Content-Type: application/json' \
  -d "{\"target_type\":\"local\",\"target_path\":\"${SMOKE_MIGRATE_TARGET:-/tmp/fcb-smoke/migrate-target}\",\"dry_run\":true}")
MIG_D_SW=$(printf '%s\n' "$MIG_D" | J "(d.get('data') or {}).get('switched')")
MIG_D_OBJ=$(printf '%s\n' "$MIG_D" | J "(d.get('data') or {}).get('objects')")
if [ "$MIG_D_SW" = "False" ] && [ -n "$MIG_D_OBJ" ] && ! is_jerr "$MIG_D_OBJ"; then
  ok "S24d dry-run 只算计划不切换（switched=false objects=${MIG_D_OBJ}）"
else
  bad "S24d dry-run 语义" "switched=${MIG_D_SW} objects=${MIG_D_OBJ}"
fi
# S24e 真迁移：**会改目标实例的存储后端** ⇒ 仅隔离实例可跑（显式开关）
if [ "${SMOKE_ALLOW_STORAGE_MIGRATE:-0}" = "1" ]; then
  MIG_TARGET="${SMOKE_MIGRATE_TARGET:-/tmp/fcb-smoke/migrate-target}"
  MIG_E=$(curl -s -X POST "$BASE/admin/storage/migrate" -H "$AH" -H 'Content-Type: application/json' \
    -d "{\"target_type\":\"local\",\"target_path\":\"${MIG_TARGET}\"}")
  MIG_E_SW=$(printf '%s\n' "$MIG_E" | J "(d.get('data') or {}).get('switched')")
  MIG_E_CP=$(printf '%s\n' "$MIG_E" | J "(d.get('data') or {}).get('copied')")
  MIG_E_FL=$(printf '%s\n' "$MIG_E" | J "(d.get('data') or {}).get('failed')")
  if [ "$MIG_E_SW" = "True" ] && [ "$MIG_E_FL" = "0" ]; then
    ok "S24e 真迁移完成并切换（copied=${MIG_E_CP} failed=0）"
  else
    bad "S24e 真迁移" "switched=${MIG_E_SW} copied=${MIG_E_CP} failed=${MIG_E_FL}"
  fi
  # 切换后：当前后端仍是 local，但 storage_path 指向新目录 ⇒ 存量分享链接仍可下载
  AFTER_TYPE=$(curl -s "$BASE/admin/storage" -H "$AH" | J "(d.get('data') or {}).get('current') or ''")
  [ -n "$AFTER_TYPE" ] && ok "S24f 迁移后存储后端仍可读（current=${AFTER_TYPE}）" \
    || bad "S24f 迁移后读存储信息失败" "-"
else
  skip "S24e 真迁移（改存储后端）" "仅隔离实例可跑（SMOKE_ALLOW_STORAGE_MIGRATE=1）"
fi

# S25 备份包（4.6.0 能力：统一备份包导出 + 恢复校验）
#
# 只做**只读**动作：导出（读 DB/对象）与恢复的 --dry-run（只校验，不落盘）
# ⇒ 不动线上数据。真正的恢复是**破坏性**操作，只在隔离实例上做。
SMOKE_CONTAINER="${SMOKE_CONTAINER:-pigeonbox}"
if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SMOKE_CONTAINER"; then
  skip "S25 备份包" "本机无 docker 或容器 $SMOKE_CONTAINER 不在运行（离线子命令只能在容器内跑）"
else
  S25_PKG=/tmp/pb-smoke-backup.tar.gz
  if docker exec "$SMOKE_CONTAINER" /app/pigeonbox backup export --out "$S25_PKG" >/dev/null 2>&1; then
    if docker cp "$SMOKE_CONTAINER:$S25_PKG" /tmp/pb-smoke-backup.tar.gz >/dev/null 2>&1; then
      S25_LIST=$(tar -tzf /tmp/pb-smoke-backup.tar.gz 2>/dev/null | tr '\n' ' ')
      case "$S25_LIST" in
        *manifest.json*) ok "S25a 备份包导出成功且含 manifest.json" ;;
        *) bad "S25a 备份包缺 manifest.json" "$S25_LIST" ;;
      esac
      S25_FMT=$(tar -xzOf /tmp/pb-smoke-backup.tar.gz manifest.json 2>/dev/null | J "d.get('backup_format')")
      [ "$S25_FMT" = "1" ] && ok "S25b 备份包格式版本可读（backup_format=1）" || bad "S25b 备份包格式版本" "backup_format=${S25_FMT:-读不到}"
      # 恢复的 dry-run：校验 sha256 + DB 快照可打开（**不落盘**）
      if docker cp /tmp/pb-smoke-backup.tar.gz "$SMOKE_CONTAINER:$S25_PKG" >/dev/null 2>&1 &&
         docker exec "$SMOKE_CONTAINER" /app/pigeonbox backup restore --from "$S25_PKG" --dry-run >/dev/null 2>&1; then
        ok "S25c 备份包恢复校验通过（dry-run：逐对象 sha256 + DB 快照可打开）"
      else
        bad "S25c 备份包恢复校验未通过" "dry-run 失败（包损坏/格式不认识/DB 快照打不开）"
      fi
      rm -f /tmp/pb-smoke-backup.tar.gz
      docker exec "$SMOKE_CONTAINER" rm -f "$S25_PKG" >/dev/null 2>&1
    else
      bad "S25a 备份包导出后取不出来" "docker cp 失败"
    fi
  else
    bad "S25a 备份包导出失败" "容器内 backup export 退出码非 0"
  fi
fi

# S25 备份包（4.6.0 能力：统一备份包导出 + 恢复校验）
#
# 只做**只读**动作：导出（读 DB/对象）与恢复的 --dry-run（只校验，不落盘）
# ⇒ 不动线上数据。真正的恢复是**破坏性**操作，只在隔离实例上做。
SMOKE_CONTAINER="${SMOKE_CONTAINER:-pigeonbox}"
if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SMOKE_CONTAINER"; then
  skip "S25 备份包" "本机无 docker 或容器 $SMOKE_CONTAINER 不在运行（离线子命令只能在容器内跑）"
else
  # 二进制与配置都**探**不写死：镜像布局会变（/app/server、/app/pigeonbox…），
  # 写死一个路径 ⇒ 布局一变就假红。
  S25_BIN=""
  for cand in /app/server /app/pigeonbox; do
    if docker exec "$SMOKE_CONTAINER" test -x "$cand" 2>/dev/null; then S25_BIN="$cand"; break; fi
  done
  S25_CFG=""
  for cand in /app/config/config.yaml /app/config/config.prod.yaml; do
    if docker exec "$SMOKE_CONTAINER" test -f "$cand" 2>/dev/null; then S25_CFG="$cand"; break; fi
  done
  if [ -z "$S25_BIN" ]; then
    skip "S25 备份包" "容器内找不到服务端二进制（/app/server、/app/pigeonbox 都没有）"
  elif [ -z "$S25_CFG" ]; then
    skip "S25 备份包" "容器内找不到配置文件（/app/config/config.yaml 等）"
  else
    S25_PKG=/tmp/pb-smoke-backup.tar.gz
    # 离线备份要过**同一套配置校验**（含 jwt_secret）⇒ 把容器里正在用的那份带上，
    # 否则配置初始化直接失败（真机实录：首次跑 S25 就是这么红的）。
    S25_JWT=$(docker exec "$SMOKE_CONTAINER" printenv PB_JWT_SECRET 2>/dev/null)
    if [ -z "$S25_JWT" ]; then
      S25_JWT=$(docker exec "$SMOKE_CONTAINER" cat /app/data/.jwt_secret 2>/dev/null)
    fi
    if [ -n "$S25_JWT" ]; then
      S25_EXEC="docker exec -e PB_JWT_SECRET=$S25_JWT $SMOKE_CONTAINER"
    else
      S25_EXEC="docker exec $SMOKE_CONTAINER"
    fi
    if $S25_EXEC "$S25_BIN" backup export --out "$S25_PKG" --config "$S25_CFG" >/dev/null 2>&1; then
      if docker cp "$SMOKE_CONTAINER:$S25_PKG" /tmp/pb-smoke-backup.tar.gz >/dev/null 2>&1; then
        S25_LIST=$(tar -tzf /tmp/pb-smoke-backup.tar.gz 2>/dev/null | tr '\n' ' ')
        case "$S25_LIST" in
          *manifest.json*) ok "S25a 备份包导出成功且含 manifest.json" ;;
          *) bad "S25a 备份包缺 manifest.json" "$S25_LIST" ;;
        esac
        S25_FMT=$(tar -xzOf /tmp/pb-smoke-backup.tar.gz manifest.json 2>/dev/null | J "d.get('backup_format')")
        [ "$S25_FMT" = "1" ] && ok "S25b 备份包格式版本可读（backup_format=1）" || bad "S25b 备份包格式版本" "backup_format=${S25_FMT:-读不到}"
        # ★ 断言必须有牙：导出的是**活实例**的库与对象 ⇒ 本轮冒烟自己造过分享（S5/S9）
        #   与文件对象 ⇒ 计数必须 ≥1 ⇒ 「导到了空库/错目录」会被当场抓住。
        S25_FILES=$(tar -xzOf /tmp/pb-smoke-backup.tar.gz manifest.json 2>/dev/null | J "d.get('file_count')")
        S25_OBJS=$(tar -xzOf /tmp/pb-smoke-backup.tar.gz manifest.json 2>/dev/null | J "d.get('object_count')")
        if [ "${S25_FILES:-0}" -ge 1 ] 2>/dev/null; then
          ok "S25c 导出的是活实例的库（分享记录 ${S25_FILES} 条 ≥ 1）"
        else
          bad "S25c 导出包里的分享记录为 ${S25_FILES:-?}（本轮冒烟造过分享 ⇒ 应 ≥1 ⇒ 多半导到了空库/错配置）" "file_count=${S25_FILES:-读不到}"
        fi
        if [ "${S25_OBJS:-0}" -ge 1 ] 2>/dev/null; then
          ok "S25d 导出的是活实例的存储对象（对象 ${S25_OBJS} 个 ≥ 1）"
        else
          bad "S25d 导出包里的对象数为 ${S25_OBJS:-?}（本轮冒烟传过文件 ⇒ 应 ≥1 ⇒ 多半导到了错存储目录）" "object_count=${S25_OBJS:-读不到}"
        fi
        # 恢复的 dry-run：校验 sha256 + DB 快照可打开（**不落盘**）
        if docker cp /tmp/pb-smoke-backup.tar.gz "$SMOKE_CONTAINER:$S25_PKG" >/dev/null 2>&1 &&
           $S25_EXEC "$S25_BIN" backup restore --from "$S25_PKG" --dry-run --config "$S25_CFG" >/dev/null 2>&1; then
          ok "S25e 备份包恢复校验通过（dry-run：逐对象 sha256 + DB 快照可打开）"
        else
          bad "S25e 备份包恢复校验未通过" "dry-run 失败（包损坏/格式不认识/DB 快照打不开）"
        fi
        rm -f /tmp/pb-smoke-backup.tar.gz
        docker exec "$SMOKE_CONTAINER" rm -f "$S25_PKG" >/dev/null 2>&1
      else
        bad "S25a 备份包导出后取不出来" "docker cp 失败"
      fi
    else
      bad "S25a 备份包导出失败" "容器内 backup export 退出码非 0"
    fi
  fi
fi

# ── 收尾：还原 S13 改过的用户配置（否则冒烟等于永久改动目标实例配置）────────
# 还原逻辑独立成 scripts/smoke-user-config-restore.sh（写回 + 回读比对，
# 三条静默逃逸口全部改为非零退出码 ⇒ 还原失败计入 FAIL ⇒ 退出码非 0）。
# 正常路径在此调用一次；异常路径（Ctrl-C / 超时 / 中途失败）由 on_exit trap 兜底。
restore_user_config

echo ""
echo "=============================="
echo "SMOKE RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
