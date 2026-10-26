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
cd "$(dirname "$0")/.." || exit 1

MIN_BYTES=$((8192 * 1024 * 1024))   # 8 GiB：与业务上限(4 GiB)留一倍以上余量
EXCLUDE='/(tests?|__tests__|node_modules|\.git|\.vitepress|dist)/'

# 值 → 字节（支持 k/m/g 后缀与纯字节）
to_bytes() {
  _v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$_v" in
    *k) echo $(( ${_v%k} * 1024 )) ;;
    *m) echo $(( ${_v%m} * 1024 * 1024 )) ;;
    *g) echo $(( ${_v%g} * 1024 * 1024 * 1024 )) ;;
    *)  echo "$_v" ;;
  esac
}

vals=$(grep -rInE 'PB_MAX_BODY_SIZE:-[0-9]+[kmg]?|PB_MAX_BODY_SIZE=[0-9]+[kmg]?|client_max_body_size +[0-9]+[kmg]?|clientMaxBodySize:[[:space:]]*"?[0-9]+[kmg]?"?' \
  --include='*.yml' --include='*.yaml' --include='*.conf' --include='*.example' --include='*.env*' \
  . 2>/dev/null | grep -vE "$EXCLUDE" || true)

# ── 跨仓：charts 独立仓的反代上限（Helm 用户的默认部署路径）──────────────
# charts 仓不在 hub 仓的 checkout 里时**跳过并告警**（不硬失败）——
# 权威断言在 charts 仓自己的 CI（helm template 后断 CLIENT_MAX_BODY_SIZE）。
for charts_values in ../charts/charts/pigeonbox/values.yaml charts/charts/pigeonbox/values.yaml; do
  if [ -f "$charts_values" ]; then
    cross=$(grep -HnE 'clientMaxBodySize:[[:space:]]*"?[0-9]+[kmg]?"?' "$charts_values" 2>/dev/null || true)
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
  val=$(printf '%s' "$line" | grep -oE '[0-9]+[kmg]?' | tail -1)
  [ -z "$val" ] && continue
  echo "VAL $val" >> "$tmp"
  if [ "$(to_bytes "$val")" -lt "$MIN_BYTES" ]; then
    echo "LOW $file $val" >> "$tmp"
  fi
done

fail=0
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
