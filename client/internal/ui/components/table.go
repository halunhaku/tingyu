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

// tableColumns is one row's fixed column rhythm (§10-4):
// 序号 22 + 封面 44 + 曲名 330 + 艺术家 170 + 专辑 210 + 弹性 + 时长 56 + 收藏 30.
type tableColumns struct {
	index, cover, title, artist, album, source, duration, favorite float32
}

// total is the width the fixed columns ask for; what is left over is the
// flexible column between 专辑 and 时长.
func (c tableColumns) total() float32 {
	return c.index + c.cover + c.title + c.artist + c.album + c.source + c.duration + c.favorite
}

// tableColumnsFor lays the columns out for the width the table has. The full
// rhythm needs 862 DIP; a narrower table (the minimum window is 900 wide, so
// its table is 600) drops 专辑, then 来源, then 艺术家, then narrows 曲名, so
// the minimum window keeps the row readable instead of clipping it.
func tableColumnsFor(avail float32, showSource bool) tableColumns {
	c := tableColumns{
		index:    tokens.TableIndex,
		cover:    tokens.TableCoverCol,
		title:    tokens.TableTitle,
		artist:   tokens.TableArtist,
		album:    tokens.TableAlbum,
		duration: tokens.TableDuration,
		favorite: tokens.TableFavorite,
	}
	if showSource {
		c.source = tokens.TableSource
	}
	if avail <= 0 {
		return c
	}
	if avail < c.total() {
		c.album = 0
	}
	if avail < c.total() {
		c.source = 0
	}
	if avail < c.total() {
		c.artist = 0
	}
	if avail < c.total() {
		c.title = avail - (c.total() - c.title)
		if c.title < 160 {
			c.title = 160
		}
	}
	return c
}

// tableWidth is the width the table lays out in: the window minus the sidebar
// and the page's insets.
func tableWidth(c *ui.Context, d Design) float32 {
	width, _ := c.Size()
	return width - d.SidebarWidth() - 2*d.PagePadding()
}

// TrackTable is the shared track list: a fixed header whose labels sort, and a
// virtualised list of rows (only the visible ones are built). A single click
// plays from that row, as the Flutter client does; the leading glyph shows the
// current track and Enter on the keyboard plays the chosen row.
func TrackTable(c *ui.Context, d Design, opts TableOptions) {
	list := opts.List
	state := opts.State
	items := list.Items()
	width := tableWidth(c, d)
	cols := tableColumnsFor(width, opts.ShowSource)
	ui.Column(c).Width(width).Grow(1).Gap(0).Children(func() {
		header := ui.Row(c).FillWidth().Height(tokens.TableHeaderHeight).AlignItems(ui.Center)
		header.Children(func() {
			ui.Box(c).Width(cols.index)
			ui.Box(c).Width(cols.cover)
			sortHeader(c, d, list, model.SortTitle, "曲名", cols.title, true)
			if cols.artist > 0 {
				sortHeader(c, d, list, model.SortArtist, "艺术家", cols.artist, false)
			}
			if cols.album > 0 {
				sortHeader(c, d, list, model.SortAlbum, "专辑", cols.album, false)
			}
			ui.Spacer(c)
			if opts.ShowSource && cols.source > 0 {
				headerLabel(c, d, "来源", cols.source)
			}
			sortHeader(c, d, list, model.SortDuration, "时长", cols.duration, false)
			headerLabel(c, d, "", cols.favorite)
		})
		// tableEl is the list itself, which the rows ask for the keyboard focus:
		// at paint time, when the row's ring is due, the list holds its state.
		var tableEl ui.Element
		table := ui.List(c, list.BindTable(), len(items), func(row int) {
			if row < 0 || row >= len(items) {
				return
			}
			rowTrack := items[row]
			current := state.Player().Track != nil && state.Player().Track.ID == rowTrack.ID
			selected := list.Selected() == row
			rowElement := ui.Row(c).FillWidth().Height(d.RowHeight()).
				AlignItems(ui.Center).PaddingX(tokens.Space2).Radius(tokens.RadiusSM)
			// Three states (§4.4/§10-5): hover is 5% ink, the chosen row is the
			// raised surface with a border, and the playing row is the accent
			// tint with an accent title and the little equalizer. The page behind
			// is opaque, so the translucent tokens are blended once here.
			switch {
			case selected:
				rowElement.Background(d.P.SurfaceRaised).Border(1, d.P.Border)
			case current:
				rowElement.Background(tokens.Blend(d.P.Canvas, d.P.AccentSoft))
			case rowElement.Hovered():
				rowElement.Background(tokens.Blend(d.P.Canvas, d.P.Hover))
			}
			// The keyboard's cursor also shows a 2 px accent ring (§4.4, §11).
			// The ring is drawn at paint time, when the row's state exists: a
			// row built during layout cannot ask whether the focus is within it.
			if selected {
				rowElement.DrawOver(func(p *ui.Painter, r ui.Rect) {
					if !tableEl.FocusVisible() {
						return
					}
					p.FocusRing(ui.Rect{X: r.X + 2, Y: r.Y + 2, W: r.W - 4, H: r.H - 4},
						[4]float32{tokens.RadiusXS, tokens.RadiusXS, tokens.RadiusXS, tokens.RadiusXS})
				})
			}
			rowElement.OnClick(func() {
				list.SetSelected(row)
				playFrom(state, list, row)
			})
			rowElement.ContextMenu(func(m *ui.Menu) {
				rowMenu(m, state, rowTrack, opts, row)
			})
			rowElement.Children(func() {
				// Leading glyph: the current track's equalizer, a play hint for
				// the others. It is not a button; the row itself plays.
				lead := ui.Box(c).Width(cols.index).Center()
				lead.Children(func() {
					if current {
						NowPlayingBars(c, d, state.Player().Snapshot.Playing)
					} else {
						ui.Icon(c, IconPlay).FontSize(11).TextColor(d.P.TextTertiary)
					}
				})
				ui.Box(c).Width(cols.cover).Children(func() {
					tableCoverCell(c, d, state, rowTrack)
				})
				title := ui.Row(c).Width(cols.title).PaddingX(tokens.Space4).AlignItems(ui.Center)
				title.Children(func() {
					text := d.Text(c, tokens.Body, rowTrack.Title).TextColor(d.P.TextPrimary).SingleLine()
					if current {
						text.TextColor(d.P.Accent)
					}
				})
				if cols.artist > 0 {
					cellText(c, d, rowTrack.Artist, cols.artist, d.P.TextSecondary)
				}
				if cols.album > 0 {
					cellText(c, d, rowTrack.Album, cols.album, d.P.TextTertiary)
				}
				ui.Spacer(c)
				if opts.ShowSource && cols.source > 0 {
					cellText(c, d, state.SourceName(rowTrack.SourceID), cols.source, d.P.TextTertiary)
				}
				ui.Row(c).Width(cols.duration).Justify(ui.End).Children(func() {
					d.Text(c, tokens.Num, model.FormatDuration(rowTrack.Duration)).TextColor(d.P.TextTertiary)
				})
				favoriteCell(c, d, state, rowTrack, cols.favorite)
			})
		}).Grow(1)
		// The ring belongs to the row the keys are on, not around the whole table.
		table.FocusRing(false)
		tableEl = table
		if table.Submitted() {
			playFrom(state, list, list.Selected())
		}
	})
	list.MaybeRequestMore()
}

