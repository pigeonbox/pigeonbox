package pigeonbox

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pigeonbox/contracts/errcode"
	"github.com/pigeonbox/contracts/gen/share"
	"github.com/pigeonbox/contracts/gen/user"
)

// envelope 构造统一响应体。
func envelope(code int32, message, data string) string {
	return fmt.Sprintf(`{"code":%d,"message":%q,"data":%s}`, code, message, data)
}

// newTestClient 起 mock server 并返回（记录每个请求）。
func newTestClient(t *testing.T, h http.HandlerFunc, opts ...Option) (*Client, *httptest.Server, *[]string) {
	t.Helper()
	var paths []string
	wrapped := func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.Method+" "+r.URL.Path)
		h(w, r)
	}
	srv := httptest.NewServer(http.HandlerFunc(wrapped))
	t.Cleanup(srv.Close)
	opts = append([]Option{WithRetry(2, time.Millisecond), WithHTTPClient(srv.Client())}, opts...)
	c, err := New(srv.URL, opts...)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return c, srv, &paths
}

func TestNewValidation(t *testing.T) {
	for _, bad := range []string{"", "   ", "127.0.0.1:12345", "ftp://x", "://x"} {
		if _, err := New(bad); err == nil {
			t.Errorf("New(%q) 应报错", bad)
		}
	}
	if _, err := New("http://127.0.0.1:12345/"); err != nil {
		t.Errorf("合法 baseURL 不应报错: %v", err)
	}
}

// 寄件：POST /share/text/ + X-API-Key 注入 + 请求体字段。
func TestCreateTextShare(t *testing.T) {
	var gotKey, gotCT, body string
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/share/text/" {
			t.Errorf("意外请求 %s %s", r.Method, r.URL.Path)
		}
		gotKey = r.Header.Get("X-API-Key")
		gotCT = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		_, _ = fmt.Fprint(w, envelope(0, "ok", `{"code":"abc123","url":"http://h/s/abc123","pickup_code":"654321"}`))
	}, WithAPIKey("pb_test_key"))

	data, err := c.CreateTextShare(context.Background(), &share.ShareTextReq{
		Text: "hello", ExpireValue: 10, ExpireStyle: "minute", RequireAuth: false,
	})
	if err != nil {
		t.Fatalf("CreateTextShare: %v", err)
	}
	if gotKey != "pb_test_key" {
		t.Errorf("X-API-Key 未注入: %q", gotKey)
	}
	if !strings.HasPrefix(gotCT, "application/json") {
		t.Errorf("Content-Type 应为 JSON: %q", gotCT)
	}
	var req map[string]any
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatalf("请求体非 JSON: %v", err)
	}
	if req["text"] != "hello" || req["expire_style"] != "minute" {
		t.Errorf("请求体字段不符: %s", body)
	}
	if data == nil || data.Code != "abc123" || data.PickupCode == nil || *data.PickupCode != "654321" {
		t.Errorf("解析结果不符: %+v", data)
	}
}

// 取件元数据：GET /share/metadata/{code} + Bearer 注入。
func TestShareMetadata(t *testing.T) {
	var gotAuth string
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/share/metadata/654321" {
			t.Errorf("意外请求 %s %s", r.Method, r.URL.Path)
		}
		gotAuth = r.Header.Get("Authorization")
		_, _ = fmt.Fprint(w, envelope(0, "ok", `{"code":"abc123","type":"text","size":11,"has_password":false,"expired_count":10,"used_count":1,"encrypted":false,"file_count":1,"created_at":"2026-11-16T00:00:00Z"}`))
	}, WithToken("tok-1"))

	md, err := c.ShareMetadata(context.Background(), "654321")
	if err != nil {
		t.Fatalf("ShareMetadata: %v", err)
	}
	if gotAuth != "Bearer tok-1" {
		t.Errorf("Authorization 未注入: %q", gotAuth)
	}
	if md.Code != "abc123" || md.Type != "text" || md.FileCount != 1 {
		t.Errorf("元数据不符: %+v", md)
	}
}

