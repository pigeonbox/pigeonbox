import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import type { IncomingMessage, ServerResponse } from "node:http";

import { afterEach, describe, expect, it } from "vitest";

import {
  ErrCode,
  isErrCode,
  isNotFound,
  PigeonBoxClient,
  PigeonBoxError,
} from "../src/index.js";

type Handler = (
  req: IncomingMessage,
  res: ServerResponse,
  body: string,
  paths: string[],
) => void;

interface MockServer {
  base: string;
  paths: string[];
  close: () => Promise<void>;
}

const cleanups: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length) {
    const fn = cleanups.pop();
    if (fn) await fn();
  }
});

function json(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

function envelope(code: number, message: string, data?: unknown): unknown {
  return data === undefined
    ? { code, message }
    : { code, message, data };
}

async function mockServer(handler: Handler): Promise<MockServer> {
  const paths: string[] = [];
  const srv = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => {
      body += String(chunk);
    });
    req.on("end", () => {
      paths.push((req.method || "") + " " + (req.url || ""));
      handler(req, res, body, paths);
    });
  });
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", resolve));
  const addr = srv.address() as AddressInfo;
  const close = () =>
    new Promise<void>((resolve, reject) =>
      srv.close((err) => (err ? reject(err) : resolve())),
    );
  cleanups.push(close);
  return { base: "http://127.0.0.1:" + addr.port, paths, close };
}

function client(base: string, extra: Record<string, unknown> = {}): PigeonBoxClient {
  return new PigeonBoxClient({
    baseURL: base,
    maxRetries: 2,
    retryBaseMs: 1,
    ...extra,
  });
}

describe("PigeonBoxClient 构造", () => {
  it("拒绝非法 baseURL", () => {
    expect(() => new PigeonBoxClient({ baseURL: "" })).toThrow();
    expect(() => new PigeonBoxClient({ baseURL: "ftp://x" })).toThrow();
  });
});

describe("寄件 → 取件 → 删除 三路径", () => {
  it("createTextShare：POST /share/text/ + X-API-Key 注入", async () => {
    let seenKey = "";
    let seenBody = "";
    const srv = await mockServer((req, res, body) => {
      seenKey = String(req.headers["x-api-key"] || "");
      seenBody = body;
      json(
        res,
        200,
        envelope(0, "ok", {
          code: "abc123",
          url: "http://h/s/abc123",
          pickup_code: "654321",
        }),
      );
    });
    const c = client(srv.base, { apiKey: "pb_test_key" });
    const data = await c.createTextShare({
      text: "hello",
      expire_value: 10,
      expire_style: "minute",
      require_auth: false,
    });
    expect(seenKey).toBe("pb_test_key");
    const parsed = JSON.parse(seenBody) as Record<string, unknown>;
    expect(parsed["text"]).toBe("hello");
    expect(parsed["expire_style"]).toBe("minute");
    expect(data.code).toBe("abc123");
    expect(data.pickup_code).toBe("654321");
    expect(srv.paths).toEqual(["POST /share/text/"]);
  });

  it("shareMetadata：GET /share/metadata/:code + Bearer 注入", async () => {
    let seenAuth = "";
    const srv = await mockServer((req, res) => {
      seenAuth = String(req.headers["authorization"] || "");
      json(
        res,
        200,
        envelope(0, "ok", {
          code: "abc123",
          type: "text",
          size: 11,
          has_password: false,
          expired_count: 10,
          used_count: 1,
          encrypted: false,
          file_count: 1,
          created_at: "2026-11-16T00:00:00Z",
        }),
      );
    });
    const c = client(srv.base, { token: "tok-1" });
    const md = await c.shareMetadata("654321");
    expect(seenAuth).toBe("Bearer tok-1");
    expect(srv.paths).toEqual(["GET /share/metadata/654321"]);
    expect(md.code).toBe("abc123");
    expect(md.file_count).toBe(1);
  });

  it("deleteShare：软删（batch-delete）+ 硬删（/hard）两连发", async () => {
    const srv = await mockServer((req, res, body, paths) => {
      if (paths.length === 1) {
        expect(req.method).toBe("POST");
        expect(req.url).toBe("/api/v1/user/shares/batch-delete");
        const parsed = JSON.parse(body) as { codes: string[] };
        expect(parsed.codes).toEqual(["abc123"]);
        json(res, 200, envelope(0, "ok", { deleted: 1 }));
        return;
      }
      expect(req.method).toBe("DELETE");
      expect(req.url).toBe("/api/v1/user/shares/abc123/hard");
      json(res, 200, envelope(0, "ok", { deleted: 1 }));
    });
    const c = client(srv.base, { apiKey: "pb_k" });
    await c.deleteShare("abc123");
    expect(srv.paths).toEqual([
      "POST /api/v1/user/shares/batch-delete",
      "DELETE /api/v1/user/shares/abc123/hard",
    ]);
  });
});

