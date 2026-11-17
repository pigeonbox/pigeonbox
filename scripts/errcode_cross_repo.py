#!/usr/bin/env python3
"""错误码跨仓对账（L2 层：跨版本前后端错误码语义）。

为什么有这道门禁（2026-11-14 生态技术评审 §六 L2 层缺口）
----------------------------------------------------------
错误码的真相源是 ``contracts/errcode/errcode.go``（手写 Go 常量表）。
消费方有三处：

  1. ``core``——按码返回错误信封（core 仓内另有 AST 守卫管「字面量不越界」，
     与本门禁互补，不重复）；
  2. ``frontend-core`` 的 ``ERRCODE_KEY_MAP``（码 → i18n key）；
  3. ``frontend-core`` 五门语言包的 ``errcode:`` 块（码 → 文案）。

**历史形态**：三者的一致性**纯属约定**，没有任何机器断言：

  - contracts 无「const 表 ⇄ messages 表」自检；
  - frontend-core 的测试断言源头是**手抄**的码表数组（实测手抄 66 条、
    真相源 67 条 ⇒ 已漏一条而无人发现）；
  - 「已发布码不得删除 / 不得改语义 / 不得复用」这条**跨版本**不变量
    完全没有机器表达。

⇒ 本门禁把「三端集合必须相等」与「已发布码只增不减」做成机械断言。

本门禁断言什么（全部必须变红，判据即负对照）
------------------------------------------
  ① 契约基线同步：``contracts/errcode/baseline.json`` 的码集合 == 当前 const 表，
     且**同号常量的名字不变**（防「码号被复用给另一种语义」——这是最阴险的一类：
     数字对得上、老前端却拿到了新语义）；
  ② 前端映射对齐：``ERRCODE_KEY_MAP`` 的键集合 == 契约码集合，且每个值形如
     ``errcode.<同一个码>``（防手滑把 10001 写成 10010）；
  ③ 五门语言对齐：每门语言 ``errcode`` 块的键集合 == 契约码集合（不多不少），
     且文案非空；
  ④ 单调性：``baseline.json`` 里的码不得从契约消失（删已发布码 ⇒ 红）。

检出形态（三态，与 check-platform-capabilities.sh 同口径）
----------------------------------------------------------
  · **判定形态**：CI 把 ``frontend-core`` 检出到同级目录 ⇒ 全量跑；
  · **跳过形态**：本地单仓检出（frontend-core 不在场）⇒ 打印**明确的跳过原因**，
    只跑契约侧自检（①④）——不让「没扫到」看起来像「扫过且通过」；
  · CI 侧用 ``--require-frontend`` 强制全量：**缺仓即红**（与
    check-docs-consistency.sh 的「缺仓判红」同口径）。

用法：
    python3 scripts/errcode_cross_repo.py validate --root <hub> [--frontend <dir>]
                                                  [--require-frontend]
    python3 scripts/errcode_cross_repo.py selfcheck --root <hub>
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile

# 契约常量声明：CodeXxx = 12345（只取 5 位码；CodeSuccess = 0 不算错误码）
# 行尾允许带 // 注释（契约表每条都带中文注释），但**行首**必须是常量名
# ⇒ 注释行（以 // 开头）不会误命中。
CONST_RE = re.compile(r"^\s*(Code[A-Za-z0-9]+)\s*=\s*([0-9]{5})\b")
# 前端映射条目：10000: 'errcode.10000',
MAP_ENTRY_RE = re.compile(r"^\s*([0-9]{5})\s*:\s*'([^']+)'")
# 语言包条目：'10000': '未知错误',
LOCALE_ENTRY_RE = re.compile(r"^\s*'([0-9]{5})'\s*:\s*'((?:[^'\\]|\\.)*)'")

LOCALES = ("zh-CN", "en-US", "ja-JP", "de-DE", "ru-RU")

GREEN = "\033[0;32m"
RED = "\033[1;31m"
YELLOW = "\033[1;33m"
RESET = "\033[0m"


class GateError(Exception):
    """门禁判红（消息必须点名具体码 / 文件 / 差异）。"""


def _err(msg: str) -> None:
    print(f"{RED}✗ {msg}{RESET}", file=sys.stderr)


def _ok(msg: str) -> None:
    print(f"{GREEN}  ✓ {msg}{RESET}")


def _warn(msg: str) -> None:
    print(f"{YELLOW}! {msg}{RESET}")


def load_contracts(errcode_go: str) -> dict[str, str]:
    """解析契约 const 表 ⇒ {常量名: 码}；同时返回 {码: 常量名} 由调用方反推。"""
    if not os.path.isfile(errcode_go):
        raise GateError(f"找不到契约真相源 {errcode_go}")
    name_to_code: dict[str, str] = {}
    with open(errcode_go, "r", encoding="utf-8") as fh:
        for line in fh:
            m = CONST_RE.match(line.rstrip("\n"))
            if m:
                name, code = m.group(1), m.group(2)
                if name in name_to_code:
                    raise GateError(f"契约常量名重复：{name}（{errcode_go}）")
                name_to_code[name] = code
    if not name_to_code:
        raise GateError(f"契约真相源里没解析出任何常量码：{errcode_go}（格式变了？）")
    seen: dict[str, str] = {}
    for name, code in name_to_code.items():
        if code in seen:
            raise GateError(
                f"契约里两个常量取同一个码值：{seen[code]} 与 {name} ⇒ {code}"
            )
        seen[code] = name
    return name_to_code


def load_baseline(path: str) -> dict[str, str]:
    """读已发布码基线 ⇒ {码: 常量名}。"""
    if not os.path.isfile(path):
        raise GateError(f"找不到已发布码基线 {path}（应由 contracts 仓维护）")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise GateError(f"基线文件不是合法 JSON：{path}（{exc}）") from exc
    codes = data.get("codes")
    if not isinstance(codes, dict) or not codes:
        raise GateError(f"基线文件缺少非空的 codes 段：{path}")
    out: dict[str, str] = {}
    for code, name in codes.items():
        if not re.fullmatch(r"[0-9]{5}", str(code)):
            raise GateError(f"基线里的码 {code!r} 不是 5 位数字（{path}）")
        if not isinstance(name, str) or not name:
            raise GateError(f"基线里的 {code} 缺常量名（{path}）")
        out[str(code)] = name
    return out


def load_frontend_map(path: str) -> dict[str, str]:
    """解析前端 ERRCODE_KEY_MAP ⇒ {码: i18n key}。"""
    if not os.path.isfile(path):
        raise GateError(f"找不到前端错误码映射 {path}")
    entries: dict[str, str] = {}
    in_block = False
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not in_block:
                if "ERRCODE_KEY_MAP" in line and "=" in line and "{" in line:
                    in_block = True
                continue
            if line.strip() == "};" or line.strip() == "}":
                break
            m = MAP_ENTRY_RE.match(line)
            if m:
                entries[m.group(1)] = m.group(2)
    if not entries:
        raise GateError(f"前端错误码映射里没解析出任何条目：{path}（格式变了？）")
    return entries


def load_locale_errcodes(path: str) -> dict[str, str]:
    """解析语言包 errcode 块 ⇒ {码: 文案}。"""
    if not os.path.isfile(path):
        raise GateError(f"找不到语言包 {path}")
    entries: dict[str, str] = {}
    in_block = False
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not in_block:
                if re.match(r"^\s*errcode\s*:\s*\{", line):
                    in_block = True
                continue
            if re.match(r"^\s*\},?\s*$", line):
                break
            m = LOCALE_ENTRY_RE.match(line)
            if m:
                entries[m.group(1)] = m.group(2)
    if not entries:
        raise GateError(f"语言包 {path} 里没解析出任何 errcode 条目（格式变了？）")
    return entries


def _diff(left: set[str], right: set[str]) -> tuple[list[str], list[str]]:
    return sorted(left - right), sorted(right - left)


def check_baseline(
    const_name_to_code: dict[str, str], baseline: dict[str, str]
) -> None:
    """① 基线同步 + ④ 单调性（已发布码不得消失 / 改名 / 改语义）。"""
    const_codes = set(const_name_to_code.values())
    code_to_name = {v: k for k, v in const_name_to_code.items()}

    missing, extra = _diff(const_codes, set(baseline))
    if missing:
        raise GateError(
            f"契约新增了码但基线未同步（基线在 contracts/errcode/baseline.json）：{missing}"
            " ⇒ 新增码必须同时进基线（基线是「已发布码」的机器表达）"
        )
    if extra:
        raise GateError(
            f"基线里的码在契约中已消失：{extra}"
            " ⇒ **已发布码只增不减**：删码会让旧版前端的映射失效（老前端遇到已删码只能落兜底）"
        )
    for code, name in sorted(baseline.items()):
        now = code_to_name.get(code)
        if now != name:
            raise GateError(
                f"码号被复用：{code} 原常量名 {name}，现常量名 {now}"
                " ⇒ 数字对得上但语义变了，老前端会拿到新语义的错误文案"
            )


def check_frontend_map(const_codes: set[str], fmap: dict[str, str]) -> None:
    """② 前端映射与契约集合相等，且值的码与键一致。"""
    missing, extra = _diff(const_codes, set(fmap))
    if missing:
        raise GateError(
            f"前端 ERRCODE_KEY_MAP 缺少契约登记的码：{missing} ⇒ 后端会返回前端翻译不出的码"
        )
    if extra:
        raise GateError(
            f"前端 ERRCODE_KEY_MAP 里有契约未登记的码：{extra} ⇒ 前端多出的码会让"
            "「契约是真相源」失效（也可能是旧契约遗留）"
        )
    for code, key in sorted(fmap.items()):
        if key != f"errcode.{code}":
            raise GateError(
                f"前端 ERRCODE_KEY_MAP[{code}] 的值是 {key!r}，应为 'errcode.{code}'"
                " ⇒ 值与键不一致会让取件页显示错语言的文案"
            )


def check_locales(const_codes: set[str], locales: dict[str, dict[str, str]]) -> None:
    """③ 五门语言的 errcode 键集合与契约相等，文案非空。"""
    for lang, entries in sorted(locales.items()):
        missing, extra = _diff(const_codes, set(entries))
        if missing:
            raise GateError(
                f"语言包 {lang} 缺少契约登记的码：{missing} ⇒ 该语言下会显示原始文案"
            )
        if extra:
            raise GateError(
                f"语言包 {lang} 里有契约未登记的码：{extra} ⇒ 多余文案会随契约删码变成死键"
            )
        for code, text in sorted(entries.items()):
            if not text.strip():
                raise GateError(f"语言包 {lang} 的 {code} 文案为空")


def collect(contracts_dir: str, frontend_dir: str | None):
    """收集三端集合。frontend_dir 为 None ⇒ 只收契约侧（本地单仓检出形态）。"""
    const_name_to_code = load_contracts(
        os.path.join(contracts_dir, "errcode", "errcode.go")
    )
    baseline = load_baseline(
        os.path.join(contracts_dir, "errcode", "baseline.json")
    )
    const_codes = set(const_name_to_code.values())
    if frontend_dir is None:
        return const_name_to_code, baseline, const_codes, None, None
    fmap = load_frontend_map(
        os.path.join(frontend_dir, "src", "utils", "api-interceptor.ts")
    )
    locales: dict[str, dict[str, str]] = {}
    for lang in LOCALES:
        locales[lang] = load_locale_errcodes(
            os.path.join(frontend_dir, "src", "i18n", "locales", f"{lang}.ts")
        )
    return const_name_to_code, baseline, const_codes, fmap, locales


def cmd_validate(args: argparse.Namespace) -> int:
    contracts_dir = args.contracts or os.path.join(args.root, "contracts")
    frontend_dir = args.frontend
    if frontend_dir is None:
        candidate = os.path.join(args.root, "frontend-core")
        if os.path.isdir(candidate):
            frontend_dir = candidate
    if frontend_dir is None:
        if args.require_frontend:
            raise GateError(
                "frontend-core 不在场——CI 形态要求三端同场对账（缺仓判红，"
                "与 check-docs-consistency.sh 同口径）"
            )
        _warn(
            "frontend-core 不在场 ⇒ 只跑契约侧自检（基线同步 + 单调性）；"
            "这不是「全绿」，是**跳过前端侧**"
        )

    const_name_to_code, baseline, const_codes, fmap, locales = collect(
        contracts_dir, frontend_dir
    )

    check_baseline(const_name_to_code, baseline)
    _ok(f"基线同步 + 单调性：{len(baseline)} 个已发布码全部在契约中且未改语义")

    if fmap is not None:
        check_frontend_map(const_codes, fmap)
        _ok(f"前端 ERRCODE_KEY_MAP 与契约一致：{len(fmap)} 个码")
        assert locales is not None
        check_locales(const_codes, locales)
        _ok(f"{len(locales)} 门语言包与契约一致：{', '.join(sorted(locales))}")

    print(f"{GREEN}✓ 错误码跨仓对账通过（契约 {len(const_codes)} 个码）{RESET}")
    return 0


# ── selfcheck（负对照）──────────────────────────────────────────────────────
def _copy_tree(src: str, dst: str) -> None:
    """只复制需要的文件（保持目录结构），避免把整个仓搬进临时目录。"""
    for rel in (
        os.path.join("errcode", "errcode.go"),
        os.path.join("errcode", "baseline.json"),
    ):
        s = os.path.join(src, rel)
        if os.path.isfile(s):
            d = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)
    s = os.path.join(src, os.path.join("src", "utils", "api-interceptor.ts"))
    if os.path.isfile(s):
        d = os.path.join(dst, os.path.join("src", "utils", "api-interceptor.ts"))
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(s, d)
    loc_src = os.path.join(src, "src", "i18n", "locales")
    if os.path.isdir(loc_src):
        loc_dst = os.path.join(dst, "src", "i18n", "locales")
        os.makedirs(loc_dst, exist_ok=True)
        for name in os.listdir(loc_src):
            if name.endswith(".ts"):
                shutil.copy2(os.path.join(loc_src, name), os.path.join(loc_dst, name))


def _drop_contract_code(errcode_go: str) -> None:
    """注入①：契约删一个 const（模拟「有人删了已发布码」）。"""
    with open(errcode_go, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    for i, line in enumerate(lines):
        if CONST_RE.match(line.rstrip("\n")):
            del lines[i]
            break
    with open(errcode_go, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


def _drop_map_entry(path: str) -> None:
    """注入②：前端映射删一条。"""
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    for i, line in enumerate(lines):
        if MAP_ENTRY_RE.match(line.rstrip("\n")):
            del lines[i]
            break
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


def _drop_locale_entry(path: str) -> None:
    """注入③：某门语言删一条。"""
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    for i, line in enumerate(lines):
        if LOCALE_ENTRY_RE.match(line.rstrip("\n")):
            del lines[i]
            break
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


def _rename_baseline_entry(path: str) -> None:
    """注入④：基线里改常量名（模拟「码号被复用给另一种语义」）。"""
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    codes = data["codes"]
    first = sorted(codes)[0]
    codes[first] = codes[first] + "Renamed"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")


def _run_checks(contracts_dir: str, frontend_dir: str | None) -> tuple[int, str]:
    """跑全部断言 ⇒ (0=绿, 1=红, 消息)。"""
    import contextlib
    import io

    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            const_name_to_code, baseline, const_codes, fmap, locales = collect(
                contracts_dir, frontend_dir
            )
            check_baseline(const_name_to_code, baseline)
            if fmap is not None:
                check_frontend_map(const_codes, fmap)
                check_locales(const_codes, locales or {})
    except GateError as exc:
        return 1, str(exc)
    return 0, buf.getvalue()


def cmd_selfcheck(args: argparse.Namespace) -> int:
    contracts_src = args.contracts or os.path.join(args.root, "contracts")
    frontend_src = args.frontend
    if frontend_src is None:
        candidate = os.path.join(args.root, "frontend-core")
        if os.path.isdir(candidate):
            frontend_src = candidate
    if frontend_src is None:
        raise GateError(
            "selfcheck 需要 frontend-core 在场（要注入前端侧故障）——用 --frontend <dir> 指定"
        )

    rc, out = _run_checks(contracts_src, frontend_src)
    if rc != 0:
        raise GateError(f"selfcheck 基线态竟然不绿（门禁自身坏了）：{out}")
    _ok("基线态：干净副本 ⇒ 绿")

    faults = (
        ("① 契约删掉一个已发布码", "contract"),
        ("② 前端映射删掉一条", "map"),
        ("③ 中文语言包删掉一条", "locale"),
        ("④ 基线里把常量改名（码号复用）", "baseline"),
    )
    for title, kind in faults:
        # 每次注入都在**干净副本**上做 ⇒ 四组负对照互不污染。
        with tempfile.TemporaryDirectory(prefix="pb-errcode-fault-") as tmp2:
            c2 = os.path.join(tmp2, "contracts")
            f2 = os.path.join(tmp2, "frontend-core")
            _copy_tree(contracts_src, c2)
            _copy_tree(frontend_src, f2)
            if kind == "contract":
                _drop_contract_code(os.path.join(c2, "errcode", "errcode.go"))
            elif kind == "map":
                _drop_map_entry(os.path.join(f2, "src", "utils", "api-interceptor.ts"))
            elif kind == "locale":
                _drop_locale_entry(
                    os.path.join(f2, "src", "i18n", "locales", "zh-CN.ts")
                )
            else:
                _rename_baseline_entry(os.path.join(c2, "errcode", "baseline.json"))
            rc, msg = _run_checks(c2, f2)
            if rc == 0:
                raise GateError(
                    f"负对照 {title} **没有变红** ⇒ 门禁空转（这条判据没牙齿）"
                )
            _ok(f"负对照 {title} ⇒ 判红：{msg}")
    print(f"{GREEN}✓ 错误码跨仓对账 selfcheck 通过（4 组负对照均判红）{RESET}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="错误码跨仓对账（L2 层）")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("validate", "selfcheck"):
        p = sub.add_parser(name)
        p.add_argument("--root", required=True, help="hub 仓根目录")
        p.add_argument("--contracts", help="contracts 仓目录（默认 <root>/contracts）")
        p.add_argument("--frontend", help="frontend-core 仓目录（默认 <root>/frontend-core）")
        p.add_argument(
            "--require-frontend",
            action="store_true",
            help="frontend-core 不在位即判红（CI 用；本地单仓检出时不要开）",
        )
    args = parser.parse_args(argv)
    try:
        if args.cmd == "validate":
            return cmd_validate(args)
        return cmd_selfcheck(args)
    except GateError as exc:
        _err(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
