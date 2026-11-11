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
#   ⚠️ 站点地址是 HTTPS 且证书自签时,再设 SMOKE_CURL_INSECURE=1(S18 的 presign
#   PUT 打的是对外地址,验证不了自签证书 ⇒ 不设就会出两条假红)。
# 用法四(判据自证,不打任何服务):bash scripts/smoke-full.sh --selfcheck-params
#   对 stub 响应跑参数校验判据函数(S35 组;含负对照:旧语义/一律400/超条数等)
#   ⇒ 判据必须能区分新旧语义(对旧版本实例的响应判红)。不连接任何实例。
set -u
SMOKE=${SMOKE:-/tmp/fcb-smoke}
# 自毁守卫（2026-11-06 P2）：下方内置模式会用 rm -rf 清 $SMOKE 下的数据目录。
# 此前没有任何前置判据 ⇒ SMOKE 被外部环境设成空串/根路径时，
# `rm -rf "$SMOKE/data"` 会退化成 `rm -rf "/data"`（生产上可能是真实数据目录）。
# 判据：必须是绝对路径、不是 /，且不与仓库根/家目录重合。
case "$SMOKE" in
  /*) ;;
  *)
    echo "SMOKE 必须是绝对路径（当前: '$SMOKE'）" >&2
    exit 2
    ;;
esac
# ⚠️ ROOT 在本脚本里尚未定义（set -u 下裸引用会直接崩），用 ${ROOT:-} 兜底。
if [ "$SMOKE" = "/" ] || [ "$SMOKE" = "$HOME" ] || [ "$SMOKE" = "${ROOT:-}" ]; then
  echo "拒绝在 '$SMOKE' 下清理数据（疑似误设 SMOKE）" >&2
  exit 2
fi
# ⚠️ 2026-11-10 真机实录（103）：scratch 目录里可能留着**别的属主**的旧产物
# （本机此前用 root 跑过一轮 ⇒ $SMOKE/src/docs、$SMOKE/s28.zip 等属 root）。
# 后果有两层，且**都静默**：
#   ① fixture 写不进去（Permission denied）⇒ curl -F 拿到的是**旧文件或空**
#      ⇒ S28b 拿旧 zip 做断言 ⇒ **假红**（实测：zip 里是上上轮的 token）；
#   ② curl -o 覆盖不了属主的旧文件（rc=23）⇒ 断言读到**上轮产物** ⇒
#      同样是假红/假绿，判据根本没测当轮行为。
# ⇒ 治法：**产物与 fixture 一律写到本轮独占子目录**（带 run 标记），
#   不用 $SMOKE 下的固定文件名 ⇒ 既躲开别人的属主，也躲开自己上轮的残留。
#   （$SMOKE/import、$SMOKE/data、$SMOKE/uploads 是**服务端要读的路径**
#     ⇒ 不能挪，保持原位。）
# 定义放在头部（USER_CFG_SNAP 在文件前段就要用它 ⇒ set -u 下晚定义会崩）。
SMOKE_RUN_DIR="$SMOKE/run-$(date +%s)-$$"
mkdir -p "$SMOKE_RUN_DIR/src" "$SMOKE_RUN_DIR/art" || {
  echo "无法创建本轮 scratch 目录 ${SMOKE_RUN_DIR}（${SMOKE} 不可写?）" >&2
  exit 1
}
# fixture 与产物目录的**可写性必须当场验**：不可写却继续跑 ⇒ 断言会拿旧
# 文件当本轮产物 ⇒ 假红/假绿（上面 ①② 的根因）。验不过就直接退出，
# 不产出"看起来跑过了"的假象。
if ! (: >"$SMOKE_RUN_DIR/src/.w") 2>/dev/null; then
  echo "scratch 目录不可写：$SMOKE_RUN_DIR/src" >&2
  exit 1
fi
rm -f "$SMOKE_RUN_DIR/src/.w"
# ── 本轮起始标记文件（S33 用）────────────────────────────────────────────
# 存储根下「本轮新增文件」的判据 = mtime 晚于这个标记 ⇒ 用 find -newer 判定。
# 为什么不用「脚本开始时刻」直接比：find 的时间比较要**参照文件**（-newer FILE），
# 且各平台 find 对 -newermt 的支持不一致（busybox 只有 -newer）⇒ 落一个标记文件最稳。
# 标记建在**任何服务端写盘动作之前**（内置模式的清库/建库都在其后）⇒ 之后落进
# 存储根的文件必定是本轮造的。
SMOKE_RUN_MARKER="$SMOKE_RUN_DIR/art/run-start.marker"
: >"$SMOKE_RUN_MARKER" 2>/dev/null || true
BASE=${SMOKE_BASE:-http://127.0.0.1:18777}
PORT=18777
# 脚本自身目录（绝对路径）：内置模式会 cd 到 ../server ⇒ 相对路径全废
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 调用方 CWD（2026-11-10 #322：.env 探测用）——「./.env」指脚本启动时的目录，
# 必须在任何 cd 之前先钉死（内置模式随后会 cd 到 ../server，那时 CWD 已变）。
_SMOKE_CWD="$(pwd)"
PASS=0
FAIL=0
SKIP=0
ok() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
  throttle
}
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1  [$2]"
  throttle
}
# skip：断言域因**环境前置条件不足**无法执行（如外置实例没开 local_import）——
# 这不是产品缺陷，记 SKIP 而不是 FAIL。否则一轮真机冒烟里永远带着几个假红，
# 久了就没人看结果了（2026-10-22 真机跑全量冒烟时暴露）。
skip() {
  SKIP=$((SKIP + 1))
  echo "SKIP: $1  [$2]"
  throttle
}
# note：只记一笔、不计入 PASS/FAIL/SKIP —— 用于「判据被环境因素改写了」这类
# 必须留痕但本身不是断言的事实（否则日志里看不出这条 PASS 是怎么来的）。
note() { echo "NOTE: $1"; }
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
is_jerr() { case "$1" in JERR*) return 0 ;; *) return 1 ;; esac }

# ── 参数校验判据（pigeonbox#338：core#102 过滤参数 / core#104 分页参数）────
# 语义：过滤/分页参数解析失败 ⇒ 400 + 信封 code=10001 + message **点名参数**
# （core#102：不再「解析失败静默丢条件回全量」；core#104：不再「非数字静默当
# 默认页」）。判定只断言**结构事实**（HTTP 状态 / 信封 code / message 含参数名），
# 不比对本地化文案。
#
# judge_param_error <http_code> <body> <param> ⇒ GOOD / BAD:<原因>
judge_param_error() {
  _pjc=$1
  _pjb=$2
  _pjp=$3
  if [ "$_pjc" != "400" ]; then
    printf 'BAD:http=%s（期望 400）' "$_pjc"
    return 0
  fi
  _pjcode=$(printf '%s' "$_pjb" | J "d.get('code')")
  if is_jerr "$_pjcode"; then
    printf 'BAD:body 非 JSON（%s）' "$_pjcode"
    return 0
  fi
  if [ "$_pjcode" != "10001" ]; then
    printf 'BAD:code=%s（期望 10001）' "${_pjcode:-<空>}"
    return 0
  fi
  _pjm=$(printf '%s' "$_pjb" | J "(d.get('message') or '')")
  case "$_pjm" in
    *"$_pjp"*) printf 'GOOD' ;;
    *) printf 'BAD:message 未点名参数 %s（message=%s）' "$_pjp" "$_pjm" ;;
  esac
}

# judge_page_ok <http_code> <body> <max> ⇒ GOOD / BAD:<原因>
# 合法分页必须仍是 200 且条数 ≤ page_size —— 防「一律 400」的假修复。
judge_page_ok() {
  _pjc=$1
  _pjb=$2
  _pmax=$3
  if [ "$_pjc" != "200" ]; then
    printf 'BAD:http=%s（期望 200；合法分页不许 400）' "$_pjc"
    return 0
  fi
  _pjn=$(printf '%s' "$_pjb" | J "len((d.get('data') or {}).get('items') or (d.get('data') or {}).get('list') or [])")
  case "$_pjn" in
    JERR*) printf 'BAD:body 非 JSON（%s）' "$_pjn" ;;
    '' | None) printf 'BAD:响应没有 data.items/data.list 列表' ;;
    *)
      if [ "$_pjn" -le "$_pmax" ] 2>/dev/null; then
        printf 'GOOD'
      else printf 'BAD:返回 %s 条 > %s（page_size 未生效）' "$_pjn" "$_pmax"; fi
      ;;
  esac
}

# s35_expect_param_error <标签> <参数名> <鉴权头> <url>
s35_expect_param_error() {
  _s35r=$(curl -s -w '\n%{http_code}' "$4" -H "$3")
  _s35c=$(printf '%s\n' "$_s35r" | tail -n 1)
  _s35b=$(printf '%s\n' "$_s35r" | sed '$d')
  _s35v=$(judge_param_error "$_s35c" "$_s35b" "$2")
  if [ "$_s35v" = "GOOD" ]; then ok "$1"; else bad "$1" "$_s35v"; fi
}

# s35_expect_page_ok <标签> <鉴权头> <url>（page=1&page_size=5 ⇒ 200 且 ≤5 条）
s35_expect_page_ok() {
  _s35r=$(curl -s -w '\n%{http_code}' "$3" -H "$2")
  _s35c=$(printf '%s\n' "$_s35r" | tail -n 1)
  _s35b=$(printf '%s\n' "$_s35r" | sed '$d')
  _s35v=$(judge_page_ok "$_s35c" "$_s35b" 5)
  if [ "$_s35v" = "GOOD" ]; then ok "$1"; else bad "$1" "$_s35v"; fi
}

# ── --selfcheck-params：判据自证（对 stub 响应跑断言函数；不打任何服务）──────
# 负对照是关键：**旧版本语义**的响应（解析失败静默 200 全量 / 静默默认页）必须
# 判 BAD —— 这就是「对旧版本实例跑同一组断言必须红」的牙齿：判据能区分新旧语义，
# 升级前后跑同一脚本，红绿翻转即语义翻转的证明。
if [ "${1:-}" = "--selfcheck-params" ]; then
  PY="${SMOKE_PY:-python3}"
  command -v "$PY" >/dev/null 2>&1 || PY=python
  command -v "$PY" >/dev/null 2>&1 || {
    echo "需要 python3（断言解析用）" >&2
    exit 2
  }
  SC_BAD=0
  sc_case() { # <期望 GOOD|BAD> <实际 GOOD|BAD:原因> <说明>
    # 判定按**前缀**比对（BAD 可带原因后缀；结构事实不比对文案）
    _scv="${2%%:*}"
    if [ "$1" = "$_scv" ]; then
      echo "  ✓ $3 ⇒ $2"
    else
      echo "  ✗ $3 ⇒ $2（期望 $1）" >&2
      SC_BAD=1
    fi
  }
  # ① 新语义（core#102/#104 修复后）：400 + 10001 + 点名参数 ⇒ GOOD
  sc_case GOOD "$(judge_param_error 400 '{"code":10001,"message":"参数 created_after 取值 \"x\" 非法：期望 RFC3339 时间（如 2026-11-10T09:52:04+08:00）；注意 URL 里的 + 要编码成 %2B","trace_id":"t"}' created_after)" "① 新语义错误响应（400/10001/点名）"
  # ② 负对照：旧版本语义（解析失败静默丢条件 ⇒ 200 全量）⇒ 必须判 BAD
  sc_case BAD "$(judge_param_error 200 '{"code":0,"message":"success","data":{"total":122,"items":[]}}' created_after)" "② 负对照：旧语义 200 全量（对旧实例必须红）"
  # ③ 400 但业务码不对 ⇒ BAD
  sc_case BAD "$(judge_param_error 400 '{"code":400,"message":"参数 created_after 取值 \"x\" 非法"}' created_after)" "③ 400 但 code≠10001"
  # ④ 400+10001 但 message 不点名参数 ⇒ BAD
  sc_case BAD "$(judge_param_error 400 '{"code":10001,"message":"参数解析失败"}' created_after)" "④ message 不点名参数"
  # ⑤ body 非 JSON ⇒ BAD
  sc_case BAD "$(judge_param_error 400 '<html>bad request</html>' created_after)" "⑤ body 非 JSON"
  # ⑥ 合法分页：200 且 ≤5 条 ⇒ GOOD
  sc_case GOOD "$(judge_page_ok 200 '{"code":0,"message":"success","data":{"items":[{"id":1},{"id":2}],"total":2}}' 5)" "⑥ 合法分页 200 且 ≤5 条"
  # ⑦ 负对照：「一律 400」假修复 ⇒ 合法分页也 400 ⇒ 必须判 BAD
  sc_case BAD "$(judge_page_ok 400 '{"code":10001,"message":"参数 page 取值 \"1\" 非法"}' 5)" "⑦ 负对照：一律 400 假修复"
  # ⑧ 负对照：page_size 不生效（返回 6 条 > 5）⇒ 必须判 BAD
  sc_case BAD "$(judge_page_ok 200 '{"code":0,"data":{"items":[{"id":1},{"id":2},{"id":3},{"id":4},{"id":5},{"id":6}],"total":6}}' 5)" "⑧ 负对照：page_size 不生效（6 条 > 5）"
  # 清掉本轮 scratch（--selfcheck-params 不打服务，on_exit trap 尚未安装）
  case "$SMOKE_RUN_DIR" in
    "$SMOKE"/run-*) rm -rf "$SMOKE_RUN_DIR" 2>/dev/null || true ;;
  esac
  if [ "$SC_BAD" -ne 0 ]; then
    echo "--selfcheck-params 判据自证失败（判据没牙齿或误报）" >&2
    exit 1
  fi
  echo "✓ --selfcheck-params 判据自证通过：正判据 + 负对照（旧语义/一律400/超条数/非JSON/错码/不点名）全部按预期区分"
  exit 0
fi

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
USER_CFG_SNAP="$SMOKE_RUN_DIR/art/user-config-before.json"
USER_CFG_RESTORE_PENDING=0

# ── 探针登记（2026-11-10 #323）─────────────────────────────────────────────
# 冒烟造的每一条分享探针（匿名 + 带凭据的业务探针）都会在 file_codes 里留行、
# 在存储里留物理文件 ⇒ 上一版收尾不回收，真机每跑一轮攒一批残留（升级验收的
# 「DB 基线对账」断言全红，排查耗时比升级本身还多）。⇒ 每次创建探针分享后把
# 分享码登记进临时文件，收尾经**管理端**统一回收（cleanup_probes，见 trap 段前）；
# 2026-11-10 真机实测：匿名分享(user_id=NULL)在管理端可见且可删 ⇒ 缺口只在脚本。
PROBE_REG="${TMPDIR:-/tmp}/pb-smoke-probes.$$"
PROBE_CLEAN_PENDING=1
# 登记：只收**纯字母数字**的码（分享码/取件码形态；防异常响应片段混进 URL 与
# JSON 表达式）；空 / JERR / None 一律忽略 ⇒ 创建失败的探针不登记、也不会误删。
register_probe() {
  case "${1:-}" in
    '' | JERR* | None | none | null) return 0 ;;
    # 分享码/取件码可能含 '-' 或 '_'（脚本自己的 S5d 链接正则就是 [A-Za-z0-9_-]+）
    # ⇒ 白名单必须带上它们，否则**含 '-' 的码会被静默丢掉** ⇒ 登记不上 ⇒ 残留回收不掉。
    *[!A-Za-z0-9_-]*) return 0 ;;
  esac
  printf '%s\n' "$1" >>"$PROBE_REG" 2>/dev/null || true
}

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

# ── 探针回收 + 终验（2026-11-10 #323）─────────────────────────────────────
# cleanup_probes：逐登记码走**管理端**回收——GET /admin/files/filter?keyword=<码>
# 找 id ⇒ POST /admin/files/batch-delete {"ids":[id]}（软删 + 物理文件随之清理；
# 2026-11-10 真机实测该路径对匿名分享(user_id=NULL)同样生效）。匿名探针（无 owner）
# 无法走用户面回收，管理端是唯一统一出口。
# 幂等:PROBE_CLEAN_PENDING 在**尝试前**清零 ⇒ 正常末尾与 trap 各调一次只真正执行一次
# （与 USER_CFG_RESTORE_PENDING 同款机制）。
# 无可用 TOK（登录失败/未走到登录）⇒ 跳过并提示，不影响退出码——此时冒烟本身
# 已红（S4 登录失败 ⇒ 一串 FAIL），回收只是收尾卫生，不该再改判失败语义。
# probe_exact_ids <码>：打印该码在管理端**精确**匹配的行 id（每行一个）。
#
# ⚠️ 为什么不能图省事「keyword 命中数==1 就当是探针」：
#   filter 的 keyword 是 **code / uuid_file_name / text / pickup_code / file_path
#   五列 LIKE 匹配**（dao adminFileQuerySpec）⇒ 别人的分享**文本或路径里恰好
#   含我们的码**时也会命中 ⇒ 照着删会**误删他人分享**（比残留严重得多）。
#   ⇒ 候选 id 逐个取详情（GET /admin/files/:id），用 share.code /
#     share.pickup_code **精确相等**确认「这一行确实是我们造的探针」才认。
#   （管理端列表项不回 pickup_code ⇒ 只有详情端点能拿到取件码；
#     而匿名生成/访客投递/presign 三条探针**只回取件码** ⇒ 必须走详情。）
# 失败（响应不可解析）⇒ 返回非 0 ⇒ 调用方记「未核实」，不许当「查不到」。
probe_exact_ids() {
  _pe_code="$1"
  [ -n "$_pe_code" ] || return 0
  _pe_ids=$(curl -s "$BASE/admin/files/filter?page=1&page_size=50&keyword=$_pe_code&deleted=all" -H "$AH" |
    J "' '.join(str(x['id']) for x in d['data']['items'])")
  case "$_pe_ids" in JERR*) return 1 ;; esac
  for _pe_id in $_pe_ids; do
    [ -n "$_pe_id" ] || continue
    _pe_det=$(curl -s "$BASE/admin/files/$_pe_id" -H "$AH")
    _pe_c=$(printf '%s\n' "$_pe_det" | J "((d.get('data') or {}).get('share') or {}).get('code')")
    _pe_p=$(printf '%s\n' "$_pe_det" | J "((d.get('data') or {}).get('share') or {}).get('pickup_code')")
    if [ "$_pe_c" = "$_pe_code" ] || [ "$_pe_p" = "$_pe_code" ]; then
      printf '%s\n' "$_pe_id"
    fi
  done
  return 0
}

cleanup_probes() {
  [ "${PROBE_CLEAN_PENDING:-0}" = "1" ] || return 0
  PROBE_CLEAN_PENDING=0
  if [ ! -f "$PROBE_REG" ] || [ ! -s "$PROBE_REG" ]; then
    return 0
  fi
  case "${TOK:-}" in
    '' | JERR*)
      note "探针回收跳过（无可用管理端 TOK）⇒ 本轮探针码: $(sort -u "$PROBE_REG" 2>/dev/null | tr '\n' ' ')"
      return 0
      ;;
  esac
  _cp_n=0
  _cp_del=0
  _cp_miss=0
  _cp_amb=0
  # while-read 直读文件（不用 for $(cat) 分词，也避开管道子 shell 丢计数器）
  while IFS= read -r _cp_code; do
    [ -n "$_cp_code" ] || continue
    _cp_n=$((_cp_n + 1))
    # ⚠️ 2026-11-10 真机实录（103）：**不能靠列表项回显哪个字段命中**。
    # 探针码有两种形态：8 位分享码（share/code）与 6 位取件码（pickup_code）
    # —— 匿名生成、访客投递、presign 这三条路径**只回取件码**。
    # 而管理端列表项（core fileGovernanceItem）**只回分享码、不回 pickup_code**
    # ⇒ 旧写法「x['code']==码 or x.get('pickup_code')==码」对取件码**永远匹配不上**
    # ⇒ 回收跳过 ⇒ 探针行留在库里（实测残留 id=1668/1672 两行）。
    # 但 **filter 的 keyword 本身按 code/uuid_file_name/text/pickup_code/file_path
    # 五列 LIKE 匹配**（dao adminFileQuerySpec）⇒ 用取件码也能**唯一命中**那一行。
    # ⇒ 正确口径：**keyword 命中且唯一** ⇒ 取该行 id；命中多条 ⇒ 不可安全回收
    #   （宁可不删，也不能删错行——误删他人分享是更严重的事故）。
    _cp_ids=$(probe_exact_ids "$_cp_code")
    _cp_rc=$?
    if [ "$_cp_rc" != 0 ]; then
      _cp_id=""
      _cp_amb=1
    else
      # 多行命中 ⇒ 该码不唯一（同名不同分享）⇒ 逐个删（都是精确匹配到的）
      _cp_id=""
      _cp_ids_norm=$(printf '%s' "$_cp_ids" | tr '\n' ' ')
      for _cp_one in $_cp_ids_norm; do
        [ -n "$_cp_one" ] || continue
        if [ -z "$_cp_id" ]; then _cp_id="$_cp_one"; else _cp_id="$_cp_id,$_cp_one"; fi
      done
    fi
    if [ -n "$_cp_id" ] && [ "$_cp_id" != "None" ] && ! is_jerr "$_cp_id"; then
      # **必须硬删(purge)而不是软删(batch-delete)**：
      # 软删只是给行打上 deleted_at，**行仍留在 file_codes / file_code_files 里**
      # ⇒ 验收脚本的「DB 基线逐项对账」（比的是 COUNT(*)）照样红 ⇒ #323 的原始诉求没解决。
      # purge = 硬删 + 删无主物理文件，且带「秒传共享对象保护」
      #   （被别的分享共享的物理文件不会被误删）。
      # 老版本 core 没有 /admin/files/purge ⇒ 回落 batch-delete（至少把探针移出存活集）。
      _cp_resp=$(curl -s -X POST "$BASE/admin/files/purge" -H "$AH" -H 'Content-Type: application/json' \
        -d "{\"ids\":[$_cp_id]}")
      case "$_cp_resp" in
        *'"purged"'*) : ;;
        *) curl -s -X POST "$BASE/admin/files/batch-delete" -H "$AH" -H 'Content-Type: application/json' \
          -d "{\"ids\":[$_cp_id]}" >/dev/null ;;
      esac
      _cp_del=$((_cp_del + 1))
    else
      _cp_miss=$((_cp_miss + 1))
    fi
    throttle
  done <"$PROBE_REG"
  note "探针回收：登记 ${_cp_n} 条 ⇒ 发出删除 ${_cp_del} 条 / 未找到 ${_cp_miss} 条 / 命中多条未回收 ${_cp_amb} 条（终验见 S31）"
}

# verify_probes_gone：终验断言（只在**正常路径末尾**跑；trap 中断路径只回收不断言
# ——中断时 FAIL 计数已非 0，别再往噪声里添）。
# 判据：登记码在管理端 filter 里**查不到** ⇒ ok()；**还在** ⇒ bad()；
# **查询失败/响应不可解析** ⇒ 也 bad()——「核实不存在」与「没核实成」必须区分，
# 否则清理失效会被网络噪声盖成假绿（不 mask 失败）。
verify_probes_gone() {
  if [ ! -f "$PROBE_REG" ] || [ ! -s "$PROBE_REG" ]; then
    note "S31 探针终验跳过：本轮无登记探针（未走到分享创建段）"
    return 0
  fi
  case "${TOK:-}" in
    '' | JERR*)
      bad "S31 探针终验未跑" "无管理端 TOK ⇒ 无法核实探针是否回收（这不是绿灯，是没法核实）"
      return 0
      ;;
  esac
  _vg_tot=0
  _vg_left=""
  # while-read 直读文件（不用 for $(cat) 分词，也避开管道子 shell 丢计数器）
  while IFS= read -r _vg_code; do
    [ -n "$_vg_code" ] || continue
    _vg_tot=$((_vg_tot + 1))
    # ⚠️ 与 cleanup 同口径：**按详情精确匹配**判残留（share.code 或 share.pickup_code
    # 与登记码逐字相等），不看列表项回显哪个字段。
    # 旧写法 `any(x['code']==码)` 对**按取件码登记**的探针恒为 False
    # ⇒ 残留行被判成「已回收」⇒ **假绿**（2026-11-10 真机实录：残留 id=1668/1672
    # 却在 S31 报「全部回收」）。
    # 三态必须分清：**查不到**（已回收）/ **仍在**（残留）/ **没核实成**（查询失败）——
    # 「没核实成」不能当绿灯（否则网络噪声会把清理失效盖成假绿）。
    _vg_ids=$(probe_exact_ids "$_vg_code")
    _vg_rc=$?
    if [ "$_vg_rc" != 0 ]; then
      _vg_left="$_vg_left $_vg_code(未核实)"
    elif [ -n "$(printf '%s' "$_vg_ids" | tr -d ' \n')" ]; then
      _vg_left="$_vg_left $_vg_code(残留)"
    fi
    throttle
  done <"$PROBE_REG"
  if [ -z "$_vg_left" ]; then
    ok "S31 探针全部回收（${_vg_tot} 条登记码在管理端均查不到）"
  else
    bad "S31 探针残留或未核实" "登记 ${_vg_tot} 条 ⇒$_vg_left"
  fi
  # S32：**本轮新建的分享必须全部消失**（精确判据，不看全局总数）。
  #
  # ⚠️ 2026-11-10 真机实测修正（此前判据方向是反的）：
  #   旧判据「存活总数 ≥ 基线即过」**永远绿** ⇒ 泄漏方向（越跑越多）根本测不出来；
  #   而当时 CI 看到的「基线=0 现值=2」被误读成「他人新建的正常业务」，
  #   实测那 2 行**正是本轮冒烟自己漏下的探针**（id=1668/1672）⇒
  #   把真泄漏解释成了环境噪声，还顺手把判据放宽成永远绿。
  # ⇒ 正确口径：**基线 = 本轮开始时刻**；跑完后再取一次存活总数；
  #   差值 = 本轮净增的存活分享数 ⇒ 必须为 0（探针全回收）才算绿。
  #   仍用「总数」而非「探针集合」是因为 S31 已逐码断言过探针不在了，
  #   S32 是**独立的第二道闸**：万一某条探针压根没登记进 S31 的码表
  #   （漏登记造点），S31 看不见它，只有总数差能兜住 ⇒ 两道闸互补。
  #
  # 共享实例上「他人新建分享」确实会让总数变多 ⇒ 那种情况 S32 会红，
  # 但那是**真实需要人看一眼**的红（新增了谁？），不该被自动放宽成绿。
  if [ -n "${SMOKE_BASE_TOTAL:-}" ]; then
    _vg_after=$(curl -s "$BASE/admin/files/filter?page=1&page_size=1" -H "$AH" | J "d['data']['total']")
    case "${_vg_after:-}" in
      '' | *[!0-9]*)
        bad "S32 存活分享数读取失败" "total=${_vg_after:-空}（接口异常，不能判绿）"
        ;;
      *)
        if [ "$_vg_after" -eq "$SMOKE_BASE_TOTAL" ]; then
          ok "S32 存活分享数回到基线（基线=${SMOKE_BASE_TOTAL} 现值=${_vg_after}，本轮净增 0）"
        elif [ "$_vg_after" -lt "$SMOKE_BASE_TOTAL" ]; then
          bad "S32 存活分享数少于基线" "基线=${SMOKE_BASE_TOTAL} 现值=${_vg_after}（回收过头或他人删除，须核实）"
        else
          # 归因：净增的行若是**登记码**命中 ⇒ 本轮探针残留（回收没做干净）；
          # 都不命中 ⇒ 共享实例上他人新建（不是冒烟的锅）——两种成因分开报，
          # 别把「探针没回收」混进「环境噪声」里被自动放过（2026-11-10 的旧误读）。
          _vg_leak=""
          _vg_other=0
          # created_after 必须 --data-urlencode（+ 在 query 里会被解码成空格 ⇒
          # 服务端解析失败 ⇒ 静默丢条件 ⇒ 窗口失效；详见 SMOKE_RUN_START_ISO 处注释）。
          _vg_win=$(curl -s -G "$BASE/admin/files/filter" --data-urlencode "page=1" --data-urlencode "page_size=50" \
            --data-urlencode "created_after=${SMOKE_RUN_START_ISO}" -H "$AH" |
            J "' '.join(str(x['id']) for x in d['data']['items'])")
          case "$_vg_win" in JERR*) _vg_win="" ;; esac
          for _vg_one in $_vg_win; do
            [ -n "$_vg_one" ] || continue
            _vg_det=$(curl -s "$BASE/admin/files/$_vg_one" -H "$AH")
            _vg_c=$(printf '%s\n' "$_vg_det" | J "((d.get('data') or {}).get('share') or {}).get('code')")
            _vg_p=$(printf '%s\n' "$_vg_det" | J "((d.get('data') or {}).get('share') or {}).get('pickup_code')")
            _vg_hit=0
            while IFS= read -r _vg_rcode; do
              [ -n "$_vg_rcode" ] || continue
              if [ "$_vg_c" = "$_vg_rcode" ] || [ "$_vg_p" = "$_vg_rcode" ]; then
                _vg_hit=1
                break
              fi
            done <"$PROBE_REG"
            if [ "$_vg_hit" = 1 ]; then
              _vg_leak="$_vg_leak ${_vg_c:-$_vg_p}(探针)"
            else
              _vg_other=$((_vg_other + 1))
            fi
          done
          if [ -n "$_vg_leak" ]; then
            bad "S32 本轮探针未回收干净" "基线=${SMOKE_BASE_TOTAL} 现值=${_vg_after}；残留探针：${_vg_leak}（另有 ${_vg_other} 条非探针新增）"
          else
            bad "S32 本轮净增存活分享（非探针）" "基线=${SMOKE_BASE_TOTAL} 现值=${_vg_after}，净增 $((_vg_after - SMOKE_BASE_TOTAL)) 条，均不匹配登记码（疑为他人新建分享）——请核实"
          fi
        fi
        ;;
    esac
  else
    note "S32 计数基线跳过：运行前未能读到管理端存活数"
  fi
}

# ── S33/S34 收尾残留断言（#323 收尾口径）───────────────────────────────────
# S33：**存储根下本轮新增文件数 = 0**。
#   存储根 = /admin/diagnostics 的 data.storage.data_path（**服务端机器上的路径**）。
#   ⚠️ 外置实例（SMOKE_BASE 指到别的机器）时这个路径在本机不可达 ⇒ skip，
#      绝不把「数不到」当成「没有残留」（那是假绿）。
#   ⚠️ 非 local 后端（s3/oss/…）时 data_path 只承载分片临时/合并副本，
#      真正的分享文件在远端 ⇒ 本机磁盘数不出「新增分享文件」⇒ 同样 skip。
#   计数口径：mtime 晚于本轮起始标记（run-start.marker）的**普通文件**；
#   **排除 chunks/**（分片会话临时区：core 合并后异步清理 + janitor 兜底，
#   与「分享文件残留」不同源 ⇒ 单独计数并在消息里报出，不当残留判红）。
# S34：**冒烟账号（smoker / smoketotp）名下本轮新增分享数 = 0**。
#   账号可能运行前就存在（真机 253 的 smoker 名下有 20 条存量分享）⇒ 必须用
#   created_after 窗口圈「本轮新增」，不能按账号全量计数（那会把存量算成残留）。
#   口径含**软删行**（deleted=all）⇒ 软删残留也算残留：验收脚本的 DB 基线对账
#   比的是 COUNT(*) ⇒ 软删行照样占名额。
verify_storage_residue() {
  _sr_backend=$(printf '%s\n' "$D" | J "((d.get('data') or {}).get('storage') or {}).get('backend') or ''")
  _sr_path=$(printf '%s\n' "$D" | J "((d.get('data') or {}).get('storage') or {}).get('data_path') or ''")
  case "$_sr_path" in
    '' | None | JERR*)
      skip "S33 存储根下本轮新增文件数" "诊断未给出 storage.data_path（本机无从判定存储根）⇒ 不判绿"
      return 0
      ;;
  esac
  case "$_sr_backend" in
    local | Local | LOCAL) : ;;
    '')
      skip "S33 存储根下本轮新增文件数" "诊断未给出 storage.backend（无从确认后端类型）⇒ 不判绿"
      return 0
      ;;
    *)
      skip "S33 存储根下本轮新增文件数" "后端=${_sr_backend}（非 local）：data_path 只承载分片临时/合并副本，分享文件在远端 ⇒ 本机磁盘数不出残留"
      return 0
      ;;
  esac
  case "$_sr_path" in
    /*) : ;;
    *)
      skip "S33 存储根下本轮新增文件数" "存储根=${_sr_path} 是相对路径（相对服务端 CWD），本机无法解析 ⇒ 不判绿"
      return 0
      ;;
  esac
  _sr_root=${_sr_path%/}
  if [ ! -d "$_sr_root" ]; then
    skip "S33 存储根下本轮新增文件数" "存储根=${_sr_root} 在本机不可达（外置实例：路径在服务端机器上）⇒ 不判绿"
    return 0
  fi
  _sr_errf="$SMOKE_RUN_DIR/art/s33-find.err"
  _sr_list=$(find "$_sr_root" -path "$_sr_root/chunks" -prune -o -type f -newer "$SMOKE_RUN_MARKER" -print 2>"$_sr_errf")
  if [ -s "$_sr_errf" ]; then
    skip "S33 存储根下本轮新增文件数" "存储根=${_sr_root} 无法完整枚举（$(head -c 120 "$_sr_errf")）⇒ 不判绿"
    return 0
  fi
  _sr_n=$(printf '%s\n' "$_sr_list" | grep -c '[^[:space:]]' || true)
  _sr_chunk=0
  if [ -d "$_sr_root/chunks" ]; then
    _sr_clist=$(find "$_sr_root/chunks" -type f -newer "$SMOKE_RUN_MARKER" 2>/dev/null)
    _sr_chunk=$(printf '%s\n' "$_sr_clist" | grep -c '[^[:space:]]' || true)
  fi
  if [ "$_sr_n" -eq 0 ]; then
    ok "S33 存储根下本轮新增文件数 0（根=${_sr_root}；chunks 会话临时区另有 ${_sr_chunk} 个文件，core 合并后异步清理 + janitor 兜底，不计残留）"
  else
    bad "S33 存储根下本轮新增文件数非 0" "根=${_sr_root} 本轮新增 ${_sr_n} 个文件：$(printf '%s' "$_sr_list" | head -n 3 | tr '\n' ' ')"
  fi
}

verify_smoke_accounts_clean() {
  case "${TOK:-}" in
    '' | JERR*)
      skip "S34 冒烟账号本轮新增分享数" "无管理端 TOK ⇒ 无从核实（这不是绿灯，是没法核实）"
      return 0
      ;;
  esac
  for _sa_name in smoker smoketotp; do
    _sa_resp=$(curl -s -G "$BASE/admin/users/filter" --data-urlencode "keyword=$_sa_name" \
      --data-urlencode "page=1" --data-urlencode "page_size=50" -H "$AH")
    _sa_uid=$(printf '%s\n' "$_sa_resp" | J "next((str(u.get('id')) for u in ((d.get('data') or {}).get('list') or (d.get('data') or {}).get('items') or []) if (u.get('username') or '') == '$_sa_name'), '')")
    case "$_sa_uid" in
      '' | None | JERR*)
        skip "S34 冒烟账号本轮新增分享数（${_sa_name}）" "管理端用户列表里没有这个账号（本轮未创建/注册关闭）⇒ 无新增可判"
        continue
        ;;
    esac
    _sa_cnt=$(curl -s -G "$BASE/admin/files/filter" --data-urlencode "page=1" --data-urlencode "page_size=100" \
      --data-urlencode "user_id=$_sa_uid" --data-urlencode "created_after=$SMOKE_RUN_START_ISO" \
      --data-urlencode "deleted=all" -H "$AH" | J "str((d.get('data') or {}).get('total'))")
    case "$_sa_cnt" in
      '' | None | JERR*)
        bad "S34 冒烟账号本轮新增分享数（${_sa_name}）" "查询失败（total=${_sa_cnt:-空}）⇒ 不能判绿"
        continue
        ;;
    esac
    if [ "$_sa_cnt" -eq 0 ]; then
      ok "S34 冒烟账号本轮新增分享数 0（${_sa_name} id=${_sa_uid}）"
    else
      bad "S34 冒烟账号本轮新增分享数非 0" "${_sa_name}（id=${_sa_uid}）本轮新增 ${_sa_cnt} 条 ⇒ 冒烟账号名下留了分享（回收没做干净）"
    fi
  done
}

# 退出钩子:顺序不可换 —— **先回收探针、再还原**(都要打服务端 API)、最后杀本地 server。
# ⚠️ 探针回收(#323)必须排在**还原用户配置之前**：两步都用「刚登录的 TOK」打管理端
#    API，而还原会把用户配置(含 sessionexpiryhours)写回原值——先做还原再回收的话，
#    万一会话有效性被还原动作改写，探针就收不干净了（先收探针 ⇒ 再还原 ⇒ 再杀）。
# shellcheck disable=SC2317,SC2329  # 由 trap 间接调用（不同 shellcheck 版本报不同码：旧版 SC2317「命令不可达」/ 新版 SC2329「函数从未被调用」）
on_exit() {
  _want="${1:-$?}"
  cleanup_probes
  restore_user_config
  # ⚠️ **未定义变量退出时 bash 3.2 给 trap 的 `$?` 是 0**（不是失败码）
  #    ⇒ 单靠 `_want` 会把失败吞成成功 ⇒ 用成功哨兵兜底：
  #    没跑到结尾（OK≠1）却没留下失败码 ⇒ 判失败。
  #    （INT/TERM 那一路显式传了 130/143 ⇒ 不受影响。）
  # 用显式 if 而不是 `[ -n "$X" ] && kill …`：后者的复合状态在 X 为空时是 1
  # （旧版 shellcheck 判其后语句「不可达」⇒ SC2317；且读起来像「exit 走不到」）。
  rm -f "$PROBE_REG" 2>/dev/null
  # 本轮独占 scratch 目录自清理：每轮会留下 ~300KB fixture（big-a.txt 等）
  # ⇒ 跑几十轮就堆积在 $SMOKE 下 ⇒ 退出时删掉**自己建的**那一个。
  # 顺序：**必须在 restore_user_config 之后**（还原要读 run 目录里的配置快照）。
  # 路径守卫：只删 $SMOKE/run-* 形态（防止变量被改坏后误删别的东西）。
  case "${SMOKE_RUN_DIR:-}" in
    "$SMOKE"/run-*) rm -rf "$SMOKE_RUN_DIR" 2>/dev/null || true ;;
  esac
  if [ -n "${SRV:-}" ]; then kill "$SRV" 2>/dev/null || true; fi
  if [ -n "${RPID:-}" ]; then kill "$RPID" 2>/dev/null || true; fi
  if [ "$FAIL" -gt 0 ]; then exit "$FAIL"; fi
  if [ "$_want" -ne 0 ]; then exit "$_want"; fi
  if [ "${OK:-0}" != 1 ]; then exit 1; fi
  exit 0
}
OK=0
trap on_exit EXIT
trap 'on_exit 130' INT
trap 'on_exit 143' TERM

# 显式列目录，不用 mkdir 的 {a,b} brace expansion（dash 下会建出字面量目录
# "{data,uploads,import,src}" ⇒ 后续写 $SMOKE/import/... 全部失败）。
mkdir -p "$SMOKE/data" "$SMOKE/uploads" "$SMOKE/import" "$SMOKE/src"
# fixture/产物一律写到 ${SMOKE_RUN_DIR}（本轮独占子目录）⇒ 理由与做法见文件头部。
# $SMOKE/import、$SMOKE/data、$SMOKE/uploads 是**服务端要读的路径** ⇒ 保持原位。
echo "smoke-local-content-$(date +%s)" >"$SMOKE/import/local-nas.txt"
printf 'hello-pigeonbox-range' >"$SMOKE_RUN_DIR/src/smoke-range.txt"
# ⚠️ 分片测试文件的内容**必须每轮唯一**（2026-10-30 真机实录）：
#   分片会话的键 = 文件内容的 sha256 ⇒ 内容固定 ⇒ upload_id 固定 ⇒
#   上一轮留下的会话（**归属上一轮的来源 IP**，且未 complete 时状态仍是 pending）
#   会让本轮的 init 撞「他人进行中的会话」⇒ 409 ⇒ upload_id 取空 ⇒
#   后续分片请求打到 /chunk/upload/chunk//0 ⇒ 报 400/404 ⇒ 一串**假红**。
#   （S11b/S11b2 的「同 hash 二次 init」断言是**轮内**语义 ⇒ 每轮唯一不影响它们。）
#   ⇒ 用 20 位定长 run 标记做前缀，**保持字节数不变**（300000 / 1024）。
RUN_TAG=$(printf '%020d' $(($(date +%s) * 1000 + $$ % 1000)))
{
  printf 'smoke-run-%s' "$RUN_TAG"
  head -c 299970 /dev/zero | tr '\0' 'A'
} >"$SMOKE_RUN_DIR/src/big-a.txt"
{
  printf 'smoke-run-%s' "$RUN_TAG"
  head -c 994 /dev/zero | tr '\0' 'B'
} >"$SMOKE_RUN_DIR/src/bad-chunk.bin"
echo "multi-file-one" >"$SMOKE_RUN_DIR/src/m1.txt"
echo "multi-file-two" >"$SMOKE_RUN_DIR/src/m2.txt"

# python:断言解析用。python3 优先,退化到 python（部分 NAS 只有 python2;
# 断言里没用 f-string,py2 可跑）。
# ⚠️ 必须放在**顶层**（两种模式都要用）：此前定义在内置模式分支内 ⇒
# 外置模式（SMOKE_BASE）下 PY 未定义 ⇒ set -u 直接报 "PY: unbound variable"
# ⇒ 所有 JSON 解析断言全红（2026-10-22 murphy-server 真机跑时抓到）。
PY="${SMOKE_PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || {
  echo "需要 python3（断言解析用）;请先安装"
  exit 1
}

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
  cat >"${SMOKE}/config.yaml" <<EOF
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
    [ -x "$SMOKE_BIN" ] || {
      echo "SMOKE_BIN 不可执行: $SMOKE_BIN"
      exit 1
    }
    cp -f "$SMOKE_BIN" "${SMOKE}/server-bin"
    chmod +x "${SMOKE}/server-bin"
    echo "  使用现成二进制: $SMOKE_BIN"
  else
    command -v go >/dev/null 2>&1 || {
      echo "需要 go（编译服务端）或用 SMOKE_BIN 指定现成二进制"
      exit 1
    }
    cd "$(dirname "$0")/../server" || exit 1
    go build -o "${SMOKE}/server-bin" ./cmd/server || {
      echo "BUILD FAILED"
      exit 1
    }
  fi
  # jwt secret 启动时定死一份（≥32 字符才过配置校验），供 S25/S26 离线命令沿用。
  # 不能到用时再 date +%s 现生成——与实例手上的不一致，且不够长；
  # /proc/<pid>/environ 探测只在 Linux 成立（macOS 无 /proc ⇒ 2026-11-02
  # 本机实测 S25a/S26a 假红）⇒ 这份 shell 变量是跨平台的真相源。
  SMOKE_JWT="smoke-secret-$(date +%s)-padded-to-exceed-32chars"
  PB_JWT_SECRET=$SMOKE_JWT "${SMOKE}/server-bin" --config "${SMOKE}/config.yaml" >"${SMOKE}/server.log" 2>&1 &
  SRV=$!
  if [ "$HAVE_REDIS" = 1 ]; then
    redis-server --port 16379 --daemonize no --save '' --appendonly no >"$SMOKE/redis.log" 2>&1 &
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
  curl -sf "$BASE/health" >/dev/null || {
    echo "SERVER NOT UP"
    tail -20 "${SMOKE}/server.log"
    exit 1
  }
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
  _rl_try=$((_rl_try + 1))
  if [ "$_rl_try" -gt 18 ]; then
    echo "限流预算未恢复(429，已等 $((_rl_try * 5))s) ⇒ 本轮放弃（**不是产品缺陷**：上一轮冒烟的请求还在限流窗口内，稍后重跑即可）"
    exit 1
  fi
  sleep 5
done
[ "$_rl_try" -gt 0 ] && echo "（限流预算已恢复：等了 $((_rl_try * 5))s）"

# S1 健康面
[ -n "$(curl -s "$BASE/live")" ] && ok "S1a live" || bad "S1a live" "$(curl -s "$BASE/live")"
curl -s "$BASE/readyz" | grep -qi 'ok\|ready\|true' && ok "S1b readyz" || bad "S1b readyz" "$(curl -s "$BASE/readyz" | head -c 120)"
# S1c /version 已收归管理员（2026-10-06 攻击面收缩：版本披露辅助 CVE 匹配），
# 未认证应为 401；带 admin token 可读（TOK 在 S3 段取得，此处先做未认证断言）
V=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/version")
[ "$V" = "401" ] && ok "S1c version 未认证 401" || bad "S1c version 未认证 401" "$V"

# S2 openapi.json 运行时生成
# ⚠️ 该端点**是否注册**跟随生效配置的 ui.expose_openapi（core v0.33.7 起）：
#   关掉开关后它就是 404 —— 这是正确行为，不是缺陷。
#   4.9.1 之前这里读的是**启动期的包级 config**（全局配置改 copy-on-write 换指针后，
#   那个变量指向被换掉的旧对象）⇒ "关掉 API 文档"永不生效，端点一直暴露；
#   修好之后关闭态真的 404 了，而本脚本仍按"一直开着"断言 ⇒ 三条恒红假红。
#   ⇒ 开启态跑三条形状断言；关闭态改断言"必须 404 **且** apiDocsEnabled=false"，
#     开关与路由不一致才是真缺陷（真空转成假绿才是要防的事）。
OA_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/openapi.json")
if [ "$OA_CODE" = "200" ]; then
  OA=$(curl -s "$BASE/openapi.json")
  printf '%s\n' "$OA" | grep -q '"/share/metadata/{code}"' && ok "S2a openapi 含 metadata 端点" || bad "S2a openapi metadata" "-"
  printf '%s\n' "$OA" | grep -q '"/admin/local-files"' && ok "S2b openapi 含 local-files 端点" || bad "S2b openapi local-files" "-"
  N=$(printf '%s\n' "$OA" | J "len(d['paths'])")
  case "$N" in JERR* | "") bad "S2c openapi paths 数" "$N" ;; [0-9]*) [ "$N" -ge 90 ] && ok "S2c openapi paths=$N" || bad "S2c openapi paths=$N" "<90" ;; esac
else
  ADV=$(curl -s "$BASE/api/config" | J "d['data'].get('apiDocsEnabled')")
  case "$ADV" in
    False) skip "S2 openapi 已由配置关闭（expose_openapi=false ⇒ ${OA_CODE}），开关与路由一致" "http=${OA_CODE}" ;;
    *) bad "S2 openapi 关闭态自相矛盾（端点 ${OA_CODE} 但 apiDocsEnabled=${ADV}）" "-" ;;
  esac
fi

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
#
# ── 管理口令来源探测链（2026-11-10 #322）──────────────────────────────────
# 口令默认写死 admin123 ⇒ 在**改了口令**的站上不传 SMOKE_ADMIN_PASSWORD 就是
# 16 条断言连环假红（2026-11-10 真机实录：.env 是强口令，未传 ⇒ 16 FAIL，看起来
# 像升级把功能改坏了；传对口令即 PASS=133 FAIL=0 与基线一致）。⇒ 探测链（高→低）：
#   ① 环境变量 SMOKE_ADMIN_PASSWORD（显式最高优先）；
#   ② 常见部署目录 .env 里的 PB_ADMIN_PASSWORD（高→低，取存在的第一个）：
#     $PIGEONBOX_DIR/.env → 调用方 CWD/.env → /opt/pigeonbox/.env（compose/官方镜像）
#     → /vol1/@appdata/pigeonbox/.env（**fnOS 正式应用目录**：真机 253 的 .env
#       实际落在这里，缺这一条 ⇒ fnOS 上的冒烟永远探测不到真口令 ⇒ 一屏假红，
#       看着像「升级把功能改坏了」）；
#   ③ 都没有才回落 admin123，并**明确提示**（不是静默回落）。
# 来源一律打印一行（日志里可对账「这次冒烟用的是哪个口令」）。
# .env 解析（POSIX：grep/sed/参数展开）：KEY=VALUE / export KEY=VALUE / 行首缩进 /
# 行首注释跳过 / 单双引号剥离 / CRLF 剥除；值剥完为空视为**未设**（fnOS 的 .env
# 常见 PB_ADMIN_PASSWORD=""＝未启用 prewire ⇒ 不能当口令用，继续探测链）。
read_env_key() {
  [ -f "$1" ] || return 1
  _ek_line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${2}[[:space:]]*=" "$1" 2>/dev/null | head -n 1)
  [ -n "$_ek_line" ] || return 1
  _ek_line=$(printf '%s\n' "$_ek_line" | tr -d '\r')
  _ek_v=${_ek_line#*=}
  case "$_ek_v" in
    '"'*)
      _ek_v=${_ek_v#'"'}
      _ek_v=${_ek_v%'"'}
      ;;
    "'"*)
      _ek_v=${_ek_v#"'"}
      _ek_v=${_ek_v%"'"}
      ;;
    *) _ek_v=$(printf '%s\n' "$_ek_v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') ;;
  esac
  [ -n "$_ek_v" ] || return 1
  printf '%s' "$_ek_v"
}
SMOKE_ADMIN_PW="${SMOKE_ADMIN_PASSWORD:-}"
SMOKE_ADMIN_PW_SRC=""
if [ -n "$SMOKE_ADMIN_PW" ]; then
  SMOKE_ADMIN_PW_SRC="SMOKE_ADMIN_PASSWORD"
else
  for _ek_cand in "${PIGEONBOX_DIR:+$PIGEONBOX_DIR/.env}" "${_SMOKE_CWD}/.env" "/opt/pigeonbox/.env" "/vol1/@appdata/pigeonbox/.env"; do
    [ -n "$_ek_cand" ] || continue
    _ek_got=$(read_env_key "$_ek_cand" PB_ADMIN_PASSWORD) || continue
    SMOKE_ADMIN_PW="$_ek_got"
    SMOKE_ADMIN_PW_SRC=".env($_ek_cand)"
    break
  done
fi
if [ -n "$SMOKE_ADMIN_PW" ]; then
  echo "[smoke] 管理口令来源: $SMOKE_ADMIN_PW_SRC"
else
  SMOKE_ADMIN_PW="admin123"
  SMOKE_ADMIN_PW_SRC="默认值"
  echo "[smoke] 管理口令来源: $SMOKE_ADMIN_PW_SRC"
  echo "[smoke] ⚠️ 当前用默认口令 admin123——若站点已改口令请传 SMOKE_ADMIN_PASSWORD（或让部署目录 .env 里的 PB_ADMIN_PASSWORD 可被探测到）"
fi
TOK=$(curl -s -X POST "$BASE/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"${SMOKE_ADMIN_USER:-admin}\",\"password\":\"$SMOKE_ADMIN_PW\"}" | J "d['data']['token']")
[ -n "$(curl -s "$BASE/version" -H "Authorization: Bearer $TOK")" ] && ok "S3a0 version admin 可读" || bad "S3a0 version admin 可读" "-"
[ -n "$TOK" ] && [ "${TOK#JERR}" = "$TOK" ] && ok "S4 admin 登录" ||
  bad "S4 admin 登录" "${TOK}（口令来源: ${SMOKE_ADMIN_PW_SRC:-未知}——401 多半是口令不符，用 SMOKE_ADMIN_PASSWORD= 显式传）"
AH="Authorization: Bearer $TOK"
SMOKE_ADMIN_TOKEN="$TOK"
export SMOKE_ADMIN_TOKEN
# 探针基线（#323）：跑之前记下管理端**存活分享数**，收尾回收后必须回到这个数。
# 为什么不能只看「探针查不到了」：软删的行仍占着 file_codes 计数 ⇒ 验收脚本的
# 「DB 基线逐项对账」照样红 ⇒ 回收必须**硬删**才真的把计数打回基线。
SMOKE_BASE_TOTAL=$(curl -s "$BASE/admin/files/filter?page=1&page_size=1" -H "$AH" | J "d['data']['total']")
case "$SMOKE_BASE_TOTAL" in '' | JERR* | None) SMOKE_BASE_TOTAL="" ;; esac
# 本轮开始时刻（S32 圈「本轮新建」用）：管理端按 RFC3339 解析 created_after，
# 而服务端的 created_at 存的是**本地时区**（真机 +08:00）⇒ 必须给本地时刻 +
# 时区偏移，不能用 UTC（否则差 8 小时 ⇒ 窗口圈错 ⇒ 归因失效）。
# 取整到秒（服务端 created_at 带微秒 ⇒ 用 >= 比较时同秒的行仍会被圈进来，
# 那正是我们要的：本轮新建的都算）。
SMOKE_RUN_START_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
# ⚠️ created_after 的值必须**百分号编码**后进 URL，否则窗口静默失效（实测两处）：
#   ① query string 里的 **+ 会被解码成空格**（application/x-www-form-urlencoded 语义）
#      ⇒ 直接拼 "…T09:52:04+08:00" 到达服务端时是 "…T09:52:04 08:00"
#      ⇒ time.Parse(RFC3339) 失败 ⇒ **条件被静默丢弃**（core admin_manage.go：
#         解析失败即不设 q.CreatedAfter，**无日志、无 400**）⇒ 返回全量数据
#      ⇒ 以为圈出了「本轮窗口」、实际什么都没筛 ⇒ 归因面失效。
#      实测（103，未编码）："+08:00" ⇒ total=122（全量）；"+0800" ⇒ total=122（全量）。
#   ② Go 的 time.RFC3339 **不接受紧凑偏移** "+0800"（必须 "+08:00"）
#      ⇒ 即便编码正确，"+0800" 仍解析失败 ⇒ 同样被静默丢弃。
#      实测（103，已编码 %2B）："+08:00" ⇒ total=0（过滤生效）；"+0800" ⇒ total=122（全量）。
# ⇒ 结论：**两个条件都要满足** —— ① 用 --data-urlencode 编码（curl 会把 + 编成 %2B）；
#   ② 用带冒号的 "+08:00" 形态。少任何一条，服务端都会静默忽略整个时间窗。
# ⇒ 这里把 %z 的 +0800 改写成 +08:00；%z 若为空（老 busybox）则退回不带偏移
#    （服务端按 UTC 解释 ⇒ 窗口会偏 8 小时 ⇒ 归因不准 ⇒ 记 note 提示）。
# 偏移量转成 **+08:00** 形态：**用 $PY 算，不用 sed / 参数展开**——
#   ① BSD sed 与 GNU sed 对含 [+-] 的替换模式行为不同（macOS 上报
#      "unescaped newline inside substitute pattern" ⇒ 整行被清空）；
#   ② POSIX 参数展开的 % / # 是**最短**匹配，剥不掉 "+0800" 这种尾巴。
# $PY 在此处已就绪（脚本前段就完成了 python3→python 的退化）。
SMOKE_RUN_START_ISO=$("$PY" -c "
import datetime, sys
# date %z 给的是 +0800 ⇒ 补冒号成 +08:00（RFC3339 要求）
s = sys.argv[1]
if len(s) > 5 and s[-5] in '+-' and s[-4:].isdigit():
    s = s[:-5] + s[-5] + s[-4:-2] + ':' + s[-2:]
print(s)
" "$SMOKE_RUN_START_ISO" 2>/dev/null || SMOKE_RUN_START_ISO="$(date +%Y-%m-%dT%H:%M:%S)")
case "$SMOKE_RUN_START_ISO" in
  *[+-][0-9][0-9]:[0-9][0-9]) : ;;
  *)
    # 无偏移形态**不是合法 RFC3339**（缺时区）⇒ 服务端解析失败 ⇒ 条件被静默丢弃
    # ⇒ 窗口彻底失效且毫无征兆 ⇒ 宁可退回 **UTC 的 Z 形态**（仍是合法 RFC3339、
    # 指向同一瞬间）⇒ 窗口准确，只是与 DB 字面时区不同（服务端按瞬间比较，实测一致）。
    SMOKE_RUN_START_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    note "S32 归因窗口：本地时区偏移不可用 ⇒ 退回 UTC(Z) 形态（窗口仍准确）"
    ;;
esac

# S4a/S4b 部署自检端点（2026-10-30）：/admin/diagnostics 是**管理面**端点 ——
# 未认证必须 401（不能给公网开新的信息面）；带 admin token 必须可读且带回
# database/storage 等运行事实（官方 CLI `pb doctor` 消费的就是这一份）。
D_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/admin/diagnostics")
[ "$D_CODE" = "401" ] && ok "S4a /admin/diagnostics 未认证 401" || bad "S4a /admin/diagnostics 未认证 401" "$D_CODE"
D=$(curl -s "$BASE/admin/diagnostics" -H "$AH")
printf '%s\n' "$D" | J "'database' in d['data'] and 'storage' in d['data'] and 'capabilities' in d['data']" | grep -q True && ok "S4b /admin/diagnostics 含 database/storage/capabilities" || bad "S4b /admin/diagnostics 字段" "$(printf '%s\n' "$D" | head -c 120)"
SMOKE_BASE="$BASE"
export SMOKE_BASE

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
  # ⚠️ 响应体必须留全（原写法 -o /dev/null 只留状态码 ⇒ 建出来的分享拿不到码
  #    ⇒ 无法登记回收 ⇒ 探针残留）。code 在倒数第二段，状态码在最后一段。
  S4F_RESP=$(curl -s -w '\n%{http_code}' -X POST "$BASE/share/text/" -H "$SC_HDR" \
    -H 'Content-Type: application/json' -d '{"text":"smoke-scope-share","expire_value":1,"expire_style":"day","require_auth":false}')
  S4F=$(printf '%s\n' "$S4F_RESP" | tail -n 1)
  register_probe "$(printf '%s\n' "$S4F_RESP" | sed '$d' | J "d['data']['code']")"
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
    [ "$SC_REVOKED" = "True" ] && ok "S4g 测试用受限 Key 已吊销（回读 revoked=true）" ||
      bad "S4g 测试用受限 Key 已吊销" "id=$SC_ID 回读 revoked=${SC_REVOKED}（期望 True）"
  else
    bad "S4g 测试用受限 Key 已吊销" "拿不到 id"
  fi
else
  bad "S4c 受限 Key 创建" "拿不到 key（服务端未实现 scopes？）"
fi

# S5 文本分享
CODE_T=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-hello","expire_value":1,"expire_style":"day","require_auth":false}' | J "d['data']['code']")
[ -n "$CODE_T" ] && ! is_jerr "$CODE_T" && ok "S5 文本分享 code=$CODE_T" || bad "S5 文本分享" "$CODE_T"
register_probe "$CODE_T"
# S5b 文本分享响应必须带 6 位取件码（文本/文件同权铸造；前端快捷取件卡依赖，2026-10-15 回归守卫）
# 响应体留全（原写法只取 pickup_code ⇒ 建出的分享拿不到码 ⇒ 无法登记回收）
S5B_RESP=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-pickup","expire_value":1,"expire_style":"day","require_auth":false}')
PICKUP_T=$(printf '%s\n' "$S5B_RESP" | J "d['data']['pickup_code']")
register_probe "$(printf '%s\n' "$S5B_RESP" | J "d['data']['code']")"
printf '%s\n' "$PICKUP_T" | grep -qE "^[A-Z0-9]{6}$" && ok "S5b 文本分享铸 pickup_code=$PICKUP_T" || bad "S5b 文本分享 pickup_code 缺失" "$PICKUP_T"
# S5c 取件响应文本分享必须回传 share_code（前端跳详情页展示文本依赖，2026-10-15 回归守卫）
SC_T=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_T\"}" | J "d['data']['share_code']")
[ "$SC_T" != "None" ] && [ -n "$SC_T" ] && ! is_jerr "$SC_T" && ok "S5c 取件回传 share_code=$SC_T" || bad "S5c 取件 share_code 缺失" "$SC_T"

# S5d 分享链接形态守卫（2026-10-22 真机定位的「死链」修复）：
# 页面链接必须是 hash 路由 {base}/#/share/{code}——前端是 createWebHashHistory，
# 路径形态 {base}/share/{code} 在浏览器里打不开（docker 端 nginx 反代后端→后端
# 无此路由→404；原生端 SPA 回退的相对资源路径解析错→白屏）。此前后端下发的
# 是路径形态 ⇒ MCP/脚本/IM 机器人拿到的分享链接全是死链（前端有转换兜底，后端没有）。
S5D_RESP=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"smoke-text-url","expire_value":1,"expire_style":"day","require_auth":false}')
SHARE_URL_T=$(printf '%s\n' "$S5D_RESP" | J "d['data']['url']")
register_probe "$(printf '%s\n' "$S5D_RESP" | J "d['data']['code']")"
printf '%s\n' "$SHARE_URL_T" | grep -qE "/#/share/[A-Za-z0-9_-]+$" && ok "S5d 分享链接为 hash 路由形态" || bad "S5d 分享链接形态（须 {base}/#/share/CODE）" "$SHARE_URL_T"

# S5e 取件码可直接当分享页链接用（2026-10-23 新能力）
# 此前取件码（6 位）只能走匿名通道 /anonymous/retrieve 取件，**没有页面链接**——
# 分享页路由 /share/:code → /share/select/?code= 只认 8 位分享码（file_codes.code），
# 拿取件码去查必然 404。现在分享域「按码取分享」同时认 6 位取件码（真相源
# file_codes.pickup_code 列）⇒ /#/share/{取件码} 可直接打开取件页。
PSEL=$(curl -s "$BASE/share/select/?code=$PICKUP_T")
PSHARE=$(printf '%s\n' "$PSEL" | J "d['data'].get('code')")
[ -n "$PSHARE" ] && [ "$PSHARE" != "None" ] && [ ${#PSHARE} -eq 8 ] &&
  ok "S5e 取件码可当分享页链接（归一为 8 位分享码 ${PSHARE}）" ||
  bad "S5e 取件码应能经分享域解析" "$(printf '%s\n' "$PSEL" | head -c 120)"

# S6 metadata（text）
MD=$(curl -s "$BASE/share/metadata/$CODE_T")
[ "$(printf '%s\n' "$MD" | J "d['data']['type']")" = "text" ] && ok "S6a metadata type=text" || bad "S6a metadata text" "$MD"
[ "$(printf '%s\n' "$MD" | J "d['data']['has_password']")" = "False" ] && ok "S6b metadata has_password=false" || bad "S6b metadata" "$MD"
printf '%s\n' "$MD" | grep -q "smoke-text-hello" && bad "S6c metadata 泄露文本内容!" "$MD" || ok "S6c metadata 不外泄内容"

# S7 select 查询不扣次数 + 下载（次数=1 的分享，查询 3 次后仍可下载）
CODE_1=$(curl -s -X POST "$BASE/share/text/" -H 'Content-Type: application/json' -d '{"text":"once-only","expire_value":1,"expire_style":"count","require_auth":false}' | J "d['data']['code']")
register_probe "$CODE_1"
SEL=$(curl -s "$BASE/share/select/?code=$CODE_1")
DL=$(printf '%s\n' "$SEL" | J "d['data']['download_url']")
case "$DL" in /*) DL="$BASE$DL" ;; esac
for _ in 1 2 3; do curl -s "$BASE/share/select/?code=$CODE_1" >/dev/null; done
BODY=$(curl -s "$DL")
printf '%s\n' "$BODY" | grep -q "once-only" && ok "S7 select 不扣次数+令牌下载" || bad "S7 下载" "$(printf '%s\n' "$BODY" | head -c 80)"

# S8 密码分享
CODE_P=$(curl -s -X POST "$BASE/share/text/" -F "text=secret-pwd" -F "expire_value=1" -F "expire_style=day" -F "require_auth=true" -F "password=pw123" | J "d['data']['code']")
register_probe "$CODE_P"
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
register_probe "$LOCKC"
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
CODE_F=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE_RUN_DIR/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false" | J "d['data']['code']")
[ -n "$CODE_F" ] && ! is_jerr "$CODE_F" && ok "S9a 文件分享 code=$CODE_F" || bad "S9a 文件分享" "$CODE_F"
register_probe "$CODE_F"
# S9a2 文件分享响应带 6 位取件码 + select 带 download 令牌（契约字段齐套回归守卫）
# 响应体留全（原写法只取 pickup_code ⇒ 建出的分享拿不到码 ⇒ 无法登记回收）
S9A2_RESP=$(curl -s -X POST "$BASE/share/file/" -F "file=@$SMOKE_RUN_DIR/src/smoke-range.txt" -F "expire_value=1" -F "expire_style=day" -F "require_auth=false")
PICKUP_F=$(printf '%s\n' "$S9A2_RESP" | J "d['data']['pickup_code']")
register_probe "$(printf '%s\n' "$S9A2_RESP" | J "d['data']['code']")"
printf '%s\n' "$PICKUP_F" | grep -qE "^[A-Z0-9]{6}$" && ok "S9a2 文件分享铸 pickup_code=$PICKUP_F" || bad "S9a2 文件分享 pickup_code" "$PICKUP_F"
# S9a3 文件分享取件 share_code 恒空（契约：share_code 仅文本分享回传，文件走 download_url）
# 注意用 .get()：文件分享的响应里该键是「不存在」而非 null，取不到时 J 助手返回
# "None"（旧写法 d['data']['share_code'] 遇缺键抛 KeyError → 断言恒假）
[ "$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' -d "{\"code\":\"$PICKUP_F\"}" | J "d.get('data',{}).get('share_code')")" = "None" ] && ok "S9a3 文件取件 share_code 恒空(契约)" || bad "S9a3 文件取件不应回传 share_code" "-"
[ "$(curl -s "$BASE/share/metadata/$CODE_F" | J "d['data']['name']")" = "smoke-range.txt" ] && ok "S9b metadata 文件名" || bad "S9b metadata name" "-"
DLF=$(curl -s "$BASE/share/select/?code=$CODE_F" | J "d['data']['download_url']")
case "$DLF" in /*) DLF="$BASE$DLF" ;; esac
R=$(curl -s -H "Range: bytes=0-4" -o /dev/null -w "%{http_code}" "$DLF")
[ "$R" = "206" ] && ok "S9c Range 206" || bad "S9c Range" "$R"
PART=$(curl -s -H "Range: bytes=0-4" "$DLF")
[ "$PART" = "hello" ] && ok "S9d Range 内容正确" || bad "S9d Range 内容" "$PART"

# S10 多文件直传 + zip
CODE_M=$(curl -s -X POST "$BASE/api/v1/share/multi-direct" -F "files=@$SMOKE_RUN_DIR/src/m1.txt" -F "files=@$SMOKE_RUN_DIR/src/m2.txt" -F "expire_value=1" -F "expire_style=day" | J "d['data']['code']")
[ -n "$CODE_M" ] && ! is_jerr "$CODE_M" && ok "S10a 多文件分享 code=$CODE_M" || bad "S10a 多文件" "$CODE_M"
register_probe "$CODE_M"
# S10a2 select 的 download_url 必须带签名令牌（缺令牌直链 401——历史事故回归守卫）
curl -s "$BASE/share/select/?code=$CODE_M" | grep -q "token=" && ok "S10a2 select 带下载令牌" || bad "S10a2 下载令牌缺失" "-"
DLM=$(curl -s "$BASE/share/select/?code=$CODE_M" | J "d['data']['download_url']")
case "$DLM" in /*) DLM="$BASE$DLM" ;; esac
curl -s "$DLM" -o "$SMOKE_RUN_DIR/art/dl.zip"
"$PY" -c "
import zipfile,sys
z = zipfile.ZipFile('$SMOKE_RUN_DIR/art/dl.zip')
names = z.namelist()
assert len(names) == 2, names
assert z.read(names[0]).rstrip(b'\n') in (b'multi-file-one', b'multi-file-two')
print('ZIP-OK')
" 2>/dev/null && ok "S10b 多文件 zip 2 entries" || bad "S10b zip" "$("$PY" -c "import sys;d=open(sys.argv[1],'rb').read(4);print('PK-magic-ok' if d[:2]==b'PK' else repr(d))" "$SMOKE_RUN_DIR/art/dl.zip" 2>/dev/null | head -c 80)"

# S11 chunk 分片上传完整闭环 + 完成后秒传
# 随机 upload_id：od 在部分 busybox 环境缺失 ⇒ 用 sha256sum 取前 32 位十六进制
UPID=$(head -c 16 /dev/urandom | sha256sum | cut -c1-32)
HA=$(sha256sum "$SMOKE_RUN_DIR/src/big-a.txt" | cut -d' ' -f1)
INIT=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"big-a.txt\",\"file_size\":300000,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$HA\"}")
UPID=$(printf '%s\n' "$INIT" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UPID/0" -F "chunk=@$SMOKE_RUN_DIR/src/big-a.txt" >/dev/null
CMP=$(curl -s -X POST "$BASE/chunk/upload/complete/$UPID" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}')
CMP_CODE=$(printf '%s\n' "$CMP" | J "d['data']['share_code']")
case "$CMP_CODE" in
  JERR* | "") CMP_CODE=$(printf '%s\n' "$CMP" | J "d['data']['code']") ;;
esac
register_probe "$CMP_CODE"
[ -n "$CMP_CODE" ] && ! is_jerr "$CMP_CODE" && ok "S11a 分片完成→建分享 code=$CMP_CODE" || bad "S11a chunk complete" "$(printf '%s\n' "$CMP" | head -c 120)"
HA=$(sha256sum "$SMOKE_RUN_DIR/src/big-a.txt" | cut -d' ' -f1)
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
INIT2=$(curl -s -X POST "$BASE/chunk/upload/init/" -H 'Content-Type: application/json' -d "{\"file_name\":\"bad-chunk.bin\",\"file_size\":1024,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$(sha256sum "$SMOKE_RUN_DIR/src/bad-chunk.bin" | cut -d' ' -f1)\"}")
UP2=$(printf '%s\n' "$INIT2" | J "d['data']['upload_id']")
BADR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HBAD" -F "chunk=@$SMOKE_RUN_DIR/src/bad-chunk.bin")
[ "$BADR" = 422 ] && ok "S11c 期望哈希不符拒收(422)" || bad "S11c 哈希校验" "$BADR"
HOK=$(sha256sum "$SMOKE_RUN_DIR/src/bad-chunk.bin" | cut -d' ' -f1)
OKR=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/chunk/upload/chunk/$UP2/0?hash=$HOK" -F "chunk=@$SMOKE_RUN_DIR/src/bad-chunk.bin")
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
case "$SRV_ROOT" in '' | None | null) SRV_ROOT="" ;; esac
SMOKE_IMPORT_TRIED=""
for SMOKE_CAND in "$SMOKE_IMPORT_DIR" "$SRV_ROOT"; do
  [ -n "$SMOKE_CAND" ] || continue
  case " $SMOKE_IMPORT_TRIED " in *" $SMOKE_CAND "*) continue ;; esac
  SMOKE_IMPORT_TRIED="$SMOKE_IMPORT_TRIED $SMOKE_CAND"
  [ -d "$SMOKE_CAND" ] && [ -w "$SMOKE_CAND" ] || continue
  printf 'smoke local import test content\n' >"$SMOKE_CAND/local-nas.txt" 2>/dev/null || continue
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
    register_probe "$CODE_L"
    DLL=$(curl -s "$BASE/share/select/?code=$CODE_L" | J "d['data']['download_url']")
    case "$DLL" in /*) DLL="$BASE$DLL" ;; esac
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
USER_CFG_SNAP="$SMOKE_RUN_DIR/art/user-config-before.json"
curl -s "$BASE/admin/config/user" -H "$AH" >"$USER_CFG_SNAP"
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
# S13a-0 重复注册撞名 ⇒ 409 + 业务码 10016（2026-11-02 缺陷回归锁：此前撞名
# 返回 500/10008「服务器内部错误」，用户无从得知该换用户名）。
# 对重复冒烟稳健：smoker 无论是本轮建的还是上轮残留，二次注册必撞名。
# 负对照：把 core Register 的 409 映射改回 500 ⇒ 本断言红。
S13A0_CODE=$(curl -s -o "$SMOKE_RUN_DIR/art/s13a0.json" -w '%{http_code}' -X POST "$BASE/user/register" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345","nickname":"smoker","email":"smoker@example.com"}')
S13A0_BIZ=$(J "d['code']" <"$SMOKE_RUN_DIR/art/s13a0.json" 2>/dev/null | head -1)
if [ "$S13A0_CODE" = "409" ] && [ "$S13A0_BIZ" = "10016" ]; then
  ok "S13a-0 重复注册撞名 409/10016"
else
  bad "S13a-0 重复注册撞名" "http=${S13A0_CODE} code=${S13A0_BIZ}（期望 409/10016；500/10008=注册撞名 500 回归）"
fi
UTOK=$(curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' -d '{"username":"smoker","password":"smoke12345"}' | J "d['data']['token']")
[ -n "$UTOK" ] && ! is_jerr "$UTOK" && ok "S13a 用户注册登录" || bad "S13a 用户登录" "$UTOK"
REQ=$(curl -s -X POST "$BASE/api/v1/user/requests" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"title":"smoke-req","expire_value":1,"expire_style":"day"}')
RTOK=$(printf '%s\n' "$REQ" | J "d['data']['token']")
[ -n "$RTOK" ] && ! is_jerr "$RTOK" && ok "S13b 建寄件链接 token" || bad "S13b 寄件链接" "$REQ"

# S13b-1/2/3 会话 Cookie 通道（2026-11-02 真机缺陷回归锁）：浏览器登录态是
# HttpOnly Cookie（pb_token），其余接口走 pkg AuthMiddleware 双通道，而
# /api/v1/user/requests* 绑的 UserAuth 曾只认 Authorization: Bearer 头 ⇒
# 浏览器访问「我的请求/寄件码」恒 401（前端误报「未登录或登录已过期」）。
# 三条断言：①仅 Cookie 的 GET ⇒ 200（漏 Cookie 通道即红）；②Cookie 写请求
# 缺 X-Requested-With ⇒ 403（CSRF 门禁）；③带 CSRF 头 ⇒ 正常建单。
S13B1_CODE=$(curl -s -o "$SMOKE_RUN_DIR/art/s13b1.json" -w '%{http_code}' "$BASE/api/v1/user/requests" -H "Cookie: pb_token=${UTOK}")
[ "$S13B1_CODE" = "200" ] && ok "S13b-1 Cookie 会话读寄件请求" || bad "S13b-1 Cookie 会话读寄件请求" "http=${S13B1_CODE}（期望 200；401=UserAuth 漏 Cookie 通道回归）"
S13B2_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/user/requests" -H "Cookie: pb_token=${UTOK}" -H 'Content-Type: application/json' -d '{"title":"smoke-csrf","expire_value":1,"expire_style":"day"}')
[ "$S13B2_CODE" = "403" ] && ok "S13b-2 Cookie 写请求缺 CSRF 头被拒" || bad "S13b-2 CSRF 门禁" "http=${S13B2_CODE}（期望 403）"
S13B3=$(curl -s -X POST "$BASE/api/v1/user/requests" -H "Cookie: pb_token=${UTOK}" -H 'X-Requested-With: XMLHttpRequest' -H 'Content-Type: application/json' -d '{"title":"smoke-cookie","expire_value":1,"expire_style":"day"}')
S13B3_TOK=$(printf '%s\n' "$S13B3" | J "d['data']['token']")
[ -n "$S13B3_TOK" ] && ! is_jerr "$S13B3_TOK" && ok "S13b-3 Cookie 会话建寄件链接" || bad "S13b-3 Cookie 建寄件链接" "$S13B3"
# S13c 访客可取链接信息：断**标题的实际取值**（原断言 grep "title" 只是键名，
# 键恒在 ⇒ 恒真）+ 断业务码为成功。
S13C_BODY=$(curl -s "$BASE/request/$RTOK")
S13C_BIZ=$(printf '%s\n' "$S13C_BODY" | J "d.get('code')")
if printf '%s\n' "$S13C_BODY" | grep -q "smoke-req" && [ "$S13C_BIZ" = "0" ]; then
  ok "S13c 访客可取链接信息"
else
  bad "S13c 访客取链接" "biz=${S13C_BIZ}（期望 0 且含标题值 smoke-req）"
fi
GUP=$(curl -s -X POST "$BASE/api/v1/request/$RTOK/upload" -F "files=@$SMOKE_RUN_DIR/src/m1.txt")
# 访客投递**只回 pickup_code**（core 的 guestUploadData：投递成功只带 file_count+pickup_code）
# ⇒ 登记取件码即可（管理端 filter 的 keyword 也匹配 pickup_code ⇒ 查得到 id）。
printf '%s\n' "$GUP" | grep -q "投递成功" && ok "S13d 访客投递" || bad "S13d 投递" "$(printf '%s\n' "$GUP" | head -c 100)"
register_probe "$(printf '%s\n' "$GUP" | J "d['data'].get('pickup_code')")"

# S13e 同用户秒传命中（秒传去重限「同用户内」——匿名侧见 S11b，这里验命中侧）
# 用独立内容：上传会话按文件 hash 键控，复用 S11 的内容会拿到同一个 upload_id
# （那是会话去重，不是分享秒传），且那份分享属匿名用户(user_id=0)，
# 对登录用户不可见——去重源必须是自己名下的分享。
printf 'u-dedup-%s' "$(date +%s)" >"$SMOKE_RUN_DIR/src/u-dedup.txt"
UH=$(sha256sum "$SMOKE_RUN_DIR/src/u-dedup.txt" | cut -d' ' -f1)
USIZE=$(wc -c <"$SMOKE_RUN_DIR/src/u-dedup.txt" | tr -d ' ')
UUPID=$(curl -s -X POST "$BASE/chunk/upload/init/" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d "{\"file_name\":\"u-dedup.txt\",\"file_size\":$USIZE,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$UH\"}")
UUID=$(printf '%s\n' "$UUPID" | J "d['data']['upload_id']")
curl -s -X POST "$BASE/chunk/upload/chunk/$UUID/0" -H "Authorization: Bearer $UTOK" -F "chunk=@$SMOKE_RUN_DIR/src/u-dedup.txt" >/dev/null
# 响应体留全（原写法 > /dev/null ⇒ 建出的用户分享拿不到码 ⇒ 无法登记回收）
S13E_CMP=$(curl -s -X POST "$BASE/chunk/upload/complete/$UUID" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d '{"expire_value":1,"expire_style":"day","require_auth":false}')
register_probe "$(printf '%s\n' "$S13E_CMP" | J "d['data'].get('share_code') or d['data'].get('code')")"
UQI=$(curl -s -X POST "$BASE/chunk/upload/init/" -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' -d "{\"file_name\":\"u-dedup.txt\",\"file_size\":$USIZE,\"chunk_size\":1048576,\"total_chunks\":1,\"file_hash\":\"$UH\",\"expire_value\":1,\"expire_style\":\"day\"}")
# 秒传命中时**init 就建了分享行**（复用既有物理文件）⇒ 必须登记，否则留下一个活着的分享。
register_probe "$(printf '%s\n' "$UQI" | J "d['data'].get('code') or d['data'].get('share_code')")"
[ "$(printf '%s\n' "$UQI" | J "d['data'].get('is_quick_upload')")" = "True" ] && ok "S13e 同用户秒传命中" || bad "S13e 同用户秒传" "$(printf '%s\n' "$UQI" | head -c 120)"

# S14 MCP（Streamable HTTP；官方 SDK 要求 Accept 同时含 application/json 与 text/event-stream）
MCP=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
NT=$(printf '%s\n' "$MCP" | J "len(d['result']['tools'])")
case "$NT" in [0-9]*) [ "$NT" -ge 8 ] && ok "S14 MCP tools=$NT" || bad "S14 MCP tools=$NT" "<8" ;; *) bad "S14 MCP" "$(printf '%s\n' "$MCP" | head -c 100)" ;; esac
# S14b MCP 工具调用：结构化出参（structuredContent）应含分享码与分享链接
MCPC=$(curl -s -X POST "$BASE/api/v1/mcp" -H "$AH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"share_text","arguments":{"text":"smoke-mcp-check"}}}')
MCODE=$(printf '%s\n' "$MCPC" | J "d['result']['structuredContent']['code']")
MURL=$(printf '%s\n' "$MCPC" | J "d['result']['structuredContent']['share_url']")
register_probe "$MCODE"
[ -n "$MCODE" ] && [ "$MCODE" != "None" ] && [ -n "$MURL" ] && [ "$MURL" != "None" ] &&
  ok "S14b MCP share_text code=$MCODE" || bad "S14b MCP share_text" "$(printf '%s\n' "$MCPC" | head -c 160)"
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
# 占位分享（文件未传）也是 file_codes 里的一行 ⇒ 一并登记回收（#323）
register_probe "$ACODE"
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
{ [ "$ASELCODE" = "0" ] || [ "$ASELCODE" = "20001" ]; } &&
  ok "S16e 匿名码页面链接的码能解析（code=${ASELCODE}）" ||
  bad "S16e 匿名码页面链接解析不到" "$ASELCODE"

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
register_probe "$PCODE"
PINIT=$(curl -s -X POST "$BASE/api/v1/presign/upload" -H 'Content-Type: application/json' -d "{\"file_name\":\"smoke-presign.bin\",\"file_size\":16,\"content_type\":\"application/octet-stream\",\"pickup_code\":\"$PCODE\"}")
PUPID=$(printf '%s\n' "$PINIT" | J "d['data']['upload_id']")
PUURL=$(printf '%s\n' "$PINIT" | J "d['data']['upload_url']")
PUTK=$(printf '%s\n' "$PINIT" | J "d['data']['headers']['X-Upload-Token']")
PPTOK=$(printf '%s\n' "$PINIT" | J "d['data']['token']")
if [ -n "$PUPID" ] && [ -n "$PUURL" ] && [ -n "$PPTOK" ]; then
  # 字节数须与申报一致（服务端校验申报大小）：恰好 16 字节
  printf 'smoke-presign-16' >"$SMOKE_RUN_DIR/src/presign.bin"
  # ⚠️ presign 的 upload_url 是**对外**地址（站点地址 + 公开端口），不是回环。
  # 站点配了 HTTPS 且证书自签时，冒烟客户端验证不了它 ⇒ curl 直接失败（http=000）
  # ⇒ complete 拿不到对象、响应无 data ⇒ **S18a / S18c 假红**，而链接形态其实是对的。
  # 2026-11-07 在 10.10.10.3 实测坐实：PUT 无 -k = 000、带 -k = 200，complete 之后
  # url=/#/share/CODE、download_url=…/share/download?code=… 全对。
  # ⇒ 这类站点显式设 SMOKE_CURL_INSECURE=1 跳过证书校验（默认关，公网证书站点无需设）。
  if [ "${SMOKE_CURL_INSECURE:-0}" = "1" ]; then
    note "S18 presign PUT 跳过 TLS 校验（SMOKE_CURL_INSECURE=1；站点为自签证书时属预期）"
    curl -sk -X PUT "$PUURL" -H "X-Upload-Token: $PUTK" --data-binary "@$SMOKE_RUN_DIR/src/presign.bin" >/dev/null
  else
    curl -s -X PUT "$PUURL" -H "X-Upload-Token: $PUTK" --data-binary "@$SMOKE_RUN_DIR/src/presign.bin" >/dev/null
  fi
  PCMP=$(curl -s -X POST "$BASE/api/v1/presign/complete" -H 'Content-Type: application/json' -d "{\"upload_id\":\"$PUPID\",\"token\":\"$PPTOK\"}")
  PURL=$(printf '%s\n' "$PCMP" | J "d['data']['url']")
  PDL=$(printf '%s\n' "$PCMP" | J "d['data']['download_url']")
  # presign 的**最终分享码只出现在链接里**（complete 响应不回 code 字段）
  # ⇒ 从页面链接 / 直链里取出来登记，否则留下一个活着的匿名分享。
  register_probe "$(printf '%s\n' "$PURL" | sed -n 's|.*/#/share/||p')"
  register_probe "$(printf '%s\n' "$PDL" | sed -n 's|.*[?&]code=||p')"
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
  curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' -d '{"upload_ex":{"max_file_size":1024}}' >/dev/null
  S19_OPEN_AFTER=$(curl -s "$BASE/admin/config" -H "$AH" | J "d['data'].get('upload_ex',{}).get('open_upload')")
  if [ "$S19_OPEN_BEFORE" = "$S19_OPEN_AFTER" ]; then
    ok "S19a 配置 PUT 字段级合并（同段其余字段保留）"
  else
    bad "S19a 配置 PUT 清零了同段其它字段" "open_upload before=$S19_OPEN_BEFORE after=$S19_OPEN_AFTER"
  fi
  # 复原（字段级合并 ⇒ 只动 max_file_size 一个字段）
  curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' -d "{\"upload_ex\":{\"max_file_size\":$S19_MAX_BEFORE}}" >/dev/null
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
  curl -s "$BASE/admin/files/filter?page=1&page_size=20&keyword=$1" -H "$AH" |
    J "([x['used_count'] for x in d['data']['items'] if x['code']=='$1'] or ['NA'])[0]"
}

