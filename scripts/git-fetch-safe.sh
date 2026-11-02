#!/usr/bin/env bash
#
# 有界、可重试的 git 取数（fetch / pull / clone）。
#
# 为什么有这个脚本（2026-11-02 实录）：
#   本机到 GitHub 的 git 操作会**瞬断并挂住**（ssh 层无进展时 git 不会自行放弃）。
#   没有超时 ⇒ 调用方被拖死：
#   · agent 后台任务：60s 上限一到就被杀 ⇒ **只留下半截输出**——实录任务
#     「Hub local vs origin/main」的完整输出只有本地 HEAD `69a968b`，
#     远端值根本没取到 ⇒ 看输出的人把它当成了结论 ⇒ 漏掉「本地 main 落后
#     远端两个 commit」这个真分叉（AGENTS.md 早就记过这个坑）；
#   · `make setup`：十二个仓逐个 pull ⇒ 一个卡住整个命令无限等；
#   · trainctl（CI）：fetch 挂住 ⇒ job 拖满 6 小时上限。
#
#   本脚本给每次 git 操作加**超时上限** + **有限重试**，并把
#   **「超时」与「失败」分成两个退出码**——超时不是失败：前者说明链路抖、
#   重试即可；后者要人看（仓库错/权限错）。
#
# 每次尝试都打印一行结论 ⇒ **失败在输出里看得见**，不再留半截输出让人误读。
#
# 用法:
#   bash scripts/git-fetch-safe.sh fetch <dir> [branch]
#   bash scripts/git-fetch-safe.sh pull  <dir> [branch]
#   bash scripts/git-fetch-safe.sh clone <url> <dir> <branch>
#   公共选项: --timeout 60s --retries 3 --backoff 5s
#   bash scripts/git-fetch-safe.sh --selfcheck
#
# 退出码:
#   0 = 成功   1 = 最终失败   2 = 最终超时（**不是失败**）
set -uo pipefail

DEFAULT_TIMEOUT="60s"
DEFAULT_RETRIES=3
DEFAULT_BACKOFF="5s"

# ───────────────────────── 用法 ─────────────────────────

usage() {
	cat >&2 <<'EOF'
用法:
  bash scripts/git-fetch-safe.sh fetch <dir> [branch]
  bash scripts/git-fetch-safe.sh pull  <dir> [branch]
  bash scripts/git-fetch-safe.sh clone <url> <dir> <branch>
  bash scripts/git-fetch-safe.sh compare [branch]     # 默认 main；GIT_FETCH_SAFE_DIR 指定仓目录
  bash scripts/git-fetch-safe.sh push [refspec]       # 默认 HEAD；GIT_FETCH_SAFE_DIR 指定仓目录
  公共选项: --timeout 60s --retries 3 --backoff 5s
  bash scripts/git-fetch-safe.sh --selfcheck

退出码: 0 = 成功 / 同点   1 = 失败 / 有差异（落后·领先·分叉）   2 = 超时（**不是失败**）   3 = 用法错误
EOF
}

# ───────────────────────── 参数 ─────────────────────────

# parse_duration 把 "60s"/"5m"/"1h" 解析成秒数；非法输入返回 1。
parse_duration() {
	local d="${1:-}"
	local n u
	case "$d" in
	*s) n="${d%s}"; u=1 ;;
	*m) n="${d%m}"; u=60 ;;
	*h) n="${d%h}"; u=3600 ;;
	*) n="$d"; u=1 ;;
	esac
	case "$n" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$((n * u))"
}

# ───────────────────────── 有界执行 ─────────────────────────

# run_bounded <秒数> <命令...>：执行命令，超过秒数即杀掉并返回 124。
#
# 不用外部 timeout（macOS 自带 BSD 工具链**没有** coreutils 的 timeout）⇒
# 自己实现：后台起进程 → 轮询进程状态 → 超时则 TERM 再 KILL。
#
# ⚠️ 僵尸态判定：子进程退出后未 wait 之前是僵尸，`kill -0` 对僵尸**仍返回 0**
# ⇒ 只用 `kill -0` 判存活会**永远等不到退出** ⇒ 必须看 `ps` 的状态位
# （Z = 僵尸 = 已退出）。
run_bounded() {
	local secs="$1"
	shift
	local out err pid waited=0 rc=0 state=""
	out="$(mktemp)"
	err="$(mktemp)"
	"$@" >"$out" 2>"$err" &
	pid=$!
	while :; do
		state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
		case "$state" in
		"" | Z*)
			break
			;;
		esac
		if [ "$waited" -ge "$secs" ]; then
			kill -TERM "$pid" 2>/dev/null
			sleep 1
			kill -KILL "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			echo "[超时] ${*} 超过 ${secs}s 被终止" >&2
			cat "$out" >&2
			cat "$err" >&2
			rm -f "$out" "$err"
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$pid" 2>/dev/null
	rc=$?
	cat "$out"
	cat "$err" >&2
	rm -f "$out" "$err"
	return "$rc"
}

