package sourcemock

// WebDAV server: PROPFIND with Depth 0/1, Basic authentication, GET with byte
// ranges, and recordable failures (401, 403, 503 + BlockedTemporarily). The
// response bodies use the DAV: namespace and the element names the production
// parser reads (webdav_xml_parser.dart / webdav_xml.go).

import (
	"encoding/base64"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Mode is what the server does with the next requests.
type Mode int

const (
	// ModeAllow authenticates and answers.
	ModeAllow Mode = iota
	// ModeUnauthorized rejects PROPFIND with 401.
	ModeUnauthorized
	// ModeRateLimited rejects PROPFIND with 503 and the Nutstore body.
	ModeRateLimited
	// ModeForbiddenRoot rejects the root directory with 403 (wrong account or
	// root path).
	ModeForbiddenRoot
)

// Request is one recorded request.
type Request struct {
	At            time.Time `json:"at"`
	Method        string    `json:"method"`
	Path          string    `json:"path"`
	Depth         string    `json:"depth,omitempty"`
	Range         string    `json:"range,omitempty"`
	Authorization string    `json:"authorization,omitempty"`
	Status        int       `json:"status"`
	Bytes         int64     `json:"bytes,omitempty"`
}

// WebDAV is the mock server.
type WebDAV struct {
	mu      sync.Mutex
	user    string
	pass    string
	mode    Mode
	files   map[string][]byte // full cleaned path → bytes
	dirs    map[string]bool   // every directory, trailing slash
	child   map[string][]string
	records []Request
}

// NewWebDAV serves files at their full paths (e.g. "/dav/专辑/歌.wav").
func NewWebDAV(files map[string][]byte, user, password string) *WebDAV {
	server := &WebDAV{user: user, pass: password, mode: ModeAllow, files: map[string][]byte{}}
	for name, data := range files {
		server.files[cleanPath(name)] = data
	}
	server.index()
	return server
}

// index builds the directory tree the PROPFIND listings walk.
func (s *WebDAV) index() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.indexLocked()
}

func (s *WebDAV) record(request Request) {
	s.mu.Lock()
	s.records = append(s.records, request)
	s.mu.Unlock()
}

// SetMode changes the next responses.
func (s *WebDAV) SetMode(mode Mode) {
	s.mu.Lock()
	s.mode = mode
	s.mu.Unlock()
}

// Mode returns the current mode.
func (s *WebDAV) Mode() Mode {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mode
}

// Remove deletes a file from the tree, as a user deleting it on the server
// would, so the next authoritative scan can prove deletion of its track.
func (s *WebDAV) Remove(name string) {
	s.mu.Lock()
	delete(s.files, cleanPath(name))
	s.mu.Unlock()
	s.mu.Lock()
	s.indexLocked()
	s.mu.Unlock()
}

// indexLocked is index for callers already holding the lock.
func (s *WebDAV) indexLocked() {
	s.dirs = map[string]bool{}
	s.child = map[string][]string{}
	for name := range s.files {
		parent := path.Dir(name)
		for current := parent; current != "/" && current != "."; current = path.Dir(current) {
			dir := current + "/"
			if !s.dirs[dir] {
				s.dirs[dir] = true
				s.child[path.Dir(current)+"/"] = append(s.child[path.Dir(current)+"/"], dir)
			}
		}
		s.child[parent+"/"] = append(s.child[parent+"/"], name)
	}
	for dir := range s.child {
		sort.Strings(s.child[dir])
	}
}

// Records returns a copy of what was requested.
func (s *WebDAV) Records() []Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Request(nil), s.records...)
}

// ResetRecords clears the log.
func (s *WebDAV) ResetRecords() {
	s.mu.Lock()
	s.records = nil
	s.mu.Unlock()
}

