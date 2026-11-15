// demo 是 TS SDK 全链路演示：寄件 → 取件 → 删除。
// CI 的 scripts/sdk-demo.sh 用它对真实 server 冒烟（issue #367 验收）。
//
// 用法：
//   node dist/demo.js --base http://127.0.0.1:18777 --user smoker --password smoke12345
//   node dist/demo.js --base http://127.0.0.1:18777 --api-key pb_xxx
import { isNotFound, PigeonBoxClient } from "./index.js";

function arg(name: string): string {
  const argv = process.argv;
  const i = argv.indexOf(name);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1] || "";
  return "";
}

async function run(
  base: string,
  apiKey: string,
  username: string,
  password: string,
): Promise<void> {
  const opts = { baseURL: base, maxRetries: 2, retryBaseMs: 100 };
  let key = apiKey;
  if (!key) {
    if (!username || !password) {
      throw new Error("未提供 --api-key 时必须给 --user 与 --password");
    }
    const bootstrap = new PigeonBoxClient(opts);
    let token: string;
    try {
      token = await bootstrap.login({ username, password });
    } catch (loginErr) {
      try {
        await bootstrap.register({
          username,
          email: username + "@example.com",
          password,
          nickname: username,
        });
        token = await bootstrap.login({ username, password });
      } catch (regErr) {
        throw new Error(
          "登录与注册均失败: 登录=" +
            String(loginErr) +
            " 注册=" +
            String(regErr),
        );
      }
    }
    console.log("  ✓ 登录成功 " + username);
    const authed = new PigeonBoxClient({ ...opts, token });
    const created = await authed.createAPIKey("sdk-demo", ["share", "user"]);
    key = created.key;
    console.log("  ✓ 创建 API Key 成功（scopes=share,user）");
  }

  const c = new PigeonBoxClient({ ...opts, apiKey: key });

  // ── 1) 寄件：文本分享 ────────────────────────────────────────────────
  const data = await c.createTextShare({
    text: "pigeonbox sdk demo: 寄件→取件→删除",
    expire_value: 10,
    expire_style: "minute",
    require_auth: false,
  });
  if (!data.code) throw new Error("寄件响应缺分享码");
  const lookup = data.pickup_code || data.code;
  console.log("  ✓ 寄件成功 code=" + data.code + " pickup=" + lookup);

  // ── 2) 取件：元数据查询（不扣次数） ─────────────────────────────────
  const md = await c.shareMetadata(lookup);
  console.log(
    "  ✓ 取件元数据成功 type=" + md.type + " file_count=" + md.file_count,
  );

  // ── 3) 删除：软删（回收站）+ 永久删除，随后验证已消失 ────────────────
  await c.deleteShare(data.code);
  console.log("  ✓ 删除成功（软删+硬删）code=" + data.code);

  try {
    await c.shareMetadata(lookup);
  } catch (err) {
    if (!isNotFound(err)) throw err;
    console.log("  ✓ 删除生效：元数据查询已 404");
    return;
  }
  throw new Error("删除后仍能查到元数据（删除未生效）");
}

const base = arg("--base");
if (!base) {
  console.error(
    "用法: demo --base URL [--api-key KEY | --user U --password P]",
  );
  process.exit(2);
}
try {
  await run(base, arg("--api-key"), arg("--user"), arg("--password"));
  console.log("SDK demo PASS: 寄件 → 取件 → 删除 全链路 OK");
} catch (err) {
  console.error("DEMO FAILED:", err);
  process.exit(1);
}
