#!/usr/bin/env bash
#
# 门禁：所有部署模板里的「反代体积上限」默认值必须一致，且不低于下限。
#
# 为什么有这道门禁（2026-10-23 413 事故的复盘）：
#   事故根因是「业务上限（upload.max_file_size）与反代防线（client_max_body_size）
#   脱节」——nginx 1 GiB 硬顶、后端不限 ⇒ 3.19GiB 文件传到一半被拒成 413。
#   修复时把上限从 1024m 抬到 8192m，**改了 4 处模板却漏了第 5 处**
#   （仓根 .env.example 仍是 1024m）⇒ 新部署 `cp .env.example .env` 仍是 1 GiB 防线
#   ⇒ 同一个不变量仍能被破坏 ⇒ 事故复发。
#
#   「同一份上限散落多处、改一处漏三处」是**结构性**风险，靠人记不住 ⇒ 用门禁机械保证：
#   任何一处被单独改动（改小/改大/删掉）⇒ 本门禁红 ⇒ CI 拦下。
#
# 扫的形态：
#   ① compose 环境变量默认值：CLIENT_MAX_BODY_SIZE=${PB_MAX_BODY_SIZE:-<值>}
#   ② env 文件赋值：          PB_MAX_BODY_SIZE=<值>
#   ③ nginx 裸指令：          client_max_body_size <值>;
#   ④ Helm chart 的 values：   clientMaxBodySize: "<值>"（跨仓，见下）
#   ⑤ compose 环境变量裸赋值： CLIENT_MAX_BODY_SIZE=<值>（2026-11-14 #370 补：
#      实测 ugreen/upk/rootfs_common/docker-compose.yaml 的该形态整行漏扫，
#      门禁仍报「共扫到 N 处」exit 0 ⇒ 第五种写法静默绿灯）
#
# 两条值形态口径（2026-11-14 #370/#375 同批）：
#   · 变量名/指令名**大小写都收**（扫描加 -i）⇒ CLIENT_ / client_ 同形都进射程；
#   · 单位后缀 **kK m M g G 都收**（[kKmMgG]）且提取后归一成小写 —— nginx 单位
#     大小写均合法，只认小写会把 8192M 提成 8192 字节 ⇒ 既误判低于下限、又在
#     一致性断言里多出一个 distinct 值 ⇒ **假红**（#375）。
#
# 空转守卫（#370）：文件里有 BODY_SIZE 字样、模式集却在**该文件**一条都没命中
#   ⇒ 判红。防「第六种声明形态」——模式集不认识的新写法会让该文件整体漏扫，
#   而扫描照旧报绿（2026-10-30 出厂默认自相矛盾事故的教训：改一处≠改全）。
#
# 跨仓对账（2026-10-26 审计 P1）：charts 是**独立仓**（hub 仓 CI 里未必在同一
# checkout）⇒ 显式扫 ../charts/charts/pigeonbox/values.yaml；**存在才扫、不存在
# 则跳过并告警**（不硬失败），权威断言在 charts 仓自己的 CI 里
# （charts/.github/workflows/lint-test.yml ⇒ helm template 后断 CLIENT_MAX_BODY_SIZE）。
# 此前只对齐了 hub 仓内的模板，charts 仓仍是 1024m ⇒ Helm 用户按默认值部署 =
# nginx 1GiB 硬顶 + 服务端允许 4GiB ⇒ **重演 2026-10-23 的 413 事故**。
#
# 排除：tests/ 目录（测试夹具模拟用户 env，不参与部署）。
# 兼容：POSIX sh + 基础工具（不用关联数组/大小写展开，macOS 自带 bash 3.2 也能跑）。
set -uo pipefail
# 扫描根目录可覆盖（自证模式要指向临时工作区）
ROOT="${BODY_SIZE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      echo "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

MIN_BYTES=$((8192 * 1024 * 1024)) # 8 GiB：与业务上限(4 GiB)留一倍以上余量
EXCLUDE='/(tests?|__tests__|node_modules|\.git|\.vitepress|dist)/'

# 值 → 字节（支持 k/m/g 后缀与纯字节）
to_bytes() {
  _v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$_v" in
    *k) echo $((${_v%k} * 1024)) ;;
    *m) echo $((${_v%m} * 1024 * 1024)) ;;
    *g) echo $((${_v%g} * 1024 * 1024 * 1024)) ;;
    *) echo "$_v" ;;
  esac
}

