package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// AlbumGrid renders album cards in an adaptive grid (as many 150-wide columns
// as fit). A card's cover opens the album; its play button plays the album.
func AlbumGrid(c *ui.Context, d components.Design, s *model.State, albums []model.Album) {
	grid := s.AlbumsList()
	selected, _ := s.Transient("albumGridSelected").(*int)
	if selected == nil {
		n := -1
		selected = &n
		s.SetTransient("albumGridSelected", selected)
	}
	grid.Selected = selected
	grid.Key = func(i int) any { return albums[i].Key }
	grid.Label = func(i int) string { return albums[i].Name }
	ui.GridView(c, grid, len(albums), 150, 238, func(i int) {
		if i < 0 || i >= len(albums) {
			return
		}
		album := albums[i]
		card := ui.Column(c).Gap(tokens.Space8).OnClick(func() { s.OpenAlbum(album) })
		card.Children(func() {
			components.CoverFill(c, d, s, album.Cover, tokens.RadiusLG)
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space4).Children(func() {
				ui.Column(c).Gap(2).Grow(1).Children(func() {
					d.Text(c, tokens.BodyM, album.Name).TextColor(d.P.TextPrimary).SingleLine()
					meta := album.Artist + " · " + model.FormatCount(album.TrackCount(), "首")
					d.Text(c, tokens.BodyS, meta).TextColor(d.P.TextSecondary).SingleLine()
				})
				play := ui.Button(c, "").Padding(4).Radius(tokens.RadiusXS).
					Label("播放专辑 " + album.Name).Tooltip("播放专辑")
				play.Children(func() {
					ui.Icon(c, components.IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
				})
				if play.Clicked() {
					PlayAll(s, album.Tracks)
				}
			})
		})
	}).Grow(1)
}

// Albums is the album browser.
func Albums(c *ui.Context, d components.Design, s *model.State) {
	albums := s.Albums()
	Page(c, d, s, "专辑", model.FormatCount(len(albums), "张"), nil, nil, func() {
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if len(albums) == 0 {
			components.Empty(c, d, components.IconMusic, "还没有专辑",
				"扫描一个音乐目录后，曲目会按「艺术家 + 专辑」自动归并。", func() {
					AddDirectoryButton(c, d, s)
				})
			return
		}
		AlbumGrid(c, d, s, albums)
	})
}

// AlbumDetail is one album: cover, metadata and its tracks. A click on a row
// plays the album from that track.
func AlbumDetail(c *ui.Context, d components.Design, s *model.State) {
	album := s.AlbumDetail()
	back := s.Back
	if album == nil {
		Page(c, d, s, "专辑", "", back, nil, func() {
			components.Empty(c, d, components.IconMusic, "没有可显示的专辑", "回到专辑列表重新选择。", nil)
		})
		return
	}
	actions := func() {
		if b := d.Button(c, "播放"); b.Clicked() {
			PlayAll(s, album.Tracks)
		}
		if b := d.Button(c, "加入歌单"); b.Clicked() {
			s.AskKernel("歌单条目写入（playlist_items）")
		}
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
				d.Text(c, tokens.TitleM, album.Artist).TextColor(d.P.TextPrimary)
				d.Text(c, tokens.BodyS, subtitle).TextColor(d.P.TextSecondary)
				ui.Row(c).Gap(tokens.Space8).Children(func() {
					if b := d.Button(c, "在艺人中查看"); b.Clicked() {
						if artist := s.ArtistByName(album.Artist); artist != nil {
							s.OpenArtist(*artist)
						}
					}
				})
			})
		})
		if len(album.Tracks) == 0 {
			components.Empty(c, d, components.IconMusic, "没有可播放的曲目", "这张专辑的曲目不在曲库中。", nil)
			return
		}
		list := s.DetailList()
		list.Selected = nil
		ui.List(c, list, len(album.Tracks), func(row int) {
			track := album.Tracks[row]
			components.TrackRow(c, d, s, track, s.Player().Track != nil && s.Player().Track.ID == track.ID, func() {
				PlayFrom(s, album.Tracks, row)
			})
		}).Grow(1)
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