S20A=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"count-once-via-pickup","expire_value":3,"expire_style":"count","require_auth":false}')
S20A_CODE=$(printf '%s\n' "$S20A" | J "d['data']['code']")
register_probe "$S20A_CODE"
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
  [ "$S20A_USED" = "1" ] &&
    ok "S20a 6 位取件码取件只扣 1 次（used=${S20A_USED}）" ||
    bad "S20a 取件扣次异常" "used_count=${S20A_USED}（期望 1；修前双扣为 2）"
else
  bad "S20a 匿名取件未下发 download_url" "code=$S20A_RCODE"
fi

# S20b 对照组：8 位分享码路径（select 不扣 + download 扣 1）——不得被本次改动带歪
S20B=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"count-once-via-share","expire_value":3,"expire_style":"count","require_auth":false}')
S20B_CODE=$(printf '%s\n' "$S20B" | J "d['data']['code']")
register_probe "$S20B_CODE"
S20B_DL=$(curl -s "$BASE/share/select/?code=$S20B_CODE" | J "d['data'].get('download_url')")
if [ -n "$S20B_DL" ]; then
  curl -s -o /dev/null "$BASE$S20B_DL"
  S20B_USED=$(used_count_of "$S20B_CODE")
  [ "$S20B_USED" = "1" ] &&
    ok "S20b 8 位分享码取件只扣 1 次（used=${S20B_USED}）" ||
    bad "S20b 分享码扣次异常" "used_count=${S20B_USED}（期望 1）"
