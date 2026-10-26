package sources

// WebDAV: PROPFIND directory enumeration and Basic auth for playback, ported
// from app/lib/sources/webdav/{webdav_client,webdav_source_adapter}.dart.
//
// The user-visible error sentences are byte-identical to the Flutter client's,
// including Nutstore's two flow-control variants. Basic credentials travel in
// the Authorization header only — never in the URL — so they cannot leak into
// logs, cache keys or mpv's status line (plan §3.4/§3.5).

import (
	"context"
	"encoding/base64"
	"fmt"
	"github.com/halunhaku/tingyu/client/internal/titleparse"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// propfindBody is webdav_client.dart's request body verbatim.
const propfindBody = `<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname />
    <d:resourcetype />
    <d:getcontentlength />
    <d:getcontenttype />
    <d:getlastmodified />
    <d:getetag />
  </d:prop>
</d:propfind>`

// maxDAVBody bounds one PROPFIND response. A directory listing of a few
// thousand entries is well under this; anything larger is not a listing.
const maxDAVBody = 32 << 20

// WebDAVOptions configure a WebDAV source. Zero values take the Flutter
// client's defaults (throttle 120 ms, depth 8, 5000 files, three retries).
type WebDAVOptions struct {
	RootURL  string
	Username string
	Password string
	MaxDepth int
	MaxFiles int
	Throttle time.Duration
	// HTTP overrides the client (tests inject httptest's).
	HTTP *http.Client
	// Retry overrides the replay policy.
	Retry Retry
	Logf  func(string, ...any)
}

// WebDAV is one configured WebDAV source.
type WebDAV struct {
	sourceID string
	root     *url.URL
	rootPath string
	username string
	password string
	maxDepth int
	maxFiles int
	throttle time.Duration
	http     *http.Client
	retry    Retry
	logf     func(string, ...any)
}

// NewWebDAV validates the root URL and builds the adapter. A malformed URL is
// rejected here, the way WebDavCredentials parses it in its constructor, so the
// form reports it before anything is scanned.
func NewWebDAV(sourceID string, options WebDAVOptions) (*WebDAV, error) {
	rootText := strings.TrimSpace(options.RootURL)
	if rootText == "" {
		return nil, newError(KindOther, "请填写 WebDAV 地址")
	}
	root, err := url.Parse(rootText)
	if err != nil || root.Host == "" || (root.Scheme != "http" && root.Scheme != "https") {
		return nil, newError(KindOther, "WebDAV 地址无效：需要 http(s):// 开头的完整地址")
	}
	if options.MaxDepth <= 0 {
		options.MaxDepth = WebDAVMaxDepth
	}
	if options.MaxFiles <= 0 {
		options.MaxFiles = WebDAVMaxFiles
	}
	if options.Throttle < 0 {
		options.Throttle = 0
	} else if options.Throttle == 0 {
		options.Throttle = 120 * time.Millisecond
	}
	if options.Retry == (Retry{}) {
		options.Retry = DefaultRetry
	}
	if options.HTTP == nil {
		options.HTTP = newHTTPClient(webdavTimeout)
	}
	return &WebDAV{
		sourceID: sourceID,
		root:     root,
		rootPath: normalizePath(root.Path),
		username: options.Username,
		password: options.Password,
		maxDepth: options.MaxDepth,
		maxFiles: options.MaxFiles,
		throttle: options.Throttle,
		http:     options.HTTP,
		retry:    options.Retry,
		logf:     options.Logf,
	}, nil
}

// Kind is sources.KindWebDAV.
func (w *WebDAV) Kind() string { return KindWebDAV }

// SourceID is the music_sources row this adapter belongs to.
func (w *WebDAV) SourceID() string { return w.sourceID }

// RootURL is the normalized root for display.
func (w *WebDAV) RootURL() string { return w.root.String() }

// TestConnection probes the root with Depth: 0. 2xx is success; the same
// status mapping as a scan applies so the form can say what is wrong.
func (w *WebDAV) TestConnection(ctx context.Context) error {
	status, body, err := w.propfind(ctx, w.root, "0")
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return webDAVNetworkError(err)
	}
	return w.statusError(status, body, 0)
}

