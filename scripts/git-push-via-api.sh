#!/usr/bin/env bash
#
# git-push-via-api.sh —— **github.com:443 不可达时的推送兜底**（Git Data API）。
#
# 为什么要有这个脚本（2026-11-04 实录）：
#   本机到 github.com 的链路会**完全不通**（不是慢，是 connect timeout：
#   curl 8s 直连返回 000），而 **api.github.com 仍然可达**（200 / 0.7s）。
#   ⇒ git 协议走 github.com ⇒ fetch/push 全废；
#     但 REST API 走 api.github.com ⇒ **推分支照样能做成**。
#   实录：一次 push 报 `curl 28 Failed to connect to github.com port 443 after
#   75000 ms` ⇒ 远端**没有**分支；改走 API（blob → tree → commit → ref）
#   ⇒ 一次成功。
#
#   姊妹脚本 `git-fetch-safe.sh` 管的是「**慢/抖**」（加超时 + 重试）；
#   本脚本管的是「**彻底不通**」⇒ 两者互补，不是重复。
#
# ⚠️ 为什么用「Git Data API」而不是「Contents API」：
#   Contents API 只能**逐文件**改（每个文件一次 commit）⇒ 多文件改动会产生
#   N 个碎 commit，PR diff 难读；Git Data API 一次提交**整棵树** ⇒ 干净。
#
# 本脚本的**安全设计**（每条都有对应的自证用例）：
#   ① **内容完整性闸门**：远端返回的 blob sha 必须与本地 `git hash-object`
#      **逐字相同**，否则**立即中止**（不建 ref、不建 commit）⇒
#      杜绝「base64 传输/编码坏了但看起来推成功了」。
#   ② **不静默改写历史**：目标分支已存在且**不等于**基线时，默认**拒绝**
#      （要 `--force`）⇒ 不会把别人的提交覆盖掉。
#   ③ **快进更新**：目标分支已存在且**等于**基线时 ⇒ 直接更新（正常推新提交）。
#   ④ 作者/提交者**不写死**：交给 GitHub 按 token 身份填（与普通 git push 同义）。
#
# 用法:
#   bash scripts/git-push-via-api.sh --repo <owner/name> --branch <branch> \
#        [--base <base-branch>] [--message <file>] [--force] -- <file>...
#   bash scripts/git-push-via-api.sh --selfcheck
#
# 退出码:
#   0 = 推送成功（并打印 commit sha）   1 = 失败   2 = 用法错误
set -uo pipefail

ROOT="${PB_PUSH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 1

# gh 可被替换（自证时注入假 gh ⇒ 全程离线）
GH_BIN="${PB_GH_BIN:-gh}"

SELFCHECK=0
REPO=""
BRANCH=""
BASE=""
MSG_FILE=""
FORCE=0
FILES_FILE=""
OK=0

cleanup() {
	if [ -n "$FILES_FILE" ]; then
		rm -f "$FILES_FILE"
	fi
	return 0
}
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; cleanup; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

usage() {
	cat >&2 <<'EOF'
用法:
  bash scripts/git-push-via-api.sh --repo <owner/name> --branch <branch> \
       [--base <base-branch>] [--message <file>] [--force] -- <file>...
  bash scripts/git-push-via-api.sh --selfcheck

说明:
  --base     目标分支的基线（默认取该仓默认分支；显式给更稳）
  --message  提交信息文件（不给则用 "chore: push via Git Data API"）
  --force    目标分支已存在且与 --base 不同时，允许改写（默认拒绝）
  --         其后为要推送的文件（相对仓根，路径原样进 commit）

退出码: 0 = 成功 / 1 = 失败 / 2 = 用法错误
EOF
}

die() {
	echo "✗ ${1}" >&2
	exit 1
}

# ───────────────────────── API 调用 ─────────────────────────
# api_get <path>：GET，输出原始 JSON；HTTP 错误 ⇒ 返回非零且 stdout 为空。
api_get() {
	"$GH_BIN" api "$1"
}

# api_post <path>：POST，请求体从 stdin 读，输出原始 JSON。
api_post() {
	"$GH_BIN" api --method POST "$1" --input -
}

