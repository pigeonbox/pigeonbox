#!/usr/bin/env bash
# S3 存储后端真实 E2E（MinIO）。
#
# 在可访问 Docker registry 的环境运行，验证 storage.type=s3 全链路：
#   上传 → 对象落 MinIO → 取件下载内容一致 → 删除分享后对象消失。
#
# 用法: bash scripts/e2e-s3-minio.sh
# 依赖: docker、curl、python3
# shellcheck disable=SC2015
# 断言形态「A && echo 成功 || { echo 失败; exit 1; }」：中间的 echo 恒以 exit 0
# 收尾，故不存在 SC2015 担心的「B 失败导致 C 误跑」路径。
set -euo pipefail

# ── shellkit（E2E 侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
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

CONTAINER=fcb-minio-e2e
PORT=9000
DATA="$(mktemp -d)"

# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原手写 trap 等价。
# ⚠️ 原脚本先装了一个**函数式** trap（trap cleanup EXIT）⇒ 静态判不了 ⇒ 脱离
#    scripts/check-shell-trap-exit-code.sh 的覆盖；随后又被一个手写 trap 覆盖 ⇒
#    实际生效的只有后一个（它自己也调 cleanup）。这里把两个动作都收进清理栈：
#    **容器回收 + 数据目录回收 + server 进程回收**，与后一个 trap 的实际语义一致。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true'
trap_push 'rm -rf "${DATA}"'
trap_push 'if [ -n "${SERVER_PID:-}" ]; then kill "${SERVER_PID}" 2>/dev/null || true; fi'
trap_install

log_info "== 1. 启动 MinIO =="
docker run -d --name "$CONTAINER" -p "$PORT":9000 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data >/dev/null
sleep 5

log_info "== 2. 以 s3 存储启动 server =="
cd "$ROOT/server"
mkdir -p "$DATA/static" && cp -R static/* "$DATA/static/" 2>/dev/null || true
cat >"$DATA/config.yaml" <<EOF
server: {host: "127.0.0.1", port: 12345, mode: "debug", base_url: "http://127.0.0.1:12345"}
database: {driver: "sqlite", db_name: "$DATA/fcb.db"}
redis: {host: "", port: 6379}
log: {level: "error"}
app: {name: "fcb-e2e", datapath: "$DATA/data", production: false}
upload: {open_upload: true, upload_size: 10485760, enable_chunk: false}
storage:
  type: "s3"
  storage_path: "$DATA/uploads"
  s3:
    endpoint: "http://127.0.0.1:$PORT"
    region: "us-east-1"
    bucket: "fcb-e2e"
    access_key: "minioadmin"
    secret_key: "minioadmin"
    use_ssl: false
    path_style: true
user:
  jwt_secret: "e2e-secret-key-0123456789abcdef0123456789abcdef"
EOF
PB_JWT_SECRET="e2e-secret-key-0123456789abcdef0123456789abcdef" \
  go run ./cmd/server --config "$DATA/config.yaml" >"$DATA/server.log" 2>&1 &
# shellcheck disable=SC2034  # SERVER_PID 只在 trap 清理串里被读（shellcheck 看不见单引号串）
SERVER_PID=$!
for _ in $(seq 1 30); do
  curl -sf http://127.0.0.1:12345/live >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://127.0.0.1:12345/live >/dev/null || {
  log_error "server 未就绪"
  tail -20 "$DATA/server.log"
  exit 1
}
log_info "server up"

log_info "== 3. 文件分享（应写入 MinIO）=="
printf 'minio-e2e-content-%s' "$(date +%s)" >"$DATA/origin.txt"
CODE=$(curl -sf -X POST http://127.0.0.1:12345/share/file/ \
  -F "file=@$DATA/origin.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" |
  python3 -c "import json,sys; print(json.load(sys.stdin)['data']['code'])")
log_info "share code: $CODE"

log_info "== 4. MinIO 中存在对象 =="
docker exec "$CONTAINER" sh -c "ls -R /data 2>/dev/null | grep -q uploads" &&
  log_ok "对象已落 MinIO" || {
  log_error "MinIO 中未找到对象"
  exit 1
}

log_info "== 5. 取件下载内容一致 =="
DL=$(curl -s "http://127.0.0.1:12345/share/select/?code=$CODE" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['download_url'])")
curl -sf "http://127.0.0.1:12345$DL" >"$DATA/downloaded.txt"
cmp -s "$DATA/origin.txt" "$DATA/downloaded.txt" && log_ok "下载内容一致" || {
  log_error "内容不一致"
  exit 1
}

log_info "== 6. 删除分享 → 对象消失 =="
TOKEN=$(curl -sf -X POST http://127.0.0.1:12345/admin/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin123"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")
FILE_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:12345/admin/files?keyword=$CODE" |
  python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('data') or {}).get('items',[{}])[0].get('id',''))")
curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:12345/admin/files/$FILE_ID" >/dev/null
sleep 1
docker exec "$CONTAINER" sh -c "ls -R /data 2>/dev/null | grep -q uploads" &&
  {
    log_error "删除后对象仍存在"
    exit 1
  } || log_ok "删除后对象已清理"

log_ok "✓✓ S3 存储后端 E2E 全部通过"
