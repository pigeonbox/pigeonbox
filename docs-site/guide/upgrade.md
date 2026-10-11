---
title: 升级说明
---

<!-- 内容引自 hub 仓库 docs/v0.3-upgrade-notes.md（真相源），勿在本页手改内容 -->
<!--@include: ../../docs/v0.3-upgrade-notes.md-->

### 0.12.x（会话 Cookie 化列车）

- **浏览器会话迁 HttpOnly Cookie**：前端不再持久化令牌；第三方脚本/桌面端继续走 `Authorization: Bearer` 与 API Key，零改动。Cookie 认证的写请求须携带 `X-Requested-With: XMLHttpRequest`（CSRF 防御，前端已内置）。
- **密码分享取件页修复**：业务性 401（需要密码/密码错误）不再触发会话刷新，匿名取件人不再被跳转登录页。
- **p2p 直传协议 v2**（p2p v0.4 / desktop v1.3.1）：与旧版互不兼容，双端须同版升级。
- **CSP**：前端 nginx 层下发 `script-src 'self' 'unsafe-eval'`（vue-i18n 运行时编译需要；自建反代如自行收紧 CSP 需保留 eval，否则 i18n 白屏）。