# api_patch <path>：PATCH，请求体从 stdin 读，输出原始 JSON。
api_patch() {
	"$GH_BIN" api --method PATCH "$1" --input -
}

# json_field <字段名>：从 stdin 的 JSON 里取顶层字段（取不到就空串）。
json_field() {
	python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
if isinstance(d, dict):
    print(d.get(sys.argv[1], "") or "")
else:
    print("")' "$1"
}

# json_path <点分路径>：从 stdin 的 JSON 里取**嵌套**字段（取不到就空串）。
#
# ⚠️ 必须用它取 ref 的 sha：GitHub 的 `GET /repos/{o}/{r}/git/ref/heads/{b}`
#    返回的是 `{"ref":..., "object":{"sha":"...","type":"commit"}}`
#    ⇒ sha 在 **object.sha**（嵌套）⇒ 按顶层 `sha` 取**永远取不到**
#    （踩过：本地脚本一路"取不到基线"，而同一个端点用 jq 的 .object.sha 是好的）。
json_path() {
	python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, dict):
        d = d.get(k, "")
    else:
        d = ""
        break
print(d if isinstance(d, str) else "")' "$1"
}

# ───────────────────────── 主流程 ─────────────────────────
push_files() {
	local base_sha="" base_tree="" ref_exists=0 cur_sha=""
	local file b64 resp remote_sha local_sha mode
	local entries_file tree_json tree_sha commit_json commit_sha
	local msg

	if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
		usage
		exit 2
	fi
	if [ ! -s "$FILES_FILE" ]; then
		echo "✗ 没有要推送的文件" >&2
		exit 2
	fi
	if ! command -v "$GH_BIN" >/dev/null 2>&1 && [ ! -x "$GH_BIN" ]; then
		die "找不到 gh（PB_GH_BIN=${GH_BIN}）"
	fi

	# 基线：显式 --base 优先；否则取仓库默认分支
	if [ -z "$BASE" ]; then
		BASE="$(api_get "repos/${REPO}" 2>/dev/null | json_field default_branch)"
		[ -n "$BASE" ] || BASE="main"
	fi
	base_sha="$(api_get "repos/${REPO}/git/ref/heads/${BASE}" 2>/dev/null | json_path object.sha)"
	[ -n "$base_sha" ] || die "取不到基线 refs/heads/${BASE}（仓库名/分支名错？或权限不足？）"
	echo "基线 ${BASE} = ${base_sha}"

	# 目标分支已存在？
	cur_sha="$(api_get "repos/${REPO}/git/ref/heads/${BRANCH}" 2>/dev/null | json_path object.sha)"
	if [ -n "$cur_sha" ]; then
		ref_exists=1
		echo "目标分支已存在 = ${cur_sha}"
		if [ "$cur_sha" != "$base_sha" ] && [ "$FORCE" -ne 1 ]; then
			die "目标分支已存在且与基线 ${BASE} 不同（${cur_sha} ≠ ${base_sha}）⇒ 默认拒绝改写历史；要改写请加 --force"
		fi
	fi

	entries_file="$(mktemp)"
	# ── blob：逐个上传，并**逐字核对 sha** ──
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		[ -f "$file" ] || die "文件不存在: ${file}"
		mode="$(git ls-files -s -- "$file" 2>/dev/null | awk '{print $1}')"
		if [ -z "$mode" ]; then
			if [ -x "$file" ]; then mode=100755; else mode=100644; fi
		fi
		b64="$(base64 <"$file" | tr -d '\n')"
		resp="$(printf '{"content":"%s","encoding":"base64"}' "$b64" | api_post "repos/${REPO}/git/blobs")"
		remote_sha="$(printf '%s' "$resp" | json_field sha)"
		local_sha="$(git hash-object "$file")"
		if [ -z "$remote_sha" ]; then
			die "建 blob 失败: ${file}（API 返回: ${resp}）"
		fi
		if [ "$remote_sha" != "$local_sha" ]; then
			die "blob sha 与本地不一致（内容完整性闸门）: ${file} 远端=${remote_sha} 本地=${local_sha} ⇒ 中止，不建 commit/ref"
		fi
		echo "  blob ${file}  mode=${mode}  sha=${remote_sha}  ✓与本地逐字一致"
		printf '{"path":%s,"mode":"%s","type":"blob","sha":"%s"}\n' \
			"$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$file")" \
			"$mode" "$remote_sha" >>"$entries_file"
	done <"$FILES_FILE"

	# ── tree ──
	base_tree="$(api_get "repos/${REPO}/git/commits/${base_sha}" 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tree", {}).get("sha", ""))
