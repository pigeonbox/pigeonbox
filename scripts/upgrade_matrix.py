#!/usr/bin/env python3
"""N-1/N-2 制品级升级矩阵：静态矩阵判定（hub#660 · L7 升级层）。

为什么要有这道门禁（2026-11-18 生态技术评审，L7 升级层）：
    生态此前只有「升级**失败**可恢复」的断言（hub scripts/check-upgrade-recoverability.sh
    收编 qnap/synology/fnos 三端），**没有**「从上一车/上上车的**真实制品**装起来 →
    升级到当前车 → 数据完整性对账」这条链的任何覆盖 ⇒ N-1→N 的**制品级**升级路径
    在仓内是零覆盖的盲区。

本文件是**静态矩阵**（PR 期可跑的那一半）的实现：
    ① 列车序列：从 release/train.yaml 的 **git 历史**解析 N / N-1 / N-2
       （历史台账不新建——历史提交里就是当时那车）；
    ② 产物存在性：每辆车的 release/manifest.json 必须声明全部终端产物
       （7 平台包 + server/frontend 镜像）；
    ③ 钉版一致：该车 train.yaml 声明的钉版 == **产物内嵌**的钉版
       （fnos/qnap/openwrt 的 DEPS.env、synology/ugreen/terramaster 的镜像钉版、
       desktop 的 VERSION），取自**平台仓的发布 tag**（= 当轮真实产物）；
    ④ 钉版单调：N-2 ≤ N-1 ≤ N（不许倒退，也不许 N 比 N-1 老）；
    ⑤ 远端产物存在性（可选层）：hub Release 上 <plat>-v<X> / v<X> 是否真的存在。
       远端**网络不可用**时降级为「未扫描（登记在案）」——「没扫到」≠「扫过且通过」。

零第三方依赖（只用标准库）⇒ 门禁不因装依赖失败而红。
子命令：
    check       跑静态矩阵判定（判定形态）
    plan        输出某辆车的产物计划（JSON，供发布后升级演练用）
    selfcheck   负对照：注入各类坏形态 ⇒ 必须判红；好形态 ⇒ 放行

用法（由 scripts/check-upgrade-matrix.sh 调用，也可直接跑）：
    python3 scripts/upgrade_matrix.py check --root <hub根> [--platforms-root <dir>]
    python3 scripts/upgrade_matrix.py plan  --root <hub根> [--train <版本>]
    python3 scripts/upgrade_matrix.py selfcheck --root <hub根>
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

TRAIN_REL = os.path.join("release", "train.yaml")
MANIFEST_REL = os.path.join("release", "manifest.json")

# 终端产物平台（每个平台必须有 ≥1 个 package 产物）
PACKAGE_PLATFORMS = ["fnos", "openwrt", "qnap", "synology", "ugreen", "terramaster", "desktop"]
# 镜像产物（server / frontend）
IMAGE_NAMES = ["server", "frontend"]
# 内嵌 core/frontend-core/p2pc 钉版的平台（DEPS.env 口径）
DEPS_PLATFORMS = ["fnos", "openwrt", "qnap"]
# 内嵌镜像钉版的编排平台（env.example 的 PB_IMAGE_TAG 口径）
COMPOSE_PLATFORMS = ["synology", "ugreen", "terramaster"]

DEFAULT_REPO = "pigeonbox/pigeonbox"
DEFAULT_API = "https://api.github.com"


class MatrixError(Exception):
    """矩阵违规：消息即判红理由。"""


# ── 小工具 ────────────────────────────────────────────────────────────────
def sh(args, cwd, check=True, binary=False):
    """跑一条命令；check=True 时非 0 退出即抛。"""
    try:
        p = subprocess.run(
            args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
        )
    except OSError as exc:
        if check:
            raise MatrixError("命令执行失败 %s：%s" % (" ".join(args), exc))
        return (1, "", str(exc))
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise MatrixError(
            "命令失败（rc=%d）%s：%s" % (p.returncode, " ".join(args), (err or out).strip())
        )
    return (p.returncode, out, err)


def git(root, *args, check=True):
    rc, out, err = sh(["git"] + list(args), cwd=root, check=check)
    return out if check else (rc, out, err)


def parse_kv(text):
    """解析 train.yaml 形态的 key: value（只取顶层 key，忽略空值）。"""
    data = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key and val:
            data[key] = val
    return data


def ver_tuple(v):
    """'v0.42.0' / '6.1.0' → (0,42,0)；非数字段按 0。"""
    v = (v or "").strip().lstrip("v")
    parts = re.split(r"[.\-+]", v)
    out = []
    for p in parts[:3]:
        m = re.match(r"^(\d+)", p)
        out.append(int(m.group(1)) if m else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out)


def find_platform_repo(platforms_root, name):
    """平台仓定位：platforms_root/<name>；desktop 额外看 ../desktop（工作区布局）。"""
    cands = [os.path.join(platforms_root, name)]
    if name == "desktop":
        cands.append(os.path.join(platforms_root, os.pardir, "desktop"))
    for c in cands:
        if os.path.isdir(os.path.join(c, ".git")) or os.path.isfile(os.path.join(c, ".git")):
            return os.path.abspath(c)
    return None


def read_at(repo, ref, path):
    """git show <ref>:<path>；不存在返回 None。"""
    rc, out, _ = sh(["git", "show", "%s:%s" % (ref, path)], cwd=repo, check=False)
    if rc != 0:
        return None
    return out


def grep_at(repo, ref, pattern):
    """git grep <pattern> <ref> —— 返回命中行列表（无命中返回 []）。"""
    rc, out, _ = sh(
        ["git", "grep", "-h", "-e", pattern, ref], cwd=repo, check=False
    )
    if rc not in (0, 1):
        return None
    return [ln for ln in out.splitlines() if ln.strip()]


def kv_in(text):
    """DEPS.env / env.example 形态的 KEY=VALUE。"""
    data = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        data[key.strip()] = val.strip().strip('"').strip("'")
    return data


# ── 列车序列（真相源 = release/train.yaml 的 git 历史） ─────────────────────
class Train(object):
    def __init__(self, number, state, commit, train_text, manifest_text):
        self.number = number
        self.state = state
        self.commit = commit
        self.train_text = train_text
        self.manifest_text = manifest_text
        self.data = parse_kv(train_text)

    def get(self, key, default=""):
        return self.data.get(key, default)

    @property
    def manifest(self):
        try:
            return json.loads(self.manifest_text)
        except Exception:
            return None

    @property
    def label(self):
        return self.number


def resolve_trains(root):
    """按 git 历史解析已发货车次（最新在前）。

    锚点取「最后一辆 state=shipped 的车」而不是工作区 train.yaml 的车号：
    bump PR 期间工作区车号是**在途**（state=draft）那辆，其产物尚未发布 ⇒
    以它为锚点会必然假红。已发货车次才有 manifest、有平台 tag、有真实产物。

    manifest 按**自描述**口径取（manifest.json 自带 train 字段）⇒
    「只改了 manifest 没改 train.yaml」的提交（列车打 tag 后重生成 manifest）
    不会被漏掉，也不会把上一车的 manifest 误当成本车的。
    """
    rc, out, _ = sh(
        ["git", "log", "--format=%H", "--", TRAIN_REL, MANIFEST_REL], cwd=root, check=False
    )
    if rc != 0:
        raise MatrixError("读不到 %s 的 git 历史（不是 git 仓？）" % TRAIN_REL)
    trains = {}
    manifests = {}
    for commit in [c for c in out.split() if c]:
        text = read_at(root, commit, TRAIN_REL)
        if text is not None:
            data = parse_kv(text)
            number = data.get("train", "")
            if number and number not in trains:
                trains[number] = Train(number, data.get("state", ""), commit, text, "")
        mtext = read_at(root, commit, MANIFEST_REL)
        if mtext is not None:
            try:
                mtrain = json.loads(mtext).get("train", "")
            except Exception:
                mtrain = ""
            if mtrain and mtrain not in manifests:
                manifests[mtrain] = (commit, mtext)
    for number, train in trains.items():
        found = manifests.get(number)
        if found:
            train.commit = found[0]
            train.manifest_text = found[1]
    ships = [t for t in trains.values() if t.state == "shipped"]
    if not ships:
        raise MatrixError(
            "git 历史里找不到任何 state=shipped 的车次（train.yaml 历史异常？）"
        )
    return ships


def train_by_number(trains, number):
    for t in trains:
        if t.number == number:
            return t
    return None


# ── 判定项 ②：产物存在性（以该车 manifest 为声明面） ───────────────────────
def check_artifacts(train, problems, notes):
    manifest = train.manifest
    if manifest is None:
        problems.append("%s：manifest 缺失或不可解析（release/manifest.json @ %s）"
                        % (train.label, train.commit[:8]))
        return
    mtrain = manifest.get("train", "")
    if mtrain != train.number:
        problems.append("%s：manifest 声明的车号是 %s，与 train.yaml 的 %s 不符"
                        % (train.label, mtrain or "(空)", train.number))
    kinds = {}
    for art in manifest.get("artifacts", []):
        if art.get("kind") == "image":
            kinds.setdefault("image", set()).add(art.get("name", ""))
        else:
            kinds.setdefault("package", set()).add(art.get("platform", ""))
    pkgs = kinds.get("package", set())
    imgs = kinds.get("image", set())
    missing = [p for p in PACKAGE_PLATFORMS if p not in pkgs]
    missing_img = [i for i in IMAGE_NAMES if i not in imgs]
    if missing or missing_img:
        problems.append(
            "%s：终端产物不全（缺平台包 %s；缺镜像 %s）"
            % (train.label, ",".join(missing) or "无", ",".join(missing_img) or "无")
        )
    else:
        notes.append("%s：产物齐备（%d 平台包 + %d 镜像）"
                     % (train.label, len(pkgs), len(imgs)))


# ── 判定项 ③：声明钉版 == 产物内嵌钉版 ────────────────────────────────────
def embedded_pins(plat, repo, train):
    """取某平台某车 tag 里的内嵌钉版；返回 (dict, 说明)。取不到返回 (None, 原因)。"""
    if plat in DEPS_PLATFORMS:
        tag = "v%s" % train.number
        text = read_at(repo, tag, "DEPS.env")
        if text is None:
            return None, "平台仓 %s 缺 tag %s 的 DEPS.env" % (plat, tag)
        data = kv_in(text)
        return (
            {
                "core": data.get("CORE_PIN", ""),
                "frontend_core": data.get("FRONTEND_CORE_PIN", ""),
                "p2p": data.get("P2PC_REF", ""),
            },
            "DEPS.env@%s" % tag,
        )
    if plat in COMPOSE_PLATFORMS:
        tag = "v%s" % train.number
        text = None
        for cand in ("deploy/env.example", "spk/package/env.example", "spk/env.example",
                     "env.example"):
            text = read_at(repo, tag, cand)
            if text is not None:
                break
        if text is None:
            hits = grep_at(repo, tag, "PB_IMAGE_TAG=")
            if hits:
                text = hits[0]
        if text is None:
            return None, "平台仓 %s 缺 tag %s 的镜像钉版声明" % (plat, tag)
        data = kv_in(text)
        image_tag = data.get("PB_IMAGE_TAG", "")
        if not image_tag:
            hits = grep_at(repo, tag, "PB_IMAGE_TAG=")
            for hit in hits:
                m = re.search(r"PB_IMAGE_TAG[=:}]*([0-9][^\"'\s,}]*)", hit)
                if m:
                    image_tag = m.group(1)
                    break
        return {"image": image_tag}, "env.example@%s" % tag
    if plat == "desktop":
        tag = "desktop-v%s" % train.number
        text = read_at(repo, tag, "VERSION")
        if text is None:
            return None, "平台仓 desktop 缺 tag %s 的 VERSION" % tag
        return {"version": text.strip()}, "VERSION@%s" % tag
    return None, "平台 %s 无内嵌钉版口径" % plat


def declared_pins(train, plat):
    """该车 train.yaml 对某平台声明的钉版。"""
    if plat in DEPS_PLATFORMS:
        return (
            {
                "core": train.get("terminal.%s.core_pin" % plat),
                "frontend_core": train.get("terminal.%s.frontend_core_pin" % plat),
                "p2p": train.get("terminal.p2pc_ref"),
            },
            ["core", "frontend_core", "p2p"],
        )
    if plat in COMPOSE_PLATFORMS:
        return {"image": train.get("images.server")}, ["image"]
    if plat == "desktop":
        return {"version": train.get("terminal.desktop.version")}, ["version"]
    return {}, []


def check_embedded_pins(train, plat, repo, problems, notes):
    emb, emb_src = embedded_pins(plat, repo, train)
    if emb is None:
        problems.append("%s/%s：取不到产物内嵌钉版（%s）" % (train.label, plat, emb_src))
        return
    dec, keys = declared_pins(train, plat)
    for key in keys:
        want = dec.get(key, "")
        got = emb.get(key, "")
        if not want:
            problems.append("%s/%s：train.yaml 未声明该钉版（%s）" % (train.label, plat, key))
            continue
        if not got:
            problems.append("%s/%s：产物内嵌缺该钉版（%s，来源 %s）"
                            % (train.label, plat, key, emb_src))
            continue
        if want != got:
            problems.append(
                "%s/%s：钉版声明与产物内嵌不一致（%s：声明 %s / 内嵌 %s，来源 %s）"
                % (train.label, plat, key, want, got, emb_src)
            )
    notes.append("%s/%s：钉版一致（%s）" % (train.label, plat, emb_src))


# ── 判定项 ④：钉版单调（不许倒退 / 不许 N 比 N-1 老） ──────────────────────
MONO_KEYS = [
    ("lib.core", "core"),
    ("lib.frontend-core", "frontend_core"),
    ("lib.p2p", "p2p"),
]


def check_monotonic(trains, problems, notes):
    """N-2 ≤ N-1 ≤ N（同向升级）。"""
    for i in range(len(trains) - 1):
        newer = trains[i]
        older = trains[i + 1]
        for key, _ in MONO_KEYS:
            a = newer.get(key)
            b = older.get(key)
            if not a or not b:
                continue
            if ver_tuple(a) < ver_tuple(b):
                problems.append(
                    "钉版倒退：%s 的 %s=%s 比 %s 的 %s=%s 老"
                    % (newer.label, key, a, older.label, key, b)
                )
            elif ver_tuple(a) > ver_tuple(b):
                notes.append(
                    "%s→%s：%s 同向升级（%s → %s）" % (older.label, newer.label, key, b, a)
                )
            else:
                notes.append(
                    "%s→%s：%s 未变（%s）" % (older.label, newer.label, key, a)
                )


# ── 判定项 ⑤：远端产物存在性（网络不可用 ⇒ 降级为未扫描） ──────────────────
def remote_release_status(api_base, repo, tag, token, timeout=10):
    """返回 (state, detail)：state ∈ found / missing / unscanned。"""
    url = "%s/repos/%s/releases/tags/%s" % (api_base.rstrip("/"), repo, tag)
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "pigeonbox-upgrade-matrix"})
    if token:
        req.add_header("Authorization", "Bearer %s" % token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            try:
                data = json.loads(body)
            except Exception:
                return "found", "release %s 存在（响应非 JSON，按存在处理）" % tag
            if data.get("draft"):
                return "missing", "release %s 是草稿（未正式发布）" % tag
            return "found", "release %s 存在（assets %d 个）" % (
                tag, len(data.get("assets", []))
            )
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return "missing", "release %s 不存在（HTTP 404）" % tag
        return "unscanned", "未扫描：release %s 查询失败（HTTP %d，限流/权限？）" % (tag, exc.code)
    except Exception as exc:  # 网络不可达 / DNS / 超时
        return "unscanned", "未扫描：release %s 查询失败（网络不可用：%s）" % (tag, exc)


def check_remote(trains, opts, problems, notes, skipped):
    for train in trains:
        tags = ["v%s" % train.number]
        for plat in PACKAGE_PLATFORMS:
            tags.append("%s-v%s" % (plat, train.number))
        for tag in tags:
            state, detail = remote_release_status(
                opts.api_base, opts.repo, tag, opts.token
            )
            if state == "found":
                notes.append("%s：%s" % (train.label, detail))
            elif state == "missing":
                problems.append("%s：远端产物缺失 —— %s" % (train.label, detail))
            else:
                skipped.append("%s：%s" % (train.label, detail))


# ── check 子命令 ──────────────────────────────────────────────────────────
def cmd_check(opts):
    root = os.path.abspath(opts.root)
    if not os.path.isdir(root):
        raise MatrixError("hub 根不存在：%s" % root)
    trains = resolve_trains(root)
    spans = ["N", "N-1", "N-2"]
    window = trains[:3]
    if len(window) < 3:
        raise MatrixError(
            "已发货车次不足 3 辆（只有 %d 辆）⇒ 无法建立 N/N-1/N-2 矩阵"
            % len(window)
        )
    platforms_root = os.path.abspath(opts.platforms_root or root)
    problems = []
    notes = []
    skipped = []

    print("── 升级矩阵静态判定（锚点：最后一辆已发货车次 %s）" % window[0].label)
    inflight = ""
    cur_text = read_at(root, "HEAD", TRAIN_REL)
    if cur_text is not None:
        cur = parse_kv(cur_text)
        if cur.get("train") and cur.get("train") != window[0].label:
            inflight = cur.get("train")
            print(
                "  ! 当前在途车次 %s（state=%s，未发货）⇒ 矩阵锚定在最后一辆已发货车次 %s"
                % (inflight, cur.get("state", "?"), window[0].label)
            )

    # ② 产物存在性
    for train in window:
        check_artifacts(train, problems, notes)

    # ③ 声明钉版 == 产物内嵌钉版（平台仓的发布 tag = 当轮真实产物）
    for train in window:
        for plat in PACKAGE_PLATFORMS:
            repo = find_platform_repo(platforms_root, plat)
            if repo is None:
                msg = "%s/%s：平台仓不在位（%s）⇒ 该端钉版未核对" % (
                    train.label, plat, os.path.join(platforms_root, plat)
                )
                skipped.append(msg)
                if opts.require_platform_repos:
                    problems.append(msg)
                continue
            check_embedded_pins(train, plat, repo, problems, notes)

    # ④ 钉版单调
    check_monotonic(window, problems, notes)

    # ⑤ 远端产物存在性
    if opts.remote:
        check_remote(window, opts, problems, notes, skipped)
        if opts.require_remote and skipped:
            for line in skipped:
                problems.append("%s（要求必须扫到 ⇒ 降级不放行）" % line)
    else:
        skipped.append("远端产物存在性：未启用（UPGRADE_MATRIX_REMOTE=0）")

    for line in notes:
        print("  ✓ %s" % line)
    for line in skipped:
        print("  ⏳ %s" % line)
    if problems:
        print("")
        for line in problems:
            print("  ✗ %s" % line)
        print("✗ 升级矩阵静态判定失败（%d 项）" % len(problems))
        return 1
    print("✓ 升级矩阵静态判定通过（%s / %s / %s）"
          % (window[0].label, window[1].label, window[2].label))
    return 0


# ── plan 子命令（供发布后升级演练用） ─────────────────────────────────────
def cmd_plan(opts):
    root = os.path.abspath(opts.root)
    trains = resolve_trains(root)
    if opts.train:
        train = train_by_number(trains, opts.train)
        if train is None:
            raise MatrixError("找不到已发货车次 %s" % opts.train)
    else:
        train = trains[0]
    manifest = train.manifest
    if manifest is None:
        raise MatrixError("%s 的 manifest 不可解析" % train.label)
    plan = {
        "train": train.label,
        "commit": train.commit,
        "declared": {
            k: train.get(k)
            for k in ("lib.core", "lib.frontend-core", "lib.p2p", "images.server",
                      "terminal.p2pc_ref")
            if train.get(k)
        },
        "artifacts": [],
    }
    for art in manifest.get("artifacts", []):
        plan["artifacts"].append(
            {
                "kind": art.get("kind", ""),
                "name": art.get("name", ""),
                "platform": art.get("platform", ""),
                "ref": art.get("ref", ""),
                "sha256": art.get("sha256", ""),
                "url": art.get("url", ""),
                "sizeBytes": art.get("sizeBytes", 0),
            }
        )
    print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


# ── selfcheck 子命令（负对照：注入坏形态必须判红） ─────────────────────────
def git_in(repo, *args):
    return git(repo, *args)


def make_fixture(base):
    """构造一个自洽的三车 fixture 仓（hub + 平台仓），供负对照用。"""
    hub = os.path.join(base, "hub")
    os.makedirs(os.path.join(hub, "release"))
    git_in(hub, "init", "-q", "-b", "main")
    git_in(hub, "config", "user.email", "fixture@example.invalid")
    git_in(hub, "config", "user.name", "fixture")

    platform_specs = {
        "fnos": ("v%s", "DEPS.env",
                 "CORE_PIN=v0.10.0\nFRONTEND_CORE_PIN=v0.5.0\nP2PC_REF=v0.9.0\n"),
        "qnap": ("v%s", "DEPS.env",
                 "CORE_PIN=v0.10.0\nFRONTEND_CORE_PIN=v0.5.0\nP2PC_REF=v0.9.0\n"),
        "openwrt": ("v%s", "DEPS.env",
                    "CORE_PIN=v0.10.0\nFRONTEND_CORE_PIN=v0.5.0\nP2PC_REF=v0.9.0\n"),
        "synology": ("v%s", "deploy/env.example", "PB_IMAGE_TAG=%s\n"),
        "ugreen": ("v%s", "deploy/env.example", "PB_IMAGE_TAG=%s\n"),
        "terramaster": ("v%s", "deploy/env.example", "PB_IMAGE_TAG=%s\n"),
        "desktop": ("desktop-v%s", "VERSION", "%s\n"),
    }
    platforms_root = os.path.join(base, "platforms")
    os.makedirs(platforms_root)
    for name, (tagfmt, path, body) in platform_specs.items():
        repo = os.path.join(platforms_root, name)
        os.makedirs(repo)
        git_in(repo, "init", "-q", "-b", "main")
        git_in(repo, "config", "user.email", "fixture@example.invalid")
        git_in(repo, "config", "user.name", "fixture")

    # 三辆车：1.0.0 / 2.0.0 / 3.0.0（逐车升 core/frontend-core/p2p）
    pins = {
        "1.0.0": ("v0.10.0", "v0.5.0", "v0.9.0"),
        "2.0.0": ("v0.11.0", "v0.6.0", "v0.9.1"),
        "3.0.0": ("v0.12.0", "v0.7.0", "v0.9.2"),
    }
    for num in ("1.0.0", "2.0.0", "3.0.0"):
        core, fe, p2p = pins[num]
        train_lines = [
            "schema: \"1\"",
            "train: %s" % num,
            "state: shipped",
            "lib.core: %s" % core,
            "lib.frontend-core: %s" % fe,
            "lib.p2p: %s" % p2p,
            "images.server: %s" % num,
            "images.frontend: %s" % num,
            "terminal.p2pc_ref: %s" % p2p,
            "terminal.desktop.tag: desktop-v%s" % num,
            "terminal.desktop.version: %s" % num,
        ]
        for plat in DEPS_PLATFORMS:
            train_lines.append("terminal.%s.tag: v%s" % (plat, num))
            train_lines.append("terminal.%s.version: %s" % (plat, num))
            train_lines.append("terminal.%s.core_pin: %s" % (plat, core))
            train_lines.append("terminal.%s.frontend_core_pin: %s" % (plat, fe))
        for plat in COMPOSE_PLATFORMS:
            train_lines.append("terminal.%s.tag: v%s" % (plat, num))
            train_lines.append("terminal.%s.version: %s" % (plat, num))
        with open(os.path.join(hub, TRAIN_REL), "w") as fh:
            fh.write("\n".join(train_lines) + "\n")

        arts = []
        for plat in PACKAGE_PLATFORMS:
            arts.append({"kind": "package", "name": "pkg-%s" % plat, "platform": plat,
                         "ref": "%s-v%s" % (plat, num), "sha256": "0" * 64,
                         "sizeBytes": 1, "url": "https://example.invalid/%s" % plat})
        for img in IMAGE_NAMES:
            arts.append({"kind": "image", "name": img, "platform": "linux/amd64",
                         "ref": "%s:%s" % (img, num), "sha256": "0" * 64,
                         "sizeBytes": 1, "url": "https://example.invalid/%s" % img})
        with open(os.path.join(hub, MANIFEST_REL), "w") as fh:
            json.dump({"schema": "2", "train": num, "artifacts": arts}, fh,
                      ensure_ascii=False, sort_keys=True)
        git_in(hub, "add", "-A")
        git_in(hub, "commit", "-q", "-m", "train %s" % num)

        for name, (tagfmt, path, body) in platform_specs.items():
            repo = os.path.join(platforms_root, name)
            content = body % ((num,) if "%s" in body and name not in DEPS_PLATFORMS else ())
            if name in DEPS_PLATFORMS:
                content = "CORE_PIN=%s\nFRONTEND_CORE_PIN=%s\nP2PC_REF=%s\n" % (
                    core, fe, p2p)
            target = os.path.join(repo, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w") as fh:
                fh.write(content)
            git_in(repo, "add", "-A")
            git_in(repo, "commit", "-q", "-m", "release %s" % num)
            git_in(repo, "tag", tagfmt % num)
    return hub, platforms_root


def run_check(hub, platforms_root, extra=None):
    args = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "upgrade_matrix.py"),
            "check", "--root", hub, "--platforms-root", platforms_root, "--no-remote"]
    if extra:
        args += extra
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    return (p.returncode, p.stdout.decode("utf-8", "replace"))


def cmd_selfcheck(opts):
    rc_final = 0
    base = tempfile.mkdtemp(prefix="pb-upgrade-matrix-selfcheck-")
    try:
        hub, platforms_root = make_fixture(base)
        rc, out = run_check(hub, platforms_root)
        if rc != 0:
            print("  ✗ 自检①：自洽 fixture ⇒ 门禁却判红")
            print(out)
            rc_final = 1
        else:
            print("  ✓ 自检①：自洽 fixture（N/N-1/N-2 三车 + 7 平台 + 2 镜像）⇒ 放行")

        # ② 某车缺一个平台产物 ⇒ 判红
        manifest_path = os.path.join(hub, MANIFEST_REL)
        with open(manifest_path) as fh:
            manifest = json.load(fh)
        keep = [a for a in manifest["artifacts"]
                if not (a.get("kind") == "package" and a.get("platform") == "qnap")]
        with open(manifest_path, "w") as fh:
            json.dump({"schema": "2", "train": manifest["train"],
                       "artifacts": keep}, fh, ensure_ascii=False)
        git_in(hub, "commit", "-q", "-am", "drop qnap artifact")
        rc, out = run_check(hub, platforms_root)
        if rc == 0:
            print("  ✗ 自检②：某车缺平台产物 ⇒ 门禁仍绿")
            rc_final = 1
        else:
            print("  ✓ 自检②：某车缺平台产物 ⇒ 判红")
        git_in(hub, "reset", "-q", "--hard", "HEAD~1")

        # ③ 产物内嵌钉版与该车声明不一致 ⇒ 判红
        fnos = os.path.join(platforms_root, "fnos")
        with open(os.path.join(fnos, "DEPS.env"), "a") as fh:
            fh.write("# drift\n")
        with open(os.path.join(fnos, "DEPS.env")) as fh:
            body = fh.read().replace("CORE_PIN=v0.12.0", "CORE_PIN=v0.99.0")
        with open(os.path.join(fnos, "DEPS.env"), "w") as fh:
            fh.write(body)
        git_in(fnos, "commit", "-q", "-am", "drift core pin")
        git_in(fnos, "tag", "-f", "v3.0.0")
        rc, out = run_check(hub, platforms_root)
        if rc == 0:
            print("  ✗ 自检③：产物内嵌钉版与该车声明不一致 ⇒ 门禁仍绿")
            rc_final = 1
        else:
            print("  ✓ 自检③：产物内嵌钉版与该车声明不一致 ⇒ 判红")
        # 复原：回到 "release 3.0.0" 那次提交，并让 tag 重新指向它
        git_in(fnos, "reset", "-q", "--hard", "HEAD~1")
        git_in(fnos, "tag", "-f", "v3.0.0")

        # ④ 钉版倒退（N-1 的钉版比 N 新）⇒ 判红
        hub2 = os.path.join(base, "hub2")
        shutil.copytree(hub, hub2)
        train_path = os.path.join(hub2, TRAIN_REL)
        with open(train_path) as fh:
            body = fh.read().replace("lib.core: v0.12.0", "lib.core: v0.08.0")
        with open(train_path, "w") as fh:
            fh.write(body)
        git_in(hub2, "commit", "-q", "-am", "core pin rollback")
        rc, out = run_check(hub2, platforms_root)
        if rc == 0:
            print("  ✗ 自检④：钉版倒退 ⇒ 门禁仍绿")
            rc_final = 1
        else:
            print("  ✓ 自检④：钉版倒退 ⇒ 判红")

        # ⑤ 已发货车次不足 3 辆 ⇒ 判红（矩阵建不起来不是「通过」）
        hub3 = os.path.join(base, "hub3")
        shutil.copytree(hub, hub3)
        git_in(hub3, "reset", "-q", "--hard", "HEAD~2")
        rc, out = run_check(hub3, platforms_root)
        if rc == 0:
            print("  ✗ 自检⑤：已发货车次不足 3 辆 ⇒ 门禁仍绿")
            rc_final = 1
        else:
            print("  ✓ 自检⑤：已发货车次不足 3 辆 ⇒ 判红")

        # ⑥ 远端不可达 ⇒ 降级为「未扫描」，且必须显式可见（没扫到 ≠ 扫过且通过）
        args = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             "upgrade_matrix.py"),
                "check", "--root", hub, "--platforms-root", platforms_root,
                "--remote", "--api-base", "http://127.0.0.1:9"]
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           check=False)
        out = p.stdout.decode("utf-8", "replace")
        if p.returncode != 0 or "未扫描" not in out:
            print("  ✗ 自检⑥：远端不可达 ⇒ 未按「未扫描」降级（rc=%d）" % p.returncode)
            print(out)
            rc_final = 1
        else:
            print("  ✓ 自检⑥：远端不可达 ⇒ 降级为「未扫描」并显式可见（未伪装成通过）")

        # ⑦ 远端不可达 + 要求必须扫到 ⇒ 判红（不得静默放过）
        args.append("--require-remote")
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           check=False)
        if p.returncode == 0:
            print("  ✗ 自检⑦：要求必须扫到但远端不可达 ⇒ 门禁仍绿")
            rc_final = 1
        else:
            print("  ✓ 自检⑦：要求必须扫到但远端不可达 ⇒ 判红")

        # ⑧ 远端 404（产物真的不存在）⇒ 判红（不能与「扫不到」混为一谈）
        stub = StubApi({"v1.0.0"})
        stub.start()
        try:
            args = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                 "upgrade_matrix.py"),
                    "check", "--root", hub, "--platforms-root", platforms_root,
                    "--remote", "--api-base", stub.url]
            p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               check=False)
            out = p.stdout.decode("utf-8", "replace")
            if p.returncode == 0:
                print("  ✗ 自检⑧：远端 release 缺失（404）⇒ 门禁仍绿")
                print(out)
                rc_final = 1
            else:
                print("  ✓ 自检⑧：远端 release 缺失（404）⇒ 判红")
        finally:
            stub.stop()
    finally:
        shutil.rmtree(base, ignore_errors=True)
    return rc_final


class StubApi(object):
    """极简 GitHub API 桩：只为自证「404 = 产物缺失 ⇒ 判红」。

    零外部依赖（标准库 http.server），⇒ 自证完全离线可跑。
    """

    def __init__(self, existing_tags):
        self.existing = set(existing_tags)
        self.server = None
        self.thread = None

    def start(self):
        import http.server
        import threading

        existing = self.existing

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                tag = self.path.rsplit("/", 1)[-1]
                if tag in existing:
                    body = json.dumps(
                        {"tag_name": tag, "draft": False, "assets": [{"name": "a"}]}
                    ).encode("utf-8")
                    self.send_response(200)
                else:
                    body = b'{"message":"Not Found"}'
                    self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, fmt, *args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    @property
    def url(self):
        host, port = self.server.server_address[:2]
        return "http://%s:%d" % (host, port)

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()


# ── 入口 ──────────────────────────────────────────────────────────────────
def main(argv):
    parser = argparse.ArgumentParser(description="N-1/N-2 制品级升级矩阵（静态矩阵）")
    sub = parser.add_subparsers(dest="cmd")

    p_check = sub.add_parser("check", help="跑静态矩阵判定")
    p_check.add_argument("--root", default=".")
    p_check.add_argument("--platforms-root", default="")
    p_check.add_argument("--repo", default=DEFAULT_REPO)
    p_check.add_argument("--api-base", default=DEFAULT_API)
    p_check.add_argument("--token", default=os.environ.get("GITHUB_TOKEN")
                         or os.environ.get("GH_TOKEN", ""))
    p_check.add_argument("--remote", dest="remote", action="store_true", default=True)
    p_check.add_argument("--no-remote", dest="remote", action="store_false")
    p_check.add_argument("--require-remote", action="store_true")
    p_check.add_argument("--require-platform-repos", action="store_true")

    p_plan = sub.add_parser("plan", help="输出某辆车的产物计划（JSON）")
    p_plan.add_argument("--root", default=".")
    p_plan.add_argument("--train", default="")

    p_self = sub.add_parser("selfcheck", help="负对照自证")
    p_self.add_argument("--root", default=".")

    opts = parser.parse_args(argv)
    if not opts.cmd:
        parser.print_help()
        return 2
    try:
        if opts.cmd == "check":
            return cmd_check(opts)
        if opts.cmd == "plan":
            return cmd_plan(opts)
        if opts.cmd == "selfcheck":
            return cmd_selfcheck(opts)
    except MatrixError as exc:
        print("✗ %s" % exc, file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
