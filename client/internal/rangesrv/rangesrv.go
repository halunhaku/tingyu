// Package rangesrv is the HTTP audio source the M2 acceptance run plays from.
//
// It enforces what a real source enforces — Basic authentication on every
// request and byte ranges — and records every request, so acceptance can prove
// that libmpv (not Go) fetched the audio, that it sent Range, and that it sent
// the per-track Authorization header the kernel installed in the on_load hook.
//
// It is a development/acceptance tool, not part of the app: nothing in
// internal/app imports it.
package rangesrv

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Mode is what the server pretends to be on the next request.
type Mode int

const (
	// ModeAllow authenticates, honours Range and returns the file.
	ModeAllow Mode = iota
	// ModeUnauthorized rejects every request with 401, like a missing or
	// withdrawn credential.
	ModeUnauthorized
	// ModeForbidden rejects every request with 403, like an expired signed
	// direct link.
	ModeForbidden
	// ModeChunked serves 200 with no Content-Length and ignores Range, so the
	// player has no length to work from.
	ModeChunked
)

func (m Mode) String() string {
	switch m {
	case ModeUnauthorized:
		return "unauthorized"
	case ModeForbidden:
		return "forbidden"
	case ModeChunked:
		return "chunked"
	}
	return "allow"
}

// Options configures a Server.
type Options struct {
	// Root is the directory served. Required.
	Root string
	// User and Password are the Basic credentials every request must carry.
	User     string
	Password string
	// LogPath, when set, receives one JSON object per request.
	LogPath string
	// RequireRange makes ModeAllow reject a request that carries no Range
	// header. mpv always sends one; requiring it turns "the player uses Range"
	// from an observation into a rule the source enforces.
	RequireRange bool
}

// Request is one recorded HTTP request.
type Request struct {
	At            time.Time `json:"at"`
	Method        string    `json:"method"`
	Path          string    `json:"path"`
	Range         string    `json:"range"`
	Authorization string    `json:"authorization"`
	Authorized    bool      `json:"authorized"`
	Status        int       `json:"status"`
	Bytes         int64     `json:"bytes"`
	Mode          string    `json:"mode"`
}

// Server is a running (or startable) test audio server.
type Server struct {
	opts Options

	mu      sync.Mutex
	mode    Mode
	records []Request
	addr    string
	listen  net.Listener
	http    *http.Server
	logFile *os.File
	closed  bool
}

// New validates the options and prepares a server. It does not listen yet.
func New(o Options) (*Server, error) {
	if o.Root == "" {
		return nil, errors.New("rangesrv: Root is required")
	}
	info, err := os.Stat(o.Root)
	if err != nil {
		return nil, fmt.Errorf("rangesrv: root: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("rangesrv: root %s is not a directory", o.Root)
	}
	s := &Server{opts: o}
	if o.LogPath != "" {
		file, err := os.Create(o.LogPath)
		if err != nil {
			return nil, fmt.Errorf("rangesrv: log: %w", err)
		}
		s.logFile = file
	}
	return s, nil
}

// Start listens on a loopback ephemeral port and returns the base URL.
func (s *Server) Start() (string, error) {
	address, err := s.listenOn("127.0.0.1:0")
	if err != nil {
		return "", err
	}
	return "http://" + address, nil
}

// Restart listens again on the address Start chose. It simulates a network
// that comes back after an outage.
func (s *Server) Restart() (string, error) {
	s.mu.Lock()
	address := s.addr
	s.mu.Unlock()
	if address == "" {
		return s.Start()
	}
	address, err := s.listenOn(address)
	if err != nil {
		return "", err
	}
	return "http://" + address, nil
}

func (s *Server) listenOn(address string) (string, error) {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return "", fmt.Errorf("rangesrv: listen %s: %w", address, err)
	}
	server := &http.Server{Handler: s, ReadHeaderTimeout: 5 * time.Second}
	s.mu.Lock()
	s.addr = listener.Addr().String()
	s.listen = listener
	s.http = server
	s.mu.Unlock()
	go func() { _ = server.Serve(listener) }()
	return listener.Addr().String(), nil
}

// Stop closes the listener: further requests are refused, like a dropped
// network. The server keeps its address so Restart can reuse it.
func (s *Server) Stop() error {
	s.mu.Lock()
	listener, server := s.listen, s.http
	s.listen, s.http = nil, nil
	s.mu.Unlock()
	if server != nil {
		// Server.Close closes its listeners; closing them twice is not an
		// error worth reporting.
		_ = server.Close()
	}
	if listener != nil {
		if err := listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			return err
		}
	}
	return nil
}

// BaseURL returns the URL from Start, or "" before Start.
func (s *Server) BaseURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.addr == "" {
		return ""
	}
	return "http://" + s.addr
}

// URL returns the absolute URL for a path relative to Root. Each segment is
// escaped separately, so "remote/tone.flac" stays a path instead of becoming
// one escaped segment.
func (s *Server) URL(name string) string {
	segments := strings.Split(strings.TrimPrefix(name, "/"), "/")
	for index := range segments {
		segments[index] = url.PathEscape(segments[index])
	}
	return s.BaseURL() + "/" + strings.Join(segments, "/")
}

// SetMode changes how the next requests are answered.
func (s *Server) SetMode(mode Mode) {
	s.mu.Lock()
	s.mode = mode
	s.mu.Unlock()
}

// Mode returns the current mode.
func (s *Server) Mode() Mode {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mode
}

// Records returns a snapshot of all recorded requests.
func (s *Server) Records() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Request(nil), s.records...)
}

