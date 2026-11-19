#!/usr/bin/env bash
#
# git 领域的「正确姿势」：默认分支、脏仓守卫、浅克隆安全取 tag、
# 受控的快进/重置、worktree 检出。
#
# 为什么不能靠通用管道拼 —— 每一条都在生态里踩过坑：
#   - 硬编码 main：有的仓默认分支是 master ⇒ 报「couldn't find remote ref main」，
#     看起来像网络问题，其实是分支名错了；
#   - 不查脏仓就 pull：同机并行会话的工作会被无声冲掉；
#   - 浅克隆里 git describe --tags 退化成哈希 ⇒ 产物版本变成 (devel)；
#   - 快进与强制重置混用：会丢本地提交。
#
# 这里的每个函数都把「正确姿势」固化下来：会改工作树的动作**一律先过脏仓守卫**，
# 会丢东西的动作**必须显式**（名字里就写着 hard）。

# _sk_git_need_repo REPO —— 这是不是一个能用的 git 仓
# @exitcode 0 是；3 不是
_sk_git_need_repo() {
  local __repo="${1:-}"
  if [ -z "$__repo" ]; then
    log_error "$(_t 'the repository path is required')"
    return "$SK_PRECOND"
  fi
  if ! command -v git >/dev/null 2>&1; then
    log_error "$(_t 'Required command not found'): git"
    return "$SK_PRECOND"
  fi
  if [ ! -d "$__repo" ]; then
    log_error "$(_t 'target directory does not exist'): $__repo"
    return "$SK_PRECOND"
  fi
  if ! git -C "$__repo" rev-parse --git-dir >/dev/null 2>&1; then
    log_error "$(_t 'not a git repository'): $__repo"
    return "$SK_PRECOND"
  fi
  return 0
}

# _sk_git_describe EXACT REPO —— 取 HEAD 上的 tag
# @exitcode 0 成功（stdout 是 tag）；1 取不到
_sk_git_describe() {
  local __exact="${1:-}" __repo="${2:-}" __args=""
  if [ "$__exact" = "1" ]; then
    __args="--exact-match"
  fi
  # 不带 --dirty：版本号要的就是 tag 本身。工作区脏不脏是另一件事
  #（git_is_dirty 说了算），混进版本号里会让「v1.0.0」变成「v1.0.0-dirty」。
  # shellcheck disable=SC2086
  git -C "$__repo" describe --tags $__args 2>/dev/null || return 1
}

# git_default_branch REPO —— 解析默认分支
#
# 顺序：origin/HEAD 的符号引用（正常 clone 都有）→ 本地已有的 origin/main 或
# origin/master → 远端只有一个分支时就是它 → 多个远端分支且认不出 ⇒ 报歧义。
# 认不出就报错，不猜 —— 猜错了的代价是「拉错分支」。
#
# 只看 origin 这一个远端：默认分支是「这个仓的」概念，多远端时猜哪个远端
# 同样是猜 —— 与其猜，不如让调用方显式指定分支名。
#
# @exitcode 0 成功（stdout 是分支名）
# @exitcode 3 解析不出来（不是 git 仓 / 远端分支有歧义 / 没有远端）
# @stability experimental
git_default_branch() {
  local __repo="${1:-}" __ref __found="" __count=0
  _sk_git_need_repo "$__repo" || return $?
  # 1) origin/HEAD（正常 clone 建的符号引用）
  __ref=$(git -C "$__repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$__ref" ]; then
    printf '%s\n' "${__ref#origin/}"
    return 0
  fi
  # 2) 老仓没建 origin/HEAD ⇒ 看本地有没有 origin/main / origin/master
  #    两个都认得时优先 main（GitHub / GitLab 新仓的默认分支都是 main；
  #    认不出优先级才是「猜」，main 优先是约定不是猜）
  for __ref in main master; do
    if git -C "$__repo" show-ref --verify --quiet "refs/remotes/origin/$__ref"; then
      printf '%s\n' "$__ref"
      return 0
    fi
  done
  # 3) 远端分支只有一个 ⇒ 就是它
  while IFS= read -r __ref; do
    [ -n "$__ref" ] || continue
    case "$__ref" in
      */HEAD) continue ;;
    esac
    __count=$((__count + 1))
    [ -n "$__found" ] || __found="$__ref"
  done <<EOF
