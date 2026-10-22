#!/usr/bin/env python3
"""大文件分片上传端到端验证（对标上游踩坑清单头号主题：大文件上传失败）。

场景：48MB 随机文件 / 2MB 分片 = 24 片
  1. init（带 SHA-256）
  2. 并发上传 22 片（跳过 #5 #17，6 并发模拟真实客户端）
  3. status 断点续传：uploaded_indexes 恰为 22
  4. 补传缺失 2 片 → status 全齐
  5. complete（require_auth + password）→ 返回真实分享码（回归 P0：曾返回 uploadID）
  6. select 无密码 401 / 正确密码 200 拿下载令牌
  7. 下载内容 SHA-256 与原文件一致
  8. 秒传安全语义：complete 带密码 → 同哈希二次 init 必须 is_quick_upload=false
     （密码分享不做秒传源；无密码正向秒传由 smoke-full.sh S11b 覆盖）

注意：6 并发必须客户端节流（全局 ~8 req/s）——服务端默认 per-IP 限流
UploadQPS=10/Burst=20（middleware.DefaultRateLimitConfig），无节流的并发
会在第 ~20 片起吃 429（10005），那是限流器正确工作而非缺陷。
"""
import concurrent.futures
import hashlib
import io
import json
import os
import sys
import threading
import time
import urllib.request
import uuid

BASE = os.environ.get("PB_BASE", "http://localhost:12345")
CHUNK = 2 * 1024 * 1024
SIZE = 48 * 1024 * 1024
TOTAL = SIZE // CHUNK

failures = []

# 客户端节流：请求间隔 ≥0.11s（≈9 req/s < UploadQPS=10），跨 worker 生效
_pace_lock = threading.Lock()
_next_slot = [0.0]


def _pace():
    with _pace_lock:
        now = time.time()
        slot = max(_next_slot[0], now)
        if slot > now:
            time.sleep(slot - now)
        _next_slot[0] = slot + 0.11


def check(name, ok, detail=""):
    print(("  ✓ " if ok else "  ✗ ") + name + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def post_form(url, fields, files=None):
    boundary = uuid.uuid4().hex
    body = io.BytesIO()
    for k, v in (fields or {}).items():
        body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    for k, (fn, data) in (files or {}).items():
        body.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fn}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode())
        body.write(data)
        body.write(b"\r\n")
    body.write(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(BASE + url, data=body.getvalue(), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def get(url, headers=None):
    try:
        req = urllib.request.Request(BASE + url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


print("== 准备 48MB 随机文件 ==")
data = os.urandom(SIZE)
sha = hashlib.sha256(data).hexdigest()
print(f"  sha256={sha[:16]}... total_chunks={TOTAL}")

print("== 1. init ==")
st, res = post_form("/chunk/upload/init/", {
    "file_name": "e2e-big.bin", "file_size": str(SIZE),
    "file_hash": sha, "chunk_size": str(CHUNK), "total_chunks": str(TOTAL),
})
check("init 成功(http200/业务码0)", st == 200 and res["code"] == 0, str(res)[:120])
upload_id = res["data"]["upload_id"]
print(f"  upload_id={upload_id[:24]}...")

print("== 2. 并发上传 22/24（跳过 #5 #17, 6 并发）==")
skip = {5, 17}
idxs = [i for i in range(TOTAL) if i not in skip]

def put_chunk(i):
    _pace()
    st, res = post_form(f"/chunk/upload/chunk/{upload_id}/{i}",
                        {}, {"chunk": (f"c{i}", data[i*CHUNK:(i+1)*CHUNK])})
    okk = st == 200 and res["code"] == 0
    if not okk:
        # 单片失败详情必须可见（429=限流命中/400=契约不符，静默聚合会让根因不可诊断）
        print(f"    chunk {i} FAIL http={st} body={json.dumps(res, ensure_ascii=False)[:160]}")
    return i, okk

with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
    results = list(ex.map(put_chunk, idxs))
ok_cnt = sum(1 for _, ok in results if ok)
check(f"并发 22 片成功（实际 {ok_cnt}）", ok_cnt == 22)

print("== 3. status 断点续传 ==")
st, body = get(f"/chunk/upload/status/{upload_id}")
st_data = json.loads(body).get("data") or {}
if not st_data:
    # 429/错误体直接可见，勿裸 KeyError（status 也可能吃限流）
    check("status 响应含 data", False, f"http={st} body={body[:160]}")
    sys.exit(1)
check("uploaded=22", st_data["uploaded_chunks"] == 22, str(st_data)[:120])
have = set(st_data["uploaded_indexes"])
check("缺失恰为 #5 #17", have == set(idxs), str(have ^ set(idxs)))

print("== 4. 断点补传 ==")
for i in sorted(skip):
    _, ok = put_chunk(i)
    check(f"补传 #{i}", ok)
st, body = get(f"/chunk/upload/status/{upload_id}")
check("补传后 uploaded=24", json.loads(body)["data"]["uploaded_chunks"] == TOTAL)

print("== 5. complete（带密码）==")
PASSWORD = "e2e-pass-123"
st, res = post_form(f"/chunk/upload/complete/{upload_id}", {
    "expire_value": "1", "expire_style": "day",
    "require_auth": "true", "password": PASSWORD,
})
check("complete 成功(http200/业务码0)", st == 200 and res["code"] == 0, str(res)[:200])
share_code = res["data"]["share_code"]
check("返回真实分享码(非 uploadID)", share_code and share_code != upload_id, share_code)
print(f"  share_code={share_code}")

print("== 6. 密码校验 ==")
# 密码走请求头 X-Share-Password（2026-10-16 起 query 通道已废：query 会进
# 访问日志与 Referer）。此前脚本用 ?password= ⇒ 「对密码 200」分支恒失败。
st, body = get(f"/share/select/?code={share_code}")
check("无密码 401", st == 401, str(st))
st, body = get(f"/share/select/?code={share_code}", {"X-Share-Password": "wrong-pass"})
check("错密码 401", st == 401, str(st))
st, body = get(f"/share/select/?code={share_code}", {"X-Share-Password": PASSWORD})
sel = json.loads(body)
check("对密码 200", st == 200 and sel["code"] == 0, str(body)[:120])
dl_url = sel["data"]["download_url"]
check("下发下载令牌", "token=" in dl_url)

print("== 7. 下载内容比对 ==")
st, content = get(dl_url)
check("下载 200", st == 200, str(st))
dl_sha = hashlib.sha256(content).hexdigest()
check(f"SHA-256 一致（{len(content)} 字节）", dl_sha == sha, f"{dl_sha[:16]} vs {sha[:16]}")

print("== 8. 秒传安全语义（密码分享不做秒传源）==")
# GetByHashAndSize 恒过滤 require_auth=false（dao 回归 2026-10-03：防持同哈希者
# 借秒传令牌穿透原分享的密码校验）。本脚本 complete 带密码 → 秒传必须不命中；
# 无密码流的正向秒传由 scripts/smoke-full.sh S11b 覆盖。
st, res = post_form("/chunk/upload/init/", {
    "file_name": "e2e-big-copy.bin", "file_size": str(SIZE),
    "file_hash": sha, "chunk_size": str(CHUNK), "total_chunks": str(TOTAL),
})
qd = res["data"]
check("密码分享不做秒传源(is_quick_upload=false)", qd.get("is_quick_upload") is False, str(qd)[:150])

print()
if failures:
    print(f"✗ {len(failures)} 项失败: {failures}")
    sys.exit(1)
print("✓✓ 大文件分片端到端全部通过（断点续传/并发/密码/秒传/内容一致性）")
