# PigeonBox 规则（层2 · 版本化单源）

> 本目录是「公开安全的持久规则」唯一真相源（AGENTS.md 重构 2026-11-13，spec
> `docs/specs/2026-11-13-agents-md-restructure-design.md`）。
> 工作区 AGENTS.md 只留精编与指针；含内网/机器细节的材料在工作区 `docs/topics/`（不入库）。

| 文件 | 覆盖 | 谁改这里 |
|---|---|---|
| contributing-rules.md | 提交约定 / 依赖单向 / 生成物勿手改 / 破坏性升版 / 钉版 / 对外行为契约 | 任何仓的工程规则变更；CONTRIBUTING.md 指向此处 |
| ci-gate-failures.md | 门禁失效四形态 / 等 CI 三假信号 / git 有界取数 / 加门禁四问 | 改 CI/门禁前 |
| release-rules.md | 发版纪律（库线钉版、发车顺序、守门、切镜像判据、notes 渲染） | 动发布链前 |
| frontend-rules.md | 折叠屏断点 / 列宽公式 / CSS 特异度 / 路由与表格形态 / E2E 约束 | 动前端 UI 前 |
| brand.md | 品牌真相源 / 换色生成器 / 色板公式 | 动图标/主题色前 |
| generic-engineering.md | 幂等键 / 拆判定重审 / 守卫自证 / 静默失效响亮失败 / 负对照底线 / 数据迁移纪律 / 审计硬规则 | 通用工程判断 |

**治理**：新规则先进对应文件（PR review）；AGENTS.md 禁止直接堆实录段落
（守卫：工作区 `make agents-guard`）。