else
  bad "S20b select 未下发 download_url" "-"
fi

# S21b 取件明细在**留存期内**必须查得到（2026-10-24 修「明细只存在 1 小时」）
# 缺陷：取件记录表的清理窗口跟着下载令牌 TTL 走（TTL+1h ≈ 1 小时 17 分）⇒
# owner 第二天打开取件历史，明细全空 ⇒ 「逐条取件历史」形同虚设。
# 判据：取件一次后，明细里必须有 1 条（IP 非空）。
S21B_CODE=$(printf '%s\n' "$S20A" | J "d['data']['code']")
S21B_INFO=$(curl -s "$BASE/api/v1/user/shares?page=1&page_size=20&search=$S21B_CODE" -H "$AH" |
  J "(lambda p: ('%d|%s' % (len(p), p[0].get('ip','') if p else '')))((d['data']['items'][0].get('pickups') or []) if (d.get('data') or {}).get('items') else [])")
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
register_probe "$S22_CODE"
curl -s -o /dev/null "$BASE/share/select/?code=$S22_CODE"
curl -s -o /dev/null "$BASE/share/select/?code=$S22_CODE"
S22_USED=$(used_count_of "$S22_CODE")
[ "$S22_USED" = "1" ] &&
  ok "S22 文本分享刷新两次只扣 1 次（used=${S22_USED}）" ||
  bad "S22 文本分享重复扣次" "used_count=${S22_USED}（期望 1；修前为 2）"