# 模式集（#370 补 ⑤ + 全体单位 [kmg]→[kKmMgG]；-i 让变量名/指令名大小写都收）
SCAN_INCLUDES=(--include='*.yml' --include='*.yaml' --include='*.conf' --include='*.example' --include='*.env*' --include='Dockerfile')
vals=$(grep -rInEi 'PB_MAX_BODY_SIZE:-[0-9]+[kKmMgG]?|PB_MAX_BODY_SIZE=[0-9]+[kKmMgG]?|CLIENT_MAX_BODY_SIZE=[0-9]+[kKmMgG]?|client_max_body_size +[0-9]+[kKmMgG]?|clientMaxBodySize:[[:space:]]*"?[0-9]+[kKmMgG]?"?' \
  "${SCAN_INCLUDES[@]}" \
  . 2>/dev/null | grep -vE "$EXCLUDE" || true)

# ── 跨仓：charts 独立仓的反代上限（Helm 用户的默认部署路径）──────────────
# charts 仓不在 hub 仓的 checkout 里时**跳过并告警**（不硬失败）——
# 权威断言在 charts 仓自己的 CI（helm template 后断 CLIENT_MAX_BODY_SIZE）。
for charts_values in ../charts/charts/pigeonbox/values.yaml charts/charts/pigeonbox/values.yaml; do
  if [ -f "$charts_values" ]; then
    cross=$(grep -HnEi 'clientMaxBodySize:[[:space:]]*"?[0-9]+[kKmMgG]?"?' "$charts_values" 2>/dev/null || true)
    if [ -n "$cross" ]; then
      vals="$vals
$cross"
    fi
    echo "✓ 跨仓对账：已扫 charts 仓反代上限（${charts_values}）"
  else
    echo "! 跳过 charts 仓反代上限对账（$charts_values 不存在：hub 仓 CI 单仓 checkout）"
  fi
done

if [ -z "$vals" ]; then
  echo "✗ 没扫到任何反代体积上限声明——门禁自身失效（模板结构变了？）"
  exit 1
fi

tmp=$(mktemp)
# shellcheck disable=SC2162
printf '%s\n' "$vals" | while IFS= read -r line; do
  [ -z "$line" ] && continue
  file=${line%%:*}
  # #375：单位大小写都收并归一成小写——否则 8192M 被提成 8192（后缀丢）⇒
  # to_bytes 判低于下限；且 distinct 里 8192M / 8192m 算两种值 ⇒ 一致性断言同时假红。
  val=$(printf '%s' "$line" | grep -oE '[0-9]+[kKmMgG]?' | tail -1 | tr '[:upper:]' '[:lower:]')
  [ -z "$val" ] && continue
  echo "VAL $val" >>"$tmp"
  if [ "$(to_bytes "$val")" -lt "$MIN_BYTES" ]; then
    echo "LOW $file $val" >>"$tmp"
  fi
done

fail=0

# ── 空转守卫（#370）：文件里有 BODY_SIZE 字样、模式集却在该文件零命中 ⇒ 判红 ──
# 按**文件**判定：某个部署模板提到 BODY_SIZE 而我们一条都没扫到 ⇒ 它的声明形态
# 不在模式集里 ⇒ 该文件整体漏扫却仍可能报绿。2026-10-30 出厂默认自相矛盾事故的
# 教训是「四份反代模板改一处≠改全」——门禁绝不能在新形态上空转。
mention_files=$(grep -rIli 'body_size' "${SCAN_INCLUDES[@]}" \
  . 2>/dev/null | grep -vE "$EXCLUDE" | sed 's#^\./##' | sort -u || true)
hit_files=""
if [ -n "$vals" ]; then
  hit_files=$(printf '%s\n' "$vals" | cut -d: -f1 | sed 's#^\./##' | sort -u)
fi
unscanned=""
if [ -n "$mention_files" ]; then
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    if [ -n "$hit_files" ] && printf '%s\n' "$hit_files" | grep -qxF "$mf"; then
      continue
    fi
    unscanned="${unscanned}${mf}