// Scan walks the tree breadth-first, one PROPFIND per directory, throttled the
// way the Flutter client does (Nutstore throttles bursts). Entries that cannot
// be read are counted as skipped, which keeps the snapshot non-authoritative —
// a transient permission error must not look like a deletion.
func (w *WebDAV) Scan(ctx context.Context, progress Progress) (ScanResult, error) {
	result := ScanResult{Tracks: make([]library.ScannedTrack, 0, 32)}
	type dirJob struct {
		url   *url.URL
		depth int
	}
	queue := []dirJob{{url: w.root, depth: 0}}
	visited := map[string]bool{w.rootPath: true}

	for len(queue) > 0 && len(result.Tracks) < w.maxFiles {
		if ctx.Err() != nil {
			result.Cancelled = true
			break
		}
		job := queue[0]
		queue = queue[1:]
		if job.depth > w.maxDepth {
			continue
		}

		status, body, err := w.propfind(ctx, job.url, "1")
		if err != nil {
			if ctx.Err() != nil {
				result.Cancelled = true
				break
			}
			// The root failing fails the sync; a deeper directory is just
			// skipped (a share with one unreadable subfolder still syncs).
			if job.depth == 0 {
				return result, webDAVNetworkError(err)
			}
			result.Skipped++
			continue
		}
		if statusErr := w.statusError(status, body, job.depth); statusErr != nil {
			// 429/503 is global: retrying deeper folders would only make it
			// worse, so it is reported instead of skipped. Any other failure on
			// a deeper folder is skipped; on the root it fails the sync.
			if job.depth == 0 || KindOf(statusErr) == KindRateLimited {
				return result, statusErr
			}
		}
		if status < 200 || status > 299 {
			result.Skipped++
			continue
		}

		if err := sleepContext(ctx, w.throttle); err != nil {
			result.Cancelled = true
			break
		}
		items, parseErr := parseMultistatus(body)
		if parseErr != nil {
			result.Skipped++
			continue
		}

		currentPath := normalizePath(job.url.Path)
		for _, item := range items {
			if ctx.Err() != nil {
				result.Cancelled = true
				break
			}
			itemURL, ok := resolveHref(w.root, job.url, item.Href)
			if !ok {
				// An href we cannot place could belong anywhere; counting it
				// keeps the snapshot from being treated as complete.
				result.Skipped++
				continue
			}
			itemPath := normalizePath(itemURL.Path)
			if itemPath == currentPath {
				continue
			}
			// Strict boundary: an entry outside the root (a proxy rewriting
			// prefixes, a root URL missing its trailing slash) must not be
			// silently dropped, or a "successful" sync would delete everything.
			if !strings.HasPrefix(itemPath, w.rootPath) {
				result.Skipped++
				continue
			}
			segment := lastPathSegment(itemURL)
			if segment == "" || strings.HasPrefix(segment, ".") ||
				strings.HasPrefix(segment, "@") || strings.HasPrefix(segment, "#") {
				continue
			}

			if item.IsDir {
				if visited[itemPath] {
					continue
				}
				if job.depth+1 > w.maxDepth {
					result.Truncated = true
					if result.TruncationReason == "" {
						result.TruncationReason = fmt.Sprintf("目录层级超过 %d 层", w.maxDepth)
					}
					continue
				}
				visited[itemPath] = true
				queue = append(queue, dirJob{url: directoryURL(itemURL), depth: job.depth + 1})
				continue
			}
			if !supportedExtension(segment) {
				continue
			}
			name := ""
			if item.DisplayName != nil {
				name = strings.TrimSpace(*item.DisplayName)
			}
			if name == "" {
				name = fileNameStem(segment)
			}
			parsed := titleparse.ParseFilename(name)
			album := parsed.Album
			if album == UnknownAlbum {
				album = WebDAVAlbum
			}
			result.Tracks = append(result.Tracks, library.ScannedTrack{
				FilePathOrURL: itemURL.String(),
				Title:         parsed.Title,
				Artist:        parsed.Artist,
				Album:         album,
				FileFormat:    fileExtension(segment),
				FileSize:      item.ContentLen,
			})
			if progress != nil {
				progress(len(result.Tracks), parsed.Title)
			}
			if len(result.Tracks) >= w.maxFiles {
				result.Truncated = true
				if result.TruncationReason == "" {
					result.TruncationReason = fmt.Sprintf("达到 %d 首上限", w.maxFiles)
				}
				break
			}
		}
	}
	return result, nil
}

// Open resolves one library path. The URI is the file's own WebDAV URL (mpv
// fetches the bytes; Go does not); the credential is the per-track header.
func (w *WebDAV) Open(ctx context.Context, filePathOrURL string) (Playable, error) {
	path := strings.TrimSpace(filePathOrURL)
	if path == "" {
		return Playable{}, newError(KindOther, "曲目没有 WebDAV 地址")
	}
	parsed, err := url.Parse(path)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return Playable{}, newError(KindOther, "曲目的 WebDAV 地址无效")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return Playable{}, newError(KindOther, "曲目的 WebDAV 地址不是 http(s)")
	}
	return Playable{
		URI:     path,
		Headers: map[string]string{"Authorization": w.authorization()},
	}, nil
}