$(git -C "$__repo" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin 2>/dev/null)
EOF
  if [ "$__count" = "1" ]; then
    printf '%s\n' "$__found"
    return 0
  fi
  if [ "$__count" -gt 1 ]; then
    log_error "$(_t 'the default branch is ambiguous; several remote branches exist'): $__repo"
    return "$SK_PRECOND"
  fi
  log_error "$(_t 'the default branch cannot be resolved'): $__repo"
  return "$SK_PRECOND"
}

# git_is_dirty REPO —— 脏仓守卫
#
# 有未提交改动（含未跟踪文件）⇒ 退出码 1，stdout 是 porcelain 摘要。
# 未跟踪文件也算脏：另一个会话刚建的文件，被 pull 冲掉一样是事故。
#
# @exitcode 0 干净
# @exitcode 1 有未提交改动
# @exitcode 3 不是 git 仓
# @stability experimental
git_is_dirty() {
  local __repo="${1:-}" __out
  _sk_git_need_repo "$__repo" || return $?
  __out=$(git -C "$__repo" status --porcelain --untracked-files=normal 2>/dev/null) || {
    log_error "$(_t 'cannot read the repository status'): $__repo"
    return "$SK_PRECOND"
  }
  if [ -n "$__out" ]; then
    printf '%s\n' "$__out"
    return 1
  fi
  return 0
}

# git_tag REPO —— 取版本号（浅克隆安全）
#
# 浅克隆里 git describe --tags 会退化成哈希 ⇒ 产物版本变成 (devel)。
# 三层回退：
#   1) HEAD 上的精确 tag；
#   2) 浅克隆且拿不到 ⇒ 补取 tag（tag 跟不下来是浅克隆的常态）；
#   3) 还是拿不到 ⇒ 补深度（--deepen）：tag 指向的是**祖先**提交时，
#      只补 tag 不够 —— 浅边界把祖先链截断了，describe 仍认不出这个 tag
#      是不是 HEAD 的祖先，于是仍然失败。
# 第 2、3 步要联网；不想联网就设 SHELLKIT_GIT_NO_FETCH=1。
#
# 都取不到时退到「最近的可达 tag」：那个 tag **可能在祖先上**（HEAD 已经
# 往前走了几个提交）—— 它是这条提交链的版本号，不是 HEAD 自己的版本号。
#
# @exitcode 0 成功（stdout 是 tag；HEAD 上没有精确 tag 时是最近的可达 tag）
# @exitcode 3 拿不到（不是 git 仓 / 没有 tag / 浅克隆且不允许联网）
# @stability experimental
git_tag() {
  local __repo="${1:-}" __tag="" __shallow="false" __deepen=""
  _sk_git_need_repo "$__repo" || return $?
  __tag=$(_sk_git_describe 1 "$__repo" 2>/dev/null || true)
  if [ -z "$__tag" ]; then
    __shallow=$(git -C "$__repo" rev-parse --is-shallow-repository 2>/dev/null || printf 'false')
    if [ "$__shallow" = "true" ] && [ "${SHELLKIT_GIT_NO_FETCH:-0}" != "1" ]; then
      # 浅克隆：tag 没跟下来 ⇒ 补取一次（拉不拉得动由 git 说了算）
      git -C "$__repo" fetch --tags --quiet --force >/dev/null 2>&1 || true
      __tag=$(_sk_git_describe 1 "$__repo" 2>/dev/null || true)
      if [ -z "$__tag" ]; then
        # tag 拿到了但 describe 还是不认：tag 指向的是浅边界之外的祖先
        # ⇒ 把边界往回推一段，让祖先链接回来。
        # 深度取 SHELLKIT_GIT_DEEPEN（默认 50）；推不动就当没有（git 说了算）。
        __deepen="${SHELLKIT_GIT_DEEPEN:-50}"
        case "$__deepen" in
          '' | *[!0-9]*) __deepen=50 ;;
        esac
        git -C "$__repo" fetch --deepen="$__deepen" --quiet >/dev/null 2>&1 || true
        __tag=$(_sk_git_describe 1 "$__repo" 2>/dev/null || true)
      fi
    fi
  fi
  if [ -z "$__tag" ]; then
    # 退一步：最近的 tag（不一定在 HEAD 上，可能在祖先上）
    __tag=$(git -C "$__repo" describe --tags --abbrev=0 2>/dev/null || true)
  fi
  if [ -z "$__tag" ]; then
    log_error "$(_t 'no tag found'): $__repo"
    return "$SK_PRECOND"
  fi
  printf '%s\n' "$__tag"
}

