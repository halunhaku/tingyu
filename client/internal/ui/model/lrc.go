package model

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// LyricWord is one sung unit of a line: a CJK character or a Latin word, with
// the time it is sung. Words are what the per-character renderer colours
// (research §3.7: "只要有行级 LRC，就能做出逐字效果").
type LyricWord struct {
	Text  string
	Start time.Duration
	End   time.Duration
}

// LyricLine is one timed line.
type LyricLine struct {
	Time time.Duration
	Text string
	// Words carries the line's timing spread over its characters when the
	// line has a duration to spread. nil means "line-level only" and the
	// per-character renderer falls back to the whole-line highlight.
	Words []LyricWord
}

// Lyrics is a parsed LRC document, or plain text when nothing is timed.
type Lyrics struct {
	Lines  []LyricLine
	Synced bool
	Plain  string
}

// timeTag matches [mm:ss], [mm:ss.x], [mm:ss.xx] and [mm:ss.xxx].
var timeTag = regexp.MustCompile(`^\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\]`)

// metaTag matches [ar:...], [ti:...] and the other ID tags.
var metaTag = regexp.MustCompile(`^\[[a-zA-Z]+:[^\]]*\]`)

// ParseLRC parses the format app/lib/features/player/lrc_parser.dart accepts:
// one line may carry several timestamps, fractions are 1/2/3 digits, unknown
// tags are ignored, and text without any timestamp is shown as plain lyrics.
func ParseLRC(text string) Lyrics {
	raw := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	out := Lyrics{}
	var plain []string
	for _, line := range raw {
		rest := strings.TrimSpace(line)
		var stamps []time.Duration
		for {
			if match := metaTag.FindStringSubmatch(rest); match != nil && !strings.HasPrefix(match[0], "[0") {
				// ID tag: [ar:artist] and friends carry no time.
				if timeTag.MatchString(rest) {
					break
				}
				rest = strings.TrimSpace(rest[len(match[0]):])
				continue
			}
			match := timeTag.FindStringSubmatch(rest)
			if match == nil {
				break
			}
			stamps = append(stamps, stampDuration(match))
			rest = strings.TrimSpace(rest[len(match[0]):])
		}
		if len(stamps) == 0 {
			if strings.TrimSpace(rest) != "" && !metaTag.MatchString(rest) {
				plain = append(plain, strings.TrimSpace(rest))
			}
			continue
		}
		for _, at := range stamps {
			out.Lines = append(out.Lines, LyricLine{Time: at, Text: rest})
		}
	}
	if len(out.Lines) == 0 {
		out.Synced = false
		out.Plain = strings.Join(plain, "\n")
		return out
	}
	sort.SliceStable(out.Lines, func(i, j int) bool { return out.Lines[i].Time < out.Lines[j].Time })
	out.Synced = true
	spreadLineWords(out.Lines)
	return out
}

// lastLineWindow is how long the final line is assumed to last when nothing
// follows it: a line nobody sings past four seconds is not a fast line.
const lastLineWindow = 4 * time.Second

// spreadLineWords gives every line its word timings. A line ends where the
// next begins; the last one gets its window from the previous gap (capped at
// eight seconds) or lastLineWindow.
func spreadLineWords(lines []LyricLine) {
	for i := range lines {
		start := lines[i].Time
		var end time.Duration
		switch {
		case i+1 < len(lines):
			end = lines[i+1].Time
		case i > 0:
			gap := start - lines[i-1].Time
			if gap <= 0 || gap > 8*time.Second {
				gap = lastLineWindow
			}
			end = start + gap
		default:
			end = start + lastLineWindow
		}
		lines[i].Words = SpreadWords(lines[i].Text, start, end)
	}
}

