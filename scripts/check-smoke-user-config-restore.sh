#!/usr/bin/env bash
# shellcheck disable=SC2015  # 断言形态 A && ok || bad：ok/bad 恒以 exit 0 收尾(仓库既有约定)
# 门禁：冒烟脚本「还原用户配置」不得有静默逃逸口（2026-10-26 审计 P0）
#
# 缺陷实录：冒烟把目标实例改成「开放注册 + 上传上限 50MB + 存储配额 1GB」，
# 还原逻辑有**三条静默逃逸口**，且三条**都不影响 FAIL 计数** ⇒ `exit $FAIL`
# 仍为 0 ⇒ CI 绿，而真机/生产实例被永久留在降级态：
#   ① 读原值失败 ⇒ 变量空 ⇒ 直接 `return 0` 跳过还原；
#   ② JSON 解析失败 / 缺那 4 个键 ⇒ `sys.exit(0)` 静默退出；
#   ③ 还原 PUT 失败 ⇒ 只 `print WARNING` 后继续。
# 另有第四条：还原**没有任何 trap 保护**（注释声称有）⇒ Ctrl-C / 超时中断同样跳过。
#
# 本门禁用一个 mock 管理端把上述四条逐条跑成**可观测的红**：
#   A1 正常路径 ⇒ 还原脚本退出 0 且状态真的回到原值
#   A2 快照缺键 / A3 快照不可解析 / A6 读原值失败 ⇒ **必须非零退出**
#   A4 写回 500 ⇒ 必须非零退出
#   A5 写回空转（回读不一致）⇒ 必须非零退出
#   A7 跑到一半被 SIGTERM ⇒ 配置**必须被还原**（证明 trap 真的挂着）
#   A8 跑完 ⇒ 配置**必须被还原**（正常路径）
#   A9 结构断言：EXIT/INT/TERM 三个 trap 都指向还原钩子
#
# 门禁自带**变异自检**（M1/M2）：把还原脚本换成「永远成功」的哑元、把
# smoke-full.sh 的 trap 删掉 ⇒ 对应用例**必须变红** ⇒ 证明门禁不是空转。
#
# 用法: bash scripts/check-smoke-user-config-restore.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_SCRIPT="$ROOT/scripts/smoke-full.sh"
HELPER_SCRIPT="$ROOT/scripts/smoke-user-config-restore.sh"
WORK="${SMOKE_RESTORE_GUARD_WORK:-$(mktemp -d)}"
if [ -z "${SMOKE_RESTORE_GUARD_WORK:-}" ]; then
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$WORK"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+  [$2]}"; }

# 4 个键的「原值」与「改后值」。STATE 文件存的是**data 段本体**（mock 的
# /admin/config/user 包络由 mock 自己包）。
ORIG_DATA='{"allowuserregistration":false,"useruploadsize":104857600,"userstoragequota":10737418240,"sessionexpiryhours":168}'
MOD_DATA='{"allowuserregistration":true,"useruploadsize":52428800,"userstoragequota":1073741824,"sessionexpiryhours":168}'
ORIG="{\"code\":0,\"data\":$ORIG_DATA}"

[ -f "$SMOKE_SCRIPT" ] || { echo "找不到 $SMOKE_SCRIPT"; exit 1; }
[ -f "$HELPER_SCRIPT" ] || { echo "找不到 $HELPER_SCRIPT"; exit 1; }

# ── mock 管理端（/admin/config/user 的 GET/PUT）────────────────────────────
cat > "$WORK/mock_admin.py" <<'PYEOF'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_PATH = os.environ["MOCK_STATE"]
MODE_PATH = os.environ["MOCK_MODE_FILE"]
LOG_PATH = os.environ["MOCK_LOG"]


def mode():
    try:
        with open(MODE_PATH) as f:
            return f.read().strip()
    except Exception:
        return "ok"


def state():
    with open(STATE_PATH) as f:
        return json.load(f)


def set_state(d):
    with open(STATE_PATH, "w") as f:
        json.dump(d, f)