# S21 逐条取件明细（2026-10-24 新增）：owner 侧能看到逐条取件记录
# 判据：一次取件 = 一行（IP + 时间 + 交付面）；多文件逐个下载/断点续传属同一次取件
# ⇒ 不会被显示成「取件 N 次」（此前只有「最后 IP + 计数」⇒ 看不出来）。
# 单次 J 调用取两个值（J 的输出是 Python repr，不能再喂回 JSON 解析）
S21_INFO=$(curl -s "$BASE/api/v1/user/shares?page=1&page_size=20&search=$S20B_CODE" -H "$AH" |
  J "(lambda p: ('%d|%s' % (len(p), p[0].get('ip','') if p else '')))((d['data']['items'][0].get('pickups') or []) if (d.get('data') or {}).get('items') else [])")
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
register_probe "$S20C_CODE"
curl -s -o /dev/null "$BASE/share/select/?code=$S20C_CODE"
S20C_USED=$(used_count_of "$S20C_CODE")
[ "$S20C_USED" = "1" ] &&
  ok "S20c 文本分享取件扣 1 次（used=${S20C_USED}）" ||
  bad "S20c 文本分享扣次异常" "used_count=${S20C_USED}（期望 1；修前恒为 0）"

# S20d 末次取件必须拿得到文件（count=1）：走取件码通道
# 缺陷实录：retrieve 先把次数扣到 0 ⇒ IsExpired 判过期 ⇒ 随后的下载 404 ⇒
# **按取件次数的分享，最后一次取件永远拿不到文件**（分享页通道却能拿到）。
S20D=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"last-pickup-delivers","expire_value":1,"expire_style":"count","require_auth":false}')
S20D_CODE=$(printf '%s\n' "$S20D" | J "d['data']['code']")
register_probe "$S20D_CODE"
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
  [ "$S20D_HTTP" = "200" ] && [ "$S20D_USED" = "1" ] &&
    ok "S20d 末次取件拿到文件（http=${S20D_HTTP} used=${S20D_USED}）" ||
    bad "S20d 末次取件异常" "http=${S20D_HTTP}（期望 200；修前为 404 已过期）used=${S20D_USED}（期望 1）"
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
register_probe "$S23A_CODE"
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
register_probe "$S23B_CODE"
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
register_probe "$S23C_CODE"
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
  [ -n "$AFTER_TYPE" ] && ok "S24f 迁移后存储后端仍可读（current=${AFTER_TYPE}）" ||
    bad "S24f 迁移后读存储信息失败" "-"
