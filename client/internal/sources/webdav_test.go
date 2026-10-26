package sources

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/sourcemock"
)

// newWebDAVMock serves count WAV files across albums under /dav/.
func newWebDAVMock(t *testing.T, count int) (*sourcemock.WebDAV, *httptest.Server) {
	t.Helper()
	files := map[string][]byte{}
	audio := sourcemock.WAV(1, 8000)
	for i := 0; i < count; i++ {
		files[fmt.Sprintf("/dav/专辑%02d/%03d 歌名%03d.wav", i%6, i, i)] = audio
	}
	server := sourcemock.NewWebDAV(files, "user", "app-password")
	httpServer := httptest.NewServer(server)
	t.Cleanup(httpServer.Close)
	return server, httpServer
}

func newTestWebDAV(t *testing.T, httpServer *httptest.Server, sourceID string) *WebDAV {
	t.Helper()
	adapter, err := NewWebDAV(sourceID, WebDAVOptions{
		RootURL:  httpServer.URL + "/dav/",
		Username: "user",
		Password: "app-password",
		HTTP:     httpServer.Client(),
		Retry:    NoRetry,
		Throttle: time.Millisecond,
	})
	if err != nil {
		t.Fatalf("NewWebDAV: %v", err)
	}
	return adapter
}

func TestWebDAVScanReadsTheWholeTree(t *testing.T) {
	server, httpServer := newWebDAVMock(t, 120)
	// A non-audio file and a hidden directory must be ignored without turning
	// the snapshot non-authoritative.
	server.SetMode(sourcemock.ModeAllow)
	adapter := newTestWebDAV(t, httpServer, "src-webdav")

	var progressCalls int
	result, err := adapter.Scan(context.Background(), func(done int, name string) {
		progressCalls++
		if name == "" {
			t.Errorf("progress %d has no title", done)
		}
	})
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(result.Tracks) != 120 {
		t.Fatalf("tracks = %d, want 120", len(result.Tracks))
	}
	if !result.Authoritative() {
		t.Fatalf("scan is not authoritative: skipped=%d cancelled=%v truncated=%v reason=%q",
			result.Skipped, result.Cancelled, result.Truncated, result.TruncationReason)
	}
	if progressCalls != 120 {
		t.Fatalf("progress calls = %d, want 120", progressCalls)
	}
	track := result.Tracks[0]
	if !strings.HasPrefix(track.FilePathOrURL, httpServer.URL+"/dav/") {
		t.Fatalf("path = %q", track.FilePathOrURL)
	}
	if track.FileFormat != "wav" || track.FileSize == 0 {
		t.Fatalf("file facts = %+v", track)
	}
	if track.Album != "专辑00" && track.Album != WebDAVAlbum {
		t.Fatalf("album = %q", track.Album)
	}
	if track.Title == "" || track.Artist == "" {
		t.Fatalf("parsed metadata = %+v", track)
	}
}

func TestWebDAVScanReportsRejectedCredentials(t *testing.T) {
	server, httpServer := newWebDAVMock(t, 2)
	adapter := newTestWebDAV(t, httpServer, "src-webdav")

	server.SetMode(sourcemock.ModeUnauthorized)
	if _, err := adapter.Scan(context.Background(), nil); !IsAuth(err) || err.Error() != WebDAVUnauthorized {
		t.Fatalf("401 scan error = %v, want the auth sentence", err)
	}

	server.SetMode(sourcemock.ModeForbiddenRoot)
	if _, err := adapter.Scan(context.Background(), nil); !IsAuth(err) || err.Error() != WebDAVForbidden {
		t.Fatalf("403 root error = %v, want the forbidden sentence", err)
	}

	server.SetMode(sourcemock.ModeRateLimited)
	_, err := adapter.Scan(context.Background(), nil)
	if KindOf(err) != KindRateLimited || err.Error() != WebDAVBlocked {
		t.Fatalf("503 error = %v, want Nutstore's blocked sentence", err)
	}
}

func TestWebDAVScanStopsOnCancel(t *testing.T) {
	_, httpServer := newWebDAVMock(t, 40)
	adapter := newTestWebDAV(t, httpServer, "src-webdav")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result, err := adapter.Scan(ctx, func(done int, _ string) {
		if done == 5 {
			cancel()
		}
	})
	if err != nil {
		t.Fatalf("cancelled scan returned an error: %v", err)
	}
	if !result.Cancelled {
		t.Fatal("scan was not marked cancelled")
	}
	if result.Authoritative() {
		t.Fatal("a cancelled scan must not be authoritative")
	}
	if len(result.Tracks) == 0 || len(result.Tracks) >= 40 {
		t.Fatalf("cancelled scan kept %d tracks", len(result.Tracks))
	}
}

