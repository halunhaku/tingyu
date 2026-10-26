package sources

// Quark Drive API client, ported from app/lib/sources/quark/quark_drive_client.dart.
//
// The API is not officially documented for third parties. Everything here
// follows what the Flutter client does — endpoint paths, query parameters,
// headers, the three accepted shapes of the download response, the pagination
// completeness rules and the status codes that mean "logged out". Where the
// Flutter client cannot know either (a real account's live behaviour), this
// port makes the same assumption and the M3 record says so.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Quark endpoint defaults and limits.
const (
	quarkDefaultPCBase  = "https://drive-pc.quark.cn"
	quarkDefaultCDNBase = "https://drive.quark.cn"
	// quarkUserAgent is the Electron desktop client's UA, byte-identical to
	// the Dart constant: the web UA is treated differently by the API.
	quarkUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.23.0 Chrome/112.0.5615.165 Electron/23.3.13 Safari/537.36 Channel/pckk_other_ch"
	quarkReferer   = "https://pan.quark.cn/"
	quarkOrigin    = "https://pan.quark.cn"
	quarkAccept    = "application/json, text/plain, */*"
	// quarkPageSize is the server's page limit; quarkMaxPages bounds a folder
	// the server never stops paging, which would otherwise loop forever.
	quarkPageSize = 100
	quarkMaxPages = 100
	// QuarkDownloadTTL is how long a direct link is reused. The Flutter client
	// wrote links with this TTL but never read the cache back; this port reads
	// it, so playing one track twice does not hit the drive API twice.
	QuarkDownloadTTL = 5400 * time.Second
	// quarkFolderDelay is the polite gap between folder requests (80 ms in
	// the Dart client).
	quarkFolderDelay = 80 * time.Millisecond
	quarkMaxBody     = 8 << 20
)

// QuarkOptions configure the client. Zero values take the production
// endpoints; tests and the acceptance harness point every host at a local
// server so no real account is ever used.
type QuarkOptions struct {
	HTTP        *http.Client
	PCBaseURL   string
	CDNBaseURL  string
	Retry       Retry
	Clock       func() time.Time
	FolderDelay time.Duration
	Logf        func(string, ...any)
}

// QuarkClient talks to the drive API.
type QuarkClient struct {
	http        *http.Client
	pcBase      string
	cdnBase     string
	retry       Retry
	clock       func() time.Time
	folderDelay time.Duration
	logf        func(string, ...any)

	mu       sync.Mutex
	download map[string]quarkCachedLink
}

type quarkCachedLink struct {
	url     string
	expires time.Time
}

// NewQuarkClient builds a client. Base URLs must be absolute http(s) URLs
// without a query, like the Dart constructor's validation.
func NewQuarkClient(options QuarkOptions) (*QuarkClient, error) {
	pcBase, err := normalizeBaseURL(options.PCBaseURL, quarkDefaultPCBase)
	if err != nil {
		return nil, err
	}
	cdnBase, err := normalizeBaseURL(options.CDNBaseURL, quarkDefaultCDNBase)
	if err != nil {
		return nil, err
	}
	if options.Retry == (Retry{}) {
		options.Retry = DefaultRetry
	}
	if options.HTTP == nil {
		options.HTTP = newHTTPClient(webdavTimeout)
	}
	clock := options.Clock
	if clock == nil {
		clock = func() time.Time { return time.Now().UTC() }
	}
	delay := options.FolderDelay
	if delay < 0 {
		delay = 0
	} else if delay == 0 {
		delay = quarkFolderDelay
	}
	return &QuarkClient{
		http:        options.HTTP,
		pcBase:      pcBase,
		cdnBase:     cdnBase,
		retry:       options.Retry,
		clock:       clock,
		folderDelay: delay,
		logf:        options.Logf,
		download:    map[string]quarkCachedLink{},
	}, nil
}

func normalizeBaseURL(value, fallback string) (string, error) {
	text := strings.TrimSpace(value)
	if text == "" {
		text = fallback
	}
	parsed, err := url.Parse(text)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", newError(KindOther, "夸克接口地址无效")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", newError(KindOther, "夸克接口地址不能带查询参数")
	}
	return strings.TrimRight(text, "/") + "/", nil
}

// QuarkItem is one file or folder.
type QuarkItem struct {
	ID         string
	Name       string
	IsFolder   bool
	Size       int64
	FormatType string
}

// QuarkFolderListing is one directory. Complete is false when pages are
// missing or the response could not be parsed — the caller must then treat the
// result as a truncated snapshot, or a bad response would look like "every
// track in this folder was deleted".
type QuarkFolderListing struct {
	Items            []QuarkItem
	Complete         bool
	IncompleteReason string
}

type quarkFolderPage struct {
	items     []QuarkItem
	total     int64
	hasTotal  bool
	malformed bool
}

