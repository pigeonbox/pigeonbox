#!/usr/bin/env bash
#
# 逐个执行 tests/test_*.sh。
#   - 每个测试都从 /dev/null 取 stdin：测试不得依赖调用者的终端输入，
#     否则在 CI 或管道里会因为等待 stdin 而挂死。
#   - 有 timeout(1) 时给每个文件上限，卡死就报错而不是无限等待。
#
# 选项：
#   --format plain|tap|junit   输出格式，默认 plain（与旧版逐字一致）
#   --jobs N                   并行执行 N 个测试文件，默认 1（串行）
#   --filter PATTERN           只跑文件名匹配 PATTERN 的文件（shell 通配符）
#   --list                     只列出将要执行的测试文件，不执行
#   -h, --help                 显示帮助
#
# 用例粒度：测试文件里可以用 `# CASE: 标题` 注释切分用例，runner 把每个
# CASE 当成一条用例单独记账（失败时重跑一次带 xtrace 定位到具体用例）。
# 没有 CASE 注释的文件退化成「文件级一条用例」，失败原因取断言打印的
# FAIL: 行。两种粒度都不会出现「有失败但报告说全过」。
#
# 并行隔离：--jobs N 时每个测试文件拿到自己的 TEST_TMP_ROOT（不再共用），
# 串行时仍共用同一个 TEST_TMP_ROOT（与旧版一致）。汇总输出按文件名字母序，
# 与完成顺序无关，结果可复现。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shellkit-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export TEST_TMP_ROOT="$TMP"

WORK="$TMP/work"
mkdir -p "$WORK"

# 每文件上限：120 秒太贴着天花板了 —— test_ai_docs.sh 本机就要 ~60 秒，
# 机器一忙就撞线，于是「负载高」被误读成「测试坏了」。抬到 300 秒。
#
# 个别用例天然就慢（变异测试的 campaign 要把守卫套件按计分位点数跑那么多遍），
# 允许它在文件头里写一行「# TEST_TIMEOUT: 900」单独放宽 ——
# 只放宽那一个文件，不拖累其他文件的卡死检测。
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
else
  TIMEOUT_BIN=""
fi

FORMAT=plain
JOBS=1
FILTER=""
LIST_ONLY=0

usage() {
  cat <<'EOF'
usage: tests/run.sh [options]

  --format FORMAT   输出格式：plain（默认）/ tap / junit
  --jobs N          并行执行 N 个测试文件（默认 1，即串行）
  --filter PATTERN  只执行文件名匹配 PATTERN 的测试文件（shell 通配符）
  --list            只列出将要执行的测试文件，不执行
  -h, --help        显示这段帮助
EOF
}

# _file_timeout FILE —— 这个文件自己的时间上限（秒）
#
# 默认用全局的 TEST_TIMEOUT。文件头里写了「# TEST_TIMEOUT: 900」就用它自己的 ——
# 变异测试那种天然就慢的用例可以单独放宽，不必把全局上限一起抬高
# （全局抬高会让所有文件的卡死检测都变慢）。
_file_timeout() {
  local __f=${1:-} __line
  [ -f "$__f" ] || {
    printf '%s' "$TEST_TIMEOUT"
    return 0
  }
  # 取「# TEST_TIMEOUT: 900」里的数字；行尾允许有解释文字。
  __line=$(awk '/^# TEST_TIMEOUT: *[0-9]/ {
      sub(/^# TEST_TIMEOUT: */, "")
      sub(/[^0-9].*$/, "")
      print
      exit
    }' "$__f" 2>/dev/null || true)
  case "$__line" in
    '' | *[!0-9]*) printf '%s' "$TEST_TIMEOUT" ;;
    *) printf '%s' "$__line" ;;
  esac
}

