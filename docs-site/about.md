---
layout: home
pageClass: pb-about
title: 站点介绍
description: PigeonBox（文件快递柜）是什么、能做什么、怎么部署——一页看完。
hero:
  name: PigeonBox
  text: 文件快递柜
  tagline: 发一份文件，只留一串 6 位取件码。对方凭码取件，双方都不必注册；文件留在你自己的机器上。
  image:
    src: /logo.svg
    alt: PigeonBox
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/pigeonbox
---

<PbFeatures />

## 三步完成一次交付

<div class="pb-steps">
  <div class="pb-step">
    <span class="pb-step-num">01</span>
    <span class="pb-step-icon"><PbIcon name="cloud" :size="22" /></span>
    <h3>上传</h3>
    <p>拖入文件或粘贴文本，设好有效期，需要时再加一个<span class="nb">取件密码</span>。</p>
  </div>
  <div class="pb-step">
    <span class="pb-step-num">02</span>
    <span class="pb-step-icon"><PbIcon name="key" :size="22" /></span>
    <h3>出码</h3>
    <p>系统铸造 6 位<span class="nb">取件码</span>，同时给出分享链接与<span class="nb">二维码</span>。</p>
  </div>
  <div class="pb-step">
    <span class="pb-step-num">03</span>
    <span class="pb-step-icon"><PbIcon name="download" :size="22" /></span>
    <h3>取件</h3>
    <p>对方在首页输入<span class="nb">取件码</span>（必要时加密码）即可下载，到期自动失效。</p>
  </div>
</div>

## 部署形态

<div class="pb-deploys">
  <a class="pb-deploy" href="/guide/getting-started">
    <span class="pb-deploy-icon"><PbIcon name="container" :size="22" /></span>
    <h3>Docker Compose</h3>
    <p>自建服务器、任意云主机</p>
    <span class="pb-deploy-more">快速开始 →</span>
  </a>
  <a class="pb-deploy" href="/guide/deploy-kubernetes">
    <span class="pb-deploy-icon"><PbIcon name="wheel" :size="22" /></span>
    <h3>Kubernetes（Helm）</h3>
    <p>多副本、Ingress、对象存储</p>
    <span class="pb-deploy-more">部署 Kubernetes →</span>
  </a>
  <a class="pb-deploy" href="/guide/deploy-nas">
    <span class="pb-deploy-icon"><PbIcon name="database" :size="22" /></span>
    <h3>NAS 原生包</h3>
    <p>飞牛 / 威联通 / 群晖<br />绿联 / 铁威马 / OpenWrt</p>
    <span class="pb-deploy-more">部署 NAS →</span>
  </a>
  <a class="pb-deploy" href="https://github.com/pigeonbox/desktop" target="_blank" rel="noreferrer">
    <span class="pb-deploy-icon"><PbIcon name="monitor" :size="22" /></span>
    <h3>桌面客户端</h3>
    <p>连接任意自建服务器的日常取件</p>
    <span class="pb-deploy-more">获取桌面端 →</span>
  </a>
</div>

## 界面一览

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

## 常见问题

::: details 需要注册吗？
不注册即可分享与取件。管理员可按需开启「上传需登录」或关闭注册，两者互相独立。
:::

::: details 取件码泄露了怎么办？
6 位取件码 + 可选密码是两道护栏。你也可以到管理后台直接删掉该次分享，或把有效期调短。
:::

::: details 文件会保存多久？
由发送方选择的有效期决定（分钟 / 小时 / 天 / 周 / 月 / 年 / 永久 / 按取件次数），到期自动清理。允许哪些选项由管理员在后台勾选。
:::

::: details 设备直传（P2P 直传）去哪了？
3.0.0 起，**设备直传从 PigeonBox 拆出为独立应用 PigeonBeam（信鸽直传）**——PigeonBox 专注「到柜」这一件事，直传交给专门做它的应用。

Box 侧保留的是**联邦面**：口令跨站路由、邀请信封交接（仍是 PigeonBox 的原生能力，见[使用说明](/guide/usage)与 [PigeonBeam 说明](/guide/pigeonbeam)）。
:::

::: details 第一次部署要准备什么？
一台装了 Docker 的机器。**不需要**先想管理员密码：启动后打开站点走首启向导当场建号。想批量部署再预设 `PB_ADMIN_PASSWORD`。详见[快速开始](/guide/getting-started)。
:::

## 生态仓库

<div class="pb-links">
  <a class="pb-link" href="https://github.com/pigeonbox/pigeonbox" target="_blank" rel="noreferrer">
    <b>hub 装配仓</b><span>compose / 脚本 / 发布列车 / 文档站</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/core" target="_blank" rel="noreferrer">
    <b>core 业务核心</b><span>17 个域服务 + 仓库 + 存储抽象</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/contracts" target="_blank" rel="noreferrer">
    <b>contracts 契约层</b><span>统一错误码 + Thrift 模型 + IDL</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/server" target="_blank" rel="noreferrer">
    <b>server 部署壳</b><span>薄壳 + 官方 CLI（pb）</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/p2p" target="_blank" rel="noreferrer">
    <b>PigeonBeam 信鸽直传</b><span>独立产品：直传数据面 + 联邦注册中心与中继</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/charts" target="_blank" rel="noreferrer">
    <b>charts Helm</b><span>前后端分离 + 可选数据面</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/frontend-core" target="_blank" rel="noreferrer">
    <b>frontend-core</b><span>平台无关前端应用与宿主 SPI</span>
  </a>
  <a class="pb-link" href="https://github.com/pigeonbox/desktop" target="_blank" rel="noreferrer">
    <b>desktop 桌面端</b><span>Tauri 2 托盘常驻，纯客户端</span>
  </a>
</div>

<div class="pb-cta">
  <h2>现在就把文件发出去</h2>
  <p>一条命令起一个站点，或者先在文档里逛两分钟。</p>
  <a class="pb-btn pb-btn--brand" href="/guide/getting-started">快速开始</a>
  <a class="pb-btn" href="/guide/usage">先看使用说明</a>
</div>