// ServeHTTP implements the protocol.
func (s *WebDAV) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	recorder := &statusWriter{ResponseWriter: w, status: http.StatusOK}
	switch r.Method {
	case "PROPFIND":
		s.propfind(recorder, r)
	case http.MethodGet, http.MethodHead:
		s.get(recorder, r)
	default:
		http.Error(recorder, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *WebDAV) propfind(w *statusWriter, r *http.Request) {
	request := Request{At: time.Now(), Method: r.Method, Path: r.URL.Path,
		Depth: r.Header.Get("Depth"), Authorization: r.Header.Get("Authorization")}
	defer func() {
		request.Status = w.status
		s.record(request)
	}()

	if !s.authorized(r) {
		w.Header().Set("WWW-Authenticate", `Basic realm="mock"`)
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	mode := s.mode
	s.mu.Unlock()
	switch mode {
	case ModeUnauthorized:
		w.WriteHeader(http.StatusUnauthorized)
		return
	case ModeRateLimited:
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = io.WriteString(w, "<html><body>BlockedTemporarily</body></html>")
		return
	}

	dir := cleanPath(r.URL.Path)
	if !strings.HasSuffix(dir, "/") {
		dir += "/"
	}
	if mode == ModeForbiddenRoot && dir == "/dav/" {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	var entries []davEntry
	if r.Header.Get("Depth") == "0" {
		entries = []davEntry{{Href: dir, Dir: true}}
	} else {
		entries = s.entries(dir)
	}
	body, err := xml.Marshal(davMultistatus{Responses: entries})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.WriteHeader(http.StatusMultiStatus)
	_, _ = w.Write([]byte(xml.Header))
	_, _ = w.Write(body)
}

func (s *WebDAV) get(w *statusWriter, r *http.Request) {
	request := Request{At: time.Now(), Method: r.Method, Path: r.URL.Path,
		Range: r.Header.Get("Range"), Authorization: r.Header.Get("Authorization")}
	defer func() {
		request.Status = w.status
		s.record(request)
	}()
	if !s.authorized(r) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	s.mu.Lock()
	data, ok := s.files[cleanPath(r.URL.Path)]
	s.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "audio/wav")
	w.Header().Set("Accept-Ranges", "bytes")
	serveRange(w, r, data, &request, 0)
}

func (s *WebDAV) authorized(r *http.Request) bool {
	header := r.Header.Get("Authorization")
	const prefix = "Basic "
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(header, prefix))
	if err != nil {
		return false
	}
	user, pass, found := strings.Cut(string(decoded), ":")
	if !found {
		return false
	}
	s.mu.Lock()
	wantUser, wantPass := s.user, s.pass
	s.mu.Unlock()
	return user == wantUser && pass == wantPass
}

// entries lists the directory itself plus its immediate children.
func (s *WebDAV) entries(dir string) []davEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries := []davEntry{{Href: dir, Dir: true}}
	for _, child := range s.child[dir] {
		if strings.HasSuffix(child, "/") {
			entries = append(entries, davEntry{Href: child, Dir: true})
			continue
		}
		entries = append(entries, davEntry{
			Href:         child,
			Size:         int64(len(s.files[child])),
			DisplayName:  path.Base(child),
			LastModified: time.Now().UTC().Format(http.TimeFormat),
		})
	}
	return entries
}

// davEntry marshals as one <D:response>.
type davEntry struct {
	Href         string
	Dir          bool
	Size         int64
	DisplayName  string
	LastModified string
}

type davMultistatus struct {
	XMLName   xml.Name   `xml:"D:multistatus"`
	Responses []davEntry `xml:"D:response"`
}

