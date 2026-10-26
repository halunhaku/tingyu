package sourcemock

// Quark Drive server: the endpoint shapes, status codes, Set-Cookie flow,
// pagination and direct-link expiry the production client was written against
// (and the Flutter client before it). Every host the app talks to — CAS, pan,
// drive-pc, CDN — is served from one httptest server, so no real account or
// network is ever involved.
//
// The response shapes are copied from the Dart parsers, not from official
// documentation; see the package comment and the M3 record's "what was not
// verified against the real service" section.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"
)

// QuarkEntry is one file or folder of the mock drive.
type QuarkEntry struct {
	FID    string `json:"fid"`
	Name   string `json:"file_name"`
	Folder bool   `json:"-"`
	Size   int64  `json:"size"`
	Format string `json:"format_type,omitempty"`
}

// mockQRToken is the QR login token the mock hands out.
const mockQRToken = "qr-token-1"

// QuarkOptions configure the mock.
type QuarkOptions struct {
	// Entries maps a folder fid ("0" is the root) to its children.
	Entries map[string][]QuarkEntry
	// Media maps a file fid to its bytes.
	Media map[string][]byte
	// Session is the initial `__pus` value; empty means logged out.
	Session string
	// ByteRate throttles media responses, in bytes per second (0 = no limit).
	ByteRate int
}

// QuarkRequest is one recorded request.
type QuarkRequest struct {
	At     time.Time `json:"at"`
	Method string    `json:"method"`
	Path   string    `json:"path"`
	Query  string    `json:"query,omitempty"`
	Range  string    `json:"range,omitempty"`
	// Cookie is the Cookie header's presence only; the value is a credential.
	Cookie    bool   `json:"cookie"`
	UserAgent string `json:"user_agent,omitempty"`
	Status    int    `json:"status"`
	Bytes     int64  `json:"bytes,omitempty"`
}

// Quark is the mock server.
type Quark struct {
	mu       sync.Mutex
	entries  map[string][]QuarkEntry
	media    map[string][]byte
	session  string
	qrToken  string
	qrTicket string
	qrScan   bool
	qrCancel bool
	link     string
	linkSeq  int
	records  []QuarkRequest
	issues   int // download-link issuances
	baseURL  string
	// malformedSort answers a listing without `data.list`, the shape that
	// must be read as "unreadable", never as "empty".
	malformedSort bool
	// totalLie reports more entries than the pages return.
	totalLie bool
	byteRate int
}

// NewQuark builds the mock. The caller mounts it on an httptest server and
// then calls SetBaseURL with that server's URL.
func NewQuark(options QuarkOptions) *Quark {
	server := &Quark{
		entries:  map[string][]QuarkEntry{},
		media:    map[string][]byte{},
		session:  options.Session,
		byteRate: options.ByteRate,
	}
	for fid, children := range options.Entries {
		server.entries[fid] = append([]QuarkEntry(nil), children...)
	}
	for fid, data := range options.Media {
		server.media[fid] = data
	}
	if server.session == "" {
		server.session = "mock-session"
	}
	return server
}

// SetBaseURL is the httptest server's URL, used to build direct links.
func (s *Quark) SetBaseURL(base string) {
	s.mu.Lock()
	s.baseURL = strings.TrimRight(base, "/")
	s.mu.Unlock()
}

// ExpireSession invalidates the current Cookie: the API then answers 401 and
// the CDN 403, which is what a revoked login looks like.
func (s *Quark) ExpireSession() {
	s.mu.Lock()
	s.session = ""
	s.mu.Unlock()
}

// RestoreSession makes the Cookie `value` valid again.
func (s *Quark) RestoreSession(value string) {
	s.mu.Lock()
	s.session = value
	s.mu.Unlock()
}

// Session returns the currently valid `__pus` value.
func (s *Quark) Session() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.session
}

// ConfirmScan marks the QR code as scanned by the phone.
func (s *Quark) ConfirmScan() {
	s.mu.Lock()
	s.qrScan = true
	s.mu.Unlock()
}

// CancelLogin makes the next poll report that the phone cancelled.
func (s *Quark) CancelLogin() {
	s.mu.Lock()
	s.qrCancel = true
	s.mu.Unlock()
}

// ExpireLink invalidates every issued direct link. The next download request
// mints a new token, which is how a real link rotates.
func (s *Quark) ExpireLink() {
	s.mu.Lock()
	s.link = ""
	s.mu.Unlock()
}

// SetMalformedSort makes the next listings answer without a list.
func (s *Quark) SetMalformedSort(broken bool) {
	s.mu.Lock()
	s.malformedSort = broken
	s.mu.Unlock()
}

