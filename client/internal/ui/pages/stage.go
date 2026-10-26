package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

type stageView struct {
	seek    float64
	pressed bool
	scrub   model.Scrubber
	volume  float64
	panel   int
}

func stageState(s *model.State) *stageView {
	if v, ok := s.Transient("stage").(*stageView); ok {
		return v
	}
	v := &stageView{volume: s.Volume(), panel: s.Stage().Panel}
	s.SetTransient("stage", v)
	return v
}

// Stage is the full-window now-playing page: a 160° gradient from the cover
// tint tokens (palette extraction itself is M5), the large cover, title and
// artist, transport, and a lyrics/queue side panel when the window is wide
// enough. The cover shares a Match identity with the transport's cover, which
// is the accepted Hero approximation (plan §3.1).
func Stage(c *ui.Context, d components.Design, s *model.State) {
	width, height := c.Size()
	v := stageState(s)
	update := s.Player()
	track := update.Track

	// Palette extraction from the cover belongs to M5, so the stage uses the
	// neutral token gradient (DESIGN.md §2.5.8) rather than inventing a color
	// and calling it the cover's.
	from, to := d.P.Canvas, d.P.SurfaceSunken
	if d.P.Dark {
		to = d.P.Surface
	}
	surface := ui.Column(c).Fill().Gradient(from, to, 160).Padding(tokens.Space24, tokens.Space20).Gap(tokens.Space12)
	surface.Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
			back := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).Label("关闭舞台").Tooltip("关闭（Esc）")
			back.Children(func() {
				ui.Icon(c, components.IconBack).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
			})
			if back.Clicked() {
				s.CloseStage()
			}
			if track != nil {
				d.Text(c, tokens.BodyS, model.StatusText(update)).TextColor(d.P.TextSecondary)
			}
			ui.Spacer(c)
			if track != nil {
				label := "收藏"
				icon := components.IconHeart
				color := d.P.TextSecondary
				if track.IsFavorite {
					label = "取消收藏"
					icon = components.IconHeartOn
					color = d.P.Accent
				}
				fav := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).Label(label).Tooltip(label)
				fav.Children(func() {
					ui.Icon(c, icon).FontSize(tokens.IconNormal).TextColor(color)
				})
				if fav.Clicked() {
					s.ToggleFavorite(*track)
				}
			}
		})
		if track == nil {
			components.Empty(c, d, components.IconMusic, "未在播放", "从曲库中选一首歌开始播放。", func() {
				d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
			})
			return
		}
		wide := width >= 1000
		ui.Row(c).Grow(1).Gap(tokens.Space40).AlignItems(ui.Center).Children(func() {
			ui.Column(c).Grow(1).Justify(ui.Center).AlignItems(ui.Center).Gap(tokens.Space20).Children(func() {
				coverSize := min(float32(360), min(width*0.42, height-300))
				if wide {
					coverSize = min(coverSize, 300)
				}
				if coverSize < 180 {
					coverSize = 180
				}
				cover := components.Cover(c, d, s, track.CoverArtPath, coverSize, tokens.RadiusXL)
				cover.Transition(ui.ElementTransition{Match: components.CoverMatch{ID: track.ID}, Duration: tokens.DurationStage})
				ui.Column(c).Gap(tokens.Space6).AlignItems(ui.Center).Children(func() {
					title := d.Text(c, tokens.DisplayM, track.Title).TextColor(d.P.TextPrimary)
					title.TextAlign(ui.Center)
					artist := d.Text(c, tokens.BodyL, track.Artist).TextColor(d.P.TextSecondary)
					artist.TextAlign(ui.Center)
					artist.Cursor(ui.CursorPointer)
					artist.OnClick(func() {
						if found := s.ArtistByName(track.Artist); found != nil {
							s.OpenArtist(*found)
						}
					})
					if update.Failure != nil {
						d.Text(c, tokens.BodyS, "播放失败："+update.Failure.Message).TextColor(d.P.Danger)
						if b := d.Button(c, "重试此曲"); b.Clicked() {
							PlayAll(s, []library.Track{*track})
						}
					}
				})
			})
			if wide {
				panel := ui.Column(c).Width(380).FillHeight().Gap(tokens.Space10).Children(func() {
					section := v.panel
					seg := ui.Segmented(c, &section, "歌词", "队列").Radius(tokens.RadiusSM).FontSize(13)
					if seg.Changed() {
						v.panel = section
						s.SetStagePanel(section)
					}
					if section == 0 {
						components.LyricsView(c, d, s)
					} else {
						stageQueue(c, d, s, 12)
					}
				})
				_ = panel
			}
		})
		stageControls(c, d, s, v, track)
	})
}

