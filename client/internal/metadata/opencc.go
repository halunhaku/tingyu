package metadata

import (
	_ "embed"
	"strings"
	"sync"
)

// OpenCC converts traditional Chinese to simplified one character at a time,
// from the same table the Flutter client ships (chinese_converter.dart,
// Apache-2.0, copied from app/assets/opencc/TSCharacters.txt). Phrase-level
// disambiguation (OpenCC's 800 KB TSPhrases table) is deliberately not
// included: lyrics are the only consumer, and the Dart client made the same
// trade-off. See data/NOTICE.
//
//go:embed data/TSCharacters.txt
var tsCharacters string

var (
	dictionaryOnce sync.Once
	dictionary     map[string]string
)

// ParseDictionary reads OpenCC's `traditional<TAB>candidate …` format and keeps
// the first candidate of each line, as the Dart implementation does.
func ParseDictionary(content string) map[string]string {
	out := make(map[string]string, 5000)
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimRight(raw, " \t\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		tab := strings.IndexByte(line, '\t')
		if tab <= 0 {
			continue
		}
		traditional := line[:tab]
		candidates := strings.Fields(line[tab+1:])
		if len(candidates) == 0 {
			continue
		}
		out[traditional] = candidates[0]
	}
	return out
}

func table() map[string]string {
	dictionaryOnce.Do(func() { dictionary = ParseDictionary(tsCharacters) })
	return dictionary
}

// OpenCC is the traditional→simplified converter.
type OpenCC struct{}

// ToSimplified converts every character the table knows and leaves the rest
// unchanged. It returns the input untouched when nothing converted.
func (*OpenCC) ToSimplified(text string) string {
	if text == "" {
		return text
	}
	known := table()
	var builder strings.Builder
	builder.Grow(len(text))
	converted := false
	for _, character := range text {
		if simplified, ok := known[string(character)]; ok {
			builder.WriteString(simplified)
			converted = true
			continue
		}
		builder.WriteRune(character)
	}
	if !converted {
		return text
	}
	return builder.String()
}
