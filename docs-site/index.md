---
layout: home
title: PigeonBox 文档
# 首页是**文档门户**：hero → 3 个卖点 → 30 秒启动 → 三条任务线 → 界面预览。
# 与 /about（产品门面：品牌大图 + 9 项能力 + 流程/部署/FAQ）刻意区分——
# 首屏 h1、hero 形态、往下第一块内容三者都不同，点了能看出换页了。
hero:
  name: PigeonBox 文档
  text: 上传即出码，凭码取件
  tagline: 匿名口令分享文本与文件的开源自托管平台 —— 双方都不必注册，文件留在你自己的机器上。
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: 部署指南
      link: /guide/deploy-docker
    - theme: alt
      text: 站点介绍
      link: /about
---

<div class="pb-sell">
  <div class="pb-sell-item">
    <span class="pb-sell-icon"><PbIcon name="link" :size="24" /></span>
    <h3>6 位取件码</h3>
    <p>文件与文本同权铸造短码，对方凭码取件——不用注册，不用加好友。</p>
  </div>
  <div class="pb-sell-item">
    <span class="pb-sell-icon"><PbIcon name="shield" :size="24" /></span>
    <h3>密码与有效期</h3>
    <p>两道护栏任选，到期自动清理；口令泄露可在后台一键删掉该次分享。</p>
  </div>
  <div class="pb-sell-item">
    <span class="pb-sell-icon"><PbIcon name="database" :size="24" /></span>
    <h3>14 种存储后端</h3>
    <p>local / S3 / OSS / WebDAV / OneDrive… 数据放哪你说了算，随时热切换。</p>
  </div>
</div>

## 30 秒启动

```bash
git clone https://github.com/pigeonbox/pigeonbox.git && cd pigeonbox
cp .env.example .env      # 不改也能起：打开站点走首启向导建管理员
docker compose up -d      # 打开 http://localhost:12345
```

装完打开浏览器就能用——**不需要先想好管理员密码**：首启向导当场建号（站点名、密码、有效期一页配完）。公网部署再加一行 `PB_SETUP_TOKEN` 防"谁先访问谁建号"。

<div class="pb-tasks">
  <a class="pb-task" href="/guide/getting-started">
    <span class="pb-task-icon"><PbIcon name="container" :size="22" /></span>
    <h3>开始使用</h3>
    <p>部署、初始化与升级 —— 从一台空服务器开始跑起来。</p>
    <span class="pb-task-more">快速开始 →</span>
  </a>
  <a class="pb-task" href="/guide/deploy-nas">
    <span class="pb-task-icon"><PbIcon name="doc" :size="22" /></span>
    <h3>管理服务</h3>
    <p>存储、配置与安全 —— NAS / Kubernetes 部署与存储后端选型。</p>
    <span class="pb-task-more">部署与配置 →</span>
  </a>
  <a class="pb-task" href="/reference/api-tokens">
    <span class="pb-task-icon"><PbIcon name="code" :size="22" /></span>
    <h3>集成开发</h3>
    <p>API Token、MCP 接入 —— 让脚本与 AI 客户端直接收发文件。</p>
    <span class="pb-task-more">API 与 MCP →</span>
  </a>
</div>

## 界面预览

<div class="pb-shots">
  <figure class="pb-shot">
    <img src="/screenshots/home-pickup.png" alt="首页取件" loading="lazy" />
    <figcaption>首页就是取件页</figcaption>
  </figure>
  <figure class="pb-shot">
    <img src="/screenshots/send-file.png" alt="发送文件" loading="lazy" />
    <figcaption>发送文件：多选、有效期、密码</figcaption>
  </figure>
  <figure class="pb-shot">
    <img src="/screenshots/share-success.png" alt="分享成功" loading="lazy" />
    <figcaption>分享成功：6 位取件码</figcaption>
  </figure>
  <figure class="pb-shot">
    <img src="/screenshots/admin-dashboard.png" alt="管理台" loading="lazy" />
    <figcaption>管理台：用户、文件、存储</figcaption>
  </figure>
</div>
