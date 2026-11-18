#!/usr/bin/env python3
"""错误码**跨版本**兼容断言（L2 层：旧版前端在新契约下是否仍可用）。

为什么要有这道门禁（既有 check-errcode-cross-repo.sh 的缺口）
-----------------------------------------------------------
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

四种结论（严格区分，别把「没判」当成「判过且通过」）
--------------------------------------------------
  · **判定通过**（退出码 0）：所有面都真的判了，且都过。
  · **判定不通过**（退出码 1）：某条不变量被破（只增不减 / 码号复用 /
    老前端认了新契约没有的码 / 前端 i18n key 写错 / 清单漂移）。
  · **判据不可用**（退出码 3）：**缺料**（契约仓不在、历史拿不到、前端包
    读不出）⇒ 这一面**没有判**。退出码非 0 且**不打印「通过」**——
    「读不到素材」绝不等于「扫过且通过」。
  · **门禁自身不可用**（退出码 2）：参数/形态不对（MatrixError）。

素材来源（已发布版本清单 = scripts/errcode-published-versions.json）
--------------------------------------------------------------------
  · contracts：**已发布 tag**（清单里的 published_tags）⇒ 相邻两版做
    「只增不减 + 码号不复用」对账；另加 contracts 仓 git 历史（含未发布
    提交）对比当前码表。
  · frontend-core：**已发布 tgz**（--frontend-pkg 传入）⇒ 老前端码集必须
    ⊆ 新契约码集，且 ⊆ 它**自己钉的那版**契约的码集。

用法：
    python3 scripts/errcode_cross_version.py validate --root <hub> \
        [--contracts <contracts仓路径>] [--manifest <已发布版本清单>] \
        [--frontend-pkg <tgz或已解包目录> ...] [--require-all]
    python3 scripts/errcode_cross_version.py selfcheck --root <hub>
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import types

# 契约常量声明：CodeXxx = 12345（只取 5 位码；CodeSuccess = 0 不算错误码）
CONST_RE = re.compile(r"^\s*(Code[A-Za-z0-9]+)\s*=\s*([0-9]{5})\b")

# 前端 ERRCODE_KEY_MAP 的**块**定位：只解析这张表，不碰同文件的其它映射
# （HTTP_FALLBACK_KEY_MAP / SEGMENT_FALLBACK_KEY_MAP / DYNAMIC_MESSAGE_CODES）。
FRONT_MAP_OPEN_RE = re.compile(r"ERRCODE_KEY_MAP[^\n=]*=\s*\{")
# 块内条目：10001: 'errcode.10001',（值是字面量字符串；允许行尾注释）
FRONT_ENTRY_RE = re.compile(
    r"^\s*([0-9]{5})\s*:\s*['\"]([^'\"]*)['\"]\s*,?\s*(?://.*)?$")
# 块内「像条目但值不是字面量」的形态：10001: someVar, ⇒ 解析出来值记 None
FRONT_ENTRY_LOOSE_RE = re.compile(r"^\s*([0-9]{5})\s*:")


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
def read_frontend_keys(text: str) -> dict:
    """从前端包源码里取 ERRCODE_KEY_MAP 的「码 → i18n key」。

    ★ 为什么必须**解析出键和值**再断言：
      旧实现把「值必须形如 errcode.<同码>」写进了**正则**⇒ 手滑成
      10001: 'errcode.10002' 的那一行**整条消失** ⇒ 判据没有牙齿
      （老前端认了一个新语义，断言却当没看见）。
      现在：值单独取出来，由 check_frontend_key_shape 逐条判红。

    只解析 ERRCODE_KEY_MAP 这一个块：同文件里还有 HTTP_FALLBACK_KEY_MAP /
    SEGMENT_FALLBACK_KEY_MAP / DYNAMIC_MESSAGE_CODES ⇒ 不圈块会误抓。

    返回：{码: 值}；值不是字面量字符串的条目记 None（后续判红）。
    """
    lines = text.splitlines()
    start = None
    for idx, line in enumerate(lines):
        if FRONT_MAP_OPEN_RE.search(line):
            start = idx
            break
    if start is None:
        raise MatrixError("前端包里找不到 ERRCODE_KEY_MAP 定义")
    out = {}
    for line in lines[start + 1:]:
        if line.strip().startswith("}"):
            break
        m = FRONT_ENTRY_RE.match(line)
        if m:
            out[m.group(1)] = m.group(2)
            continue
        m2 = FRONT_ENTRY_LOOSE_RE.match(line)
        if m2:
            out[m2.group(1)] = None
    return out


def _pick_frontend_codes(texts: list, pkg_path: str) -> dict:
    """从候选源码里挑出**真能解析出码表**的那一份。

    ★ 为什么不能「第一个名字匹配的就用」：
      macOS 的 tar 会把扩展属性打包成 ._xxx 旁文件（AppleDouble）⇒ 归档里
      可能同时有 package/src/utils/api-interceptor.ts（真源码）和
      package/src/utils/._api-interceptor.ts（几百字节的残片）⇒ 第一个
      命中的可能是残片 ⇒ 解析不到码表 ⇒ 门禁误判「素材不可用」（旧实现同坑）。
      ⇒ 挨个试，取**能解析出码表**的那份。
    """
    last = ""
    for text in texts:
        try:
            codes = read_frontend_keys(text)
        except MatrixError as exc:
            last = str(exc)
            continue
        if codes:
            return codes
        last = "候选文件里没有 ERRCODE_KEY_MAP 条目"
    raise MatrixError("前端包里解析不出码表 %s: %s"
                      % (pkg_path, last or "未知原因"))


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
        texts = []
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn != "api-interceptor.ts" or fn.startswith("._"):
                    continue
                try:
                    with open(os.path.join(root, fn), encoding="utf-8") as fh:
                        texts.append(fh.read())
                except OSError:
                    continue
        if not texts:
            raise MatrixError("前端包里找不到 api-interceptor.ts: %s" % pkg_path)
        return _pick_frontend_codes(texts, pkg_path)

    if not os.path.isfile(pkg_path):
        raise MatrixError("前端包不存在: %s" % pkg_path)
    try:
        texts = []
        with tarfile.open(pkg_path, "r:gz") as tf:
            for member in tf.getmembers():
                base_name = member.name.rsplit("/", 1)[-1]
                if not member.name.endswith("api-interceptor.ts"):
                    continue
                if base_name.startswith("._") or "/__MACOSX/" in member.name:
                    continue  # macOS AppleDouble 旁文件（残片，不是源码）
                fh = tf.extractfile(member)
                if fh is None:
                    continue
                with fh:
                    texts.append(fh.read().decode("utf-8", "replace"))
    except tarfile.TarError as exc:
        raise MatrixError("解包失败 %s: %s" % (pkg_path, exc))
    if not texts:
        raise MatrixError("前端包里找不到 api-interceptor.ts: %s" % pkg_path)
    return _pick_frontend_codes(texts, pkg_path)


def read_pkg_json(pkg_path: str) -> dict:
    """读已发布前端包的 package.json（tgz 或已解包目录）。

    ★ 同 frontend_codes_from_pkg：归档里可能有 macOS 的 ._package.json 旁文件
      （AppleDouble 残片）⇒ 取**能解析成 JSON**的那一份，且优先 package/package.json。
    """
    if os.path.isdir(pkg_path):
        for cand in (os.path.join(pkg_path, "package", "package.json"),
                     os.path.join(pkg_path, "package.json")):
            if os.path.isfile(cand):
                try:
                    with open(cand, encoding="utf-8") as fh:
                        return json.load(fh)
                except (OSError, ValueError) as exc:
                    raise MatrixError("读前端包 package.json 失败 %s: %s"
                                      % (pkg_path, exc))
        raise MatrixError("前端包里找不到 package.json: %s" % pkg_path)
    if not os.path.isfile(pkg_path):
        raise MatrixError("前端包不存在: %s" % pkg_path)
    try:
        entries = []
        with tarfile.open(pkg_path, "r:gz") as tf:
            for member in tf.getmembers():
                base_name = member.name.rsplit("/", 1)[-1]
                if base_name != "package.json":
                    continue
                if "/__MACOSX/" in member.name:
                    continue
                if member.name.count("/") > 2:
                    continue
                fh = tf.extractfile(member)
                if fh is None:
                    continue
                with fh:
                    entries.append(
                        (member.name, fh.read().decode("utf-8", "replace")))
    except (tarfile.TarError, OSError) as exc:
        raise MatrixError("解包失败 %s: %s" % (pkg_path, exc))
    if not entries:
        raise MatrixError("前端包里找不到 package.json: %s" % pkg_path)
    entries.sort(key=lambda item: (0 if item[0] == "package/package.json" else 1,
                                   item[0]))
    last = ""
    for name, text in entries:
        try:
            return json.loads(text)
        except ValueError as exc:
            last = "%s: %s" % (name, exc)
    raise MatrixError("读前端包 package.json 失败 %s: %s" % (pkg_path, last))


def frontend_contracts_pin(pkg_path: str) -> str:
    """从已发布前端包的 package.json 读它钉的 contracts 版本。"""
    dep = (read_pkg_json(pkg_path).get("dependencies") or {}).get(
        "@pigeonbox/contracts", "")
    m = re.search(r"download/(v[0-9][^/]*)/", dep)
    return m.group(1) if m else ""


def frontend_pkg_version(pkg_path: str) -> str:
    """已发布前端包的版本号（package.json 的 version）。"""
    return str(read_pkg_json(pkg_path).get("version") or "")


# ── 已发布版本清单 ──────────────────────────────────────────────────────
def load_manifest(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise MatrixError("读已发布版本清单失败 %s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise MatrixError("已发布版本清单形态不对（应为 JSON 对象）: %s" % path)
    return data


def published_tags_from_manifest(manifest: dict) -> list:
    return [str(t) for t in
            (manifest.get("contracts") or {}).get("published_tags") or []]


def frontend_releases_from_manifest(manifest: dict) -> dict:
    """已发布前端清单：版本号 → {tag, asset, url, pinned_contracts}。"""
    out = {}
    for item in (manifest.get("frontend_core") or {}).get("releases") or []:
        ver = str(item.get("version") or "")
        if ver:
            out[ver] = item
    return out


# ── 判定 ────────────────────────────────────────────────────────────────
def check_cross_version(current: dict, older: dict, label: str) -> list:
    """两条不变量：
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


