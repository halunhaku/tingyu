// Package httpsrv is a small test-only HTTP audio file server for spike S1.
//
// It exists to exercise libmpv's HTTP source against a server that
//   - requires HTTP Basic authentication on every request except OPTIONS,
//   - supports byte ranges (single range only), including suffix ranges,
//   - records every request as a JSONL line so a test can assert what mpv sent,
//   - refuses to escape its root directory.
package httpsrv

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Options configures a Server.
type Options struct {
	// Addr is the listen address. Empty means 127.0.0.1:0 (ephemeral port).
	Addr string
	// Dir is the static file root. Required; it is resolved to an absolute path.
	Dir string
	// User and Pass are the Basic auth credentials. An empty User disables auth.
	User string
	Pass string
	// LogPath, when non-empty, makes the server append one JSON object per
	// request to that file, flushing each line to disk.
	LogPath string
}

// Record is what the server remembers about a single request.
type Record struct {
	At        time.Time `json:"at"`
	Method    string    `json:"method"`
	Path      string    `json:"path"`
	Range     string    `json:"range,omitempty"`
	AuthOK    bool      `json:"auth_ok"`
	Status    int       `json:"status"`
	BytesSent int64     `json:"bytes_sent"`
	// ReqHeaders holds a few interesting client headers. Authorization is
	// reduced to "ok"/"fail"/"absent" so credentials never reach the log.
	ReqHeaders map[string]string `json:"req_headers"`
}

// Server is a running (or startable) test audio server.
type Server struct {
	opts Options
	dir  string

	mu      sync.Mutex
	ln      net.Listener
	httpSrv *http.Server
	baseURL string
	closed  bool

	records []Record

	logMu sync.Mutex
	logF  *os.File
}

// New validates the options and prepares a server. It does not listen yet.
func New(o Options) (*Server, error) {
	if o.Dir == "" {
		return nil, errors.New("httpsrv: Dir is required")
	}
	dir, err := filepath.Abs(o.Dir)
	if err != nil {
		return nil, fmt.Errorf("httpsrv: abs dir: %w", err)
	}
	st, err := os.Stat(dir)
	if err != nil {
		return nil, fmt.Errorf("httpsrv: stat dir: %w", err)
	}
	if !st.IsDir() {
		return nil, fmt.Errorf("httpsrv: %s is not a directory", dir)
	}
	if o.User == "" && o.Pass != "" {
		return nil, errors.New("httpsrv: Pass set without User")
	}
	if o.Addr == "" {
		o.Addr = "127.0.0.1:0"
	}

	s := &Server{opts: o, dir: dir}
	if o.LogPath != "" {
		f, err := os.OpenFile(o.LogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return nil, fmt.Errorf("httpsrv: open log: %w", err)
		}
		s.logF = f
	}
	return s, nil
}

// Start listens immediately and returns the base URL, e.g.
// "http://127.0.0.1:53412" (no trailing slash).
func (s *Server) Start() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return "", errors.New("httpsrv: server closed")
	}
	if s.baseURL != "" {
		return s.baseURL, nil
	}
	ln, err := net.Listen("tcp", s.opts.Addr)
	if err != nil {
		return "", fmt.Errorf("httpsrv: listen: %w", err)
	}
	s.ln = ln
	s.baseURL = "http://" + ln.Addr().String()
	s.httpSrv = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 15 * time.Second,
	}
	go func() {
		err := s.httpSrv.Serve(ln)
		if err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, net.ErrClosed) {
			// Nothing meaningful to report from a background goroutine on a
			// test helper; requests simply start failing.
			_ = err
		}
	}()
	return s.baseURL, nil
}

// BaseURL returns the URL from Start, or "" before Start.
func (s *Server) BaseURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.baseURL
}

// URL returns the absolute URL for a file name relative to Dir.
func (s *Server) URL(name string) string {
	return s.BaseURL() + "/" + url.PathEscape(name)
}

// Records returns a snapshot of all recorded requests.
func (s *Server) Records() []Record {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Record, len(s.records))
	for i, r := range s.records {
		out[i] = r
		if r.ReqHeaders != nil {
			m := make(map[string]string, len(r.ReqHeaders))
			for k, v := range r.ReqHeaders {
				m[k] = v
			}
			out[i].ReqHeaders = m
		}
	}
	return out
}