die_usage() {
  printf '%s
' "$*" >&2
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --format)
      [ $# -ge 2 ] || die_usage "--format 需要一个参数"
      FORMAT=$2
      shift 2
      ;;
    --format=*)
      FORMAT=${1#*=}
      shift
      ;;
    --jobs)
      [ $# -ge 2 ] || die_usage "--jobs 需要一个参数"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --filter)
      [ $# -ge 2 ] || die_usage "--filter 需要一个参数"
      FILTER=$2
      shift 2
      ;;
    --filter=*)
      FILTER=${1#*=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die_usage "未知选项：$1"
      ;;
  esac
done

case "$FORMAT" in
  plain | tap | junit) ;;
  *) die_usage "--format 只接受 plain / tap / junit" ;;
esac

case "$JOBS" in
  '' | *[!0-9]*) die_usage "--jobs 需要一个正整数" ;;
esac
[ "$JOBS" -ge 1 ] || die_usage "--jobs 需要一个正整数"

# --------------------------------------------------------------------------
# 文件清单：glob 顺序已是字母序，再用 C 序排一次保证跨 locale 可复现。
# --------------------------------------------------------------------------

_list_candidates() {
  local f base
  for f in "$ROOT"/tests/test_*.sh; do
    [ -f "$f" ] || continue
    base=${f##*/}
    case "$base" in
      *test_helper.sh) continue ;;
    esac
    if [ -n "$FILTER" ]; then
      # 变量不加引号才是 shell 通配符模式（加引号会变成字面量匹配）
      # shellcheck disable=SC2254
      case "$base" in
        $FILTER) ;;
        *) continue ;;
      esac
    fi
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

TEST_FILES=()
_list_candidates >"$TMP/files.list"
while IFS= read -r __line; do
  [ -n "$__line" ] || continue
  TEST_FILES+=("$__line")
done <"$TMP/files.list"

# 过滤器一个都没匹配上时必须报错。
# 「All 0 test files passed.」是假绿：用户以为自己跑了一组测试，其实什么都没跑。
if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  if [ -n "$FILTER" ]; then
    printf '没有测试文件匹配过滤器：%s\n' "$FILTER" >&2
  else
    printf '没有找到任何测试文件：%s/tests/test_*.sh\n' "$ROOT" >&2
  fi
  printf '可用的测试文件：\n' >&2
  for __f in "$ROOT"/tests/test_*.sh; do
    [ -f "$__f" ] || continue
    if [ "${__f##*/}" = "test_helper.sh" ]; then
      continue
    fi
    printf '  %s\n' "${__f##*/}" >&2
  done
  exit 2
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for __file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
    printf '%s\n' "${__file##*/}"
  done
  exit 0
fi

# --------------------------------------------------------------------------
# 默认路径：plain + 串行。行为与旧版逐字一致（流式输出、首个失败即退出）。
# --------------------------------------------------------------------------

_run_one() {
  local __file=$1
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$(_file_timeout "$__file")" bash "$__file" </dev/null
  else
    bash "$__file" </dev/null
  fi
}

_run_serial_plain() {
  local test_file
  local passed=0
  for test_file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
    printf '\n==> %s\n' "${test_file##*/}"
    if ! _run_one "$test_file"; then
      printf '\nFAILED: %s\n' "${test_file##*/}" >&2
      exit 1
    fi
    passed=$((passed + 1))
  done
  printf '\nAll %d test files passed.\n' "$passed"
}

if [ "$FORMAT" = plain ] && [ "$JOBS" -eq 1 ]; then
  _run_serial_plain
  exit 0
fi

# --------------------------------------------------------------------------
# 捕获式执行：tap / junit 报告，或并行（--jobs N）。
# 每个文件的 stdout / stderr / 退出码落在 $WORK/<idx>.* 里，最后统一汇总。
# --------------------------------------------------------------------------

