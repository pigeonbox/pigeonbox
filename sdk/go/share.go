package pigeonbox

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"

	"github.com/pigeonbox/contracts/gen/publicapi"
	"github.com/pigeonbox/contracts/gen/share"
)

// maxIterPages 翻页安全阀：服务端分页字段自相矛盾（HasNext 恒 true）时
// 防止迭代器无限翻页。
const maxIterPages = 10000

// CreateTextShare 寄件（文本分享）：POST /share/text/（scope=share）。
// 返回 data 段（含 6 位取件码 pickup_code 与分享码 code）。
func (c *Client) CreateTextShare(ctx context.Context, req *share.ShareTextReq) (*share.ShareData, error) {
	var data *share.ShareData
	if err := c.do(ctx, http.MethodPost, "/share/text/", nil, req, &data); err != nil {
		return nil, err
	}
	return data, nil
}

// ShareMetadata 取件前置查询：GET /share/metadata/{code}（scope=share，公开面）。
// 返回分享元数据（类型/大小/取件计数/过期时间…）。
func (c *Client) ShareMetadata(ctx context.Context, code string) (*publicapi.ShareMetadataData, error) {
	var data *publicapi.ShareMetadataData
	if err := c.do(ctx, http.MethodGet, "/share/metadata/"+url.PathEscape(code), nil, nil, &data); err != nil {
		return nil, err
	}
	return data, nil
}

// DeleteShare 删除（核心路径）：软删进回收站 + 永久删除两步合并。
// 服务端硬删只认「已在回收站」的分享（否则 ErrNotInRecycleBin），
// 单调 HardDeleteShare 会 404 ⇒ 对外的“删除”必须先 SoftDeleteShares。
func (c *Client) DeleteShare(ctx context.Context, code string) error {
	if _, err := c.SoftDeleteShares(ctx, []string{code}); err != nil {
		return err
	}
	_, err := c.HardDeleteShare(ctx, code)
	return err
}

// SoftDeleteShares 批量软删除（进回收站）：POST /api/v1/user/shares/batch-delete（scope=user）。
func (c *Client) SoftDeleteShares(ctx context.Context, codes []string) (map[string]int32, error) {
	var data map[string]int32
	body := map[string]any{"codes": codes}
	if err := c.do(ctx, http.MethodPost, "/api/v1/user/shares/batch-delete", nil, body, &data); err != nil {
		return nil, err
	}
	return data, nil
}

// HardDeleteShare 永久删除：DELETE /api/v1/user/shares/{code}/hard（scope=user）。
// ⚠️ 只认回收站内的分享；一般调用方用 DeleteShare（软删+硬删）。
// 返回 data 段（服务端回执的计数 map，可为 nil）。
func (c *Client) HardDeleteShare(ctx context.Context, code string) (map[string]int32, error) {
	var data map[string]int32
	if err := c.do(ctx, http.MethodDelete, "/api/v1/user/shares/"+url.PathEscape(code)+"/hard", nil, nil, &data); err != nil {
		return nil, err
	}
	return data, nil
}

// ListShares 我的分享列表（分页单页）：GET /api/v1/user/shares（scope=user）。
// req 的 page/page_size/status/search 映射为查询参数（nil 走服务端默认）。
func (c *Client) ListShares(ctx context.Context, req *share.UserSharesListReq) (*share.UserSharesListData, error) {
	q := url.Values{}
	if req != nil {
		if req.Status != nil && *req.Status != "" {
			q.Set("status", *req.Status)
		}
		if req.Search != nil && *req.Search != "" {
			q.Set("search", *req.Search)
		}
		if req.Page != nil && *req.Page > 0 {
			q.Set("page", strconv.Itoa(int(*req.Page)))
		}
		if req.PageSize != nil && *req.PageSize > 0 {
			q.Set("page_size", strconv.Itoa(int(*req.PageSize)))
		}
	}
	var data *share.UserSharesListData
	if err := c.do(ctx, http.MethodGet, "/api/v1/user/shares", q, nil, &data); err != nil {
		return nil, err
	}
	return data, nil
}

// ShareIterator 是 ListShares 的跨页迭代器（分页能力）。
// 用法：
//
//	it := client.IterateShares(ctx, &share.UserSharesListReq{...})
//	for it.Next() {
//	    fmt.Println(it.Item().Code)
//	}
//	if err := it.Err(); err != nil { ... }
//
// 迭代器绑定构造时的 ctx（翻页请求都走它）。
type ShareIterator struct {
	c    *Client
	ctx  context.Context
	base share.UserSharesListReq

	nextPage  int32
	fetched   int
	buf       []*share.UserShareItemData
	pos       int
	exhausted bool
	err       error
}

// IterateShares 构造跨页迭代器。req 作为每页的查询基底（Page 字段被迭代器接管）。
func (c *Client) IterateShares(ctx context.Context, req *share.UserSharesListReq) *ShareIterator {
	it := &ShareIterator{c: c, ctx: ctx, nextPage: 1}
	if req != nil {
		it.base = *req
		// 拷贝指针字段指向的值，避免与调用方共享可变状态。
		if req.Status != nil {
			v := *req.Status
			it.base.Status = &v
		}
		if req.Search != nil {
			v := *req.Search
			it.base.Search = &v
		}
		if req.PageSize != nil {
			v := *req.PageSize
			it.base.PageSize = &v
		}
	}
	return it
}

// Next 前进到下一条；没有更多或出错时返回 false（用 Err 区分）。
func (it *ShareIterator) Next() bool {
	if it.err != nil {
		return false
	}
	for it.pos >= len(it.buf) {
		if it.exhausted {
			return false
		}
		it.fetched++
		if it.fetched > maxIterPages {
			it.err = fmt.Errorf("pigeonbox: 分页迭代超过 %d 页（服务端分页字段疑似异常）", maxIterPages)
			return false
		}
		page := it.nextPage
		req := it.base
		req.Page = &page
		data, err := it.c.ListShares(it.ctx, &req)
		if err != nil {
			it.err = err
			return false
		}
		if data == nil || len(data.Items) == 0 {
			it.exhausted = true
			return false
		}
		it.buf = data.Items
		it.pos = 0
		it.nextPage++
		if !data.HasNext || (data.TotalPages > 0 && int64(it.nextPage) > data.TotalPages) {
			it.exhausted = true
		}
	}
	it.pos++
	return true
}

// Item 返回最近一次 Next 取到的条目（Next 返回 false 后勿调用）。
func (it *ShareIterator) Item() *share.UserShareItemData {
	return it.buf[it.pos-1]
}

// Err 返回迭代期间的首个错误（正常结束为 nil）。
func (it *ShareIterator) Err() error { return it.err }
