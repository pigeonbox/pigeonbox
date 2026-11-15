package pigeonbox

import (
	"context"
	"net/http"

	"github.com/pigeonbox/contracts/gen/user"
)

// Login 用户登录：POST /user/login，返回 JWT（data.token）。
// 拿到 token 后用 WithToken 注入后续调用；第三方集成更推荐 WithAPIKey。
func (c *Client) Login(ctx context.Context, req *user.LoginReq) (string, error) {
	var data *user.LoginData
	if err := c.do(ctx, http.MethodPost, "/user/login", nil, req, &data); err != nil {
		return "", err
	}
	if data == nil || data.Token == "" {
		return "", &APIError{Message: "登录响应缺 token"}
	}
	return data.Token, nil
}

// Register 用户注册：POST /user/register（站点须开放注册）。
func (c *Client) Register(ctx context.Context, req *user.RegisterReq) error {
	var data *user.UserData
	return c.do(ctx, http.MethodPost, "/user/register", nil, req, &data)
}

// CreateAPIKey 为当前身份创建 API Key：POST /user/api-keys（需 Bearer 登录态）。
// scopes 留空 = 全量；指定时取值 admin/user/share（缺能力的服务端 403）。
// 返回的 plaintext key 只在本响应出现一次，之后只能看到 prefix。
func (c *Client) CreateAPIKey(ctx context.Context, name string, scopes []string) (string, *user.APIKeyData, error) {
	req := &user.CreateAPIKeyReq{Name: name, Scopes: scopes}
	var data *user.CreateAPIKeyData
	if err := c.do(ctx, http.MethodPost, "/user/api-keys", nil, req, &data); err != nil {
		return "", nil, err
	}
	if data == nil || data.Key == "" {
		return "", nil, &APIError{Message: "创建 API Key 响应缺 key"}
	}
	return data.Key, data.APIKey, nil
}
