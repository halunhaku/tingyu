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
	volume  float64
}

func transportState(s *model.State) *transportView {
	if v, ok := s.Transient("transport").(*transportView); ok {
		return v
	}
	v := &transportView{volume: s.Volume()}
	s.SetTransient("transport", v)
	return v
}

// Transport is the full-width bottom bar (§10-3): 88 high on Clear glass with a
// 1 px top edge, the playing track on the left, the keys and the progress in one
// column in the middle, and the queue/lyrics/volume on the right without the
// "音量" label. It is the one place playback state is shown outside the stage,
// so the two cannot disagree.
func Transport(c *ui.Context, d Design, s *model.State) {
	v := transportState(s)
	update := s.Player()
	track := update.Track
	hasTrack := track != nil
	windowWidth, _ := c.Size()
	narrow := windowWidth < 1000
	titleWidth := float32(210)
	if narrow {
		titleWidth = 160
	}
	bar := ui.Row(c).FillWidth().Height(tokens.TransportHeight).PaddingX(tokens.Space24).
		Gap(tokens.Space16).AlignItems(ui.Center).
		Material(d.ClearGlass(0.25)).
		BorderWidth(1, 0, 0, 0).BorderColor(d.P.Border)
	bar.Children(func() {
		// Now playing: 48 cover, 13/500 title, 13 artist; both open the stage.
		ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Center).Children(func() {
			if hasTrack {
				cover := Cover(c, d, s, track.CoverArtPath, 48, tokens.RadiusSM)
				cover.Transition(ui.ElementTransition{Match: CoverMatch{ID: track.ID}, Duration: tokens.DurationStage})
				cover.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
				ui.Column(c).Gap(2).Width(titleWidth).Children(func() {
					title := d.Text(c, tokens.Caption, track.Title).SingleLine().TextColor(d.P.TextPrimary)
					title.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
					d.Text(c, tokens.Small, model.TrackSubtitle(*track)).TextColor(d.P.TextSecondary).SingleLine()
				})
			} else {
				Cover(c, d, s, "", 48, tokens.RadiusSM)
				ui.Column(c).Gap(2).Width(titleWidth).Children(func() {
					d.Text(c, tokens.Caption, "未在播放").TextColor(d.P.TextSecondary)
					d.Text(c, tokens.Small, "从曲库中选一首歌开始播放").TextColor(d.P.TextTertiary).SingleLine()
				})
				if b := d.Button(c, "去曲库"); b.Clicked() {
					s.OpenPage(model.PageLibrary)
				}
			}
		})
		ui.Spacer(c)
		// Keys over the progress, in one column (§10-3 控件与进度同栏).
		ui.Column(c).Gap(tokens.Space6).AlignItems(ui.Center).Children(func() {
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
				play := ui.Button(c, "").Size(42, 42).Radius(21).Background(d.P.Accent).
					Label(playLabel).Tooltip(playLabel)
				play.Children(func() {
					ui.Icon(c, playIcon).FontSize(18).TextColor(d.P.OnAccent)
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
			ui.Row(c).Width(420).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
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
		ui.Spacer(c)
		// The right cluster: icons only, then the volume slider at 72 (§10-3).
		ui.Row(c).Gap(tokens.Space6).AlignItems(ui.Center).Children(func() {
			transportButton(c, d, IconQueue, 32, "播放队列", func() { s.OpenPage(model.PageQueue) })
			transportButton(c, d, IconLyrics, 32, "歌词", func() {
				if s.Page() == model.PageLyrics {
					s.Back()
					return
				}
				s.OpenPage(model.PageLyrics)
			})
			transportButton(c, d, IconUp, 32, "打开播放舞台", s.OpenStage)
			ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Center).Children(func() {
				ui.Icon(c, IconVolume).FontSize(15).TextColor(d.P.TextTertiary)
				if !narrow {
					volume := v.volume
					volumeSlider := ui.Slider(c, &volume, 0, 1).Width(72).Label("音量")
					if volumeSlider.Changed() {
						v.volume = volume
						if a := s.Actions(); a != nil {
							_ = a.SetVolume(volume)
						}
					}
				}
			})
		})
	})
}

// transportButton is one icon key of the transport bar, sized by the caller.
func transportButton(c *ui.Context, d Design, icon *ui.SVG, size float32, label string, action func()) {
	button := ui.Button(c, "").Size(size, size).Padding(6).Radius(tokens.RadiusSM).
		Label(label).Tooltip(label)
	button.Children(func() {
		ui.Icon(c, icon).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
	})
	if button.Clicked() && action != nil {
		action()
	}
}
