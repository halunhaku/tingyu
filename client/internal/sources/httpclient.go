package sources

// HTTP clients: one per source, with connection reuse, a bounded request
// budget and context cancellation (plan §3.5).
//
// Go honours HTTP_PROXY/HTTPS_PROXY/ALL_PROXY and nothing else; macOS users
// configure a proxy system-wide, so a client that could not see it would fail
// to connect on their networks while every other app works. `scutil --proxy`
// is read once and mapped onto the transport. PAC files and exception lists are
// not evaluated: Go has no PAC engine, and the plan rules out a third-party
// proxy library. That limitation is documented rather than silently ignored.

import (
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// NewHTTPClient is the HTTP client the M5 metadata pipeline shares with the
// source adapters: the same system-proxy-aware transport, connection reuse and
// overall budget (plan §3.5).
func NewHTTPClient(timeout time.Duration) *http.Client { return newHTTPClient(timeout) }

// newHTTPClient builds a client with the given overall request budget. The
// per-attempt deadline comes from each caller's context; Timeout is the
// belt-and-braces cap so a stalled body read cannot hang a sync forever.
func newHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{Transport: newTransport(), Timeout: timeout}
}

var (
	proxyOnce   sync.Once
	systemProxy string
)

// newTransport clones the default transport and applies the system proxy when
// no proxy environment variable says otherwise.
func newTransport() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = 4
	if hasProxyEnv() {
		return transport
	}
	proxyOnce.Do(func() { systemProxy = readSystemProxy() })
	if systemProxy != "" {
		if parsed, err := url.Parse(systemProxy); err == nil {
			transport.Proxy = http.ProxyURL(parsed)
		}
	}
	return transport
}

func hasProxyEnv() bool {
	for _, name := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"} {
		if strings.TrimSpace(os.Getenv(name)) != "" {
			return true
		}
	}
	return false
}

var scutilLine = regexp.MustCompile(`^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$`)

// readSystemProxy returns an http:// proxy URL from `scutil --proxy`, or "".
func readSystemProxy() string {
	output, err := exec.Command("scutil", "--proxy").Output()
	if err != nil {
		return ""
	}
	return parseScutilProxy(string(output))
}

// parseScutilProxy turns the output of `scutil --proxy` into a proxy URL.
// HTTPS wins over HTTP when both are enabled (most networks with TLS
// interception enable both to the same endpoint). SOCKS is ignored: net/http
// has no SOCKS proxy support without a dependency.
func parseScutilProxy(text string) string {
	values := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		match := scutilLine.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		values[match[1]] = match[2]
	}
	for _, candidate := range []struct{ enable, host, port string }{
		{"HTTPSEnable", "HTTPSProxy", "HTTPSPort"},
		{"HTTPEnable", "HTTPProxy", "HTTPPort"},
	} {
		if values[candidate.enable] != "1" {
			continue
		}
		host := values[candidate.host]
		port := values[candidate.port]
		if host == "" || port == "" {
			continue
		}
		return "http://" + host + ":" + port
	}
	return ""
}
