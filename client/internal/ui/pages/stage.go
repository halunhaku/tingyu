package pages

import (
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

type stageView struct {
	seek    float64
	pressed bool
	scrub   model.Scrubber
}

func stageState(s *model.State) *stageView {
	if v, ok := s.Transient("stage").(*stageView); ok {
		return v
	}
	v := &stageView{}
	s.SetTransient("stage", v)
	return v
}

// Stage is the full-window now-playing page of §4.3 / §10-9 / §10-10: the
// cover's two colours mixed half way to the canvas and a 28 px thumbnail
// washed 86% as the room's atmosphere, the 392 cover, the lyrics window (the
// current line 18/600 with a 2×24 accent bar and no pill) and the three
// "接下来" rows. The queue keeps its own page (⌘U), which is why the stage no
// longer has a lyrics/queue switch.
func Stage(c *ui.Context, d components.Design, s *model.State) {
	width, height := c.Size()
	v := stageState(s)
	update := s.Player()
	track := update.Track

	// The background is the cover's palette at half strength (§10-9), with the
	// same neutral tokens M4 used when tinting is off, the cover is gray or
	// extraction failed.
	coverName := ""
	if track != nil {
		coverName = track.CoverArtPath
	}
	from, to := s.StageColors(coverName, d.P.Dark)
	from = tokens.Mix(from, d.P.Canvas, tokens.StageAtmosphere)
	to = tokens.Mix(to, d.P.Canvas, tokens.StageAtmosphere)
	tinted := s.Settings().CoverTint && coverName != ""
	root := ui.Column(c).Fill().Gradient(from, to, 165)
	root.Draw(func(p *ui.Painter, r ui.Rect) {
		// A 28 px thumbnail stretched over the window and washed toward the
		// canvas: the atmosphere, never a picture (§4.3). It belongs to the
		// tint switch — with 封面动态取色 off the stage is the neutral
		// gradient, not the cover's colours under another name.
		if !tinted {
			return
		}
		if thumb := s.CoverThumb(coverName); thumb != nil {
			p.Image(thumb, ui.Rect{X: 0, Y: 0, W: width, H: height}, ui.Cover)
			p.Fill(r, d.P.Canvas.Alpha(tokens.StageAmbientWash), 0)
		}
	})
	root.Children(func() {
		stageTopBar(c, d, s, track)
		if track == nil {
			components.Empty(c, d, components.IconMusic, "未在播放", "从曲库中选一首歌开始播放。", func() {
				d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
			})
			return
		}
		ui.Row(c).FillWidth().Grow(1).
			Padding(tokens.Space24, tokens.StagePadding, tokens.Space40, tokens.StagePadding).
			Gap(tokens.StageContentGap).AlignItems(ui.Center).Children(func() {
			stageLeftColumn(c, d, s, v, track, height)
			stageRightColumn(c, d, s)
		})
	})
}

// stageTopBar is the stage's 60 high head (§4.3): the way back, the overline,
// and the favourite / match / close keys.
func stageTopBar(c *ui.Context, d components.Design, s *model.State, track *library.Track) {
	ui.Row(c).FillWidth().Height(tokens.StageTopBar).Padding(0, tokens.StagePadding).
		AlignItems(ui.Center).Children(func() {
		back := ui.Button(c, "").Size(tokens.ToolbarControl, tokens.ToolbarControl).Padding(6).
			Radius(tokens.RadiusSM).Label("返回").Tooltip("关闭（Esc）").
			Background(ui.Transparent).Border(0, ui.Transparent)
		back.Children(func() {
			ui.Icon(c, components.IconBack).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
		})
		if back.Clicked() {
			s.CloseStage()
		}
		ui.Box(c).Width(tokens.Space10)
		d.Text(c, tokens.Overline, "正在播放").TextColor(d.P.TextTertiary)
		ui.Spacer(c)
		if track == nil {
			return
		}
		label := "收藏"
		icon := components.IconHeart
		color := d.P.TextTertiary
		if track.IsFavorite {
			label = "取消收藏"
			icon = components.IconHeartOn
			color = d.P.Accent
		}
		fav := stageIconButton(c, d, icon, color, 30, label)
		if fav.Clicked() {
			s.ToggleFavorite(*track)
		}
		match := stageIconButton(c, d, components.IconSearch, d.P.TextTertiary, 30, "匹配元数据")
		match.Tooltip("匹配元数据…")
		if match.Clicked() {
			s.OpenMatch(*track)
		}
		closeStage := stageIconButton(c, d, components.IconClose, d.P.TextTertiary, 30, "关闭舞台")
		closeStage.Tooltip("关闭（Esc）")
		if closeStage.Clicked() {
			s.CloseStage()
		}
	})
}

// stageIconButton is one quiet icon key of the stage: no face of its own, so
// the keys sit on the atmosphere instead of on button-coloured squares (§4.3).
func stageIconButton(c *ui.Context, d components.Design, icon *ui.SVG, color ui.Color, size float32, label string) ui.Element {
	button := ui.Button(c, "").Size(size, size).Padding(6).Radius(tokens.RadiusSM).Label(label).
		Background(ui.Transparent).Border(0, ui.Transparent)
	button.Children(func() {
		ui.Icon(c, icon).FontSize(size * 0.5).TextColor(color)
	})
	return button
}

// stageLeftColumn is the 392 wide left column of §4.3: cover, title, artist,
// progress and the five keys, all left-aligned on the same 392 width.
func stageLeftColumn(c *ui.Context, d components.Design, s *model.State, v *stageView, track *library.Track, height float32) {
	update := s.Player()
	coverSize := min(tokens.StageCoverMax, height-360)
	if coverSize < 180 {
		coverSize = 180
	}
	ui.Column(c).Width(tokens.StageCoverMax).Gap(0).AlignItems(ui.Start).Children(func() {
		cover := components.Cover(c, d, s, track.CoverArtPath, coverSize, tokens.RadiusLG)
		cover.Shadow(0, 28, 60, -18, ui.RGBA(0, 0, 0, 110))
		cover.Transition(ui.ElementTransition{Match: components.CoverMatch{ID: track.ID}, Duration: tokens.DurationStage})
		ui.Box(c).Height(tokens.Space24)
		title := d.Text(c, tokens.Display, track.Title).TextColor(d.P.TextPrimary).SingleLine()
		title.TextAlign(ui.Start)
		ui.Box(c).Height(tokens.Space8)
		artist := d.Text(c, tokens.Body, track.Artist).TextColor(d.P.TextSecondary).SingleLine()
		artist.Cursor(ui.CursorPointer)
		artist.OnClick(func() {
			if found := s.ArtistByName(track.Artist); found != nil {
				s.OpenArtist(*found)
			}
		})
		if update.Failure != nil {
			ui.Box(c).Height(tokens.Space8)
			d.Text(c, tokens.Small, "播放失败："+update.Failure.Message).TextColor(d.P.Danger).Wrap()
			if b := d.Button(c, "重试此曲"); b.Clicked() {
				PlayAll(s, []library.Track{*track})
			}
		}
		ui.Box(c).Height(tokens.Space24)
		stageProgress(c, d, s, v, track)
		ui.Box(c).Height(tokens.Space20)
		stageControls(c, d, s, update)
	})
}

// stageProgress is the 392×4 rail with its 12 DIP thumb and the times under it
// (§4.3). The drag only moves the display; the release seeks once, so a remote
// source sees one Range request instead of one per frame.
func stageProgress(c *ui.Context, d components.Design, s *model.State, v *stageView, track *library.Track) {
	update := s.Player()
	position := update.Snapshot.Position
	duration := update.Snapshot.Duration
	if duration <= 0 {
		duration = track.Duration
	}
	end := duration.Seconds()
	if end <= 0 {
		end = 1
	}
	if !v.pressed {
		v.seek = position.Seconds()
	}
	slider := ui.SliderBase(c, &v.seek, 0, end).Width(tokens.StageCoverMax).Height(24).
		PaddingX(6).Label("播放进度")
	slider.Draw(func(p *ui.Painter, r ui.Rect) {
		frac := float32(v.seek / end)
		if frac < 0 || frac > 1 {
			frac = 0
		}
		center := r.Y + r.H/2
		p.Fill(ui.Rect{X: r.X, Y: center - 2, W: r.W, H: 4}, d.P.Border, 2)
		p.Fill(ui.Rect{X: r.X, Y: center - 2, W: r.W * frac, H: 4}, d.P.Accent, 2)
		p.Fill(ui.Rect{X: r.X + r.W*frac - 6, Y: center - 6, W: 12, H: 12}, d.P.Accent, 6)
	})
	if slider.Pressed() {
		v.pressed = true
	}
	if target, ok := v.scrub.Seek(v.seek, end, slider.Pressed(), slider.Changed()); ok {
		if a := s.Actions(); a != nil {
			_ = a.Seek(target)
		}
	}
	if v.pressed && !slider.Pressed() {
		v.pressed = false
	}
	ui.Row(c).Width(tokens.StageCoverMax).Children(func() {
		d.Text(c, tokens.NumSm, model.FormatDuration(position)).TextColor(d.P.TextTertiary)
		ui.Spacer(c)
		d.Text(c, tokens.NumSm, model.FormatDuration(duration)).TextColor(d.P.TextTertiary)
	})
}

// stageControls is the five-key row of §4.3: shuffle 30, prev 34, play 52,
// next 34, repeat 30, centred on the cover's width.
func stageControls(c *ui.Context, d components.Design, s *model.State, update player.Update) {
	ui.Row(c).Width(tokens.StageCoverMax).Gap(tokens.Space20).AlignItems(ui.Center).
		Justify(ui.Center).Children(func() {
		shuffleColor := d.P.TextTertiary
		if s.Shuffle() {
			shuffleColor = d.P.Accent
		}
		shuffle := stageIconButton(c, d, components.IconShuffle, shuffleColor, 30,
			"随机播放："+model.ShuffleLabel(s.Shuffle()))
		shuffle.Tooltip("随机播放：" + model.ShuffleLabel(s.Shuffle()))
		if shuffle.Clicked() {
			s.ToggleShuffle()
		}
		prev := stageIconButton(c, d, components.IconPrev, d.P.TextPrimary, 34, "上一首")
		if prev.Clicked() {
			if a := s.Actions(); a != nil {
				_ = a.Previous()
			}
		}
		icon := components.IconPlay
		label := "播放"
		if update.Snapshot.Playing {
			icon = components.IconPause
			label = "暂停"
		}
		play := ui.Button(c, "").Size(52, 52).Radius(26).Background(d.P.Accent).Label(label).Tooltip(label)
		play.Children(func() {
			ui.Icon(c, icon).FontSize(21).TextColor(d.P.OnAccent)
		})
		if play.Clicked() {
			if a := s.Actions(); a != nil {
				_ = a.TogglePlayPause()
			}
		}
		next := stageIconButton(c, d, components.IconNext, d.P.TextPrimary, 34, "下一首")
		if next.Clicked() {
			if a := s.Actions(); a != nil {
				_ = a.Next()
			}
		}
		repeat := stageIconButton(c, d, components.IconRepeat, d.P.TextTertiary, 30,
			"循环："+model.RepeatLabel(s.Repeat()))
		repeat.Tooltip("当前：" + model.RepeatLabel(s.Repeat()))
		if repeat.Clicked() {
			if a := s.Actions(); a != nil {
				s.SetRepeat(a.CycleRepeat())
			}
		}
	})
}

// stageRightColumn is the always-on lyrics window plus the three "接下来"
// rows (§10-10): 8 lines with the current one at 18/600 behind a 2×24 accent
// bar, sung lines at 45% and unsung at 55%, then a rule and the next tracks.
func stageRightColumn(c *ui.Context, d components.Design, s *model.State) {
	ui.Column(c).Grow(1).FillHeight().Justify(ui.Center).Gap(0).Children(func() {
		ui.Row(c).FillWidth().AlignItems(ui.Center).Children(func() {
			d.Text(c, tokens.Overline, "歌词").TextColor(d.P.TextTertiary)
			ui.Spacer(c)
			d.Text(c, tokens.NumSm, "LRC · 行级").TextColor(d.P.TextTertiary)
		})
		ui.Box(c).Height(tokens.Space24)
		stageLyricWindow(c, d, s)
		ui.Box(c).Height(tokens.Space24)
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Box(c).Height(tokens.Space16)
		stageUpNext(c, d, s)
	})
}

// stageLyricWindow shows eight lines of the current song around the one being
// sung. Clicking a timed line seeks there, as the lyrics page does.
func stageLyricWindow(c *ui.Context, d components.Design, s *model.State) {
	_, lyrics, ok := s.CurrentLyrics()
	if !ok || (len(lyrics.Lines) == 0 && lyrics.Plain == "") {
		d.Text(c, tokens.Small, "这首歌没有歌词；可按 ⌘L 打开歌词页。").
			TextColor(d.P.TextTertiary).Wrap()
		return
	}
	if len(lyrics.Lines) == 0 {
		// Untimed lyrics: the text is the only thing to show, so the window
		// shows it as plain lines of the same 15/1.9 step.
		ui.Text(c, lyrics.Plain).FontSize(15).LineHeight(1.9).
			TextColor(d.P.TextSecondary).Wrap()
		return
	}
	position := s.Player().Snapshot.Position
	current := -1
	if lyrics.Synced {
		current = lyrics.Current(position)
	}
	first := 0
	if current > 0 {
		first = max(0, current-3)
	}
	last := min(len(lyrics.Lines), first+8)
	for i := first; i < last; i++ {
		line := lyrics.Lines[i]
		if i == current {
			row := ui.Row(c).FillWidth().Gap(tokens.Space12).AlignItems(ui.Center).
				PaddingY(tokens.Space2)
			row.Children(func() {
				ui.Box(c).Width(2).Height(24).Radius(1).Background(d.P.Accent)
				if s.LyricsMode() == model.LyricsWords && model.WordsAvailable(line) {
					stageWordLine(c, d, line, position)
					return
				}
				d.Text(c, tokens.LyricActive, line.Text).TextColor(d.P.TextPrimary).SingleLine()
			})
			ui.Box(c).Height(tokens.Space8)
			continue
		}
		// Sung lines are dimmer than the ones still to come (§4.3: 45% / 55%).
		alpha := float32(0.55)
		if current >= 0 && i < current {
			alpha = 0.45
		}
		row := ui.Row(c).FillWidth().Padding(tokens.Space12, 0).AlignItems(ui.Center).Height(34)
		row.Children(func() {
			d.Text(c, tokens.Lyric, line.Text).TextColor(d.P.TextSecondary.Alpha(alpha)).SingleLine()
		})
		if lyrics.Synced {
			row.Focusable()
			row.OnClick(func() {
				if a := s.Actions(); a != nil {
					_ = a.Seek(line.Time)
				}
			})
		}
	}
}

// stageWordLine draws the current line word by word when the page's 逐字 mode
// is on — the same renderer the lyrics page uses (§4.3).
func stageWordLine(c *ui.Context, d components.Design, line model.LyricLine, pos time.Duration) {
	spans := make([]ui.Span, 0, len(line.Words))
	for _, word := range line.Words {
		progress := model.WordProgress(word, pos)
		spans = append(spans, ui.Span{
			Text:   word.Text,
			Size:   18,
			Weight: 600,
			Color:  tokens.Mix(d.P.TextSecondary, d.P.Accent, progress),
		})
	}
	ui.RichText(c, spans...).LineHeight(1.55).Wrap().Grow(1)
}

// stageUpNext is the "接下来" block of §4.3: three rows of a 24 DIP cover, the
// title at 12 and the duration at 11, plus the queue's size on the right.
func stageUpNext(c *ui.Context, d components.Design, s *model.State) {
	queue := s.Queue()
	index := s.QueueIndex()
	ui.Row(c).FillWidth().AlignItems(ui.Center).Children(func() {
		d.Text(c, tokens.Overline, "接下来").TextColor(d.P.TextTertiary)
		ui.Spacer(c)
		if len(queue) > 0 {
			d.Textf(c, tokens.NumSm, "共 %d 首", len(queue)).TextColor(d.P.TextTertiary)
		}
	})
	ui.Box(c).Height(tokens.Space6)
	shown := 0
	for i := index + 1; i < len(queue) && shown < 3; i++ {
		track := queue[i]
		row := ui.Row(c).FillWidth().Height(34).Gap(tokens.Space10).AlignItems(ui.Center).Focusable()
		if row.Hovered() {
			row.Background(tokens.Blend(d.P.Canvas, d.P.Hover))
		}
		row.OnClick(func() {
			PlayFrom(s, queue, i)
		})
		row.ContextMenu(func(m *ui.Menu) {
			components.TrackContextMenu(m, s, track)
		})
		row.Children(func() {
			components.Cover(c, d, s, track.CoverArtPath, 24, tokens.RadiusXS)
			d.Text(c, tokens.Label, track.Title).TextColor(d.P.TextSecondary).Grow(1).SingleLine()
			d.Text(c, tokens.NumSm, model.FormatDuration(track.Duration)).TextColor(d.P.TextTertiary)
		})
		shown++
	}
	if shown == 0 {
		d.Text(c, tokens.Small, "队列里没有下一首了。").TextColor(d.P.TextTertiary)
	}
}