# ───────────────────────── 取数（带重试） ─────────────────────────

# fetch_with_retry <超时秒> <重试次数> <退避秒> <命令...>
# 返回: 0 = 成功 / 1 = 最终失败 / 2 = 最终超时
fetch_with_retry() {
	local tsec="$1" retries="$2" backoff="$3"
	shift 3
	local attempt=1 rc=0 kind=""
	while :; do
		run_bounded "$tsec" "$@"
		rc=$?
		case "$rc" in
		0)
			echo "[ok] 第 ${attempt} 次成功"
			return 0
			;;
		124)
			kind="超时"
			;;
		*)
			kind="失败"
			;;
		esac
		if [ "$attempt" -ge "$retries" ]; then
			echo "[${kind}] 重试 ${attempt} 次仍${kind} ⇒ 放弃" >&2
			if [ "$rc" -eq 124 ]; then
				return 2
			fi
			return 1
		fi
		echo "[${kind}] 第 ${attempt} 次${kind}，${backoff}s 后重试" >&2
		attempt=$((attempt + 1))
		sleep "$backoff"
	done
}

# ───────────────────────── 自证 ─────────────────────────

# selfcheck 用**假 git**（PATH 注入，不依赖网络）验证：
#   ① 超时 ⇒ rc=2（**不是** 1）
#   ② 第一次失败、重试后成功 ⇒ rc=0
#   ③ 一直失败 ⇒ rc=1
#   ④ 一次成功 ⇒ rc=0
selfcheck() {
	local fails=0
	local tmp
	tmp="$(mktemp -d)"

	mk_fake_git() {
		local dir="$1"
		mkdir -p "$dir"
		cat >"$dir/git" <<'EOF'
#!/usr/bin/env bash
# 假 git：忽略全部参数，按 GIT_FAKE_BEHAVIOR 模拟
counter="${GIT_FAKE_COUNTER:-/dev/null}"
case "${GIT_FAKE_BEHAVIOR:-ok}" in
sleep)
	sleep 30
	exit 0
	;;
fail-once)
	n=$(cat "$counter" 2>/dev/null || echo 0)
	n=$((n + 1))
	echo "$n" >"$counter"
	if [ "$n" -lt 2 ]; then
		echo "fake git: 模拟瞬断" >&2
		exit 128
	fi
	exit 0
	;;
fail-always)
	echo "fake git: 模拟持续失败" >&2
	exit 128
	;;
