#!/usr/bin/env bash
# check-toolchain-pins.sh — 生态前端**类型检查工具链**跨仓对账门禁（2026-10-30 实录新增）
#
# 背景（2026-10-30 4.4.0 列车终验红，实录）：
#   frontend-core 以 **源码 tgz** 形式被三个平台仓消费（fnos/openwrt/qnap 的
#   `web/` 把 node_modules/@pigeonbox/frontend-core/src/** 一起纳入自己的
#   vue-tsc 类型检查）。⇒ **库的类型检查结论 = 消费方的类型检查结论**，
#   库自己的 CI 绿并不代表消费方绿。
#   本轮 fnos 重解析 web 锁文件后拿到 vue-tsc **3.3.14**，而 3.3.14 对
#   `<script setup>` 中 `reactive()` 绑定的 v-model 嵌套成员**误生成 `.value`
#   访问** ⇒ TS2339「Property 'value' does not exist on type '{...}'」×20
#   ⇒ fnos / openwrt / qnap 三个 `web/` 的 typecheck 全红 ⇒ 列车终验被挡。
#   实测逐版本扫（同一份 v0.11.40 源码 + 同一份 tsconfig）：
#     3.3.14 → 20 条；3.3.13 / 3.3.12 / 3.3.11 / 3.2.9 → 0 条
#   ⇒ 回归只存在于 3.3.14，而**让锁文件漂到回归版的正是 `"vue-tsc": "^3.1.5"`
#   这种开放区间**（^3.1.5 允许 3.3.14）。
#
#   ⇒ 两条机械规则（本门禁）：
#     ① 四个仓（frontend-core / fnos / openwrt / qnap）声明的 vue-tsc 版本
#        **必须逐字相同** —— 库与消费方用不同版本 ⇒ 库的绿不能代表消费方的绿；
#     ② 该版本必须是**精确版本**（无 ^ / ~ / >= 等区间）—— 区间 = 锁文件随时
#        可能漂进上游回归版，且漂移**只在消费方显红**（库自己的锁通常没动）。
#
# 顺带对账 typescript 的声明（四仓必须一致；允许 ~ 这种 patch 级区间）——
# TS 版本差异会改变同名错误的报法与判定面。
#
# 自检: `--selfcheck` 用**临时目录**注入三类故障（版本不一致 / 版本写成区间 /
#       typescript 不一致）⇒ 本门禁必须逐条变红。不污染真实仓。
set -euo pipefail

ROOT="${TOOLCHAIN_GATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# 四个仓的 package.json 相对 hub 根的位置（CI 与本地同布局：兄弟仓检出到 hub 根下）
REPOS=(
  "frontend-core:frontend-core/package.json"
  "fnos:fnos/web/package.json"
  "openwrt:openwrt/web/package.json"
  "qnap:qnap/web/package.json"
)

# fail 只打印并**返回**非零（不 exit）⇒ 自检里能用 `if check_all ...` 捕获；
# 主路径用 `check_all ... || exit 1` 终止。
fail() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; return 1; }

# 取 package.json 里的 devDependencies.<field>
dev_dep() { # $1=package.json 路径  $2=字段名
  python3 - "$1" "$2" <<'PY'
import json, sys
path, field = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception as e:
    print(f"读取失败:{e}", file=sys.stderr)
    sys.exit(2)
print(data.get("devDependencies", {}).get(field, ""))
PY
}

