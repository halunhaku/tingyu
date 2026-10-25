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

// LyricsView shows the current track's lyrics, highlights the line playing and
// scrolls it into view. Manual scrolling pauses that for three seconds, as the
// Flutter panel does. A timed line is clickable and seeks to its timestamp.
func LyricsView(c *ui.Context, d Design, s *model.State) {
	track, lyrics, ok := s.CurrentLyrics()
	if !ok {
		Empty(c, d, IconLyrics, "未在播放", "从曲库中选一首歌，歌词会随播放高亮。", nil)
		return
	}
	if len(lyrics.Lines) == 0 && lyrics.Plain == "" {
		Empty(c, d, IconLyrics, "未找到歌词", "这首曲目没有内嵌歌词；歌词抓取需要 M5 的元数据管线。", nil)
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
			text := ui.Text(c, line.Text).Wrap().Grow(1)
			if active {
				text.FontSize(17).FontWeight(600).LineHeight(1.5).TextColor(d.P.Accent)
			} else {
				text.FontSize(15).LineHeight(1.6).TextColor(d.P.TextSecondary)
			}
		})
	}).Grow(1)
}
