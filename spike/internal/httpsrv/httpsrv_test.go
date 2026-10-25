package httpsrv

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testUser = "spike"
	testPass = "s3cr3t-pass"
)

// payload is a deterministic 1000-byte body so offsets are obvious.
func payload() []byte {
	b := make([]byte, 1000)
	for i := range b {
		b[i] = byte('A' + i%26)
	}
	return b
}

type fixture struct {
	t    *testing.T
	srv  *Server
	dir  string
	base string
	log  string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "audio")
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	body := payload()
	if err := os.WriteFile(filepath.Join(dir, "tone.flac"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sub", "nested.flac"), body[:10], 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "曲 目.flac"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "secret.txt"), []byte("TOP-SECRET"), 0o644); err != nil {
		t.Fatal(err)
	}

	logPath := filepath.Join(t.TempDir(), "requests.jsonl")
	srv, err := New(Options{
		Dir:     dir,
		User:    testUser,
		Pass:    testPass,
		LogPath: logPath,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	base, err := srv.Start()
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })
	return &fixture{t: t, srv: srv, dir: dir, base: base, log: logPath}
}

func (f *fixture) do(method, rawURL, rangeHdr string, auth *[2]string) (*http.Response, []byte) {
	f.t.Helper()
	req, err := http.NewRequest(method, rawURL, nil)
	if err != nil {
		f.t.Fatalf("NewRequest(%s %s): %v", method, rawURL, err)
	}
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	}
	req.Header.Set("User-Agent", "spike-test/1.0")
	req.Header.Set("Icy-MetaData", "1")
	if auth != nil {
		req.SetBasicAuth(auth[0], auth[1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		f.t.Fatalf("Do(%s %s): %v", method, rawURL, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		f.t.Fatalf("read body: %v", err)
	}
	return resp, body
}

func goodAuth() *[2]string { return &[2]string{testUser, testPass} }

func TestAuthAndServing(t *testing.T) {
	f := newFixture(t)
	body := payload()
	fileURL := f.srv.URL("tone.flac")

	tests := []struct {
		name       string
		method     string
		url        string
		rangeHdr   string
		auth       *[2]string
		wantStatus int
		wantBody   []byte
		wantCR     string // expected Content-Range, "" if absent
		wantCL     string // expected Content-Length, "" if unchecked
	}{
		{
			name: "no auth 401", method: "GET", url: fileURL,
			wantStatus: 401, wantBody: []byte("unauthorized"),
		},
		{
			name: "wrong password 401", method: "GET", url: fileURL,
			auth: &[2]string{testUser, "nope"}, wantStatus: 401, wantBody: []byte("unauthorized"),
		},
		{
			name: "wrong user 401", method: "GET", url: fileURL,
			auth: &[2]string{"other", testPass}, wantStatus: 401, wantBody: []byte("unauthorized"),
		},
		{
			name: "full 200", method: "GET", url: fileURL, auth: goodAuth(),
			wantStatus: 200, wantBody: body, wantCL: "1000",
		},
		{
			name: "range a-b", method: "GET", url: fileURL, rangeHdr: "bytes=10-19", auth: goodAuth(),
			wantStatus: 206, wantBody: body[10:20], wantCR: "bytes 10-19/1000", wantCL: "10",
		},
		{
			name: "range a-", method: "GET", url: fileURL, rangeHdr: "bytes=990-", auth: goodAuth(),
			wantStatus: 206, wantBody: body[990:], wantCR: "bytes 990-999/1000", wantCL: "10",
		},
		{
			name: "range -n", method: "GET", url: fileURL, rangeHdr: "bytes=-50", auth: goodAuth(),
			wantStatus: 206, wantBody: body[950:], wantCR: "bytes 950-999/1000", wantCL: "50",
		},
		{
			name: "range end past EOF truncates", method: "GET", url: fileURL, rangeHdr: "bytes=900-5000", auth: goodAuth(),
			wantStatus: 206, wantBody: body[900:], wantCR: "bytes 900-999/1000", wantCL: "100",
		},
		{
			name: "range suffix larger than file", method: "GET", url: fileURL, rangeHdr: "bytes=-5000", auth: goodAuth(),
			wantStatus: 206, wantBody: body, wantCR: "bytes 0-999/1000", wantCL: "1000",
		},
		{
			name: "range start == size 416", method: "GET", url: fileURL, rangeHdr: "bytes=1000-", auth: goodAuth(),
			wantStatus: 416, wantCR: "bytes */1000", wantCL: "0",
		},
		{
			name: "range zero suffix 416", method: "GET", url: fileURL, rangeHdr: "bytes=-0", auth: goodAuth(),
			wantStatus: 416, wantCR: "bytes */1000", wantCL: "0",
		},
		{
			name: "garbage range 416", method: "GET", url: fileURL, rangeHdr: "bytes=abc", auth: goodAuth(),
			wantStatus: 416, wantCR: "bytes */1000", wantCL: "0",
		},
		{
			name: "inverted range 416", method: "GET", url: fileURL, rangeHdr: "bytes=20-10", auth: goodAuth(),
			wantStatus: 416, wantCR: "bytes */1000", wantCL: "0",
		},
		{
			name: "HEAD full", method: "HEAD", url: fileURL, auth: goodAuth(),
			wantStatus: 200, wantBody: nil, wantCL: "1000",
		},
		{
			name: "HEAD with range", method: "HEAD", url: fileURL, rangeHdr: "bytes=100-199", auth: goodAuth(),
			wantStatus: 206, wantBody: nil, wantCR: "bytes 100-199/1000", wantCL: "100",
		},
		{
			name: "HEAD without auth", method: "HEAD", url: fileURL,
			wantStatus: 401, wantBody: nil,
		},
		{
			name: "encoded space filename", method: "GET", url: f.srv.URL("曲 目.flac"), auth: goodAuth(),
			wantStatus: 200, wantBody: body, wantCL: "1000",
		},
		{
			name: "subdir file", method: "GET", url: f.srv.URL("sub/nested.flac"), auth: goodAuth(),
			wantStatus: 200, wantBody: body[:10], wantCL: "10",
		},
		{
			name: "unknown file 404", method: "GET", url: f.srv.URL("missing.flac"), auth: goodAuth(),
			wantStatus: 404, wantBody: []byte("not found"),
		},
		{
			name: "POST 405", method: "POST", url: fileURL, auth: goodAuth(),
			wantStatus: 405, wantBody: []byte("method not allowed"),
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp, got := f.do(tc.method, tc.url, tc.rangeHdr, tc.auth)
			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.wantStatus)
			}
			if !bytes.Equal(got, tc.wantBody) {
				t.Fatalf("body = %q (%d bytes), want %q (%d bytes)", got, len(got), tc.wantBody, len(tc.wantBody))
			}
			if tc.wantCR != "" {
				if cr := resp.Header.Get("Content-Range"); cr != tc.wantCR {
					t.Fatalf("Content-Range = %q, want %q", cr, tc.wantCR)
				}
			}
			if tc.wantCL != "" {
				if cl := resp.Header.Get("Content-Length"); cl != tc.wantCL {
					t.Fatalf("Content-Length = %q, want %q", cl, tc.wantCL)
				}
			}
			switch resp.StatusCode {
			case 200, 206:
				if ar := resp.Header.Get("Accept-Ranges"); ar != "bytes" {
					t.Fatalf("Accept-Ranges = %q, want bytes", ar)
				}
			case 401:
				if wa := resp.Header.Get("WWW-Authenticate"); !strings.Contains(wa, `Basic realm="spike"`) {
					t.Fatalf("WWW-Authenticate = %q", wa)
				}
			}
		})
	}
}