def log(line):
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/admin/config/user":
            log("GET")
            if mode() == "get500":
                return self._send(500, {"code": 10008, "message": "boom"})
            return self._send(200, {"code": 0, "data": state()})
        self._send(404, {"code": 10004})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        if self.path == "/user/register":
            log("POST /user/register")
            if mode() == "hang":
                time.sleep(60)
            return self._send(200, {"code": 0, "data": {"token": "t"}})
        self._send(404, {"code": 10004})

    def do_PUT(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if self.path == "/admin/config/user":
            log("PUT " + raw.decode("utf-8", "replace"))
            m = mode()
            if m == "put500":
                return self._send(500, {"code": 10008, "message": "boom"})
            if m == "put_noop":
                return self._send(200, {"code": 0, "data": {"affected": 0}})
            try:
                body = json.loads(raw)
            except Exception:
                return self._send(400, {"code": 10001})
            st = state()
            st.update(body)
            set_state(st)
            return self._send(200, {"code": 0, "data": {"affected": 1}})
        self._send(404, {"code": 10004})


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

# ── mock 启停 ──────────────────────────────────────────────────────────────
# 实例的「原值」= ORIG_DATA（注册关闭/配额宽松）；冒烟会把它改成 MOD_DATA
# （开放注册/配额下调）⇒ 还原必须把状态**带回 ORIG_DATA**。
reset_state() { printf '%s' "$1" > "$WORK/state.json"; }
MOCK_PID=""
start_mock() { # <mode>
  echo "$1" > "$WORK/mode"
  reset_state "$ORIG_DATA"
  : > "$WORK/mock.log"
  MOCK_STATE="$WORK/state.json" MOCK_MODE_FILE="$WORK/mode" MOCK_LOG="$WORK/mock.log" \
    python3 "$WORK/mock_admin.py" "$PORT" >"$WORK/mock.err" 2>&1 &
  MOCK_PID=$!
  _i=0
  while [ "$_i" -lt 50 ]; do
    if curl -sf "http://127.0.0.1:$PORT/admin/config/user" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    _i=$((_i+1))
  done
  echo "mock 起不来: $(head -3 "$WORK/mock.err" 2>/dev/null || true)" >&2
  return 1
}
stop_mock() {
  # 显式 if（不用 `A && B`）：空值时复合状态为 1 ⇒ 旧版 shellcheck 判其后「不可达」
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  MOCK_PID=""
}
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')

# 当前 mock 里的配置值（4 个键，排序后输出便于比较）
cur_state() {
  python3 -c "
import json
d=json.load(open('$WORK/state.json'))
print(json.dumps({k:d.get(k) for k in ('allowuserregistration','useruploadsize','userstoragequota','sessionexpiryhours')},sort_keys=True))
"
}
ORIG_4=$(python3 -c "
import json
d=json.loads('''$ORIG_DATA''')
print(json.dumps({k:d.get(k) for k in ('allowuserregistration','useruploadsize','userstoragequota','sessionexpiryhours')},sort_keys=True))
")

# ── 还原脚本用例 ───────────────────────────────────────────────────────────
# run_helper <helper> <snapshot-json> ; 打印退出码
run_helper() {
  printf '%s' "$2" > "$WORK/snap.json"
  sh "$1" --base "http://127.0.0.1:$PORT" --token "tok" --snapshot "$WORK/snap.json" \
    >"$WORK/helper.out" 2>"$WORK/helper.err"
  echo $?
}

check_helper_scenarios() { # <helper 路径> <期望:成功场景必须过>
  local helper="$1" label="$2" rc
  start_mock ok || { bad "$label mock 起不来"; return 1; }

  # A1 正常路径：状态先置成「改后值」，快照是「原值」⇒ 还原后状态必须回到原值
  reset_state "$MOD_DATA"
  rc=$(run_helper "$helper" "$ORIG")
  if [ "$rc" = "0" ] && [ "$(cur_state)" = "$ORIG_4" ]; then
    ok "$label A1 正常路径：写回 + 回读校验通过且状态回到原值"
  else
    bad "$label A1 正常路径" "退出码=$rc 状态=$(cur_state)"
  fi

  # A2 快照缺键 ⇒ 必须非零（读原值失败 ⇒ 不得写回）
  reset_state "$MOD_DATA"
  rc=$(run_helper "$helper" '{"code":0,"data":{"allowuserregistration":false}}')
  [ "$rc" != "0" ] && ok "$label A2 快照缺键 ⇒ 非零退出" || bad "$label A2 快照缺键" "退出码=0（静默跳过了？）"

  # A3 快照不可解析 ⇒ 必须非零
  reset_state "$MOD_DATA"
  rc=$(run_helper "$helper" 'not-json')
  [ "$rc" != "0" ] && ok "$label A3 快照不可解析 ⇒ 非零退出" || bad "$label A3 快照不可解析" "退出码=0"

  # A4 写回 500 ⇒ 必须非零（旧实现只 print WARNING ⇒ 退出码 0）
  reset_state "$MOD_DATA"
  echo put500 > "$WORK/mode"
  rc=$(run_helper "$helper" "$ORIG")
  [ "$rc" != "0" ] && ok "$label A4 写回失败 ⇒ 非零退出" || bad "$label A4 写回失败" "退出码=0（旧缺陷：只 print WARNING）"

  # A5 写回空转 ⇒ 回读不一致 ⇒ 必须非零
  reset_state "$MOD_DATA"
  echo put_noop > "$WORK/mode"
  rc=$(run_helper "$helper" "$ORIG")
  [ "$rc" != "0" ] && ok "$label A5 回读不一致 ⇒ 非零退出" || bad "$label A5 回读不一致" "退出码=0（没回读比对？）"

  # A6 读原值失败（GET 500 ⇒ 快照取不到）⇒ 必须非零
  reset_state "$MOD_DATA"
  echo get500 > "$WORK/mode"
  rc=$(run_helper "$helper" '')
  [ "$rc" != "0" ] && ok "$label A6 读原值失败 ⇒ 非零退出" || bad "$label A6 读原值失败" "退出码=0"
  stop_mock
}

# ── 冒烟脚本中断用例（证明 trap 真的挂着）──────────────────────────────────
# 跑到 S13 改完配置后被 SIGTERM ⇒ 配置必须已被还原。
cat > "$WORK/interrupt.py" <<'PYEOF'
import os, signal, subprocess, sys, time

smoke_script, base, smoke_dir, log_path, rc_path = sys.argv[1:6]
env = dict(os.environ)
env["SMOKE_BASE"] = base
env["SMOKE"] = smoke_dir
env["SMOKE_PY"] = "python3"
p = subprocess.Popen(["sh", smoke_script], env=env, stdout=open(log_path, "wb"),
                     stderr=subprocess.STDOUT, start_new_session=True)
deadline = time.time() + 60
while time.time() < deadline:
    try:
        with open(os.environ["MOCK_LOG"]) as f:
            if "POST /user/register" in f.read():
                break
    except Exception:
        pass
    time.sleep(0.2)
else:
    p.kill()
    with open(rc_path, "w") as f:
        f.write("timeout")
    sys.exit(0)
# 整组杀（含阻塞中的 curl）⇒ shell 的 TERM trap 立即执行
try:
    os.killpg(os.getpgid(p.pid), signal.SIGTERM)
except Exception:
    p.terminate()
try:
    p.wait(timeout=30)
except Exception:
    p.kill()
    p.wait()
with open(rc_path, "w") as f:
    f.write(str(p.returncode))
PYEOF

check_trap_scenario() { # <smoke 脚本> <label>
  local script="$1" label="$2" rc
  start_mock hang || { bad "$label mock 起不来"; return 1; }
  mkdir -p "$WORK/smoke"
  rm -f "$WORK/smoke.log" "$WORK/rc"
  MOCK_LOG="$WORK/mock.log" python3 "$WORK/interrupt.py" "$script" \
    "http://127.0.0.1:$PORT" "$WORK/smoke" "$WORK/smoke.log" "$WORK/rc"
  rc=$(head -n 1 "$WORK/rc" 2>/dev/null || true); [ -n "$rc" ] || rc="none"
  if [ "$(cur_state)" = "$ORIG_4" ]; then
    ok "$label A7 中断(SIGTERM)后配置已还原 ⇒ trap 生效"
  else
    bad "$label A7 中断后配置未还原" "状态=$(cur_state)（期望原值）"
  fi
  if [ "$rc" != "0" ] && [ "$rc" != "none" ] && [ "$rc" != "timeout" ]; then
    ok "$label A7b 中断后退出码非 0（rc=${rc}）"
  else
    bad "$label A7b 中断后退出码" "rc=${rc}（期望非 0）"
  fi
  if grep -q "SMOKE RESULT" "$WORK/smoke.log" 2>/dev/null; then
    bad "$label A7c 脚本跑到了结尾（说明没被中断/没走 trap）" "-"
  else
    ok "$label A7c 脚本确被中断（未跑到结尾）"
  fi
  stop_mock
}

echo "── A1..A6 还原脚本的四条逃逸口"
check_helper_scenarios "$HELPER_SCRIPT" ""

echo "── A7 trap 生效（跑到一半被 SIGTERM）"
check_trap_scenario "$SMOKE_SCRIPT" ""

echo "── A8 正常路径跑完必须还原"
start_mock ok || bad "A8 mock 起不来"
mkdir -p "$WORK/smoke2"
SMOKE_BASE="http://127.0.0.1:$PORT" SMOKE="$WORK/smoke2" SMOKE_PY=python3 \
  sh "$SMOKE_SCRIPT" >"$WORK/smoke2.log" 2>&1
RC2=$?
stop_mock
if [ "$(cur_state)" = "$ORIG_4" ]; then
  ok "A8 跑完后配置已还原"
else
  bad "A8 跑完后配置未还原" "状态=$(cur_state)"
fi
if [ "$RC2" -ne 0 ]; then
  ok "A8b 跑完退出码非 0（mock 上多数断言本就不成立，重点看还原）"
else
  bad "A8b 跑完退出码" "rc=$RC2"
fi

echo "── A9 结构断言：EXIT/INT/TERM 三个 trap 都指向还原钩子"
for sig in EXIT INT TERM; do
  if grep -qE "trap .*on_exit.*$sig|trap '$sig'.*on_exit|trap \"$sig\".*on_exit" "$SMOKE_SCRIPT" \
     || grep -qE "trap 'on_exit [0-9]+' $sig" "$SMOKE_SCRIPT"; then
    ok "A9 $sig trap 已挂"
  else
    bad "A9 $sig trap 未挂（Ctrl-C/超时会跳过还原）"
  fi
done
if grep -q 'restore_user_config' "$SMOKE_SCRIPT"; then
  ok "A9 on_exit 调用了 restore_user_config"
else
  bad "A9 on_exit 未调用 restore_user_config"
fi

echo "── 变异自检（证明门禁不是空转）"
# M1：还原脚本换成「永远成功」的哑元 ⇒ A4/A5/A6 必须变红
cat > "$WORK/helper_dumb.sh" <<'EOF'
#!/bin/sh
OK=1
exit 0
EOF
chmod +x "$WORK/helper_dumb.sh"
M1_FAIL=0
# 子 shell 跑:变异体的**预期失败**不许污染本门禁的 PASS/FAIL 计数
( check_helper_scenarios "$WORK/helper_dumb.sh" "M1" ) > "$WORK/m1.out" 2>&1 || true
grep -q "✗ M1 A4" "$WORK/m1.out" && M1_FAIL=1
grep -q "✗ M1 A5" "$WORK/m1.out" && M1_FAIL=1
grep -q "✗ M1 A6" "$WORK/m1.out" && M1_FAIL=1
if [ "$M1_FAIL" = "1" ]; then
  ok "M1 变异（还原脚本永远成功）被 A4/A5/A6 抓住"
else
  bad "M1 变异未被抓住" "哑元还原脚本竟通过了 A4/A5/A6 ⇒ 门禁空转"
fi

# M2：删掉 smoke-full.sh 的 trap ⇒ A7 必须变红（配置留在降级态）
sed -e "s/^trap on_exit EXIT$/# trap removed by mutation/" \
    -e "s/^trap 'on_exit 130' INT$/# trap removed by mutation/" \
    -e "s/^trap 'on_exit 143' TERM$/# trap removed by mutation/" \
    "$SMOKE_SCRIPT" > "$WORK/smoke_mutated.sh"
if ! diff -q "$SMOKE_SCRIPT" "$WORK/smoke_mutated.sh" >/dev/null 2>&1; then
  M2_FAIL=0
  ( check_trap_scenario "$WORK/smoke_mutated.sh" "M2" ) > "$WORK/m2.out" 2>&1 || true
  grep -q "✗ M2 A7 " "$WORK/m2.out" && M2_FAIL=1
  if [ "$M2_FAIL" = "1" ]; then
    ok "M2 变异（删掉 trap）被 A7 抓住"
  else
    bad "M2 变异未被抓住" "删掉 trap 后 A7 仍绿 ⇒ 门禁空转"
  fi
else
  bad "M2 变异未生效" "没能在 smoke-full.sh 里定位 trap 行（脚本结构变了？）"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✓ 冒烟「还原用户配置」守卫通过（无静默逃逸口 + trap 生效）"
OK=1