except Exception:
    print("")')"
	[ -n "$base_tree" ] || die "取不到基线提交的 tree"

	tree_json="$(python3 -c 'import json,sys
tree = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
print(json.dumps({"base_tree": sys.argv[1], "tree": tree}))' "$base_tree" "$entries_file")"
	resp="$(printf '%s' "$tree_json" | api_post "repos/${REPO}/git/trees")"
	tree_sha="$(printf '%s' "$resp" | json_field sha)"
	[ -n "$tree_sha" ] || die "建 tree 失败（API 返回: ${resp}）"
	echo "tree = ${tree_sha}"
	rm -f "$entries_file"

	# ── commit ──
	if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
		msg="$(cat "$MSG_FILE")"
	else
		msg="chore: push via Git Data API (github.com 不可达时的兜底路径)"
	fi
	commit_json="$(python3 -c 'import json,sys
print(json.dumps({"message": sys.argv[1], "tree": sys.argv[2], "parents": [sys.argv[3]]}))' \
		"$msg" "$tree_sha" "$base_sha")"
	resp="$(printf '%s' "$commit_json" | api_post "repos/${REPO}/git/commits")"
	commit_sha="$(printf '%s' "$resp" | json_field sha)"
	[ -n "$commit_sha" ] || die "建 commit 失败（API 返回: ${resp}）"
	echo "commit = ${commit_sha}"

	# ── ref ──
	if [ "$ref_exists" -eq 1 ]; then
		printf '{"sha":"%s","force":false}' "$commit_sha" \
			| api_patch "repos/${REPO}/git/refs/heads/${BRANCH}" >/dev/null \
			|| die "更新 ref 失败: refs/heads/${BRANCH}"
		echo "✓ 已更新 refs/heads/${BRANCH}"
	else
		printf '{"ref":"refs/heads/%s","sha":"%s"}' "$BRANCH" "$commit_sha" \
			| api_post "repos/${REPO}/git/refs" >/dev/null \
			|| die "创建 ref 失败: refs/heads/${BRANCH}"
		echo "✓ 已创建 refs/heads/${BRANCH}"
	fi

	echo
	echo "BRANCH=${BRANCH}"
	echo "COMMIT_SHA=${commit_sha}"
	echo "开 PR：gh pr create --repo ${REPO} --head ${BRANCH} --base ${BASE}"
}

# ───────────────────────── 自证 ─────────────────────────
# 用**假 gh**（PB_GH_BIN 注入，全程离线）验证：
#   ① 正常路径 ⇒ rc=0 且 ref 真被创建；
#   ② blob sha 不符 ⇒ rc≠0 且**没建 ref**（内容完整性闸门有牙齿）；
#   ③ 分支已存在且与 base 不同 ⇒ rc≠0（不静默改写历史）；
#   ④ 分支已存在且等于 base ⇒ rc=0（快进更新）。
selfcheck() {
	local tmp fails=0 rc=0
	tmp="$(mktemp -d)"

	mk_fake_gh() {
		local dir="$1"
		mkdir -p "$dir"
		cat >"$dir/gh" <<'FAKEGH'
#!/usr/bin/env bash
# 假 gh：只实现本脚本用到的 5 类端点。
# GIT_FAKE_MODE=bad-blob   ⇒ blob 返回**错的** sha（模拟传输损坏）
# GIT_FAKE_BRANCH_SHA      ⇒ 目标分支已存在时的 sha（空 = 不存在）
# GIT_FAKE_BRANCH_SHA_NAME ⇒ 目标分支名
# GIT_FAKE_LOG             ⇒ 记录「建/改 ref」的调用（用于断言 ref 真没被动）
set -u
mode="${GIT_FAKE_MODE:-ok}"
method=GET
path=""
input=""
while [ $# -gt 0 ]; do
	case "$1" in
	--method)
		method="$2"
		shift 2
		;;
	--input)
		input="$2"
		shift 2
		;;
	--jq)
		shift 2
		;;
	-*)
		shift
		;;
	*)
		path="$1"
		shift
		;;
	esac