// Close stops the listener and closes the log file.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	logFile := s.logFile
	s.logFile = nil
	s.mu.Unlock()
	err := s.Stop()
	if logFile != nil {
		if closeErr := logFile.Close(); err == nil {
			err = closeErr
		}
	}
	return err
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	authorized := s.checkAuth(r)
	mode := s.Mode()
	recorder := &recorder{ResponseWriter: w, status: http.StatusOK}
	s.mu.Lock()
	index := len(s.records)
	s.records = append(s.records, Request{
		At:            time.Now(),
		Method:        r.Method,
		Path:          r.URL.Path,
		Range:         r.Header.Get("Range"),
		Authorization: r.Header.Get("Authorization"),
		Authorized:    authorized,
		Mode:          mode.String(),
	})
	s.mu.Unlock()

	switch {
	case mode == ModeUnauthorized || !authorized:
		recorder.Header().Set("WWW-Authenticate", `Basic realm="tingyu-m2"`)
		http.Error(recorder, "unauthorized", http.StatusUnauthorized)
	case mode == ModeForbidden:
		http.Error(recorder, "link expired", http.StatusForbidden)
	default:
		s.serveFile(recorder, r, mode)
	}

	s.mu.Lock()
	s.records[index].Status = recorder.status
	s.records[index].Bytes = recorder.written
	record := s.records[index]
	s.mu.Unlock()
	if s.logFile != nil {
		line, err := json.Marshal(record)
		if err == nil {
			_, _ = s.logFile.Write(append(line, '\n'))
		}
	}
}

func (s *Server) checkAuth(r *http.Request) bool {
	header := r.Header.Get("Authorization")
	const prefix = "Basic "
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(header[len(prefix):]))
	if err != nil {
		return false
	}
	want := s.opts.User + ":" + s.opts.Password
	return subtle.ConstantTimeCompare(decoded, []byte(want)) == 1
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, mode Mode) {
	path, ok := s.resolve(r.URL.Path)
	if !ok {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.IsDir() {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", contentType(path))
	if mode == ModeChunked {
		// No Content-Length and no ranges: the player has to do without.
		// Flushing before the first write stops net/http from measuring the
		// body and adding the length back.
		w.WriteHeader(http.StatusOK)
		_ = http.NewResponseController(w).Flush()
		_, _ = io.Copy(w, file)
		return
	}
	w.Header().Set("Accept-Ranges", "bytes")
	rangeHeader := r.Header.Get("Range")
	if s.opts.RequireRange && rangeHeader == "" {
		http.Error(w, "range required", http.StatusBadRequest)
		return
	}
	start, length, partial, err := parseRange(rangeHeader, info.Size())
	if err != nil {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", info.Size()))
		http.Error(w, "range not satisfiable", http.StatusRequestedRangeNotSatisfiable)
		return
	}
	if partial {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, start+length-1, info.Size()))
		w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.WriteHeader(http.StatusOK)
	}
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return
	}
	_, _ = io.CopyN(w, file, length)
}

// resolve maps a request path to an absolute file path, refusing anything that
// could leave the root directory.
func (s *Server) resolve(urlPath string) (string, bool) {
	cleaned := filepath.Clean("/" + strings.TrimPrefix(urlPath, "/"))
	path := filepath.Join(s.opts.Root, cleaned)
	relative, err := filepath.Rel(s.opts.Root, path)
	if err != nil || relative == ".." || strings.HasPrefix(relative, "../") {
		return "", false
	}
	return path, true
}

type rangeKind int

const (
	rangeFull rangeKind = iota
	rangePartial
)

// parseRange understands a single "bytes=" range: "a-b", "a-", "-n".
// Multi-range requests are treated as unsatisfiable: mpv never sends them.
func parseRange(header string, size int64) (start, length int64, partial bool, err error) {
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, size, false, nil
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false, errors.New("not a byte range")
	}
	spec := strings.TrimSpace(strings.TrimPrefix(header, "bytes="))
	if strings.Contains(spec, ",") {
		return 0, 0, false, errors.New("multi-range not supported")
	}
	first, last, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false, errors.New("malformed range")
	}
	first = strings.TrimSpace(first)
	last = strings.TrimSpace(last)
	switch {
	case first == "" && last == "":
		return 0, 0, false, errors.New("empty range")
	case first == "":
		count, convErr := strconv.ParseInt(last, 10, 64)
		if convErr != nil || count <= 0 {
			return 0, 0, false, errors.New("bad suffix range")
		}
		if count > size {
			count = size
		}
		return size - count, count, true, nil
	default:
		startValue, convErr := strconv.ParseInt(first, 10, 64)
		if convErr != nil || startValue < 0 || startValue >= size {
			return 0, 0, false, errors.New("bad range start")
		}
		end := size - 1
		if last != "" {
			endValue, convErr := strconv.ParseInt(last, 10, 64)
			if convErr != nil || endValue < startValue {
				return 0, 0, false, errors.New("bad range end")
			}
			if endValue < end {
				end = endValue
			}
		}
		return startValue, end - startValue + 1, true, nil
	}
}

func contentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".flac":
		return "audio/flac"
	case ".mp3":
		return "audio/mpeg"
	case ".m4a", ".alac":
		return "audio/mp4"
	case ".aac":
		return "audio/aac"
	case ".wav":
		return "audio/wav"
	case ".ogg", ".opus":
		return "audio/ogg"
	case ".aiff":
		return "audio/aiff"
	}
	return "application/octet-stream"
}

// recorder remembers the status and byte count a handler produced.
type recorder struct {
	http.ResponseWriter
	status  int
	written int64
}

func (r *recorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(data []byte) (int, error) {
	written, err := r.ResponseWriter.Write(data)
	r.written += int64(written)
	return written, err
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }
