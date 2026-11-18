#!/usr/bin/env bash
# 门禁：破坏性升级「可恢复/可回滚」断言统一收编入口（hub#364 强制测试③）。
#
# 为什么收编而不是各跑各的（2026-11-14 生态技术评审，issue #364）：
#   三端的升级失败语义（升级中断 / 备份失败≈空间不足 / 回滚点快照）此前
#   分散在 qnap/synology/fnos 各仓的测试里，**没有任何一处**能在 hub CI
#   一眼看到「破坏性升级可恢复」这条不变量还活着 ⇒ 某端断言被删/被绕过时
#   门禁静默失明。本脚本把三端既有断言**收编成一个统一测试入口**并挂进
#   hub CI：任一端套件失败、或关键升级断言从输出里消失 ⇒ 判红。
#
# 断言覆盖（按平台语义，全部来自各仓既有测试，本脚本不重复实现）：
#   · 升级中断   —— qnap：截断包在解包前被拦下（已装内容原封不动）
#   · 空间不足   —— qnap/synology：备份 cp 失败 ⇒ 中止安装/升级（不赌），
#                   中止路径不留下半份快照
#                   （真 ENOSPC 无法离线注入 ⇒ 以 cp 失败走同一中止分支代理）
#   · 回滚点     —— qnap/synology：preupgrade/pkg_pre_install 快照业务库、
#                   轮转保留 3 份、快照与源库逐字一致（迁移失败可回滚的物证）
#   · 换装可恢复 —— fnos：原地换装框架托管启停 + 网关/版本断言 + 自带 C7 负对照
#   · 迁移中途失败 —— hub#660（L7 升级层）：跑各平台**真实**升级钩子 + 注入
#                   「数据搬迁/快照写一半失败」⇒ 断言旧版本仍可启动、业务数据无损、
#                   失败可见、不留半份快照（scripts/check-upgrade-migration-failure.sh）
#
# 形态（与 check-nas-prewire-consistency.sh 同口径，三种都要判对）：
#   ① 判定形态：hub CI 把三端检出到同一 workspace ⇒ 逐套件跑 + 断言存在性核对
#   ② 跳过形态：三端全不在（本地单仓检出）⇒ 打印**明确的跳过原因**后放行
#   ③ 缺失形态：只有部分端在 ⇒ 判红（半截检出不是覆盖）
# ⚠️ 跳过形态也必须被 --selfcheck 覆盖（否则本地最常见形态从未被执行过）。
#
# 用法: bash scripts/check-upgrade-recoverability.sh [--selfcheck]
# ── shellkit（门禁侧统一管道；**设备侧脚本一律不引**，见设计稿 C1）────────────
# vendor/shellkit 是上游镜像（由 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**（C7）。
# ⚠️ **fail-closed**：缺库就退 5，不静默退回手写实现。
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

set -uo pipefail

# 本脚本自身所在目录（**必须在 cd "$ROOT" 之前**取绝对路径：
# $ROOT 可能是「平台仓根」，那里不一定有 hub 的 scripts/）。
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${UPGRADE_RECOVER_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
cd "$ROOT" || exit 1

SELFCHECK=0
for arg in "$@"; do
  case "$arg" in
    --selfcheck) SELFCHECK=1 ;;
    *)
      log_info "用法: $0 [--selfcheck]"
      exit 2
      ;;
  esac
done

fail=0

# require_any <端名> <日志> <断言组说明> <模式>... 任一模式命中即绿（-F 字面）。
# 用「任一」是因为 root 环境下权限位注入分支会显式跳过并打印跳过文案——
# 跳过是**按平台语义的合法执行**（假红比缺断言更糟），故跳过文案也算命中。
require_any() {
  local name=$1 log=$2 label=$3
  shift 3
  local args=() p
  for p in "$@"; do
    args+=(-e "$p")
  done
  if grep -qF "${args[@]}" "$log"; then
    log_ok "  ✓ ${name}：${label}"
  else
    log_error "  ✗ ${name}：缺升级可恢复断言「${label}」（任一命中即可：$*）"
    fail=1
  fi
}

