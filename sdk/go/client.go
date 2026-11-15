// Package pigeonbox 是 PigeonBox 官方 Go SDK（v0 薄封装）。
//
// 设计边界：只做 HTTP 传输层的横切能力——认证注入（API Key / Bearer）、
// 重试/退避、分页迭代、errcode 错误码映射；请求/响应模型直接复用
// github.com/pigeonbox/contracts 的生成物 ⇒ 契约破坏性变更时本 SDK 升钉版
// 即在编译期报红（而不是运行时 404/400）。
package pigeonbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	// DefaultMaxRetries 幂等方法（GET/DELETE/…）默认最多再试 2 次（共 3 次尝试）。
	DefaultMaxRetries = 2
	// DefaultRetryBase 退避基数：200ms、400ms 指数递增（尊重 Retry-After，封顶 30s）。
	DefaultRetryBase = 200 * time.Millisecond
	maxRetryAfter    = 30 * time.Second
)

// Client 是 SDK 入口。零值不可用，用 New 构造。
type Client struct {
	baseURL    string
	apiKey     string
	token      string
	httpClient *http.Client
	maxRetries int
	retryBase  time.Duration
}

// Option 是 New 的可选项。
type Option func(*Client)

// WithAPIKey 注入 API Key（请求头 X-API-Key；scope 按服务端路径判定：admin/user/share）。
func WithAPIKey(key string) Option {
	return func(c *Client) { c.apiKey = key }
}

// WithToken 注入用户 JWT（请求头 Authorization: Bearer）。
func WithToken(token string) Option {
	return func(c *Client) { c.token = token }
}

// WithHTTPClient 覆盖底层 HTTP 客户端（超时、代理、测试 transport 用）。
func WithHTTPClient(h *http.Client) Option {
	return func(c *Client) { c.httpClient = h }
}

// WithRetry 配置幂等方法的重试次数与退避基数。max<=0 表示不重试。
// 非幂等方法（POST 等）不重试：寄件非幂等，盲目重发会造出重复分享。
func WithRetry(max int, base time.Duration) Option {
	return func(c *Client) {
		if max < 0 {
			max = 0
		}
		c.maxRetries = max
		if base > 0 {
			c.retryBase = base
		}
	}
}

// New 构造 Client。baseURL 形如 http://127.0.0.1:12345（不带路径、可带/不带尾斜杠）。
func New(baseURL string, opts ...Option) (*Client, error) {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return nil, fmt.Errorf("pigeonbox: baseURL 不能为空")
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("pigeonbox: 非法 baseURL %q（需要 http(s)://host[:port]）", baseURL)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("pigeonbox: baseURL scheme 必须是 http/https，got %q", u.Scheme)
	}
	c := &Client{
		baseURL:    baseURL,
		httpClient: &http.Client{Timeout: 30 * time.Second},
		maxRetries: DefaultMaxRetries,
		retryBase:  DefaultRetryBase,
	}
	for _, opt := range opts {
		opt(c)
	}
	return c, nil
}

// wireMsg 是全站统一响应 envelope（contracts 生成模型的外层形态）。
type wireMsg struct {
	Code    int32           `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

// retryableStatus 是幂等方法会重试的 HTTP 状态。
var retryableStatus = map[int]bool{429: true, 502: true, 503: true, 504: true}

// idempotent 判定方法是否可安全重试。
func idempotent(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete, http.MethodOptions:
		return true
	}
	return false
}

// do 执行一次 API 调用：组装 URL/头、幂等重试、解析 envelope。
// out 为指针时把 data 段解进它（业务错误先于解包返回）。
func (c *Client) do(ctx context.Context, method, path string, query url.Values, body, out any) error {
	u := c.baseURL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	var payload []byte
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("pigeonbox: 编码请求体 %s %s: %w", method, path, err)
		}
		payload = b
	}

	attempts := 1
	if idempotent(method) {
		attempts = c.maxRetries + 1
	}
	var retryAfter time.Duration
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			if err := c.sleep(ctx, attempt, retryAfter); err != nil {
				return err
			}
			retryAfter = 0
		}
		req, err := http.NewRequestWithContext(ctx, method, u, bytes.NewReader(payload))
		if err != nil {
			return fmt.Errorf("pigeonbox: 构造请求 %s %s: %w", method, path, err)
		}
		if len(payload) > 0 {
			req.Header.Set("Content-Type", "application/json")
		}
		req.Header.Set("Accept", "application/json")
		if c.apiKey != "" {
			req.Header.Set("X-API-Key", c.apiKey)
		}
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}

		resp, err := c.httpClient.Do(req)
		if err != nil {
			// 传输层错误（连接被拒/超时/读半截）：幂等方法按退避重试。
			if attempt < attempts-1 {
				continue
			}
			return fmt.Errorf("pigeonbox: %s %s: %w", method, path, err)
		}
		b, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if readErr != nil {
			if attempt < attempts-1 {
				continue
			}
			return fmt.Errorf("pigeonbox: 读取响应 %s %s: %w", method, path, readErr)
		}
		if idempotent(method) && attempt < attempts-1 && retryableStatus[resp.StatusCode] {
			retryAfter = parseRetryAfter(resp.Header.Get("Retry-After"))
			continue
		}

		var w wireMsg
		if err := json.Unmarshal(b, &w); err != nil {
			if resp.StatusCode >= http.StatusBadRequest {
				return &APIError{HTTPStatus: resp.StatusCode, Code: 0, Message: snippet(b)}
			}
			return fmt.Errorf("pigeonbox: %s %s 响应非 JSON (HTTP %d): %s", method, path, resp.StatusCode, snippet(b))
		}
		if w.Code != 0 || resp.StatusCode >= http.StatusBadRequest {
			msg := w.Message
			if msg == "" {
				msg = snippet(b)
			}
			return &APIError{HTTPStatus: resp.StatusCode, Code: w.Code, Message: msg}
		}
		if out != nil && len(w.Data) > 0 && string(w.Data) != "null" {
			if err := json.Unmarshal(w.Data, out); err != nil {
				return fmt.Errorf("pigeonbox: 解析 data 段 %s %s: %w", method, path, err)
			}
		}
		return nil
	}
	return nil
}

// sleep 退避等待：指数递增、尊重 Retry-After、封顶 30s；ctx 取消立即返回。
func (c *Client) sleep(ctx context.Context, attempt int, retryAfter time.Duration) error {
	d := c.retryBase << (attempt - 1)
	if d > maxRetryAfter || d <= 0 {
		d = maxRetryAfter
	}
	if retryAfter > d {
		d = retryAfter
	}
	if d > maxRetryAfter {
		d = maxRetryAfter
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// parseRetryAfter 只认 delta-seconds 形态（HTTP-date 不支持，服务端也只发秒数）。
func parseRetryAfter(v string) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	var sec int
	if _, err := fmt.Sscanf(v, "%d", &sec); err != nil || sec <= 0 {
		return 0
	}
	d := time.Duration(sec) * time.Second
	if d > maxRetryAfter {
		d = maxRetryAfter
	}
	return d
}

// snippet 截取响应体前 200 字节做错误消息（防整页 HTML 灌进日志）。
func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
