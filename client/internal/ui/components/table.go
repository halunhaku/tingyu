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
	// PlaylistID, when set, makes the rows a playlist's: their menu offers
	// 移出歌单 and the two reorder steps, and the list is in saved order.
	PlaylistID string
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
			// M5's cover column (the token was reserved in M4): cover then
			// title, as the Flutter table lays it out.
			ui.Box(c).Width(tokens.TableCoverColumn + tokens.Space10)
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
				rowMenu(m, state, rowTrack, opts, row)
			})
			rowElement.Children(func() {
				// Leading glyph: the current track's state, a play hint for
				// the others. It is not a button; the row itself plays.
				if current {
					NowPlayingBars(c, d, state.Player().Snapshot.Playing)
				} else {
					ui.Icon(c, IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
				}
				tableCoverCell(c, d, state, rowTrack)
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
				moreCell(c, d, state, rowTrack, opts, row)
			})
		}).Grow(1)
		if table.Submitted() {
			playFrom(state, list, list.Selected())
		}
	})
	list.MaybeRequestMore()
}

// tableCoverCell is the table's cover column: the cover when the track has
// one, otherwise the reserved space (an empty block per row would read as a
// wall of placeholders in a ten-thousand-row library).
func tableCoverCell(c *ui.Context, d Design, state *model.State, track library.Track) {
	if bitmap := state.CoverBitmap(track.CoverArtPath); bitmap != nil {
		ui.Image(c, bitmap).Size(tokens.TableCoverColumn, tokens.TableCoverColumn).
			Fit(ui.Cover).Radius(tokens.RadiusXS)
	} else {
		ui.Box(c).Width(tokens.TableCoverColumn).Height(tokens.TableCoverColumn)
	}
	ui.Box(c).Width(tokens.Space10)
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

// playFrom plays the list from a row. The rows come from the query, not from
// the pages loaded so far: a click on row 3 of page 1 must still queue the
// whole list (the Flutter page's 「播放全部先补齐查询结果」).
func playFrom(state *model.State, list *model.TrackList, row int) {
	all := state.AllOf(list)
	if len(all) == 0 {
		return
	}
	if row < 0 || row >= len(all) {
		row = 0
	}
	state.Play(all, row)
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
		state.ToggleFavorite(track)
	}
}

func moreCell(c *ui.Context, d Design, state *model.State, track library.Track, opts TableOptions, row int) {
	button := ui.Button(c, "").Width(28).Height(28).Padding(2).Radius(tokens.RadiusXS).
		Label("更多操作").Tooltip("更多").Background(ui.Transparent).Border(0, ui.Transparent)
	button.Children(func() {
		ui.Icon(c, IconMore).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
	})
	button.Menu(func(m *ui.Menu) { rowMenu(m, state, track, opts, row) })
}

func rowMenu(m *ui.Menu, state *model.State, track library.Track, opts TableOptions, row int) {
	if m.Item("播放").Chosen() {
		state.Play([]library.Track{track}, 0)
	}
	label := "收藏"
	if track.IsFavorite {
		label = "取消收藏"
	}
	if m.Item(label).Chosen() {
		state.ToggleFavorite(track)
	}
	addToPlaylistItem(m, state, []library.Track{track})
	if opts.PlaylistID != "" {
		m.Separator()
		if m.Item("移出歌单").Chosen() {
			state.RemoveFromPlaylist(row)
		}
		up := m.Item("上移").Disabled(row <= 0)
		if up.Chosen() {
			state.MovePlaylistItem(row, row-1)
		}
		down := m.Item("下移").Disabled(row >= opts.List.Total()-1)
		if down.Chosen() {
			state.MovePlaylistItem(row, row+1)
		}
	}
	if m.Item("匹配元数据…").Chosen() {
		state.OpenMatch(track)
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

// addToPlaylistItem is the 「添加到播放列表」 submenu, shared by the row menu and
// the album/stage headers: the playlists come from the library, and choosing
// one appends the tracks through the app's write path.
func addToPlaylistItem(m *ui.Menu, state *model.State, tracks []library.Track) {
	playlists := state.Playlists()
	if len(playlists) == 0 {
		m.Item("添加到播放列表…").Disabled(true)
		return
	}
	m.Submenu("添加到播放列表", func(sub *ui.Menu) {
		for _, playlist := range playlists {
			playlist := playlist
			item := sub.Item(playlist.Name)
			if item.Chosen() {
				state.AddToPlaylist(playlist.ID, tracks)
			}
		}
	})
}

// AddToPlaylistButton is the album/stage 「加入歌单」 control.
func AddToPlaylistButton(c *ui.Context, d Design, state *model.State, tracks []library.Track) {
	playlists := state.Playlists()
	if len(playlists) == 0 {
		if b := d.Button(c, "加入歌单"); b.Clicked() {
			state.SetNotice("还没有歌单：先在「歌单」页新建一个，再把曲目加进去")
		}
		return
	}
	ui.MenuButton(c, "加入歌单", func(m *ui.Menu) {
		for _, playlist := range playlists {
			playlist := playlist
			if m.Item(playlist.Name).Chosen() {
				state.AddToPlaylist(playlist.ID, tracks)
			}
		}
	}).Radius(tokens.RadiusSM).FontSize(13)
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
