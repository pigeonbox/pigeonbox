#!/bin/sh
# 还原冒烟脚本改动过的「用户配置」段（allowuserregistration / useruploadsize /
# userstoragequota / sessionexpiryhours）。
#
# 为什么独立成脚本（2026-10-26 审计 P0）：
#   冒烟脚本把目标实例改成「开放注册 + 上传上限 50MB + 存储配额 1GB」再还原。
#   此前还原逻辑内联在脚本尾部的 Python 里，有**三条静默逃逸口**，
#   且**三条都不影响 FAIL 计数** ⇒ `exit $FAIL` 仍为 0 ⇒ CI 绿：
#     ① 读原值失败 ⇒ 变量为空 ⇒ `return 0` 静默跳过还原；
#     ② JSON 解析失败 / 缺那 4 个键 ⇒ `sys.exit(0)` 静默退出；
#     ③ 还原 PUT 失败 ⇒ 只 `print WARNING` 后继续。
#   后果：在真机/生产实例上跑冒烟，只要读原值那一瞬失败（网络抖/token 过期/5xx），
#   冒烟全绿并留下**开放注册 + 配额下调**的永久降级；Ctrl-C/超时中断同样跳过还原
#   （注释声称「还原放在脚本尾部（含异常路径的 trap）」，但**没有任何 trap**）。
#
# 本脚本的契约：**任何一条还原没真正生效的路径都返回非零退出码**，
# 由调用方（冒烟脚本）计入 FAIL ⇒ 绿冒烟不再等于「目标实例是安全的」。
#
# 用法: smoke-user-config-restore.sh --base URL --token TOKEN --snapshot FILE
# 退出码:
#   0 = 已写回且**回读比对一致**
#   1 = 用法错误
#   2 = 快照不可解析 / 缺键（读原值失败 ⇒ 不得写回）
#   3 = 写回失败（PUT 非 2xx 或网络异常）
#   4 = 回读失败或与快照不一致（还原没真正生效 ⇒ 目标实例仍是降级态）
set -u

BASE=""
TOKEN=""
SNAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE="${2:-}"; shift 2 ;;
    --token)   TOKEN="${2:-}"; shift 2 ;;
    --snapshot) SNAP="${2:-}"; shift 2 ;;
    *) echo "用法: $0 --base URL --token TOKEN --snapshot FILE" >&2; exit 1 ;;
  esac
done
# 显式 if（不用 `A && B && C || {…}`）：后者不是 if-then-else（shellcheck SC2015）
if [ -z "$BASE" ] || [ -z "$TOKEN" ] || [ -z "$SNAP" ]; then
  echo "用法: $0 --base URL --token TOKEN --snapshot FILE" >&2; exit 1
fi
[ -f "$SNAP" ] || { echo "快照文件不存在: $SNAP" >&2; exit 2; }

PY="${SMOKE_PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "需要 python(还原校验用)" >&2; exit 2; }

"$PY" - "$BASE" "$TOKEN" "$SNAP" <<'PYEOF'
import json, sys, urllib.request

base, token, snap_path = sys.argv[1], sys.argv[2], sys.argv[3]
KEYS = ('allowuserregistration', 'useruploadsize', 'userstoragequota', 'sessionexpiryhours')


def die(code, msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


# ① 快照必须可解析且 4 个键齐全 —— 读原值失败/缺键 ⇒ 退出码 2（不再静默跳过）
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


# ② 写回（失败 ⇒ 退出码 3；不再只 print WARNING 后继续）
try:
    st, body = http('PUT', '/admin/config/user', orig)
except Exception as e:
    die(3, "写回失败: %s" % e)
if st < 200 or st >= 300:
    die(3, "写回 HTTP %s: %s" % (st, body[:200]))

# ③ 回读比对（不一致 ⇒ 退出码 4：还原没真正生效 ⇒ 目标实例仍处于降级态）
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
