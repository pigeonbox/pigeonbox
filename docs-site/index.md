---
layout: home

hero:
  name: PigeonBox
  image:
    src: /logo.svg
    alt: PigeonBox
  text: 文件快递柜
  tagline: 匿名口令分享文本/文件的开源自托管平台 —— 多用户、多存储后端、Kubernetes 友好、内置 MCP AI 集成
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/pigeonbox

features:
  - icon: 🔗
    title: 匿名口令分享
    details: 文本/文件一键分享，凭取件口令提取；支持密码保护与过期自动清理。
  - icon: 👥
    title: 多用户与 API Token
    details: 用户注册/登录/封禁管理；个人访问令牌（pb_sk_ 前缀）让脚本与 CI 直接调用接口，无需浏览器会话。
  - icon: 💾
    title: 多存储后端
    details: 共 14 种热切换后端：local / S3(MinIO) / 阿里 OSS / 腾讯 COS / 百度 BOS / 金山 KS3 / 华为 OBS / WebDAV / FTP / SFTP / GCS / Azure Blob / HDFS / OneDrive，云厂商按 region 自动推导 endpoint。
  - icon: 📦
    title: 分片上传 + 秒传
    details: 大文件分片上传；服务端流式 SHA-256 计算哈希，同哈希文件秒传直接出码，省时省带宽。
  - icon: ⚡
    title: S3 预签名直传
    details: 大文件由浏览器直传对象存储，后端只签发预签名 URL，不占用应用带宽。
  - icon: 🤖
    title: MCP AI 集成
    details: 内置 Model Context Protocol server（Streamable HTTP），Claude Desktop 等 AI 客户端可直接创建/查询/清理文件分享。
  - icon: 🕸️
    title: P2P 联邦与设备直传
    details: 每台服务器都是对称 P2P 节点，管理后台一键热启停；联邦注册中心让多节点口令跨站可达（文件始终源节点直出）；p2pc 端到端加密设备直传（随 server 镜像/NAS 包/桌面客户端分发，流量不过服务器）。
  - icon: 🔐
    title: OIDC 单点登录
    details: 对接任意 OIDC IdP（Keycloak 等），按账号映射或自动建号，签发本站 JWT；API Token、内容审核、SMTP 通知等治理能力内建。
---