// tableCoverCell is the table's cover: 30 DIP in a 44 DIP column, radius 4
// (§10-5). A track without one keeps the column's space so rows do not jump.
func tableCoverCell(c *ui.Context, d Design, state *model.State, track library.Track) {
	if bitmap := state.CoverBitmap(track.CoverArtPath); bitmap != nil {
		ui.Image(c, bitmap).Size(tokens.TableCover, tokens.TableCover).Fit(ui.Cover).Radius(tokens.RadiusXS)
	} else {
		ui.Box(c).Size(tokens.TableCover, tokens.TableCover)
	}
}

func sortHeader(c *ui.Context, d Design, list *model.TrackList, field model.SortField, label string, width float32, grow bool) {
	e := ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space4).Cursor(ui.CursorPointer).Focusable()
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
		color := d.P.TextTertiary
		if active {
			color = d.P.TextPrimary
		}
		d.Text(c, tokens.Overline, label).TextColor(color)
		if active {
			arrow := "↑"
			if !list.Asc() {
				arrow = "↓"
			}
			d.Text(c, tokens.Overline, arrow).TextColor(d.P.Accent)
		}
	})
}

func headerLabel(c *ui.Context, d Design, label string, width float32) {
	ui.Row(c).Width(width).AlignItems(ui.Center).Children(func() {
		if label != "" {
			d.Text(c, tokens.Overline, label).TextColor(d.P.TextTertiary)
		}
	})
}

func cellText(c *ui.Context, d Design, text string, width float32, color ui.Color) {
	ui.Row(c).Width(width).PaddingX(tokens.Space4).AlignItems(ui.Center).Children(func() {
		d.Text(c, tokens.Small, text).TextColor(color).SingleLine()
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

func favoriteCell(c *ui.Context, d Design, state *model.State, track library.Track, width float32) {
	label := "收藏此曲"
	icon := IconHeart
	color := d.P.TextTertiary
	if track.IsFavorite {
		label = "取消收藏此曲"
		icon = IconHeartOn
		color = d.P.Accent
	}
	cell := ui.Box(c).Width(width).Center()
	cell.Children(func() {
		button := ui.Button(c, "").Size(width, 28).Padding(2).Radius(tokens.RadiusXS).
			Label(label).Tooltip(label).Background(ui.Transparent).Border(0, ui.Transparent)
		button.Children(func() {
			ui.Icon(c, icon).FontSize(tokens.IconCompact).TextColor(color)
		})
		if button.Clicked() {
			state.ToggleFavorite(track)
		}
	})
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
	}).Radius(tokens.RadiusSM).FontSize(12).Height(tokens.ToolbarControl)
}

// TrackRow is the lighter row of the queue, album/artist details and search
// results: cover, title, subtitle and duration, chosen with a click.
func TrackRow(c *ui.Context, d Design, s *model.State, track library.Track, current bool, onClick func()) ui.Element {
	row := ui.Row(c).FillWidth().Height(tokens.TableRowHeight).AlignItems(ui.Center).Gap(tokens.Space10).
		Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
	if row.Hovered() {
		row.Background(tokens.Blend(d.P.Canvas, d.P.Hover))
	}
	if current {
		row.Background(tokens.Blend(d.P.Canvas, d.P.AccentSoft))
	}
	row.OnClick(onClick)
	row.Children(func() {
		CoverFor(c, d, s, track.CoverArtPath, tokens.TableCover)
		ui.Column(c).Grow(1).Gap(2).Children(func() {
			title := d.Text(c, tokens.Body, track.Title).SingleLine()
			if current {
				title.TextColor(d.P.Accent)
			}
			d.Text(c, tokens.Small, model.TrackSubtitle(track)).TextColor(d.P.TextSecondary).SingleLine()
		})
		if current {
			NowPlayingBars(c, d, s.Player().Snapshot.Playing)
		}
		d.Text(c, tokens.Num, model.FormatDuration(track.Duration)).TextColor(d.P.TextTertiary)
	})
	return row
}