def check_frontend_key_shape(codes: dict, label: str) -> list:
    """前端码表的 i18n key 逐条核对：必须是 errcode.<同码>。

    ★ 逐条判，不在解析阶段丢弃：手滑（10001 → errcode.10002）或值不是字面量
      都必须判红，否则「老前端把新语义当旧语义显示」这类问题没有牙齿。
    """
    problems = []
    for code, key in sorted(codes.items()):
        if key is None:
            problems.append("%s：码 %s 的 i18n key 不是字面量字符串（无法核对 ⇒ 判红）"
                            % (label, code))
        elif key != "errcode.%s" % code:
            problems.append("%s：码 %s 的 i18n key 是 %s（应为 errcode.%s）"
                            % (label, code, key, code))
    return problems


def reconcile_published_pairs(contracts_dir: str, tags: list):
    """相邻**已发布**契约版本对账（只增不减 + 码号不复用）。

    返回 (problems, lines, missing_tags)：
      · problems —— 违反不变量的项；
      · lines —— 每对版本的核对结论（新增/删除/改名计数）；
      · missing_tags —— 本地 contracts 仓里**不存在**的已发布 tag（⇒ 缺料）。
    """
    problems = []
    lines = []
    missing = []
    tables = []
    for tag in tags:
        try:
            tables.append((tag, contract_table_at(contracts_dir, tag)))
        except MatrixError:
            tables.append((tag, None))
            missing.append(tag)
    for idx in range(1, len(tables)):
        (tag_old, old), (tag_new, new) = tables[idx - 1], tables[idx]
        if old is None or new is None:
            continue
        added = sorted(set(new) - set(old))
        removed = sorted(set(old) - set(new))
        renamed = [c for c in sorted(set(old) & set(new)) if old[c] != new[c]]
        lines.append("%s → %s：码数 %d→%d（新增 %d / 删除 %d / 改名 %d）"
                     % (tag_old, tag_new, len(old), len(new),
                        len(added), len(removed), len(renamed)))
        for code in removed:
            problems.append("已发布相邻版本 %s → %s：码 %s（%s）在新版本里消失了"
                            " ⇒ 违反「只增不减」" % (tag_old, tag_new, code, old[code]))
        for code in renamed:
            problems.append("已发布相邻版本 %s → %s：码 %s 的常量名从 %s 变成 %s"
                            " ⇒ 码号被复用给另一种语义"
                            % (tag_old, tag_new, code, old[code], new[code]))
    return problems, lines, missing


