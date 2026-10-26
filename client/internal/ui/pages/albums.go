package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// AlbumGrid renders album cards in an adaptive grid (as many 150-wide columns
// as fit). A card's cover opens the album; its play button plays the album.
// The grid pages like every other list: near its last loaded card it asks the
// kernel for the next page (GridView builds only the cards in view, so the
// last visible card is the trigger).
func AlbumGrid(c *ui.Context, d components.Design, s *model.State, list *model.AlbumList) {
	albums := list.Items()
	grid := s.AlbumsList()
	selected, _ := s.Transient("albumGridSelected").(*int)
	if selected == nil {
		n := -1
		selected = &n
		s.SetTransient("albumGridSelected", selected)
	}
	grid.Selected = selected
	grid.Key = func(i int) any {
		if i < 0 || i >= len(albums) {
			return i
		}
		return albums[i].Key
	}
	grid.Label = func(i int) string {
		if i < 0 || i >= len(albums) {
			return ""
		}
		return albums[i].Name
	}
	ui.GridView(c, grid, len(albums), 150, 238, func(i int) {
		if i < 0 || i >= len(albums) {
			return
		}
		if i >= len(albums)-4 {
			list.RequestMore()
		}
		album := albums[i]
		card := ui.Column(c).Gap(tokens.Space8).Focusable().OnClick(func() { s.OpenAlbum(album) })
		card.Children(func() {
			components.CoverFill(c, d, s, album.Cover, tokens.RadiusLG)
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space4).Children(func() {
				ui.Column(c).Gap(2).Grow(1).Children(func() {
					d.Text(c, tokens.Body, album.Name).TextColor(d.P.TextPrimary).SingleLine()
					meta := album.Artist + " · " + model.FormatCount(album.TrackCount(), "首")
					d.Text(c, tokens.Small, meta).TextColor(d.P.TextSecondary).SingleLine()
				})
				play := ui.Button(c, "").Padding(4).Radius(tokens.RadiusXS).
					Label("播放专辑 " + album.Name).Tooltip("播放专辑")
				play.Children(func() {
					ui.Icon(c, components.IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
				})
				if play.Clicked() {
					PlayAll(s, s.AlbumTracks(album))
				}
			})
		})
	}).Grow(1)
}

// Albums is the album browser.
func Albums(c *ui.Context, d components.Design, s *model.State) {
	list := s.Albums()
	Page(c, d, s, "专辑", albumSummary(list), nil, nil, func() {
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if list.Total() == 0 {
			components.Empty(c, d, components.IconMusic, "还没有专辑",
				"扫描一个音乐目录后，曲目会按「艺术家 + 专辑」自动归并。", func() {
					AddDirectoryButton(c, d, s)
				})
			return
		}
		AlbumGrid(c, d, s, list)
	})
}

func albumSummary(list *model.AlbumList) string {
	if list.Total() <= 0 {
		return ""
	}
	return model.FormatCount(list.Total(), "张")
}

// AlbumDetail is one album: cover, metadata and its tracks. A click on a row
// plays the album from that track.
func AlbumDetail(c *ui.Context, d components.Design, s *model.State) {
	detail := s.AlbumDetail()
	back := s.Back
	if detail == nil {
		Page(c, d, s, "专辑", "", back, nil, func() {
			components.Empty(c, d, components.IconMusic, "没有可显示的专辑", "回到专辑列表重新选择。", nil)
		})
		return
	}
	album := detail.Album
	tracks := detail.Tracks
	actions := func() {
		if b := d.Button(c, "播放"); b.Clicked() {
			PlayAll(s, tracks)
		}
		components.AddToPlaylistButton(c, d, s, tracks)
	}
	years := ""
	if album.Year > 0 {
		years = " · " + itoa(album.Year)
	}
	subtitle := album.Artist + years + " · " + model.FormatCount(album.TrackCount(), "首") + " · " + model.FormatTotal(album.Duration)
	Page(c, d, s, album.Name, subtitle, back, actions, func() {
		ui.Row(c).Gap(tokens.Space20).AlignItems(ui.End).Height(168).Children(func() {
			components.Cover(c, d, s, album.Cover, 160, tokens.RadiusLG)
			ui.Column(c).Gap(tokens.Space6).Grow(1).Children(func() {
				d.Text(c, tokens.H3, album.Artist).TextColor(d.P.TextPrimary)
				d.Text(c, tokens.Small, subtitle).TextColor(d.P.TextSecondary)
				ui.Row(c).Gap(tokens.Space8).Children(func() {
					if b := d.Button(c, "在艺人中查看"); b.Clicked() {
						if artist := s.ArtistByName(album.Artist); artist != nil {
							s.OpenArtist(*artist)
						}
					}
				})
			})
		})
		if len(tracks) == 0 {
			components.Empty(c, d, components.IconMusic, "没有可播放的曲目", "这张专辑的曲目不在曲库中。", nil)
			return
		}
		list := s.DetailList()
		table := ui.List(c, list, len(tracks), func(row int) {
			track := tracks[row]
			components.TrackRow(c, d, s, track, s.Player().Track != nil && s.Player().Track.ID == track.ID, func() {
				PlayFrom(s, tracks, row)
			})
		}).Grow(1)
		if table.Submitted() {
			if row := *list.Selected; row >= 0 && row < len(tracks) {
				PlayFrom(s, tracks, row)
			}
		}
	})
}

// itoa is a tiny local int formatter (keeps the pages package free of fmt for
// one call).
func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