# run_suite <端名> <测试脚本> <解释器>；失败置 fail 并返回 1。
run_suite() {
  local name=$1 script=$2 runner=$3
  log_info "── ${name}：${script}"
  if [ ! -f "$script" ]; then
    log_error "  ✗ 测试脚本缺失：$script"
    fail=1
    return 1
  fi
  local log rc=0
  log=$(mktemp)
  "$runner" "$script" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "  ✗ ${name} 套件失败（退出码 ${rc}），输出尾部："
    tail -n 25 "$log" | sed 's/^/    /'
    rm -f "$log"
    fail=1
    return 1
  fi
  echo "  ✓ $name 套件通过（$(grep -c '✓' "$log" 2>/dev/null || true) 条断言）"
  # 交给调用方做断言存在性核对；日志路径经全局变量带回。
  LAST_LOG="$log"
  return 0
}

selfcheck() {
  local sc rc=0
  sc=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf \"$sc\"" RETURN

  # 形态④ 的桩（selfcheck 内自洽 ⇒ 不依赖真实平台仓在位）：
  #   full    = 标记齐全（基线必须放行）
  #   partial = 只打印一半标记（负对照必须判红）
  cat >"$sc/migration-full.sh" <<'STUB'
#!/bin/sh
echo "  ✓ qnap：迁移中途失败⇒失败可见 + 数据无损 + 不留半份快照 + 旧版本仍可启动"
exit 0
STUB

  # 用例①：三端全缺 ⇒ 跳过形态必须放行（且打印明确跳过原因）。
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" bash "$0" >"$sc/out1" 2>&1; then
    if grep -q "跳过" "$sc/out1"; then
      log_ok "  ✓ 跳过形态：三端全缺 ⇒ 放行并打印跳过原因"
    else
      log_error "  ✗ 跳过形态：放行了但没打印跳过原因（没扫到 ≠ 扫过且通过）"
      rc=1
    fi
  else
    log_error "  ✗ 跳过形态：三端全缺却判红"
    rc=1
  fi

  # 用例②：只检出一端 ⇒ 半截检出必须判红。
  mkdir -p "$sc/qnap/tests"
  printf '#!/bin/sh\nexit 0\n' >"$sc/qnap/tests/run-tests.sh"
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" bash "$0" >"$sc/out2" 2>&1; then
    log_error "  ✗ 缺失形态：半截检出（1/3）却放行"
    rc=1
  else
    log_ok "  ✓ 缺失形态：半截检出 ⇒ 判红"
  fi
  rm -rf "$sc/qnap"

  # 用例③④⑤：三端齐全的桩工作区。
  mk_stubs() { # $1=行为：pass / fail / nomarker
    local mode=$1 d
    for d in qnap synology; do
      mkdir -p "$sc/$d/tests"
      if [ "$mode" = "fail" ] && [ "$d" = "synology" ]; then
        printf '#!/bin/sh\necho "✗ 桩：注入的升级测试失败"\nexit 1\n' >"$sc/$d/tests/run-tests.sh"
      elif [ "$mode" = "nomarker" ] && [ "$d" = "qnap" ]; then
        # 套件绿但**不打印任何升级断言** ⇒ 断言存在性核对必须判红。
        printf '#!/bin/sh\necho "PASS"\nexit 0\n' >"$sc/$d/tests/run-tests.sh"
      else
        cat >"$sc/$d/tests/run-tests.sh" <<'STUB'
#!/bin/sh
echo "  ✓ 截断包在解包前被拦下(安装中止)"
echo "  ✓ 第 4 份进来后仍只保留 3 份"
echo "  ✓ 快照与源库逐字一致"
echo "  ✓ 备份失败时中止升级(旧版本与数据不动)"
echo "  ✓ 备份失败时中止安装(旧安装与数据未被改动)"
exit 0
STUB
      fi
    done
    mkdir -p "$sc/fnos/scripts"
    if [ "$mode" = "nomarker" ]; then
      printf '#!/bin/sh\necho PASS\nexit 0\n' >"$sc/fnos/scripts/check-upgrade-inplace-framework-start.sh"
    else
      cat >"$sc/fnos/scripts/check-upgrade-inplace-framework-start.sh" <<'STUB'
#!/bin/sh
echo "  ✓ C7 变异体确实没了框架托管启停 ⇒ 门禁能抓住原缺陷"
echo "✓ fnos 原地换装「框架托管启停 + 网关/版本断言」守卫通过"
exit 0
STUB
    fi
  }

  # 用例③：三端全绿且断言齐 ⇒ 必须放行。
  mk_stubs pass
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" bash "$0" >"$sc/out3" 2>&1; then
    log_ok "  ✓ 判定形态：三端全绿 + 断言齐 ⇒ 放行"
  else
    log_error "  ✗ 判定形态：三端全绿却判红"
    sed 's/^/    /' "$sc/out3"
    rc=1
  fi

  # 用例④：任一端套件失败 ⇒ 必须判红（失败必中止/必有日志的收编语义）。
  mk_stubs fail
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" bash "$0" >"$sc/out4" 2>&1; then
    log_error "  ✗ 套件失败形态：某端测试红却放行"
    rc=1
  else
    log_ok "  ✓ 套件失败形态：某端测试红 ⇒ 判红"
  fi

  # 用例⑤：套件绿但关键升级断言消失 ⇒ 必须判红（断言被删不许静默）。
  mk_stubs nomarker
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" bash "$0" >"$sc/out5" 2>&1; then
    log_error "  ✗ 断言缺失形态：升级断言从输出消失却放行"
    rc=1
  else
    log_ok "  ✓ 断言缺失形态：升级断言消失 ⇒ 判红"
  fi

  # 用例⑥：形态④（迁移中途失败）断言不全 ⇒ 必须判红。
  # 用 UPGRADE_MIGRATION_CHECKER 指向一个「只打印部分标记」的桩脚本 ⇒
  # 证明本门禁对形态④ 的断言**有牙齿**（否则形态④ 会被静默放过）。
  cat >"$sc/migration-partial.sh" <<'STUB'
#!/bin/sh
# 自检夹具：只打印「迁移中途失败 + 数据无损」，缺「失败可见/不留半份快照/旧版本仍可启动」
echo "  ✓ qnap：迁移中途失败⇒数据无损"
exit 0
STUB
  chmod +x "$sc/migration-partial.sh" "$sc/migration-full.sh"
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-partial.sh" \
    bash "$0" >"$sc/out6" 2>&1; then
    log_error "  ✗ 迁移失败形态：断言不全却放行"
    rc=1
  else
    log_ok "  ✓ 迁移失败形态：断言不全 ⇒ 判红"
  fi

  # 用例⑦：形态④ 桩打印**全部**标记 ⇒ 必须放行（证明⑥的红不是因为别的）
  # 先把三端桩恢复成「全绿 + 断言齐」形态（⑤ 留下的桩是无标记形态）
  mk_stubs pass
  cat >"$sc/migration-full.sh" <<'STUB'
#!/bin/sh
echo "  ✓ qnap：迁移中途失败⇒失败可见 + 数据无损 + 不留半份快照 + 旧版本仍可启动"
exit 0
STUB
  if UPGRADE_RECOVER_ROOT="$sc" UPGRADE_MIGRATION_CHECKER="$sc/migration-full.sh" \
    bash "$0" >"$sc/out7" 2>&1; then
    log_ok "  ✓ 迁移失败形态：标记齐全 ⇒ 放行"
  else
    log_error "  ✗ 迁移失败形态：标记齐全却判红 ⇒ ⑥ 的红另有原因，门禁不可信"
    sed 's/^/    /' "$sc/out7"
    rc=1
  fi

  return "$rc"
}