else
  skip "S24e 真迁移（改存储后端）" "仅隔离实例可跑（SMOKE_ALLOW_STORAGE_MIGRATE=1）"
fi

# S25 备份包（4.6.0 能力：统一备份包导出 + 恢复校验）
#
# 只做**只读**动作：导出（读 DB/对象）与恢复的 --dry-run（只校验，不落盘）
# ⇒ 不动线上数据。真正的恢复是**破坏性**操作，只在隔离实例上做。
SMOKE_CONTAINER="${SMOKE_CONTAINER:-pigeonbox}"
# ★ **双模式**：容器在跑 ⇒ 容器模式（真机形态：跑发布产物）；
#   否则 ⇒ **本地二进制模式**（CI 形态：冒烟自己编的 server-bin 就在手边）。
#
#   为什么要本地模式（2026-10-31 实录）：CI 的冒烟**用当前 main 源码编 server**
#   起临时实例 ⇒ **根本没有容器** ⇒ 原先的 S25/S26 一律 SKIP
#   ⇒ 「备份包 / 换库」这两个域在 CI 里**覆盖为零**（门禁绿是**假绿**：
#   它绿是因为「没跑」，不是因为「跑过了」）。
#   ⇒ 离线子命令本来就能在本地二进制上跑（它只是「同机操作」）⇒ 补上这条路。
S25_MODE=""
S25_BIN=""
S25_CFG=""
S25_EXEC=""
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SMOKE_CONTAINER"; then
  S25_MODE="container"
  # 二进制与配置都**探**不写死：镜像布局会变（/app/server、/app/pigeonbox…），
  # 写死一个路径 ⇒ 布局一变就假红。
  for cand in /app/server /app/pigeonbox; do
    if docker exec "$SMOKE_CONTAINER" test -x "$cand" 2>/dev/null; then
      S25_BIN="$cand"
      break
    fi
  done
  for cand in /app/config/config.yaml /app/config/config.prod.yaml; do
    if docker exec "$SMOKE_CONTAINER" test -f "$cand" 2>/dev/null; then
      S25_CFG="$cand"
      break
    fi
  done
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
elif [ -x "${SMOKE}/server-bin" ] && [ -f "${SMOKE}/config.yaml" ]; then
  S25_MODE="local"
  S25_BIN="${SMOKE}/server-bin"
  S25_CFG="${SMOKE}/config.yaml"
  # 本地模式的 jwt secret 必须与实例一致 ⇒ 首选从实例进程环境取（Linux 最可靠）；
  # /proc 不可用（macOS）时用启动时定死的 ${SMOKE_JWT}（同一份值）。
  # （修前这里 date +%s 现生成——与实例的不一致且 <32 字符过不了配置校验。）
  S25_JWT=$(tr '\0' '\n' </proc/"$(pgrep -f "${SMOKE}/server-bin" | head -1)"/environ 2>/dev/null | sed -n 's/^PB_JWT_SECRET=//p' | head -1)
  [ -n "$S25_JWT" ] || S25_JWT=${SMOKE_JWT:-}
  if [ -n "$S25_JWT" ]; then
    S25_EXEC="env PB_JWT_SECRET=$S25_JWT"
  else
    S25_EXEC="env"
  fi
else
  skip "S25 备份包" "既无容器 ${SMOKE_CONTAINER}，也没有本地二进制（${SMOKE}/server-bin）"