"
  done <<<"$mention_files"
fi
if [ -n "$unscanned" ]; then
  echo "✗ 空转守卫：以下文件里有 BODY_SIZE 字样，但模式集在该文件一条都没命中："
  printf '%s' "$unscanned" | sed 's/^/    /'
  echo "    ⇒ 这些文件的声明形态不在模式集里（新写法/新形态），门禁对它们空转。"
  echo "    ⇒ 修法：把新形态加进本脚本的扫描模式集（别只改模板）。"
  fail=1
fi

lows=$(grep '^LOW ' "$tmp" || true)
if [ -n "$lows" ]; then
  printf '%s\n' "$lows" | while IFS= read -r l; do
    f=$(printf '%s' "$l" | cut -d' ' -f2)
    v=$(printf '%s' "$l" | cut -d' ' -f3)
    echo "✗ $f 的反代体积上限 = ${v}（$(to_bytes "$v") 字节）< 下限 8192m"
  done
  fail=1
fi

distinct=$(grep '^VAL ' "$tmp" | awk '{print $2}' | sort -u | tr '\n' ' ')
ndistinct=$(grep -c '^VAL ' "$tmp" || true)
nuniq=$(printf '%s\n' "$distinct" | wc -w | tr -d ' ')
if [ "$nuniq" -gt 1 ]; then
  echo "✗ 反代体积上限默认值有 $nuniq 种（${distinct}）——各处必须一致："
  printf '%s\n' "$vals" | sed 's/^/    /'
  fail=1
fi
rm -f "$tmp"

if [ "$fail" -ne 0 ]; then
  echo
  echo "口径（勿再改错）:"
  echo "  · 反代上限 = **物理防线**,不表达业务上限;业务上限在服务端 upload.max_file_size"
  echo "  · 不变量: 反代上限 >= 服务端 upload.max_file_size（否则 nginx 先拒成 413，业务上限形同虚设）"
  echo "  · 改这里要**一处不漏地同步**所有模板/示例；本门禁就是防漏改的"
  exit 1
fi

echo "✓ 反代体积上限默认值一致（${distinct}，≥ 8GiB），共扫到 $ndistinct 处声明"

# ── 自证：注入不一致/过小的值 ⇒ 本门禁必须变红 ─────────────────────────────
if [ "$SELFCHECK" -eq 1 ]; then
  SELF_TMP=$(mktemp -d)
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "$SELF_TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  mkdir -p "$SELF_TMP/deploy" "$SELF_TMP/charts/pigeonbox"
  self_fail=0

  cat >"$SELF_TMP/deploy/compose.yml" <<'YML'
services:
  frontend:
    environment:
      CLIENT_MAX_BODY_SIZE: ${PB_MAX_BODY_SIZE:-8192m}
YML
  cat >"$SELF_TMP/charts/pigeonbox/values.yaml" <<'YML'
clientMaxBodySize: "8192m"
YML

  # 基线：两处一致且 ≥ 下限 ⇒ 必须绿
  if BODY_SIZE_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-body-size-limits.sh" >/dev/null 2>&1; then
    echo "  ✓ 基线：一致且 ≥ 8GiB ⇒ 门禁绿"
  else
    echo "  ✗ 基线：一致且 ≥ 8GiB 竟然判红 ⇒ 门禁本身坏了" >&2
    self_fail=1
  fi

  # 注入一：某一处被改小 ⇒ 必须红（低于下限）
  cat >"$SELF_TMP/charts/pigeonbox/values.yaml" <<'YML'
clientMaxBodySize: "1024m"
YML
  if BODY_SIZE_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-body-size-limits.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「某处改成 1024m」后门禁仍绿 ⇒ 下限断言无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「某处改成 1024m」⇒ 门禁变红（下限断言有牙齿）"
  fi

  # 注入二：两处不一致（都 ≥ 下限但值不同）⇒ 必须红（一致性断言）
  cat >"$SELF_TMP/charts/pigeonbox/values.yaml" <<'YML'