// SetTotalLie makes the next listings report a larger total than they return.
func (s *Quark) SetTotalLie(lying bool) {
	s.mu.Lock()
	s.totalLie = lying
	s.mu.Unlock()
}

// CurrentLinkToken is the token of the most recently minted direct link (the
// only one the CDN accepts).
func (s *Quark) CurrentLinkToken() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.link
}

// LinkIssues counts how many direct links were minted.
func (s *Quark) LinkIssues() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.issues
}

// Records returns the request log.
func (s *Quark) Records() []QuarkRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]QuarkRequest(nil), s.records...)
}

// ResetRecords clears the log.
func (s *Quark) ResetRecords() {
	s.mu.Lock()
	s.records = nil
	s.mu.Unlock()
}

// ServeHTTP routes every mock endpoint.
func (s *Quark) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	recorder := &statusWriter{ResponseWriter: w, status: http.StatusOK}
	route := r.URL.Path
	switch {
	case route == "/cas/ajax/getTokenForQrcodeLogin":
		s.token(recorder, r)
	case route == "/cas/ajax/getServiceTicketByQrcodeToken":
		s.poll(recorder, r)
	case route == "/pan/account/info":
		s.accountInfo(recorder, r)
	case route == "/pan/home":
		s.home(recorder, r)
	case route == "/pan/" || route == "/pan":
		s.panRoot(recorder, r)
	case route == "/api/1/clouddrive/file/sort" || route == "/cdn/1/clouddrive/file/sort":
		s.sort(recorder, r)
	case route == "/api/1/clouddrive/file/download" || route == "/cdn/1/clouddrive/file/download":
		s.download(recorder, r)
	case strings.HasPrefix(route, "/cdn/download/"):
		s.serveMedia(recorder, r)
	default:
		http.NotFound(recorder, r)
	}
}

// --- QR login -------------------------------------------------------

func (s *Quark) token(w *statusWriter, r *http.Request) {
	s.mu.Lock()
	s.qrToken = mockQRToken
	s.qrTicket = "ticket-1"
	s.qrScan = false
	s.qrCancel = false
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "__cas", Value: "cas-cookie", Path: "/"})
	writeJSON(w, http.StatusOK, map[string]any{
		"status": 2000000,
		"data":   map[string]any{"members": map[string]any{"token": mockQRToken}},
	})
}

func (s *Quark) poll(w *statusWriter, r *http.Request) {
	if token := r.URL.Query().Get("token"); token != mockQRToken {
		writeJSON(w, http.StatusOK, map[string]any{"status": 50004002, "message": "expired"})
		return
	}
	s.mu.Lock()
	scanned, cancelled := s.qrScan, s.qrCancel
	s.mu.Unlock()
	switch {
	case cancelled:
		writeJSON(w, http.StatusOK, map[string]any{"status": 50004004})
	case !scanned:
		writeJSON(w, http.StatusOK, map[string]any{"status": 50004001})
	default:
		writeJSON(w, http.StatusOK, map[string]any{
			"status": 2000000,
			"data":   map[string]any{"members": map[string]any{"service_ticket": "ticket-1"}},
		})
	}
}

func (s *Quark) accountInfo(w *statusWriter, r *http.Request) {
	if r.URL.Query().Get("st") != "ticket-1" {
		http.Redirect(w, r, "/pan/login", http.StatusFound)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "rotated-puus", Path: "/"})
	http.Redirect(w, r, "/pan/home", http.StatusFound)
}

func (s *Quark) home(w *statusWriter, r *http.Request) {
	s.mu.Lock()
	// A completed login establishes a session: this is what a re-login after an
	// expired cookie looks like (the server hands out a new valid one).
	if s.session == "" {
		s.session = "relogin-session"
	}
	session := s.session
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "__pus", Value: session, Path: "/"})
	http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "rotated-puus-2", Path: "/"})
	http.SetCookie(w, &http.Cookie{Name: "push_vurl", Value: "noise", Path: "/"})
	_, _ = io.WriteString(w, "<html><body>pan home</body></html>")
}

func (s *Quark) panRoot(w *statusWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: "__puus", Value: "pan-puus", Path: "/"})
	_, _ = io.WriteString(w, "<html><body>pan</body></html>")
}

// --- drive API ------------------------------------------------------

// authed checks the Cookie and writes the expired response when it is not.
func (s *Quark) authed(w *statusWriter, r *http.Request) bool {
	s.mu.Lock()
	want := s.session
	s.mu.Unlock()
	cookie := r.Header.Get("Cookie")
	for _, part := range strings.Split(cookie, ";") {
		name, value, found := strings.Cut(strings.TrimSpace(part), "=")
		if found && name == "__pus" && want != "" && value == want {
			return true
		}
	}
	writeJSON(w, http.StatusUnauthorized, map[string]any{
		"status": 401, "code": 31001, "message": "login required",
	})
	return false
}

