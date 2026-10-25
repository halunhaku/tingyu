package model

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// LyricLine is one timed line.
type LyricLine struct {
	Time time.Duration
	Text string
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
	return out
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
