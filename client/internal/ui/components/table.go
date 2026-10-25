package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// TableOptions configures one track list.
type TableOptions struct {
	State      *model.State
	List       *model.TrackList
	ShowSource bool
}

// TrackTable is the shared track list: a fixed header whose labels sort, and a
// virtualised list of rows (only the visible ones are built). A single click
// plays from that row, as the Flutter client does; the leading glyph shows the
// current track and Enter on the keyboard plays the chosen row.
func TrackTable(c *ui.Context, d Design, opts TableOptions) {
	list := opts.List
	state := opts.State
	items := list.Items()
	sourceWidth := float32(0)
	if opts.ShowSource {
		sourceWidth = 130
	}
	ui.Column(c).Grow(1).Gap(tokens.Space4).Children(func() {
		header := ui.Row(c).FillWidth().Height(32).PaddingX(tokens.Space8).AlignItems(ui.Center)
		header.Children(func() {
			ui.Box(c).Width(tokens.IconCompact + tokens.Space8)
			sortHeader(c, d, list, model.SortTitle, "曲名", 0, true)
			sortHeader(c, d, list, model.SortArtist, "艺术家", 160, false)
			sortHeader(c, d, list, model.SortAlbum, "专辑", 200, false)
			if opts.ShowSource {
				headerLabel(c, d, "来源", sourceWidth)
			}
			sortHeader(c, d, list, model.SortDuration, "时长", 64, false)
			headerLabel(c, d, "", 36)
			headerLabel(c, d, "", 30)
		})
		ui.Box(c).Height(1).FillWidth().Background(d.P.Border)
		table := ui.List(c, list.BindTable(), len(items), func(row int) {
			if row < 0 || row >= len(items) {
				return
			}
			rowTrack := items[row]
			current := state.Player().Track != nil && state.Player().Track.ID == rowTrack.ID
			selected := list.Selected() == row
			rowElement := ui.Row(c).FillWidth().Height(d.RowHeight()).
				AlignItems(ui.Center).PaddingX(tokens.Space8).Radius(tokens.RadiusSM)
			// The list paints its own accent over a chosen row; an opaque
			// token background here keeps the design's soft tint instead.
			switch {
			case selected:
				rowElement.Background(tokens.Blend(d.P.Canvas, d.P.Selected))
			case current:
				rowElement.Background(tokens.Blend(d.P.Canvas, d.P.AccentSoft))
			case rowElement.Hovered():
				rowElement.Background(tokens.Blend(d.P.Canvas, d.P.Hover))
			}
			rowElement.OnClick(func() {
				list.SetSelected(row)
				playFrom(state, list, row)
			})
			rowElement.ContextMenu(func(m *ui.Menu) {
				rowMenu(m, state, rowTrack)
			})
			rowElement.Children(func() {
				// Leading glyph: the current track's state, a play hint for
				// the others. It is not a button; the row itself plays.
				if current {
					NowPlayingBars(c, d, state.Player().Snapshot.Playing)
				} else {
					ui.Icon(c, IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
				}
				title := ui.Column(c).Gap(1).Grow(1).PaddingX(tokens.Space8)
				title.Children(func() {
					text := d.Text(c, tokens.BodyM, rowTrack.Title).TextColor(d.P.TextPrimary).SingleLine()
					if current {
						text.TextColor(d.P.Accent)
					}
				})
				cellText(c, d, rowTrack.Artist, 160, d.P.TextSecondary)
				cellText(c, d, rowTrack.Album, 200, d.P.TextSecondary)
				if opts.ShowSource {
					cellText(c, d, state.SourceName(rowTrack.SourceID), sourceWidth, d.P.TextTertiary)
				}
				ui.Row(c).Width(64).Justify(ui.End).Children(func() {
					d.Text(c, tokens.NumericS, model.FormatDuration(rowTrack.Duration)).TextColor(d.P.TextTertiary)
				})
				favoriteCell(c, d, state, rowTrack)
				moreCell(c, d, state, rowTrack)
			})
		}).Grow(1)
		if table.Submitted() {
			playFrom(state, list, list.Selected())
		}
	})
	list.MaybeRequestMore()
}

func sortHeader(c *ui.Context, d Design, list *model.TrackList, field model.SortField, label string, width float32, grow bool) {
	e := ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space4).PaddingX(tokens.Space4).Cursor(ui.CursorPointer)
	if grow {
		e.Grow(1)
	} else {
		e.Width(width)
	}
	active := list.Sort() == field
	e.OnClick(func() {
		asc := true
		if active {
			asc = !list.Asc()
		}
		list.SetSort(field, asc)
	})
	e.Children(func() {
		color := d.P.TextSecondary
		if active {
			color = d.P.TextPrimary
		}
		d.Text(c, tokens.BodyS, label).TextColor(color)
		if active {
			arrow := "↑"
			if !list.Asc() {
				arrow = "↓"
			}
			d.Text(c, tokens.LabelS, arrow).TextColor(d.P.Accent)
		}
	})
}

