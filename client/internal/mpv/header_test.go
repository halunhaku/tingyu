package mpv

import (
	"strings"
	"testing"
)

// The Quark desktop UA carries "KHTML, like Gecko". Unescaped, mpv's
// comma-separated http-header-fields option split it into two fields and FFmpeg
// sent the second half as an HTTP header continuation, which some CDN edges
// answer with 400 Bad Request. The value must stay one field.
func TestHeaderValuesWithCommasStayOneField(t *testing.T) {
	ua := "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.23.0"
	headers := map[string]string{
		"User-Agent": ua,
		"Cookie":     "a=1; b=x,y",
		"Accept":     "*/*",
	}
	value := headerValue(headers)
	if strings.Count(value, ",")-strings.Count(value, `\,`) != 2 {
		// Three fields, two separators; every other comma is escaped.
		t.Fatalf("headerValue separators look wrong: %q", value)
	}
	if !strings.Contains(value, `KHTML\, like Gecko`) {
		t.Fatalf("UA comma was not escaped: %q", value)
	}
	if !strings.Contains(value, `b=x\,y`) {
		t.Fatalf("Cookie comma was not escaped: %q", value)
	}
	names := headerFieldNames(value)
	if names != "Accept,Cookie,User-Agent" {
		t.Fatalf("headerFieldNames = %q, want the three field names", names)
	}
}

func TestEscapedBackslashSurvives(t *testing.T) {
	if got := escapeHeaderField(`a\b,c`); got != `a\\b\,c` {
		t.Fatalf("escapeHeaderField = %q", got)
	}
	// A trailing escaped backslash must not swallow the field separator.
	value := headerValue(map[string]string{"A": `x\`, "B": "y"})
	if !strings.Contains(value, `A: x\\,B: y`) {
		t.Fatalf("headerValue = %q", value)
	}
	if names := headerFieldNames(value); names != "A,B" {
		t.Fatalf("headerFieldNames = %q", names)
	}
}

// At debug level mpv logs the http-header-fields value it sets, and FFmpeg
// logs request headers; the values are credentials and must not reach a log.
func TestHeaderValuesAreRedactedFromLogLines(t *testing.T) {
	cases := []string{
		`cplayerSet property: http-header-fields="Accept: */*,Cookie: __pus=SECRETCOOKIE" -> 1`,
		`header: Cookie: __pus=SECRETCOOKIE`,
		`header: Authorization: Basic SECRETBASIC`,
		`proxy-authorization: Basic SECRETBASIC`,
	}
	for _, line := range cases {
		redacted := redactHeaderValues(line)
		for _, secret := range []string{"SECRETCOOKIE", "SECRETBASIC"} {
			if strings.Contains(redacted, secret) {
				t.Fatalf("%q still leaks %q: %q", line, secret, redacted)
			}
		}
		if !strings.Contains(redacted, "<redacted>") {
			t.Fatalf("%q was not marked redacted: %q", line, redacted)
		}
	}
	// A line without a credential header is untouched.
	plain := "http: HTTP error 400 Bad Request"
	if got := redactHeaderValues(plain); got != plain {
		t.Fatalf("plain line changed: %q", got)
	}
}
