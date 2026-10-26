package sources

// Error copy and classification. Every message here is the Flutter client's
// sentence, character for character: users migrating from it must not see the
// wording change for the same failure, and the M3 acceptance quotes these
// strings. The kinds are what the UI reacts to: ErrAuth turns a source card
// into a "重新登录" entry instead of an empty list (plan §6 M3).

import (
	"errors"
	"fmt"
	"strings"
)

// ErrorKind classifies a source failure for the UI.
type ErrorKind int

const (
	// KindOther is a failure with a readable message and no special entry.
	KindOther ErrorKind = iota
	// KindAuth means the credential is missing, wrong or expired.
	KindAuth
	// KindRateLimited means the server asked us to slow down.
	KindRateLimited
	// KindNetwork means the transport failed (offline, DNS, TLS, proxy).
	KindNetwork
	// KindNotFound means the file is gone.
	KindNotFound
	// KindParse means the server answered something we cannot read.
	KindParse
)

// Error is a source failure carrying the sentence the UI shows.
type Error struct {
	Kind    ErrorKind
	Message string
	// Err keeps the underlying error for logs; it is never shown.
	Err error
}

func (e *Error) Error() string {
	if e.Message != "" {
		return e.Message
	}
	if e.Err != nil {
		return e.Err.Error()
	}
	return "来源操作失败"
}

func (e *Error) Unwrap() error { return e.Err }

// newError builds a classified failure.
func newError(kind ErrorKind, format string, args ...any) *Error {
	return &Error{Kind: kind, Message: fmt.Sprintf(format, args...)}
}

// wrapError adds a readable sentence around an underlying failure.
func wrapError(kind ErrorKind, err error, format string, args ...any) *Error {
	message := fmt.Sprintf(format, args...)
	if err != nil && strings.TrimSpace(err.Error()) != "" {
		message += ": " + err.Error()
	}
	return &Error{Kind: kind, Message: message, Err: err}
}

// IsAuth reports whether err is a credential failure (missing, rejected or
// expired). The UI uses it to offer re-login.
func IsAuth(err error) bool {
	var source *Error
	if errors.As(err, &source) {
		return source.Kind == KindAuth
	}
	return false
}

// KindOf returns the classification of err, KindOther when it has none.
func KindOf(err error) ErrorKind {
	var source *Error
	if errors.As(err, &source) {
		return source.Kind
	}
	return KindOther
}

// WebDAV error copy (webdav_client.dart). Do not reword: the Flutter client's
// users have seen these sentences for years.
const (
	WebDAVUnauthorized = "WebDAV 认证失败，请检查账号和应用专用密码"
	WebDAVForbidden    = "WebDAV 拒绝访问该目录 (403 Forbidden)"
	// WebDAVFlowControl is the old 503 default text (Nutstore's temporary flow
	// control).
	WebDAVFlowControl = "坚果云提示请求过于频繁 (503 临时流控)，请等待 5-10 分钟自动解封"
	// WebDAVBlocked is used when the body says BlockedTemporarily.
	WebDAVBlocked = "坚果云提示请求过于频繁（临时封禁中），请稍候 5-10 分钟自动解封"
)

// webDAVServersideError is the text for any other non-2xx response.
func webDAVServerError(status int) *Error {
	return newError(KindOther, "WebDAV 服务器返回错误 (%d): HTTP %d", status, status)
}

// webDAVNetworkError wraps a transport failure.
func webDAVNetworkError(err error) *Error {
	return wrapError(KindNetwork, err, "网络连接失败")
}

// webDAVRateLimited picks the Nutstore sentence from the response body.
func webDAVRateLimited(body string) *Error {
	if strings.Contains(body, "BlockedTemporarily") {
		return newError(KindRateLimited, "%s", WebDAVBlocked)
	}
	return newError(KindRateLimited, "%s", WebDAVFlowControl)
}

// Quark error copy (quark_drive_client.dart / quark_auth.dart).
const (
	QuarkUnauthenticatedMessage = "夸克网盘登录凭据已失效，请重新登录"
	QuarkRateLimitedMessage     = "夸克网盘请求过于频繁，请稍候再试"
	QuarkCookieFormatError      = "Cookie 为空或格式不正确，请粘贴完整的 Cookie 请求头"
	QuarkSessionExpiredMessage  = "Cookie 已失效或过期，请重新选择登录方式"
	// QuarkAuthUnavailableMessage is the sentence when the session could not be
	// checked at all (network, unexpected response).
	QuarkAuthUnavailableMessage = "暂时无法校验夸克登录，请检查网络后重试"
)

func quarkNetworkError(err error) *Error {
	return wrapError(KindNetwork, err, "夸克网络连接异常")
}

func quarkParseError(format string, args ...any) *Error {
	return newError(KindParse, "夸克数据解析失败: "+format, args...)
}

func quarkAuthError(message string) *Error {
	return newError(KindAuth, "%s", message)
}