func stageControls(c *ui.Context, d components.Design, s *model.State, v *stageView, track *library.Track) {
	update := s.Player()
	ui.Column(c).FillWidth().Gap(tokens.Space10).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).MaxWidth(720).AlignSelf(ui.Center).Children(func() {
			position := update.Snapshot.Position
			duration := update.Snapshot.Duration
			if duration <= 0 && track != nil {
				duration = track.Duration
			}
			end := duration.Seconds()
			if end <= 0 {
				end = 1
			}
			if !v.pressed {
				v.seek = position.Seconds()
			}
			d.Text(c, tokens.NumericS, model.FormatDuration(position)).TextColor(d.P.TextTertiary)
			slider := ui.Slider(c, &v.seek, 0, end).Grow(1).Label("播放进度")
			if slider.Pressed() {
				v.pressed = true
			}
			// The drag only moves the display; the release seeks once, so a
			// remote source sees one Range request instead of one per frame
			// (research report §3.2).
			if target, ok := v.scrub.Seek(v.seek, end, slider.Pressed(), slider.Changed()); ok {
				if a := s.Actions(); a != nil {
					_ = a.Seek(target)
				}
			}
			if v.pressed && !slider.Pressed() {
				v.pressed = false
			}
			d.Text(c, tokens.NumericS, model.FormatDuration(duration)).TextColor(d.P.TextTertiary)
		})
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space20).AlignSelf(ui.Center).Children(func() {
			repeat := ui.Button(c, "").Padding(8).Radius(tokens.RadiusSM).
				Label("循环：" + model.RepeatLabel(s.Repeat())).Tooltip("当前：" + model.RepeatLabel(s.Repeat()))
			repeat.Children(func() {
				ui.Icon(c, components.IconRepeat).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
			})
			if repeat.Clicked() {
				if a := s.Actions(); a != nil {
					s.SetRepeat(a.CycleRepeat())
				}
			}
			shuffle := ui.Button(c, "").Padding(8).Radius(tokens.RadiusSM).
				Label("随机播放：" + model.ShuffleLabel(s.Shuffle())).Tooltip("随机播放：" + model.ShuffleLabel(s.Shuffle()))
			shuffle.Children(func() {
				color := d.P.TextSecondary
				if s.Shuffle() {
					color = d.P.Accent
				}
				ui.Icon(c, components.IconShuffle).FontSize(tokens.IconNormal).TextColor(color)
			})
			if shuffle.Clicked() {
				s.ToggleShuffle()
			}
			prev := ui.Button(c, "").Padding(10).Radius(tokens.RadiusSM).Label("上一首").Tooltip("上一首")
			prev.Children(func() {
				ui.Icon(c, components.IconPrev).FontSize(22).TextColor(d.P.TextPrimary)
			})
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
			play := ui.Button(c, "").Size(58, 58).Radius(29).Background(d.P.Accent).Label(label).Tooltip(label)
			play.Children(func() {
				ui.Icon(c, icon).FontSize(26).TextColor(d.P.OnAccent)
			})
			if play.Clicked() {
				if a := s.Actions(); a != nil {
					_ = a.TogglePlayPause()
				}
			}
			next := ui.Button(c, "").Padding(10).Radius(tokens.RadiusSM).Label("下一首").Tooltip("下一首")
			next.Children(func() {
				ui.Icon(c, components.IconNext).FontSize(22).TextColor(d.P.TextPrimary)
			})
			if next.Clicked() {
				if a := s.Actions(); a != nil {
					_ = a.Next()
				}
			}
			if b := d.IconButton(c, components.IconQueue, "播放队列"); b.Clicked() {
				s.OpenPage(model.PageQueue)
			}
			if b := d.IconButton(c, components.IconLyrics, "歌词"); b.Clicked() {
				s.OpenPage(model.PageLyrics)
			}
			ui.Text(c, "音量").FontSize(11).TextColor(d.P.TextTertiary)
			volume := v.volume
			volumeSlider := ui.Slider(c, &volume, 0, 1).Width(96)
			if volumeSlider.Changed() {
				v.volume = volume
				if a := s.Actions(); a != nil {
					_ = a.SetVolume(volume)
				}
			}
		})
	})
}

func stageQueue(c *ui.Context, d components.Design, s *model.State, limit int) {
	queue := s.Queue()
	index := s.QueueIndex()
	if len(queue) == 0 {
		components.Empty(c, d, components.IconQueue, "暂无待播歌曲", "从曲库中播放一首歌后，队列会显示在这里。", nil)
		return
	}
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(2).Children(func() {
			count := 0
			for i := index; i < len(queue) && count < limit; i++ {
				track := queue[i]
				row := i
				current := i == index
				components.TrackRow(c, d, s, track, current, func() {
					PlayFrom(s, queue, row)
				}).Focusable()
				count++
			}
		})
	})
}
