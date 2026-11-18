#!/usr/bin/env bash
# API Key e2e 回归：签发 → Key 直传/管理 → 无效/吊销 401（依赖 localhost:12345 空闲 + 默认 admin 密码）
# shellcheck disable=SC2015
# 断言形态「A && echo 成功 || { echo 失败; exit 1; }」：中间的 echo 恒以 exit 0
# 收尾，故不存在 SC2015 担心的「B 失败导致 C 误跑」路径。
set -u

# ── shellkit（E2E 侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
# ⚠️ 库路径按**脚本自身位置**解析（在 cd 之前算好）⇒ cd 进 server/ 后仍指向仓内副本。
HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SK_BOOTSTRAP="$HUB_ROOT/vendor/shellkit/lib/bootstrap.sh"
if [ ! -r "$SK_BOOTSTRAP" ]; then
  echo "✗ 缺 $SK_BOOTSTRAP —— shellkit 没随仓入库" >&2
  echo "  修法: 在 hub 工作区跑 'bash scripts/vendor-shellkit.sh sync --all'" >&2
  exit 5
fi
# shellcheck source=../vendor/shellkit/lib/bootstrap.sh
. "$SK_BOOTSTRAP"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

cd "$HUB_ROOT" || exit 1
cd server || exit 1
mkdir -p data logs

PB_JWT_SECRET=$(openssl rand -hex 32) go run ./cmd/server --config ./configs/config.yaml >/tmp/fcb-e2e.log 2>&1 &
# shellcheck disable=SC2034  # SRV 只在 trap 清理串里被读（shellcheck 看不见单引号串）
SRV=$!
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原手写 trap 等价。
# ⚠️ 原手写 trap 的「成功哨兵」（OK≠1 ⇒ 没跑到结尾 ⇒ 判失败）：本脚本的失败出口
#    都是显式 `exit 1`，成功路径唯一（末尾一句成功日志后自然结束）⇒ 哨兵拆掉后
#    行为等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'if [ -n "${SRV:-}" ]; then kill "${SRV}" 2>/dev/null || true; fi'
trap_install
for _ in $(seq 1 30); do
  curl -sf http://localhost:12345/live >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://localhost:12345/live >/dev/null || {
  log_error "server 未就绪"
  tail -20 /tmp/fcb-e2e.log
  exit 1
}
log_ok "server 就绪"

B=http://localhost:12345
jqq() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }

# 1. admin 登录拿 JWT
JWT=$(curl -sf -X POST $B/admin/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | jqq "['data']['token']")
[ -n "$JWT" ] && log_ok "admin 登录（JWT ${#JWT} 字符）" || {
  log_error "登录失败"
  exit 1
}

# 1.5 清场：吊销历史 Key，避免 5 把上限影响重复执行（旧版本无此端点，忽略失败）
curl -s -o /dev/null -X POST $B/user/api-keys/revoke-all -H "Authorization: Bearer $JWT" || true

# 2. 签发 API Key
RESP=$(curl -sf -X POST $B/user/api-keys -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{"name":"e2e-smoke"}')
KEY=$(echo "$RESP" | jqq "['data']['key']")
KID=$(echo "$RESP" | jqq "['data']['api_key']['id']")
[ -n "$KEY" ] && log_ok "签发 Key：${KEY:0:12}…（id=${KID}）" || {
  log_error "签发失败: $RESP"
  exit 1
}

# 3. Key 直传文本（X-API-Key 头）
R3=$(curl -s -X POST $B/share/text/ -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"text":"api-key e2e smoke","expire_value":1,"expire_style":"hour","require_auth":false}')
echo "$R3" | head -c 200
echo ""
CODE3=$(echo "$R3" | jqq "['code']")
{ [ "$CODE3" = "0" ] || [ "$CODE3" = "200" ]; } && log_ok "Key 直传文本成功" || {
  log_error "Key 直传失败 code=$CODE3"
  exit 1
}

# 4. Bearer pb_sk_ 列举自己的分享（/api/v1 组）
R4=$(curl -s "$B/api/v1/user/shares?page=1&page_size=10" -H "Authorization: Bearer $KEY")
CODE4=$(echo "$R4" | jqq "['code']")
{ [ "$CODE4" = "0" ] || [ "$CODE4" = "200" ]; } && log_ok "Bearer pb_sk_ 列举自己分享成功" || {
  log_error "/api/v1 组 Key 认证失败: $(echo "$R4" | head -c 200)"
  exit 1
}

# 5. 无效 Key 必须 401（fail-closed）
R5=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: ${KEY}bad" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R5" = "401" ] && log_ok "无效 Key 401（fail-closed）" || {
  log_error "无效 Key 返回 $R5"
  exit 1
}

# 6. JWT 吊销 Key
curl -sf -X DELETE "$B/user/api-keys/$KID" -H "Authorization: Bearer $JWT" >/dev/null && log_ok "吊销 Key"

# 7. 吊销后再用 → 401
R7=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: $KEY" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R7" = "401" ] && log_ok "吊销后 Key 401" || {
  log_error "吊销后仍可用：$R7"
  exit 1
}

# 8. 再签发一把（供 revoke-all 与归因验证）
RESP2=$(curl -sf -X POST $B/user/api-keys -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' -d '{"name":"e2e-keep"}')
KEY2=$(echo "$RESP2" | jqq "['data']['key']")
[ -n "$KEY2" ] && log_ok "签发第二把 Key" || {
  log_error "第二把签发失败"
  exit 1
}

# 9. Key2 上传 → transfer_logs.api_key_id 应为该 Key（Key 粒度归因）
curl -s -o /dev/null -X POST $B/share/text/ -H "X-API-Key: $KEY2" \
  -H 'Content-Type: application/json' -d '{"text":"attr","expire_value":1,"expire_style":"hour","require_auth":false}'
sleep 1
ATTR=$(sqlite3 data/fileCodeBox.db "SELECT api_key_id FROM transfer_logs WHERE operation='upload' ORDER BY id DESC LIMIT 1")
[ -n "$ATTR" ] && log_ok "传输日志归因 api_key_id=$ATTR" || {
  log_error "传输日志未落 api_key_id"
  exit 1
}

# 10. 一键吊销全部（JWT-only）
RA=$(curl -sf -X POST $B/user/api-keys/revoke-all -H "Authorization: Bearer $JWT" | jqq "['data']['revoked']")
[ -n "$RA" ] && log_ok "revoke-all 吊销 ${RA} 把" || {
  log_error "revoke-all 失败"
  exit 1
}
R10=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/share/text/ -H "X-API-Key: $KEY2" \
  -H 'Content-Type: application/json' -d '{"text":"x","expire_value":1,"expire_style":"hour","require_auth":false}')
[ "$R10" = "401" ] && log_ok "revoke-all 后 Key2 401" || {
  log_error "revoke-all 后仍可用：$R10"
  exit 1
}

# 11. refresh 黑名单：登出后旧 JWT 不得再换新 token
curl -s -o /dev/null -X POST $B/api/v1/user/logout -H "Authorization: Bearer $JWT"
R11=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/v1/user/refresh -H "Authorization: Bearer $JWT")
[ "$R11" = "401" ] && log_ok "登出后 refresh 401（黑名单生效）" || {
  log_error "登出后 refresh 仍可用：$R11"
  exit 1
}

log_ok "=== e2e 全链路 OK ==="