esac
exit 0
EOF
		chmod +x "$dir/git"
	}

	# ① 超时 ⇒ rc=2
	mk_fake_git "$tmp/sleepbin"
	local rc=0
	( PATH="$tmp/sleepbin:$PATH" GIT_FAKE_BEHAVIOR=sleep GIT_FAKE_COUNTER="$tmp/c1" \
		bash "$0" fetch "$tmp" --timeout 1s --retries 1 --backoff 0s ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 2 ]; then
		echo "✗ 超时被判成 rc=${rc}（应为 2=超时，不是 1=失败）"
		fails=$((fails + 1))
	fi

	# ② 失败后重试成功 ⇒ rc=0
	mk_fake_git "$tmp/retrybin"
	rc=0
	( PATH="$tmp/retrybin:$PATH" GIT_FAKE_BEHAVIOR=fail-once GIT_FAKE_COUNTER="$tmp/c2" \
		bash "$0" fetch "$tmp" --timeout 5s --retries 3 --backoff 0s ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "✗ 重试后成功却判成 rc=${rc}（应为 0）"
		fails=$((fails + 1))
	fi

	# ③ 一直失败 ⇒ rc=1
	mk_fake_git "$tmp/failbin"
	rc=0
	( PATH="$tmp/failbin:$PATH" GIT_FAKE_BEHAVIOR=fail-always GIT_FAKE_COUNTER="$tmp/c3" \
		bash "$0" fetch "$tmp" --timeout 5s --retries 2 --backoff 0s ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 1 ]; then
		echo "✗ 持续失败被判成 rc=${rc}（应为 1）"
		fails=$((fails + 1))
	fi

	# ④ 一次成功 ⇒ rc=0
	mk_fake_git "$tmp/okbin"
	rc=0
	( PATH="$tmp/okbin:$PATH" GIT_FAKE_BEHAVIOR=ok GIT_FAKE_COUNTER="$tmp/c4" \
		bash "$0" fetch "$tmp" --timeout 5s --retries 2 --backoff 0s ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "✗ 一次成功被判成 rc=${rc}（应为 0）"
		fails=$((fails + 1))
	fi

	# ⑤ compare：取数失败 ⇒ rc=2（**不是 1**）
	#    1 = 有差异、2 = 没取到数 ⇒ 两者必须分开，否则调用方会把网络失败
	#    读成「本地与远端不同」⇒ 给出根本不存在的结论。
	mk_fake_git "$tmp/cmpfailbin"
	rc=0
	( PATH="$tmp/cmpfailbin:$PATH" GIT_FAKE_BEHAVIOR=fail-always GIT_FAKE_COUNTER="$tmp/c5" \
		bash "$0" compare main --timeout 5s --retries 2 --backoff 0s ) >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 2 ]; then
		echo "✗ compare 取数失败被判成 rc=${rc}（应为 2=没取到数，不是 1=有差异）"
		fails=$((fails + 1))
	fi

	rm -rf "$tmp"
	if [ "$fails" -eq 0 ]; then
		echo "✓ selfcheck 通过（超时≠失败 / 重试可救 / 失败可辨 / 成功直出 / compare 没取到数≠有差异）"
		return 0
	fi
	echo "✗ selfcheck 失败 ${fails} 项"
	return 1
}

# ───────────────────────── 主流程 ─────────────────────────

