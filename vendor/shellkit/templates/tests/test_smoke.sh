#!/usr/bin/env bash
# 骨架冒烟：生成完必须当场是绿的。
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

ENTRY="$TEST_ROOT/bin/{{NAME}}"

out=$("$ENTRY" --version 2>/dev/null)
assert_ne "" "$out" "--version prints a version"

assert_exit_code 0 "$ENTRY" --help

assert_exit_code 0 "$ENTRY" {{CMD}}

assert_exit_code 2 "$ENTRY" definitely-not-a-command

# 日志必须走 stderr：stdout 只能有数据
out=$("$ENTRY" {{CMD}} 2>/dev/null)
assert_not_contains "$out" "[INFO]" "logs must not pollute stdout"