func (e davEntry) MarshalXML(encoder *xml.Encoder, _ xml.StartElement) error {
	start := xml.StartElement{Name: xml.Name{Local: "D:response"}}
	if err := encoder.EncodeToken(start); err != nil {
		return err
	}
	if err := encoder.EncodeElement(e.Href, xml.StartElement{Name: xml.Name{Local: "D:href"}}); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.StartElement{Name: xml.Name{Local: "D:propstat"}}); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.StartElement{Name: xml.Name{Local: "D:prop"}}); err != nil {
		return err
	}
	if e.DisplayName != "" {
		if err := encoder.EncodeElement(e.DisplayName, xml.StartElement{Name: xml.Name{Local: "D:displayname"}}); err != nil {
			return err
		}
	}
	if err := encoder.EncodeToken(xml.StartElement{Name: xml.Name{Local: "D:resourcetype"}}); err != nil {
		return err
	}
	if e.Dir {
		if err := encoder.EncodeToken(xml.StartElement{Name: xml.Name{Local: "D:collection"}}); err != nil {
			return err
		}
		if err := encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:collection"}}); err != nil {
			return err
		}
	}
	if err := encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:resourcetype"}}); err != nil {
		return err
	}
	if !e.Dir {
		if err := encoder.EncodeElement(fmt.Sprintf("%d", e.Size), xml.StartElement{Name: xml.Name{Local: "D:getcontentlength"}}); err != nil {
			return err
		}
		if e.LastModified != "" {
			if err := encoder.EncodeElement(e.LastModified, xml.StartElement{Name: xml.Name{Local: "D:getlastmodified"}}); err != nil {
				return err
			}
		}
	}
	if err := encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:prop"}}); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.StartElement{Name: xml.Name{Local: "D:status"}}); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.CharData("HTTP/1.1 200 OK")); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:status"}}); err != nil {
		return err
	}
	if err := encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:propstat"}}); err != nil {
		return err
	}
	return encoder.EncodeToken(xml.EndElement{Name: xml.Name{Local: "D:response"}})
}

func cleanPath(value string) string {
	cleaned := path.Clean("/" + strings.TrimPrefix(value, "/"))
	if strings.HasSuffix(value, "/") && !strings.HasSuffix(cleaned, "/") {
		cleaned += "/"
	}
	return cleaned
}

// statusWriter records the status code a handler sent.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// serveRange writes data honouring a single Range header and counts bytes. A
// positive rate (bytes per second) throttles the body, so a player cannot
// buffer a whole file instantly — which is what makes "seek while the link is
// expired" a deterministic request in acceptance.
func serveRange(w http.ResponseWriter, r *http.Request, data []byte, request *Request, byteRate int) {
	total := int64(len(data))
	start, length, partial, err := parseByteRange(r.Header.Get("Range"), total)
	if err != nil {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", total))
		w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return
	}
	if partial {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, start+length-1, total))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
	}
	if r.Method != http.MethodHead {
		written := writeBody(w, data[start:start+length], byteRate)
		if request != nil {
			request.Bytes = int64(written)
		}
	}
}

// writeBody writes data, pacing it when byteRate > 0.
func writeBody(w http.ResponseWriter, data []byte, byteRate int) int {
	if byteRate <= 0 {
		written, _ := w.Write(data)
		return written
	}
	const chunk = 16 * 1024
	written := 0
	started := time.Now()
	for offset := 0; offset < len(data); offset += chunk {
		end := offset + chunk
		if end > len(data) {
			end = len(data)
		}
		n, err := w.Write(data[offset:end])
		written += n
		if err != nil {
			return written
		}
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		// Pace to the requested rate, measured from the first byte.
		wanted := time.Duration(float64(written) / float64(byteRate) * float64(time.Second))
		if sleep := wanted - time.Since(started); sleep > 0 {
			time.Sleep(sleep)
		}
	}
	return written
}

func parseByteRange(header string, total int64) (start, length int64, partial bool, err error) {
	if header == "" {
		return 0, total, false, nil
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false, fmt.Errorf("unsupported range %q", header)
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if strings.Contains(spec, ",") {
		return 0, 0, false, fmt.Errorf("multiple ranges unsupported")
	}
	left, right, found := strings.Cut(spec, "-")
	if !found {
		return 0, 0, false, fmt.Errorf("malformed range")
	}
	if left == "" {
		n, parseErr := strconv.ParseInt(right, 10, 64)
		if parseErr != nil || n <= 0 {
			return 0, 0, false, fmt.Errorf("malformed suffix range")
		}
		if n > total {
			n = total
		}
		return total - n, n, true, nil
	}
	first, parseErr := strconv.ParseInt(left, 10, 64)
	if parseErr != nil || first < 0 || first >= total {
		return 0, 0, false, fmt.Errorf("range start out of bounds")
	}
	last := total - 1
	if right != "" {
		parsed, rangeErr := strconv.ParseInt(right, 10, 64)
		if rangeErr != nil || parsed < first {
			return 0, 0, false, fmt.Errorf("range end out of bounds")
		}
		if parsed < last {
			last = parsed
		}
	}
	return first, last - first + 1, true, nil
}