type quarkResponse struct {
	status int
	body   string
}

// json decodes the body when it is a JSON object.
func (r *quarkResponse) json() map[string]any {
	if r == nil || r.body == "" {
		return nil
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(r.body), &decoded); err != nil {
		return nil
	}
	return decoded
}

// ValidateSession checks a Cookie with the cheapest listing request and
// separates "expired" from "cannot tell right now".
func (c *QuarkClient) ValidateSession(ctx context.Context, session *QuarkSession) QuarkSessionCheck {
	if session == nil || session.IsEmpty() {
		return QuarkSessionCheck{State: QuarkSessionExpired}
	}
	endpoint := c.endpoint(c.pcBase, "1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=1")
	response, err := c.send(ctx, endpoint, session, http.MethodGet, nil)
	if err != nil {
		if ctx.Err() != nil {
			return QuarkSessionCheck{State: QuarkSessionUnavailable, Message: "请求已取消"}
		}
		return QuarkSessionCheck{State: QuarkSessionUnavailable, Message: quarkNetworkError(err).Message}
	}
	if response.status == 401 || response.status == 403 {
		return QuarkSessionCheck{State: QuarkSessionExpired}
	}
	if response.status < 200 || response.status > 299 {
		return QuarkSessionCheck{State: QuarkSessionUnavailable, Message: fmt.Sprintf("HTTP %d", response.status)}
	}
	body := response.json()
	if body == nil {
		return QuarkSessionCheck{State: QuarkSessionUnavailable, Message: "服务返回了无法识别的数据"}
	}
	status := intValue(body["status"])
	switch status {
	case 200:
		return QuarkSessionCheck{State: QuarkSessionValid, Nickname: "夸克用户"}
	case 400, 401, 403, 31001:
		return QuarkSessionCheck{State: QuarkSessionExpired}
	}
	message, _ := body["message"].(string)
	if message == "" {
		message = fmt.Sprintf("接口 status %d", status)
	}
	return QuarkSessionCheck{State: QuarkSessionUnavailable, Message: message}
}

// ListFolder returns a whole directory, paging until a short page. A folder
// whose pages cannot all be fetched is marked incomplete (never "empty").
func (c *QuarkClient) ListFolder(ctx context.Context, fid string, session *QuarkSession) (QuarkFolderListing, error) {
	items := make([]QuarkItem, 0, quarkPageSize)
	var total int64
	hasTotal := false
	for page := 1; page <= quarkMaxPages; page++ {
		if ctx.Err() != nil {
			return QuarkFolderListing{Items: items, Complete: false, IncompleteReason: "已取消"}, ctx.Err()
		}
		result, err := c.listFolderPage(ctx, fid, page, session)
		if err != nil {
			return QuarkFolderListing{Items: items}, err
		}
		if result.malformed {
			return QuarkFolderListing{
				Items:            items,
				Complete:         false,
				IncompleteReason: "服务端返回了无法解析的目录内容",
			}, nil
		}
		if !hasTotal && result.hasTotal {
			total, hasTotal = result.total, true
		}
		items = append(items, result.items...)
		if len(result.items) < quarkPageSize {
			if hasTotal && int64(len(items)) < total {
				return QuarkFolderListing{
					Items:            items,
					Complete:         false,
					IncompleteReason: fmt.Sprintf("目录未取全（%d/%d 项）", len(items), total),
				}, nil
			}
			return QuarkFolderListing{Items: items, Complete: true}, nil
		}
	}
	return QuarkFolderListing{
		Items:            items,
		Complete:         false,
		IncompleteReason: fmt.Sprintf("目录超过 %d 页未取完", quarkMaxPages),
	}, nil
}