if [ "$SELFCHECK" -eq 1 ]; then
  log_info "── 自证：七形态（跳过/半截/全绿/套件红/断言缺失/迁移失败断言不全/迁移失败标记齐全）"
  if selfcheck; then
    log_ok "✓ 本门禁自证通过（改坏任一形态都会判红；含形态④ 迁移中途失败）"
    exit 0
  fi
  log_error "✗ 本门禁自证失败"
  exit 1
fi

# ── 形态判定：三端检出情况 ──────────────────────────────────────────────
present=0
for f in qnap/tests/run-tests.sh synology/tests/run-tests.sh \
  fnos/scripts/check-upgrade-inplace-framework-start.sh; do
  if [ -f "$f" ]; then
    present=$((present + 1))
  fi
done

if [ "$present" -eq 0 ]; then
  log_info "三端平台仓均未检出到 workspace（本地单仓形态）⇒ 跳过本门禁。"
  log_info "hub CI 会把 qnap/synology/fnos 检出到同级目录后强制执行本脚本。"
  exit 0
fi
if [ "$present" -ne 3 ]; then
  log_error "✗ 平台仓检出不完整（$present/3）——半截检出不是覆盖："
  for f in qnap/tests/run-tests.sh synology/tests/run-tests.sh \
    fnos/scripts/check-upgrade-inplace-framework-start.sh; do
    [ -f "$f" ] || echo "    缺失：$f"
  done
  exit 1
