// demo 是 SDK 全链路演示：寄件 → 取件 → 删除。
// CI 的 scripts/sdk-demo.sh 用它对真实 server 冒烟（issue #367 验收）。
//
// 用法：
//
//	go run ./cmd/demo -base http://127.0.0.1:18777 -user smoker -password smoke12345
//	go run ./cmd/demo -base http://127.0.0.1:18777 -api-key pb_xxx
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/pigeonbox/contracts/gen/share"
	"github.com/pigeonbox/contracts/gen/user"

	pb "github.com/pigeonbox/pigeonbox/sdk/go"
)

func main() {
	base := flag.String("base", "", "服务端 base URL（如 http://127.0.0.1:18777）")
	apiKey := flag.String("api-key", "", "直接使用已有 API Key（跳过登录）")
	username := flag.String("user", "", "登录用户名（登录失败且站点开放注册时自动注册）")
	password := flag.String("password", "", "登录/注册密码")
	flag.Parse()
	if *base == "" {
		fmt.Fprintln(os.Stderr, "用法: demo -base URL [-api-key KEY | -user U -password P]")
		os.Exit(2)
	}
	if err := run(*base, *apiKey, *username, *password); err != nil {
		fmt.Fprintln(os.Stderr, "DEMO FAILED:", err)
		os.Exit(1)
	}
	fmt.Println("SDK demo PASS: 寄件 → 取件 → 删除 全链路 OK")
}

// step 打一行进度（CI 日志可读）。
func step(format string, args ...any) {
	fmt.Printf("  ✓ "+format+"\n", args...)
}

func run(base, apiKey, username, password string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// ── 认证：优先 API Key（第三方集成的正道）；否则登录后现造一个 ──────
	key := apiKey
	var token string
	if key == "" {
		if username == "" || password == "" {
			return errors.New("未提供 -api-key 时必须给 -user 与 -password")
		}
		bootstrap, err := pb.New(base, pb.WithRetry(2, 100*time.Millisecond))
		if err != nil {
			return err
		}
		token, err = bootstrap.Login(ctx, &user.LoginReq{Username: username, Password: password})
		if err != nil {
			// 登录失败 → 尝试注册（站点须开放注册）再登录。
			rerr := bootstrap.Register(ctx, &user.RegisterReq{
				Username: username,
				Email:    username + "@example.com",
				Password: password,
				Nickname: username,
			})
			if rerr != nil {
				return fmt.Errorf("登录与注册均失败: 登录=%v 注册=%v", err, rerr)
			}
			token, err = bootstrap.Login(ctx, &user.LoginReq{Username: username, Password: password})
			if err != nil {
				return fmt.Errorf("注册后登录失败: %w", err)
			}
		}
		step("登录成功 %s", username)
		// 用登录态造一个 share+user scope 的 API Key，后续三步全走 X-API-Key。
		authed, err := pb.New(base, pb.WithToken(token), pb.WithRetry(2, 100*time.Millisecond))
		if err != nil {
			return err
		}
		k, _, kerr := authed.CreateAPIKey(ctx, "sdk-demo", []string{"share", "user"})
		if kerr != nil {
			return fmt.Errorf("创建 API Key 失败: %w", kerr)
		}
		key = k
		step("创建 API Key 成功（scopes=share,user）")
	}

	c, err := pb.New(base, pb.WithAPIKey(key), pb.WithRetry(2, 100*time.Millisecond))
	if err != nil {
		return err
	}

	// ── 1) 寄件：文本分享 ──────────────────────────────────────────────
	data, err := c.CreateTextShare(ctx, &share.ShareTextReq{
		Text:        "pigeonbox sdk demo: 寄件→取件→删除",
		ExpireValue: 10,
		ExpireStyle: "minute",
		RequireAuth: false,
	})
	if err != nil {
		return fmt.Errorf("寄件失败: %w", err)
	}
	if data == nil || data.Code == "" {
		return fmt.Errorf("寄件响应缺分享码: %+v", data)
	}
	shareCode := data.Code
	lookup := shareCode
	if data.PickupCode != nil && *data.PickupCode != "" {
		lookup = *data.PickupCode
	}
	step("寄件成功 code=%s pickup=%s", shareCode, lookup)

	// ── 2) 取件：元数据查询（不扣次数） ────────────────────────────────
	md, err := c.ShareMetadata(ctx, lookup)
	if err != nil {
		return fmt.Errorf("取件元数据失败: %w", err)
	}
	if md == nil || md.Code == "" {
		return fmt.Errorf("元数据响应缺 code: %+v", md)
	}
	step("取件元数据成功 type=%s file_count=%d", md.Type, md.FileCount)

	// ── 3) 删除：软删（回收站）+ 永久删除，随后验证已消失 ──────────────
	if err := c.DeleteShare(ctx, shareCode); err != nil {
		return fmt.Errorf("删除失败: %w", err)
	}
	step("删除成功（软删+硬删）code=%s", shareCode)

	if _, err := c.ShareMetadata(ctx, lookup); err == nil {
		return errors.New("删除后仍能查到元数据（删除未生效）")
	} else if !errors.Is(err, pb.ErrNotFound) &&
		!errors.Is(err, pb.ErrShareNotFound) &&
		!errors.Is(err, pb.ErrPickupCodeNotFound) {
		return fmt.Errorf("删除后查询返回了预期外的错误: %w", err)
	}
	step("删除生效：元数据查询已 404")
	return nil
}
