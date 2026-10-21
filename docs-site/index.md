---
layout: home
title: PigeonBox 文档
# 首页是**文档门户**，介绍页（/about）才是产品门面——两者首屏必须一眼可分：
# 这里不放 hero 大图（留给 /about），标题也写「文档」而非品牌名。
hero:
  name: PigeonBox 文档
  text: 文件快递柜
  tagline: 部署方式、使用说明、API 接入的入口都在这里。产品本身长什么样，看「站点介绍」。
  # 注意：hero 的 tagline 是 v-html 渲染（不走 markdown），写 markdown 链接语法会原样露出
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: 站点介绍
      link: /about
---

<PbSearchCta />

<div class="pb-nav">
  <div class="pb-nav-card">
    <h3>我要部署</h3>
    <ul>
      <li><a href="/guide/getting-started">快速开始（Docker Compose）</a></li>
      <li><a href="/guide/deploy-nas">NAS 六平台原生包</a></li>
      <li><a href="/guide/deploy-kubernetes">Kubernetes（Helm）</a></li>
    </ul>
  </div>
  <div class="pb-nav-card">
    <h3>我要用</h3>
    <ul>
      <li><a href="/guide/usage">使用说明</a></li>
      <li><a href="/guide/pigeonbeam">设备直传（PigeonBeam）</a></li>
      <li><a href="/guide/environment">环境变量参考</a></li>
    </ul>
  </div>
  <div class="pb-nav-card">
    <h3>我要接入</h3>
    <ul>
      <li><a href="/reference/api-tokens">API Token</a></li>
      <li><a href="/reference/mcp">MCP 集成</a></li>
      <li><a href="/guide/error-codes">错误码对照表</a></li>
    </ul>
  </div>
</div>

<div class="pb-cta">
  <h2>先看看它是什么</h2>
  <p>一页讲清 PigeonBox 能做什么、怎么部署、界面长什么样。</p>
  <a class="pb-btn pb-btn--brand" href="/about">站点介绍</a>
  <a class="pb-btn" href="https://github.com/pigeonbox">GitHub（Apache-2.0）</a>
</div>
