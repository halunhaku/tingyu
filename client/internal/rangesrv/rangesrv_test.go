package rangesrv

import (
	"encoding/base64"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	root := t.TempDir()
	content := []byte("0123456789abcdefghij")
	if err := os.WriteFile(filepath.Join(root, "tone.flac"), content, 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(Options{Root: root, User: "user", Password: "secret", LogPath: filepath.Join(root, "requests.jsonl")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	return server, string(content)
}

func do(t *testing.T, method, uri string, headers map[string]string) (*http.Response, string) {
	t.Helper()
	request, err := http.NewRequest(method, uri, nil)
	if err != nil {
		t.Fatal(err)
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	return response, string(body)
}

func TestRequiresBasicAuthAndRecordsTheRequest(t *testing.T) {
	server, content := newTestServer(t)
	url := server.URL("tone.flac")

	response, _ := do(t, http.MethodGet, url, nil)
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status without auth = %d, want 401", response.StatusCode)
	}

	response, body := do(t, http.MethodGet, url, map[string]string{"Authorization": basicAuth("user", "secret")})
	if response.StatusCode != http.StatusOK || body != content {
		t.Fatalf("status=%d body=%q, want 200 and the whole file", response.StatusCode, body)
	}

	records := server.Records()
	if len(records) != 2 {
		t.Fatalf("records = %d, want 2", len(records))
	}
	if records[0].Authorized || records[0].Status != http.StatusUnauthorized {
		t.Fatalf("first record = %+v, want unauthorized 401", records[0])
	}
	if !records[1].Authorized || records[1].Status != http.StatusOK || records[1].Bytes != int64(len(content)) {
		t.Fatalf("second record = %+v", records[1])
	}
}

func TestRangeRequests(t *testing.T) {
	server, _ := newTestServer(t)
	url := server.URL("tone.flac")
	auth := map[string]string{"Authorization": basicAuth("user", "secret")}

	cases := []struct {
		rangeHeader  string
		status       int
		body         string
		contentRange string
	}{
		{"bytes=10-13", http.StatusPartialContent, "abcd", "bytes 10-13/20"},
		{"bytes=10-", http.StatusPartialContent, "abcdefghij", "bytes 10-19/20"},
		{"bytes=-4", http.StatusPartialContent, "ghij", "bytes 16-19/20"},
		{"bytes=25-", http.StatusRequestedRangeNotSatisfiable, "range not satisfiable\n", "bytes */20"},
	}
	for _, tc := range cases {
		headers := map[string]string{"Authorization": auth["Authorization"], "Range": tc.rangeHeader}
		response, body := do(t, http.MethodGet, url, headers)
		if response.StatusCode != tc.status {
			t.Fatalf("%s: status = %d, want %d", tc.rangeHeader, response.StatusCode, tc.status)
		}
		if tc.status == http.StatusPartialContent && body != tc.body {
			t.Fatalf("%s: body = %q, want %q", tc.rangeHeader, body, tc.body)
		}
		if got := response.Header.Get("Content-Range"); got != tc.contentRange {
			t.Fatalf("%s: Content-Range = %q, want %q", tc.rangeHeader, got, tc.contentRange)
		}
	}
	if got := server.Records(); len(got) != len(cases) || got[0].Range != "bytes=10-13" {
		t.Fatalf("records did not capture Range: %+v", got)
	}
}

func TestModesRejectLikeARealSource(t *testing.T) {
	server, _ := newTestServer(t)
	url := server.URL("tone.flac")
	auth := map[string]string{"Authorization": basicAuth("user", "secret")}

	server.SetMode(ModeForbidden)
	if response, _ := do(t, http.MethodGet, url, auth); response.StatusCode != http.StatusForbidden {
		t.Fatalf("forbidden mode status = %d, want 403", response.StatusCode)
	}
	server.SetMode(ModeUnauthorized)
	if response, _ := do(t, http.MethodGet, url, auth); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized mode status = %d, want 401", response.StatusCode)
	}

	server.SetMode(ModeChunked)
	response, body := do(t, http.MethodGet, url, map[string]string{"Authorization": auth["Authorization"], "Range": "bytes=0-3"})
	if response.StatusCode != http.StatusOK || body != "0123456789abcdefghij" {
		t.Fatalf("chunked mode status=%d body=%q", response.StatusCode, body)
	}
	if response.Header.Get("Content-Length") != "" {
		t.Fatalf("chunked mode sent Content-Length %q", response.Header.Get("Content-Length"))
	}
}

func TestOfflineThenRestartKeepsTheAddress(t *testing.T) {
	server, _ := newTestServer(t)
	url := server.URL("tone.flac")
	auth := map[string]string{"Authorization": basicAuth("user", "secret")}

	if err := server.Stop(); err != nil {
		t.Fatal(err)
	}
	if _, err := http.Get(url); err == nil {
		t.Fatal("request to a stopped server succeeded; the outage is not simulated")
	}
	if _, err := server.Restart(); err != nil {
		t.Fatal(err)
	}
	if response, _ := do(t, http.MethodGet, url, auth); response.StatusCode != http.StatusOK {
		t.Fatalf("after restart status = %d", response.StatusCode)
	}
}

func TestTraversalAndMissingFilesAre404(t *testing.T) {
	server, _ := newTestServer(t)
	auth := map[string]string{"Authorization": basicAuth("user", "secret")}
	for _, path := range []string{"../secret.txt", "missing.flac"} {
		url := strings.TrimSuffix(server.BaseURL(), "/") + "/" + path
		if response, _ := do(t, http.MethodGet, url, auth); response.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: status = %d, want 404", path, response.StatusCode)
		}
	}
}

func TestRequireRangeRejectsAPlainGet(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "tone.flac"), []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := New(Options{Root: root, User: "user", Password: "secret", RequireRange: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	url := server.URL("tone.flac")
	auth := map[string]string{"Authorization": basicAuth("user", "secret")}

	if response, _ := do(t, http.MethodGet, url, auth); response.StatusCode != http.StatusBadRequest {
		t.Fatalf("plain GET status = %d, want 400", response.StatusCode)
	}
	withRange := map[string]string{"Authorization": auth["Authorization"], "Range": "bytes=0-"}
	if response, _ := do(t, http.MethodGet, url, withRange); response.StatusCode != http.StatusPartialContent {
		t.Fatalf("ranged GET status = %d, want 206", response.StatusCode)
	}
}

func basicAuth(user, password string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+password))
}
