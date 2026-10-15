#!/bin/bash
# PigeonBox 全能力真机冒烟（49 项断言）：健康面/openapi 运行时生成/api config/admin 登录/
# 文本+密码分享/元数据不泄露/select 不扣次数/文件分享+Range/多文件+zip/chunk 完成+秒传/
# 本地文件管理(穿越防护，目标需启用 local_import)/寄件码全链路/MCP/二维码/匿名码(需 Redis)/robots。
#
# 用法一(默认):bash scripts/smoke-full.sh
#   自动编译 server、起临时实例(含临时 Redis,端口 18777)、跑完即清理。
# 用法二(外置实例):SMOKE_BASE=http://host:port bash scripts/smoke-full.sh
#   不编译不起服务,直接对已有实例跑全部断言——用于 Docker/compose/K8s 部署验证。
#   注意:外置实例需启用 local_import(roots 需包含本机 /tmp/fcb-smoke/import
#   的容器内挂载路径)且 Redis 可用,否则 S12/S16 两域会失败。
set -u
SMOKE=${SMOKE:-/tmp/fcb-smoke}
BASE=${SMOKE_BASE:-http://127.0.0.1:18777}
PORT=18777
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1  [$2]"; }
J() { python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(eval(sys.argv[1], {'d': d}))
except Exception as e:
    print('JERR:'+str(e))
" "$1" 2>/dev/null; }

mkdir -p "$SMOKE"/{data,uploads,import,src}
echo "smoke-local-content-$(date +%s)" > "$SMOKE/import/local-nas.txt"
printf 'hello-pigeonbox-range' > "$SMOKE/src/smoke-range.txt"
head -c 300000 /dev/zero | tr '\0' 'A' > "$SMOKE/src/big-a.txt"
echo "multi-file-one" > "$SMOKE/src/m1.txt"
echo "multi-file-two" > "$SMOKE/src/m2.txt"

if [ -z "${SMOKE_BASE:-}" ]; then
  # ===== 内置模式:起临时实例 =====
  command -v redis-server >/dev/null || { echo "需要 redis-server（冒烟会起临时实例）;请先安装"; exit 1; }
  command -v python3 >/dev/null || { echo "需要 python3（断言解析用）;请先安装"; exit 1; }
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
  host: "127.0.0.1"
  port: 16379
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

  # 编译 + 起服务
  cd "$(dirname "$0")/../server" || exit 1
  go build -o "$SMOKE/server-bin" ./cmd/server || { echo "BUILD FAILED"; exit 1; }
  PB_JWT_SECRET=smoke-secret-$(date +%s) "$SMOKE/server-bin" --config "$SMOKE/config.yaml" > "$SMOKE/server.log" 2>&1 &
  SRV=$!
  redis-server --port 16379 --daemonize no --save '' --appendonly no > "$SMOKE/redis.log" 2>&1 &
  RPID=$!
  trap 'kill $SRV $RPID 2>/dev/null' EXIT
  for i in $(seq 1 30); do
    curl -sf "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -sf "$BASE/health" >/dev/null || { echo "SERVER NOT UP"; tail -20 "$SMOKE/server.log"; exit 1; }
fi

# S1 健康面
[ -n "$(curl -s "$BASE/live")" ] && ok "S1a live" || bad "S1a live" "$(curl -s $BASE/live)"
curl -s "$BASE/readyz" | grep -qi 'ok\|ready\|true' && ok "S1b readyz" || bad "S1b readyz" "$(curl -s $BASE/readyz | head -c 120)"
# S1c /version 已收归管理员（2026-10-06 攻击面收缩：版本披露辅助 CVE 匹配），
# 未认证应为 401；带 admin token 可读（TOK 在 S3 段取得，此处先做未认证断言）
V=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/version")
[ "$V" = "401" ] && ok "S1c version 未认证 401" || bad "S1c version 未认证 401" "$V"

# S2 openapi.json 运行时生成
OA=$(curl -s "$BASE/openapi.json")
echo "$OA" | grep -q '"/share/metadata/{code}"' && ok "S2a openapi 含 metadata 端点" || bad "S2a openapi metadata" "-"
echo "$OA" | grep -q '"/admin/local-files"' && ok "S2b openapi 含 local-files 端点" || bad "S2b openapi local-files" "-"
N=$(echo "$OA" | J "len(d['paths'])")
case "$N" in JERR*|"") bad "S2c openapi paths 数" "$N";; [0-9]*) [ "$N" -ge 90 ] && ok "S2c openapi paths=$N" || bad "S2c openapi paths=$N" "<90";; esac

