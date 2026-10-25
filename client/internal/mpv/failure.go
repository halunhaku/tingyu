package mpv

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// FailureMessage renders one user-facing sentence for a failure. The UI shows
// Message and nothing else; Detail stays in the snapshot for logs. Messages
// say what a person can do next, because "loading failed: Failed to open
// http://…" told nobody whether to reconnect, re-login or reload the file.
func FailureMessage(kind FailureKind, status int, detail string) string {
	detail = strings.TrimSpace(detail)
	switch kind {
	case FailureNetwork:
		return "无法连接到服务器：请检查网络后重试"
	case FailureUnauthorized:
		if status > 0 {
			return fmt.Sprintf("直链已失效或没有访问权限（HTTP %d）：请重新获取链接或重新登录", status)
		}
		return "直链已失效或没有访问权限：请重新获取链接或重新登录"
	case FailureNotFound:
		if status > 0 {
			return fmt.Sprintf("找不到这个文件（HTTP %d）", status)
		}
		return "找不到这个文件：它可能已被移动或删除"
	case FailureDecode:
		if detail != "" {
			return "无法解码这个文件：" + detail
		}
		return "无法解码这个文件"
	}
	if detail != "" {
		return "播放失败：" + detail
	}
	return "播放失败"
}

// httpStatusPattern matches the one line FFmpeg prints with the response code
// ("HTTP error 401 Unauthorized"). This is the only place the status appears:
// mpv's own error text is a generic "Failed to open".
var httpStatusPattern = regexp.MustCompile(`HTTP error (\d{3})`)

// networkMarkers are the transport failures that mean "no server", as opposed
// to "server said no".
var networkMarkers = []string{
	"connection refused",
	"connection timed out",
	"connection reset",
	"network is unreachable",
	"no route to host",
	"name or service not known",
	"temporary failure in name resolution",
	"failed to resolve",
	"could not resolve",
	"operation timed out",
}

// decodeMarkers mean the bytes arrived and could not be played.
var decodeMarkers = []string{
	"failed to recognize file format",
	"could not open codec",
	"failed to initialize decoder",
	"failed to open decoder",
	"unsupported format",
	"no audio",
}

// Direct links carry their signature in the query string and sometimes
// userinfo in the authority; both must not reach a log or a bug report.
var (
	urlWithQuery = regexp.MustCompile(`(https?://[^\s?]+)\?[^\s]*`)
	urlUserinfo  = regexp.MustCompile(`(https?://)[^/@\s]+:[^/@\s]+@`)
)

// redactURIs removes query strings and userinfo from every URL in text.
func redactURIs(text string) string {
	text = urlWithQuery.ReplaceAllString(text, `$1?<redacted>`)
	return urlUserinfo.ReplaceAllString(text, `$1`)
}

// loadFailure classifies a failed load from what the engine observed: the URI,
// mpv's error string, the HTTP status FFmpeg logged, and the warning lines of
// this load attempt. The engine cannot distinguish "401" from "offline" on its
// own, and the plan requires a readable, actionable prompt for both.
func loadFailure(uri, detail string, status int, logText string) *Failure {
	lowered := strings.ToLower(detail + " " + logText)
	if status == 0 {
		if match := httpStatusPattern.FindStringSubmatch(logText + " " + detail); match != nil {
			if parsed, err := strconv.Atoi(match[1]); err == nil {
				status = parsed
			}
		}
	}
	// A path with no URL scheme is local: missing and undecodable are the only
	// two interesting answers, and both are checkable.
	if uri != "" && !strings.Contains(uri, "://") {
		if _, err := os.Stat(uri); err != nil {
			return newFailure(FailureNotFound, 0, detail)
		}
		return newFailure(FailureDecode, 0, detail)
	}
	switch status {
	case 401, 403:
		return newFailure(FailureUnauthorized, status, detail)
	case 404, 410:
		return newFailure(FailureNotFound, status, detail)
	}
	if containsAny(lowered, networkMarkers) {
		return newFailure(FailureNetwork, status, detail)
	}
	if containsAny(lowered, decodeMarkers) {
		return newFailure(FailureDecode, status, detail)
	}
	return newFailure(FailureUnknown, status, detail)
}

func newFailure(kind FailureKind, status int, detail string) *Failure {
	detail = redactURIs(detail)
	return &Failure{Kind: kind, Status: status, Detail: detail, Message: FailureMessage(kind, status, detail)}
}

func containsAny(haystack string, needles []string) bool {
	for _, needle := range needles {
		if strings.Contains(haystack, needle) {
			return true
		}
	}
	return false
}
