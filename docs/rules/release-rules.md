# 发版纪律（release-rules）

> 单源：AGENTS.md 重构（2026-11-13，spec 附录 A#10/#11/#14/#21、附录 B L784-811·L817·
> L825·L856·L858·L859）。**动发布链/发车前读**；AGENTS.md·发车必守点是本文件压缩版。

## 发布列车三条硬规则（v3，2026-10-27 起）

1. **推进归编排器自己**：`make train` 在同一次 CI 运行内自轮询到 shipped；
   `*/15` 的 cron **实测每 2~4 小时才跑一次** ⇒ cron 只是兜底，别当「每 15 分钟」。
2. **库线钉版不用人算**：`lib.*` 四键默认自动跟随各库仓最新已发布 tag（只升不降）；
   要发一个还没发布的库线版本才传 `SET="<lib>=vX.Y.Z"` ⇒ 列车自己打 tag
   （带仓内版本声明断言 + semver 单调性断言）并等可消费才 bump。
3. **操作面收敛成一条命令**：`make train TRAIN=<号>`；旧接口 `train-bump`/`train-advance`
   保留为兼容与崩溃接力。**判据**：改动这条链前先问「发车者还要记几步？」——答案是
   「一步」才算合格；「靠人记得」的每一条都是漏点。

## 发车顺序与库线

- **库线契约**：库线版本真相源是**库仓自己的 tag** ⇒ **先发库线 tag，再开产品线列车**；
  列车只自动跟随已发布的 tag。`phase=bump` 不发库线（悬空钉守卫报错）；
  同列车号重跑 skipBump（想重抬钉版不能靠重跑 run）。
- **库线仓自身钉版不在 bump 范围**：库线 A 依赖库线 B 升级时，A 的钉版无人抬 ⇒
  该库线仓单独提交抬钉版，且**必须发新版本号**（不重切已发 tag——代理按版本号缓存，
  重打会被喂陈旧 zip；重切还会让 verify 报版本元数据不一致）。
- **版本元数据两/三处同抬**：frontend-core = `VERSION` + `package.json` +
  **`package-lock.json`**（漏 lock ⇒ 发布闸门 `npm ci` 红 ⇒ tgz 不产出）；
  bump 不写库线仓自身元数据，人工归一（verify 会查）。
- **打 tag 顺序**：提交 → push main → 打 tag → push tag（只推 tag 漏推 main ⇒
  tag 锚定校验红 + 该提交 CI 根本不触发）。判据：`git merge-base --is-ancestor <tag> origin/main`。
- **库线发版三坑**：① contracts 三条生成链（gen-model/gen-ts/gen-openapi）漏一条
  ⇒ Release 失败；② release.yml 的 `npm version` 必须带 `--allow-same-version`；
  ③ 抬 tgz 钉版后 `npm install --package-lock-only` 要按**已发布资产**核对 integrity
  （本地 pack 字节可能与 CI 不同 ⇒ EINTEGRITY）。

## 守门与红线

- **列车守门**：旧列车卡在 tagged 态挡住新列车 ⇒ 逃生口=人工把 state 改回 shipped
  （**人工改 state 被允许；人工改版本号严禁**）。
- **train.yaml 是行解析器不是标准 YAML**：**行内注释会被当成值** ⇒ 任何说明必须
  独立成行；作废原因记提交信息/PR 正文（bump 的 Render 会整体覆盖该文件，且
  TestRenderParity 要求逐行一致）。
- **禁止绕过列车手改** VERSION/DEPS.env/manifest/tauri.conf.json/go.mod 钉版
  （tag 前置断言 + verify 双层拦截）。
- **主版本编号规则**（对外产品号）：破坏性变更 ⇒ 主版本+1 且次版本归零；
  库线版本与产品版本**各走各的**；已发版本不重切；chart 版本是独立计数器。
- **产品版本策略**：用户可见分发物一律与 hub 快照（产品号）同号（七终端包 + 镜像 tag +
  两仓 git tag + 包体版本）；库线维持各自 semver（版本讲兼容语义，勿拉齐）。

## 切镜像前的包含关系判据（2026-11-03 实录）

**切回官方镜像前，用「包含关系」判据而非版本号大小**：列车 bump 只跟随
「bump 时刻最新已发布 tag」⇒ 库线可能落后于在跑的热修。
`git log <列车钉的 tag> | grep -E '#<热修 PR 号>'`——命中数少于热修集 ⇒ 该库线落后，别切。
**部署一律带指纹硬门**：server 二进制字节级 `LC_ALL=C grep -a` 验关键文案/版本戳，
前端验 version.txt 同号 + 新特性键名，任一缺失即中止不切换。
镜像拉取走加速源（如 `ghcr.nju.edu.cn`）再 retag ghcr.io。

## Release body 与文档站 changelog 刻意不同（2026-10-28）

**不要把 Release body 逐字搬进文档站**：Release body 要自包含、每列车内联破坏性清单；
文档站是时间轴、每份清单只渲染一次（逐字搬=同一清单读 N 遍 + 幽灵锚点）。
站点侧 `docs-site/scripts/fetch-releases.mjs` 重排；门禁
`docs-site/scripts/check-changelog.mjs`（标题唯一/清单唯一/列数/禁 `{{` 等，
③⑤都是真坏过的项）。⚠️ **表格单元格里的竖线必须转义 `\|`**（反引号里也不例外）
——实弹：未转义 `||` 把整行拆列、关键指引整列消失，源头在 `notes.go` 修 +
`notes_test.go` 逐表比列数守卫。