def cmd_validate(opts) -> int:
    root = os.path.abspath(opts.root)
    contracts_dir = os.path.abspath(
        opts.contracts or os.path.join(root, "contracts"))
    manifest_path = os.path.abspath(
        opts.manifest or os.path.join(root, "scripts", "errcode-published-versions.json"))
    require_all = opts.require_all

    unavailable = []   # 判据不可用（缺料）——与「判定不通过」严格区分
    problems = []      # 判定不通过

    def unavailable_or_raise(msg: str) -> None:
        if require_all:
            raise MatrixError(msg + "（--require-all ⇒ 缺料即红）")
        _warn(msg + " ⇒ 该面判定不可用（不是「扫过且通过」）")
        unavailable.append(msg)

    # ① 当前契约码表
    current_path = os.path.join(contracts_dir, "errcode", "errcode.go")
    current = {}
    if not os.path.isfile(current_path):
        unavailable_or_raise("契约真相源不存在 %s" % current_path)
    else:
        with open(current_path, encoding="utf-8") as fh:
            current = read_contract_table(fh.read())
        if not current:
            raise MatrixError("契约码表为空（真相源形态变了？）")
        _ok("当前契约码表：%d 个码" % len(current))

    manifest = {}
    if current:
        # ② 已发布版本清单 → 相邻已发布版本对账
        try:
            manifest = load_manifest(manifest_path)
        except MatrixError as exc:
            unavailable_or_raise(str(exc))
        tags = published_tags_from_manifest(manifest) if manifest else []
        if manifest and not tags:
            unavailable_or_raise("已发布版本清单里没有 contracts 已发布 tag：%s"
                                 % manifest_path)
        elif tags:
            pair_problems, pair_lines, missing = reconcile_published_pairs(
                contracts_dir, tags)
            for tag in missing:
                unavailable_or_raise("已发布 tag %s 在本地 contracts 仓不存在"
                                     "（清单与检出形态不符）" % tag)
            for line in pair_lines:
                _ok("已发布相邻版本对账：%s" % line)
            if pair_lines:
                _ok("已发布相邻版本对账：%d 对已发布版本（只增不减 + 码号不复用）"
                    % len(pair_lines))
            problems.extend(pair_problems)

        # ③ contracts 仓历史（含未发布提交）对比当前码表
        try:
            revs = contracts_revisions(contracts_dir)
        except MatrixError as exc:
            unavailable_or_raise(str(exc))
            revs = []
        checked_versions = 0
        for rev, subject in revs:
            try:
                older = contract_table_at(contracts_dir, rev)
            except MatrixError:
                continue
            if not older or older == current:
                continue
            checked_versions += 1
            problems.extend(check_cross_version(
                current, older, "历史版本 %s（%s）" % (rev[:9], subject[:40])))
        if checked_versions == 0:
            unavailable_or_raise("没有可比对的历史契约版本")
        else:
            _ok("跨版本比对：%d 个历史版本（只增不减 + 码号不复用）"
                % checked_versions)

        # ④ 已发布前端包：老前端在新契约下仍可用
        pkgs = opts.frontend_pkg or []
        checked_pkgs = 0
        fc_releases = frontend_releases_from_manifest(manifest) if manifest else {}
        for pkg in pkgs:
            try:
                codes = frontend_codes_from_pkg(pkg)
                pin = frontend_contracts_pin(pkg)
                version = frontend_pkg_version(pkg)
            except MatrixError as exc:
                unavailable_or_raise(str(exc))
                continue
            if not codes:
                unavailable_or_raise("前端包里没解析出码表：%s" % pkg)
                continue
            checked_pkgs += 1
            label = "已发布前端 %s（钉 contracts %s）" % (os.path.basename(pkg),
                                                        pin or "?")
            problems.extend(check_frontend_usable(codes, current, label))
            problems.extend(check_frontend_key_shape(codes, label))
            # 老前端码集 ⊆ 它**自己钉的那版**契约（更严：老前端不许认契约没有的码）
            if pin:
                try:
                    pinned_tbl = contract_table_at(contracts_dir, pin)
                except MatrixError:
                    pinned_tbl = None
                if pinned_tbl:
                    problems.extend(check_frontend_usable(
                        codes, pinned_tbl,
                        "已发布前端 %s（钉 contracts %s）" % (os.path.basename(pkg), pin)))
                else:
                    _warn("已发布前端 %s 钉的 contracts %s 在本地仓不可比对（跳过该面）"
                          % (os.path.basename(pkg), pin))
            # 清单 ↔ 实物一致性（清单记的钉版必须等于包里实际钉的）
            if version and version in fc_releases:
                want = str(fc_releases[version].get("pinned_contracts") or "")
                if want and pin and want != pin:
                    problems.append("已发布前端 %s：清单记的钉版是 %s，包里实际钉的是 %s"
                                    " ⇒ 清单漂移" % (version, want, pin))
            elif version:
                _warn("已发布前端 %s 不在「已发布版本清单」里（清单可能过期？）"
                      % version)
        if pkgs and checked_pkgs == 0:
            unavailable_or_raise("没有任何前端包被成功判定")
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
    if unavailable:
        print("\n⚠ 错误码跨版本兼容断言：**判据不可用**（%d 项缺料 ⇒ 未判定，"
              "不是「通过」）" % len(unavailable))
        for item in unavailable:
            print("    - %s" % item)
        return 3
    print("\n✓ 错误码跨版本兼容断言通过")
    return 0


