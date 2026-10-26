package mpv

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFailureMessagesAreActionable(t *testing.T) {
	cases := []struct {
		kind   FailureKind
		status int
		detail string
		want   []string
	}{
		{FailureNetwork, 0, "", []string{"网络"}},
		{FailureUnauthorized, 401, "Failed to open http://x", []string{"401", "权限"}},
		{FailureUnauthorized, 403, "", []string{"403", "直链"}},
		{FailureNotFound, 404, "", []string{"404"}},
		{FailureDecode, 0, "decoder failed", []string{"解码", "decoder failed"}},
		{FailureUnknown, 0, "loading failed", []string{"播放失败", "loading failed"}},
		{FailureServer, 400, "Failed to open https://cdn.example.com/a.flac?token=x", []string{"400", "服务器"}},
		{FailureServer, 503, "", []string{"503", "稍后"}},
		{FailureUnknown, 418, "", []string{"418"}},
	}
	seen := map[string]FailureKind{}
	for _, tc := range cases {
		got := FailureMessage(tc.kind, tc.status, tc.detail)
		if got == "" {
			t.Fatalf("%v: empty message", tc.kind)
		}
		for _, fragment := range tc.want {
			if !strings.Contains(got, fragment) {
				t.Fatalf("%v: message %q does not mention %q", tc.kind, got, fragment)
			}
		}
		if other, duplicate := seen[got]; duplicate && other != tc.kind {
			t.Fatalf("%v and %v share one message %q", tc.kind, other, got)
		}
		seen[got] = tc.kind
	}
}

func TestLocalFailureDistinguishesMissingFromUndecodable(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present.flac")
	if err := os.WriteFile(present, []byte("not really flac"), 0o600); err != nil {
		t.Fatal(err)
	}

	missing := loadFailure(filepath.Join(dir, "gone.flac"), "loading failed", 0, "")
	if missing.Kind != FailureNotFound {
		t.Fatalf("missing file kind = %v, want not-found", missing.Kind)
	}
	if !strings.Contains(missing.Message, "找不到") {
		t.Fatalf("missing file message = %q", missing.Message)
	}

	undecodable := loadFailure(present, "Failed to recognize file format", 0, "")
	if undecodable.Kind != FailureDecode {
		t.Fatalf("present file kind = %v, want decode", undecodable.Kind)
	}

	// A remote URI stays unknown here: only the controller can ask the server.
	remote := loadFailure("https://example.invalid/a.flac", "loading failed", 0, "")
	if remote.Kind != FailureUnknown {
		t.Fatalf("remote kind = %v, want unknown before the probe", remote.Kind)
	}
}

func TestLoadFailureReadsFFmpegsHTTPStatus(t *testing.T) {
	detail := "loading failed: Failed to open https://source.invalid/a.flac"
	cases := []struct {
		name     string
		status   int
		logText  string
		want     FailureKind
		wantCode int
	}{
		{"401 from the log", 0, "ffmpeg: HTTP error 401 Unauthorized", FailureUnauthorized, 401},
		{"403 from the log", 0, "ffmpeg: HTTP error 403 Forbidden", FailureUnauthorized, 403},
		{"412 from the log", 0, "ffmpeg: HTTP error 412 Precondition Failed", FailureUnauthorized, 412},
		{"404", 404, "", FailureNotFound, 404},
		{"400 is the request, not the link", 0, "ffmpeg: HTTP error 400 Bad Request", FailureServer, 400},
		{"503", 503, "", FailureServer, 503},
		{"refused", 0, "tcp: Connection to tcp://127.0.0.1:1 failed: Connection refused", FailureNetwork, 0},
		{"dns", 0, "Failed to resolve host name", FailureNetwork, 0},
		{"decode", 0, "Failed to recognize file format.", FailureDecode, 0},
		{"unknown", 0, "something else", FailureUnknown, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			failure := loadFailure("https://source.invalid/a.flac", detail, tc.status, tc.logText)
			if failure.Kind != tc.want {
				t.Fatalf("kind = %v, want %v", failure.Kind, tc.want)
			}
			if failure.Status != tc.wantCode {
				t.Fatalf("status = %d, want %d", failure.Status, tc.wantCode)
			}
			if failure.Message == "" || failure.Detail != detail {
				t.Fatalf("message=%q detail=%q", failure.Message, failure.Detail)
			}
		})
	}
}

func TestFailureDetailRedactsDirectLinkSecrets(t *testing.T) {
	detail := `loading failed: Failed to open https://user:tok@cdn.example.com/a.flac?sign=abc123&expires=99`
	failure := loadFailure("https://cdn.example.com/a.flac?sign=abc123", detail, 403, "ffmpeg: HTTP error 403 Forbidden")
	if strings.Contains(failure.Detail, "abc123") || strings.Contains(failure.Detail, "user:tok") {
		t.Fatalf("detail leaked credentials: %q", failure.Detail)
	}
	if !strings.Contains(failure.Detail, "cdn.example.com/a.flac") {
		t.Fatalf("detail lost the host: %q", failure.Detail)
	}
	if failure.Status != 403 || failure.Kind != FailureUnauthorized {
		t.Fatalf("kind=%v status=%d", failure.Kind, failure.Status)
	}
}

func TestServerRejectionShowsStatusAndNoURL(t *testing.T) {
	link := "https://dl-pc-sz.drive.quark.cn/x/1/2?sign=SECRETVALUE&expires=1"
	detail := "loading failed: Failed to open " + link
	failure := loadFailure(link, detail, 0, "ffmpeg: https: HTTP error 400 Bad Request")
	if failure.Kind != FailureServer || failure.Status != 400 {
		t.Fatalf("kind=%v status=%d, want server/400", failure.Kind, failure.Status)
	}
	if !strings.Contains(failure.Message, "HTTP 400") {
		t.Fatalf("message %q does not name the status", failure.Message)
	}
	for _, leak := range []string{"SECRETVALUE", "://", "sign="} {
		if strings.Contains(failure.Message, leak) {
			t.Fatalf("message %q leaks %q", failure.Message, leak)
		}
	}
	if !strings.Contains(failure.Detail, "dl-pc-sz.drive.quark.cn") {
		t.Fatalf("detail lost the host: %q", failure.Detail)
	}
	if strings.Contains(failure.Detail, "SECRETVALUE") {
		t.Fatalf("detail leaked the signature: %q", failure.Detail)
	}
}