func TestPathTraversalRejected(t *testing.T) {
	f := newFixture(t)

	// Build raw request URLs: http.Client will not clean these, but %2e%2e and
	// %2f forms prove the server decodes before resolving.
	rawPaths := []string{
		"/../secret.txt",
		"/../../secret.txt",
		"/%2e%2e/secret.txt",
		"/%2e%2e%2fsecret.txt",
		"/sub/../../secret.txt",
		"/sub/%2e%2e/../secret.txt",
		"/..%2Fsecret.txt",
	}
	for _, p := range rawPaths {
		t.Run(p, func(t *testing.T) {
			req, err := http.NewRequest("GET", f.base+p, nil)
			if err != nil {
				// Some clients refuse to build such URLs; that also satisfies
				// "cannot escape", but log it so the case is not silently lost.
				t.Logf("NewRequest rejected %q: %v", p, err)
				return
			}
			req.SetBasicAuth(testUser, testPass)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("Do: %v", err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != 404 {
				t.Fatalf("%q: status = %d, want 404", p, resp.StatusCode)
			}
			if bytes.Contains(body, []byte("TOP-SECRET")) {
				t.Fatalf("%q: leaked file outside Dir: %q", p, body)
			}
		})
	}
}

func TestRecordsAndJSONL(t *testing.T) {
	f := newFixture(t)
	fileURL := f.srv.URL("tone.flac")

	f.do("GET", fileURL, "", goodAuth())                  // 200, auth ok
	f.do("GET", fileURL, "", nil)                         // 401, absent
	f.do("GET", fileURL, "", &[2]string{testUser, "bad"}) // 401, fail
	f.do("GET", fileURL, "bytes=0-9", goodAuth())         // 206
	if f.srv.BaseURL() == "" {
		t.Fatal("BaseURL empty after Start")
	}

	req, err := http.NewRequest("OPTIONS", fileURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("User-Agent", "spike-test/1.0")
	req.Header.Set("Icy-MetaData", "1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("OPTIONS status = %d, want 204", resp.StatusCode)
	}
	if allow := resp.Header.Get("Allow"); !strings.Contains(allow, "OPTIONS") {
		t.Fatalf("OPTIONS Allow = %q", allow)
	}
	if resp.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("OPTIONS Accept-Ranges = %q", resp.Header.Get("Accept-Ranges"))
	}

	recs := f.srv.Records()
	if len(recs) != 5 {
		t.Fatalf("len(Records()) = %d, want 5", len(recs))
	}

	wantAuth := []string{"ok", "absent", "fail", "ok", "absent"}
	wantStatus := []int{200, 401, 401, 206, 204}
	for i, r := range recs {
		if r.ReqHeaders["Authorization"] != wantAuth[i] {
			t.Fatalf("record %d Authorization = %q, want %q", i, r.ReqHeaders["Authorization"], wantAuth[i])
		}
		if got := r.AuthOK; got != (wantAuth[i] == "ok") {
			t.Fatalf("record %d AuthOK = %v, want %v", i, got, wantAuth[i] == "ok")
		}
		if r.Status != wantStatus[i] {
			t.Fatalf("record %d Status = %d, want %d", i, r.Status, wantStatus[i])
		}
		if r.Method != "GET" && r.Method != "OPTIONS" {
			t.Fatalf("record %d Method = %q", i, r.Method)
		}
		if r.At.IsZero() || r.At.After(time.Now().Add(time.Minute)) {
			t.Fatalf("record %d At = %v", i, r.At)
		}
		if r.ReqHeaders["User-Agent"] != "spike-test/1.0" {
			t.Fatalf("record %d User-Agent = %q", i, r.ReqHeaders["User-Agent"])
		}
		if r.ReqHeaders["Icy-MetaData"] != "1" {
			t.Fatalf("record %d Icy-MetaData = %q", i, r.ReqHeaders["Icy-MetaData"])
		}
	}
	if recs[0].BytesSent != 1000 {
		t.Fatalf("record 0 BytesSent = %d, want 1000", recs[0].BytesSent)
	}
	if recs[3].BytesSent != 10 {
		t.Fatalf("record 3 BytesSent = %d, want 10", recs[3].BytesSent)
	}
	if recs[3].Range != "bytes=0-9" {
		t.Fatalf("record 3 Range = %q", recs[3].Range)
	}
	if recs[1].BytesSent != int64(len("unauthorized")) {
		t.Fatalf("record 1 BytesSent = %d", recs[1].BytesSent)
	}
	if recs[0].Path != "/tone.flac" {
		t.Fatalf("record 0 Path = %q", recs[0].Path)
	}

	// Snapshot must be a copy: mutating it must not affect the server.
	recs[0].ReqHeaders["Authorization"] = "tampered"
	recs[0].Range = "tampered"
	again := f.srv.Records()
	if again[0].ReqHeaders["Authorization"] != "ok" || again[0].Range != "" {
		t.Fatalf("Records() did not return a deep copy: %+v", again[0])
	}

	// Close flushes; the JSONL must have exactly one line per request.
	if err := f.srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	data, err := os.ReadFile(f.log)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if bytes.Contains(data, []byte(testPass)) || bytes.Contains(data, []byte(testUser+":")) {
		t.Fatalf("log leaked credentials: %s", data)
	}
	var lines []Record
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		if len(bytes.TrimSpace(sc.Bytes())) == 0 {
			continue
		}
		var r Record
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			t.Fatalf("bad jsonl line %q: %v", sc.Text(), err)
		}
		lines = append(lines, r)
	}
	if len(lines) != len(recs) {
		t.Fatalf("log lines = %d, want %d\n%s", len(lines), len(recs), data)
	}
	for i, l := range lines {
		if l.Status != recs[i].Status || l.BytesSent != recs[i].BytesSent {
			t.Fatalf("log line %d = %+v, record = %+v", i, l, recs[i])
		}
		if l.ReqHeaders["Authorization"] == "" {
			t.Fatalf("log line %d missing Authorization marker", i)
		}
	}

	// After Close, the port is gone.
	if _, err := http.Get(fileURL); err == nil {
		t.Fatal("request succeeded after Close")
	}
}