def cmd_selfcheck(opts) -> int:
    """负对照：注入坏形态 ⇒ 必须判红。"""
    root = os.path.abspath(opts.root)
    contracts_dir = os.path.abspath(
        opts.contracts or os.path.join(root, "contracts"))
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
        problems.extend(check_frontend_key_shape(frontend, name))
        if problems:
            print("  ✓ %s：坏形态被判红（%d 项）" % (name, len(problems)))
            for p in problems[:2]:
                print("      %s" % p)
        else:
            print("  ✗ %s：坏形态被放行了（判据没有牙齿）" % name)
            sc_rc = 1

    def expect_front_red(name: str, snippet: str, victim: str) -> None:
        """前端码表**解析级**负对照：坏条目必须被抓到（不能被静默丢弃）。"""
        nonlocal sc_rc
        parsed = read_frontend_keys(snippet)
        if victim not in parsed:
            print("  ✗ %s：坏条目被**静默丢弃**（解析器没抓到 %s ⇒ 判据没有牙齿）"
                  % (name, victim))
            sc_rc = 1
            return
        problems = check_frontend_key_shape(parsed, name)
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
    problems += check_frontend_key_shape(good_frontend, "好形态")
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

    # 坏形态⑤/⑥：**解析级**负对照（源码形态的手滑 / 非字面量）
    front_good = (
        "const ERRCODE_KEY_MAP: Record<number, string> = {\n"
        "  10000: 'errcode.10000',\n"
        "  10001: 'errcode.10001',\n"
        "}\n"
        "const HTTP_FALLBACK_KEY_MAP: Record<number, string> = {\n"
        "  401: 'error.unauthorized',\n"
        "}\n"
    )
    parsed_good = read_frontend_keys(front_good)
    if parsed_good == {"10000": "errcode.10000", "10001": "errcode.10001"}:
        print("  ✓ 好形态（前端码表解析）：只取 ERRCODE_KEY_MAP 块、键值都抓到")
    else:
        print("  ✗ 好形态（前端码表解析）解析结果不对：%s" % parsed_good)
        sc_rc = 1
    expect_front_red(
        "坏形态⑤前端 i18n key 手滑（10001→10002）",
        front_good.replace("10001: 'errcode.10001'", "10001: 'errcode.10002'"),
        "10001")
    expect_front_red(
        "坏形态⑥前端 i18n key 不是字面量",
        front_good.replace("10001: 'errcode.10001'", "10001: someKey,"),
        "10001")

    # 负对照⑦：**读不到素材** ⇒ 必须判「判据不可用」（退出码 3），不得报「通过」
    fake = types.SimpleNamespace(
        root=root,
        contracts=os.path.join(tmp, "no-such-contracts"),
        manifest=os.path.join(root, "scripts", "errcode-published-versions.json"),
        frontend_pkg=[],
        require_all=False,
    )
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc_missing = cmd_validate(fake)
    out_missing = buf.getvalue()
    if rc_missing == 3 and "错误码跨版本兼容断言通过" not in out_missing:
        print("  ✓ 负对照⑦读不到素材：判「判据不可用」（退出码 3）且未报「通过」")
    else:
        print("  ✗ 负对照⑦读不到素材：退出码=%s 且报「通过」=%s"
              "（缺料被当成通过 ⇒ 判据没有牙齿）"
              % (rc_missing, "错误码跨版本兼容断言通过" in out_missing))
        sc_rc = 1

    if sc_rc != 0:
        print("\n✗ 跨版本断言自检未通过：至少一种形态的判定与预期不符")
        return 1
    print("\n✓ 跨版本断言自检通过（好形态放行 + 6 类坏形态 + 缺料负对照全部判红）")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="错误码跨版本兼容断言（L2）")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_val = sub.add_parser("validate", help="跑跨版本判定")
    p_val.add_argument("--root", required=True)
    p_val.add_argument("--contracts", default="")
    p_val.add_argument("--manifest", default="")
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