done
body=""
if [ "$input" = "-" ]; then
	body="$(cat)"
elif [ -n "$input" ] && [ -f "$input" ]; then
	body="$(cat "$input")"
fi
case "${method} ${path}" in
"GET repos/"*"/git/ref/heads/"*)
	branch="${path##*/git/ref/heads/}"
	if [ "$path" = "repos/${FAKE_REPO}/git/ref/heads/${FAKE_BASE}" ]; then
		printf '{"object":{"sha":"%s"}}\n' "${FAKE_BASE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
		exit 0
	fi
	if [ -n "${GIT_FAKE_BRANCH_SHA:-}" ] && [ "$branch" = "${GIT_FAKE_BRANCH_SHA_NAME:-}" ]; then
		printf '{"object":{"sha":"%s"}}\n' "$GIT_FAKE_BRANCH_SHA"
		exit 0
	fi
	printf '{"message":"Not Found"}\n'
	exit 1
	;;
"POST "*"/git/blobs")
	if [ "$mode" = "bad-blob" ]; then
		printf '{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}\n'
		exit 0
	fi
	sha="$(printf '%s' "$body" | python3 -c 'import base64,hashlib,json,sys
d = json.load(sys.stdin)
c = base64.b64decode(d["content"])
print(hashlib.sha1(b"blob %d\0" % len(c) + c).hexdigest())')"
	printf '{"sha":"%s"}\n' "$sha"
	exit 0
	;;
"POST "*"/git/trees")
	printf '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n'
	exit 0
	;;
"POST "*"/git/commits")
	printf '{"sha":"cccccccccccccccccccccccccccccccccccccccc"}\n'
	exit 0
	;;
"POST "*"/git/refs")
	if [ -n "${GIT_FAKE_LOG:-}" ]; then
		printf 'created-ref\n' >>"$GIT_FAKE_LOG"
	fi
	printf '{"ref":"refs/heads/x"}\n'
	exit 0
	;;
"PATCH "*"/git/refs/heads/"*)
	if [ -n "${GIT_FAKE_LOG:-}" ]; then
		printf 'updated-ref\n' >>"$GIT_FAKE_LOG"
	fi
	printf '{"ref":"refs/heads/x"}\n'
	exit 0
	;;
"GET repos/"*"/git/commits/"*)
	printf '{"tree":{"sha":"dddddddddddddddddddddddddddddddddddddddd"}}\n'
	exit 0
	;;
