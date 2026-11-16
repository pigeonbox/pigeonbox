#!/usr/bin/env python3
"""安装版本分布聚合（pigeonbox#385）。

把维护者收到的诊断包 / 匿名上报 JSON 聚合成「版本 × 平台 × 架构」分布，
回答「某个安全修复覆盖了多少活跃实例」。

输入：
  - `pb doctor --export` 产出的诊断包（信封含 diagnostics 段）；
  - 开启 `PB_UPDATE_REPORT_URL` 后上报方 POST 的 JSON body（一行一条）；
  - 任何上述形态的 JSON 文件（自动判别），或 JSONL 文件（每行一条）。

用法：
  python3 scripts/version_distribution.py reports/*.json
  python3 scripts/version_distribution.py --latest 5.9.0 collected.jsonl
  cat collected.jsonl | python3 scripts/version_distribution.py -
  python3 scripts/version_distribution.py --json reports/   # 机器读

「落后 N 个版本」需要版本序列：传 `--latest` 并配合 `--series`（逗号分隔的
历史版本，旧→新），或在含 GitHub releases 的文件上自行比对。缺省只做分布。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from collections import Counter, defaultdict


def records_from_file(path: str) -> list[dict]:
    """读一个文件：JSON 数组/对象、诊断包信封、或 JSONL。"""
    raw = open(path, encoding="utf-8").read().strip()
    if not raw:
        return []
    try:
        doc = json.loads(raw)
        if isinstance(doc, list):
            return [d for d in doc if isinstance(d, dict)]
        if isinstance(doc, dict):
            # 诊断包信封：取 diagnostics 段（含版本/平台/架构）。
            if isinstance(doc.get("diagnostics"), dict):
                return [doc["diagnostics"]]
            return [doc]
    except json.JSONDecodeError:
        pass
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(d, dict):
            out.append(d)
    return out


def expand(paths: list[str]) -> list[str]:
    files: list[str] = []
    for p in paths:
        if p == "-":
            files.append(p)
        elif os.path.isdir(p):
            files.extend(sorted(glob.glob(os.path.join(p, "*"))))
        else:
            files.extend(sorted(glob.glob(p)) or [p])
    return files


def norm(d: dict) -> dict:
    """统一字段名（诊断包与上报 body 的字段名一致；仅做缺省）。"""
    return {
        "version": str(d.get("version") or "").strip(),
        "platform": str(d.get("platform") or "-").strip() or "-",
        "arch": str(d.get("arch") or "-").strip() or "-",
        "upgrade_from": str(d.get("upgrade_from") or "").strip(),
        "schema_version": str(d.get("schema_version") or "").strip(),
        "instance_id": str(d.get("instance_id") or "").strip(),
        "checked_at": str(d.get("checked_at") or "").strip(),
    }


def version_key(v: str):
    """宽松 semver：5.8.0 / v5.8.0 / 5.8 / 5.8.0-rc1。"""
    v = v.strip().lstrip("vV")
    core = v.split("-", 1)[0].split("+", 1)[0]
    parts = []
    for p in core.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def main() -> int:
    ap = argparse.ArgumentParser(description="PigeonBox 安装版本分布聚合（hub#385）")
    ap.add_argument("inputs", nargs="+", help="诊断包/上报 JSON（文件、目录、glob；- = stdin）")
    ap.add_argument("--latest", default="", help="最新版本（算「落后 N 个版本」用）")
    ap.add_argument("--series", default="", help="历史版本序列（逗号分隔，旧→新）；缺省从数据自身排序")
    ap.add_argument("--json", action="store_true", help="输出机器读 JSON")
    args = ap.parse_args()

    recs: list[dict] = []
    for f in expand(args.inputs):
        if f == "-":
            raw = sys.stdin.read()
            try:
                d = json.loads(raw)
                if isinstance(d, list):
                    recs.extend(x for x in d if isinstance(x, dict))
                elif isinstance(d, dict):
                    recs.append(d.get("diagnostics") if isinstance(d.get("diagnostics"), dict) else d)
            except json.JSONDecodeError:
                for line in raw.splitlines():
                    if line.strip():
                        try:
                            d = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if isinstance(d, dict):
                            recs.append(d)
        else:
            recs.extend(records_from_file(f))

    rows = [norm(r) for r in recs if norm(r)["version"]]
    if not rows:
        print("没有可解析的记录（期望含 version/platform/arch 的 JSON）", file=sys.stderr)
        return 1

    total = len(rows)
    by_version = Counter(r["version"] for r in rows)
    by_platform = Counter(r["platform"] for r in rows)
    by_arch = Counter(r["arch"] for r in rows)
    by_pair = Counter((r["version"], r["platform"]) for r in rows)
    # 实例去重口径：有 instance_id 时按 ID 去重（同一实例多次上报只算一次）。
    uniq = {}
    for r in rows:
        key = r["instance_id"] or f"{r['version']}|{r['platform']}|{r['arch']}"
        uniq[key] = r
    uniq_rows = list(uniq.values())

    # 落后版本数
    series = [s.strip() for s in args.series.split(",") if s.strip()]
    if not series:
        series = sorted({r["version"] for r in uniq_rows}, key=version_key)
    if args.latest:
        series = [v for v in series if version_key(v) < version_key(args.latest)] + [args.latest]
    lag = {}
    if series:
        for v in {r["version"] for r in uniq_rows}:
            try:
                idx = series.index(v)
                lag[v] = len(series) - 1 - idx
            except ValueError:
                lag[v] = None

    if args.json:
        print(json.dumps({
            "total_reports": total,
            "unique_instances": len(uniq_rows),
            "versions": dict(by_version),
            "platforms": dict(by_platform),
            "arches": dict(by_arch),
            "version_platform": {f"{v}/{p}": n for (v, p), n in by_pair.items()},
            "lag_versions": lag,
            "series": series,
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"记录 {total} 条 · 去重实例 {len(uniq_rows)} 个")
    print("\n== 版本分布 ==")
    for v, n in sorted(by_version.items(), key=lambda kv: version_key(kv[0]), reverse=True):
        pct = n * 100.0 / total
        extra = ""
        if lag.get(v) is not None:
            extra = "（最新）" if lag[v] == 0 else f"（落后 {lag[v]} 个版本）"
        print(f"  {v:<12} {n:>5}  {pct:5.1f}%{extra}")
    print("\n== 平台 ==")
    for p, n in by_platform.most_common():
        print(f"  {p:<12} {n:>5}  {n*100.0/total:5.1f}%")
    print("\n== 架构 ==")
    for a, n in by_arch.most_common():
        print(f"  {a:<12} {n:>5}  {n*100.0/total:5.1f}%")
    print("\n== 版本/平台 ==")
    for (v, p), n in sorted(by_pair.items(), key=lambda kv: (version_key(kv[0][0]), kv[0][1]), reverse=True):
        print(f"  {v:<12} {p:<12} {n:>5}")
    return 0


if __name__ == "__main__":
    sys.exit(main())