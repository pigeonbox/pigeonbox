import type { publicapi, share, user } from "@pigeonbox/contracts";

import { PigeonBoxError, isNotFound } from "./errors.js";

export interface ClientOptions {
  /** 服务端 base URL，如 https://pb.example.com（不带路径） */
  baseURL: string;
  /** API Key（请求头 X-API-Key；scope 按服务端路径判定 admin/user/share） */
  apiKey?: string;
  /** 用户 JWT（请求头 Authorization: Bearer） */
  token?: string;
  /** 注入 fetch 实现（测试/Node 特殊环境用；缺省取全局 fetch） */
  fetch?: typeof fetch;
  /** 幂等方法最大重试次数（默认 2；0 = 关闭） */
  maxRetries?: number;
  /** 退避基数毫秒（默认 200，指数递增，尊重 Retry-After，封顶 30s） */
  retryBaseMs?: number;
}

interface Envelope<T> {
  code: number;
  message: string;
  data?: T;
}

interface RequestOptions {
  query?: Record<string, string | number | undefined | null>;
  body?: unknown;
}

const IDEMPOTENT = new Set(["GET", "HEAD", "PUT", "DELETE", "OPTIONS"]);
const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);
const MAX_BACKOFF_MS = 30_000;
/** 翻页安全阀：服务端分页字段自相矛盾时防死循环 */
const MAX_ITER_PAGES = 10_000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function snippet(text: string): string {
  const s = text.trim();
  return s.length > 200 ? s.slice(0, 200) + "…" : s;
}

function parseRetryAfter(value: string | null): number {
  if (!value) return 0;
  const sec = Number.parseInt(value.trim(), 10);
  if (!Number.isFinite(sec) || sec <= 0) return 0;
  return Math.min(sec * 1000, MAX_BACKOFF_MS);
}

/**
 * PigeonBox API 客户端（v0 薄封装）。
 *
 * 横切能力：认证注入、幂等重试/退避、分页迭代、errcode 错误映射；
 * 请求/响应类型直接复用 @pigeonbox/contracts 生成物 ⇒ 契约破坏性变更
 * 升钉版后 tsc --noEmit / 构建即红（而不是运行时 404/400）。
 *
 * 重试策略：幂等方法（GET/HEAD/PUT/DELETE/OPTIONS）对传输错误与
 * 429/502/503/504 指数退避重试；POST 不重试（寄件非幂等，重发会造重复分享）。
 */
export class PigeonBoxClient {
  private readonly baseURL: string;
  private readonly apiKey?: string;
  private readonly token?: string;
  private readonly fetchImpl: typeof fetch;
  private readonly maxRetries: number;
  private readonly retryBaseMs: number;