func TestWebDAVOpenSendsBasicAuthAndTheServerSeesRange(t *testing.T) {
	_, httpServer := newWebDAVMock(t, 1)
	adapter := newTestWebDAV(t, httpServer, "src-webdav")
	playable, err := adapter.Open(context.Background(), httpServer.URL+"/dav/专辑00/000 歌名000.wav")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if playable.URI != httpServer.URL+"/dav/专辑00/000 歌名000.wav" {
		t.Fatalf("URI = %q", playable.URI)
	}
	if !strings.HasPrefix(playable.Headers["Authorization"], "Basic ") {
		t.Fatalf("headers = %+v", playable.Headers)
	}
	// The engine is what sends Range; here we prove the header the adapter
	// exports is the one the server accepts, and that a ranged GET succeeds.
	request, err := http.NewRequest(http.MethodGet, playable.URI, nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	for name, value := range playable.Headers {
		request.Header.Set(name, value)
	}
	request.Header.Set("Range", "bytes=100-199")
	response, err := httpServer.Client().Do(request)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusPartialContent {
		t.Fatalf("status = %d, want 206", response.StatusCode)
	}
}

func TestWebDAVRejectsMalformedRootURL(t *testing.T) {
	for _, root := range []string{"", "not a url", "ftp://example.com/dav", "https:///dav"} {
		if _, err := NewWebDAV("src", WebDAVOptions{RootURL: root}); err == nil {
			t.Errorf("NewWebDAV(%q) accepted an invalid root", root)
		}
	}
}

func TestNormalizePathAndHrefResolution(t *testing.T) {
	if got := normalizePath("/dav/专辑/"); got != "/dav/专辑/" {
		t.Fatalf("normalize = %q", got)
	}
	if got := normalizePath("/"); got != "/" {
		t.Fatalf("root normalize = %q", got)
	}
	root := mustURL(t, "https://dav.example.com/dav/")
	current := mustURL(t, "https://dav.example.com/dav/album/")

	absolute, ok := resolveHref(root, current, "https://other.example.com/x.wav")
	if !ok || absolute.Host != "other.example.com" {
		t.Fatalf("absolute href = %v %v", absolute, ok)
	}
	siteAbsolute, ok := resolveHref(root, current, "/dav/b.wav")
	if !ok || siteAbsolute.String() != "https://dav.example.com/dav/b.wav" {
		t.Fatalf("site-absolute href = %v %v", siteAbsolute, ok)
	}
	relative, ok := resolveHref(root, current, "c.wav")
	if !ok || relative.String() != "https://dav.example.com/dav/album/c.wav" {
		t.Fatalf("relative href = %v %v", relative, ok)
	}
	// A directory URL without a trailing slash still resolves children inside
	// the directory rather than beside it.
	noSlash := mustURL(t, "https://dav.example.com/dav/album")
	inside, ok := resolveHref(root, noSlash, "c.wav")
	if !ok || inside.String() != "https://dav.example.com/dav/album/c.wav" {
		t.Fatalf("href against slashless dir = %v %v", inside, ok)
	}
	if _, ok := resolveHref(root, current, "   "); ok {
		t.Fatal("blank href resolved")
	}
}

func TestParseMultistatusKeepsLastValuesAndDropsEmptyHrefs(t *testing.T) {
	body := `<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/a/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/a/x.wav</d:href>
    <d:propstat><d:prop><d:getcontentlength>10</d:getcontentlength></d:prop></d:propstat>
    <d:propstat><d:prop>
      <d:getcontentlength>20</d:getcontentlength>
      <d:getetag>"abc"</d:getetag>
      <d:displayname> X </d:displayname>
    </d:prop></d:propstat>
  </d:response>
  <d:response><d:href>  </d:href></d:response>
</d:multistatus>`
	items, err := parseMultistatus([]byte(body))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("items = %d, want 2", len(items))
	}
	if !items[0].IsDir {
		t.Fatal("collection not recognized as a directory")
	}
	if items[1].ContentLen != 20 || items[1].ETag != "abc" {
		t.Fatalf("last-wins failed: %+v", items[1])
	}
	if items[1].DisplayName == nil || *items[1].DisplayName != "X" {
		t.Fatalf("display name = %v", items[1].DisplayName)
	}
	if _, err := parseMultistatus([]byte("<html>not a listing</html>")); err == nil {
		t.Fatal("a non-multistatus body parsed as a listing")
	}
}

func mustURL(t *testing.T, text string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(text)
	if err != nil {
		t.Fatalf("parse %q: %v", text, err)
	}
	return parsed
}