fi
if [ -n "$S25_MODE" ]; then
  if [ -z "$S25_BIN" ]; then
    skip "S25 备份包" "容器内找不到服务端二进制（/app/server、/app/pigeonbox 都没有）"
  elif [ -z "$S25_CFG" ]; then
    skip "S25 备份包" "容器内找不到配置文件（/app/config/config.yaml 等）"
  else
    # ⚠️ 备份包文件名**必须唯一**（带 $$ 与时间戳）。
    #
    # 2026-10-31 10.10.10.3 真机实录：固定名 `/tmp/pb-smoke-backup.tar.gz`
    # 在容器里留下一份 **root 属主**的 896MB 残片（上一轮跑的产物）；
    # 而容器 USER 是 **app**(uid 1000) 且 `/tmp` 有 sticky 位 ⇒ app **无权覆盖**
    # root 的文件 ⇒ `os.Create` 直接 EACCES ⇒ 导出**必然**退出非 0
    # ⇒ 冒烟从此**每轮都红**，且红得毫无信息量（只说「退出码非 0」）。
    #
    # ⇒ 三处一起改：
    #   ① 文件名唯一 ⇒ 永不撞名；
    #   ② 失败时把**真实 stderr** 带出来（别只说「退出码非 0」）；
    #   ③ 清理用 `-u 0` 兜底（能删掉 root 属主的陈旧残片）。
    S25_STAMP="$$-$(date +%s)"
    if [ "$S25_MODE" = "container" ]; then
      S25_PKG="/tmp/pb-smoke-backup-${S25_STAMP}.tar.gz"
      S25_HOST_PKG="/tmp/pb-smoke-backup-${S25_STAMP}.tar.gz"
    else
      # 本地模式：产物落在冒烟自己的工作目录里（与实例同机 ⇒ 不必绕容器）。
      S25_PKG="${SMOKE}/pb-smoke-backup-${S25_STAMP}.tar.gz"
      S25_HOST_PKG="$S25_PKG"
    fi
    S25_ERR=$(mktemp)
    if $S25_EXEC "$S25_BIN" backup export --out "$S25_PKG" --config "$S25_CFG" >/dev/null 2>"$S25_ERR"; then
      if [ "$S25_MODE" = "container" ]; then
        S25_GOT=$(docker cp "$SMOKE_CONTAINER:$S25_PKG" "$S25_HOST_PKG" >/dev/null 2>&1 && echo ok || echo fail)
      elif [ "$S25_PKG" = "$S25_HOST_PKG" ]; then
        # 本地模式：产物**就在本机** ⇒ 不必复制（`cp -f X X` 会报
        # 「are the same file」⇒ 上一版就是这么红的）。
        S25_GOT=ok
      else
        S25_GOT=$(cp -f "$S25_PKG" "$S25_HOST_PKG" >/dev/null 2>&1 && echo ok || echo fail)
      fi
      if [ "$S25_GOT" = "ok" ]; then
        S25_LIST=$(tar -tzf "$S25_HOST_PKG" 2>/dev/null | tr '\n' ' ')
        case "$S25_LIST" in
          *manifest.json*) ok "S25a 备份包导出成功且含 manifest.json" ;;
          *) bad "S25a 备份包缺 manifest.json" "$S25_LIST" ;;
        esac
        S25_FMT=$(tar -xzOf "$S25_HOST_PKG" manifest.json 2>/dev/null | J "d.get('backup_format')")
        [ "$S25_FMT" = "1" ] && ok "S25b 备份包格式版本可读（backup_format=1）" || bad "S25b 备份包格式版本" "backup_format=${S25_FMT:-读不到}"
        # ★ 断言必须有牙：导出的是**活实例**的库与对象 ⇒ 本轮冒烟自己造过分享（S5/S9）
        #   与文件对象 ⇒ 计数必须 ≥1 ⇒ 「导到了空库/错目录」会被当场抓住。
        S25_FILES=$(tar -xzOf "$S25_HOST_PKG" manifest.json 2>/dev/null | J "d.get('file_count')")
        S25_OBJS=$(tar -xzOf "$S25_HOST_PKG" manifest.json 2>/dev/null | J "d.get('object_count')")
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
        if [ "$S25_MODE" = "container" ]; then
          S25_PUT=$(docker cp "$S25_HOST_PKG" "$SMOKE_CONTAINER:$S25_PKG" >/dev/null 2>&1 && echo ok || echo fail)
        else
          S25_PUT=ok
        fi
        if [ "$S25_PUT" = "ok" ] &&
          $S25_EXEC "$S25_BIN" backup restore --from "$S25_PKG" --dry-run --config "$S25_CFG" >/dev/null 2>&1; then
          ok "S25e 备份包恢复校验通过（dry-run：逐对象 sha256 + DB 快照可打开）"
        else
          bad "S25e 备份包恢复校验未通过" "dry-run 失败（包损坏/格式不认识/DB 快照打不开）"
        fi
        rm -f "$S25_HOST_PKG"
        # 清理用 `-u 0` 兜底（容器模式）：容器内可能残留**别的属主**（root）的文件
        # ⇒ 普通用户删不掉 ⇒ 残留每轮 ~900MB 累积 ⇒ 最终撑爆容器磁盘。
        if [ "$S25_MODE" = "container" ]; then
          docker exec -u 0 "$SMOKE_CONTAINER" rm -f "$S25_PKG" >/dev/null 2>&1
        else
          rm -f "$S25_PKG"
        fi
      else
        bad "S25a 备份包导出后取不出来" "从${S25_MODE}取产物失败（模式=${S25_MODE}，产物=${S25_PKG}）"
      fi
    else
      # 失败时把**真实 stderr** 带出来（只说「退出码非 0」等于没说：
      # 真机实录里它掩盖了「/tmp 有 root 属主残片 ⇒ app 无权覆盖」这个真因）。
      bad "S25a 备份包导出失败" "退出码非 0：$(tail -c 400 "$S25_ERR" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "$S25_ERR"
  fi
fi

# ── S26 换库（4.6.2 能力：SQLite → PG/MySQL 的逻辑搬运）────────────────────
#
# 断言设计（判据必须有牙 ⇒ 每条都打在**真正会被读到的量**上）：
#
#   S26a 导出行数据成功（`db export` 退出码 0 + 产物是合法 JSON 且 dump_format=1）
#   S26b 导入到**独立的目标库**成功（`db import --yes` 退出码 0）
#   S26c 目标库的**分享记录数与源库一致**（⇒ 行数据真搬过去了，不是空库）
#   S26d 目标库里**取件码逐字一致**（⇒ 「链接/取件码不变」的承诺成立）
#   S26e 在目标库**新建一行不撞主键**（⇒ 自增序列对齐真的做了；
#        ⚠️ 这是换库最经典的静默地雷：导入是显式写 ID ⇒ PG 的 bigserial 序列
#        不会前进 ⇒ 不对齐的话「迁移完第一次新建分享」就 duplicate key）
#
# 目标库用**容器外的临时 SQLite 文件**（经 `docker cp` 进出）⇒ 不碰生产库。
# 真 PG / 真 MySQL 的跨方言验收在 **core CI**（service 容器）里做 ——
# 冒烟机不假设自己有 PG/MySQL ⇒ 缺前置条件时 SKIP 而不是假红。
# ★ 与 S25 同款：**双模式**（容器模式 = 真机形态；本地二进制模式 = CI 形态）。
#   CI 的冒烟用当前源码编 server 起本地实例（**没有容器**）⇒ 只走容器模式的话
#   S26 在 CI 里恒 SKIP ⇒ 「换库」这个域在门禁里**零覆盖**（绿是假绿）。
S26_MODE=""
S26_BIN=""
S26_CFG=""
S26_EXEC=""
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${SMOKE_CONTAINER:-pigeonbox}"; then
  S26_MODE="container"
  S26_C="${SMOKE_CONTAINER:-pigeonbox}"
  for cand in /app/server /app/pigeonbox; do
    if docker exec "$S26_C" test -x "$cand" 2>/dev/null; then
      S26_BIN="$cand"
      break
    fi
  done
  for cand in /app/config/config.yaml /app/config/config.prod.yaml; do
    if docker exec "$S26_C" test -f "$cand" 2>/dev/null; then
      S26_CFG="$cand"
      break
    fi
  done
  S26_JWT=$(docker exec "$S26_C" printenv PB_JWT_SECRET 2>/dev/null)
  if [ -z "$S26_JWT" ]; then
    S26_JWT=$(docker exec "$S26_C" cat /app/data/.jwt_secret 2>/dev/null)
  fi
  if [ -n "$S26_JWT" ]; then
    S26_EXEC="docker exec -e PB_JWT_SECRET=$S26_JWT $S26_C"
  else
    S26_EXEC="docker exec $S26_C"
  fi
elif [ -x "${SMOKE}/server-bin" ] && [ -f "${SMOKE}/config.yaml" ]; then
  S26_MODE="local"
  S26_BIN="${SMOKE}/server-bin"
  S26_CFG="${SMOKE}/config.yaml"
  S26_JWT=$(tr '\0' '\n' </proc/"$(pgrep -f "${SMOKE}/server-bin" | head -1)"/environ 2>/dev/null | sed -n 's/^PB_JWT_SECRET=//p' | head -1)
  [ -n "$S26_JWT" ] || S26_JWT=${SMOKE_JWT:-}
  if [ -n "$S26_JWT" ]; then
    S26_EXEC="env PB_JWT_SECRET=$S26_JWT"
  else
    S26_EXEC="env"
  fi
else
  skip "S26 换库" "既无容器，也没有本地二进制（${SMOKE}/server-bin）"
fi
if [ -n "$S26_MODE" ]; then
  if [ -z "$S26_BIN" ] || [ -z "$S26_CFG" ]; then
    skip "S26 换库" "找不到服务端二进制或配置文件"
  else
    # 目标库：容器**外**的临时文件（⇒ 绝不碰生产库）。
    # ⚠️ 文件名**必须唯一**（同 S25 的坑）：容器 /tmp 有 sticky 位，
    #   别的属主（root）留下的同名残片 ⇒ 当前用户（app）无权覆盖 ⇒ 必失败。
    S26_STAMP="$$-$(date +%s)"
    if [ "$S26_MODE" = "container" ]; then
      S26_DUMP="/tmp/pb-smoke-dbdump-${S26_STAMP}.json"
      S26_TGT="/tmp/pb-smoke-target-${S26_STAMP}.db"
    else
      S26_DUMP="${SMOKE}/pb-smoke-dbdump-${S26_STAMP}.json"
      S26_TGT="${SMOKE}/pb-smoke-target-${S26_STAMP}.db"
    fi
    rm -f "$S26_DUMP" "$S26_TGT"

    # S26a 导出
    # ⚠️ 取产物必须**按模式分支**，且**必须在 export 之后**（2026-11-01 真机实录）：
    #   容器模式要把产物 docker cp 出来；本地模式文件本来就在本机 ⇒ 再 docker cp 必然失败。
    #   ⚠️ **fetch 不能排在 export 之前**：那时产物还不存在 ⇒ docker cp 必失败
    #   ⇒ S26_FETCHED=fail ⇒ S26a **恒 FAIL**（假红）；且 S26_IMP_ERR 还没建
    #   ⇒ 末尾清理时连锁报「S26_IMP_ERR: parameter not set」。
    #   ⚠️ 症状**只在容器模式**出现（本地模式 fetch 是 no-op ⇒ 恒 ok）
    #   ⇒ CI（本地进程实例）永远绿 ⇒ 这段覆盖**只在真机**才露出来。
    S26_ERR=$(mktemp)
    S26_IMP_ERR=$(mktemp)
    if $S26_EXEC "$S26_BIN" db export --out "$S26_DUMP" --config "$S26_CFG" >/dev/null 2>"$S26_ERR"; then
      if [ "$S26_MODE" = "container" ]; then
        S26_FETCHED=$(docker cp "$S26_C:$S26_DUMP" "$S26_DUMP" >/dev/null 2>&1 && echo ok || echo fail)
      else
        S26_FETCHED=ok
      fi
      if [ "$S26_FETCHED" != "ok" ]; then
        bad "S26a 换库导出成功但取不出产物" "docker cp ${S26_C}:${S26_DUMP} 失败"
      fi
      S26_FMT=$(J "d.get('dump_format')" <"$S26_DUMP" 2>/dev/null)
      if [ "${S26_FMT:-0}" -ge 1 ] 2>/dev/null; then
        ok "S26a 换库导出成功（dump_format=${S26_FMT}）"
      else
        bad "S26a 换库导出的格式版本读不到" "dump_format=${S26_FMT:-读不到}"
      fi
      # 源库的行数（导入后要与目标库逐表比对 ⇒ 先记下来）
      S26_SRC_FILES=$(J "sum(len(t.get('rows') or []) for t in (d.get('tables') or []) if t.get('name')=='file_codes')" <"$S26_DUMP" 2>/dev/null)
      # 源库的第一个取件码（⇒「取件码不变」的比对基准）
      S26_SRC_CODE=$(J "next((r[4] for t in (d.get('tables') or []) if t.get('name')=='file_codes' for r in (t.get('rows') or []) if len(r)>4 and r[4]), '')" <"$S26_DUMP" 2>/dev/null)

      # S26b 导入到独立目标库
      # ⚠️ 目标库必须**容器内也先清干净**（宿主清过不代表容器内没有残留
      #   ⇒ 目标库非空 ⇒ db import 按安全语义拒绝 ⇒ 假红）。
      # ⚠️ **本地模式在这里绝不能再 rm**：上面的 dump 刚由 export 写出来
      #   ⇒ 再 rm 就把产物删了 ⇒ 随后的 import 报
      #   「打开导出文件失败: no such file or directory」（CI 上真红过）。
      #   ⇒ 只有容器模式需要「清容器内 + 把产物送进去」这一步。
      if [ "$S26_MODE" = "container" ]; then
        docker exec -u 0 "$S26_C" rm -f "$S26_DUMP" "$S26_TGT" >/dev/null 2>&1
        docker cp "$S26_DUMP" "$S26_C:$S26_DUMP" >/dev/null 2>&1
      fi
      if $S26_EXEC "$S26_BIN" db import --from "$S26_DUMP" --target-driver sqlite \
        --target-dsn "$S26_TGT" --yes --config "$S26_CFG" >/dev/null 2>"$S26_IMP_ERR"; then
        ok "S26b 换库导入到独立目标库成功"
        if [ "$S26_MODE" = "container" ]; then
          docker cp "$S26_C:$S26_TGT" "$S26_TGT" >/dev/null 2>&1
        fi

        # S26c 目标库的行数与源库一致（⇒ 行数据真搬过去了）
        S26_TGT_FILES=$(
          python3 - "$S26_TGT" <<'PYEOF' 2>/dev/null || echo ""
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
try:
    print(c.execute("select count(*) from file_codes").fetchone()[0])
except Exception:
    print("")
PYEOF
        )
        if [ -n "$S26_TGT_FILES" ] && [ "$S26_TGT_FILES" = "${S26_SRC_FILES:-}" ]; then
          ok "S26c 目标库分享记录数与源库一致（${S26_TGT_FILES} 条）"
        else
          bad "S26c 目标库分享记录数与源库不一致" "源=${S26_SRC_FILES:-?} 目标=${S26_TGT_FILES:-?}"
        fi

        # S26d 取件码逐字一致（⇒「取件码与链接不变」的承诺成立）
        S26_TGT_CODE=$(
          python3 - "$S26_TGT" <<'PYEOF' 2>/dev/null || echo ""
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
try:
    r = c.execute("select code from file_codes where code is not null order by id limit 1").fetchone()
    print(r[0] if r else "")
except Exception:
    print("")
PYEOF
        )
        if [ -n "$S26_SRC_CODE" ] && [ "$S26_SRC_CODE" = "$S26_TGT_CODE" ]; then
          ok "S26d 目标库取件码与源库逐字一致（${S26_TGT_CODE}）"
        else
          bad "S26d 目标库取件码与源库不一致" "源=${S26_SRC_CODE:-?} 目标=${S26_TGT_CODE:-?}"
        fi

        # S26e 在目标库**真的新建一行** ⇒ 必须成功，且 ID 必须大于已导入的最大 ID
        # （**这条是换库的地雷**：导入是显式写 ID ⇒ 目标库的自增计数器若没对齐
        #  ⇒ 新建行会撞主键。SQLite 的 rowid 天然对齐 ⇒ 这条验的是「导入后的表
        #  还能正常接新行」；**PG/MySQL 的序列对齐由 core CI 的真库用例覆盖**
        #  （那里才有 bigserial 序列不前进的问题）。）
        S26_INS=$(
          python3 - "$S26_TGT" <<'PYEOF' 2>/dev/null || echo ""
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
try:
    maxid = c.execute("select coalesce(max(id),0) from file_codes").fetchone()[0]
    c.execute(
        "insert into file_codes (code, uuid_file_name, file_path, size, text, status, expired_count, used_count, created_at, updated_at)"
        " values (?,?,?,?,?,?,?,?,datetime('now'),datetime('now'))",
        ("SMOKES26", "smoke-s26.bin", "uploads/smoke/s26.bin", 1, "s26.txt", "normal", -1, 0),
    )
    c.commit()
    newid = c.execute("select last_insert_rowid()").fetchone()[0]
    print("%d %d" % (maxid, newid))
except Exception:
    print("")
PYEOF
        )
        S26_MAXID=$(printf '%s' "$S26_INS" | cut -d' ' -f1)
        S26_NEWID=$(printf '%s' "$S26_INS" | cut -d' ' -f2)
        if [ -n "$S26_NEWID" ] && [ -n "$S26_MAXID" ] && [ "$S26_NEWID" -gt "$S26_MAXID" ] 2>/dev/null; then
          ok "S26e 目标库新建行成功且 ID 未撞主键（max=${S26_MAXID} → new=${S26_NEWID}）"
        else
          bad "S26e 目标库新建行失败或撞主键" "max=${S26_MAXID:-?} new=${S26_NEWID:-?}（插入报错=导入后的表不能接新行）"
        fi
      else
        bad "S26b 换库导入失败" "退出码非 0：$(tail -c 400 "$S26_IMP_ERR" 2>/dev/null | tr '\n' ' ')"
      fi
      rm -f "$S26_DUMP" "$S26_TGT"
      # 清理用 -u 0 兜底（容器模式：能删掉别的属主的残片；本地模式直接删）。
      if [ "$S26_MODE" = "container" ]; then
        docker exec -u 0 "$S26_C" rm -f "$S26_DUMP" "$S26_TGT" >/dev/null 2>&1
      fi
    else
      bad "S26a 换库导出失败" "退出码非 0：$(tail -c 400 "$S26_ERR" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "$S26_ERR" "$S26_IMP_ERR" 2>/dev/null
  fi
fi

