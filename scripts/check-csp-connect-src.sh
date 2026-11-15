#!/usr/bin/env bash
#
# 门禁：CSP connect-src 必须可配置、且不得被通配放宽（frontend#169）。
#
# 为什么有这道门禁：
#   预签名直传让**浏览器**把文件 PUT 到对象存储域名（S3/MinIO/OSS…）。CSP 的
#   connect-src 若写死 'self'，浏览器会把它拦成 CSP violation —— 而 curl 冒烟、
#   服务端日志、单测全都看不见（CSP 只由浏览器执行）⇒ 表现成「偶发的直传失败」，
#   排查成本极高。反过来，为了修它随手写 `connect-src *` 又等于取消这道防线。
#   ⇒ 用机械门禁把两头都钉住：默认值不许是通配；部署侧必须能把存储域注入进去。
#
# 扫的形态（hub 侧权威断言；镜像模板的权威断言在 frontend 仓自己的 CI）：
#   ① compose 透传：       - CSP_CONNECT_SRC=${PB_CSP_CONNECT_SRC:-'self'}
#   ② env 样例：           PB_CSP_CONNECT_SRC=…
#   ③ 环境变量文档：        PB_CSP_CONNECT_SRC 行
#   ④ 通配禁令：           任何部署模板不得出现 connect-src *
#   ⑤ 静态反代模板：       deploy/nginx/nginx.conf 仍有 CSP 且写明预签名注入口
#   ⑥ 跨仓（存在才扫）：   frontend/docker/nginx.conf.template 三处都必须注入
#
# 兼容：POSIX 基础工具 + bash 3.2（macOS 自带）可跑；shfmt -i 2 -ci。
set -uo pipefail

ROOT="${CSP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

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

fails=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*"
  fails=$((fails + 1))
}

# scan_root <root>：跑全部断言，累计 fails
scan_root() {
  root="$1"
  printf '── CSP connect-src 门禁（root=%s）\n' "$root"

  # ① compose 透传（根 compose + NAS compose 两处，缺一处就有一个部署面恒 'self'）
  for f in docker-compose.yml deploy/nas/compose.yml; do
    p="$root/$f"
    if [ ! -f "$p" ]; then
      fail "缺 $f"
      continue
    fi
    # 只看非注释行的赋值；模式串用单引号钉死，避免 bash 先展开 ${...}（set -u 下会炸）
    line=$(grep 'CSP_CONNECT_SRC=' "$p" | grep -v '^[[:space:]]*#' | head -1)
    # shellcheck disable=SC2016  # 要的是**字面** ${...}，展开后就匹配不到了
    if [ -n "$line" ] && printf '%s' "$line" | grep -qF '${PB_CSP_CONNECT_SRC:-'; then
      pass "$f 透传 PB_CSP_CONNECT_SRC"
    else
      fail "$f 缺 CSP_CONNECT_SRC 透传（应为 PB_CSP_CONNECT_SRC 带默认 'self'）——变量进不了容器，预签名直传必被 CSP 拦"
    fi
  done

  # ② env 样例
  for f in .env.example deploy/nas/env.example; do
    p="$root/$f"
    if [ ! -f "$p" ]; then
      fail "缺 $f"
      continue
    fi
    if grep -qF 'PB_CSP_CONNECT_SRC' "$p"; then
      pass "$f 有 PB_CSP_CONNECT_SRC 样例"
    else
      fail "$f 缺 PB_CSP_CONNECT_SRC 样例（部署者不知道要配，直传静默失败）"
    fi
  done

  # ③ 环境变量文档
  if grep -qF 'PB_CSP_CONNECT_SRC' "$root/docs/ENVIRONMENT_VARIABLES.md" 2>/dev/null; then
    pass "ENVIRONMENT_VARIABLES.md 记录了 PB_CSP_CONNECT_SRC"
  else
    fail "docs/ENVIRONMENT_VARIABLES.md 缺 PB_CSP_CONNECT_SRC 说明"
  fi

  # ④ 通配禁令：任何部署模板都不许把 connect-src 放宽成 *
  hits=$(grep -rnE 'connect-src[^;"]*[*]' \
    "$root/deploy" "$root/docker-compose.yml" "$root/.env.example" 2>/dev/null)
  if [ -n "$hits" ]; then
    fail "connect-src 出现通配 *（等于取消该防线）："
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    pass "部署模板无 connect-src 通配"
  fi

  # ⑤ 静态反代模板：CSP 仍在，且写明预签名注入口（这文件不走 envsubst，只能人工改）
  nginx="$root/deploy/nginx/nginx.conf"
  if [ ! -f "$nginx" ]; then
    fail "缺 deploy/nginx/nginx.conf"
  else
    n=$(grep -c 'Content-Security-Policy' "$nginx")
    if [ "${n:-0}" -ge 3 ]; then
      pass "deploy/nginx/nginx.conf 的 CSP 声明 ${n} 处"
    else
      fail "deploy/nginx/nginx.conf 的 CSP 声明只有 ${n:-0} 处（add_header 不继承，应 ≥3）"
    fi
    if grep -qF 'check-csp-connect-src.sh' "$nginx"; then
      pass "deploy/nginx/nginx.conf 写明了预签名 CSP 注入口"
    else
      fail "deploy/nginx/nginx.conf 缺预签名 connect-src 说明（部署者改不到点子上）"
    fi
  fi

  # ⑥ 跨仓：frontend 仓在场才扫（hub CI 不 checkout 模块仓 ⇒ 不存在则跳过并告警）
  tpl="$root/frontend/docker/nginx.conf.template"
  if [ ! -f "$tpl" ]; then
    printf '  · frontend 仓不在场，跳过镜像模板断言（权威断言在 frontend 仓 CI）\n'
  else
    n=$(grep -c 'Content-Security-Policy' "$tpl")
    # shellcheck disable=SC2016  # 同上：模板里的 ${...} 就是要匹配的字面量
    inj=$(grep -cF 'connect-src ${CSP_CONNECT_SRC};' "$tpl")
    if [ "${n:-0}" -ge 3 ] && [ "${inj:-0}" -eq "${n:-0}" ]; then
      pass "frontend 镜像模板 ${inj}/${n} 处 CSP 走 CSP_CONNECT_SRC 注入"
    else
      fail "frontend 镜像模板只有 ${inj:-0}/${n:-0} 处 CSP 走注入（写死 'self' 会拦预签名直传）"
    fi
    if grep -qF "connect-src 'self';" "$tpl"; then
      fail "frontend 镜像模板仍残留写死的 connect-src 'self'"
    fi
  fi
}

