#!/usr/bin/env bash
# check-agents-md.sh —— AGENTS.md 薄索引守卫(2026-11-13 规则重构,spec G6)。
#
# 四判据:①尺寸 ≤24KB ②层1 指针目标存在 ③无 >120 字重复长行 ④bump 版本矩阵
# 15 个行首格锚点在(契约见 spec §6;trainctl bump 按行首格定位、改末格)。
#
# ⚠️ 重构完成前跑本脚本会红(旧文件 207KB > 24KB)——属预期,不是脚本坏。
# 用法: bash scripts/check-agents-md.sh   (在 hub 仓根;读 ../AGENTS.md)
set -euo pipefail

AGENTS="../AGENTS.md"
[ -f "$AGENTS" ] || { echo "✗ 找不到 $AGENTS"; exit 1; }
rc=0

# ① 尺寸 ≤24KB(24576 字节)
size=$(wc -c < "$AGENTS")
if [ "$size" -gt 24576 ]; then
  echo "✗ ① 尺寸 $size B > 24576 B —— AGENTS.md 必须是薄索引(实录进 docs/topics/)"
  rc=1
else
  echo "✓ ① 尺寸 $size B"
fi

# ② 层1 指针目标存在:提取 ](路径) 形式指针(PigeonBox/... 与 docs/...)
missing=0
while IFS= read -r target; do
  [ -z "$target" ] && continue
  case "$target" in http*) continue;; esac
  if [ ! -e "$target" ] && [ ! -e "../$target" ]; then
    echo "✗ ② 断指针: $target"
    missing=1
    rc=1
  fi
done < <(grep -oE '\]\((PigeonBox/[^)]+|docs/[^)]+)\)' "$AGENTS" | sed 's/](\(.*\))/\1/' | sort -u)
[ "$missing" -eq 0 ] && echo "✓ ② 指针目标全存在"

# ③ 重复长行(>120 字)出现 ≥2 次 = 语义重复回归
dups=$(awk 'length($0)>120' "$AGENTS" | sort | uniq -d | wc -l | tr -d ' ')
if [ "$dups" -gt 0 ]; then
  echo "✗ ③ $dups 条 >120 字长行重复 —— 收敛为一"
  awk 'length($0)>120' "$AGENTS" | sort | uniq -d | head -3
  rc=1
else
  echo "✓ ③ 无重复长行"
fi

# ④ bump 锚点 15 个行首格(spec §6:12 字面键 + platforms 3)
# ⚠️ 与 bump 的 SetTableLastCell 同语义:**行首格内包含**键即命中(实录:desktop 行
# 首格是 `desktop/`(项目根),精确匹配会误报缺行——bump 生产上按包含匹配正常更新)。
# shellcheck disable=SC2016  # 反引号是表内 Markdown 字面量,不是命令替换——用双引号展开反而错
anchors=( '`PigeonBox/`' '`PigeonBox/contracts/`' '`PigeonBox/core/`' '`PigeonBox/frontend-core/`' '`PigeonBox/server/`' '`PigeonBox/frontend/`' '`PigeonBox/fnos/`' '`PigeonBox/openwrt/`' '`PigeonBox/qnap/`' '`PigeonBox/p2p/`' '`desktop/`' '`charts/`' '`PigeonBox/synology/`' '`PigeonBox/ugreen/`' '`PigeonBox/terramaster/`' )
miss=0
for a in "${anchors[@]}"; do
  # 行首格 = 行首个 "|" 与第二个 "|" 之间;锚点含反引号,按字面 grep -F 判包含
  firstcell=$(printf '%s\n' "$(grep -m1 -F "$a" "$AGENTS" 2>/dev/null || true)" | awk -F'|' '{print $2}')
  case "$firstcell" in
    *"$a"*) ;;
    *) echo "✗ ④ 缺锚点行(或行首格不含键): $a"; miss=1; rc=1 ;;
  esac
done
[ "$miss" -eq 0 ] && echo "✓ ④ 15 个 bump 锚点全在(行首格包含匹配,同 bump 语义)"

exit $rc