clientMaxBodySize: "16384m"
YML
  if BODY_SIZE_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-body-size-limits.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「两处值不一致」后门禁仍绿 ⇒ 一致性断言无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「两处值不一致」⇒ 门禁变红（一致性断言有牙齿）"
  fi

  # 注入三：一个声明都扫不到 ⇒ 必须红（「门禁自身失效」守卫）
  SELF_TMP2=$(mktemp -d)
  mkdir -p "$SELF_TMP2/deploy"
  cat >"$SELF_TMP2/deploy/compose.yml" <<'YML'
services:
  frontend:
    image: docker.io/pigeonbox/frontend:1
YML
  if BODY_SIZE_ROOT="$SELF_TMP2" bash "$ROOT/scripts/check-body-size-limits.sh" >/dev/null 2>&1; then
    echo "  ✗ 注入「零处声明」后门禁仍绿 ⇒ 空转守卫无效" >&2
    self_fail=1
  else
    echo "  ✓ 注入「零处声明」⇒ 门禁变红（空转守卫有牙齿）"
  fi
  rm -rf "$SELF_TMP2"

  # 注入四（#370 形态盲区）：大写裸 CLIENT_MAX_BODY_SIZE=<值> ⇒ 必须红**且点名**
  # 并带出值——只靠空转守卫蒙对的话输出里不会有 1024m ⇒ 断言区分「扫到了」与「守卫喊了」。
  cat >"$SELF_TMP/charts/pigeonbox/values.yaml" <<'YML'
clientMaxBodySize: "8192m"
YML
  cat >"$SELF_TMP/deploy/extra.env" <<'ENV'
CLIENT_MAX_BODY_SIZE=1024m
ENV
  inj4_rc=0
  inj4_out=$(BODY_SIZE_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-body-size-limits.sh" 2>&1) || inj4_rc=$?
  if [ "$inj4_rc" -eq 0 ]; then
    echo "  ✗ 注入「大写裸 CLIENT_MAX_BODY_SIZE=1024m」后门禁仍绿 ⇒ 形态盲区没补上" >&2
    self_fail=1
  elif printf '%s' "$inj4_out" | grep -q 'extra.env' && printf '%s' "$inj4_out" | grep -q '1024m'; then
    echo "  ✓ 注入「大写裸 CLIENT_MAX_BODY_SIZE=1024m」⇒ 门禁变红并点名 extra.env=1024m（形态盲区补上）"
  else
    echo "  ✗ 判红但没点名 extra.env/1024m ⇒ 不是模式集扫到的，结论不可用" >&2
    printf '%s' "$inj4_out" | sed 's/^/      /' >&2
    self_fail=1
  fi
  rm -f "$SELF_TMP/deploy/extra.env"

  # 注入五（#375 大写单位假红）：两处单位都写成大写 8192M ⇒ 合法配置，必须**绿**
  # 且归一显示 8192m（修前会被提成 8192 ⇒ 判低于下限 + distinct 多一种 ⇒ 假红）。
  cat >"$SELF_TMP/deploy/compose.yml" <<'YML'
services:
  frontend:
    environment:
      CLIENT_MAX_BODY_SIZE: ${PB_MAX_BODY_SIZE:-8192M}
YML
  cat >"$SELF_TMP/charts/pigeonbox/values.yaml" <<'YML'
clientMaxBodySize: "8192M"
YML
  inj5_rc=0
  inj5_out=$(BODY_SIZE_ROOT="$SELF_TMP" bash "$ROOT/scripts/check-body-size-limits.sh" 2>&1) || inj5_rc=$?
  if [ "$inj5_rc" -ne 0 ]; then
    echo "  ✗ 注入「大写单位 8192M」后门禁判红 ⇒ 合法配置被冤（#375 假红）" >&2
    printf '%s' "$inj5_out" | sed 's/^/      /' >&2
    self_fail=1
  elif ! printf '%s' "$inj5_out" | grep -q '8192m'; then
    echo "  ✗ 大写单位没被归一成 8192m ⇒ 提取层仍只认小写（#375 没修）" >&2
    self_fail=1
  else
    echo "  ✓ 注入「大写单位 8192M」⇒ 门禁绿且归一为 8192m（不假红）"
  fi

  if [ "$self_fail" -ne 0 ]; then
    echo "✗ 自证失败：本门禁至少有一条断言没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：不一致/过小/零值/形态盲区(大写裸)/大写单位 ⇒ 判据各有牙齿"
fi
OK=1
