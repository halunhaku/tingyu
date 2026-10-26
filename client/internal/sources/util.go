package sources

// Small parsing helpers shared by the protocol clients.

import (
	"strconv"
	"strings"
)

// parseInt64Strict parses a decimal integer and rejects anything else, so a
// `max-age=abc` attribute cannot silently look like zero.
func parseInt64Strict(text string) (int64, error) {
	return strconv.ParseInt(strings.TrimSpace(text), 10, 64)
}