# ── S27 口令型 E2E 的服务端语义（core#30 全链）────────────────────────────
# 服务端在零知���前提下承担五个语义（客户端解密语义在 desktop/frontend 单测面）：
#   ① wrapped_key 非空 ⇒ 与明文分享同权铸 6 位取件码（两因子：码+口令）；
#   ② /share/metadata 只给 has_wrapped_key 标志，**不给本体**——metadata 无鉴权，
#      泄本体 = 把信封交给任何探码者（本体仅随取件/详情下发）；
#   ③ /anonymous/retrieve 把 wrapped_key **原样逐字**回传（取件人凭口令解封；
#      文本分享与文件分享同权，漏传则该通道取到的密文无从解密）；
#   ④ 旧「URL-hash-key」形态（encrypted 无 wrapped_key）**不铸码**（负对照）；
#   ⑤ wrapped_key 形状校验（core PR#45）：非 base64 / 解码后 >512B ⇒ 10001 拒绝。
# 信封造法（形状合法 77B = 0x01||salt16||nonce12||ct32||tag16，base64 104 字符）：
# 服务端只校验编码与长度、不解密 ⇒ 全零填充即可（零知识不变）。
# ⚠️ printf 与 head 必须在**同一管道**里再整体 base64（花括号组）——
#    写成 `printf …; head … | base64` 会让 0x01 原样进变量（非 base64 字符
#    还会把 JSON 打成非法）⇒ 断言全红（2026-11-02 首轮实测）。
S27_ENVELOPE=$({
  printf '\x01'
  head -c 76 /dev/zero
} | base64 | tr -d '\n')

# ①+② 铸码 + metadata 标志不泄本体（过期样式 count=3：与 S20A 同款已验证可用）
S27=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d "{\"text\":\"s27-e2e-wrapped\",\"expire_value\":3,\"expire_style\":\"count\",\"require_auth\":false,\"encrypted\":true,\"wrapped_key\":\"$S27_ENVELOPE\"}")
S27_CODE=$(printf '%s\n' "$S27" | J "d['data'].get('code') or ''")
register_probe "$S27_CODE"
if [ "$(printf '%s\n' "$S27" | J "len(d['data'].get('pickup_code') or '')==6")" = "True" ]; then
  ok "S27a 口令型 E2E 与明文同权铸 6 位取件码"
else
  bad "S27a 口令型 E2E 未铸 6 位取件码" "code=${S27_CODE:-<空>} pickup=$(printf '%s\n' "$S27" | J "d['data'].get('pickup_code')")（wrapped_key 非空须铸码）"
fi
if [ -n "$S27_CODE" ] && ! is_jerr "$S27_CODE"; then
  S27_MD=$(curl -s "$BASE/share/metadata/$S27_CODE")
  [ "$(printf '%s\n' "$S27_MD" | J "d['data']['has_wrapped_key']")" = "True" ] &&
    ok "S27b metadata 下发 has_wrapped_key=true" ||
    bad "S27b metadata 未下发 has_wrapped_key=true" "$(printf '%s\n' "$S27_MD" | J "d['data'].get('has_wrapped_key')")"
  # 本体不得出现在 metadata 响应（哪怕被 JSON 转义切割，base64 串本身必然原样出现）
  printf '%s\n' "$S27_MD" | grep -q "$S27_ENVELOPE" &&
    bad "S27b2 metadata 泄露 wrapped_key 本体!" "$S27_MD" ||
    ok "S27b2 metadata 不泄 wrapped_key 本体（只给标志）"
else
  bad "S27b metadata 面未跑（S27a 未拿到 share_code）" "code=${S27_CODE:-<空>}"
fi

# ③ 匿名取件通道原样回传 wrapped_key（逐字一致；retrieve 不扣次，S20 已证）
S27_PICK=$(printf '%s\n' "$S27" | J "d['data'].get('pickup_code') or ''")
S27_RET=$(curl -s -X POST "$BASE/anonymous/retrieve" -H 'Content-Type: application/json' \
  -d "{\"code\":\"$S27_PICK\"}")
S27_RCODE=$(printf '%s\n' "$S27_RET" | J "d.get('code')")
S27_WK=$(printf '%s\n' "$S27_RET" | J "(d.get('data') or {}).get('wrapped_key') or ''")
if [ "$S27_RCODE" = "10002" ] || [ "$S27_RCODE" = "10003" ]; then
  skip "S27c retrieve 回传 wrapped_key（本机要求登录取件）" "code=${S27_RCODE}"
elif [ -n "$S27_WK" ] && [ "$S27_WK" = "$S27_ENVELOPE" ]; then
  ok "S27c retrieve 原样逐字回传 wrapped_key"
else
  bad "S27c retrieve 未原样回传 wrapped_key" "rcode=${S27_RCODE:-?} wk=${S27_WK:-<空>}（期望与提交值逐字一致）"
fi

# ④ 旧形态负对照：encrypted 无 wrapped_key ⇒ 不铸码（密钥在 URL #fragment，服务端无码可铸）
S27D=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"s27-legacy-hashkey","expire_value":3,"expire_style":"count","require_auth":false,"encrypted":true}')
S27D_CODE=$(printf '%s\n' "$S27D" | J "d['data'].get('code') or ''")
register_probe "$S27D_CODE"
S27D_PICK=$(printf '%s\n' "$S27D" | J "d['data'].get('pickup_code') or ''")
if [ -z "$S27D_CODE" ] || is_jerr "$S27D_CODE"; then
  bad "S27d 旧形态分享创建失败" "resp=${S27D}"
elif [ -z "$S27D_PICK" ]; then
  ok "S27d 旧形态（encrypted 无 wrapped_key）不铸取件码（负对照）"
else
  bad "S27d 旧形态仍铸了取件码" "pickup=${S27D_PICK}（encrypted 无 wrapped_key 须不铸码）"
fi

# ⑤ wrapped_key 形状校验（core PR#45）：非 base64 / 解码后超 512B ⇒ 10001 显式拒绝
S27E=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d '{"text":"s27-bad-b64","expire_value":3,"expire_style":"count","require_auth":false,"encrypted":true,"wrapped_key":"!!not-base64!!"}')
[ "$(printf '%s\n' "$S27E" | J "d.get('code')")" = "10001" ] &&
  ok "S27e 非 base64 信封被拒（code=10001）" ||
  bad "S27e 非 base64 信封未被拒" "code=$(printf '%s\n' "$S27E" | J "d.get('code')")（期望 10001；形状非法须显式拒绝）"
S27_LONG=$(head -c 700 /dev/zero | base64 | tr -d '\n')
S27E2=$(curl -s -X POST "$BASE/share/text/" -H "$AH" -H 'Content-Type: application/json' \
  -d "{\"text\":\"s27-oversize-b64\",\"expire_value\":3,\"expire_style\":\"count\",\"require_auth\":false,\"encrypted\":true,\"wrapped_key\":\"$S27_LONG\"}")
[ "$(printf '%s\n' "$S27E2" | J "d.get('code')")" = "10001" ] &&
  ok "S27e2 超长信封被拒（解码 700B>512B，code=10001）" ||
  bad "S27e2 超长信封未被拒" "code=$(printf '%s\n' "$S27E2" | J "d.get('code')")（期望 10001；须防存储/传输放大）"

# ── S28 目录上传（5.3.0 rel_dir）：结构保真 + 五条负对照 ──────────────────
# 判据不是"能传上去"，而是"zip 解出来的路径与上传时的目录结构逐路径一致"——
# 只验上传成功无法发现「rel_dir 被静默丢弃、zip 全部拍平」这种退化。
# 五条负对照各自锁一个逃逸口：上跳段 / 绝对路径 / 数量不匹配 / 同目录同名 / 中段上跳。
S28_TOK=$(head -c 8 /dev/urandom | sha256sum | cut -c1-12)
mkdir -p "$SMOKE_RUN_DIR/src/docs/guide" "$SMOKE_RUN_DIR/src/docs"
printf '%s\n' "s28-guide-$S28_TOK" >"$SMOKE_RUN_DIR/src/docs/guide/readme.txt"
printf '%s\n' "s28-root-$S28_TOK" >"$SMOKE_RUN_DIR/src/docs/readme.txt"
S28=$(curl -s -X POST "$BASE/api/v1/share/multi-direct" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/guide/readme.txt" -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" \
  -F "dirs=docs/guide" -F "dirs=docs" \
  -F "expire_value=1" -F "expire_style=day")
S28_CODE=$(printf '%s\n' "$S28" | J "d['data'].get('code') or ''")
register_probe "$S28_CODE"
[ -n "$S28_CODE" ] && ! is_jerr "$S28_CODE" && ok "S28a 目录分享建码 code=$S28_CODE" || bad "S28a 目录分享" "$(printf '%s\n' "$S28" | head -c 160)"