# ── 主检查 ───────────────────────────────────────────────────────────────────
check_all() { # $1=根目录（其下有 frontend-core/package.json 等）
  local root="$1"
  local vue_ver="" vue_repo="" ts_ver="" ts_repo=""
  local f

  for f in "${REPOS[@]}"; do
    local repo="${f%%:*}"
    local rel="${f#*:}"
    local pkg="$root/$rel"
    [ -f "$pkg" ] || { fail "找不到 ${repo} 的 package.json（${pkg}）⇒ 检出布局不对" || return 1; }

    local v t
    v="$(dev_dep "$pkg" vue-tsc)" || { fail "${repo}: 读取 vue-tsc 失败" || return 1; }
    t="$(dev_dep "$pkg" typescript)" || { fail "${repo}: 读取 typescript 失败" || return 1; }

    [ -n "$v" ] || { fail "${repo}: devDependencies.vue-tsc 缺失" || return 1; }
    [ -n "$t" ] || { fail "${repo}: devDependencies.typescript 缺失" || return 1; }

    # ② 精确版本：区间会让锁文件漂进上游回归版
    printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
      || { fail "${repo}: vue-tsc 声明为 '${v}' ⇒ 必须是**精确版本**（如 3.3.13）；区间会让锁文件漂进上游回归版" || return 1; }

    if [ -z "$vue_ver" ]; then
      vue_ver="$v"; vue_repo="$repo"
    elif [ "$v" != "$vue_ver" ]; then
      fail "vue-tsc 版本不一致：${vue_repo}=${vue_ver} 而 ${repo}=${v} ⇒ 库与消费方类型检查结论不可互推（须全生态同版本）" || return 1
    fi

    if [ -z "$ts_ver" ]; then
      ts_ver="$t"; ts_repo="$repo"
    elif [ "$t" != "$ts_ver" ]; then
      fail "typescript 版本不一致：${ts_repo}=${ts_ver} 而 ${repo}=${t}" || return 1
    fi
  done

  echo "✓ 四个仓 vue-tsc 同版本且为精确版本：$vue_ver"
  echo "✓ 四个仓 typescript 声明一致：$ts_ver"
  return 0
}

# ── 自检：注入三类故障，必须逐条变红 ─────────────────────────────────────────
selfcheck() {
  # 用全局变量：trap 在 shell 退出时执行，届时 local 已出作用域（set -u 会报未绑定）
  TMP_FIXTURE="$(mktemp -d)"
  OK=0
  # shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
  trap 'rc=$?; rm -rf "${TMP_FIXTURE:-}"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT
  local tmp="$TMP_FIXTURE"

  make_fixture() { # $1=目录名  $2=vue-tsc  $3=typescript
    local d="$tmp/$1"
    mkdir -p "$d/frontend-core" "$d/fnos/web" "$d/openwrt/web" "$d/qnap/web"
    local r
    for r in frontend-core fnos openwrt qnap; do
      local rel="package.json"
      [ "$r" = "frontend-core" ] || rel="web/package.json"
      cat > "$d/$r/$rel" <<EOF
{ "name": "fixture", "devDependencies": { "vue-tsc": "$2", "typescript": "$3" } }
EOF
    done
  }

  patch() { # $1=package.json  $2=字段  $3=新值
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, field, value = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p)); d["devDependencies"][field] = value
json.dump(d, open(p, "w"), indent=2)
PY
  }

  # 基线：一致 ⇒ 必须绿
  make_fixture ok 3.3.13 "~5.9.3"
  check_all "$tmp/ok" >/dev/null || { fail "自检：一致的基线 fixture 竟然判红"; exit 1; }

  # 故障①：版本不一致 ⇒ 必须红
  make_fixture mismatch 3.3.13 "~5.9.3"
  patch "$tmp/mismatch/qnap/web/package.json" vue-tsc 3.3.14
  if check_all "$tmp/mismatch" >/dev/null 2>&1; then
    fail "自检：vue-tsc 版本不一致竟判绿"; exit 1
  fi

  # 故障②：写成区间 ⇒ 必须红
  make_fixture ranged 3.3.13 "~5.9.3"
  patch "$tmp/ranged/openwrt/web/package.json" vue-tsc "^3.3.13"
  if check_all "$tmp/ranged" >/dev/null 2>&1; then
    fail "自检：vue-tsc 写成区间竟判绿"; exit 1
  fi

  # 故障③：typescript 不一致 ⇒ 必须红
  make_fixture tsdrift 3.3.13 "~5.9.3"
  patch "$tmp/tsdrift/fnos/web/package.json" typescript "~5.9.2"
  if check_all "$tmp/tsdrift" >/dev/null 2>&1; then
    fail "自检：typescript 不一致竟判绿"; exit 1
  fi

  echo "✓ 自检通过：三类故障逐条判红，一致基线判绿"
}

case "${1:-}" in
  --selfcheck) selfcheck ;;
  "") check_all "$ROOT" || exit 1 ;;
  *) echo "用法: $0 [--selfcheck]" >&2; exit 2 ;;
esac
OK=1