func TestConcurrentRanges(t *testing.T) {
	f := newFixture(t)
	fileURL := f.srv.URL("tone.flac")
	body := payload()

	const n = 32
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := range n {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			start := i * 10
			req, err := http.NewRequest("GET", fileURL, nil)
			if err != nil {
				errs <- err
				return
			}
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, start+9))
			req.SetBasicAuth(testUser, testPass)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				errs <- err
				return
			}
			defer resp.Body.Close()
			got, err := io.ReadAll(resp.Body)
			if err != nil {
				errs <- err
				return
			}
			if resp.StatusCode != 206 {
				errs <- fmt.Errorf("status %d", resp.StatusCode)
				return
			}
			if !bytes.Equal(got, body[start:start+10]) {
				errs <- fmt.Errorf("range %d body mismatch", start)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if got := len(f.srv.Records()); got != n {
		t.Fatalf("records = %d, want %d", got, n)
	}
}

func TestNewValidation(t *testing.T) {
	if _, err := New(Options{}); err == nil {
		t.Fatal("New with empty Dir: want error")
	}
	if _, err := New(Options{Dir: t.TempDir(), Pass: "x"}); err == nil {
		t.Fatal("New with Pass but no User: want error")
	}
	if _, err := New(Options{Dir: filepath.Join(t.TempDir(), "nope")}); err == nil {
		t.Fatal("New with missing Dir: want error")
	}
}