// 删除核心路径 = 软删（batch-delete）+ 硬删（/hard）两连发。
func TestDeleteShare(t *testing.T) {
	var calls []string
	var softBody string
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/user/shares/batch-delete":
			b, _ := io.ReadAll(r.Body)
			softBody = string(b)
			calls = append(calls, "soft")
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"deleted":1}`))
		case r.Method == http.MethodDelete && r.URL.Path == "/api/v1/user/shares/abc123/hard":
			calls = append(calls, "hard")
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"deleted":1}`))
		default:
			t.Errorf("意外请求 %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}, WithAPIKey("pb_k"))

	if err := c.DeleteShare(context.Background(), "abc123"); err != nil {
		t.Fatalf("DeleteShare: %v", err)
	}
	if len(calls) != 2 || calls[0] != "soft" || calls[1] != "hard" {
		t.Errorf("调用序列不符: %v", calls)
	}
	if !strings.Contains(softBody, "abc123") {
		t.Errorf("软删请求体应含 code: %s", softBody)
	}
}

// 错误码映射：envelope code → 语义哨兵（errors.Is）+ 原码可取。
func TestErrorMapping(t *testing.T) {
	cases := []struct {
		code    int32
		http    int
		wantIs  error
		wantErr bool // 期望判为非业务错误（无哨兵）
	}{
		{errcode.CodeNotFound, http.StatusNotFound, ErrNotFound, false},
		{errcode.CodeShareReachLimit, http.StatusForbidden, ErrReachLimit, false},
		{errcode.CodeShareExpired, http.StatusNotFound, ErrShareExpired, false},
		{errcode.CodeInvalidParam, http.StatusBadRequest, ErrInvalidParam, false},
		{errcode.CodeRateLimit, http.StatusTooManyRequests, ErrRateLimit, false},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprint(tc.code), func(t *testing.T) {
			// 每个用例独立 server（429/5xx 会被重试 ⇒ 关掉重试测状态码路径）。
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.http)
				_, _ = fmt.Fprint(w, envelope(tc.code, "boom", "null"))
			}))
			defer srv.Close()
			c, err := New(srv.URL, WithRetry(0, time.Millisecond), WithHTTPClient(srv.Client()))
			if err != nil {
				t.Fatal(err)
			}
			_, err = c.ShareMetadata(context.Background(), "x")
			if err == nil {
				t.Fatal("应报错")
			}
			if !errors.Is(err, tc.wantIs) {
				t.Errorf("errors.Is(err, %v) 失败: %v", tc.wantIs, err)
			}
			got, ok := ErrCode(err)
			if !ok || got != tc.code {
				t.Errorf("ErrCode = %d,%v want %d", got, ok, tc.code)
			}
			ae, ok := AsAPIError(err)
			if !ok || ae.HTTPStatus != tc.http {
				t.Errorf("AsAPIError HTTPStatus = %+v", ae)
			}
		})
	}
}

// 传输错误 → 包装为普通 error（不是 APIError）。
func TestTransportErrorNotAPIError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	srv.Close() // 立刻拒绝连接
	c, err := New(srv.URL, WithRetry(0, time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.ShareMetadata(context.Background(), "x")
	if err == nil {
		t.Fatal("应报错")
	}
	if _, ok := AsAPIError(err); ok {
		t.Errorf("传输错误不应是 APIError: %v", err)
	}
}

// 幂等 GET：503 两次后成功（退避重试生效）。
func TestRetryIdempotentGET(t *testing.T) {
	var n atomic.Int32
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if n.Add(1) <= 2 {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = fmt.Fprint(w, envelope(errcode.CodeUnavailable, "warming up", "null"))
			return
		}
		_, _ = fmt.Fprint(w, envelope(0, "ok", `{"code":"abc123","type":"text","size":0,"has_password":false,"expired_count":1,"used_count":0,"encrypted":false,"file_count":1,"created_at":"t"}`))
	})
	md, err := c.ShareMetadata(context.Background(), "x")
	if err != nil {
		t.Fatalf("重试后应成功: %v", err)
	}
	if md.Code != "abc123" {
		t.Errorf("md 不符: %+v", md)
	}
	if got := n.Load(); got != 3 {
		t.Errorf("请求次数 = %d, want 3", got)
	}
}

