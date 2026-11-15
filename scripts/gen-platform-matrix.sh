#!/usr/bin/env bash
#
# 生成 Platform Compatibility Matrix（pigeonbox#365）。
#
# 真相源是 deploy/platforms/capabilities.yaml；本脚本只做**生成**，
# 生成物 docs/platform-compatibility-matrix.md 禁止手改（CI 对账由
# scripts/check-platform-capabilities.sh 把关：生成物 == 生成结果）。
#
# 用法：bash scripts/gen-platform-matrix.sh   # 覆盖写 docs/platform-compatibility-matrix.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ 没有 python3——无法生成矩阵"
  exit 1
fi

MATRIX="docs/platform-compatibility-matrix.md"
mkdir -p docs
python3 scripts/platform_capabilities.py matrix --root "$ROOT" >"$MATRIX"
echo "✓ 已生成 ${MATRIX}（$(wc -l <"${MATRIX}" | tr -d " ") 行）"
