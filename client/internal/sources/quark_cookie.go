package sources

// Quark Cookie handling, ported from app/lib/sources/quark/quark_cookie_store.dart
// and quark_session.dart.
//
// Login methods (QR scan, web login, manual paste) only produce a raw Cookie
// header; parsing, de-duplication and the merge of Set-Cookie responses all
// happen here, so every path ends with the same session state.

import (
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// cookieNamePattern is the RFC 6265 token rule the Flutter client enforces.
var cookieNamePattern = regexp.MustCompile("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")

// setCookieAttributes are names that appear on the right side of Set-Cookie but
// are not cookies themselves.
var setCookieAttributes = map[string]bool{
	"domain": true, "expires": true, "httponly": true, "max-age": true,
	"partitioned": true, "path": true, "samesite": true, "secure": true,
}

// QuarkCookieJar is an insertion-ordered, duplicate-free Cookie set. Order is
// kept because the Cookie header the server sees should be stable across
// requests, which makes server-side debugging possible.
type QuarkCookieJar struct {
	order  []string
	values map[string]string
}

// NewQuarkCookieJar returns an empty jar.
func NewQuarkCookieJar() *QuarkCookieJar {
	return &QuarkCookieJar{values: map[string]string{}}
}

// ParseQuarkCookie parses a browser Cookie request header. Empty or attribute
// pairs are ignored, exactly as the Dart implementation does.
func ParseQuarkCookie(raw string) *QuarkCookieJar {
	jar := NewQuarkCookieJar()
	value := strings.TrimSpace(raw)
	if strings.HasPrefix(strings.ToLower(value), "cookie:") {
		if index := strings.Index(value, ":"); index >= 0 {
			value = strings.TrimSpace(value[index+1:])
		}
	}
	value = strings.NewReplacer("\r\n", ";", "\n", ";", "\r", ";").Replace(value)
	for _, part := range strings.Split(value, ";") {
		jar.putPair(part)
	}
	return jar
}

// putPair stores one name=value pair, dropping attributes and empty values.
func (j *QuarkCookieJar) putPair(rawPair string) {
	pair := strings.TrimSpace(rawPair)
	equals := strings.Index(pair, "=")
	if equals <= 0 {
		return
	}
	name := strings.TrimSpace(pair[:equals])
	value := strings.TrimSpace(pair[equals+1:])
	if !cookieNamePattern.MatchString(name) || setCookieAttributes[strings.ToLower(name)] || value == "" {
		return
	}
	if _, exists := j.values[name]; !exists {
		j.order = append(j.order, name)
	}
	j.values[name] = value
}

// IsEmpty reports whether no cookie is set.
func (j *QuarkCookieJar) IsEmpty() bool { return len(j.values) == 0 }

// Header renders the Cookie request header.
func (j *QuarkCookieJar) Header() string {
	if len(j.values) == 0 {
		return ""
	}
	parts := make([]string, 0, len(j.order))
	for _, name := range j.order {
		parts = append(parts, name+"="+j.values[name])
	}
	return strings.Join(parts, "; ")
}

// HeaderExcept renders the Cookie header without the named cookies, keeping
// insertion order (the ticket exchange drops two housekeeping cookies).
func (j *QuarkCookieJar) HeaderExcept(excluded ...string) string {
	skip := make(map[string]bool, len(excluded))
	for _, name := range excluded {
		skip[name] = true
	}
	parts := make([]string, 0, len(j.order))
	for _, name := range j.order {
		if skip[name] {
			continue
		}
		parts = append(parts, name+"="+j.values[name])
	}
	return strings.Join(parts, "; ")
}

// Names returns the cookie names in insertion order.
func (j *QuarkCookieJar) Names() []string {
	return append([]string(nil), j.order...)
}

// Cookies returns a copy of the cookies.
func (j *QuarkCookieJar) Cookies() map[string]string {
	out := make(map[string]string, len(j.values))
	for name, value := range j.values {
		out[name] = value
	}
	return out
}

// Has reports whether name is present.
func (j *QuarkCookieJar) Has(name string) bool {
	_, ok := j.values[name]
	return ok
}

// MergeSetCookie applies Set-Cookie response headers and reports whether the
// session changed. Expired or emptied cookies are removed, matching the Dart
// jar's rules (max-age<=0, or an Expires in the past).
func (j *QuarkCookieJar) MergeSetCookie(headers []string) bool {
	changed := false
	for _, header := range headers {
		parts := strings.Split(header, ";")
		if len(parts) == 0 {
			continue
		}
		pair := strings.TrimSpace(parts[0])
		equals := strings.Index(pair, "=")
		if equals <= 0 {
			continue
		}
		name := strings.TrimSpace(pair[:equals])
		if !cookieNamePattern.MatchString(name) {
			continue
		}
		value := strings.TrimSpace(pair[equals+1:])
		if value == "" || deletesCookie(parts[1:]) {
			if j.remove(name) {
				changed = true
			}
			continue
		}
		if existing, ok := j.values[name]; !ok || existing != value {
			j.putPair(name + "=" + value)
			changed = true
		}
	}
	return changed
}

// deletesCookie reports whether the attributes expire the cookie.
func deletesCookie(attributes []string) bool {
	for _, attribute := range attributes {
		trimmed := strings.TrimSpace(attribute)
		equals := strings.Index(trimmed, "=")
		if equals <= 0 {
			continue
		}
		name := strings.ToLower(strings.TrimSpace(trimmed[:equals]))
		value := strings.TrimSpace(trimmed[equals+1:])
		switch name {
		case "max-age":
			if seconds, err := parseInt64Strict(value); err == nil && seconds <= 0 {
				return true
			}
		case "expires":
			// Quark sends non-RFC dates such as `Mon, 14-Sep-2026 …`; an
			// unparsable Expires must not interrupt polling or delete a live
			// session (the Dart comment says the same).
			if when, err := http.ParseTime(value); err == nil && !when.After(nowUTC()) {
				return true
			}
		}
	}
	return false
}

func (j *QuarkCookieJar) remove(name string) bool {
	if _, ok := j.values[name]; !ok {
		return false
	}
	delete(j.values, name)
	for i, existing := range j.order {
		if existing == name {
			j.order = append(j.order[:i], j.order[i+1:]...)
			break
		}
	}
	return true
}

// QuarkSession is a parsed, live Cookie set plus the optional persistence hook
// that writes merged cookies back to the Keychain.
type QuarkSession struct {
	mu       sync.Mutex
	jar      *QuarkCookieJar
	nickname string
	onChange func(string)
}

// NewQuarkSession wraps a jar.
func NewQuarkSession(jar *QuarkCookieJar) *QuarkSession {
	return &QuarkSession{jar: jar, nickname: "夸克用户"}
}

// Jar returns the underlying jar (used by tests and the QR flow).
func (s *QuarkSession) Jar() *QuarkCookieJar { return s.jar }

// Nickname is the display name (the real API never returns one; the Flutter
// client also falls back to 夸克用户).
func (s *QuarkSession) Nickname() string { return s.nickname }

// IsEmpty reports whether the session has no cookie at all.
func (s *QuarkSession) IsEmpty() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.jar.IsEmpty()
}