# run_quiet <root>：静默跑断言，用返回码表示结果（selfcheck 用）
run_quiet() {
  fails=0
  scan_root "$1" >/dev/null 2>&1
  [ "$fails" -eq 0 ]
}

if [ "$SELFCHECK" -eq 1 ]; then
  echo "── 自证：基线必绿，三类变异必红"
  base=$(mktemp -d)
  mkdir -p "$base/deploy/nas" "$base/deploy/nginx" "$base/docs" "$base/frontend/docker"
  cp "$ROOT/docker-compose.yml" "$base/" 2>/dev/null
  cp "$ROOT/.env.example" "$base/" 2>/dev/null
  cp "$ROOT/deploy/nas/compose.yml" "$ROOT/deploy/nas/env.example" "$base/deploy/nas/" 2>/dev/null
  cp "$ROOT/deploy/nginx/nginx.conf" "$base/deploy/nginx/" 2>/dev/null
  cp "$ROOT/docs/ENVIRONMENT_VARIABLES.md" "$base/docs/" 2>/dev/null
  cp "$ROOT/frontend/docker/nginx.conf.template" "$base/frontend/docker/" 2>/dev/null

  if run_quiet "$base"; then
    echo "  ✓ 基线绿"
  else
    echo "  ✗ 基线应绿（门禁自身与当前模板不一致）"
    exit 1
  fi

  # 变异 1：compose 去掉透传
  cp "$base/docker-compose.yml" "$base/dc.bak"
  grep -v 'CSP_CONNECT_SRC' "$base/dc.bak" >"$base/docker-compose.yml"
  if run_quiet "$base"; then
    echo "  ✗ 变异「compose 去掉透传」未转红"
    exit 1
  fi
  echo "  ✓ 变异「compose 去掉透传」转红"
  cp "$base/dc.bak" "$base/docker-compose.yml"

  # 变异 2：通配放开
  printf 'add_header Content-Security-Policy "connect-src *;" always;\n' >>"$base/deploy/nginx/nginx.conf"
  if run_quiet "$base"; then
    echo "  ✗ 变异「connect-src *」未转红"
    exit 1
  fi
  echo "  ✓ 变异「connect-src *」转红"
  cp "$ROOT/deploy/nginx/nginx.conf" "$base/deploy/nginx/nginx.conf"

  # 变异 3：镜像模板写死 'self'（仅当 frontend 仓在场）
  if [ -f "$base/frontend/docker/nginx.conf.template" ]; then
    sed "s/connect-src \${CSP_CONNECT_SRC};/connect-src 'self';/g" \
      "$ROOT/frontend/docker/nginx.conf.template" >"$base/frontend/docker/nginx.conf.template"
    if run_quiet "$base"; then
      echo "  ✗ 变异「模板写死 'self'」未转红"
      exit 1
    fi
    echo "  ✓ 变异「模板写死 'self'」转红"
  fi

  rm -rf "$base"
  echo "✓ 自证通过"
  exit 0
fi

scan_root "$ROOT"
if [ "$fails" -ne 0 ]; then
  echo "✗ CSP connect-src 门禁：$fails 处不符"
  exit 1
fi
echo "✓ CSP connect-src 门禁通过"