_run_capture() {
  local file=$1 idx=$2
  local out="$WORK/$idx.out"
  local err="$WORK/$idx.err"
  local test_root="$TMP"
  local rc=0
  local started
  if [ "$JOBS" -gt 1 ]; then
    # 并行时每个文件一个自己的根目录，谁也踩不到谁
    test_root="$WORK/$idx.tmp"
    mkdir -p "$test_root"
  fi
  started=$SECONDS
  (
    set +e
    export TEST_TMP_ROOT="$test_root"
    if [ -n "$TIMEOUT_BIN" ]; then
      "$TIMEOUT_BIN" "$(_file_timeout "$file")" bash "$file" </dev/null >"$out" 2>"$err"
    else
      bash "$file" </dev/null >"$out" 2>"$err"
    fi
    rc=$?
    printf '%s %s\n' "$rc" "$((SECONDS - started))" >"$WORK/$idx.meta"
  )
  return 0
}

_LAUNCHED=0
_COMPLETED=0
_DONE_IDS=""

# 等一个后台任务收工：轮询 meta 文件，不依赖 wait -n（bash 3.2 没有）。
_reap_one() {
  local i
  while :; do
    for ((i = 0; i < _LAUNCHED; i += 1)); do
      if [ -f "$WORK/$i.meta" ]; then
        case " $_DONE_IDS " in
          *" $i "*) continue ;;
        esac
        _DONE_IDS="$_DONE_IDS $i"
        _COMPLETED=$((_COMPLETED + 1))
        return 0
      fi
    done
    sleep 0.05 2>/dev/null || sleep 1
  done
}

_run_parallel() {
  local idx=0
  local file
  for file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
    while [ $((_LAUNCHED - _COMPLETED)) -ge "$JOBS" ]; do
      _reap_one
    done
    _run_capture "$file" "$idx" >"$WORK/$idx.runner" 2>&1 &
    _LAUNCHED=$((_LAUNCHED + 1))
    idx=$((idx + 1))
  done
  while [ "$_COMPLETED" -lt "$_LAUNCHED" ]; do
    _reap_one
  done
  wait || true
}

if [ "$JOBS" -gt 1 ]; then
  _run_parallel
else
  __idx=0
  for __file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
    _run_capture "$__file" "$__idx" >"$WORK/$__idx.runner" 2>&1
    __idx=$((__idx + 1))
  done
fi

# --------------------------------------------------------------------------
# 用例结果：把每个文件的退出码与输出翻译成用例记录。
# 记录格式（制表符分隔）：status / TAP 名 / JUnit 名 / classname / 原因
# --------------------------------------------------------------------------

_rc_of() {
  local idx=$1
  local meta rc
  meta=$(cat "$WORK/$idx.meta" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    rc=${meta%% *}
  else
    rc=1
  fi
  case "$rc" in
    '' | *[!0-9]*) rc=1 ;;
  esac
  printf '%s' "$rc"
}

