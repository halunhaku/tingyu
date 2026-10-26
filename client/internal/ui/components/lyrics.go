package components

import (
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

type lyricsViewState struct {
	trackID  string
	line     int
	manualAt time.Time
	autoAt   time.Time
}

// LyricsView shows the current track's lyrics, highlights what is being sung
// and scrolls the line into view. Manual scrolling pauses that for three
// seconds, as the Flutter panel does. A timed line is clickable and seeks.
//
// Two renderers share the same parsed document (plan §6 M5 item 5): 逐行 colours
// the whole line, 逐字 colours each character/word by how far playback is into
// it. Both are pure functions of the playback position — no wall clock drives
// the highlight, so seeking to t and playing to t draw the same frame
// (research §3.7).
func LyricsView(c *ui.Context, d Design, s *model.State) {
	track, lyrics, ok := s.CurrentLyrics()
	if !ok {
		Empty(c, d, IconLyrics, "未在播放", "从曲库中选一首歌，歌词会随播放高亮。", nil)
		return
	}
	if len(lyrics.Lines) == 0 && lyrics.Plain == "" {
		Empty(c, d, IconLyrics, "未找到歌词", "这首曲目没有内嵌歌词；可在曲目右键「匹配元数据…」或设置页触发补全后重试。", nil)
		return
	}
	view, _ := s.Transient("lyrics").(*lyricsViewState)
	if view == nil || view.trackID != track.ID {
		view = &lyricsViewState{trackID: track.ID, line: -1}
		s.SetTransient("lyrics", view)
	}
	pos := s.Player().Snapshot.Position
	current := lyrics.Current(pos)
	list := s.LyricsList()
	first, last := list.Visible()
	visible := first < 0 || (current >= first && current <= last)
	if lyrics.Synced && current >= 0 {
		if current != view.line {
			view.line = current
			// A new line scrolls into view unless the reader scrolled by hand
			// within the last three seconds (lyrics_view.dart behavior).
			if s.Now().Sub(view.manualAt) > tokens.LyricsManualPause {
				list.ScrollTo(current, ui.Center)
				view.autoAt = s.Now()
			}
		} else if !visible && view.autoAt.IsZero() {
			// The same line left the view without us moving it: a manual
			// scroll. Pause auto-follow for three seconds.
			view.manualAt = s.Now()
		}
		if s.Now().Sub(view.manualAt) > tokens.LyricsManualPause && !visible {
			list.ScrollTo(current, ui.Center)
			view.autoAt = s.Now()
		}
	}
	if !lyrics.Synced {
		ui.Column(c).Grow(1).Gap(tokens.Space12).Padding(tokens.Space8).Children(func() {
			ui.Text(c, lyrics.Plain).FontSize(15).LineHeight(1.8).TextColor(d.P.TextSecondary).Wrap()
		})
		return
	}
	lyricsModeRow(c, d, s, lyrics)
	list.Selected = nil
	ui.List(c, list, len(lyrics.Lines), func(row int) {
		line := lyrics.Lines[row]
		active := row == current
		rowElement := ui.Row(c).FillWidth().Padding(tokens.Space12, tokens.Space10).
			Radius(tokens.RadiusSM)
		if active {
			rowElement.Background(d.P.AccentSoft)
		} else if rowElement.Hovered() {
			rowElement.Background(d.P.Hover)
		}
		rowElement.OnClick(func() {
			if a := s.Actions(); a != nil {
				_ = a.Seek(line.Time)
			}
		})
		rowElement.Children(func() {
			if active && s.LyricsMode() == model.LyricsWords && model.WordsAvailable(line) {
				wordSpans(c, d, line, pos)
				return
			}
			text := ui.Text(c, line.Text).Wrap().Grow(1)
			if active {
				text.FontSize(17).FontWeight(600).LineHeight(1.5).TextColor(d.P.Accent)
			} else {
				text.FontSize(15).LineHeight(1.6).TextColor(d.P.TextSecondary)
			}
		})
	}).Grow(1)
}

// lyricsModeRow is the 逐行 / 逐字 switch. It only appears when there are timed
// lines; the per-character renderer is the second mode, never the default.
func lyricsModeRow(c *ui.Context, d Design, s *model.State, lyrics model.Lyrics) {
	available := false
	for _, line := range lyrics.Lines {
		if model.WordsAvailable(line) {
			available = true
			break
		}
	}
	if !available {
		return
	}
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
		d.Text(c, tokens.LabelS, "歌词显示").TextColor(d.P.TextTertiary)
		ui.Spacer(c)
		mode := s.LyricsMode()
		segment := ui.Segmented(c, &mode, "逐行", "逐字").Radius(tokens.RadiusSM).FontSize(11)
		if segment.Changed() {
			s.SetLyricsMode(mode)
		}
	})
}

// wordSpans draws the active line character by character: each sung unit
// interpolates from the secondary text color to the accent as playback crosses
// it, so the highlight follows the vocal rather than the line.
func wordSpans(c *ui.Context, d Design, line model.LyricLine, pos time.Duration) {
	spans := make([]ui.Span, 0, len(line.Words))
	for _, word := range line.Words {
		progress := model.WordProgress(word, pos)
		spans = append(spans, ui.Span{
			Text:   word.Text,
			Size:   17,
			Weight: 600,
			Color:  mixColor(d.P.TextSecondary, d.P.Accent, progress),
		})
	}
	ui.RichText(c, spans...).LineHeight(1.5).Wrap().Grow(1)
}

// mixColor interpolates two opaque colors by t (0..1).
func mixColor(from, to ui.Color, t float32) ui.Color {
	if t <= 0 {
		return from
	}
	if t >= 1 {
		return to
	}
	channel := func(a, b uint8) uint8 {
		return uint8(float32(a) + (float32(b)-float32(a))*t)
	}
	return ui.RGBA(channel(from.R, to.R), channel(from.G, to.G), channel(from.B, to.B), 1)
}
