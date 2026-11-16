#!/usr/bin/env bash
#
# 共享：公开看板（PigeonBox Ecosystem）的分类/状态映射与仓列表。
#
# 存在原因（Refs pigeonbox/pigeonbox#366）：board-sync.sh 与 metrics.sh 都要把
# 「issue → 六分类/三状态」的判定放同一处——两份实现漂移过一次，看板与指标表
# 就会各说各话。本文件只放**纯函数与常量**，不发任何网络请求，可单独被
# 静态检查覆盖。
#
# 分类真相源：issue 标题前缀【分类·优先级】（hub 与各仓的既有惯例）+ label 兜底。
# 前缀优先于 label：大量 issue 只有前缀没有 label，而 label（bug/enhancement）
# 是全生态默认模板，区分度低于前缀。
#
# 用法：source scripts/board-lib.sh
#       pb_classify_category "【安全·中】xxx" "enhancement"
#       pb_classify_status   "【安全·中】xxx" "security"
#
# ⚠️ Bash 3.2 基线（macOS 自带 /bin/bash）：不用关联数组/${x,,} 等 bash4 特性。

# 参与看板同步的仓（AGENTS.md 生态表口径；kit 已归档、contracts 无 issue，
# 保留在列表里——拉到空集即跳过，新增仓时这里加一行即可）
# shellcheck disable=SC2034  # 本文件是被 source 的库，变量供引用方消费
PB_BOARD_REPOS="pigeonbox contracts core server frontend frontend-core fnos openwrt p2p kit synology qnap ugreen terramaster charts desktop"

# 六分类（看板 Category 字段的合法值，改这里必须同步 board-setup.sh 的字段选项）
# shellcheck disable=SC2034  # 被 source 消费
PB_BOARD_CATEGORIES="Security Correctness Reliability Platform Product Community"

# 三状态（看板 Triage 字段的合法值，同上；与 pigeonbox/.github 的 sync-board.py 同一口径）
# shellcheck disable=SC2034  # 被 source 消费
PB_BOARD_STATUSES="已验证缺陷 待确认问题 未来功能提案"

# 判定规则**有序**：先匹配先生效，改动顺序=改判定语义，须同步 docs/METRICS.md
# 的「映射口径」表。
#
# pb_classify_category <title> <labels逗号串> → stdout：六分类之一或 UNMAPPED
#
# 两阶段：先**全部前缀规则**，再词面/label 兜底——前缀是维护者显式声明的分类，
# 词面只是猜（实测 #382「【发布·高】…NAS」曾被词面 NAS 抢成 Platform）。
pb_classify_category() {
  local title="$1" labels="$2"

  # ── 阶段 A：标题前缀【分类（显式声明，最高优先）──
  case "$title" in
    【安全*)
      echo Security
      return 0
      ;;
    【平台* | 【K8s*)
      echo Platform
      return 0
      ;;
    【正确性* | 【架构*)
      echo Correctness
      return 0
      ;;
    【可靠* | 【发布* | 【测试* | 【门禁* | 【依赖*)
      echo Reliability
      return 0
      ;;
    【产品* | 【展望* | 【治理*)
      echo Product
      return 0
      ;;
    【生态*)
      echo Community
      return 0
      ;;
  esac

  # ── 阶段 B：label（security/bug 是坐实信号，先于词面）──
  case ",${labels}," in
    *,security,*)
      echo Security
      return 0
      ;;
    *,bug,*)
      echo Correctness
      return 0
      ;;
  esac

  # ── 阶段 C：词面兜底（无前缀的老 issue / [生态债] 类方括号标题）──
  #    「真机/分发/上架」归 Platform：hub#240 要回答「哪些平台真机过」；
  #    台账/文档归 Community。
  case "$title" in
    *真机* | *分发* | *上架* | *K8s* | *NAS*)
      echo Platform
      return 0
      ;;
    *CI* | *train-* | *SLO*)
      echo Reliability
      return 0
      ;;
    *需产品*)
      echo Product
      return 0
      ;;
    *台账* | *文档*)
      echo Community
      return 0
      ;;
  esac

  # ── 阶段 D：label 兜底（全生态默认模板 label，区分度最低）──
  case ",${labels}," in
    *,enhancement,*)
      echo Product
      return 0
      ;;
    *,documentation,*)
      echo Community
      return 0
      ;;
  esac

  echo UNMAPPED
}
# pb_classify_status <title> <labels逗号串> → stdout：三状态之一
#
# 口径（启发式，docs/METRICS.md 同源）：
#   · 已验证缺陷 = 带 bug/security label（本仓惯例：坐实的缺陷才打这两个）
#   · 未来功能提案 = enhancement label 或标题【展望（未来能力，未排期）
#   · 待确认问题 = 其余（只有标题前缀、尚无坐实/排定的单）
# 「已验证」与「待确认」的人工复核在看板上直接改 Status 字段，不回写 issue。
pb_classify_status() {
  local title="$1" labels="$2"

  case ",${labels}," in
    *,bug,* | *,security,*)
      echo 已验证缺陷
      return 0
      ;;
  esac
  case "$title" in
    【展望*)
      echo 未来功能提案
      return 0
      ;;
  esac
  case ",${labels}," in
    *,enhancement,*)
      echo 未来功能提案
      return 0
      ;;
  esac
  echo 待确认问题
}
