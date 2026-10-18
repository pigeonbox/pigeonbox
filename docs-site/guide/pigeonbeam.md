# PigeonBeam（信鸽直传）— 设备直传独立应用

> PigeonBox 生态的姊妹应用：任意两台设备之间端到端直传文件——**口令即身份（PAKE）、无需账号、无需同网段**，UDP 打洞优先、失败自动回落加密中继，QUIC 多流 + 断点续传 + sha256 校验，服务端全程只见密文。

与文件快递柜（PigeonBox）的关系：**完全独立可用**；配置文件柜地址 + API Key 后，可把收到的文件一键「投递到柜」——转存为快递柜分享，换取 6 位取件码发给任何人。

## 三个组件

| 组件 | 是什么 |
|---|---|
| `p2pc` | 直传客户端（命令行）：六平台静态二进制 |
| `p2pc-web` | 直传客户端（网页模式）：单个纯静态二进制，本机起服务、浏览器即界面（拖放收发/进度可视化/浏览器直下链接/投递到柜） |
| `p2pd` | 注册中心 + 加密中继（可选自建）：官方公共节点已运营，Docker 镜像 `ghcr.io/pigeonbox/p2p` |

## 快速开始

从 [p2p 仓 Releases](https://github.com/pigeonbox/p2p/releases) 下载对应平台二进制（文件名含目标平台 triple，附 sha256 清单），两端各跑一份：

```bash
# 发送方(自动生成口令 XXXX-XXXX-XXXX 并等待对方取走)
p2pc send 报告.pdf --registry http://home.enjoye.top:56788

# 接收方(输入同一口令,文件直连下载到当前目录)
p2pc recv XXXX-XXXX-XXXX --registry http://home.enjoye.top:56788

# 配对码模式(2026-10-18):4 位定时码,免抄 12 位口令
p2pc send 报告.pdf --pair
# 配对码: 4823（5 分钟内有效）→ 对方输入后还需你确认「接受」
p2pc recv 4823 --registry http://home.enjoye.top:56788

# 不想敲命令行:网页模式(默认 127.0.0.1:12348,自动开浏览器)
./p2pc-web-x86_64-unknown-linux-gnu
```

`--registry` 缺省指向本机 `127.0.0.1:12346`（自建场景）；跨网直传用官方公共节点（如上），或自建后填自己的地址。支持多文件/目录、断点续传、逐文件授权、IPv6 双栈。

## 配对码：4 位定时码，免抄口令

不想转抄 12 位口令时，用**配对码模式**——4 位数字、5 分钟有效、一次性：

| 端 | 做法 |
|---|---|
| 发送方（亮码） | `p2pc send 文件 --pair` → 屏幕显示 4 位码 + 倒计时；有人敲码时屏幕弹「设备 X 请求连接」，回车接受（输 n 拒绝） |
| 接收方（敲码） | `p2pc recv 4823` → 等对方确认后自动开始接收 |
| 反向（接收方亮码） | `p2pc recv --pair` → 把自己的 4 位码告诉对方，对方 `p2pc send 文件 --code 4823` 推送过来 |

网页模式（p2pc-web）与 PigeonBox 桌面版同样内置配对码：发送侧亮码+倒计时+「接受/拒绝」卡片，接收框 4 位数字自动识别。

**它是怎么安全的**：4 位码只是「门牌号+门铃」——真正的会话密钥是发送方设备本地生成的高熵口令，经注册中心在「你确认接受」之后才一次性交给敲码方。码猜中也只是按响门铃（限流+拒绝即烧码+一次性发放），拿不到任何数据；数据面仍走 PAKE + 端到端加密，与口令模式同一条链路。信任模型细节见 [p2p 仓 README](https://github.com/pigeonbox/p2p#安全模型)。

## 投递到柜（与文件快递柜的桥）

1. 在 p2pc-web「文件柜」页填入你的 PigeonBox 服务器地址与 API Key（柜侧 **个人设置 → API Token** 生成）；
2. 接收完成后，每个文件旁出现「投递到柜」按钮；
3. 点击即上传建分享，换取 6 位取件码——对方凭码在快递柜取件，无需安装任何东西。

典型场景：手机/外网设备 →（直传）→ 家里 NAS 或电脑 →（投递到柜）→ 6 位取件码 → 微信发给朋友。PigeonBox 侧零改动、零 PigeonBeam 代码——桥完全走公开 API。

## 自建注册中心（可选）

```bash
docker run -d --name pigeonbeam-registry -p 12346:12346/udp -p 12346:12346 -p 12347:12347 \
  -e PB_P2P_ADMIN_PASSWORD=$(openssl rand -hex 16) \
  ghcr.io/pigeonbox/p2p:latest
```

更多配置、API 与安全模型见 [p2p 仓 README](https://github.com/pigeonbox/p2p)，产品定位与拆分路线见 [docs/PRODUCT.md](https://github.com/pigeonbox/p2p/blob/main/docs/PRODUCT.md)。