// statusError maps a PROPFIND status to the user-visible failure.
func (w *WebDAV) statusError(status int, body []byte, depth int) error {
	switch {
	case status == 401:
		return newError(KindAuth, "%s", WebDAVUnauthorized)
	case status == 403:
		if depth == 0 {
			// Root forbidden = wrong account, app password or root path;
			// re-entering the credential is the action the user needs.
			return newError(KindAuth, "%s", WebDAVForbidden)
		}
		return nil // a deeper directory is skipped by the caller
	case status == 429 || status == 503:
		return webDAVRateLimited(string(body))
	case status < 200 || status > 299:
		return webDAVServerError(status)
	}
	return nil
}

// propfind performs one Depth request with replay, returning the final status
// and body. A transport error is returned; a retryable status is returned as
// the status (the caller has the sentences).
func (w *WebDAV) propfind(ctx context.Context, dir *url.URL, depth string) (int, []byte, error) {
	var status int
	var body []byte
	err := w.retry.Do(ctx, w.logf, func(attempt int) (bool, error) {
		status, body = 0, nil
		requestCtx, cancel := context.WithTimeout(ctx, webdavTimeout)
		defer cancel()
		req, reqErr := http.NewRequestWithContext(requestCtx, "PROPFIND", dir.String(), strings.NewReader(propfindBody))
		if reqErr != nil {
			return false, reqErr
		}
		req.Header.Set("Content-Type", "application/xml; charset=utf-8")
		req.Header.Set("Depth", depth)
		req.Header.Set("Authorization", w.authorization())
		resp, doErr := w.http.Do(req)
		if doErr != nil {
			return true, doErr
		}
		defer resp.Body.Close()
		data, readErr := io.ReadAll(io.LimitReader(resp.Body, maxDAVBody))
		status, body = resp.StatusCode, data
		if readErr != nil {
			return true, readErr
		}
		return RetryableStatus(status), nil
	})
	return status, body, err
}

// authorization is the Basic header value. Basic credentials go in the header
// only (plan §3.5).
func (w *WebDAV) authorization() string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(w.username+":"+w.password))
}

// resolveHref turns an href into an absolute URL: absolute forms are parsed,
// site-absolute forms get the root's scheme and host, and relative forms
// resolve against the directory (with a trailing slash ensured, so a root URL
// written without one still resolves its children correctly).
func resolveHref(root, current *url.URL, href string) (*url.URL, bool) {
	clean := strings.TrimSpace(href)
	if clean == "" {
		return nil, false
	}
	if parsed, err := url.Parse(clean); err == nil && parsed.Scheme != "" {
		return parsed, true
	}
	if strings.HasPrefix(clean, "/") {
		parsed, err := url.Parse(root.Scheme + "://" + root.Host + clean)
		return parsed, err == nil
	}
	base := *current
	if !strings.HasSuffix(base.Path, "/") {
		base.Path += "/"
	}
	resolved, err := base.Parse(clean)
	if err != nil {
		return nil, false
	}
	return resolved, true
}

// directoryURL makes a directory URL end with "/" so relative children resolve
// inside it rather than beside it.
func directoryURL(item *url.URL) *url.URL {
	if strings.HasSuffix(item.Path, "/") {
		return item
	}
	copied := *item
	copied.Path += "/"
	return &copied
}

// normalizePath percent-decodes, trims and wraps a path in slashes, so prefix
// comparisons see `/a/b/` on both sides. Ported from webdav_client.dart, which
// also documents the old root-path `//` bug this fixes.
func normalizePath(path string) string {
	decoded, err := url.PathUnescape(path)
	if err != nil {
		decoded = path
	}
	trimmed := strings.Trim(decoded, "/")
	if trimmed == "" {
		return "/"
	}
	return "/" + trimmed + "/"
}

// lastPathSegment is the final non-empty segment, percent-decoded.
func lastPathSegment(item *url.URL) string {
	segments := strings.Split(strings.Trim(item.EscapedPath(), "/"), "/")
	for i := len(segments) - 1; i >= 0; i-- {
		if segments[i] == "" {
			continue
		}
		decoded, err := url.PathUnescape(segments[i])
		if err != nil {
			return segments[i]
		}
		return decoded
	}
	return ""
}

// fileNameStem drops the last extension (deletingPathExtension).
func fileNameStem(segment string) string {
	if dot := strings.LastIndex(segment, "."); dot > 0 {
		return segment[:dot]
	}
	return segment
}

// sleepContext waits d, returning ctx.Err() when cancelled first.
func sleepContext(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
