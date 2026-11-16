#!/usr/bin/env python3
"""平台能力契约：解析 / 校验 / 实测判据 / 生成兼容矩阵（pigeonbox#365）。

零第三方依赖：capabilities.yaml 是**受限 YAML 子集**（整行 # 注释、两空格缩进、
key: value、内联列表 [a, b]、值内无行内注释），本文件自带迷你解析器。
（不 import yaml：CI runner 未必装 PyYAML，而门禁依赖网络安装=门禁四问里的
「依赖网络」红灯；子集解析让门禁在任何环境确定性可跑）。

子命令：
  validate   校验 schema + 字段双向全覆盖 + unknown 必有 todo + 判据类型合法
             + 平台仓在场时**实测**每条 probe（声明值与实测不符 ⇒ exit 1）
  matrix     由声明生成 Platform Compatibility Matrix（markdown，打 stdout）
  selfcheck  负对照：删字段 / 坏判据 / unknown 无 todo / 实测不符 / 矩阵漂移 ⇒ 必红

用法（由 scripts/check-platform-capabilities.sh 调用，也可直接跑）：
  python3 scripts/platform_capabilities.py validate --root <hub根> [--platforms-root <dir>]
  python3 scripts/platform_capabilities.py matrix   --root <hub根>
  python3 scripts/platform_capabilities.py selfcheck --root <hub根>
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

CAP_REL = os.path.join("deploy", "platforms", "capabilities.yaml")
MATRIX_REL = os.path.join("docs", "platform-compatibility-matrix.md")
PLATFORM_NAMES = ["fnos", "qnap", "openwrt", "synology", "ugreen", "terramaster"]
PROBE_TYPES = {"file", "grep", "absent", "nogrep"}


class CapError(Exception):
    """契约违规：消息即判红理由。"""


# ── 迷你 YAML 子集解析 ──────────────────────────────────────────────────────
def _parse_scalar(raw):
    s = raw.strip()
    if s.startswith("[") and s.endswith("]"):
        inner = s[1:-1].strip()
        return [x.strip() for x in inner.split(",") if x.strip()] if inner else []
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    if s in ("true", "false"):
        return s == "true"
    if re.fullmatch(r"-?\d+", s):
        return int(s)
    return s


def parse_subset_yaml(text):
    """受限子集解析 → dict。两空格缩进；key: value 或 key:（子映射）。"""
    root = {}
    stack = [(-2, root)]  # [(indent, container)]
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent % 2 != 0:
            raise CapError("第 %d 行：缩进必须是两空格的整数倍" % lineno)
        body = line.strip()
        if ":" not in body:
            raise CapError("第 %d 行：不是 key: value 形态：%s" % (lineno, body))
        key, _, rest = body.partition(":")
        key = key.strip()
        if not key:
            raise CapError("第 %d 行：空 key" % lineno)
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if not stack:
            raise CapError("第 %d 行：缩进回退异常" % lineno)
        parent = stack[-1][1]
        if not isinstance(parent, dict):
            raise CapError("第 %d 行：父节点不是映射" % lineno)
        if key in parent:
            raise CapError("第 %d 行：重复 key %s" % (lineno, key))
        if rest.strip() == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _parse_scalar(rest)
    return root


def load_contract(path):
    if not os.path.isfile(path):
        raise CapError("找不到契约文件 %s" % path)
    with open(path, encoding="utf-8") as f:
        doc = parse_subset_yaml(f.read())
    return doc


# ── 结构校验 ────────────────────────────────────────────────────────────────
def check_structure(doc):
    errs = []
    if doc.get("schema_version") != 1:
        errs.append("schema_version 必须是 1，实际 %r" % doc.get("schema_version"))

    fields = doc.get("capability_fields")
    if not isinstance(fields, dict) or not fields:
        errs.append("capability_fields 缺失或为空")
        fields = {}
    for fname, fdef in fields.items():
        if not isinstance(fdef, dict):
            errs.append("capability_fields.%s 必须是映射" % fname)
            continue
        if not fdef.get("desc"):
            errs.append("capability_fields.%s 缺 desc" % fname)
        acc = fdef.get("acceptance")
        if not isinstance(acc, list) or not acc:
            errs.append("capability_fields.%s 缺 acceptance 判据字段（允许的 probe 类型列表）" % fname)
        else:
            bad = [a for a in acc if a not in PROBE_TYPES]
            if bad:
                errs.append("capability_fields.%s.acceptance 含未知判据类型 %s" % (fname, bad))

    plats = doc.get("platforms")
    if not isinstance(plats, dict):
        errs.append("platforms 缺失")
        plats = {}
    missing_plats = [p for p in PLATFORM_NAMES if p not in plats]
    if missing_plats:
        errs.append("缺平台声明：%s" % ", ".join(missing_plats))

    field_names = set(fields)
    for pname, pdef in plats.items():
        if not isinstance(pdef, dict):
            errs.append("platforms.%s 必须是映射" % pname)
            continue
        if not pdef.get("repo"):
            errs.append("platforms.%s 缺 repo" % pname)
        mx = pdef.get("matrix")
        if not isinstance(mx, dict):
            errs.append("platforms.%s 缺 matrix 元数据" % pname)
        else:
            for mk in ("arch", "os", "package_format", "upgrade_path", "verified", "verified_note"):
                if mk not in mx or mx[mk] in ("", None, []):
                    errs.append("platforms.%s.matrix 缺 %s" % (pname, mk))
            v = mx.get("verified")
            if v not in (True, False, "partial"):
                errs.append("platforms.%s.matrix.verified 必须是 true/false/partial，实际 %r" % (pname, v))

        caps = pdef.get("capabilities")
        if not isinstance(caps, dict):
            errs.append("platforms.%s 缺 capabilities" % pname)
            continue
        cap_names = set(caps)
        for fname in sorted(field_names - cap_names):
            errs.append("platforms.%s 缺能力字段 %s（必须与 capability_fields 双向全覆盖）" % (pname, fname))
        for fname in sorted(cap_names - field_names):
            errs.append("platforms.%s 声明了未注册能力 %s（先在 capability_fields 注册）" % (pname, fname))

        for fname, cdef in caps.items():
            if not isinstance(cdef, dict):
                errs.append("platforms.%s.capabilities.%s 必须是映射" % (pname, fname))
                continue
            val = cdef.get("value")
            loc = "platforms.%s.capabilities.%s" % (pname, fname)
            if val not in (True, False, "unknown"):
                errs.append("%s.value 必须是 true/false/unknown，实际 %r" % (loc, val))
                continue
            if val == "unknown":
                if not cdef.get("todo"):
                    errs.append("%s 为 unknown 但缺 todo（unknown 必须列待办）" % loc)
                continue
            probe = cdef.get("probe")
            if not probe:
                errs.append("%s.value=%s 但缺 probe 判据（每个字段必须有验收判据）" % (loc, val))
                continue
            perr = probe_error(probe, fields.get(fname, {}).get("acceptance") or [])
            if perr:
                errs.append("%s：%s" % (loc, perr))
            if not cdef.get("evidence"):
                errs.append("%s 缺 evidence（仓内证据）" % loc)
    return errs


# ── 判据（probe）解析与实测 ─────────────────────────────────────────────────
def probe_error(probe, acceptance):
    if not isinstance(probe, str) or ":" not in probe:
        return "probe 必须是 <type>:<arg> 形态：%r" % (probe,)
    ptype, _, arg = probe.partition(":")
    if ptype not in PROBE_TYPES:
        return "未知判据类型 %r" % ptype
    if acceptance and ptype not in acceptance:
        return "判据类型 %r 不在字段 acceptance %s 内" % (ptype, acceptance)
    if not arg:
        return "probe 缺参数"
    if ptype == "grep":
        parts = probe.split(":", 2)
        if len(parts) != 3 or not parts[1] or not parts[2]:
            return "grep 判据必须是 grep:<路径>:<pattern>"
    return None


def run_probe(probe, platform_dir):
    """执行一条判据。返回 None=通过，否则返回失败理由。"""
    ptype, _, arg = probe.partition(":")
    if ptype == "grep":
        _, rel, pattern = probe.split(":", 2)
        fpath = os.path.join(platform_dir, rel)
        if not os.path.isfile(fpath):
            return "文件不存在：%s" % rel
        try:
            with open(fpath, encoding="utf-8", errors="ignore") as f:
                if pattern not in f.read():
                    return "%s 不含 %r" % (rel, pattern)
        except OSError as e:
            return "读 %s 失败：%s" % (arg, e)
        return None
    if ptype == "file":
        if not os.path.exists(os.path.join(platform_dir, arg)):
            return "路径不存在：%s" % arg
        return None
    if ptype == "absent":
        if os.path.exists(os.path.join(platform_dir, arg)):
            return "路径不应存在：%s" % arg
        return None
    if ptype == "nogrep":
        # 全仓在库文件无命中（排除 .git；二进制以 utf-8 ignore 读，命中即判红）。
        # 用 git ls-files 限定**在库文件**：构建产物/未跟踪文件不参与，判据可复现。
        try:
            ls = subprocess.run(
                ["git", "-C", platform_dir, "ls-files"],
                capture_output=True, text=True, check=True,
            )
        except (subprocess.CalledProcessError, OSError) as e:
            return "无法枚举 %s 的在库文件：%s" % (platform_dir, e)
        pat = re.compile(arg)
        for rel in ls.stdout.splitlines():
            fpath = os.path.join(platform_dir, rel)
            if not os.path.isfile(fpath):
                continue
            # 文档（*.md）不参与反向判据：README 会**引用**判据文本来说明
            # 「本平台没有 X」（实测 ugreen/terramaster README 写「没有 <db>.bak-…
            # 快照」⇒ 命中假红）。nogrep 抓的是**实现**（脚本/配置），不是叙述。
            if rel.endswith(".md"):
                continue
            try:
                with open(fpath, encoding="utf-8", errors="ignore") as f:
                    if pat.search(f.read()):
                        return "在库文件 %s 命中 %r" % (rel, arg)
            except OSError:
                continue
        return None
    return "未知判据类型 %r" % ptype


def validate(root, platforms_root, quiet=False):
    """结构校验 + 平台仓在场时实测。返回错误列表。"""
    doc = load_contract(os.path.join(root, CAP_REL))
    errs = check_structure(doc)
    if errs:
        return errs

    plats = doc["platforms"]
    present, absent = [], []
    for pname in PLATFORM_NAMES:
        pdir = os.path.join(platforms_root, pname)
        (present if os.path.isdir(pdir) else absent).append((pname, pdir))

    if absent and not quiet:
        names = ", ".join(p for p, _ in absent)
        print("  · 平台仓不在场，跳过实测：%s（本地单仓检出形态；CI 检出六仓全测）" % names)

    for pname, pdir in present:
        for fname, cdef in plats[pname]["capabilities"].items():
            val = cdef.get("value")
            if val == "unknown":
                continue
            probe = cdef.get("probe")
            if not probe:
                continue  # 结构校验已报
            reason = run_probe(probe, pdir)
            ptype = probe.split(":", 1)[0]
            if reason is None and val is False and ptype in ("file", "grep"):
                # false 值却用正向判据：判据成立说明能力存在 ⇒ 与声明矛盾
                reason = "声明 false 但正向判据成立"
            if reason is None and val is True and ptype in ("absent", "nogrep"):
                reason = "声明 true 但反向判据成立"
            if reason is not None:
                errs.append("实测不符 platforms.%s.capabilities.%s（value=%s, probe=%s）：%s"
                            % (pname, fname, val, probe, reason))
            elif not quiet:
                print("  ✓ %s.%s（%s）" % (pname, fname, probe))
    if not quiet:
        if present:
            print("  实测 %d 个平台仓 × 全部判据" % len(present))
        else:
            print("  未实测任何平台仓（六个仓都不在场）——仅结构校验通过")
    return errs


# ── 矩阵生成 ────────────────────────────────────────────────────────────────
def _mark(val):
    if val is True:
        return "✅"
    if val is False:
        return "❌"
    return "❓unknown"


def _verified(v):
    if v is True:
        return "✅ 真机已验"
    if v == "partial":
        return "🟡 部分已验"
    return "⏳ 待真机"


def render_matrix(doc):
    fields = doc["capability_fields"]
    plats = doc["platforms"]
    out = []
    out.append("# Platform Compatibility Matrix（六适配平台兼容矩阵）")
    out.append("")
    out.append("> **本文件由 scripts/gen-platform-matrix.sh 从")
    out.append("> deploy/platforms/capabilities.yaml 生成，禁止手改**（CI 对账：生成物 == 生成结果）。")
    out.append("> 能力判据与实测由 scripts/check-platform-capabilities.sh 把关（pigeonbox#365）。")
    out.append("")
    out.append("## 能力矩阵")
    out.append("")
    header = "| 能力 | " + " | ".join(PLATFORM_NAMES) + " |"
    sep = "|---|" + "---|" * len(PLATFORM_NAMES)
    out.append(header)
    out.append(sep)
    for fname in fields:
        row = [fname]
        for pname in PLATFORM_NAMES:
            cdef = plats[pname]["capabilities"].get(fname, {})
            row.append(_mark(cdef.get("value")))
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## 平台元数据")
    out.append("")
    out.append("| 平台 | 仓库 | 架构 | OS | 安装包格式 | 升级路径 | 真机验证 |")
    out.append("|---|---|---|---|---|---|---|")
    for pname in PLATFORM_NAMES:
        p = plats[pname]
        m = p["matrix"]
        arch = ", ".join(m["arch"]) if isinstance(m["arch"], list) else str(m["arch"])
        out.append("| %s | %s | %s | %s | %s | %s | %s |"
                   % (pname, p["repo"], arch, m["os"], m["package_format"],
                      m["upgrade_path"], _verified(m["verified"])))
    out.append("")
    out.append("## 未决项（unknown ⇒ 必须有 TODO）")
    out.append("")
    todos = []
    for pname in PLATFORM_NAMES:
        for fname in fields:
            cdef = plats[pname]["capabilities"].get(fname, {})
            if cdef.get("value") == "unknown":
                todos.append("- **%s / %s**：%s" % (pname, fname, cdef.get("todo", "（缺 todo）")))
    out.extend(todos if todos else ["- （无）"])
    out.append("")
    out.append("## 判据索引（每字段的验收判据，CI 实测）")
    out.append("")
    out.append("| 平台 | 能力 | 值 | 判据 |")
    out.append("|---|---|---|---|")
    for pname in PLATFORM_NAMES:
        for fname in fields:
            cdef = plats[pname]["capabilities"].get(fname, {})
            val = cdef.get("value")
            probe = cdef.get("probe") or ("todo: " + str(cdef.get("todo", ""))[:60])
            out.append("| %s | %s | %s | %s |" % (pname, fname, val, probe))
    out.append("")
    return "\n".join(out)


def write_matrix(root, dest=None):
    doc = load_contract(os.path.join(root, CAP_REL))
    errs = check_structure(doc)
    if errs:
        raise CapError("结构校验未过，拒绝生成矩阵：\n  " + "\n  ".join(errs))
    text = render_matrix(doc) + "\n"
    if dest is None:
        sys.stdout.write(text)
        return None
    with open(dest, "w", encoding="utf-8") as f:
        f.write(text)
    return dest


# ── selfcheck（负对照） ─────────────────────────────────────────────────────
def _run(args):
    return subprocess.run(args, capture_output=True, text=True)


def selfcheck(root):
    """负对照：每种违规形态必须让 validate/matrix 判红。"""
    fails = 0
    tmp = tempfile.mkdtemp(prefix="cap-selfcheck-")
    try:
        capdir = os.path.join(tmp, "deploy", "platforms")
        os.makedirs(capdir)
        # 六平台都必须在（结构校验要求 PLATFORM_NAMES 全覆盖）；
        # 判据文本集中在 fnos 条目，供下面的字符串变异定位。
        cap_block = (
            "      native_sso:\n"
            "        value: true\n"
            "        probe: grep:adapter/sso.go:X-Trim\n"
            "        evidence: adapter/sso.go:1\n"
        )
        fake_fields = (
            "schema_version: 1\n"
            "capability_fields:\n"
            "  native_sso:\n"
            "    desc: 原生 SSO\n"
            "    acceptance: [grep, absent]\n"
            "platforms:\n"
        )
        for pname in PLATFORM_NAMES:
            fake_fields += (
                "  %s:\n"
                "    repo: pigeonbox/%s\n"
                "    matrix:\n"
                "      arch: [x86_64]\n"
                "      os: testos\n"
                "      package_format: pkg\n"
                "      upgrade_path: 升级\n"
                "      verified: true\n"
                "      verified_note: 真机\n"
                "    capabilities:\n"
                % (pname, pname)
            )
            fake_fields += cap_block
        capfile = os.path.join(capdir, "capabilities.yaml")

        def write_cap(text):
            with open(capfile, "w", encoding="utf-8") as f:
                f.write(text)

        def expect_red(label, text):
            write_cap(text)
            rc = _run([sys.executable, __file__, "validate", "--root", tmp,
                       "--platforms-root", tmp]).returncode
            if rc == 0:
                print("  ✗ 变异「%s」未转红" % label)
                return 1
            print("  ✓ 变异「%s」转红" % label)
            return 0

        # 基线：合法契约（fnos 平台仓不在场 ⇒ 只结构校验）
        write_cap(fake_fields)
        rc = _run([sys.executable, __file__, "validate", "--root", tmp,
                   "--platforms-root", tmp]).returncode
        if rc != 0:
            print("  ✗ 基线应绿（自身契约校验失败）")
            fails += 1
        else:
            print("  ✓ 基线绿")

        # 变异 1：删掉能力条目（覆盖不全）
        fails += expect_red(
            "删 native_sso 条目",
            fake_fields.replace(
                "      native_sso:\n"
                "        value: true\n"
                "        probe: grep:adapter/sso.go:X-Trim\n"
                "        evidence: adapter/sso.go:1\n", ""),
        )
        # 变异 2：坏判据（未知类型）
        fails += expect_red(
            "坏判据（未知类型 waffle）",
            fake_fields.replace("probe: grep:adapter/sso.go:X-Trim",
                                "probe: waffle:adapter/sso.go"),
        )
        # 变异 3：unknown 无 todo
        fails += expect_red(
            "unknown 无 todo",
            fake_fields.replace(
                "        value: true\n"
                "        probe: grep:adapter/sso.go:X-Trim\n"
                "        evidence: adapter/sso.go:1\n",
                "        value: unknown\n"),
        )
        # 变异 4：字段缺 acceptance 判据字段
        fails += expect_red(
            "字段缺 acceptance",
            fake_fields.replace("    acceptance: [grep, absent]\n", ""),
        )
        # 变异 5：实测不符 —— 声明 true 但判据不成立（造出平台仓）
        pdir = os.path.join(tmp, "fnos")
        os.makedirs(os.path.join(pdir, "adapter"), exist_ok=True)
        with open(os.path.join(pdir, "adapter", "sso.go"), "w", encoding="utf-8") as f:
            f.write("package adapter\n")  # 不含 X-Trim
        write_cap(fake_fields)
        rc = _run([sys.executable, __file__, "validate", "--root", tmp,
                   "--platforms-root", tmp]).returncode
        if rc == 0:
            print("  ✗ 变异「判据实测不符」未转红")
            fails += 1
        else:
            print("  ✓ 变异「判据实测不符」转红")
        # 修好文件 ⇒ 转绿（证明上一条红是判据生效，而非路径必红）
        with open(os.path.join(pdir, "adapter", "sso.go"), "w", encoding="utf-8") as f:
            f.write("// X-Trim 可信头\n")
        rc = _run([sys.executable, __file__, "validate", "--root", tmp,
                   "--platforms-root", tmp]).returncode
        if rc != 0:
            print("  ✗ 判据修好后未转绿（门禁可能恒红）")
            fails += 1
        else:
            print("  ✓ 判据修好后转绿")

        # 变异 6：矩阵漂移 —— 生成物 ≠ 生成结果
        os.makedirs(os.path.join(tmp, "docs"), exist_ok=True)
        mfile = os.path.join(tmp, "docs", "platform-compatibility-matrix.md")
        write_cap(fake_fields)
        write_matrix(tmp, mfile)
        with open(mfile, "a", encoding="utf-8") as f:
            f.write("\n<!-- drift -->\n")
        gen = subprocess.run(
            [sys.executable, __file__, "matrix", "--root", tmp],
            capture_output=True, text=True)
        with open(mfile, encoding="utf-8") as f:
            committed = f.read()
        if gen.returncode != 0 or gen.stdout == committed:
            print("  ✗ 变异「矩阵漂移」未转红")
            fails += 1
        else:
            print("  ✓ 变异「矩阵漂移」转红")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if fails:
        print("✗ selfcheck 失败：%d 处负对照没有区分力" % fails)
        return 1
    print("✓ selfcheck 通过（基线绿 + 6 类变异必红）")
    return 0


def main():
    ap = argparse.ArgumentParser(description="平台能力契约 validate/matrix/selfcheck")
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate")
    v.add_argument("--root", required=True, help="hub 仓根")
    v.add_argument("--platforms-root", default=None,
                   help="平台仓检出根（默认 = root；CI 检出到 workspace/<name>）")

    m = sub.add_parser("matrix")
    m.add_argument("--root", required=True)

    s = sub.add_parser("selfcheck")
    s.add_argument("--root", required=True)

    args = ap.parse_args()
    try:
        if args.cmd == "validate":
            root = os.path.abspath(args.root)
            proot = os.path.abspath(args.platforms_root or root)
            errs = validate(root, proot)
            if errs:
                print("✗ 能力契约校验失败：%d 处" % len(errs))
                for e in errs:
                    print("  · %s" % e)
                return 1
            print("✓ 能力契约校验通过")
            return 0
        if args.cmd == "matrix":
            write_matrix(os.path.abspath(args.root))
            return 0
        if args.cmd == "selfcheck":
            return selfcheck(os.path.abspath(args.root))
    except CapError as e:
        print("✗ %s" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