// Header renders the Cookie request header.
func (s *QuarkSession) Header() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.jar.Header()
}

// MergeSetCookie applies response cookies and persists the new header.
func (s *QuarkSession) MergeSetCookie(headers []string) {
	if len(headers) == 0 {
		return
	}
	s.mu.Lock()
	changed := s.jar.MergeSetCookie(headers)
	header := s.jar.Header()
	persist := s.onChange
	s.mu.Unlock()
	if changed && persist != nil {
		persist(header)
	}
}

// OnChange installs the persistence hook (the app writes the Keychain).
func (s *QuarkSession) OnChange(fn func(string)) {
	s.mu.Lock()
	s.onChange = fn
	s.mu.Unlock()
}

// QuarkSessionState is the result of validating a Cookie.
type QuarkSessionState int

const (
	// QuarkSessionValid means the API accepted the Cookie.
	QuarkSessionValid QuarkSessionState = iota
	// QuarkSessionExpired means the Cookie is gone or revoked.
	QuarkSessionExpired
	// QuarkSessionUnavailable means validation could not run (network, 5xx).
	QuarkSessionUnavailable
)

// QuarkSessionCheck is one validation result.
type QuarkSessionCheck struct {
	State    QuarkSessionState
	Nickname string
	Message  string
}

// nowUTC is a seam for tests that need a fixed clock.
var nowUTC = func() time.Time { return time.Now().UTC() }