_elapsed_of() {
  local idx=$1
  local meta
  meta=$(cat "$WORK/$idx.meta" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    printf '%s' "${meta##* }"
  else
    printf '0'
  fi
}

_failure_message() {
  local idx=$1
  local rc=$2
  local err="$WORK/$idx.err"
  local msg=""
  local line
  if [ "$rc" -eq 124 ] && [ -n "$TIMEOUT_BIN" ]; then
    msg="timed out after ${TEST_TIMEOUT}s"
  fi
  if [ -f "$err" ]; then
    line=$(grep '^FAIL: ' "$err" 2>/dev/null | tail -1 || true)
    if [ -n "$line" ]; then
      msg=${line#FAIL: }
    fi
  fi
  if [ -z "$msg" ]; then
    msg="test file exited with status $rc"
  fi
  # 压成一行：制表符与换行都换成空格，避免撑坏记录格式
  msg=$(printf '%s' "$msg" | tr '\t\n' '  ')
  printf '%s' "$msg"
}

# 抽出文件里的 `# CASE: 标题` 标记，输出「行号<TAB>标题」
#
# 结果必须写进 $out，不能往 stdout 打：stdout 是 TAP/JUnit 报告本身，
# 混进一行「12\t某个用例名」会让 JUnit 变成非法 XML、TAP 解析器直接报错。
# 读和写要用两个文件 —— 边读 $out 边往 $out 追加会死循环。
_markers_of() {
  local file=$1
  local out=$2
  local line ln name
  local raw
  raw=$(grep -nE '^[[:space:]]*#[[:space:]]*CASE:[[:space:]]*[^[:space:]]' "$file" 2>/dev/null || true)
  : >"$out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ln=${line%%:*}
    name=${line#*:}
    name=${name#*CASE:}
    name=${name#"${name%%[![:space:]]*}"}
    printf '%s\t%s\n' "$ln" "$name" >>"$out"
  done <<SK_EOF
$raw
SK_EOF
}

# 重跑一次带 xtrace，定位失败发生在哪一行、属于哪个用例。
# 只在有 CASE 标记且失败时触发；定位不到就退回文件级。
_diagnose_trace() {
  local file=$1 idx=$2
  local base=${file##*/}
  local trace="$WORK/$idx.trace"
  local test_root="$TMP"
  if [ "$JOBS" -gt 1 ]; then
    test_root="$WORK/$idx.tmp"
  fi
  (
    set +e
    export TEST_TMP_ROOT="$test_root"
    if [ -n "$TIMEOUT_BIN" ]; then
      PS4='+[${BASH_SOURCE[0]##*/}:${LINENO}]: ' \
        "$TIMEOUT_BIN" "$(_file_timeout "$file")" bash -x "$file" </dev/null >/dev/null 2>"$trace"
    else
      PS4='+[${BASH_SOURCE[0]##*/}:${LINENO}]: ' \
        bash -x "$file" </dev/null >/dev/null 2>"$trace"
    fi
  ) || true
  printf '%s' "$trace"
}

# 从 trace 里算出：失败行号、失败用例序号、各用例是否被进入过
_analyze_trace() {
  local base=$1 trace=$2 marker_lines=$3
  awk -v p="+[$base:" -v mk="$marker_lines" '
    BEGIN {
      n = split(mk, m, ",")
      for (i = 1; i <= n; i += 1) ml[i] = m[i] + 0
    }
    index($0, p) == 1 {
      r = substr($0, length(p) + 1)
      if (match(r, /^[0-9]+/)) {
        L = substr(r, 1, RLENGTH) + 0
        if (L > maxline) { maxline = L; maxcase = 0 }
        for (i = 1; i <= n; i += 1) {
          if (i < n) { hi = ml[i + 1] - 1 } else { hi = 1000000000 }
          if (L > ml[i] && L <= hi) {
            seen[i] = 1
            if (L == maxline) { maxcase = i }
          }
        }
      }
    }
    END {
      printf "%d %d", maxline, maxcase
      for (i = 1; i <= n; i += 1) printf " %d", seen[i] + 0
    }
  ' "$trace" 2>/dev/null || printf '0 0'
}

_collect_cases() {
  local file=$1 idx=$2
  local rec="$WORK/$idx.cases"
  local markers="$WORK/$idx.markers"
  local base=${file##*/}
  local stem=${base%.sh}
  local class="tests.$stem"
  local rc msg
  local ncases=0
  local ln title
  local -a mlines
  local -a mnames
  local -a seenarr
  local marker_lines=""
  local i c status

  : >"$rec"
  rc=$(_rc_of "$idx")
  _markers_of "$file" "$markers"
  if [ -s "$markers" ]; then
    ncases=$(wc -l <"$markers" | tr -d ' ')
  fi

  if [ "$ncases" -eq 0 ]; then
    # 退化路径：文件级一条用例
    if [ "$rc" -eq 0 ]; then
      printf 'ok\t%s\t%s\t%s\t\n' "$base" "$stem" "$class" >>"$rec"
    else
      msg=$(_failure_message "$idx" "$rc")
      printf 'notok\t%s\t%s\t%s\t%s\n' "$base" "$stem" "$class" "$msg" >>"$rec"
    fi
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    while IFS=$'\t' read -r ln title; do
      [ -n "$title" ] || continue
      printf 'ok\t%s :: %s\t%s\t%s\t\n' "$base" "$title" "$title" "$class" >>"$rec"
    done <"$markers"
    return 0
  fi

  # 失败：找失败落在哪个用例
  mlines=()
  mnames=()
  while IFS=$'\t' read -r ln title; do
    [ -n "$title" ] || continue
    mlines[${#mlines[@]}]=$ln
    mnames[${#mnames[@]}]=$title
  done <"$markers"
  for ((i = 0; i < ${#mlines[@]}; i += 1)); do
    if [ -z "$marker_lines" ]; then
      marker_lines=${mlines[$i]}
    else
      marker_lines="$marker_lines,${mlines[$i]}"
    fi
  done

  msg=$(_failure_message "$idx" "$rc")
  _diagnose_trace "$file" "$idx" >/dev/null
  local analysis maxline maxcase
  analysis=$(_analyze_trace "$base" "$WORK/$idx.trace" "$marker_lines")
  maxline=${analysis%% *}
  analysis=${analysis#* }
  maxcase=${analysis%% *}
  local seen_rest=""
  case "$analysis" in
    *' '*) seen_rest=${analysis#* } ;;
  esac
  if [ "$maxline" -gt 0 ]; then
    msg="$msg (test file line $maxline)"
  fi
  seenarr=()
  if [ -n "$seen_rest" ]; then
    IFS=' ' read -r -a seenarr <<<"$seen_rest"
  fi

  if [ "$maxcase" -eq 0 ]; then
    # 定位不到具体用例：文件级记一条失败，其余用例记未运行
    printf 'notok\t%s\t%s\t%s\t%s\n' "$base" "$stem" "$class" "$msg" >>"$rec"
    for ((i = 0; i < ${#mnames[@]}; i += 1)); do
      printf 'skip\t%s :: %s\t%s\t%s\tnot run\n' "$base" "${mnames[$i]}" "${mnames[$i]}" "$class" >>"$rec"
    done
    return 0
  fi

  for ((i = 0; i < ${#mnames[@]}; i += 1)); do
    c=$((i + 1))
    title=${mnames[$i]}
    if [ "$c" -gt "$maxcase" ]; then
      status=skip
    elif [ "$c" -eq "$maxcase" ]; then
      status=notok
    elif [ "${seenarr[$((c - 1))]:-0}" = "1" ]; then
      status=ok
    else
      status=skip
    fi
    case "$status" in
      ok)
        printf 'ok\t%s :: %s\t%s\t%s\t\n' "$base" "$title" "$title" "$class" >>"$rec"
        ;;
      notok)
        printf 'notok\t%s :: %s\t%s\t%s\t%s\n' "$base" "$title" "$title" "$class" "$msg" >>"$rec"
        ;;
      skip)
        printf 'skip\t%s :: %s\t%s\t%s\tnot run\n' "$base" "$title" "$title" "$class" >>"$rec"
        ;;
    esac
  done
  return 0
}

__idx=0
for __file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
  _collect_cases "$__file" "$__idx"
  __idx=$((__idx + 1))
done

# --------------------------------------------------------------------------
# 渲染
# --------------------------------------------------------------------------

_count_cases() {
  local idx n total=0
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    n=$(wc -l <"$WORK/$idx.cases" | tr -d ' ')
    total=$((total + n))
  done
  printf '%s' "$total"
}

_count_by_status() {
  local want=$1
  local idx status tap_name junit_name class message n=0
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    while IFS=$'\t' read -r status tap_name junit_name class message; do
      if [ "$status" = "$want" ]; then
        n=$((n + 1))
      fi
    done <"$WORK/$idx.cases"
  done
  printf '%s' "$n"
}

_total_time() {
  local idx t total=0
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    t=$(_elapsed_of "$idx")
    total=$((total + t))
  done
  printf '%s' "$total"
}

_xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&apos;}
  printf '%s' "$s"
}

_render_tap() {
  local idx num=0 total
  local status tap_name junit_name class message
  total=$(_count_cases)
  printf 'TAP version 13\n'
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    while IFS=$'\t' read -r status tap_name junit_name class message; do
      num=$((num + 1))
      case "$status" in
        ok)
          printf 'ok %d - %s\n' "$num" "$tap_name"
          ;;
        notok)
          printf 'not ok %d - %s\n' "$num" "$tap_name"
          if [ -n "$message" ]; then
            printf '# %s\n' "$message"
          fi
          ;;
        skip)
          printf 'ok %d - %s # SKIP %s\n' "$num" "$tap_name" "${message:-not run}"
          ;;
      esac
    done <"$WORK/$idx.cases"
  done
  printf '1..%d\n' "$total"
}

_render_junit() {
  local idx num=0 total failures skipped total_time
  local status tap_name junit_name class message
  local elapsed details
  total=$(_count_cases)
  failures=$(_count_by_status notok)
  skipped=$(_count_by_status skip)
  total_time=$(_total_time)
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<testsuites>\n'
  printf '  <testsuite name="shellkit" tests="%d" failures="%d" errors="0" skipped="%d" time="%d">\n' \
    "$total" "$failures" "$skipped" "$total_time"
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    elapsed=$(_elapsed_of "$idx")
    details=$(sed -n '1,200p' "$WORK/$idx.err" 2>/dev/null || true)
    while IFS=$'\t' read -r status tap_name junit_name class message; do
      num=$((num + 1))
      case "$status" in
        ok)
          printf '    <testcase classname="%s" name="%s" time="%d"/>\n' \
            "$(_xml_escape "$class")" "$(_xml_escape "$junit_name")" "$elapsed"
          ;;
        notok)
          printf '    <testcase classname="%s" name="%s" time="%d">\n' \
            "$(_xml_escape "$class")" "$(_xml_escape "$junit_name")" "$elapsed"
          printf '      <failure message="%s">%s</failure>\n' \
            "$(_xml_escape "$message")" "$(_xml_escape "$details")"
          printf '    </testcase>\n'
          ;;
        skip)
          printf '    <testcase classname="%s" name="%s" time="0"><skipped/></testcase>\n' \
            "$(_xml_escape "$class")" "$(_xml_escape "$junit_name")"
          ;;
      esac
    done <"$WORK/$idx.cases"
  done
  printf '  </testsuite>\n'
  printf '</testsuites>\n'
}

_render_plain() {
  local idx base failed=0
  for ((idx = 0; idx < ${#TEST_FILES[@]}; idx += 1)); do
    base=${TEST_FILES[$idx]##*/}
    printf '\n==> %s\n' "$base"
    if [ -s "$WORK/$idx.out" ]; then
      cat "$WORK/$idx.out"
    fi
    if [ -s "$WORK/$idx.err" ]; then
      cat "$WORK/$idx.err" >&2
    fi
    if [ "$(_rc_of "$idx")" != "0" ]; then
      printf '\nFAILED: %s\n' "$base" >&2
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  printf '\nAll %d test files passed.\n' "${#TEST_FILES[@]}"
  return 0
}

case "$FORMAT" in
  tap) _render_tap ;;
  junit) _render_junit ;;
  plain) _render_plain ;;
esac

# 退出码：有失败就是 1，全部通过才是 0
__failed=0
__i=0
for __file in ${TEST_FILES[@]+"${TEST_FILES[@]}"}; do
  if [ "$(_rc_of "$__i")" != "0" ]; then
    __failed=1
  fi
  __i=$((__i + 1))
done
[ "$__failed" -eq 0 ] || exit 1
exit 0