// Close stops the listener and closes the log file. It is safe to call more
// than once; the first call's error is returned.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	srv := s.httpSrv
	s.mu.Unlock()

	var err error
	if srv != nil {
		err = srv.Close()
	}
	s.logMu.Lock()
	if s.logF != nil {
		if cerr := s.logF.Sync(); cerr != nil && err == nil {
			err = cerr
		}
		if cerr := s.logF.Close(); cerr != nil && err == nil {
			err = cerr
		}
		s.logF = nil
	}
	s.logMu.Unlock()
	return err
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rec := Record{
		At:     time.Now().UTC(),
		Method: r.Method,
		Path:   r.URL.Path,
		Range:  r.Header.Get("Range"),
		ReqHeaders: map[string]string{
			"Range":        r.Header.Get("Range"),
			"User-Agent":   r.Header.Get("User-Agent"),
			"Referer":      r.Header.Get("Referer"),
			"Icy-MetaData": r.Header.Get("Icy-MetaData"),
		},
	}

	authOK := s.checkAuth(r)
	rec.AuthOK = authOK
	switch {
	case r.Header.Get("Authorization") == "":
		rec.ReqHeaders["Authorization"] = "absent"
	case authOK:
		rec.ReqHeaders["Authorization"] = "ok"
	default:
		rec.ReqHeaders["Authorization"] = "fail"
	}

	rw := &recorder{ResponseWriter: w}
	s.handle(rw, r, authOK)

	rec.Status = rw.statusCode()
	rec.BytesSent = rw.n
	s.appendRecord(rec)
}

func (s *Server) checkAuth(r *http.Request) bool {
	if s.opts.User == "" {
		return true
	}
	user, pass, ok := r.BasicAuth()
	if !ok {
		return false
	}
	u := subtle.ConstantTimeCompare([]byte(user), []byte(s.opts.User)) == 1
	p := subtle.ConstantTimeCompare([]byte(pass), []byte(s.opts.Pass)) == 1
	return u && p
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request, authOK bool) {
	if r.Method == http.MethodOptions {
		// OPTIONS is the one method served without auth: players sometimes
		// probe capabilities first. AuthOK in the record still reports whether
		// whatever credentials were presented actually validated.
		h := w.Header()
		h.Set("Allow", "GET, HEAD, OPTIONS")
		h.Set("Accept-Ranges", "bytes")
		h.Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		h.Set("Access-Control-Allow-Headers", "Authorization, Range, Icy-MetaData")
		h.Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if !authOK {
		w.Header().Set("WWW-Authenticate", `Basic realm="spike"`)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", "12")
		w.WriteHeader(http.StatusUnauthorized)
		if r.Method != http.MethodHead {
			_, _ = io.WriteString(w, "unauthorized")
		}
		return
	}

	switch r.Method {
	case http.MethodGet, http.MethodHead:
	default:
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", "18")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r.Method != http.MethodHead {
			_, _ = io.WriteString(w, "method not allowed")
		}
		return
	}

	s.serveFile(w, r)
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request) {
	full, ok := s.resolve(r.URL.Path)
	if !ok {
		notFound(w, r)
		return
	}
	f, err := os.Open(full)
	if err != nil {
		notFound(w, r)
		return
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil || st.IsDir() {
		notFound(w, r)
		return
	}
	size := st.Size()

	h := w.Header()
	h.Set("Accept-Ranges", "bytes")
	h.Set("Content-Type", contentType(full))
	h.Set("Last-Modified", st.ModTime().UTC().Format(http.TimeFormat))
	h.Set("Cache-Control", "no-store")

	rangeHeader := r.Header.Get("Range")
	if rangeHeader == "" {
		h.Set("Content-Length", strconv.FormatInt(size, 10))
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			_, _ = io.Copy(w, f)
		}
		return
	}

	start, end, kind := parseRange(rangeHeader, size)
	switch kind {
	case rangeSatisfiable:
		length := end - start + 1
		h.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
		h.Set("Content-Length", strconv.FormatInt(length, 10))
		w.WriteHeader(http.StatusPartialContent)
		if r.Method == http.MethodHead {
			return
		}
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			return
		}
		_, _ = io.CopyN(w, f, length)
	default: // unsatisfiable or malformed
		h.Set("Content-Range", fmt.Sprintf("bytes */%d", size))
		h.Set("Content-Length", "0")
		w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
	}
}

