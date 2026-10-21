// 站点统一图标集（线性风格，24×24，stroke 1.75，currentColor）。
//
// 全站图标只此一处：首页、站点介绍页、能力卡片都从这里取，避免同一含义在
// 不同页面画成两种样子（此前首页用 emoji、介绍页用另一套，视觉不统一）。
// 形状用结构化描述而不是裸 SVG 字符串，组件里统一渲染成 <path>/<circle>/<rect>。

export type IconShape =
  | { t: 'path'; d: string }
  | { t: 'circle'; cx: number; cy: number; r: number }
  | { t: 'rect'; x: number; y: number; w: number; h: number; rx?: number }

export const icons: Record<string, IconShape[]> = {
  // 匿名口令分享 —— 链条
  link: [
    { t: 'path', d: 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71' },
    { t: 'path', d: 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71' },
  ],

  // 密码与有效期 —— 盾牌 + 勾
  shield: [
    { t: 'path', d: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' },
    { t: 'path', d: 'm9 12 2 2 4-4' },
  ],

  // 分片上传与秒传 —— 层叠
  layers: [
    { t: 'path', d: 'm12 2 9 5-9 5-9-5 9-5z' },
    { t: 'path', d: 'm3 12 9 5 9-5' },
    { t: 'path', d: 'm3 17 9 5 9-5' },
  ],

  // 预签名直传 —— 云 + 上传
  cloud: [
    { t: 'path', d: 'M6.5 19a4.5 4.5 0 0 1-.42-8.98A6 6 0 0 1 17.7 9.2 4.9 4.9 0 0 1 17.5 19h-11z' },
    { t: 'path', d: 'M12 21v-8' },
    { t: 'path', d: 'm9.5 15.5 2.5-2.5 2.5 2.5' },
  ],

  // 存储后端 —— 数据库
  database: [
    { t: 'path', d: 'M20 5c0 1.66-3.58 3-8 3s-8-1.34-8-3 3.58-3 8-3 8 1.34 8 3z' },
    { t: 'path', d: 'M4 5v6c0 1.66 3.58 3 8 3s8-1.34 8-3V5' },
    { t: 'path', d: 'M4 11v6c0 1.66 3.58 3 8 3s8-1.34 8-3v-6' },
  ],

  // 多用户 —— 用户组
  users: [
    { t: 'path', d: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2' },
    { t: 'circle', cx: 9, cy: 7, r: 4 },
    { t: 'path', d: 'M22 21v-2a4 4 0 0 0-3-3.87' },
    { t: 'path', d: 'M16 3.13a4 4 0 0 1 0 7.75' },
  ],

  // MCP / AI 集成 —— 芯片
  chip: [
    { t: 'rect', x: 7, y: 7, w: 10, h: 10, rx: 2 },
    { t: 'rect', x: 10, y: 10, w: 4, h: 4, rx: 1 },
    { t: 'path', d: 'M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3' },
  ],

  // P2P 联邦与直传 —— 三节点互联
  share: [
    { t: 'circle', cx: 18, cy: 5, r: 3 },
    { t: 'circle', cx: 6, cy: 12, r: 3 },
    { t: 'circle', cx: 18, cy: 19, r: 3 },
    { t: 'path', d: 'm8.6 10.5 6.8-4M8.6 13.5l6.8 4' },
  ],

  // OIDC 单点登录 —— 钥匙
  key: [
    { t: 'circle', cx: 7.5, cy: 15.5, r: 4.5 },
    { t: 'path', d: 'm10.7 12.3 8.8-8.8' },
    { t: 'path', d: 'm15 8 2 2' },
    { t: 'path', d: 'm18 5 2 2' },
  ],

  // 容器 / 部署 —— 立方体
  container: [
    { t: 'path', d: 'M21 8v8a2 2 0 0 1-1 1.73l-7 4a2 2 0 0 1-2 0l-7-4A2 2 0 0 1 3 16V8a2 2 0 0 1 1-1.73l7-4a2 2 0 0 1 2 0l7 4A2 2 0 0 1 21 8z' },
    { t: 'path', d: 'm3.3 7 8.7 5 8.7-5' },
    { t: 'path', d: 'M12 22V12' },
  ],

  // 文档 / 说明 —— 文件
  doc: [
    { t: 'path', d: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z' },
    { t: 'path', d: 'M14 2v6h6' },
    { t: 'path', d: 'M8 13h8M8 17h5' },
  ],

  // 代码 / API —— 尖括号
  code: [
    { t: 'path', d: 'm8 8-4 4 4 4' },
    { t: 'path', d: 'm16 8 4 4-4 4' },
    { t: 'path', d: 'm13 4-2 16' },
  ],
}