func (c *QuarkClient) listFolderPage(ctx context.Context, fid string, page int, session *QuarkSession) (quarkFolderPage, error) {
	endpoint := c.endpoint(c.pcBase, fmt.Sprintf(
		"1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=%s&_page=%d&_size=%d&_fetch_total=1&_sort=file_type:asc,file_name:asc",
		url.QueryEscape(fid), page, quarkPageSize))
	response, err := c.send(ctx, endpoint, session, http.MethodGet, nil)
	if err != nil {
		return quarkFolderPage{}, quarkNetworkError(err)
	}
	if response.status == 401 || response.status == 403 {
		return quarkFolderPage{}, quarkAuthError(QuarkUnauthenticatedMessage)
	}
	if response.status == 429 {
		return quarkFolderPage{}, newError(KindRateLimited, "%s", QuarkRateLimitedMessage)
	}
	if response.status < 200 || response.status > 299 {
		return quarkFolderPage{}, newError(KindNetwork, "夸克网络连接异常: 读取夸克文件列表失败 (HTTP %d)", response.status)
	}
	body := response.json()
	apiStatus := intValue(body["status"])
	apiCode := intValue(body["code"])
	if apiStatus == 400 || apiStatus == 401 || apiStatus == 403 || apiCode == 31001 {
		return quarkFolderPage{}, quarkAuthError(QuarkUnauthenticatedMessage)
	}
	if apiStatus == 429 {
		return quarkFolderPage{}, newError(KindRateLimited, "%s", QuarkRateLimitedMessage)
	}
	if body != nil && apiStatus != 200 {
		message, _ := body["message"].(string)
		if message == "" {
			message = fmt.Sprintf("接口 status %d", apiStatus)
		}
		return quarkFolderPage{}, newError(KindNetwork, "夸克网络连接异常: %s", message)
	}
	data, ok := body["data"].(map[string]any)
	if !ok {
		// Not an empty folder: a malformed response must not be read as one.
		return quarkFolderPage{malformed: true}, nil
	}
	list, ok := data["list"].([]any)
	if !ok {
		return quarkFolderPage{malformed: true}, nil
	}
	result := quarkFolderPage{items: make([]QuarkItem, 0, len(list))}
	if total, ok := data["total"]; ok {
		result.total = int64Value(total)
		result.hasTotal = true
	}
	for _, entry := range list {
		item, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		id, idOK := item["fid"].(string)
		name, nameOK := item["file_name"].(string)
		if !idOK || !nameOK {
			continue
		}
		fileType := intValue(item["file_type"]) // 0 = folder, 1 = file
		format, _ := item["format_type"].(string)
		if format == "" {
			if fileType == 0 {
				format = "dir"
			} else {
				format = "file"
			}
		}
		result.items = append(result.items, QuarkItem{
			ID:         id,
			Name:       name,
			IsFolder:   fileType == 0,
			Size:       int64Value(item["size"]),
			FormatType: format,
		})
	}
	return result, nil
}

// GetDownloadURL returns a direct link, from the cache while it is fresh.
// drive-pc is tried first, then the CDN host, as the Dart client does.
func (c *QuarkClient) GetDownloadURL(ctx context.Context, fid string, session *QuarkSession) (string, error) {
	if session == nil || session.IsEmpty() {
		return "", quarkAuthError(QuarkUnauthenticatedMessage)
	}
	c.mu.Lock()
	cached, hit := c.download[fid]
	c.mu.Unlock()
	if hit && cached.expires.After(c.clock()) {
		return cached.url, nil
	}

	endpoints := []string{
		c.endpoint(c.pcBase, "1/clouddrive/file/download?pr=ucpro&fr=pc"),
		c.endpoint(c.cdnBase, "1/clouddrive/file/download?pr=ucpro&fr=pc"),
	}
	var lastErr error = quarkParseError("响应中没有 download_url")
	for _, endpoint := range endpoints {
		link, err := c.requestDownloadURL(ctx, endpoint, fid, session)
		if err == nil {
			c.mu.Lock()
			c.download[fid] = quarkCachedLink{url: link, expires: c.clock().Add(QuarkDownloadTTL)}
			c.mu.Unlock()
			return link, nil
		}
		lastErr = err
		if IsAuth(err) {
			return "", err
		}
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
	}
	return "", lastErr
}

func (c *QuarkClient) requestDownloadURL(ctx context.Context, endpoint, fid string, session *QuarkSession) (string, error) {
	response, err := c.send(ctx, endpoint, session, http.MethodPost, map[string]any{"fids": []string{fid}})
	if err != nil {
		return "", quarkNetworkError(err)
	}
	body := response.json()
	apiStatus := intValue(body["status"])
	apiCode := intValue(body["code"])
	message, _ := body["message"].(string)
	if response.status == 401 || apiStatus == 401 || apiCode == 31001 ||
		strings.Contains(strings.ToLower(message), "login") {
		return "", quarkAuthError(QuarkUnauthenticatedMessage)
	}
	if response.status == 429 || apiStatus == 429 {
		return "", newError(KindRateLimited, "%s", QuarkRateLimitedMessage)
	}
	if response.status < 200 || response.status > 299 {
		detail := fmt.Sprintf("HTTP %d", response.status)
		if message != "" {
			detail += " " + message
		}
		return "", newError(KindNetwork, "夸克网络连接异常: 直链失败 %s", detail)
	}
	if body != nil && apiStatus != 200 {
		if message == "" {
			message = fmt.Sprintf("接口 status %d", apiStatus)
		}
		return "", newError(KindNetwork, "夸克网络连接异常: %s", message)
	}
	if link := extractDownloadURL(body); link != "" {
		return link, nil
	}
	preview := response.body
	if len(preview) > 180 {
		preview = preview[:180]
	}
	return "", quarkParseError("响应中没有 download_url %s", preview)
}