// resolve maps a request path to an absolute file path, refusing anything that
// could leave the root directory.
func (s *Server) resolve(urlPath string) (string, bool) {
	name := strings.TrimPrefix(urlPath, "/")
	if name == "" || strings.ContainsRune(name, 0) {
		return "", false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == ".." {
			return "", false
		}
	}
	clean := path.Clean("/" + name)
	rel := strings.TrimPrefix(clean, "/")
	if rel == "" {
		return "", false
	}
	full := filepath.Join(s.dir, filepath.FromSlash(rel))
	if full != s.dir && !strings.HasPrefix(full, s.dir+string(os.PathSeparator)) {
		return "", false
	}
	return full, true
}

func notFound(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", "9")
	w.WriteHeader(http.StatusNotFound)
	if r.Method != http.MethodHead {
		_, _ = io.WriteString(w, "not found")
	}
}

type rangeKind int

const (
	rangeMalformed rangeKind = iota
	rangeSatisfiable
	rangeUnsatisfiable
)

// parseRange understands a single "bytes=" range: "a-b", "a-", "-n".
// Multi-range requests are treated as unsatisfiable: mpv never sends them and
// the spike does not need multipart/byteranges.
func parseRange(header string, size int64) (start, end int64, kind rangeKind) {
	const prefix = "bytes="
	if len(header) < len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return 0, 0, rangeMalformed
	}
	spec := strings.TrimSpace(header[len(prefix):])
	if spec == "" || strings.Contains(spec, ",") {
		return 0, 0, rangeMalformed
	}
	dash := strings.IndexByte(spec, '-')
	if dash < 0 {
		return 0, 0, rangeMalformed
	}
	first, last := strings.TrimSpace(spec[:dash]), strings.TrimSpace(spec[dash+1:])

	// suffix form: bytes=-n
	if first == "" {
		n, err := strconv.ParseInt(last, 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, rangeUnsatisfiable
		}
		if size == 0 {
			return 0, 0, rangeUnsatisfiable
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, rangeSatisfiable
	}

	a, err := strconv.ParseInt(first, 10, 64)
	if err != nil || a < 0 {
		return 0, 0, rangeMalformed
	}
	if last == "" {
		if a >= size {
			return 0, 0, rangeUnsatisfiable
		}
		return a, size - 1, rangeSatisfiable
	}
	b, err := strconv.ParseInt(last, 10, 64)
	if err != nil || b < a {
		return 0, 0, rangeMalformed
	}
	if a >= size {
		return 0, 0, rangeUnsatisfiable
	}
	if b >= size {
		b = size - 1
	}
	return a, b, rangeSatisfiable
}

func contentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".flac":
		return "audio/flac"
	case ".mp3":
		return "audio/mpeg"
	case ".m4a", ".mp4":
		return "audio/mp4"
	case ".aac":
		return "audio/aac"
	case ".ogg", ".oga", ".opus":
		return "audio/ogg"
	case ".wav":
		return "audio/wav"
	case ".wv":
		return "audio/x-wavpack"
	case ".ape":
		return "audio/x-ape"
	case ".txt":
		return "text/plain; charset=utf-8"
	}
	return "application/octet-stream"
}

func (s *Server) appendRecord(rec Record) {
	s.mu.Lock()
	s.records = append(s.records, rec)
	s.mu.Unlock()

	s.logMu.Lock()
	defer s.logMu.Unlock()
	if s.logF == nil {
		return
	}
	line, err := json.Marshal(rec)
	if err != nil {
		return
	}
	line = append(line, '\n')
	if _, err := s.logF.Write(line); err != nil {
		return
	}
	_ = s.logF.Sync()
}

type recorder struct {
	http.ResponseWriter
	status int
	n      int64
}

func (r *recorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	n, err := r.ResponseWriter.Write(b)
	r.n += int64(n)
	return n, err
}

func (r *recorder) statusCode() int {
	if r.status == 0 {
		return http.StatusOK
	}
	return r.status
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }
