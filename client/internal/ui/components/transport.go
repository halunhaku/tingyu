package components

import (
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

type transportView struct {
	seek    float64
	pressed bool
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

// Transport is the floating bottom bar: now playing, seek, transport keys,
// repeat, the stage, the queue and the volume. It is the one place playback
// state is shown outside the stage, so the two cannot disagree.
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
	ui.Column(c).FillWidth().Height(tokens.TransportHeight).Padding(tokens.Space16, tokens.Space10).
		Background(d.P.SurfaceRaised).BorderWidth(1, 0, 0, 0).BorderColor(d.P.Border).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space12).Children(func() {
			// Cover and title open the stage; the cover itself is the shared
			// element the stage's large cover matches (Hero approximation).
			if hasTrack {
				cover := Cover(c, d, s, track.CoverArtPath, 52, tokens.RadiusMD)
				cover.Transition(ui.ElementTransition{Match: CoverMatch{ID: track.ID}, Duration: tokens.DurationStage})
				cover.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
				ui.Column(c).Gap(2).Width(titleWidth).Children(func() {
					title := d.Text(c, tokens.BodyM, track.Title).SingleLine().TextColor(d.P.TextPrimary)
					title.Cursor(ui.CursorPointer).OnClick(s.OpenStage)
					d.Text(c, tokens.BodyS, model.TrackSubtitle(*track)).TextColor(d.P.TextSecondary).SingleLine()
				})
			} else {
				Cover(c, d, s, "", 52, tokens.RadiusMD)
				ui.Column(c).Gap(2).Width(titleWidth).Children(func() {
					d.Text(c, tokens.BodyM, "未在播放").TextColor(d.P.TextSecondary)
					d.Text(c, tokens.BodyS, "从曲库中选一首歌开始播放").TextColor(d.P.TextTertiary).SingleLine()
				})
			}
			ui.Spacer(c)
			ui.Column(c).Grow(1).Gap(tokens.Space4).Children(func() {
				ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).Justify(ui.Center).Children(func() {
					transportButton(c, d, IconPrev, "上一首", func() {
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
					play := ui.Button(c, "").Size(38, 38).Radius(19).Background(d.P.Accent).
						Label(playLabel).Tooltip(playLabel)
					play.Children(func() {
						ui.Icon(c, playIcon).FontSize(18).TextColor(d.P.OnAccent)
					})
					if play.Clicked() {
						if a := s.Actions(); a != nil {
							_ = a.TogglePlayPause()
						}
					}
					transportButton(c, d, IconNext, "下一首", func() {
						if a := s.Actions(); a != nil {
							_ = a.Next()
						}
					})
				})
				ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
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
					d.Text(c, tokens.NumericS, model.FormatDuration(position)).TextColor(d.P.TextTertiary)
					slider := ui.Slider(c, &v.seek, 0, end).Grow(1)
					if slider.Pressed() {
						v.pressed = true
					}
					if slider.Changed() {
						if a := s.Actions(); a != nil {
							_ = a.Seek(time.Duration(v.seek * float64(time.Second)))
						}
					}
					if v.pressed && !slider.Pressed() {
						v.pressed = false
					}
					d.Text(c, tokens.NumericS, model.FormatDuration(duration)).TextColor(d.P.TextTertiary)
				})
			})
			ui.Spacer(c)
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6).Children(func() {
				repeat := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).
					Label("循环：" + model.RepeatLabel(s.Repeat())).
					Tooltip("当前：" + model.RepeatLabel(s.Repeat()) + "，点击切换到" + model.RepeatNext(s.Repeat()))
				repeat.Children(func() {
					ui.Icon(c, IconRepeat).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
				})
				if repeat.Clicked() {
					if a := s.Actions(); a != nil {
						s.SetRepeat(a.CycleRepeat())
					}
				}
				shuffle := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).
					Label("随机播放：" + model.ShuffleLabel(s.Shuffle())).
					Tooltip("随机播放：" + model.ShuffleLabel(s.Shuffle()))
				shuffle.Children(func() {
					color := d.P.TextSecondary
					if s.Shuffle() {
						color = d.P.Accent
					}
					ui.Icon(c, IconShuffle).FontSize(tokens.IconCompact).TextColor(color)
				})
				if shuffle.Clicked() {
					s.ToggleShuffle()
				}
				transportButton(c, d, IconQueue, "播放队列", func() { s.OpenPage(model.PageQueue) })
				transportButton(c, d, IconLyrics, "歌词", func() {
					if s.Page() == model.PageLyrics {
						s.Back()
						return
					}
					s.OpenPage(model.PageLyrics)
				})
				transportButton(c, d, IconUp, "打开播放舞台", s.OpenStage)
				if !narrow {
					ui.Text(c, "音量").FontSize(11).TextColor(d.P.TextTertiary)
					volume := v.volume
					volumeSlider := ui.Slider(c, &volume, 0, 1).Width(92)
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

func transportButton(c *ui.Context, d Design, icon *ui.SVG, label string, action func()) {
	button := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).Label(label).Tooltip(label)
	button.Children(func() {
		ui.Icon(c, icon).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
	})
	if button.Clicked() && action != nil {
		action()
	}
}
