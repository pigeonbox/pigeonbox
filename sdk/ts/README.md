# PigeonBox TS SDK（v0）

PigeonBox 官方 TypeScript/JavaScript 客户端（浏览器 + Node ≥18）：
让第三方系统自动完成**寄件 → 取件 → 删除**。

- 请求/响应类型直接复用 [`@pigeonbox/contracts`](https://github.com/pigeonbox/contracts)
  已发布 tgz（gen-ts 产物，URL 钉版，同 frontend-core 消费模式）——
  **契约破坏性变更 → 升钉版 → `tsc --noEmit` / 构建即红**（而不是运行时 404/400）。
- 运行时零依赖（contracts 仅类型）；`fetch` 原生（Node 18+/现代浏览器）。

## 安装

```bash
npm install @pigeonbox/sdk   # 发布到 npm registry 后
# 源码消费：cd sdk/ts && npm ci && npm run build，产物在 dist/（ESM + d.ts）
```

## 快速上手：寄件 → 取件 → 删除

```ts
import { PigeonBoxClient, isNotFound, ErrCode } from "@pigeonbox/sdk";

// API Key 在管理台创建（scope 选 share+user 覆盖三条路径；缺能力 403）。
const client = new PigeonBoxClient({ baseURL: "https://pb.example.com", apiKey: "pb_xxx" });

// 1) 寄件：文本分享（10 分钟后过期）
const data = await client.createTextShare({
  text: "hello from sdk",
  expire_value: 10,
  expire_style: "minute",
  require_auth: false,
});
console.log("取件码:", data.pickup_code);

// 2) 取件：元数据查询（不扣取件次数）
const md = await client.shareMetadata(data.pickup_code || data.code);
console.log("类型:", md.type, "文件数:", md.file_count);

// 3) 删除：软删（回收站）+ 永久删除（硬删只认回收站内分享）
await client.deleteShare(data.code);

// 删除生效校验：再查一次应命中「查无此物」
try {
  await client.shareMetadata(data.pickup_code || data.code);
  throw new Error("删除未生效");
} catch (err) {
  if (!isNotFound(err)) throw err;
}
```

## 认证

| 方式 | 选项 | 请求头 |
|---|---|---|
| API Key（推荐） | `apiKey` | `X-API-Key` |
| 用户 JWT | `token` | `Authorization: Bearer` |

scope 按请求路径判定（`admin`/`user`/`share`），缺能力 **403**（不是 401），缺省 = 全量。
登录与造 Key：

```ts
const bootstrap = new PigeonBoxClient({ baseURL });
const token = await bootstrap.login({ username, password });
const authed = new PigeonBoxClient({ baseURL, token });
const { key } = await authed.createAPIKey("my-integration", ["share", "user"]);
```

## 重试 / 错误 / 分页

- 幂等方法（GET/HEAD/PUT/DELETE）默认重试 2 次：传输错误 + 429/502/503/504，
  指数退避（200ms 起）、尊重 `Retry-After`、封顶 30s；**POST 不重试**（寄件非幂等）。
  `maxRetries` / `retryBaseMs` 可调。
- 业务错误统一抛 `PigeonBoxError`（`code` = errcode 统一业务码，`httpStatus` 保留）；
  `ErrCode` 常量镜像 contracts/errcode，`isErrCode(err, ErrCode.ReachLimit)` /
  `isNotFound(err)` 做语义判定。
- 分页：`listShares({ page, page_size, status, search })` 单页；
  `for await (const item of client.iterateShares({ page_size: 50 }))` 跨页自动翻。

## 全链路 demo

```bash
cd sdk/ts && npm ci && npm run build
node dist/demo.js --base http://127.0.0.1:12345 --user admin --password ****
node dist/demo.js --base http://127.0.0.1:12345 --api-key pb_xxx
```

CI 里由 `scripts/sdk-demo.sh` 驱动，对真实 server 跑 寄件 → 取件 → 删除 全链路。

## 开发

```bash
npm run typecheck   # tsc --noEmit（含 test/）
npm test            # vitest（mock server：三路径/重试/错误映射/分页）
npm run build       # tsc → dist/（ESM + d.ts）
```
