#!/usr/bin/env bash
# 极简断言库。断言失败即 exit 1，由 tests/run.sh 逐文件执行。

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
TEST_TMP_ROOT="${TEST_TMP_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/shellkit-tests.XXXXXX")}"
export TEST_ROOT TEST_TMP_ROOT

# 输出语言固定成英文：断言里写的是英文文案（msgid 本身就是英文），
# 而输出会被本地化 —— 中文 locale 的机器上，168 条文案断言会整片炸红
#（国产系统默认 zh_CN.UTF-8，正是批次 4.2 要上的流水线）。
# SHELLKIT_LANG 的优先级最高（SHELLKIT_LANG → LC_ALL → LC_MESSAGES → LANG → en），
# 设成 en 就与系统 locale、gettext 在不在都无关了。
# 要测本地化行为的用例自己写 SHELLKIT_LANG=zh_CN 覆盖掉这一行。
export SHELLKIT_LANG=en

_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local __expected=$1 __actual=$2 __msg=${3:-values differ}
  if [ "$__actual" != "$__expected" ]; then
    _fail "$__msg: expected <$__expected>, got <$__actual>"
  fi
  return 0
}

assert_ne() {
  local __unexpected=$1 __actual=$2 __msg=${3:-values should differ}
  if [ "$__actual" = "$__unexpected" ]; then
    _fail "$__msg: both are <$__actual>"
  fi
  return 0
}

assert_contains() {
  local __haystack=$1 __needle=$2 __msg=${3:-value does not contain expected text}
  case "$__haystack" in
    *"$__needle"*) return 0 ;;
  esac
  _fail "$__msg: <$__needle>"
}

assert_not_contains() {
  local __haystack=$1 __needle=$2 __msg=${3:-value unexpectedly contains text}
  case "$__haystack" in
    *"$__needle"*) _fail "$__msg: <$__needle>" ;;
  esac
  return 0
}

# assert_true / assert_false —— 断言一条命令的成败
#
# ⚠️ **只能传命令，不能带提示文案**：这两个断言把**全部**参数交给被测命令，
# 多一个字符串就是多一个参数 —— assert_true test -d "$p" "说明" 会变成
# `test -d "$p" "说明"`，test 报 "binary operator expected"。
# 要带说明就自己写断言（_fail "expected ..."），或者用 assert_eq / assert_contains。
assert_true() {
  if ! "$@"; then
    _fail "expected success: $*"
  fi
  return 0
}

assert_false() {
  if "$@"; then
    _fail "expected failure: $*"
  fi
  return 0
}

assert_exit_code() {
  local __want=$1
  shift
  local __got=0
  "$@" || __got=$?
  if [ "$__got" != "$__want" ]; then
    _fail "expected exit $__want, got $__got: $*"
  fi
  return 0
}

assert_stdout_empty() {
  local __out
  __out=$("$@" 2>/dev/null) || true
  if [ -n "$__out" ]; then
    _fail "expected empty stdout, got <$__out>"
  fi
  return 0
}

# _file_mode FILE —— 权限位（八进制）；取不到就输出空
#
# 与 lib/core/fs.sh 的 _sk_fs_mode 同一条纪律：**输出必须是八进制**。
# GNU 的 stat -f 是 --file-system，会吐 `File: "..."` 这种内容且可能退出 0 ——
# 原来「退出码为 0 就认它」的写法会把文件系统信息当成权限值（CI run 43238779798
# 的 perm.mode 判据就是这么红的）。
_file_mode() {
  local __m=""
  if __m=$(stat -f '%Lp' "$1" 2>/dev/null); then
    case "$__m" in
      '' | *[!0-7]*) __m="" ;;
    esac
  else
    __m=""
  fi
  if [ -z "$__m" ]; then
    __m=$(stat -c '%a' "$1" 2>/dev/null) || __m=""
  fi
  printf '%s' "$__m"
}

assert_file_mode() {
  local __file=$1 __want=$2 __got
  __got=$(_file_mode "$__file")
  if [ "$__got" != "$__want" ]; then
    _fail "expected mode $__want for $__file, got $__got"
  fi
  return 0
}

# 每个测试文件新建互不干扰的子目录
tmpdir() {
  local __d
  __d=$(mktemp -d "$TEST_TMP_ROOT/case.XXXXXX") || return 1
  printf '%s\n' "$__d"
}

# ---------------------------------------------------------------------------
# stub：在测试进程里用同名 shell 函数顶替外部命令，用来跑失败分支。
# 函数对 $(...) 子 shell 天然可见，所以 net_download 里调的 curl 会被拦住。
# ---------------------------------------------------------------------------

SK_STUB_ROOT=""
_SK_STUB_NAMES=""