// downloadURLKeys are the candidate fields, in priority order.
var downloadURLKeys = []string{"download_url", "download_url_https", "downloadUrl", "url"}

// extractDownloadURL reads the three shapes the API has returned: data[],
// data{}, and data.list[].
func extractDownloadURL(body map[string]any) string {
	fromEntry := func(entry map[string]any) string {
		for _, key := range downloadURLKeys {
			value, ok := entry[key].(string)
			if ok && value != "" {
				if parsed, err := url.Parse(value); err == nil && parsed.Scheme != "" {
					return value
				}
			}
		}
		return ""
	}
	fromList := func(value any) string {
		list, ok := value.([]any)
		if !ok {
			return ""
		}
		for _, element := range list {
			entry, ok := element.(map[string]any)
			if !ok {
				continue
			}
			if link := fromEntry(entry); link != "" {
				return link
			}
		}
		return ""
	}
	if body == nil {
		return ""
	}
	data := body["data"]
	if link := fromList(data); link != "" {
		return link
	}
	if object, ok := data.(map[string]any); ok {
		if link := fromEntry(object); link != "" {
			return link
		}
		return fromList(object["list"])
	}
	return ""
}

// Invalidate drops one cached direct link, so the next Open fetches a fresh
// one. This is what turns "直链过期" from a dead button into a retry.
func (c *QuarkClient) Invalidate(fid string) {
	c.mu.Lock()
	delete(c.download, fid)
	c.mu.Unlock()
}

// QuarkPlaybackHeaders are what the CDN needs: the Cookie, the desktop UA and
// the pan referer. Accept differs from the API requests on purpose.
func QuarkPlaybackHeaders(session *QuarkSession) map[string]string {
	return map[string]string{
		"Cookie":     session.Header(),
		"User-Agent": quarkUserAgent,
		"Referer":    quarkReferer,
		"Origin":     quarkOrigin,
		"Accept":     "*/*",
	}
}

// send performs a request with replay. jsonBody selects POST with a JSON body.
// Set-Cookie responses are merged into the session on every attempt.
func (c *QuarkClient) send(ctx context.Context, endpoint string, session *QuarkSession, method string, body any) (*quarkResponse, error) {
	var last *quarkResponse
	err := c.retry.Do(ctx, c.logf, func(attempt int) (bool, error) {
		last = nil
		response, sendErr := c.sendOnce(ctx, endpoint, session, method, body)
		if sendErr != nil {
			return true, sendErr
		}
		last = response
		return RetryableStatus(response.status), nil
	})
	if err != nil {
		return nil, err
	}
	if last == nil {
		return nil, fmt.Errorf("夸克请求没有响应")
	}
	return last, nil
}

func (c *QuarkClient) sendOnce(ctx context.Context, endpoint string, session *QuarkSession, method string, body any) (*quarkResponse, error) {
	requestCtx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		payload = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(requestCtx, method, endpoint, payload)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Cookie", session.Header())
	req.Header.Set("User-Agent", quarkUserAgent)
	req.Header.Set("Referer", quarkReferer)
	req.Header.Set("Origin", quarkOrigin)
	req.Header.Set("Accept", quarkAccept)
	if body != nil {
		req.Header.Set("Content-Type", "application/json;charset=UTF-8")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	session.MergeSetCookie(resp.Header.Values("Set-Cookie"))
	data, readErr := io.ReadAll(io.LimitReader(resp.Body, quarkMaxBody))
	if readErr != nil {
		return nil, readErr
	}
	return &quarkResponse{status: resp.StatusCode, body: string(data)}, nil
}

// endpoint joins a base URL and a relative path (both slash-normalized).
func (c *QuarkClient) endpoint(base, relative string) string {
	return strings.TrimRight(base, "/") + "/" + strings.TrimLeft(relative, "/")
}

// intValue reads a JSON number (or a numeric string Quark sometimes returns).
func intValue(value any) int {
	switch number := value.(type) {
	case int:
		return number
	case int64:
		return int(number)
	case float64:
		return int(number)
	case json.Number:
		if parsed, err := number.Int64(); err == nil {
			return int(parsed)
		}
	case string:
		var parsed int64
		if _, err := fmt.Sscanf(number, "%d", &parsed); err == nil {
			return int(parsed)
		}
	}
	return 0
}

// int64Value is intValue for byte counts.
func int64Value(value any) int64 {
	switch number := value.(type) {
	case int64:
		return number
	case int:
		return int64(number)
	case float64:
		return int64(number)
	case json.Number:
		parsed, _ := number.Int64()
		return parsed
	case string:
		var parsed int64
		if _, err := fmt.Sscanf(number, "%d", &parsed); err == nil {
			return parsed
		}
	}
	return 0
}