fi

# ── 判定形态：逐套件跑 + 关键断言存在性核对 ────────────────────────────
LAST_LOG=""
if run_suite "qnap" "qnap/tests/run-tests.sh" sh; then
  require_any "qnap" "$LAST_LOG" "升级中断⇒截断包解包前中止（已装内容不动）" \
    "截断包在解包前被拦下"
  require_any "qnap" "$LAST_LOG" "回滚点⇒快照轮转保留 3 份" \
    "第 4 份进来后仍只保留 3 份"
  require_any "qnap" "$LAST_LOG" "空间不足/备份失败⇒中止安装" \
    "备份失败时中止安装" "root 环境无法用权限位注入 cp 失败"
  rm -f "$LAST_LOG"
fi

LAST_LOG=""
if run_suite "synology" "synology/tests/run-tests.sh" sh; then
  require_any "synology" "$LAST_LOG" "回滚点⇒快照与源库逐字一致" \
    "快照与源库逐字一致"
  require_any "synology" "$LAST_LOG" "回滚点⇒快照轮转保留 3 份" \
    "第 4 份进来后仍只保留 3 份"
  require_any "synology" "$LAST_LOG" "空间不足/备份失败⇒中止升级（不留下半份快照）" \
    "备份失败时中止升级" "root 环境无法用权限位注入 cp 失败"
  rm -f "$LAST_LOG"
fi

LAST_LOG=""
if run_suite "fnos" "fnos/scripts/check-upgrade-inplace-framework-start.sh" bash; then
  require_any "fnos" "$LAST_LOG" "换装失败⇒网关/版本断言有牙齿（非 0 退出）" \
    "守卫通过"
  require_any "fnos" "$LAST_LOG" "自带负对照（C7 变异必须被抓）" \
    "C7 变异体确实没了框架托管启停"
  rm -f "$LAST_LOG"
fi

# ── 形态④：迁移中途失败（数据搬迁/快照写一半失败） ─────────────────────
# 升级矩阵里最危险的一格不是「升级成功」，而是「升级**中途**失败」：旧版本必须
# 仍可启动、业务数据必须无损、失败必须可见、且**不留半份快照**（半份快照比没
# 快照更坏——它看着像回滚点，实际残缺，真回滚会把用户数据搞坏）。
# 实现见 scripts/check-upgrade-migration-failure.sh：跑各平台**真实**升级钩子 +
# 注入 cp 失败 ⇒ 逐端机械判定（不做标记约定，做真执行）。
# 平台仓不在位 ⇒ 子脚本自报「跳过形态」⇒ 本形态登记在案（没扫到 ≠ 扫过且通过）。
# 形态④ 的实现脚本按**自身所在目录**定位（不按 ${ROOT}）——
# $ROOT 可能是「平台仓根」（本门禁的 UPGRADE_RECOVER_ROOT 语义），
# 那里不一定有 hub 的 scripts/ ⇒ 按 $ROOT 找会误报「测试脚本缺失」。
MIGRATION_CHECKER="${UPGRADE_MIGRATION_CHECKER:-$SELF_DIR/check-upgrade-migration-failure.sh}"
LAST_LOG=""
if run_suite "迁移失败注入" "$MIGRATION_CHECKER" bash; then
  if grep -q "跳过形态" "$LAST_LOG"; then
    log_info "  ⏳ 迁移失败注入：本形态未覆盖（登记在案；没扫到 ≠ 扫过且通过）"
  else
    require_any "迁移失败注入" "$LAST_LOG" "迁移中途失败⇒旧版本仍可启动且数据无损" \
      "迁移中途失败"
    require_any "迁移失败注入" "$LAST_LOG" "失败可见" "失败可见"
    require_any "迁移失败注入" "$LAST_LOG" "不留半份快照" "不留半份快照"
    require_any "迁移失败注入" "$LAST_LOG" "旧版本仍可启动" "旧版本仍可启动"
  fi
  rm -f "$LAST_LOG"
fi

if [ "$fail" -ne 0 ]; then
  log_error "✗ 破坏性升级可恢复统一入口：有端失败或断言缺失"
  exit 1
fi
log_ok "✓ 三端破坏性升级可恢复断言全部通过（统一入口）"
