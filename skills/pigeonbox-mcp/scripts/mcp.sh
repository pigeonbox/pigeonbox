#!/usr/bin/env bash
# PigeonBox MCP 助手脚本（skill: pigeonbox-mcp）
# 依赖: curl + python3（无 jq 依赖）
#
# 用法:
#   mcp.sh login                        获取并缓存管理员 token（已设 PB_TOKEN 时直接用之）
#   mcp.sh tools                        列出全部 MCP 工具及说明
#   mcp.sh call <tool> ['{json 参数}']  调用工具，输出结果文本（业务失败退出码 1）
#   mcp.sh rpc <method> ['{params}']    通用 JSON-RPC（initialize / ping / 其他）
#
# 环境变量:
#   PB_BASE_URL       服务器基址（默认 http://localhost:12345）
#   PB_ADMIN_USER     管理员用户名（默认 admin）
#   PB_ADMIN_PASSWORD 管理员密码（未设 PB_TOKEN 时必填）
#   PB_TOKEN          直接注入 token（跳过登录）
#   PB_TOKEN_FILE     token 缓存文件（默认 ${TMPDIR:-/tmp}/pb-mcp-token.<user>，权限 600；
#                      设为 /dev/null 可禁用缓存）
set -euo pipefail

BASE="${PB_BASE_URL:-http://localhost:12345}"
AUSER="${PB_ADMIN_USER:-admin}"
TOKEN_FILE="${PB_TOKEN_FILE:-${TMPDIR:-/tmp}/pb-mcp-token.$AUSER}"

usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; }

# 从 stdin JSON 按路径取值: jget data token
jget() { python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k]
print(d)
' "$@"; }

token() {
  if [ -n "${PB_TOKEN:-}" ]; then printf '%s' "$PB_TOKEN"; return; fi
  if [ -s "$TOKEN_FILE" ]; then cat "$TOKEN_FILE"; return; fi
  [ -n "${PB_ADMIN_PASSWORD:-}" ] || { echo "错误: 未设置 PB_ADMIN_PASSWORD（或直接给 PB_TOKEN）" >&2; exit 2; }
  local body t
  body=$(python3 -c 'import json,sys;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$AUSER" "$PB_ADMIN_PASSWORD")
  t=$(curl -sf -X POST "$BASE/admin/login" -H 'Content-Type: application/json' -d "$body" | jget data token) || {
    echo "错误: 登录失败（检查 PB_BASE_URL / 账号密码）" >&2; exit 2; }
  { umask 077; printf '%s' "$t" > "$TOKEN_FILE"; }
  printf '%s' "$t"
}

# mcp <method> [params-json] —— 发一次 JSON-RPC；401 时清缓存重登重试一次
mcp() {
  local method="$1" params="${2:-}" t body out code
  [ -n "$params" ] || params='{}'   # 注意: 不可写 ${2:-{}}，裸 } 会提前闭合参数展开
  body=$(python3 -c 'import json,sys;print(json.dumps({"jsonrpc":"2.0","id":1,"method":sys.argv[1],"params":json.loads(sys.argv[2])}))' "$method" "$params")
  t=$(token)
  out=$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/v1/mcp" \
        -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' -d "$body")
  code=$(printf '%s' "$out" | tail -n1)
  if [ "$code" = "401" ]; then
    rm -f "$TOKEN_FILE"; t=$(token)
    out=$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/v1/mcp" \
          -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
          -H 'Accept: application/json, text/event-stream' -d "$body")
    code=$(printf '%s' "$out" | tail -n1)
  fi
  if [ "$code" != "200" ]; then
    echo "错误: HTTP $code（404=端点未开或在 public 副本上）" >&2
    printf '%s\n' "$out" | sed '$d' >&2
    exit 3
  fi
  printf '%s' "$out" | sed '$d'
}

case "${1:-help}" in
  login) rm -f "$TOKEN_FILE"; token >/dev/null; echo "✓ token 已缓存到 $TOKEN_FILE" ;;
  tools) mcp tools/list | python3 -c '
import sys, json
d = json.load(sys.stdin)
for t in d["result"]["tools"]:
    print(t["name"].ljust(18), t["description"])
' ;;
  call)
    [ -n "${2:-}" ] || { usage; exit 2; }
    args="$3"; [ -n "$args" ] || args='{}'
    mcp tools/call "{\"name\":\"$2\",\"arguments\":$args}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
r = d.get("result") or {}
sc = r.get("structuredContent")
if sc is not None:
    # 类型化出参：直接给结构化 JSON（agent 可直接消费字段）
    print(json.dumps(sc, ensure_ascii=False, indent=2))
else:
    for c in r.get("content", []):
        if c.get("type") == "text":
            print(c["text"])
if r.get("isError"):
    sys.exit(1)
'
    ;;
  rpc)  [ -n "${2:-}" ] || { usage; exit 2; }; mcp "$2" "${3:-}" ;;
  help|*) usage ;;
esac
