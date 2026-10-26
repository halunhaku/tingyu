// Package metadata is the M5 enrichment pipeline: four public metadata sources
// (QQ 音乐, 网易云音乐, iTunes, LRCLIB), OpenCC traditional→simplified lyrics,
// and an optional OpenAI-compatible AI fallback for file names no source can
// resolve.
//
// It is a translation of app/lib/sources/scraper/* (plan §2.4 #32/#33): the
// same search→detail→lyrics steps, the same placeholder rules, the same
// best-effort contract. Nothing here touches the database or the filesystem;
// internal/enrich writes the results back.
//
// Every source is optional at construction time. A source that needs an API
// key (only the AI does) is configured at run time and skipped silently when
// it is missing — plan §6 M5: "若某个源需要密钥/账号，做成可配置并在缺失时静默跳过".
package metadata

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Placeholders the library schema uses for unknown metadata (merge.go).
const (
	UnknownArtist = "未知艺术家"
	UnknownAlbum  = "未知专辑"
	WebDAVAlbum   = "WebDAV 曲库"
	QuarkAlbum    = "夸克曲库"
)

// DefaultTimeout bounds one upstream request. The Flutter providers use 8–15 s.
const DefaultTimeout = 12 * time.Second

// maxBody bounds one JSON response.
const maxBody = 4 << 20

// Candidate is one search hit, in a shape the sources share.
type Candidate struct {
	Provider string
	Title    string
	Artist   string
	Album    string
	CoverURL string
	SourceID string
	Duration time.Duration
}

// MatchesTitle is the old client's loose rule: either title contains the
// other. "夜曲" matches "夜曲 (Live)" and vice versa.
func (c Candidate) MatchesTitle(other string) bool {
	candidate := strings.ToLower(strings.TrimSpace(c.Title))
	target := strings.ToLower(strings.TrimSpace(other))
	if candidate == "" || target == "" {
		return false
	}
	return strings.Contains(candidate, target) || strings.Contains(target, candidate)
}

// SearchQuery is what the user (or the library) is looking for.
type SearchQuery struct {
	Title  string
	Artist string
	Album  string
}

// LyricsQuery is the LRCLIB-style lookup: title, artist, album and duration.
type LyricsQuery struct {
	Title    string
	Artist   string
	Album    string
	Duration time.Duration
}

// Searcher finds candidate tracks.
type Searcher interface {
	Name() string
	Search(ctx context.Context, query SearchQuery, limit int) ([]Candidate, error)
}

// LyricsProvider fetches an LRC/plain lyric document.
type LyricsProvider interface {
	Name() string
	Lyrics(ctx context.Context, query LyricsQuery, candidate *Candidate) (string, error)
}

// CoverLookup finds a cover URL for an album (iTunes' API is album-shaped).
type CoverLookup interface {
	Name() string
	CoverURL(ctx context.Context, query SearchQuery) (string, error)
}

// UpstreamError describes one failed request. Network marks a failure that
// never reached the server — what the UI calls "offline" and swallows.
type UpstreamError struct {
	Provider string
	URL      string
	Status   int
	Network  bool
	Err      error
}

func (e *UpstreamError) Error() string {
	if e.Status != 0 {
		return fmt.Sprintf("%s: %s: HTTP %d", e.Provider, e.URL, e.Status)
	}
	if e.Err != nil {
		return fmt.Sprintf("%s: %s: %v", e.Provider, e.URL, e.Err)
	}
	return fmt.Sprintf("%s: %s: failed", e.Provider, e.URL)
}

func (e *UpstreamError) Unwrap() error { return e.Err }

// IsNetwork reports whether err is a failure that never reached the upstream.
func IsNetwork(err error) bool {
	var upstream *UpstreamError
	if errors.As(err, &upstream) {
		return upstream.Network
	}
	return false
}

// HTTP is the shared client of the sources. A nil Client uses a 12 s default.
type HTTP struct {
	Client *http.Client
	UA     string
}

func (h *HTTP) client() *http.Client {
	if h != nil && h.Client != nil {
		return h.Client
	}
	return &http.Client{Timeout: DefaultTimeout}
}

func (h *HTTP) userAgent() string {
	if h != nil && strings.TrimSpace(h.UA) != "" {
		return h.UA
	}
	return DefaultUserAgent
}

// DefaultUserAgent identifies the client to LRCLIB, which asks for one.
const DefaultUserAgent = "Tingyu/1.0 (https://github.com/halunhaku/tingyu)"

// getJSON fetches a URL and decodes the body as a JSON object. It never fails
// silently: the caller decides whether the failure is worth reporting, and the
// error carries whether it was a network failure.
func (h *HTTP) getJSON(ctx context.Context, provider, endpoint string, params url.Values, headers map[string]string) (map[string]any, error) {
	target := endpoint
	if len(params) > 0 {
		target += "?" + params.Encode()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Err: err}
	}
	request.Header.Set("User-Agent", h.userAgent())
	request.Header.Set("Accept", "application/json")
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response, err := h.client().Do(request)
	if err != nil {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Network: true, Err: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBody))
	if err != nil {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Network: true, Err: err}
	}
	if response.StatusCode == http.StatusNotFound {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Status: response.StatusCode}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Status: response.StatusCode}
	}
	// Upstream content types are unreliable (QQ sends application/x-javascript,
	// Netease text/plain, iTunes text/javascript), so the body is parsed rather
	// than trusted.
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, &UpstreamError{Provider: provider, URL: endpoint, Err: fmt.Errorf("not JSON: %w", err)}
	}
	return decoded, nil
}

// buildSearchQuery is buildMetadataSearchQuery: placeholders never reach the
// upstream, because a remote source's album is often "夸克曲库".
func buildSearchQuery(query SearchQuery) string {
	parts := make([]string, 0, 3)
	title := strings.TrimSpace(query.Title)
	if title == "" {
		return ""
	}
	parts = append(parts, title)
	if artist := strings.TrimSpace(query.Artist); artist != "" && artist != UnknownArtist {
		parts = append(parts, artist)
	}
	if album := strings.TrimSpace(query.Album); album != "" && !isPlaceholderAlbum(album) {
		parts = append(parts, album)
	}
	return strings.Join(parts, " ")
}

func isPlaceholderAlbum(album string) bool {
	switch strings.TrimSpace(album) {
	case "", UnknownAlbum, WebDAVAlbum, QuarkAlbum:
		return true
	}
	return false
}

// IsPlaceholderArtist reports an artist the library could not read.
func IsPlaceholderArtist(artist string) bool {
	value := strings.TrimSpace(artist)
	return value == "" || value == UnknownArtist
}

// IsPlaceholderAlbum reports an album the library could not read, including the
// two source placeholders.
func IsPlaceholderAlbum(album string) bool { return isPlaceholderAlbum(album) }

// mapValue reads a nested object, tolerating the "wrong" type upstreams send.
func mapValue(value any) map[string]any {
	if object, ok := value.(map[string]any); ok {
		return object
	}
	return nil
}

// listValue reads a nested array.
func listValue(value any) []any {
	if list, ok := value.([]any); ok {
		return list
	}
	return nil
}

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return strings.TrimSpace(text)
	}
	return ""
}

func numberValue(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case int:
		return float64(typed)
	case json.Number:
		if parsed, err := typed.Float64(); err == nil {
			return parsed
		}
	}
	return 0
}