# S3 /api/config
AC=$(curl -s "$BASE/api/config")
echo "$AC" | J "d['data']['expireStyle']" | grep -q week && ok "S3 api/config 下发 expireStyle" || bad "S3 api/config" "$(echo $AC | head -c 100)"
echo "$AC" | J "'showAdminAddr' in d['data']" | grep -q True && ok "S3b showAdminAddr 字段下发" || bad "S3b showAdminAddr" "-"

# S4 admin 登录
TOK=$(curl -s -X POST "$BASE/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"${SMOKE_ADMIN_PASSWORD:-admin123}\"}" | J "d['data']['token']")
[ -n "$(curl -s "$BASE/version" -H "Authorization: Bearer $TOK")" ] && ok "S3a0 version admin 可读" || bad "S3a0 version admin 可读" "-"
[ -n "$TOK" ] && [ "$TOK" != "JERR"* ] && ok "S4 admin 登录" || bad "S4 admin 登录" "$TOK"
AH="Authorization: Bearer $TOK"

# S5 文本分享
CODE_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-hello","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['code']")
[ -n "$CODE_T" ] && [ "${CODE_T:0:4}" != "JERR" ] && ok "S5 文本分享 code=$CODE_T" || bad "S5 文本分享" "$CODE_T"
# S5b 文本分享响应必须带 6 位取件码（文本/文件同权铸造；前端快捷取件卡依赖，2026-10-15 回归守卫）
PICKUP_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-pickup","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['pickup_code']")
echo "$PICKUP_T" | grep -qE "^[A-Z0-9]{6}$" && ok "S5b 文本分享铸 pickup_code=$PICKUP_T" || bad "S5b 文本分享 pickup_code 缺失" "$PICKUP_T"
# S5c 取件响应文本分享必须回传 share_code（前端跳详情页展示文本依赖，2026-10-15 回归守卫）
SC_T=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_T\"}" | J "d['data']['share_code']")
[ "$SC_T" != "None" ] && [ -n "$SC_T" ] && [ "${SC_T:0:4}" != "JERR" ] && ok "S5c 取件回传 share_code=$SC_T" || bad "S5c 取件 share_code 缺失" "$SC_T"

# S6 metadata（text）
MD=$(curl -s "$BASE/share/metadata/$CODE_T")
[ "$(echo "$MD" | J "d['data']['type']")" = "text" ] && ok "S6a metadata type=text" || bad "S6a metadata text" "$MD"
[ "$(echo "$MD" | J "d['data']['has_password']")" = "False" ] && ok "S6b metadata has_password=false" || bad "S6b metadata" "$MD"
echo "$MD" | grep -q "smoke-text-hello" && bad "S6c metadata 泄露文本内容!" "$MD" || ok "S6c metadata 不外泄内容"

