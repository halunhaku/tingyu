package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

type transportView struct {
	seek    float64
	pressed bool
	scrub   model.Scrubber
}

func transportState(s *model.State) *transportView {
	if v, ok := s.Transient("transport").(*transportView); ok {
		return v
	}
	v := &transportView{}
	s.SetTransient("transport", v)
	return v
}

// Transport is the full-width bottom bar (§10-3): 88 high on Clear glass with a
// 1 px top edge, aligned track/transport/navigation controls above a full-width
// progress row, and the queue/lyrics/volume on the right without the
// "音量" label. It is the one place playback state is shown outside the stage,
// so the two cannot disagree.
func Transport(c *ui.Context, d Design, s *model.State) {
	v := transportState(s)
	update := s.Player()
	track := update.Track
	hasTrack := track != nil
	windowWidth, _ := c.Size()
	available := windowWidth - d.SidebarWidth()
	narrow := available < 800
	infoWidth, padding, gap := float32(220), tokens.Space24, tokens.Space16
	if narrow {
		infoWidth, padding, gap = 160, tokens.Space16, tokens.Space12
	}
	bar := ui.Column(c).FillWidth().Height(tokens.TransportHeight).Shrink(0).Label("播放控制栏").
		Padding(tokens.Space6, padding).Material(d.ClearGlass(0.25)).
		BorderWidth(1, 0, 0, 0).BorderColor(d.P.Border)
	bar.Children(func() {
		ui.Row(c).FillWidth().Grow(1).Gap(gap).AlignItems(ui.Center).Children(func() {
			// Now playing: 48 cover, 13/500 title, 13 artist; both open the stage.
			info := ui.Row(c).Width(infoWidth).Shrink(0).Gap(tokens.Space12).AlignItems(ui.Center)
			if !hasTrack {
				info.Label("去曲库").Focusable().Cursor(ui.CursorPointer).OnClick(func() { s.OpenPage(model.PageLibrary) })
			}
			info.Children(func() {
				if hasTrack {
					cover := Cover(c, d, s, track.CoverArtPath, 48, tokens.RadiusSM).Shrink(0)
					cover.Transition(ui.ElementTransition{Match: CoverMatch{ID: track.ID}, Duration: tokens.DurationStage})
					cover.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
					ui.Column(c).Gap(2).Grow(1).MinWidth(0).Children(func() {
						title := d.Text(c, tokens.Caption, track.Title).SingleLine().TextColor(d.P.TextPrimary)
						title.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
						d.Text(c, tokens.Small, model.TrackSubtitle(*track)).TextColor(d.P.TextSecondary).SingleLine()
					})
				} else {
					Cover(c, d, s, "", 48, tokens.RadiusSM).Shrink(0)
					ui.Column(c).Gap(2).Grow(1).MinWidth(0).Children(func() {
						d.Text(c, tokens.Caption, "未在播放").TextColor(d.P.TextSecondary)
						d.Text(c, tokens.Small, "从曲库中选一首歌开始播放").TextColor(d.P.TextTertiary).SingleLine()
					})
				}
			})

			ui.Box(c).Grow(1).MinWidth(214).Center().Children(func() {
				ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Center).Children(func() {
					shuffle := ui.Button(c, "").Size(30, 30).Padding(6).Radius(tokens.RadiusSM).
						Label("随机播放：" + model.ShuffleLabel(s.Shuffle())).
						Tooltip("随机播放：" + model.ShuffleLabel(s.Shuffle()))
					shuffle.Children(func() {
						color := d.P.TextTertiary
						if s.Shuffle() {
							color = d.P.Accent
						}
						ui.Icon(c, IconShuffle).FontSize(tokens.IconCompact).TextColor(color)
					})
					if shuffle.Clicked() {
						s.ToggleShuffle()
					}
					transportButton(c, d, IconPrev, 32, "上一首", func() {
						if a := s.Actions(); a != nil {
							_ = a.Previous()
						}
					})
					playLabel := "播放"
					playIcon := IconPlay
					if update.Snapshot.Playing {
						playLabel = "暂停"
						playIcon = IconPause
					}
					play := ui.Button(c, "").Size(42, 42).Padding(0).Radius(21).Background(d.P.Accent).
						Label(playLabel).Tooltip(playLabel)
					play.Children(func() {
						ui.Icon(c, playIcon).FontSize(24).TextColor(d.P.OnAccent)
					})
					if play.Clicked() {
						if a := s.Actions(); a != nil {
							_ = a.TogglePlayPause()
						}
					}
					transportButton(c, d, IconNext, 32, "下一首", func() {
						if a := s.Actions(); a != nil {
							_ = a.Next()
						}
					})
					repeat := ui.Button(c, "").Size(30, 30).Padding(6).Radius(tokens.RadiusSM).
						Label("循环：" + model.RepeatLabel(s.Repeat())).
						Tooltip("当前：" + model.RepeatLabel(s.Repeat()) + "，点击切换到" + model.RepeatNext(s.Repeat()))
					repeat.Children(func() {
						color := d.P.TextTertiary
						if s.Repeat() != player.RepeatOff {
							color = d.P.Accent
						}
						ui.Icon(c, IconRepeat).FontSize(tokens.IconCompact).TextColor(color)
					})
					if repeat.Clicked() {
						if a := s.Actions(); a != nil {
							s.SetRepeat(a.CycleRepeat())
						}
					}
				})

			})
			// Keep navigation reachable even at the minimum content width.
			ui.Row(c).Shrink(0).Gap(tokens.Space6).AlignItems(ui.Center).Children(func() {
				transportButton(c, d, IconQueue, 32, "播放队列", func() { s.OpenPage(model.PageQueue) })
				transportButton(c, d, IconLyrics, 32, "歌词", func() {
					if s.Page() == model.PageLyrics {
						s.Back()
						return
					}
					s.OpenPage(model.PageLyrics)
				})
				transportButton(c, d, IconUp, 32, "打开播放舞台", s.OpenStage)
				if available >= 900 {
					ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Center).Children(func() {
						ui.Icon(c, IconVolume).FontSize(15).TextColor(d.P.TextTertiary)
						volume := s.Volume()
						volumeSlider := ui.Slider(c, &volume, 0, 1).Width(80).Label("音量")
						if volumeSlider.Changed() {
							s.SetVolume(volume)
							if a := s.Actions(); a != nil {
								_ = a.SetVolume(volume)
							}
						}
					})
				}
			})
		})
		ui.Row(c).FillWidth().Height(20).Shrink(0).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
			position := update.Snapshot.Position
			duration := update.Snapshot.Duration
			if duration <= 0 && hasTrack {
				duration = track.Duration
			}
			end := duration.Seconds()
			if end <= 0 {
				end = 1
			}
			if !v.pressed {
				v.seek = position.Seconds()
			}
			d.Text(c, tokens.NumSm, model.FormatDuration(position)).TextColor(d.P.TextTertiary)
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
			d.Text(c, tokens.NumSm, model.FormatDuration(duration)).TextColor(d.P.TextTertiary)
		})
	})
}

// transportButton is one icon key of the transport bar, sized by the caller.
func transportButton(c *ui.Context, d Design, icon *ui.SVG, size float32, label string, action func()) {
	// The 1 px border is part of the fixed box. Reserve the icon's exact width
	// so it cannot overflow the content box and drift to the right edge.
	padding := (size-tokens.IconNormal)/2 - 1
	button := ui.Button(c, "").Size(size, size).Padding(padding).Radius(tokens.RadiusSM).
		Label(label).Tooltip(label)
	button.Children(func() {
		ui.Icon(c, icon).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
	})
	if button.Clicked() && action != nil {
		action()
	}
}