func headerLabel(c *ui.Context, d Design, label string, width float32) {
	ui.Row(c).Width(width).AlignItems(ui.Center).Children(func() {
		if label != "" {
			d.Text(c, tokens.BodyS, label).TextColor(d.P.TextSecondary)
		}
	})
}

func cellText(c *ui.Context, d Design, text string, width float32, color ui.Color) {
	ui.Row(c).Width(width).PaddingX(tokens.Space4).AlignItems(ui.Center).Children(func() {
		d.Text(c, tokens.BodyS, text).TextColor(color).SingleLine()
	})
}

func playFrom(state *model.State, list *model.TrackList, row int) {
	all := list.All()
	if row < 0 || row >= len(all) {
		if len(all) == 0 {
			return
		}
		row = 0
	}
	if actions := state.Actions(); actions != nil {
		_ = actions.PlayTracks(all, row)
		rotated := append(append([]library.Track{}, all[row:]...), all[:row]...)
		state.SetQueue(rotated, 0)
	}
}

func favoriteCell(c *ui.Context, d Design, state *model.State, track library.Track) {
	label := "收藏此曲"
	icon := IconHeart
	color := d.P.TextTertiary
	if track.IsFavorite {
		label = "取消收藏此曲"
		icon = IconHeartOn
		color = d.P.Accent
	}
	button := ui.Button(c, "").Width(32).Height(28).Padding(2).Radius(tokens.RadiusXS).
		Label(label).Tooltip(label).Background(ui.Transparent).Border(0, ui.Transparent)
	button.Children(func() {
		ui.Icon(c, icon).FontSize(tokens.IconCompact).TextColor(color)
	})
	if button.Clicked() {
		state.AskKernel("收藏写入（tracks.is_favorite）")
	}
}

func moreCell(c *ui.Context, d Design, state *model.State, track library.Track) {
	button := ui.Button(c, "").Width(28).Height(28).Padding(2).Radius(tokens.RadiusXS).
		Label("更多操作").Tooltip("更多").Background(ui.Transparent).Border(0, ui.Transparent)
	button.Children(func() {
		ui.Icon(c, IconMore).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
	})
	button.Menu(func(m *ui.Menu) { rowMenu(m, state, track) })
}

func rowMenu(m *ui.Menu, state *model.State, track library.Track) {
	if m.Item("播放").Chosen() {
		if actions := state.Actions(); actions != nil {
			_ = actions.PlayTracks([]library.Track{track}, 0)
			state.SetQueue([]library.Track{track}, 0)
		}
	}
	label := "收藏"
	if track.IsFavorite {
		label = "取消收藏"
	}
	if m.Item(label).Chosen() {
		state.AskKernel("收藏写入（tracks.is_favorite）")
	}
	if m.Item("添加到播放列表…").Chosen() {
		state.AskKernel("歌单条目写入（playlist_items）")
	}
	if m.Item("匹配元数据…").Chosen() {
		state.AskKernel("元数据匹配与写回（M5）")
	}
	m.Separator()
	reveal := m.Item("在访达中显示")
	if track.FilePath == "" || track.FilePath[0] != '/' {
		reveal.Disabled(true)
	}
	if reveal.Chosen() {
		if actions := state.Actions(); actions != nil {
			actions.RevealInFinder(track)
		}
	}
}

// TrackRow is the lighter row of the queue, album/artist details and search
// results: cover, title, subtitle and duration, chosen with a click.
func TrackRow(c *ui.Context, d Design, s *model.State, track library.Track, current bool, onClick func()) {
	row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space10).
		Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
	if row.Hovered() {
		row.Background(d.P.Hover)
	}
	if current {
		row.Background(d.P.Selected)
	}
	row.OnClick(onClick)
	row.Children(func() {
		CoverFor(c, d, s, track.CoverArtPath, 36)
		ui.Column(c).Grow(1).Gap(2).Children(func() {
			title := d.Text(c, tokens.BodyM, track.Title).SingleLine()
			if current {
				title.TextColor(d.P.Accent)
			}
			d.Text(c, tokens.BodyS, model.TrackSubtitle(track)).TextColor(d.P.TextSecondary).SingleLine()
		})
		if current {
			NowPlayingBars(c, d, s.Player().Snapshot.Playing)
		}
		d.Text(c, tokens.NumericS, model.FormatDuration(track.Duration)).TextColor(d.P.TextTertiary)
	})
}
