# PigeonBox Go SDK（v0）

PigeonBox 官方 Go 客户端：让第三方系统自动完成**寄件 → 取件 → 删除**。
薄封装——只做认证注入、重试/退避、分页、errcode 错误映射；请求/响应模型直接复用
[`github.com/pigeonbox/contracts`](https://github.com/pigeonbox/contracts) 生成物。

## 安装

```bash
go get github.com/pigeonbox/pigeonbox/sdk/go
```

契约钉版在 `go.mod`（contracts vX.Y.Z）：**契约破坏性变更 → 升钉版 → 本 SDK 编译期即红**
（而不是线上 404/400）。

## 快速上手：寄件 → 取件 → 删除

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"log"

	"github.com/pigeonbox/contracts/gen/share"
	pb "github.com/pigeonbox/pigeonbox/sdk/go"
)

func main() {
	ctx := context.Background()

	// API Key 在管理台创建（scope 选 share+user 覆盖下面三条路径；缺能力 403）。
	client, err := pb.New("https://pb.example.com", pb.WithAPIKey("pb_xxx"))
	if err != nil {
		log.Fatal(err)
	}

	// 1) 寄件：文本分享（10 分钟后过期）
	data, err := client.CreateTextShare(ctx, &share.ShareTextReq{
		Text:        "hello from sdk",
		ExpireValue: 10,
		ExpireStyle: "minute",
		RequireAuth: false,
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("取件码:", *data.PickupCode)

	// 2) 取件：元数据查询（不扣取件次数）
	md, err := client.ShareMetadata(ctx, *data.PickupCode)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("类型:", md.Type, "文件数:", md.FileCount)

	// 3) 删除：软删（回收站）+ 永久删除（服务端硬删只认回收站内的分享）
	if err := client.DeleteShare(ctx, data.Code); err != nil {
		log.Fatal(err)
	}

	// 删除生效校验：再查一次应 404
	if _, err := client.ShareMetadata(ctx, *data.PickupCode); !errors.Is(err, pb.ErrNotFound) {
		log.Fatalf("删除未生效或错误码不符: %v", err)
	}
}
```

## 认证

| 方式 | 选项 | 请求头 | 适用 |
|---|---|---|---|
| API Key | `WithAPIKey(key)` | `X-API-Key` | 第三方系统集成（推荐） |
| 用户 JWT | `WithToken(token)` | `Authorization: Bearer` | 以登录用户身份操作 |

API Key 的 scope 按**请求路径**判定：`share`（/share、/chunk、/anonymous、/api/v1/presign）、
`user`（/user、/api/v1/user、/api/v1/notifies）、`admin`（/admin）；**缺能力 403（不是 401）**，
缺省 scope = 全量。登录与造 Key 也有封装：

```go
token, _ := client.Login(ctx, &user.LoginReq{Username: "u", Password: "p"})
authed, _ := pb.New(base, pb.WithToken(token))
key, _, _ := authed.CreateAPIKey(ctx, "my-integration", []string{"share", "user"})
```

## 重试 / 退避

- 幂等方法（GET/DELETE/…）默认最多重试 2 次：传输错误 + `429/502/503/504`；
  指数退避（200ms 起），尊重 `Retry-After`，封顶 30s。
- **POST 不重试**：寄件非幂等，盲目重发会造出重复分享。
- `WithRetry(n, base)` 可调；`WithRetry(0, …)` 关闭。

## 错误处理

业务错误统一为 `*pigeonbox.APIError`（含 HTTP 状态 + errcode 统一业务码 + 服务端 message）：

```go
md, err := client.ShareMetadata(ctx, code)
switch {
case errors.Is(err, pb.ErrNotFound):        // 10004 资源不存在
case errors.Is(err, pb.ErrReachLimit):      // 20004 超过取件次数
case errors.Is(err, pb.ErrShareExpired):    // 20002 分享过期
}
if code, ok := pb.ErrCode(err); ok { // 拿原始码做日志/上报
	fmt.Println("errcode:", code)
}
```

哨兵与 `contracts/errcode` 常量一一对应（`ErrInvalidParam/ErrUnauthorized/ErrForbidden/
ErrNotFound/ErrRateLimit/ErrTooLarge/ErrShareNotFound/ErrShareExpired/ErrPasswordWrong/
ErrReachLimit/ErrPickupCodeNotFound/ErrShareBlocked`）。

## 分页

```go
pageSize := int32(50)
it := client.IterateShares(ctx, &share.UserSharesListReq{PageSize: &pageSize})
for it.Next() {
	fmt.Println(it.Item().Code)
}
if err := it.Err(); err != nil { /* 翻页中途出错 */ }
```

单页版：`ListShares(ctx, req)`（page/page_size/status/search 查询参数）。

## 全链路 demo

```bash
cd sdk/go
go run ./cmd/demo -base http://127.0.0.1:12345 -user admin -password ****
go run ./cmd/demo -base http://127.0.0.1:12345 -api-key pb_xxx
```

CI 里由 `scripts/sdk-demo.sh` 驱动，对真实 server 跑 寄件 → 取件 → 删除 全链路。

## 测试

```bash
cd sdk/go
GOWORK=off go vet ./... && GOWORK=off go test ./...
```

（独立模块，不进 hub go.work——与 `release/trainctl` 同惯例，测试消费 go.mod 钉版契约。）