func (s *Quark) sort(w *statusWriter, r *http.Request) {
	request := QuarkRequest{At: time.Now(), Method: r.Method, Path: r.URL.Path,
		Query: r.URL.RawQuery, Cookie: r.Header.Get("Cookie") != "", UserAgent: r.Header.Get("User-Agent")}
	defer func() {
		request.Status = w.status
		s.record(request)
	}()
	if !s.authed(w, r) {
		return
	}
	fid := r.URL.Query().Get("pdir_fid")
	if fid == "" {
		fid = "0"
	}
	page := 1
	if parsed, err := strconv.Atoi(r.URL.Query().Get("_page")); err == nil && parsed > 0 {
		page = parsed
	}
	size := 100
	if parsed, err := strconv.Atoi(r.URL.Query().Get("_size")); err == nil && parsed > 0 {
		size = parsed
	}
	s.mu.Lock()
	all := append([]QuarkEntry(nil), s.entries[fid]...)
	malformed, totalLie := s.malformedSort, s.totalLie
	s.mu.Unlock()
	if malformed {
		writeJSON(w, http.StatusOK, map[string]any{"status": 200, "data": map[string]any{}})
		return
	}
	start := (page - 1) * size
	if start > len(all) {
		start = len(all)
	}
	end := start + size
	if end > len(all) {
		end = len(all)
	}
	list := make([]map[string]any, 0, end-start)
	for _, entry := range all[start:end] {
		fileType := 1
		if entry.Folder {
			fileType = 0
		}
		format := entry.Format
		if format == "" {
			if entry.Folder {
				format = "dir"
			} else {
				format = "file"
			}
		}
		list = append(list, map[string]any{
			"fid":         entry.FID,
			"file_name":   entry.Name,
			"file_type":   fileType,
			"size":        entry.Size,
			"format_type": format,
		})
	}
	total := len(all)
	if totalLie {
		total += 50
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": 200,
		"code":   0,
		"data":   map[string]any{"list": list, "total": total},
	})
}

func (s *Quark) download(w *statusWriter, r *http.Request) {
	request := QuarkRequest{At: time.Now(), Method: r.Method, Path: r.URL.Path,
		Query: r.URL.RawQuery, Cookie: r.Header.Get("Cookie") != "", UserAgent: r.Header.Get("User-Agent")}
	defer func() {
		request.Status = w.status
		s.record(request)
	}()
	if !s.authed(w, r) {
		return
	}
	var body struct {
		FIDs []string `json:"fids"`
	}
	data, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	if err := json.Unmarshal(data, &body); err != nil || len(body.FIDs) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"status": 400, "message": "fids required"})
		return
	}
	fid := body.FIDs[0]
	s.mu.Lock()
	_, known := s.media[fid]
	base := s.baseURL
	s.linkSeq++
	s.link = fmt.Sprintf("link-%d", s.linkSeq)
	link := s.link
	if known {
		s.issues++
	}
	s.mu.Unlock()
	if !known {
		writeJSON(w, http.StatusOK, map[string]any{"status": 404, "message": "file not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": 200,
		"code":   0,
		"data": []map[string]any{{
			"download_url": base + "/cdn/download/" + fid + "?token=" + link,
		}},
	})
}

func (s *Quark) serveMedia(w *statusWriter, r *http.Request) {
	request := QuarkRequest{At: time.Now(), Method: r.Method, Path: r.URL.Path,
		Query: r.URL.RawQuery, Range: r.Header.Get("Range"),
		Cookie: r.Header.Get("Cookie") != "", UserAgent: r.Header.Get("User-Agent")}
	defer func() {
		request.Status = w.status
		s.record(request)
	}()
	fid := path.Base(r.URL.Path)
	s.mu.Lock()
	data, known := s.media[fid]
	link := s.link
	session := s.session
	s.mu.Unlock()
	if !known {
		http.NotFound(w, r)
		return
	}
	// A direct link is only usable while it has not rotated, and the CDN also
	// checks the session cookie and the desktop UA (both are why the kernel
	// sends per-track headers).
	if session == "" || r.URL.Query().Get("token") != link ||
		!strings.Contains(r.Header.Get("User-Agent"), "quark-cloud-drive") ||
		!strings.Contains(r.Header.Get("Cookie"), "__pus=") {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Accept-Ranges", "bytes")
	body := &Request{}
	serveRange(w, r, data, body, s.byteRate)
	request.Bytes = body.Bytes
}

func (s *Quark) record(request QuarkRequest) {
	s.mu.Lock()
	s.records = append(s.records, request)
	s.mu.Unlock()
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
