---
title: 官方 CLI（pb）
---

# 官方 CLI（pb）

> `pb` 是 PigeonBox 的官方命令行客户端：上传分享、查自己的分享列表、取取件链接、删除分享、管理联邦邀请。用 API Key 认证，适合脚本、批处理与 NAS 上的定时任务。

## 下载

CLI 随 [server 仓 Release](https://github.com/pigeonbox/server/releases) 一起发布（首发版本 v3.3.15；当前列车 **v4.6.5**），每个 Release 里有五个预编译二进制：

| 资产名 | 平台 |
|---|---|
| `pb_linux_amd64` | Linux x86_64 |
| `pb_linux_arm64` | Linux aarch64（树莓派 / ARM NAS） |
| `pb_darwin_amd64` | macOS Intel |
| `pb_darwin_arm64` | macOS Apple Silicon |
| `pb_windows_amd64.exe` | Windows x86_64 |

```bash
# Linux x86_64
curl -fLO https://github.com/pigeonbox/server/releases/download/v4.6.5/pb_linux_amd64
chmod +x pb_linux_amd64 && sudo mv pb_linux_amd64 /usr/local/bin/pb
```

::: warning 下载前先对一下版本
`pb` 的取件密码通道与接口返回码语义在 **2.0.0** 是破坏性变更（4.0.0 又改了取件密码通道）⇒
照抄旧版本的示例会装到**落后一整个列车**的 CLI。这里的版本号由
`scripts/check-docs-consistency.sh` 与当前列车号（`release/train.yaml` 的 `train:`）对账，
不匹配即门禁红。
:::

::: tip 需要 macOS / Windows？
上表是各平台的官方预编译版本；本机源码构建也可以（需要 Go 1.26+）：

```bash
git clone https://github.com/pigeonbox/server.git && cd server
GOWORK=off go build -o pb ./cmd/pb
```
:::

## 配置

两个环境变量，缺一不可：

| 变量 | 说明 | 默认值 |
|---|---|---|
| `PB_SERVER` | PigeonBox 服务地址 | `http://localhost:12345` |
| `PB_API_KEY` | 用户级 API Key | 无（**必填**） |

API Key 在**网页端「用户中心 → API 令牌」**创建。写入 shell 配置即可长期生效：

```bash
export PB_SERVER="https://box.example.com"
export PB_API_KEY="pb_sk_xxxxxxxx"
```

::: warning API Key 等同于账号权限
它能列出、下载、删除你的全部分享。别写进公开仓库或共享的 dotfiles 里。
:::

## 命令

```
pb put     [flags] <file...>   上传文件（多文件合并为一个分享）
pb import  [flags] <path>     服务器本地文件导入（免上传，NAS 场景）
pb ls                         我的分享列表
pb url    [-p <password>] <code>   取分享链接与下载直链
pb rm    <code>               删除分享（移入回收站，可在用户中心恢复）
pb p2p    peers|invites|accept|push   联邦管理（需 admin API Key）
pb help                       显示用法
```

### put —— 上传

```bash
# 上传文件
pb put report.pdf

# 多文件合并为一个分享
pb put a.zip b.zip c.txt

# 分享一段文本
pb put -t "会议纪要：本周完成 X，下周做 Y"

# 设取件密码 / 有效期 / 自定义取件码
pb put -p "hunter2" -e 7d -c "4821" report.pdf
```

| 参数 | 说明 |
|---|---|
| `-t <text>` | 分享文本（与文件互斥） |
| `-e <expire>` | 有效期：`30m` / `1h` / `7d` / `2w` / `3M` / `1y` / `forever`（默认 `1d`） |
| `-p <password>` | 取件密码（**不写入分享链接**，取件时才需要） |
| `-c <code>` | 自定义取件码（登录用户） |

### import —— 服务器本地导入

服务器**磁盘上已有的文件**直接转成分享，不走网络上传。NAS 场景最常用（文件已经在机器上了，再传一遍是浪费）：

```bash
pb import -e 1h -p "hunter2" /volume1/share/backup.tar.gz
```

参数与 `put` 相同（`-e` / `-p` / `-c`）。

### ls —— 我的分享

```bash
$ pb ls
共 2 条分享：
  4821          0 次取件       1024 B  report.pdf
  a1b2c3        3 次取件    1048576 B  backup.tar.gz
```

第一列是取件码（拿到它的人即可取件），后面依次是已用取件次数、字节数、内容名。

### url —— 取链接

```bash
$ pb url 4821
https://box.example.com/#/share/4821
直链（令牌短时效，随取随用勿缓存）: https://box.example.com/share/download/xxxx
```

密码保护的分享要带上取件密码：

```bash
pb url -p "hunter2" 4821
```

::: warning 直链是短时效令牌
`直链` 那行带下载令牌，**随取随用、别缓存**——过期后再用会 401。需要长期可用就用上面那行 `#/share/<code>` 分享链接（对方自行输密码取件）。
:::

### rm —— 删除

```bash
pb rm 4821
```

分享被**移入回收站**（软删除），可以在网页端「用户中心 → 回收站」恢复。回收站里再删一次才是彻底清除。

### p2p —— 联邦

联邦面（实例间推送邀请、设备名录）需要 **admin 权限的 API Key**：

```bash
pb p2p peers                    # 在线设备名录（node_id 用于定向邀请）
pb p2p invites                  # 待收邀请列表
pb p2p accept <invite_id>       # 认领邀请并接收
pb p2p push <目标地址> <口令> [附言]   # 把口令推给另一实例（免口令交接）
```

> 设备直传已独立为 [PigeonBeam（信鸽直传）](/guide/pigeonbeam) 应用，本 CLI 不再提供直传子命令。

## 退出码

`pb` 的退出码分级，脚本可据此区分「命令写错了」和「服务端拒绝了」：

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 运行失败（服务端拒绝、网络错误、取件码不存在……） |
| `2` | 用法错误（参数写错、少了子命令……） |

```bash
if ! pb put -p "$PWD" report.pdf; then
  case $? in
    1) echo "服务端拒绝了，检查取件码与有效期" ;;
    2) echo "命令用法错了" ;;
  esac
fi
```

## 脚本示例

把当天导出的日志打成密码分享，取件码写进当日交接文件：

```bash
#!/usr/bin/env bash
set -euo pipefail

ts=$(date +%Y%m%d)
code=$(pb put -t "$(cat /var/log/app/${ts}.log)" | awk '{print $NF}')

echo "取件码：${code}" >> /var/log/handoff.log
```

::: tip 取件密码别走命令行
`-p` 的密码会出现在本机进程列表（`ps`）里。批量场景建议用**环境变量**或密码管理器注入，并给分享设置短有效期。
:::