// 非幂等 POST：503 不重试（寄件不可盲目重发）。
func TestNoRetryOnPOST(t *testing.T) {
	var n atomic.Int32
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = fmt.Fprint(w, envelope(errcode.CodeUnavailable, "warming up", "null"))
	})
	_, err := c.CreateTextShare(context.Background(), &share.ShareTextReq{Text: "x", ExpireValue: 1, ExpireStyle: "minute"})
	if err == nil {
		t.Fatal("应报错")
	}
	if got := n.Load(); got != 1 {
		t.Errorf("POST 不应重试: 请求次数 = %d", got)
	}
}

// Retry-After 头被尊重（取秒数）。
func TestParseRetryAfter(t *testing.T) {
	if d := parseRetryAfter("2"); d != 2*time.Second {
		t.Errorf("parseRetryAfter(2) = %v", d)
	}
	if d := parseRetryAfter(""); d != 0 {
		t.Errorf("空值应为 0")
	}
	if d := parseRetryAfter("9999"); d != maxRetryAfter {
		t.Errorf("应封顶 maxRetryAfter, got %v", d)
	}
}

// 分页迭代：两页翻完、page 参数递增、顺序保持。
func TestShareIterator(t *testing.T) {
	var pages []string
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/user/shares" {
			t.Errorf("意外路径 %s", r.URL.Path)
		}
		page := r.URL.Query().Get("page")
		pages = append(pages, page)
		switch page {
		case "", "1":
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"items":[{"id":1,"code":"c1","file_name":"a","file_path":"/a"},{"id":2,"code":"c2","file_name":"b","file_path":"/b"}],"total":3,"page":1,"page_size":2,"total_pages":2,"has_next":true,"has_prev":false}`))
		case "2":
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"items":[{"id":3,"code":"c3","file_name":"c","file_path":"/c"}],"total":3,"page":2,"page_size":2,"total_pages":2,"has_next":false,"has_prev":true}`))
		default:
			t.Errorf("意外 page=%q", page)
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"items":[],"total":3,"page":9,"page_size":2,"total_pages":2,"has_next":false,"has_prev":true}`))
		}
	})

	var got []string
	it := c.IterateShares(context.Background(), &share.UserSharesListReq{PageSize: int32Ptr(2)})
	for it.Next() {
		got = append(got, it.Item().Code)
	}
	if err := it.Err(); err != nil {
		t.Fatalf("迭代出错: %v", err)
	}
	want := []string{"c1", "c2", "c3"}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Errorf("迭代结果 = %v, want %v", got, want)
	}
	if len(pages) != 2 || pages[0] != "1" || pages[1] != "2" {
		t.Errorf("翻页序列 = %v", pages)
	}
}

// 登录 + 造 Key：认证引导链路。
func TestLoginAndCreateAPIKey(t *testing.T) {
	// 预置登录态：Login 顺带验证「已有 Bearer 时不互相覆盖」，造 Key 依赖它。
	c, _, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/user/login":
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"token":"tok-9","user":{"id":1,"username":"u"}}`))
		case r.Method == http.MethodPost && r.URL.Path == "/user/api-keys":
			if r.Header.Get("Authorization") != "Bearer tok-9" {
				t.Errorf("造 Key 应带登录态: %q", r.Header.Get("Authorization"))
			}
			b, _ := io.ReadAll(r.Body)
			var req user.CreateAPIKeyReq
			_ = json.Unmarshal(b, &req)
			if req.Name != "k1" || len(req.Scopes) != 2 {
				t.Errorf("造 Key 请求不符: %s", b)
			}
			_, _ = fmt.Fprint(w, envelope(0, "ok", `{"key":"pb_live_secret","api_key":{"id":7,"name":"k1","prefix":"pb_","last_used_at":"","expires_at":"","created_at":"","revoked":false,"scopes":["share","user"]}}`))
		default:
			t.Errorf("意外请求 %s %s", r.Method, r.URL.Path)
		}
	}, WithToken("tok-9"))

	token, err := c.Login(context.Background(), &user.LoginReq{Username: "u", Password: "p"})
	if err != nil || token != "tok-9" {
		t.Fatalf("Login = %q, %v", token, err)
	}
	key, meta, err := c.CreateAPIKey(context.Background(), "k1", []string{"share", "user"})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}
	if key != "pb_live_secret" || meta == nil || meta.ID != 7 {
		t.Errorf("Key 解析不符: %q %+v", key, meta)
	}
}

func int32Ptr(v int32) *int32 { return &v }