// SpreadWords distributes a line's duration over its sung units — a CJK
// character each, a Latin word each — in proportion to their width, because
// LRC only carries line timings. Punctuation and spaces ride with the unit
// before them, so joining the words gives the line back exactly.
//
// It returns nil for an empty line or one with no positive duration; callers
// then show the whole line highlighted.
func SpreadWords(text string, start, end time.Duration) []LyricWord {
	if text == "" || end <= start {
		return nil
	}
	type unit struct {
		text   string
		weight float64
	}
	units := make([]unit, 0, len(text))
	var pending strings.Builder
	flushPending := func() {
		if pending.Len() == 0 {
			return
		}
		units = append(units, unit{text: pending.String(), weight: unitWeight(pending.String())})
		pending.Reset()
	}
	for _, character := range text {
		if isCJK(character) {
			flushPending()
			units = append(units, unit{text: string(character), weight: 2})
			continue
		}
		if isWordRune(character) {
			pending.WriteRune(character)
			continue
		}
		// Punctuation and spaces ride with the unit before them.
		if len(units) > 0 && pending.Len() == 0 {
			last := &units[len(units)-1]
			last.text += string(character)
			last.weight += unitWeight(string(character))
			continue
		}
		pending.WriteRune(character)
	}
	flushPending()
	if len(units) == 0 {
		return nil
	}
	total := 0.0
	for _, item := range units {
		total += item.weight
	}
	if total <= 0 {
		return nil
	}
	words := make([]LyricWord, 0, len(units))
	span := end - start
	consumed := 0.0
	at := start
	for _, item := range units {
		share := float64(span) * item.weight / total
		wordEnd := at + time.Duration(share)
		if wordEnd <= at {
			wordEnd = at + time.Millisecond
		}
		if wordEnd > end {
			wordEnd = end
		}
		consumed += item.weight
		if consumed >= total || wordEnd > end {
			wordEnd = end
		}
		words = append(words, LyricWord{Text: item.text, Start: at, End: wordEnd})
		at = wordEnd
	}
	return words
}

func unitWeight(text string) float64 {
	weight := 0.0
	for _, character := range text {
		if isCJK(character) {
			weight += 2
		} else {
			weight++
		}
	}
	return weight
}

func isCJK(character rune) bool {
	switch {
	case character >= 0x4E00 && character <= 0x9FFF, // CJK unified
		character >= 0x3400 && character <= 0x4DBF, // extension A
		character >= 0xF900 && character <= 0xFAFF, // compatibility
		character >= 0x3040 && character <= 0x30FF, // kana
		character >= 0xAC00 && character <= 0xD7AF: // hangul
		return true
	}
	return false
}

func isWordRune(character rune) bool {
	return character >= '0' && character <= '9' ||
		character >= 'a' && character <= 'z' ||
		character >= 'A' && character <= 'Z' ||
		character == '\'' || character == '’'
}

// WordProgress is how far into word pos is, 0..1. A word with no duration is
// either not started (0) or done (1).
func WordProgress(word LyricWord, pos time.Duration) float32 {
	if pos <= word.Start {
		return 0
	}
	if pos >= word.End {
		return 1
	}
	length := word.End - word.Start
	if length <= 0 {
		return 1
	}
	return float32(pos-word.Start) / float32(length)
}

func stampDuration(match []string) time.Duration {
	minutes, _ := strconv.Atoi(match[1])
	seconds, _ := strconv.Atoi(match[2])
	var fraction time.Duration
	if match[3] != "" {
		value, _ := strconv.Atoi(match[3])
		switch len(match[3]) {
		case 1:
			fraction = time.Duration(value) * 100 * time.Millisecond
		case 2:
			fraction = time.Duration(value) * 10 * time.Millisecond
		default:
			fraction = time.Duration(value) * time.Millisecond
		}
	}
	return time.Duration(minutes)*time.Minute + time.Duration(seconds)*time.Second + fraction
}

// Current returns the line playing at pos: 0 before the first, the last after
// the end, as lrc_parser.dart does.
func (l Lyrics) Current(pos time.Duration) int {
	if len(l.Lines) == 0 {
		return -1
	}
	index := sort.Search(len(l.Lines), func(i int) bool { return l.Lines[i].Time > pos }) - 1
	if index < 0 {
		return 0
	}
	if index >= len(l.Lines) {
		return len(l.Lines) - 1
	}
	return index
}

type lyricsCache struct {
	id   string
	text string
	lrc  Lyrics
}

// LyricsFor parses a track's lyrics once per text, keeping the result across
// frames (lyrics_panel.dart caches by text too).
func (s *State) LyricsFor(track library.Track) Lyrics {
	if s.lyrics.id == track.ID && s.lyrics.text == track.Lyrics {
		return s.lyrics.lrc
	}
	s.lyrics = lyricsCache{id: track.ID, text: track.Lyrics, lrc: ParseLRC(track.Lyrics)}
	return s.lyrics.lrc
}

// CurrentLyrics returns the current track and its parsed lyrics.
func (s *State) CurrentLyrics() (library.Track, Lyrics, bool) {
	if s.player.Track == nil {
		return library.Track{}, Lyrics{}, false
	}
	return *s.player.Track, s.LyricsFor(*s.player.Track), true
}