func TestNoAuthConfigured(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.flac"), []byte("xyz"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, err := New(Options{Dir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := srv.Start(); err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	resp, err := http.Get(srv.URL("a.flac"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(got) != "xyz" {
		t.Fatalf("status = %d body = %q", resp.StatusCode, got)
	}
	recs := srv.Records()
	if len(recs) != 1 || !recs[0].AuthOK || recs[0].ReqHeaders["Authorization"] != "absent" {
		t.Fatalf("records = %+v", recs)
	}
}

func TestParseRange(t *testing.T) {
	const size = 1000
	cases := []struct {
		hdr       string
		wantStart int64
		wantEnd   int64
		wantKind  rangeKind
	}{
		{"bytes=0-0", 0, 0, rangeSatisfiable},
		{"bytes=0-999", 0, 999, rangeSatisfiable},
		{"bytes=999-", 999, 999, rangeSatisfiable},
		{"bytes=-1", 999, 999, rangeSatisfiable},
		{"bytes=-2000", 0, 999, rangeSatisfiable},
		{"Bytes=1-2", 1, 2, rangeSatisfiable},
		{"bytes=0-1000", 0, 999, rangeSatisfiable},
		{"bytes=1000-", 0, 0, rangeUnsatisfiable},
		{"bytes=5000-6000", 0, 0, rangeUnsatisfiable},
		{"bytes=-0", 0, 0, rangeUnsatisfiable},
		{"bytes=0-1,5-6", 0, 0, rangeMalformed},
		{"bytes=", 0, 0, rangeMalformed},
		{"items=0-1", 0, 0, rangeMalformed},
		{"bytes=x-y", 0, 0, rangeMalformed},
		{"bytes=5-4", 0, 0, rangeMalformed},
	}
	for _, tc := range cases {
		start, end, kind := parseRange(tc.hdr, size)
		if kind != tc.wantKind || (kind == rangeSatisfiable && (start != tc.wantStart || end != tc.wantEnd)) {
			t.Errorf("parseRange(%q) = (%d,%d,%d), want (%d,%d,%d)",
				tc.hdr, start, end, kind, tc.wantStart, tc.wantEnd, tc.wantKind)
		}
	}
	// Empty file: any range is unsatisfiable, not satisfiable.
	if _, _, kind := parseRange("bytes=0-", 0); kind != rangeUnsatisfiable {
		t.Errorf("empty file range kind = %d, want unsatisfiable", kind)
	}
}
