package pigeonbox

import (
	"errors"
	"fmt"

	"github.com/pigeonbox/contracts/errcode"
)

// 语义哨兵：errcode 统一错误码 → 可 errors.Is 判定的语义 error。
// 取值与 contracts/errcode 常量一一对应（SDK 不自造码）。
var (
	ErrInvalidParam = &sentinel{errcode.CodeInvalidParam, "pigeonbox: 参数错误"}
	ErrUnauthorized = &sentinel{errcode.CodeUnauthorized, "pigeonbox: 未登录"}
	ErrForbidden    = &sentinel{errcode.CodeForbidden, "pigeonbox: 无权限"}
	ErrNotFound     = &sentinel{errcode.CodeNotFound, "pigeonbox: 资源不存在"}
	ErrRateLimit    = &sentinel{errcode.CodeRateLimit, "pigeonbox: 限流"}
	ErrUnavailable  = &sentinel{errcode.CodeUnavailable, "pigeonbox: 服务不可用"}
	ErrTooLarge     = &sentinel{errcode.CodeTooLarge, "pigeonbox: 请求体过大"}

	ErrShareNotFound      = &sentinel{errcode.CodeShareNotFound, "pigeonbox: 分享不存在"}
	ErrShareExpired       = &sentinel{errcode.CodeShareExpired, "pigeonbox: 分享已过期"}
	ErrPasswordWrong      = &sentinel{errcode.CodeSharePasswordWrong, "pigeonbox: 密码错误"}
	ErrReachLimit         = &sentinel{errcode.CodeShareReachLimit, "pigeonbox: 超过取件次数"}
	ErrPickupCodeNotFound = &sentinel{errcode.CodePickupCodeNotFound, "pigeonbox: 取件码不存在"}
	ErrShareBlocked       = &sentinel{errcode.CodeShareBlocked, "pigeonbox: 分享已被管理员禁用"}
)

// sentinel 是语义哨兵的实现：按 errcode 数值参与 errors.Is 匹配。
type sentinel struct {
	code int32
	msg  string
}

func (s *sentinel) Error() string { return s.msg }

// APIError 是所有业务/HTTP 层错误的统一形态。
type APIError struct {
	// HTTPStatus HTTP 状态码（传输层返回 0 表示未拿到响应）。
	HTTPStatus int
	// Code errcode 统一业务码（0 = 服务端未给出，见 Message）。
	Code int32
	// Message 服务端 message 或响应体摘要。
	Message string
}

func (e *APIError) Error() string {
	switch {
	case e.Code != 0 && e.HTTPStatus != 0:
		return fmt.Sprintf("pigeonbox: API错误 code=%d http=%d: %s", e.Code, e.HTTPStatus, e.Message)
	case e.Code != 0:
		return fmt.Sprintf("pigeonbox: API错误 code=%d: %s", e.Code, e.Message)
	default:
		return fmt.Sprintf("pigeonbox: HTTP %d: %s", e.HTTPStatus, e.Message)
	}
}

// Is 让 errors.Is(err, ErrNotFound) 这类判定按 errcode 数值匹配。
func (e *APIError) Is(target error) bool {
	s, ok := target.(*sentinel)
	return ok && s.code == e.Code
}

// AsAPIError 从错误链里取 *APIError（拿原始码/HTTP 状态用）。
func AsAPIError(err error) (*APIError, bool) {
	var e *APIError
	ok := errors.As(err, &e)
	return e, ok
}

// ErrCode 从错误链里取 errcode 统一业务码（非业务错误返回 false）。
func ErrCode(err error) (int32, bool) {
	e, ok := AsAPIError(err)
	if !ok || e.Code == 0 {
		return 0, false
	}
	return e.Code, true
}
