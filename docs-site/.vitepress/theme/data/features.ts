// 站点能力清单（单一真相源）。
//
// 首页与站点介绍页共用这一份：标题、说明、图标都只在这里写一次，
// 避免两个页面各写一版后文案漂移、图标画风不一致。

export interface Feature {
  /** 图标名，对应 ./icons.ts */
  icon: string
  title: string
  details: string
}

export const features: Feature[] = [
  {
    icon: 'link',
    title: '匿名口令分享',
    details: '文本与文件同权铸造 6 位取件码，双方都不必注册。',
  },
  {
    icon: 'shield',
    title: '密码与有效期',
    details: '两道护栏任选，到期自动清理；口令泄露可在后台一键删除该次分享。',
  },
  {
    icon: 'layers',
    title: '分片上传与秒传',
    details: '大文件分片上传，服务端流式算 SHA-256，同一内容再传直接秒出码。',
  },
  {
    icon: 'cloud',
    title: '预签名直传',
    details: '超过阈值（默认 100MB）由浏览器直传对象存储，不占应用带宽。',
  },
  {
    icon: 'database',
    title: '14 种存储后端',
    details: 'local / S3 / OSS / COS / WebDAV / SFTP / HDFS / OneDrive 等，热切换。',
  },
  {
    icon: 'users',
    title: '多用户与 API Token',
    details: '注册登录、封禁、通知齐备；pb_sk_ 令牌让脚本和 CI 直接调接口。',
  },
  {
    icon: 'chip',
    title: 'MCP AI 集成',
    details: '内置 MCP server，Claude Desktop 等 AI 客户端可直建、直查、直清分享。',
  },
  {
    icon: 'share',
    title: 'P2P 联邦（跨站取件）',
    details: '接入联邦后口令可跨站路由，文件始终留在源站；设备直传已拆为独立应用 PigeonBeam。',
  },
  {
    icon: 'key',
    title: 'OIDC 与内容治理',
    details: '对接任意 OIDC IdP 并自动建号；公告、审核、限流、活动流内建。',
  },
  {
    icon: 'rocket',
    title: '装完即用',
    details: '不需要预置管理员密码：启动后打开站点走首启向导当场建号，公网可加令牌防抢注。',
  },
]