describe("错误码映射（errcode → 语义判定）", () => {
  it("10004 → isNotFound + isErrCode + httpStatus 保留", async () => {
    const srv = await mockServer((_req, res) => {
      json(res, 404, envelope(ErrCode.NotFound, "分享不存在或已过期"));
    });
    const c = client(srv.base);
    const err = await c.shareMetadata("nope").catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PigeonBoxError);
    const pe = err as PigeonBoxError;
    expect(pe.code).toBe(ErrCode.NotFound);
    expect(pe.httpStatus).toBe(404);
    expect(isErrCode(err, ErrCode.NotFound)).toBe(true);
    expect(isNotFound(err)).toBe(true);
    expect(isErrCode(err, ErrCode.ReachLimit)).toBe(false);
  });

  it("20004 超过取件次数 → isErrCode(ReachLimit)，不被误判为 notFound", async () => {
    const srv = await mockServer((_req, res) => {
      json(res, 403, envelope(ErrCode.ReachLimit, "超过取件次数"));
    });
    const c = client(srv.base);
    const err = await c.shareMetadata("x").catch((e: unknown) => e);
    expect(isErrCode(err, ErrCode.ReachLimit)).toBe(true);
    expect(isNotFound(err)).toBe(false);
  });
});

describe("重试 / 退避", () => {
  it("幂等 GET：503 两次后成功（共 3 次请求）", async () => {
    let n = 0;
    const srv = await mockServer((_req, res) => {
      n++;
      if (n <= 2) {
        json(res, 503, envelope(ErrCode.Unavailable, "warming up"));
        return;
      }
      json(
        res,
        200,
        envelope(0, "ok", {
          code: "abc123",
          type: "text",
          size: 0,
          has_password: false,
          expired_count: 1,
          used_count: 0,
          encrypted: false,
          file_count: 1,
          created_at: "t",
        }),
      );
    });
    const c = client(srv.base);
    const md = await c.shareMetadata("x");
    expect(md.code).toBe("abc123");
    expect(n).toBe(3);
  });

  it("POST 不重试（寄件非幂等）：503 直接抛错且只发 1 次", async () => {
    let n = 0;
    const srv = await mockServer((_req, res) => {
      n++;
      json(res, 503, envelope(ErrCode.Unavailable, "warming up"));
    });
    const c = client(srv.base);
    const err = await c
      .createTextShare({
        text: "x",
        expire_value: 1,
        expire_style: "minute",
        require_auth: false,
      })
      .catch((e: unknown) => e);
    expect(err).toBeInstanceOf(PigeonBoxError);
    expect((err as PigeonBoxError).code).toBe(ErrCode.Unavailable);
    expect(n).toBe(1);
  });
});

describe("分页迭代", () => {
  it("iterateShares 跨两页按序产出，page 参数递增", async () => {
    const srv = await mockServer((req, res) => {
      const url = new URL(req.url || "/", "http://x");
      const page = url.searchParams.get("page") || "1";
      if (page === "1") {
        json(
          res,
          200,
          envelope(0, "ok", {
            items: [
              { id: 1, code: "c1", file_name: "a", file_path: "/a" },
              { id: 2, code: "c2", file_name: "b", file_path: "/b" },
            ],
            total: 3,
            page: 1,
            page_size: 2,
            total_pages: 2,
            has_next: true,
            has_prev: false,
          }),
        );
        return;
      }
      json(
        res,
        200,
        envelope(0, "ok", {
          items: [{ id: 3, code: "c3", file_name: "c", file_path: "/c" }],
          total: 3,
          page: 2,
          page_size: 2,
          total_pages: 2,
          has_next: false,
          has_prev: true,
        }),
      );
    });
    const c = client(srv.base);
    const got: string[] = [];
    for await (const item of c.iterateShares({ page_size: 2 })) {
      got.push(item.code);
    }
    expect(got).toEqual(["c1", "c2", "c3"]);
    expect(srv.paths).toEqual([
      "GET /api/v1/user/shares?page=1&page_size=2",
      "GET /api/v1/user/shares?page=2&page_size=2",
    ]);
  });
});

describe("认证引导：登录 + 造 Key", () => {
  it("login 返回 token；createAPIKey 带 Bearer 且透传 scopes", async () => {
    const srv = await mockServer((req, res, body) => {
      if (req.url === "/user/login") {
        json(res, 200, envelope(0, "ok", { token: "tok-9", user: { id: 1 } }));
        return;
      }
      expect(req.url).toBe("/user/api-keys");
      expect(req.headers["authorization"]).toBe("Bearer tok-9");
      const parsed = JSON.parse(body) as { name: string; scopes: string[] };
      expect(parsed.name).toBe("k1");
      expect(parsed.scopes).toEqual(["share", "user"]);
      json(
        res,
        200,
        envelope(0, "ok", {
          key: "pb_live_secret",
          api_key: { id: 7, name: "k1", prefix: "pb_" },
        }),
      );
    });
    const bootstrap = client(srv.base);
    const token = await bootstrap.login({ username: "u", password: "p" });
    expect(token).toBe("tok-9");
    const authed = client(srv.base, { token });
    const created = await authed.createAPIKey("k1", ["share", "user"]);
    expect(created.key).toBe("pb_live_secret");
    expect(created.apiKey.id).toBe(7);
  });
});