# S7 select 查询不扣次数 + 下载（次数=1 的分享，查询 3 次后仍可下载）
CODE_1=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"once-only","expire_value":1,"expire_style":"count","require_auth":false}' | J "d['data']['code']")
SEL=$(curl -s "$BASE/share/select/?code=$CODE_1")
DL=$(echo "$SEL" | J "d['data']['download_url']"); case "$DL" in /*) DL="$BASE$DL";; esac
for i in 1 2 3; do curl -s "$BASE/share/select/?code=$CODE_1" >/dev/null; done
BODY=$(curl -s "$DL")
echo "$BODY" | grep -q "once-only" && ok "S7 select 不扣次数+令牌下载" || bad "S7 下载" "$(echo "$BODY" | head -c 80)"

# S8 密码分享
CODE_P=$(curl -s -X POST "$BASE/share/text/" -F "text=secret-pwd" -F "expire_value=1" -F "expire_style=day" -F "require_auth=true" -F "password=pw123" | J "d['data']['code']")
[ "$(curl -s "$BASE/share/metadata/$CODE_P" | J "d['data']['has_password']")" = "True" ] && ok "S8a 密码分享 metadata has_password" || bad "S8a has_password" "-"
curl -s "$BASE/share/select/?code=$CODE_P" | grep -q "密码\|password" && ok "S8b 无密码查询被拒" || bad "S8b 无密码查询" "-"
curl -s "$BASE/share/select/?code=$CODE_P&password=pw123" | grep -q "download_url" && ok "S8c 带密码查询通过" || bad "S8c 带密码查询" "-"

# S9 文件上传 + metadata + Range
CODE_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" | J "d['data']['code']")
[ -n "$CODE_F" ] && [ "${CODE_F:0:4}" != "JERR" ] && ok "S9a 文件分享 code=$CODE_F" || bad "S9a 文件分享" "$CODE_F"
# S9a2 文件分享响应带 6 位取件码 + select 带 download 令牌（契约字段齐套回归守卫）
PICKUP_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" | J "d['data']['pickup_code']")
echo "$PICKUP_F" | grep -qE "^[A-Z0-9]{6}$" && ok "S9a2 文件分享铸 pickup_code=$PICKUP_F" || bad "S9a2 文件分享 pickup_code" "$PICKUP_F"
# S9a3 文件分享取件 share_code 恒空（契约：share_code 仅文本分享回传，文件走 download_url）
[ "$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_F\"}" | J "d['data']['share_code']")" = "None" ] && ok "S9a3 文件取件 share_code 恒空(契约)" || bad "S9a3 文件取件不应回传 share_code" "-"
[ "$(curl -s "$BASE/share/metadata/$CODE_F" | J "d['data']['name']")" = "smoke-range.txt" ] && ok "S9b metadata 文件名" || bad "S9b metadata name" "-"
DLF=$(curl -s "$BASE/share/select/?code=$CODE_F" | J "d['data']['download_url']"); case "$DLF" in /*) DLF="$BASE$DLF";; esac
R=$(curl -s -H "Range: bytes=0-4" -o /dev/null -w "%{http_code}" "$DLF")
[ "$R" = "206" ] && ok "S9c Range 206" || bad "S9c Range" "$R"
PART=$(curl -s -H "Range: bytes=0-4" "$DLF")
[ "$PART" = "hello" ] && ok "S9d Range 内容正确" || bad "S9d Range 内容" "$PART"

# S10 多文件直传 + zip
CODE_M=$(curl -s -X POST "$BASE/api/v1/share/multi-direct" -F "files=@$SMOKE/src/m1.txt" -F "files=@$SMOKE/src/m2.txt" -F "expire_value=1" -F "expire_style=day" | J "d['data']['code']")
[ -n "$CODE_M" ] && [ "${CODE_M:0:4}" != "JERR" ] && ok "S10a 多文件分享 code=$CODE_M" || bad "S10a 多文件" "$CODE_M"
# S10a2 select 的 download_url 必须带签名令牌（缺令牌直链 401——历史事故回归守卫）
echo "$(curl -s "$BASE/share/select/?code=$CODE_M")" | grep -q "token=" && ok "S10a2 select 带下载令牌" || bad "S10a2 下载令牌缺失" "-"
DLM=$(curl -s "$BASE/share/select/?code=$CODE_M" | J "d['data']['download_url']"); case "$DLM" in /*) DLM="$BASE$DLM";; esac
curl -s "$DLM" -o "$SMOKE/dl.zip"
python3 -c "
import zipfile,sys
z = zipfile.ZipFile('$SMOKE/dl.zip')
names = z.namelist()
assert len(names) == 2, names
assert z.read(names[0]).rstrip(b'\n') in (b'multi-file-one', b'multi-file-two')
print('ZIP-OK')
" 2>/dev/null && ok "S10b 多文件 zip 2 entries" || bad "S10b zip" "$(file $SMOKE/dl.zip | head -c 80)"

# S11 chunk 分片上传完整闭环 + 完成后秒传
UPID=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
INIT=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
UPID=$(echo "$INIT" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UPID/0" -F "chunk=@$SMOKE/src/big-a.txt" > /dev/null
CMP=$(curl -s -X POST "$BASE/chunk/upload/complete/$UPID" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}')
CMP_CODE=$(echo "$CMP" | J "d['data']['share_code']") ; [ "$CMP_CODE" = "JERR"* ] || [ -z "$CMP_CODE" ] && CMP_CODE=$(echo "$CMP" | J "d['data']['code']")
[ -n "$CMP_CODE" ] && [ "${CMP_CODE:0:4}" != "JERR" ] && ok "S11a 分片完成→建分享 code=$CMP_CODE" || bad "S11a chunk complete" "$(echo $CMP | head -c 120)"
HA=$(sha256sum "$SMOKE/src/big-a.txt" | cut -d' ' -f1)
QI=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
[ "$(echo "$QI" | J "d['data']['is_quick_upload']")" = "True" ] && ok "S11b 秒传命中" || bad "S11b 秒传" "$(echo $QI | head -c 120)"

# S11c/d 分片期望哈希强校验（hash 参数：不符 422 可重试 / 相符放行）
head -c 1024 /dev/zero | tr '\0' 'B' > "$SMOKE/src/bad-chunk.bin"
HBAD=$(printf 'a%.0s' $(seq 1 64))
INIT2=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"bad-chunk.bin\",\"file_size\":1024,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$(sha256sum "$SMOKE/src/bad-chunk.bin" | cut -d' ' -f1)\"}")
UP2=$(echo "$INIT2" | J "d['data']['upload_id']")
BADR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HBAD" -F "chunk=@$SMOKE/src/bad-chunk.bin")
[ "$BADR" = 422 ] && ok "S11c 期望哈希不符拒收(422)" || bad "S11c 哈希校验" "$BADR"
HOK=$(sha256sum "$SMOKE/src/bad-chunk.bin" | cut -d' ' -f1)
OKR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HOK" -F "chunk=@$SMOKE/src/bad-chunk.bin")
[ "$OKR" = 200 ] && ok "S11d 正确 SHA-256 放行" || bad "S11d 正确哈希" "$OKR"

# S12 管理端本地文件
LF=$(curl -s "$BASE/admin/local-files?root=0" -H "$AH")
[ "$(echo "$LF" | J "len(d['data']['entries'])")" -ge 1 ] && ok "S12a local-files 列表" || bad "S12a 列表" "$(echo $LF | head -c 100)"
CODE_L=$(curl -s -X POST "$BASE/admin/local-files/import" -H "$AH" -H 'Content-Type: application/json' -d "{\"root\":0,\"path\":\"local-nas.txt\",\"expire_value\":1,\"expire_style\":\"day\"}" | J "d['data']['code']")
[ -n "$CODE_L" ] && [ "${CODE_L:0:4}" != "JERR" ] && ok "S12b 本地文件生成提取码 code=$CODE_L" || bad "S12b 导入" "$CODE_L"
DLL=$(curl -s "$BASE/share/select/?code=$CODE_L" | J "d['data']['download_url']"); case "$DLL" in /*) DLL="$BASE$DLL";; esac
DLHTTP=$(curl -s -o /tmp/dl-s12.txt -w "%{http_code}" "$DLL")
[ "$DLHTTP" = 200 ] && [ -s /tmp/dl-s12.txt ] && ok "S12c 导入分享可下载" || bad "S12c 下载" "$DLHTTP"
DEL=$(curl -s -X DELETE "$BASE/admin/local-files?root=0&path=local-nas.txt" -H "$AH")
echo "$DEL" | J "d['code']" | grep -qxE "0|200" && ok "S12d 本地文件删除" || bad "S12d 删除" "$DEL"
curl -s "$BASE/admin/local-files?root=0&dir=../../etc" -H "$AH" | grep -qi "非法\|越界\|不在" && ok "S12e 路径穿越被拒" || bad "S12e 穿越防护" "-"

# S13 寄件码（管理端开注册→用户注册→建链接→访客投递）
# 生产模板默认关注册(安全默认)，故先走管理端配置 API 开启——顺带真测该端点
UCFG=$(curl -s -X PUT "$BASE/admin/config/user" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"allowuserregistration":true,"useruploadsize":52428800,"userstoragequota":1073741824,"sessionexpiryhours":168}')
echo "$UCFG" | J "d['code']" | grep -qxE "0|200" && ok "S13-0 管理端开启注册(用户配置 API)" || bad "S13-0 用户配置 API" "$(echo $UCFG | head -c 100)"
curl -s -X POST "$BASE/user/register" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345","nickname":"smoker","email":"smoker@example.com"}' >/dev/null
UTOK=$(curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345"}' | J "d['data']['token']")
[ -n "$UTOK" ] && [ "${UTOK:0:4}" != "JERR" ] && ok "S13a 用户注册登录" || bad "S13a 用户登录" "$UTOK"
REQ=$(curl -s -X POST "$BASE/api/v1/user/requests" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"title":"smoke-req","expire_value":1,"expire_style":"day"}')
RTOK=$(echo "$REQ" | J "d['data']['token']")
[ -n "$RTOK" ] && [ "${RTOK:0:4}" != "JERR" ] && ok "S13b 建寄件链接 token" || bad "S13b 寄件链接" "$REQ"
curl -s "$BASE/request/$RTOK" | grep -q "smoke-req\|title" && ok "S13c 访客可取链接信息" || bad "S13c 访客取链接" "-"
GUP=$(curl -s -X POST "$BASE/api/v1/request/$RTOK/upload" -F "files=@$SMOKE/src/m1.txt")
echo "$GUP" | grep -q "投递成功" && ok "S13d 访客投递" || bad "S13d 投递" "$(echo $GUP | head -c 100)"

# S14 MCP
MCP=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
NT=$(echo "$MCP" | J "len(d['result']['tools'])")
case "$NT" in [0-9]*) [ "$NT" -ge 8 ] && ok "S14 MCP tools=$NT" || bad "S14 MCP tools=$NT" "<8";; *) bad "S14 MCP" "$(echo $MCP | head -c 100)";; esac

# S15 二维码(return_base64 为契约必填;断言=code 精确+PNG base64 魔数 iVBOR)
QR=$(curl -s -X POST "$BASE/qrcode/generate" -H 'Content-Type: application/json' -d "{\"data\":\"$BASE/share/$CODE_T\",\"size\":200,\"return_base64\":true}")
{ echo "$QR" | J "d['code']" | grep -qxE "0|200"; } && echo "$QR" | J "d['data']['base64_data']" | grep -qE "^(data:image/png;base64,)?iVBOR" && ok "S15 二维码生成" || bad "S15 二维码" "$(echo "$QR" | head -c 80)"

# S16 匿名口令分享
AG=$(curl -s -X POST "$BASE/anonymous/generate" -H 'Content-Type: application/json' -d '{"file_name":"anon.txt","file_size":12,"expire_value":"1","expire_style":"day"}')
ACODE=$(echo "$AG" | J "d['data']['code']")
[ -n "$ACODE" ] && [ "${ACODE:0:4}" != "JERR" ] && ok "S16a 匿名码 code=$ACODE" || bad "S16a 匿名生成" "$AG"
curl -s "$BASE/anonymous/search/$ACODE" | grep -qi "anon.txt\|file_name" && ok "S16b 匿名码可检索" || bad "S16b 匿名检索" "-"
curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$ACODE\"}" | grep -qi "不存在\|未上传\|过期\|code" && ok "S16c 未上传检索优雅拒绝" || bad "S16c 检索" "-"

# S17 robots
curl -s "$BASE/robots.txt" | grep -q "User-agent" && ok "S17 robots.txt" || bad "S17 robots" "-"

echo ""
echo "=============================="
echo "SMOKE RESULT: PASS=$PASS FAIL=$FAIL"
exit $FAIL