  constructor(options: ClientOptions) {
    const raw = (options.baseURL || "").trim().replace(/\/+$/, "");
    let parsed: URL;
    try {
      parsed = new URL(raw);
    } catch {
      throw new Error("pigeonbox: 非法 baseURL " + options.baseURL);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error("pigeonbox: baseURL scheme 必须是 http/https");
    }
    this.baseURL = raw;
    this.apiKey = options.apiKey;
    this.token = options.token;
    if (!options.fetch && typeof globalThis.fetch !== "function") {
      throw new Error("pigeonbox: 当前环境无全局 fetch，请用 options.fetch 注入");
    }
    this.fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);
    this.maxRetries = Math.max(0, options.maxRetries ?? 2);
    this.retryBaseMs = options.retryBaseMs ?? 200;
  }

  /** 执行一次调用并返回 envelope 的 data 段（业务错误抛 PigeonBoxError）。 */
  private async request<T>(
    method: string,
    path: string,
    options: RequestOptions = {},
  ): Promise<T> {
    const idempotent = IDEMPOTENT.has(method);
    const attempts = idempotent ? this.maxRetries + 1 : 1;
    let url = this.baseURL + path;
    if (options.query) {
      const params = new URLSearchParams();
      for (const [k, v] of Object.entries(options.query)) {
        if (v !== undefined && v !== null && v !== "") params.set(k, String(v));
      }
      const qs = params.toString();
      if (qs) url += "?" + qs;
    }
    const payload =
      options.body === undefined ? undefined : JSON.stringify(options.body);

    let retryAfterMs = 0;
    for (let attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        const backoff = Math.min(
          this.retryBaseMs * 2 ** (attempt - 1),
          MAX_BACKOFF_MS,
        );
        await sleep(Math.max(backoff, retryAfterMs));
        retryAfterMs = 0;
      }
      const headers: Record<string, string> = { Accept: "application/json" };
      if (payload !== undefined) headers["Content-Type"] = "application/json";
      if (this.apiKey) headers["X-API-Key"] = this.apiKey;
      if (this.token) headers["Authorization"] = "Bearer " + this.token;

      let resp: Response;
      try {
        resp = await this.fetchImpl(url, {
          method,
          headers,
          body: payload,
        });
      } catch (err) {
        // 传输层错误：幂等方法按退避重试。
        if (attempt < attempts - 1) continue;
        throw new PigeonBoxError(
          "pigeonbox: " + method + " " + path + " 传输失败: " + String(err),
          0,
          0,
        );
      }
      const text = await resp.text();
      if (idempotent && attempt < attempts - 1 && RETRYABLE_STATUS.has(resp.status)) {
        retryAfterMs = parseRetryAfter(resp.headers.get("Retry-After"));
        continue;
      }

      let env: Envelope<T>;
      try {
        env = JSON.parse(text) as Envelope<T>;
      } catch {
        if (!resp.ok) {
          throw new PigeonBoxError(snippet(text), 0, resp.status);
        }
        throw new PigeonBoxError(
          "pigeonbox: " + method + " " + path + " 响应非 JSON: " + snippet(text),
          0,
          resp.status,
        );
      }
      if (typeof env.code !== "number") {
        throw new PigeonBoxError(
          "pigeonbox: 响应缺 code 字段: " + snippet(text),
          0,
          resp.status,
        );
      }
      if (env.code !== 0 || !resp.ok) {
        throw new PigeonBoxError(
          env.message || snippet(text),
          env.code,
          resp.status,
        );
      }
      return env.data as T;
    }
    /* c8 ignore next */
    throw new PigeonBoxError("pigeonbox: 不可达", 0, 0);
  }

  // ── 认证 ──────────────────────────────────────────────────────────────

  /** 用户登录：POST /user/login，返回 JWT。 */
  async login(req: user.LoginReq): Promise<string> {
    const data = await this.request<user.LoginData | undefined>(
      "POST",
      "/user/login",
      { body: req },
    );
    if (!data || !data.token) {
      throw new PigeonBoxError("登录响应缺 token");
    }
    return data.token;
  }

  /** 用户注册：POST /user/register（站点须开放注册）。 */
  async register(req: user.RegisterReq): Promise<void> {
    await this.request<user.UserData | undefined>("POST", "/user/register", {
      body: req,
    });
  }

  /** 为当前身份创建 API Key（需 Bearer 登录态）；scopes 缺省 = 全量。 */
  async createAPIKey(
    name: string,
    scopes?: string[],
  ): Promise<{ key: string; apiKey: user.APIKeyData }> {
    const req: user.CreateAPIKeyReq = scopes ? { name, scopes } : { name };
    const data = await this.request<
      { key: string; api_key: user.APIKeyData } | undefined
    >("POST", "/user/api-keys", { body: req });
    if (!data || !data.key) {
      throw new PigeonBoxError("创建 API Key 响应缺 key");
    }
    return { key: data.key, apiKey: data.api_key };
  }

  // ── 核心三路径：寄件 → 取件 → 删除 ───────────────────────────────────

  /** 寄件（文本分享）：POST /share/text/（scope=share）。 */
  async createTextShare(req: share.ShareTextReq): Promise<share.ShareData> {
    const data = await this.request<share.ShareData | undefined>(
      "POST",
      "/share/text/",
      { body: req },
    );
    if (!data) throw new PigeonBoxError("寄件响应缺 data");
    return data;
  }

  /** 取件元数据：GET /share/metadata/:code（scope=share，公开面，不扣次数）。 */
  async shareMetadata(code: string): Promise<publicapi.ShareMetadataData> {
    const data = await this.request<
      publicapi.ShareMetadataData | undefined
    >("GET", "/share/metadata/" + encodeURIComponent(code));
    if (!data) throw new PigeonBoxError("元数据响应缺 data");
    return data;
  }

  /** 删除（核心路径）：软删进回收站 + 永久删除（硬删只认回收站内分享）。 */
  async deleteShare(code: string): Promise<void> {
    await this.softDeleteShares([code]);
    await this.hardDeleteShare(code);
  }

  /** 批量软删除（回收站）：POST /api/v1/user/shares/batch-delete（scope=user）。 */
  async softDeleteShares(
    codes: string[],
  ): Promise<Record<string, number> | undefined> {
    return this.request<Record<string, number> | undefined>(
      "POST",
      "/api/v1/user/shares/batch-delete",
      { body: { codes } },
    );
  }

  /** 永久删除：DELETE /api/v1/user/shares/:code/hard（scope=user，只认回收站内分享）。 */
  async hardDeleteShare(code: string): Promise<Record<string, number> | undefined> {
    return this.request<Record<string, number> | undefined>(
      "DELETE",
      "/api/v1/user/shares/" + encodeURIComponent(code) + "/hard",
    );
  }

  // ── 列表 / 分页 ──────────────────────────────────────────────────────

  /** 我的分享列表（单页）：GET /api/v1/user/shares（scope=user）。 */
  async listShares(
    req: share.UserSharesListReq = {},
  ): Promise<share.UserSharesListData> {
    const data = await this.request<share.UserSharesListData | undefined>(
      "GET",
      "/api/v1/user/shares",
      {
        query: {
          status: req.status,
          search: req.search,
          page: req.page,
          page_size: req.page_size,
        },
      },
    );
    if (!data) throw new PigeonBoxError("列表响应缺 data");
    return data;
  }

  /** 跨页迭代（分页能力）：for await (const item of client.iterateShares()) … */
  async *iterateShares(
    req: share.UserSharesListReq = {},
  ): AsyncGenerator<share.UserShareItemData, void, undefined> {
    let page = 1;
    let fetched = 0;
    for (;;) {
      fetched++;
      if (fetched > MAX_ITER_PAGES) {
        throw new PigeonBoxError(
          "pigeonbox: 分页迭代超过 " + MAX_ITER_PAGES + " 页（服务端分页字段疑似异常）",
        );
      }
      const data = await this.listShares({ ...req, page });
      if (!data.items || data.items.length === 0) return;
      yield* data.items;
      const hasNext =
        data.has_next === true &&
        (data.total_pages <= 0 || page < data.total_pages);
      if (!hasNext) return;
      page++;
    }
  }

  /** 「查无此物」族快捷判定（10004/20001/20005）。 */
  static isNotFound = isNotFound;
}
