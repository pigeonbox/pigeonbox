#!/usr/bin/env python3
"""错误码**跨版本**兼容断言（L2 层：旧版前端在新契约下是否仍可用）。

为什么要有这道门禁（既有 check-errcode-cross-repo.sh 的缺口）
----------------------------------------------------------
既有门禁（PR #420）断言的是**当前**三端一致：

    契约 contracts/errcode/errcode.go ⇄ frontend-core 的 ERRCODE_KEY_MAP
    ⇄ 五门语言包的 errcode 块 ⇄ 已发布码基线 baseline.json

但它**没有**覆盖「已发布的旧版前端（旧的 contracts 契约）在新契约下是否仍
可用」。这三条不变量此前完全没有机器表达：

    ① 老前端在新契约下可用
       旧版 frontend-core 认识的码集合必须 ⊆ 新契约码集合——老前端认识的码，
       后端不能删、不能改语义；否则老前端会拿到它不认识的新语义。
    ② 码号不复用
       同一个数字在不同版本里不得对应**不同语义**（最阴险的一类：数字对得上、
       老前端却拿到了新语义）。
    ③ 只增不减
       从旧版本到新版本，已发布码集合必须**单调增**（旧版本有的码，新版本
       不能没有）。

判定形态 vs 跳过形态（三态，与既有门禁同口径）
------------------------------------------------
  · **判定形态**：历史版本与前端包都备齐 ⇒ 全量跑；
  · **跳过形态**：拿不到某个料（contracts 历史 / 已发布 tgz）⇒ 打印**明确的
    跳过原因**，只跑能判的部分——不让「没扫到」看起来像「扫过且通过」；
  · **CI 形态**：`--require-all` ⇒ 缺料即红（与 check-docs-consistency.sh 的
    「缺仓判红」同口径）。

用法：
    python3 scripts/errcode_cross_version.py validate --root <hub> \
        [--contracts <contracts仓路径>] [--frontend-pkg <tgz或已解包目录> ...] \
        [--require-all]
    python3 scripts/errcode_cross_version.py selfcheck --root <hub>
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile

# 契约常量声明：CodeXxx = 12345（只取 5 位码；CodeSuccess = 0 不算错误码）
CONST_RE = re.compile(r"^\s*(Code[A-Za-z0-9]+)\s*=\s*([0-9]{5})\b")
# 前端 ERRCODE_KEY_MAP 的键：10001: 'errcode.10001',
FRONT_KEY_RE = re.compile(r"^\s*([0-9]{5}):\s*['\"]errcode\.\1['\"]")


class MatrixError(Exception):
    """门禁自身不可用（缺料 / 形态不对）——与「判定不通过」严格区分。"""


def _ok(msg: str) -> None:
    print("  ✓ %s" % msg)


def _warn(msg: str) -> None:
    print("  ⚠ %s" % msg)


def _fail(msg: str) -> None:
    print("  ✗ %s" % msg)


# ── 契约码表读取 ────────────────────────────────────────────────────────
def read_contract_table(text: str) -> dict:
    """从 errcode.go 文本取「码 → 常量名」。"""
    table = {}
    for line in text.splitlines():
        m = CONST_RE.match(line)
        if not m:
            continue
        name, code = m.group(1), m.group(2)
        if code == "00000":
            continue
        table[code] = name
    return table


def contracts_revisions(contracts_dir: str, limit: int = 12) -> list:
    """列出 contracts 仓里改过 errcode/errcode.go 的历史版本（新→旧）。"""
    try:
        out = subprocess.run(
            ["git", "-C", contracts_dir, "log", "--format=%H %s",
             "--", "errcode/errcode.go"],
            capture_output=True, text=True, check=False, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise MatrixError("读 contracts git 历史失败: %s" % exc)
    if out.returncode != 0:
        raise MatrixError("git log 失败: %s" % (out.stderr or "").strip())
    revs = []
    for line in out.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            revs.append((parts[0], parts[1]))
        if len(revs) >= limit:
            break
    return revs


def contract_table_at(contracts_dir: str, rev: str) -> dict:
    out = subprocess.run(
        ["git", "-C", contracts_dir, "show", "%s:errcode/errcode.go" % rev],
        capture_output=True, text=True, check=False, timeout=60,
    )
    if out.returncode != 0:
        raise MatrixError("git show %s 失败: %s" % (rev, (out.stderr or "").strip()))
    return read_contract_table(out.stdout)


# ── 前端码表读取 ────────────────────────────────────────────────────────
def frontend_codes_from_pkg(pkg_path: str) -> dict:
    """从已发布 frontend-core 包里取「码 → i18n key」。

    支持两种形态：tgz 归档 / 已解包目录。
    """
    if os.path.isdir(pkg_path):
        base = pkg_path
        for cand in ("package",):
            if os.path.isdir(os.path.join(base, cand)):
                base = os.path.join(base, cand)
                break
        target = None
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn == "api-interceptor.ts":
                    target = os.path.join(root, fn)
                    break
            if target:
                break
        if not target:
            raise MatrixError("前端包里找不到 api-interceptor.ts: %s" % pkg_path)
        with open(target, encoding="utf-8") as fh:
            return read_frontend_keys(fh.read())

    if not os.path.isfile(pkg_path):
        raise MatrixError("前端包不存在: %s" % pkg_path)
    try:
        with tarfile.open(pkg_path, "r:gz") as tf:
            for member in tf.getmembers():
                if member.name.endswith("api-interceptor.ts"):
                    fh = tf.extractfile(member)
                    if fh is None:
                        continue
                    with fh:
                        return read_frontend_keys(fh.read().decode("utf-8", "replace"))
    except tarfile.TarError as exc:
        raise MatrixError("解包失败 %s: %s" % (pkg_path, exc))
    raise MatrixError("前端包里找不到 api-interceptor.ts: %s" % pkg_path)


def read_frontend_keys(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        m = FRONT_KEY_RE.match(line)
        if m:
            out[m.group(1)] = "errcode.%s" % m.group(1)
    return out


def frontend_contracts_pin(pkg_path: str) -> str:
    """从已发布前端包的 package.json 读它钉的 contracts 版本。"""
    raw = None
    if os.path.isdir(pkg_path):
        for cand in (
            os.path.join(pkg_path, "package.json"),
            os.path.join(pkg_path, "package", "package.json"),
        ):
            if os.path.isfile(cand):
                raw = cand
                break
    elif os.path.isfile(pkg_path):
        try:
            with tarfile.open(pkg_path, "r:gz") as tf:
                for member in tf.getmembers():
                    if member.name.endswith("package.json") and member.name.count("/") <= 2:
                        fh = tf.extractfile(member)
                        if fh is None:
                            continue
                        with fh:
                            raw_data = fh.read().decode("utf-8", "replace")
                        pkg = json.loads(raw_data)
                        dep = (pkg.get("dependencies") or {}).get("@pigeonbox/contracts", "")
                        m = re.search(r"download/(v[0-9][^/]*)/", dep)
                        if m:
                            return m.group(1)
                        return ""
        except (tarfile.TarError, ValueError, OSError) as exc:
            raise MatrixError("读前端包 package.json 失败 %s: %s" % (pkg_path, exc))
    if not raw:
        raise MatrixError("前端包里找不到 package.json: %s" % pkg_path)
    with open(raw, encoding="utf-8") as fh:
        pkg = json.load(fh)
    dep = (pkg.get("dependencies") or {}).get("@pigeonbox/contracts", "")
    m = re.search(r"download/(v[0-9][^/]*)/", dep)
    return m.group(1) if m else ""


# ── 判定 ────────────────────────────────────────────────────────────────
def check_cross_version(current: dict, older: dict, label: str) -> list:
    """三条不变量：
       ① 老版本有的码，新版本不能没有（只增不减）
       ② 同号常量的名字不得变（码号不复用）
    """
    problems = []
    missing = sorted(set(older) - set(current))
    for code in missing:
        problems.append("%s：码 %s（%s）在新契约里消失了 ⇒ 违反「只增不减」"
                        % (label, code, older[code]))
    for code in sorted(set(older) & set(current)):
        if older[code] != current[code]:
            problems.append(
                "%s：码 %s 的常量名从 %s 变成 %s ⇒ 码号被复用给另一种语义"
                % (label, code, older[code], current[code]))
    return problems


def check_frontend_usable(frontend: dict, current: dict, label: str) -> list:
    """老前端在新契约下可用：老前端认识的码必须仍在新契约里。"""
    problems = []
    for code in sorted(set(frontend) - set(current)):
        problems.append("%s：老前端认识的码 %s 在新契约里不存在 ⇒ 老前端会拿到"
                        "它不认识的新语义" % (label, code))
    return problems


def cmd_validate(opts) -> int:
    root = os.path.abspath(opts.root)
    contracts_dir = os.path.abspath(opts.contracts or os.path.join(root, "contracts"))
    require_all = opts.require_all

    if not os.path.isdir(os.path.join(contracts_dir, ".git")) and \
            not os.path.isdir(contracts_dir):
        msg = "contracts 仓不在 %s" % contracts_dir
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 跳过契约侧判定（不是「扫过且通过」）")
        return 0

    # 当前契约码表
    current_path = os.path.join(contracts_dir, "errcode", "errcode.go")
    if not os.path.isfile(current_path):
        msg = "契约真相源不存在 %s" % current_path
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 跳过契约侧判定")
        return 0
    with open(current_path, encoding="utf-8") as fh:
        current = read_contract_table(fh.read())
    if not current:
        raise MatrixError("契约码表为空（真相源形态变了？）")
    _ok("当前契约码表：%d 个码" % len(current))

    problems = []
    checked_versions = 0

    # ── 跨版本：只增不减 + 码号不复用 ─────────────────────────────────
    try:
        revs = contracts_revisions(contracts_dir)
    except MatrixError as exc:
        msg = str(exc)
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 跳过跨版本判定")
        revs = []

    for rev, subject in revs:
        try:
            older = contract_table_at(contracts_dir, rev)
        except MatrixError:
            continue
        if not older or older == current:
            continue
        checked_versions += 1
        problems.extend(check_cross_version(current, older, "历史版本 %s（%s）" % (rev[:9], subject[:40])))

    if checked_versions == 0:
        msg = "没有可比对的历史契约版本"
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 跨版本判定未生效")
    else:
        _ok("跨版本比对：%d 个历史版本（只增不减 + 码号不复用）" % checked_versions)

    # ── 跨版本前端：老前端在新契约下可用 ─────────────────────────────
    pkgs = opts.frontend_pkg or []
    checked_pkgs = 0
    for pkg in pkgs:
        try:
            codes = frontend_codes_from_pkg(pkg)
            pin = frontend_contracts_pin(pkg)
        except MatrixError as exc:
            msg = str(exc)
            if require_all:
                raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
            _warn(msg + " ⇒ 跳过该前端包")
            continue
        if not codes:
            msg = "前端包里没解析出码表：%s" % pkg
            if require_all:
                raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
            _warn(msg)
            continue
        checked_pkgs += 1
        problems.extend(check_frontend_usable(codes, current, "已发布前端 %s（钉 contracts %s）" % (os.path.basename(pkg), pin or "?")))
        # 老前端认识的码，其 i18n key 必须仍是 errcode.<同码>（防手滑写错）
        for code, key in sorted(codes.items()):
            if key != "errcode.%s" % code:
                problems.append("已发布前端 %s：码 %s 的 i18n key 是 %s（应为 errcode.%s）"
                                % (os.path.basename(pkg), code, key, code))

    if pkgs and checked_pkgs == 0:
        msg = "没有任何前端包被成功判定"
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 前端跨版本判定未生效")
    elif checked_pkgs:
        _ok("已发布前端比对：%d 个包（老前端在新契约下仍可用）" % checked_pkgs)
    elif require_all:
        # 「一个包都没给」也是**缺料**：--require-all 的语义是「本次必须真的判定
        # 了前端跨版本面」，否则这道门禁在 CI 里会退化成「只跑契约侧」
        # ——看起来在判跨版本，实际没判前端。
        raise MatrixError(
            "未提供任何已发布前端包（--frontend-pkg），无法判定「老前端在新契约下"
            "是否仍可用」（--require-all ⇒ 缺料即红）")
    else:
        # 软形态：显式说明「这一面没判」，不让「没扫到」看起来像「扫过且通过」。
        _warn("未提供已发布前端包 ⇒ **跳过**「老前端在新契约下是否仍可用」这一面"
              "（不是「扫过且通过」）")

    if problems:
        for p in problems:
            _fail(p)
        print("\n✗ 错误码跨版本兼容断言失败（%d 项）" % len(problems))
        return 1

    print("\n✓ 错误码跨版本兼容断言通过")
    return 0


def cmd_selfcheck(opts) -> int:
    """负对照：注入坏形态 ⇒ 必须判红。"""
    root = os.path.abspath(opts.root)
    contracts_dir = os.path.abspath(opts.contracts or os.path.join(root, "contracts"))
    current_path = os.path.join(contracts_dir, "errcode", "errcode.go")
    if not os.path.isfile(current_path):
        raise MatrixError("契约真相源不存在：%s" % current_path)
    with open(current_path, encoding="utf-8") as fh:
        current = read_contract_table(fh.read())
    if not current:
        raise MatrixError("契约码表为空")

    tmp = tempfile.mkdtemp(prefix="pb-errcode-xver-")
    sc_rc = 0

    def expect_red(name: str, current_tbl: dict, older: dict, frontend: dict) -> None:
        nonlocal sc_rc
        problems = []
        problems.extend(check_cross_version(current_tbl, older, name))
        problems.extend(check_frontend_usable(frontend, current_tbl, name))
        # 前端 i18n key 逐项核对（防手滑把 10001 写成 10010）
        for code, key in sorted(frontend.items()):
            if key != "errcode.%s" % code:
                problems.append("%s：老前端码 %s 的 i18n key 是 %s（应为 errcode.%s）"
                                % (name, code, key, code))
        if problems:
            print("  ✓ %s：坏形态被判红（%d 项）" % (name, len(problems)))
            for p in problems[:2]:
                print("      %s" % p)
        else:
            print("  ✗ %s：坏形态被放行了（判据没有牙齿）" % name)
            sc_rc = 1

    # 好形态：真实历史版本 + 真实前端码表必须放行
    #
    # 构造要点（负对照必须真的落在判据上）：
    #   · 老版本表必须是新版本的**真子集**（否则「只增不减」判据无交集可判）；
    #   · 前端码表必须与新版本码表**同集**（否则「老前端可用」判据无交集可判）；
    #   · 坏形态要**改交集里的那一项**，不是改集合外的项。
    subset = {k: v for k, v in list(current.items())[:5]}
    good_older = dict(subset)
    good_frontend = {k: ("errcode.%s" % k) for k in subset}
    problems = check_cross_version(current, good_older, "好形态")
    problems += check_frontend_usable(good_frontend, current, "好形态")
    if problems:
        print("  ✗ 好形态被误判红（%d 项）" % len(problems))
        sc_rc = 1
    else:
        print("  ✓ 好形态：放行")

    # 坏形态①：**新版本**少了老版本已发布的一个码（只增不减被破）
    #
    # 方向要点：判据是「老版本 ⊆ 新版本」⇒ 要造出违反，只能让**新版本**缺码
    # （从老版本删码只会让它仍是子集，判据看不见——负对照必须落在判据上）。
    victim = sorted(good_older)[0]
    current_missing = {k: v for k, v in current.items() if k != victim}
    expect_red("坏形态①新版本删已发布码", current_missing, good_older, good_frontend)

    # 坏形态②：同号常量改名（码号复用）——老版本与新版本同名不同义
    reused = dict(good_older)
    victim = sorted(reused)[0]
    reused[victim] = "CodeSomethingElse"
    expect_red("坏形态②码号复用", current, reused, good_frontend)

    # 坏形态③：老前端认识的码在新契约里不存在
    ghost = dict(good_frontend)
    ghost["99999"] = "errcode.99999"
    expect_red("坏形态③老前端认了新契约没有的码", current, good_older, ghost)

    # 坏形态④：老前端某码的 i18n key 写错（防手滑）
    bad_key = dict(good_frontend)
    victim = sorted(bad_key)[0]
    other = sorted(bad_key)[1] if len(bad_key) > 1 else "10010"
    bad_key[victim] = "errcode.%s" % other
    expect_red("坏形态④老前端 i18n key 写错", current, good_older, bad_key)

    if sc_rc != 0:
        print("\n✗ 跨版本断言自检未通过：至少一种形态的判定与预期不符")
        return 1
    print("\n✓ 错误码跨版本断言自检通过（好形态放行 + 4 种坏形态全部判红）")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="错误码跨版本兼容断言（L2）")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_val = sub.add_parser("validate", help="跑跨版本判定")
    p_val.add_argument("--root", required=True)
    p_val.add_argument("--contracts", default="")
    p_val.add_argument("--frontend-pkg", action="append", default=[])
    p_val.add_argument("--require-all", action="store_true")

    p_self = sub.add_parser("selfcheck", help="负对照：注入坏形态必须判红")
    p_self.add_argument("--root", required=True)
    p_self.add_argument("--contracts", default="")

    opts = parser.parse_args(argv)
    try:
        if opts.cmd == "validate":
            return cmd_validate(opts)
        return cmd_selfcheck(opts)
    except MatrixError as exc:
        print("✗ %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