esac
printf '{"message":"fake gh: 未实现的端点 %s %s"}\n' "$method" "$path"
exit 1
FAKEGH
		chmod +x "$dir/gh"
	}

	run_case() {
		# run_case <mode> <branch_sha> <expect: 0=成功 1=失败> <label>
		local mode="$1" bsha="$2" expect="$3" label="$4" out
		mk_fake_gh "$tmp/bin"
		printf 'selfcheck commit\n' >"$tmp/msg.txt"
		printf 'hello\n' >"$tmp/f.txt"
		out="$(cd "$tmp" && PB_GH_BIN="$tmp/bin/gh" PB_PUSH_ROOT="$tmp" \
			FAKE_REPO="o/r" FAKE_BASE="main" FAKE_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
			GIT_FAKE_MODE="$mode" GIT_FAKE_BRANCH_SHA="$bsha" GIT_FAKE_BRANCH_SHA_NAME="feature" \
			GIT_FAKE_LOG="$tmp/reflog" \
			bash "$SCRIPT_PATH" --repo o/r --branch feature \
			--base main --message "$tmp/msg.txt" -- f.txt 2>&1)"
		rc=$?
		if [ "$expect" = "0" ] && [ "$rc" -ne 0 ]; then
			echo "  ✗ ${label}：期望成功，却 rc=${rc}"
			printf '%s\n' "$out" | sed 's/^/      /'
			fails=$((fails + 1))
			return 0
		fi
		if [ "$expect" = "1" ] && [ "$rc" -eq 0 ]; then
			echo "  ✗ ${label}：期望失败，却 rc=0"
			printf '%s\n' "$out" | sed 's/^/      /'
			fails=$((fails + 1))
			return 0
		fi
		echo "  ✓ ${label}（rc=${rc}）"
	}

	echo "── 用例 ①：正常路径 ⇒ 成功且 ref 真被创建"
	rm -f "$tmp/reflog"
	run_case ok "" 0 "正常推送"
	if [ -f "$tmp/reflog" ] && grep -q 'created-ref' "$tmp/reflog"; then
		echo "  ✓ ref 确实被创建（不是只建 commit）"
	else
		echo "  ✗ ref 没被创建 ⇒ 脚本没干它该干的事"
		fails=$((fails + 1))
	fi

	echo "── 用例 ②：blob sha 不符（模拟传输损坏）⇒ 必须失败且不建 ref"
	rm -f "$tmp/reflog"
	run_case bad-blob "" 1 "内容完整性闸门"
	if [ -f "$tmp/reflog" ] && grep -q 'created-ref' "$tmp/reflog"; then
		echo "  ✗ 内容已损坏却仍然建了 ref ⇒ 闸门形同虚设"
		fails=$((fails + 1))
	else
		echo "  ✓ 内容损坏时没有建 ref（闸门拦住了）"
	fi

	echo "── 用例 ③：分支已存在且与 base 不同 ⇒ 必须拒绝（不静默改写历史）"
	rm -f "$tmp/reflog"
	run_case ok "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" 1 "拒绝改写历史"
	if [ -f "$tmp/reflog" ]; then
		echo "  ✗ 拒绝改写时却仍然动了 ref"
		fails=$((fails + 1))
	else
		echo "  ✓ 拒绝时没有动 ref"
	fi

	echo "── 用例 ④：分支已存在且等于 base ⇒ 快进更新成功"
	rm -f "$tmp/reflog"
	run_case ok "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 0 "快进更新"
	if [ -f "$tmp/reflog" ] && grep -q 'updated-ref' "$tmp/reflog"; then
		echo "  ✓ 走的是更新（快进）而非重建"
	else
		echo "  ✗ 快进场景没有更新 ref"
		fails=$((fails + 1))
	fi

	rm -rf "$tmp"
	if [ "$fails" -ne 0 ]; then
		echo "✗ 自证失败：${fails} 项"
		exit 1
	fi
	echo "✓ 自证通过（正常⇒绿 / 内容损坏⇒红且不建 ref / 改写历史⇒红 / 快进⇒绿）"
}

# ───────────────────────── 参数解析 ─────────────────────────
# ⚠️ 不用数组装位置参数：macOS 自带 bash 3.2 在 `set -u` 下引用空数组元素
#    会报 unbound variable ⇒ 用具名变量 + 计数器（与 git-fetch-safe.sh 同款）。
SCRIPT_PATH="$ROOT/scripts/git-push-via-api.sh"
FILES_FILE="$(mktemp)"
want_val=""
after_ddash=0
for arg in "$@"; do
	if [ "$after_ddash" -eq 1 ]; then
		printf '%s\n' "$arg" >>"$FILES_FILE"
		continue
	fi
	if [ -n "$want_val" ]; then
		case "$want_val" in
		repo) REPO="$arg" ;;
		branch) BRANCH="$arg" ;;
		base) BASE="$arg" ;;
		message) MSG_FILE="$arg" ;;
		esac
		want_val=""
		continue
	fi
	case "$arg" in
	--selfcheck)
		SELFCHECK=1
		;;
	--repo)
		want_val=repo
		;;
	--branch)
		want_val=branch
		;;
	--base)
		want_val=base
		;;
	--message)
		want_val=message
		;;
	--force)
		FORCE=1
		;;
	--)
		after_ddash=1
		;;
	-*)
		echo "未知参数: ${arg}" >&2
		usage
		exit 2
		;;
	*)
		echo "多余参数: ${arg}" >&2
		usage
		exit 2
		;;
	esac
done

if [ "$SELFCHECK" -eq 1 ]; then
	selfcheck
	OK=1
	exit 0
fi

if [ ! -s "$FILES_FILE" ]; then
	echo "✗ 没有要推送的文件（用法：... -- <file>...）" >&2
	usage
	exit 2
fi

push_files
OK=1