# S28b 结构保真：zip 条目名必须**恰好**是这两条（含目录前缀），且内容对得上各自目录
S28_DL=$(curl -s "$BASE/share/select/?code=$S28_CODE" | J "d['data'].get('download_url') or ''")
case "$S28_DL" in /*) S28_DL="$BASE$S28_DL" ;; esac
curl -s "$S28_DL" -o "$SMOKE_RUN_DIR/art/s28.zip"
"$PY" -c "
import zipfile
z = zipfile.ZipFile('$SMOKE_RUN_DIR/art/s28.zip')
names = sorted(z.namelist())
want = ['docs/guide/readme.txt', 'docs/readme.txt']
assert names == want, names
assert z.read('docs/guide/readme.txt').strip() == b's28-guide-$S28_TOK'
assert z.read('docs/readme.txt').strip() == b's28-root-$S28_TOK'
print('ZIP-DIR-OK')
" 2>/dev/null && ok "S28b zip 逐路径保留目录结构（同 basename 不同目录共存）" ||
  bad "S28b zip 结构不符" "$("$PY" -c "
import zipfile,sys
try:
    print(sorted(zipfile.ZipFile('$SMOKE_RUN_DIR/art/s28.zip').namelist()))
except Exception as e:
    print('ERR', e)
" 2>&1 | head -c 200)"

# S28c-e 负对照（消毒闸）：任一条被放行 = 路径穿越面回归
s28_reject() { # $1=标签 $2=期望理由，其余=curl 参数
  _tag="$1"
  shift
  _r=$(curl -s -o "$SMOKE_RUN_DIR/art/s28r.json" -w '%{http_code}' -X POST "$BASE/api/v1/share/multi-direct" "$@")
  _b=$(J "d.get('code')" <"$SMOKE_RUN_DIR/art/s28r.json" 2>/dev/null | head -1)
  if [ "$_r" != "200" ] || [ "$_b" != "0" ]; then
    ok "S28$_tag 被拒（http=${_r} code=${_b}）"
  else
    bad "S28$_tag 未被拒" "http=$_r code=$_b —— 非法 rel_dir 被放行 = 穿越面回归"
  fi
}
s28_reject "c 上跳段（../evil）" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" -F "dirs=../evil" -F "expire_value=1" -F "expire_style=day"
s28_reject "d 绝对路径（/etc）" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" -F "dirs=/etc" -F "expire_value=1" -F "expire_style=day"
s28_reject "e 中段上跳（a/../../b）" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" -F "dirs=a/../../b" -F "expire_value=1" -F "expire_style=day"
# S28f 数量不匹配：dirs 少于 files ⇒ 整单拒绝（若放行，多出的文件会拿到空目录，
# 即「目录被静默丢弃」——正是这次功能最怕的退化）
s28_reject "f dirs 数量不足" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" -F "files=@$SMOKE_RUN_DIR/src/docs/guide/readme.txt" \
  -F "dirs=docs" -F "expire_value=1" -F "expire_style=day"
# S28g 同目录同名重复：判重键是完整相对路径 ⇒ 同目录同名必须显式报错，不能静默改名
S28G=$(curl -s -o "$SMOKE_RUN_DIR/art/s28g.json" -w '%{http_code}' -X POST "$BASE/api/v1/share/multi-direct" \
  -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" -F "files=@$SMOKE_RUN_DIR/src/docs/readme.txt" \
  -F "dirs=docs" -F "dirs=docs" -F "expire_value=1" -F "expire_style=day")
S28G_BIZ=$(J "d.get('code')" <"$SMOKE_RUN_DIR/art/s28g.json" 2>/dev/null | head -1)
if [ "$S28G" != "200" ] || [ "$S28G_BIZ" != "0" ]; then
  ok "S28g 同目录同名被拒（http=${S28G} code=${S28G_BIZ}）"
else
  bad "S28g 同目录同名未被拒" "http=$S28G code=$S28G_BIZ —— 同路径重复须显式报错，不得静默改名"
fi

# ── S29 二次验证 + 登录设备（5.2.0 账号与信任）：四对正/负对照 ────────────
# 为什么用**独立用户** smoketotp 而不是复用手推的 smoker：这一域会把账号
# 改成「必须二验才能登录」。一旦中途崩掉留下开启态，smoker 的下一次登录
# （S13a）就会恒 40012 ⇒ 整份冒烟的其余断言全假红。用专属用户隔离爆炸半径，
# 最坏情况只是本节 SKIP（并给出可手工复位的一句话）。
S29_USER=smoketotp
S29_PASS=smoke12345
s29_login() { # $1=可选二验码；回显 token（失败为空）
  if [ -n "${1:-}" ]; then
    curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$S29_USER\",\"password\":\"$S29_PASS\",\"totp_code\":\"$1\"}" | J "d.get('data',{}).get('token') or ''"
  else
    curl -s -X POST "$BASE/user/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$S29_USER\",\"password\":\"$S29_PASS\"}" | J "d.get('data',{}).get('token') or ''"
  fi
}
s29_reset_hint="手工复位：UPDATE users SET totp_enabled=0,totp_secret='',totp_recovery_codes='' WHERE username='$S29_USER';"
curl -s -X POST "$BASE/user/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$S29_USER\",\"password\":\"$S29_PASS\",\"nickname\":\"$S29_USER\",\"email\":\"$S29_USER@example.com\"}" >/dev/null
S29_TOKEN=$(s29_login "")
if [ -z "$S29_TOKEN" ] || is_jerr "$S29_TOKEN"; then
  # 两种可能：注册关闭（环境前置不足）或上轮残留的二验态。二者都不是产品缺陷。
  skip "S29 二次验证 + 登录设备" "smoketotp 无法直接登录（注册关闭或上轮残留二验）；$s29_reset_hint"
  S29_SKIPPED=1
fi

if [ "${S29_SKIPPED:-0}" != 1 ]; then
  # ① 会话列表：必须存在且标出「当前设备」（前端据此渲染「这台」）
  S29_SESS=$(curl -s "$BASE/user/sessions" -H "Authorization: Bearer $S29_TOKEN")
  S29_CNT=$(printf '%s\n' "$S29_SESS" | J "len(d['data']['sessions'])")
  S29_CUR=$(printf '%s\n' "$S29_SESS" | J "sum(1 for s in d['data']['sessions'] if s.get('current'))")
  if [ "$S29_CNT" -ge 1 ] && [ "$S29_CUR" = "1" ]; then
    ok "S29a 登录设备列表有 1 条 current（共 $S29_CNT 条）"
  else
    bad "S29a 登录设备列表" "count=${S29_CNT} current=${S29_CUR}（期望 >=1 条且恰 1 条 current）"
  fi

  # ② 绑定：setup 只发密钥不启用 ⇒ 必须再送一次有效码
  S29_SETUP=$(curl -s -X POST "$BASE/user/totp/setup" -H "Authorization: Bearer $S29_TOKEN")
  S29_SEC=$(printf '%s\n' "$S29_SETUP" | J "d['data']['secret']")
  if [ -n "$S29_SEC" ] && ! is_jerr "$S29_SEC"; then
    ok "S29b TOTP setup 回密钥（尚未启用）"
  else
    bad "S29b TOTP setup" "$(printf '%s\n' "$S29_SETUP" | head -c 140)"
  fi
  S29_CODE=$("$PY" -c "
import base64,hmac,hashlib,struct,sys,time
s=sys.argv[1].strip().replace(' ','').upper(); s+='='*(-len(s)%8)
k=base64.b32decode(s); c=int(time.time()//30)
m=hmac.new(k,struct.pack('>Q',c),hashlib.sha1).digest(); o=m[-1]&0x0F
print(str((struct.unpack('>I',m[o:o+4])[0]&0x7FFFFFFF)%1000000).zfill(6))
" "$S29_SEC" 2>/dev/null)
  # ③ 负对照：错码不得启用（否则「扫了码但客户端算错时间」也会被绑上）
  S29_EBAD=$(curl -s -o "$SMOKE_RUN_DIR/art/s29e.json" -w '%{http_code}' -X POST "$BASE/user/totp/enable" \
    -H "Authorization: Bearer $S29_TOKEN" -H 'Content-Type: application/json' -d '{"code":"000000"}')
  S29_EBIZ=$(J "d.get('code')" <"$SMOKE_RUN_DIR/art/s29e.json" 2>/dev/null | head -1)
  if [ "$S29_EBAD" != "200" ] && [ "$S29_EBIZ" = "40013" ]; then
    ok "S29c 错码启用被拒（40013）"
  else
    bad "S29c 错码启用未被拒" "http=${S29_EBAD} code=${S29_EBIZ}（期望 400/40013）"
  fi
  # ④ 正路径：正确码启用 + 一次性返回 8 个恢复码（手机丢了唯一退路）
  S29_EN=$(curl -s -X POST "$BASE/user/totp/enable" -H "Authorization: Bearer $S29_TOKEN" \
    -H 'Content-Type: application/json' -d "{\"code\":\"$S29_CODE\"}")
  S29_RCS=$(printf '%s\n' "$S29_EN" | J "','.join(d['data']['recovery_codes'])")
  S29_RC1=$(printf '%s' "$S29_RCS" | cut -d, -f1)
  S29_RC2=$(printf '%s' "$S29_RCS" | cut -d, -f2)
  S29_RCN=$(printf '%s' "$S29_RCS" | awk -F, '{print NF}')
  if [ "$S29_RCN" = "8" ]; then
    ok "S29d 正确码启用成功且返回 8 个恢复码"
  else
    bad "S29d 启用/恢复码" "n=$S29_RCN resp=$(printf '%s\n' "$S29_EN" | head -c 140)"
  fi
  # ⑤ 负对照（5.2.0 的核心语义）：已开二验后，只凭口令不得登录
  S29_L1=$(curl -s -o "$SMOKE_RUN_DIR/art/s29l.json" -w '%{http_code}' -X POST "$BASE/user/login" \
    -H 'Content-Type: application/json' -d "{\"username\":\"$S29_USER\",\"password\":\"$S29_PASS\"}")
  S29_L1BIZ=$(J "d.get('code')" <"$SMOKE_RUN_DIR/art/s29l.json" 2>/dev/null | head -1)
  if [ "$S29_L1" != "200" ] && [ "$S29_L1BIZ" = "40012" ]; then
    ok "S29e 开启二验后仅凭口令被拒（40012）"
  else
    bad "S29e 仅凭口令仍能登录" "http=${S29_L1} code=${S29_L1BIZ}（期望 401/40012 —— 二验形同虚设）"
  fi
  # ⑥ 正路径：TOTP 码登录
  S29_T1=$(s29_login "$S29_CODE")
  [ -n "$S29_T1" ] && ! is_jerr "$S29_T1" && ok "S29f TOTP 码登录成功" || bad "S29f TOTP 码登录" "token 空"
  # ⑦ 正路径：恢复码登录（一次性）——这是「手机丢了」的唯一退路，不能被只测 TOTP 掩盖
  S29_T2=$(s29_login "$S29_RC1")
  [ -n "$S29_T2" ] && ! is_jerr "$S29_T2" && ok "S29g 恢复码可登录" || bad "S29g 恢复码登录" "token 空（rc1=${S29_RC1}）"
  # ⑧ 负对照：关闭二验必须双因子——错口令不得通过
  S29_DBAD=$(curl -s -o "$SMOKE_RUN_DIR/art/s29d.json" -w '%{http_code}' -X POST "$BASE/user/totp/disable" \
    -H "Authorization: Bearer $S29_T1" -H 'Content-Type: application/json' \
    -d "{\"password\":\"wrong-$S29_PASS\",\"code\":\"$S29_RC2\"}")
  S29_DBIZ=$(J "d.get('code')" <"$SMOKE_RUN_DIR/art/s29d.json" 2>/dev/null | head -1)
  if [ "$S29_DBAD" != "200" ] && [ "$S29_DBIZ" = "40013" ]; then
    ok "S29h 错口令关闭二验被拒（40013）"
  else
    bad "S29h 错口令关闭二验未被拒" "http=${S29_DBAD} code=${S29_DBIZ}（令牌被盗后关二验=最常见的绕过路径）"
  fi
  # ⑨ 正路径：口令 + 恢复码关闭，然后确认「真的关了」（否则残缺态会留在库里）
  S29_OFF=$(curl -s -X POST "$BASE/user/totp/disable" -H "Authorization: Bearer $S29_T1" \
    -H 'Content-Type: application/json' -d "{\"password\":\"$S29_PASS\",\"code\":\"$S29_RC2\"}")
  S29_OFFBIZ=$(printf '%s\n' "$S29_OFF" | J "d.get('code')")
  S29_T3=$(s29_login "")
  if [ "$S29_OFFBIZ" = "0" ] && [ -n "$S29_T3" ] && ! is_jerr "$S29_T3"; then
    ok "S29i 关闭二验后仅凭口令即可登录（负对照：确实关掉了）"
  else
    bad "S29i 关闭后仍不能登录" "code=${S29_OFFBIZ}（未关干净会污染后续冒烟；${s29_reset_hint}）"
  fi
  # ⑩ 退出所有设备：会话纪元 +1 ⇒ 手上这枚令牌立即失效（不是下次才失效）
  S29_RA=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/user/sessions/revoke-all" -H "Authorization: Bearer $S29_T3")
  S29_AFTER=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/user/sessions" -H "Authorization: Bearer $S29_T3")
  if [ "$S29_RA" = "200" ] && [ "$S29_AFTER" = "401" ]; then
    ok "S29j 退出所有设备后旧令牌立即 401"
  else
    bad "S29j 退出所有设备" "revoke=${S29_RA} after=${S29_AFTER}（期望 200/401）"
  fi
fi

# ── S30 分享到期提醒的配置面（5.5.0）────────────────────────────────────
# 交付形态：notify.expiry_reminder = {enabled, advance_hours(1..720),
# interval_minutes(1..1440)}，默认**关**。提醒循环每个节拍读**全局生效快照**
# ⇒ 落库即生效，不必重启；越界值在运行期收敛到边界（0 取默认）。
#
# 为什么这一节只打「配置面」，不打端到端投递：
# 能触发提醒的状态是「寿命 > 提前量 且 剩余 ≤ 提前量」，即 created_at 至少 1 小时前、
# 到期在 1 小时内。冒烟跑在真实实例上**造不出**这个状态——新建分享的寿命就是它的
# 有效期，而 advance 的下限是 1h（clamp，单测钉住）⇒ 新建即「短命分享」，被有意排除；
# 用管理端把到期时间改近又会让 lifespan = 新到期日 - created_at 一起退化。
# ⇒ 投递/去重/回滚/多副本仲裁由 core 单测的**可控时钟**覆盖（runExpiryReminderRound
#   的 now 是显式参数），这一节只锁「存得进、读得回、字段级合并、兄弟渠道不被牵连、
#   复原得回」——即「管理员翻了开关却永远不生效」这类静默失效。
#
# ⚠️ 这一节**从不改 enabled**，只动两个数字。理由有两条：
#   ① 把提醒打开会让真实用户收到站内信（冒烟不该给生产用户发信）；
#   ② 复原只在正常路径生效，中断（Ctrl-C / 超时）时残留的数字无害，残留的
#      enabled=true 会把提醒打开 ⇒ 那才是不可接受的副作用。
#
# ⚠️ 也注意这一节的**盲区**：回读走的是 DB + 内存镜像，**不是**全局生效快照 ⇒
# 「写进库了但没 overlay 到 conf.Snapshot()」这类缺陷冒烟**抓不到**（表现是提醒
# 永远不触发，而配置页显示已开启）。它由 core 的
# TestExpiryReminderConfigSaveEffect（保存→回读→conf.Snapshot() 生效）兜住。
# ⚠️ 前置（2026-11-07 CI 实录）：**全新实例上 notify 段整体是 null**。
# core 的指针段语义与 p2p 段一致：「从未在线保存过 ⇒ GET 返回 null，而不是零值段」
# ⇒ 直接断言「段里有 expiry_reminder」会红在「段不存在」这个边界上，而不是红在产品
# 缺陷（首轮 CI 就是这么红的：PASS=130 FAIL=1，notify 现有键为空）。
# 处置与 S19 的 upload_ex 同款：先用**默认值**把段落库（默认 = 关 / 24h / 60min，
# 与 core 的 viper 默认同口径 ⇒ 行为等价，且**不会打开提醒**），再断言。
# 若实例 < 5.5.0，写进去的键会被 json 解码静默忽略 ⇒ 段里仍然没有它 ⇒ S30a 红。
S30_CFG=$(curl -s "$BASE/admin/config" -H "$AH")
S30_HAS=$(printf '%s\n' "$S30_CFG" | J "'expiry_reminder' in (d['data'].get('notify') or {})")
if [ "$S30_HAS" != "True" ]; then
  note "S30 前置：notify.expiry_reminder 未落库（全新实例 notify 段为 null）⇒ 先写默认值再断言"
  curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' \
    -d '{"notify":{"expiry_reminder":{"enabled":false,"advance_hours":24,"interval_minutes":60}}}' >/dev/null
  S30_CFG=$(curl -s "$BASE/admin/config" -H "$AH")
  S30_HAS=$(printf '%s\n' "$S30_CFG" | J "'expiry_reminder' in (d['data'].get('notify') or {})")
fi
if [ "$S30_HAS" != "True" ]; then
  bad "S30a /admin/config 未下发 notify.expiry_reminder 段（该实例 < 5.5.0？）" \
    "notify 现有键=$(printf '%s\n' "$S30_CFG" | J "','.join(sorted((d['data'].get('notify') or {}).keys()))")｜写默认值后仍不出现 = 版本不含该能力"
else
  ok "S30a /admin/config 下发 notify.expiry_reminder 段（5.5.0 交付）"
  S30_EN=$(printf '%s\n' "$S30_CFG" | J "(d['data']['notify']['expiry_reminder'] or {}).get('enabled')")
  S30_ADV=$(printf '%s\n' "$S30_CFG" | J "(d['data']['notify']['expiry_reminder'] or {}).get('advance_hours')")
  S30_ITV=$(printf '%s\n' "$S30_CFG" | J "(d['data']['notify']['expiry_reminder'] or {}).get('interval_minutes')")
  S30_WH=$(printf '%s\n' "$S30_CFG" | J "(d['data']['notify'] or {}).get('webhook_url') or ''")
  S30_TG=$(printf '%s\n' "$S30_CFG" | J "((d['data']['notify'] or {}).get('telegram') or {}).get('chat_id') or ''")
  S30_BK=$(printf '%s\n' "$S30_CFG" | J "((d['data']['notify'] or {}).get('bark') or {}).get('device_key') or ''")
  # enabled 原值转成 JSON 字面量（Python 打印的是 True/False，JSON 要 true/false）
  case "$S30_EN" in
    True) S30_EN_JSON=true ;;
    *) S30_EN_JSON=false ;;
  esac

  # S30b 两个数字写进去能原样读回（advance 取 7、interval 取 23：都不是默认值，
  # 也不是边界值 ⇒ 读回等于它们就说明真的写进去了，而不是被 clamp/默认值掩盖）
  curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' \
    -d '{"notify":{"expiry_reminder":{"advance_hours":7,"interval_minutes":23}}}' >/dev/null
  S30_CFG2=$(curl -s "$BASE/admin/config" -H "$AH")
  S30_ADV2=$(printf '%s\n' "$S30_CFG2" | J "(d['data']['notify']['expiry_reminder'] or {}).get('advance_hours')")
  S30_ITV2=$(printf '%s\n' "$S30_CFG2" | J "(d['data']['notify']['expiry_reminder'] or {}).get('interval_minutes')")
  S30_EN2=$(printf '%s\n' "$S30_CFG2" | J "(d['data']['notify']['expiry_reminder'] or {}).get('enabled')")
  if [ "$S30_ADV2" = "7" ] && [ "$S30_ITV2" = "23" ]; then
    ok "S30b 提醒参数保存→回读一致（advance=7 interval=23）"
  else
    bad "S30b 提醒参数保存后回读不一致" "advance=${S30_ADV2:-?} interval=${S30_ITV2:-?}（期望 7 / 23）"
  fi
  # 只提交两个数字不得动开关（不然一次冒烟就给真实用户开了提醒）
  if [ "$S30_EN2" = "$S30_EN" ]; then
    ok "S30c 局部提交不牵动 enabled（保持 ${S30_EN}）"
  else
    bad "S30c 局部提交改动了 enabled" "before=${S30_EN} after=${S30_EN2}"
  fi

  # S30d 字段级合并：只带 enabled（原值）⇒ 刚写的两个数字必须保留。
  # 被清零的话 advance_hours=0 会被运行期 clamp 成默认 24 ⇒ 管理台显示「关着」，
  # 但管理员下次一开就是 24 小时而不是他上次设的 7 小时（窗口被悄悄改掉）。
  curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' \
    -d "{\"notify\":{\"expiry_reminder\":{\"enabled\":$S30_EN_JSON}}}" >/dev/null
  S30_CFG3=$(curl -s "$BASE/admin/config" -H "$AH")
  S30_ADV3=$(printf '%s\n' "$S30_CFG3" | J "(d['data']['notify']['expiry_reminder'] or {}).get('advance_hours')")
  S30_ITV3=$(printf '%s\n' "$S30_CFG3" | J "(d['data']['notify']['expiry_reminder'] or {}).get('interval_minutes')")
  if [ "$S30_ADV3" = "7" ] && [ "$S30_ITV3" = "23" ]; then
    ok "S30d 只提交 enabled 不清掉同级两个数字（字段级合并）"
  else
    bad "S30d 只提交 enabled 把同级字段清零了" "advance=${S30_ADV3:-?} interval=${S30_ITV3:-?}（期望仍是 7 / 23）"
  fi

  # S30e 兄弟渠道不被牵连（webhook / telegram / bark 与提醒段同级，整段替换时最易被冲掉）
  S30_WH3=$(printf '%s\n' "$S30_CFG3" | J "(d['data']['notify'] or {}).get('webhook_url') or ''")
  S30_TG3=$(printf '%s\n' "$S30_CFG3" | J "((d['data']['notify'] or {}).get('telegram') or {}).get('chat_id') or ''")
  S30_BK3=$(printf '%s\n' "$S30_CFG3" | J "((d['data']['notify'] or {}).get('bark') or {}).get('device_key') or ''")
  if [ "$S30_WH" = "$S30_WH3" ] && [ "$S30_TG" = "$S30_TG3" ] && [ "$S30_BK" = "$S30_BK3" ]; then
    ok "S30e 改提醒段不牵连 webhook/telegram/bark"
  else
    bad "S30e 改提醒段牵连了兄弟渠道" "webhook ${S30_WH}→${S30_WH3} telegram ${S30_TG}→${S30_TG3} bark ${S30_BK}→${S30_BK3}"
  fi

  # S30f 复原（冒烟不得永久改动目标实例；数字残留虽无害，但会改变管理台显示值）
  S30_RESTORE=$("$PY" -c "import json,sys;print(json.dumps({'notify':{'expiry_reminder':{'enabled':(sys.argv[1]=='True'),'advance_hours':int(sys.argv[2] or 0),'interval_minutes':int(sys.argv[3] or 0)}}}))" \
    "$S30_EN" "$S30_ADV" "$S30_ITV" 2>/dev/null || echo '')
  if [ -n "$S30_RESTORE" ]; then
    curl -s -X PUT "$BASE/admin/config" -H "$AH" -H 'Content-Type: application/json' -d "$S30_RESTORE" >/dev/null
    S30_CFG4=$(curl -s "$BASE/admin/config" -H "$AH")
    S30_ADV4=$(printf '%s\n' "$S30_CFG4" | J "(d['data']['notify']['expiry_reminder'] or {}).get('advance_hours')")
    S30_ITV4=$(printf '%s\n' "$S30_CFG4" | J "(d['data']['notify']['expiry_reminder'] or {}).get('interval_minutes')")
    S30_EN4=$(printf '%s\n' "$S30_CFG4" | J "(d['data']['notify']['expiry_reminder'] or {}).get('enabled')")
    if [ "$S30_ADV4" = "$S30_ADV" ] && [ "$S30_ITV4" = "$S30_ITV" ] && [ "$S30_EN4" = "$S30_EN" ]; then
      ok "S30f 复原到位（advance=${S30_ADV} interval=${S30_ITV} enabled=${S30_EN}）"
    else
      bad "S30f 提醒段未复原" "期望 ${S30_ADV}/${S30_ITV}/${S30_EN}，实得 ${S30_ADV4}/${S30_ITV4}/${S30_EN4}"
    fi
  else
    bad "S30f 复原请求构造失败" "原值 enabled=${S30_EN} advance=${S30_ADV} interval=${S30_ITV}"
  fi
fi

# ── S35 参数校验（pigeonbox#338：core#102 过滤参数 / core#104 分页参数）────
# 判据函数 judge_param_error / judge_page_ok 与 --selfcheck-params 的 stub 负对照
# **共用同一实现**（判据自证：对旧语义响应必须判 BAD ⇒ 对旧版本实例跑本组必红）。
# ⚠️ 真机复验待下趟列车：103/253 升到带 core#102/#104 的版本后本组随冒烟自动生效；
#    旧版本实例上本组会红（解析失败静默 200 全量/默认页）——那是判据在区分
#    新旧语义，不是假红。
# S35a/S35b：过滤时间参数非法 ⇒ 400 + 10001 + message 点名 created_after。
#   S35b 用**未编码**的 +0800（date %z 原生形态）：URL 里的 + 解码成空格 ⇒
#   服务端看到的值带空格 ⇒ 解析失败 ⇒ 必须 400（旧语义：静默丢条件回全量）。
S35_BAD_TS='2026-01-02T03:04:05+0800'
s35_expect_param_error "S35a /admin/files/filter created_after=not-a-time 判红" created_after "$AH" "$BASE/admin/files/filter?created_after=not-a-time"
s35_expect_param_error "S35b /admin/files/filter created_after=<未编码 +0800> 判红" created_after "$AH" "$BASE/admin/files/filter?created_after=$S35_BAD_TS"
# S35c：分页非数字（page=abc）⇒ 400 + 10001 + message 点名 page（五端点各一条）
s35_expect_param_error "S35c1 /admin/files/filter page=abc 判红" page "$AH" "$BASE/admin/files/filter?page=abc"
s35_expect_param_error "S35c2 /admin/users/filter page=abc 判红" page "$AH" "$BASE/admin/users/filter?page=abc"
s35_expect_param_error "S35c3 /admin/logs/transfer page=abc 判红" page "$AH" "$BASE/admin/logs/transfer?page=abc"
# S35d：合法分页行为不变（防「一律 400」假修复）：page=1&page_size=5 ⇒ 200 且 ≤5 条
s35_expect_page_ok "S35d1 /admin/files/filter 合法分页 200 且 ≤5 条" "$AH" "$BASE/admin/files/filter?page=1&page_size=5"
s35_expect_page_ok "S35d2 /admin/users/filter 合法分页 200 且 ≤5 条" "$AH" "$BASE/admin/users/filter?page=1&page_size=5"
s35_expect_page_ok "S35d3 /admin/logs/transfer 合法分页 200 且 ≤5 条" "$AH" "$BASE/admin/logs/transfer?page=1&page_size=5"
# 用户侧两端点需登录用户令牌（UTOK 在 S13 段取得）
case "${UTOK:-}" in
  '' | JERR* | None | none)
    skip "S35c4/c5/d4/d5 用户侧参数判据（/api/v1/user/shares、/api/v1/notifies/mine）" "无用户令牌 UTKO（注册/登录未成功）⇒ 不判绿"
    ;;
  *)
    UATH="Authorization: Bearer $UTOK"
    s35_expect_param_error "S35c4 /api/v1/user/shares page=abc 判红" page "$UATH" "$BASE/api/v1/user/shares?page=abc"
    s35_expect_param_error "S35c5 /api/v1/notifies/mine page=abc 判红" page "$UATH" "$BASE/api/v1/notifies/mine?page=abc"
    s35_expect_page_ok "S35d4 /api/v1/user/shares 合法分页 200 且 ≤5 条" "$UATH" "$BASE/api/v1/user/shares?page=1&page_size=5"
    s35_expect_page_ok "S35d5 /api/v1/notifies/mine 合法分页 200 且 ≤5 条" "$UATH" "$BASE/api/v1/notifies/mine?page=1&page_size=5"
    ;;
esac

# ── 收尾：探针回收 + 终验 + 还原 S13 改过的用户配置 ────────────────────────
# ① 探针回收（#323）：登记码逐个经管理端 filter 找 id、batch-delete 软删；
#    随后终验断言「登记码在管理端 filter 里查不到」⇒ ok()；还在/查询失败 ⇒ bad()
#    （不 mask 失败）。回收与还原都要用 TOK，先收探针再还原（trap 路径同序）。
# ② 还原逻辑独立成 scripts/smoke-user-config-restore.sh（写回 + 回读比对，
# 三条静默逃逸口全部改为非零退出码 ⇒ 还原失败计入 FAIL ⇒ 退出码非 0）。
# 正常路径在此各调用一次；异常路径（Ctrl-C / 超时 / 中途失败）由 on_exit trap 兜底
# （PENDING 幂等哨兵 ⇒ 两条路径各调一次也只真正执行一次）。
cleanup_probes
verify_probes_gone
verify_storage_residue
verify_smoke_accounts_clean
restore_user_config

echo ""
echo "=============================="
echo "SMOKE RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
OK=1
exit $FAIL