main() {
	local op="" timeout_s="" retries="$DEFAULT_RETRIES" backoff="$DEFAULT_BACKOFF"
	local selfcheck_mode=0
	# ⚠️ 不用数组装位置参数：macOS 自带 bash 3.2 在 `set -u` 下引用空数组元素
	# 会报 unbound variable ⇒ 用计数器 + 具名变量（与 wait-pr-checks.sh 同款做法）。
	local a1="" a2="" a3="" pos=0
	local want_val="" arg

	for arg in "$@"; do
		if [ -n "$want_val" ]; then
			case "$want_val" in
			timeout) timeout_s="$arg" ;;
			retries) retries="$arg" ;;
			backoff) backoff="$arg" ;;
			esac
			want_val=""
			continue
		fi
		case "$arg" in
		--selfcheck)
			selfcheck_mode=1
			;;
		--timeout)
			want_val="timeout"
			;;
		--retries)
			want_val="retries"
			;;
		--backoff)
			want_val="backoff"
			;;
		--timeout=*)
			timeout_s="${arg#--timeout=}"
			;;
		--retries=*)
			retries="${arg#--retries=}"
			;;
		--backoff=*)
			backoff="${arg#--backoff=}"
			;;
		-*)
			echo "未知参数: ${arg}" >&2
			usage
			return 3
			;;
		*)
			pos=$((pos + 1))
			case "$pos" in
			1) a1="$arg" ;;
			2) a2="$arg" ;;
			3) a3="$arg" ;;
			*)
				echo "多余参数: ${arg}" >&2
				usage
				return 3
				;;
			esac
			;;
		esac
	done

	if [ "$selfcheck_mode" -eq 1 ]; then
		selfcheck
		return $?
	fi

	[ -n "$timeout_s" ] || timeout_s="$DEFAULT_TIMEOUT"
	local tsec bsec
	tsec="$(parse_duration "$timeout_s")" || {
		echo "非法 --timeout: ${timeout_s}" >&2
		return 3
	}
	bsec="$(parse_duration "$backoff")" || {
		echo "非法 --backoff: ${backoff}" >&2
		return 3
	}
	case "$retries" in
	'' | *[!0-9]*)
		echo "非法 --retries: ${retries}" >&2
		return 3
		;;
	esac
	if [ "$retries" -lt 1 ]; then
		echo "--retries 至少为 1" >&2
		return 3
	fi

	op="$a1"
	case "$op" in
	fetch | pull | clone | compare | push) ;;
	*)
		usage
		return 3
		;;
	esac

	local dir="" branch="main" url="" refspec=""
	case "$op" in
	fetch | pull)
		dir="$a2"
		branch="${a3:-main}"
		[ -n "$dir" ] || {
			usage
			return 3
		}
		;;
	clone)
		url="$a2"
		dir="$a3"
		branch="main"
		if [ -z "$url" ] || [ -z "$dir" ]; then
			usage
			return 3
		fi
		;;
	compare)
		dir="${GIT_FETCH_SAFE_DIR:-.}"
		branch="${a2:-main}"
		;;
	push)
		dir="${GIT_FETCH_SAFE_DIR:-.}"
		refspec="${a2:-HEAD}"
		;;
	esac

	local -a cmd=()
	case "$op" in
	fetch) cmd=(git -C "$dir" fetch -q origin "$branch") ;;
	pull) cmd=(git -C "$dir" pull --ff-only origin "$branch") ;;
	clone) cmd=(git clone -b "$branch" "$url" "$dir") ;;
	compare) cmd=(git -C "$dir" fetch -q origin "$branch") ;;
	push) cmd=(git -C "$dir" push origin "$refspec") ;;
	esac

	echo "取数: ${cmd[*]}（超时 ${timeout_s}，重试 ${retries}，退避 ${backoff}）"
	fetch_with_retry "$tsec" "$retries" "$bsec" "${cmd[@]}"
	local frc=$?
	if [ "$frc" -ne 0 ]; then
		if [ "$op" = "compare" ]; then
			# ⚠️ compare 的「没取到数」**必须**与「有差异」分开：
			# 两者都返回 1 会让调用方把「网络失败」读成「本地与远端不同」⇒
			# 给出根本不存在的结论（这正是本脚本要根除的那类错）。
			# ⇒ 取数失败/超时一律 2（输出里已写明是超时还是失败）。
			echo "✗ 取数失败/超时 ⇒ **不给结论**（本地与远端的关系未知）" >&2
			return 2
		fi
		return "$frc"
	fi

	# compare：取到数之后才给结论
	#
	# ⚠️ 比的对象必须是**同一个 ref 的两端**：`git rev-list --left-right --count
	# <ref>...origin/<branch>`。拿 **HEAD**（当前分支）去比 origin/main 是**比错了
	# 对象**——在 feature 分支上 HEAD 本就与 origin/main 不同 ⇒ 报出假「分叉」
	# （实录：本地 main 其实只是落后 2 个提交，却被看成 a243d8c vs 8147ca0）。
	if [ "$op" != "compare" ]; then
		return 0
	fi
	local counts left=0 right=0 local_sha remote_sha
	counts="$(git -C "$dir" rev-list --left-right --count "${branch}...origin/${branch}" 2>/dev/null)" || {
		echo "比对失败: 无法解析 ${branch}...origin/${branch}" >&2
		return 1
	}
	left="$(echo "$counts" | awk '{print $1}')"
	right="$(echo "$counts" | awk '{print $2}')"
	local_sha="$(git -C "$dir" rev-parse --short "${branch}" 2>/dev/null)"
	remote_sha="$(git -C "$dir" rev-parse --short "origin/${branch}" 2>/dev/null)"
	echo "本地 ${branch}=${local_sha}  远端 origin/${branch}=${remote_sha}  本地独有=${left} 远端独有=${right}"
	if [ "$left" -eq 0 ] && [ "$right" -eq 0 ]; then
		echo "✓ 同点"
		return 0
	fi
	if [ "$left" -gt 0 ] && [ "$right" -gt 0 ]; then
		echo "✗ **真分叉**：本地独有 ${left} 提交、远端独有 ${right} 提交 ⇒ 先人工处理（本地改动先存 patch，再 git reset --hard origin/${branch}）"
		return 1
	fi
	if [ "$right" -gt 0 ]; then
		echo "⚠ 本地落后 ${right} 个提交（可快进：git -C ${dir} merge --ff-only origin/${branch}）"
	else
		echo "⚠ 本地**领先** ${left} 个提交（远端没有；确认是不是该推上去）"
	fi
	return 1
}

main "$@"