# git_fetch REPO BRANCH —— 受控取数
#
# 脏仓直接拒绝：同机并行会话的工作不能被无声冲掉（我们被冲掉过两次）。
# 只取不改工作树，但仍然守脏仓 —— 「干净才动」是这一族函数的统一口径。
#
# @exitcode 0 成功
# @exitcode 2 用法错
# @exitcode 3 脏仓 / 不是 git 仓
# @exitcode 1 git 自己失败
# @stability experimental
git_fetch() {
  local __repo="${1:-}" __branch="${2:-}"
  _sk_git_need_repo "$__repo" || return $?
  if [ -z "$__branch" ]; then
    log_error "$(_t 'the branch name is required')"
    return "$SK_USAGE"
  fi
  if ! git_is_dirty "$__repo" >/dev/null; then
    log_error "$(_t 'the repository has uncommitted changes'): $__repo"
    return "$SK_PRECOND"
  fi
  git -C "$__repo" fetch --quiet origin "$__branch" || return 1
  return 0
}

# git_fast_forward REPO BRANCH —— 只快进，绝不丢本地提交
#
# 能快进 ⇒ merge --ff-only；不能快进（本地有分叉）⇒ **明确报错，不动工作树**。
# 「快进 vs 强制重置」的区别就在这里：强制重置会丢本地提交，所以它另有
# 一个名字更直白的函数（git_reset_hard），要的人自己明说。
#
# **只快进当前工作树所在的分支**：本地已有这个分支、而 HEAD 不在它上面时，
# 明确报错、不动工作树。不这么判的后果是「把 origin/main 合进当前分支」还
# 返回 0 —— 调用方以为快进了 main，其实被合进去的是另一个分支，
# 两边的提交也搅在了一起（假成功比报错坏得多）。
#
# @exitcode 0 成功
# @exitcode 2 用法错
# @exitcode 3 脏仓 / 不能快进 / 远端分支不存在 / HEAD 不在目标分支上
# @exitcode 1 git 自己失败
# @stability experimental
git_fast_forward() {
  local __repo="${1:-}" __branch="${2:-}" __remote __head
  _sk_git_need_repo "$__repo" || return $?
  if [ -z "$__branch" ]; then
    log_error "$(_t 'the branch name is required')"
    return "$SK_USAGE"
  fi
  if ! git_is_dirty "$__repo" >/dev/null; then
    log_error "$(_t 'the repository has uncommitted changes'): $__repo"
    return "$SK_PRECOND"
  fi
  __remote="origin/$__branch"
  if ! git -C "$__repo" show-ref --verify --quiet "refs/remotes/$__remote"; then
    log_error "$(_t 'the remote branch does not exist'): $__remote"
    return "$SK_PRECOND"
  fi
  if ! git -C "$__repo" show-ref --verify --quiet "refs/heads/$__branch"; then
    # 本地还没有这个分支 ⇒ 从远端建一个并跟住。
    # 新建分支不动当前分支的提交，所以这里不需要「HEAD 必须是目标分支」。
    git -C "$__repo" checkout --quiet -b "$__branch" --track "$__remote" || return 1
    return 0
  fi
  # 本地有这个分支 ⇒ 只能快进**当前工作树所在的那个分支**
  __head=$(git -C "$__repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$__head" ]; then
    log_error "$(_t 'the working tree is in a detached HEAD state'): $__repo"
    return "$SK_PRECOND"
  fi
  if [ "$__head" != "$__branch" ]; then
    log_error "$(_t 'the working tree is on another branch'): $__head (expected $__branch)"
    return "$SK_PRECOND"
  fi
  if ! git -C "$__repo" merge --ff-only --quiet "$__remote"; then
    log_error "$(_t 'the branch cannot fast-forward; local commits would be lost'): $__branch"
    return "$SK_PRECOND"
  fi
  return 0
}

# git_reset_hard REPO REF —— 显式的破坏性重置
#
# 会丢本地提交 —— 名字里就写着 hard，调用方必须自己确认过。
# 想要「不丢」的语义就用 git_fast_forward。
#
# @exitcode 0 成功
# @exitcode 2 用法错
# @exitcode 3 不是 git 仓
# @exitcode 1 git 自己失败
# @stability experimental
git_reset_hard() {
  local __repo="${1:-}" __ref="${2:-}"
  _sk_git_need_repo "$__repo" || return $?
  if [ -z "$__ref" ]; then
    log_error "$(_t 'the target reference is required')"
    return "$SK_USAGE"
  fi
  git -C "$__repo" reset --hard --quiet "$__ref" || return 1
  return 0
}