# 注意：必须在当前 shell 里设置 SK_STUB_ROOT，不能靠 $( ) 取回 ——
# 命令替换在子 shell 里执行，赋值出不来，断言就会去 /curl.log 找记录。
_sk_stub_dir() {
  if [ -z "$SK_STUB_ROOT" ]; then
    SK_STUB_ROOT="$TEST_TMP_ROOT/stubs"
    mkdir -p "$SK_STUB_ROOT" || _fail "cannot create $SK_STUB_ROOT"
  fi
  return 0
}

# stub NAME [--exit N] [--stdout TEXT] [--stderr TEXT] [--body SCRIPT]
stub() {
  local __name=${1:-}
  local __dir __exit=0 __out="" __err="" __body="" __outf __errf __log __fn
  if [ -z "$__name" ]; then
    _fail "stub: name is required"
  fi
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --exit)
        __exit=${2:-0}
        shift 2
        ;;
      --stdout)
        __out=${2:-}
        shift 2
        ;;
      --stderr)
        __err=${2:-}
        shift 2
        ;;
      --body)
        __body=${2:-}
        shift 2
        ;;
      *)
        _fail "stub: unknown option: $1"
        ;;
    esac
  done

  _sk_stub_dir
  __dir=$SK_STUB_ROOT
  __outf="$__dir/$__name.out"
  __errf="$__dir/$__name.err"
  __log="$__dir/$__name.log"
  printf '%s' "$__out" >"$__outf"
  printf '%s' "$__err" >"$__errf"
  : >"$__log"

  # body 必须在**子 shell 里的函数**中执行，两层都缺一不可：
  #   - 子 shell：body 里的 exit 只退出子 shell —— 否则 exit 会把整个测试脚本
  #     干掉，而退出码恰好是 0 ⇒ runner 判「全过」，后面所有断言都没跑过
  #     （这个假绿真的发生过：test_svc.sh 后半段从来没执行过）；
  #   - 函数：body 里的 return N 是「让 stub 返回 N」的既有写法，
  #     直接放进子 shell 会变成「不是函数里不能 return」的报错。
  # 末尾补一句 return 0：body 自然走完时落回 --exit 指定的退出码，
  # 显式 return / exit 的短路行为不变。
  __fn="$__name() {
  printf '%s\n' \"\$*\" >>'$__log'
  if [ -s '$__outf' ]; then cat '$__outf'; fi
  if [ -s '$__errf' ]; then cat '$__errf' >&2; fi
  _sk_stub_body__() {
  $__body
  return 0
  }
  ( _sk_stub_body__ \"\$@\" )
  __brc=\$?
  unset -f _sk_stub_body__
  if [ \"\$__brc\" -ne 0 ]; then return \"\$__brc\"; fi
  return $__exit
}"
  eval "$__fn"
  case " $_SK_STUB_NAMES " in
    *" $__name "*) ;;
    *) _SK_STUB_NAMES="$_SK_STUB_NAMES $__name" ;;
  esac
  return 0
}

unstub() {
  local __name=${1:-}
  if [ -z "$__name" ]; then
    return 0
  fi
  unset -f "$__name" 2>/dev/null || true
  return 0
}

stub_reset() {
  local __n
  for __n in $_SK_STUB_NAMES; do
    unset -f "$__n" 2>/dev/null || true
  done
  _SK_STUB_NAMES=""
  if [ -n "$SK_STUB_ROOT" ]; then
    rm -rf "$SK_STUB_ROOT"
  fi
  return 0
}

_sk_stub_log() {
  printf '%s\n' "$SK_STUB_ROOT/$1.log"
}

assert_stub_called() {
  local __name=$1 __want=${2:-} __log __got=0
  __log=$(_sk_stub_log "$__name")
  if [ -f "$__log" ]; then
    __got=$(grep -c '' "$__log" 2>/dev/null || true)
  fi
  case "$__got" in
    '' | *[!0-9]*) __got=0 ;;
  esac
  if [ -n "$__want" ] && [ "$__got" != "$__want" ]; then
    _fail "stub <$__name> expected $__want call(s), got $__got"
  fi
  if [ -z "$__want" ] && [ "$__got" -eq 0 ]; then
    _fail "stub <$__name> was not called"
  fi
  return 0
}

assert_stub_not_called() {
  local __name=$1 __log __got=0
  __log=$(_sk_stub_log "$__name")
  if [ -f "$__log" ]; then
    __got=$(grep -c '' "$__log" 2>/dev/null || true)
  fi
  case "$__got" in
    '' | *[!0-9]*) __got=0 ;;
  esac
  if [ "$__got" -ne 0 ]; then
    _fail "stub <$__name> was called $__got time(s)"
  fi
  return 0
}

assert_stub_args() {
  local __name=$1 __text=${2:-} __log
  __log=$(_sk_stub_log "$__name")
  if [ ! -f "$__log" ] || ! grep -F -- "$__text" "$__log" >/dev/null 2>&1; then
    _fail "stub <$__name> was never called with args containing <$__text>"
  fi
  return 0
}