# git_worktree_add REPO PATH BRANCH [START_POINT] —— 检出到工作树
#
# 多仓并行改动的标准做法：每个改动一个工作树，互不干扰，
# 也不会把别人的工作区冲掉（这正是脏仓守卫要防的那类事故）。
#
# PATH 不能落在仓里：工作树建在仓内 ⇒ 主仓多出一堆未跟踪文件 ⇒ 主仓**永久变脏**
# ⇒ 脏仓守卫把取数与快进全锁死（而且没人知道为什么）。也不能是软链，
# 父目录必须已经存在（git 自己也要求）。
#
# BRANCH 本地已有 ⇒ 检出那个分支（此时不能再给 START_POINT）；没有 ⇒ 新建并跟住。
#
# @exitcode 0 成功
# @exitcode 2 用法错
# @exitcode 3 不是 git 仓 / 路径不合法（落在仓里 / 是软链 / 父目录不存在）
# @exitcode 1 git 自己失败
# @stability experimental
git_worktree_add() {
  local __repo="${1:-}" __path="${2:-}" __branch="${3:-}" __start="${4:-}"
  local __base="HEAD" __abs __pdir __wt __top __common __bare __b1 __b2 __b
  _sk_git_need_repo "$__repo" || return $?
  if [ -z "$__path" ] || [ -z "$__branch" ]; then
    log_error "$(_t 'Usage'): git_worktree_add REPO PATH BRANCH [START_POINT]"
    return "$SK_USAGE"
  fi
  if [ -L "$__path" ]; then
    log_error "$(_t 'refusing to write through a symlink'): $__path"
    return "$SK_PRECOND"
  fi
  # git -C REPO 会把工作目录切到 REPO ⇒ 相对路径是相对 REPO 解析的
  case "$__path" in
    /*) __abs="$__path" ;;
    *) __abs="$__repo/$__path" ;;
  esac
  __pdir=$(dirname "$__abs")
  if [ ! -d "$__pdir" ]; then
    log_error "$(_t 'target directory does not exist'): $__pdir"
    return "$SK_PRECOND"
  fi
  # 父目录解析成真实路径（pwd -P）：中间的软链也要算进去 ——
  # 软链指向仓内 ⇒ 一样是「建在仓里」
  __pdir=$(cd "$__pdir" 2>/dev/null && pwd -P) || {
    log_error "$(_t 'cannot resolve the target directory'): $__pdir"
    return "$SK_PRECOND"
  }
  __wt="$__pdir/$(basename "$__abs")"
  # 仓边界：这个仓的工作树根；若这是链接工作树，还有主仓的根
  __top=$(git -C "$__repo" rev-parse --show-toplevel 2>/dev/null || true)
  __bare=$(git -C "$__repo" rev-parse --is-bare-repository 2>/dev/null || printf 'false')
  __common=$(git -C "$__repo" rev-parse --git-common-dir 2>/dev/null || true)
  case "$__common" in
    /*) : ;;
    *) __common="$__repo/$__common" ;;
  esac
  __common=$(cd "$__common" 2>/dev/null && pwd -P) || __common=""
  __b1=""
  __b2=""
  if [ "$__bare" = "true" ]; then
    # 裸仓：仓目录本身就是边界（父目录不是 —— 那会把整个 /tmp 都封掉）
    __b1="$__common"
  else
    if [ -n "$__top" ]; then
      __b1=$(cd "$__top" 2>/dev/null && pwd -P) || __b1=""
    fi
    if [ -n "$__common" ]; then
      __b2=$(dirname "$__common")
    fi
  fi
  for __b in "$__b1" "$__b2"; do
    [ -n "$__b" ] || continue
    if [ "$__wt" = "$__b" ] || _sk_fs_in_dir "$__b" "$__wt"; then
      log_error "$(_t 'the worktree path must be outside the repository'): $__wt"
      return "$SK_PRECOND"
    fi
  done
  if git -C "$__repo" show-ref --verify --quiet "refs/heads/$__branch"; then
    if [ -n "$__start" ]; then
      log_error "$(_t 'the branch already exists; the start point must be omitted'): $__branch"
      return "$SK_USAGE"
    fi
    if ! git -C "$__repo" worktree add --quiet "$__wt" "$__branch"; then
      return 1
    fi
    return 0
  fi
  # 起点默认是当前 HEAD（不是仓库路径 —— 那是 invalid reference）
  if [ -n "$__start" ]; then
    __base="$__start"
  fi
  if ! git -C "$__repo" worktree add --quiet -b "$__branch" "$__wt" "$__base"; then
    return 1
  fi
  return 0
}
