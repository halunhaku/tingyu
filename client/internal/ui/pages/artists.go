package pages

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Artists is the artist browser, a virtualised list of rows fed by the SQL
// aggregate (one page at a time, near the end of the loaded rows).
func Artists(c *ui.Context, d components.Design, s *model.State) {
	artists := s.Artists().Items()
	selected, _ := s.Transient("artistListSelected").(*int)
	if selected == nil {
		n := -1
		selected = &n
		s.SetTransient("artistListSelected", selected)
	}
	list := s.ArtistsList()
	list.Selected = selected
	list.Key = func(i int) any {
		if i < 0 || i >= len(artists) {
			return i
		}
		return artists[i].Key
	}
	list.Label = func(i int) string {
		if i < 0 || i >= len(artists) {
			return ""
		}
		return artists[i].Name
	}
	summary := ""
	if s.Artists().Total() > 0 {
		summary = model.FormatCount(s.Artists().Total(), "位")
	}
	Page(c, d, s, "艺术家", summary, nil, nil, func() {
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if s.Artists().Total() == 0 {
			components.Empty(c, d, components.IconMusic, "还没有艺术家",
				"扫描一个音乐目录后，曲目会按艺术家归并。", func() {
					AddDirectoryButton(c, d, s)
				})
			return
		}
		listElement := ui.List(c, list, len(artists), func(i int) {
			artist := artists[i]
			if i >= len(artists)-4 {
				s.Artists().RequestMore()
			}
			row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
				Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM).Focusable()
			if row.Hovered() {
				row.Background(d.P.Hover)
			}
			row.OnClick(func() { s.OpenArtist(artist) })
			row.Children(func() {
				components.Cover(c, d, s, artist.Cover, 44, 22)
				ui.Column(c).Gap(2).Grow(1).Children(func() {
					d.Text(c, tokens.BodyM, artist.Name).TextColor(d.P.TextPrimary).SingleLine()
					d.Textf(c, tokens.BodyS, "%d 首 · %d 张专辑 · %s",
						artist.Count, artist.Albums, model.FormatTotal(artist.Duration)).
						TextColor(d.P.TextSecondary).SingleLine()
				})
				play := ui.Button(c, "").Padding(5).Radius(tokens.RadiusXS).
					Label("播放 " + artist.Name).Tooltip("播放全部")
				play.Children(func() {
					ui.Icon(c, components.IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
				})
				if play.Clicked() {
					PlayAll(s, s.ArtistTracks(artist))
				}
			})
		})
		listElement.Grow(1)
		if listElement.Submitted() {
			if *selected >= 0 && *selected < len(artists) {
				s.OpenArtist(artists[*selected])
			}
		}
	})
}

// ArtistDetail is one artist: play all, an album rail and the tracks, which
// collapse to 20 rows until 「全部展开」.
func ArtistDetail(c *ui.Context, d components.Design, s *model.State) {
	detail := s.ArtistDetail()
	back := s.Back
	if detail == nil {
		Page(c, d, s, "艺术家", "", back, nil, func() {
			components.Empty(c, d, components.IconMusic, "没有可显示的艺术家", "回到艺术家列表重新选择。", nil)
		})
		return
	}
	artist := detail.Artist
	actions := func() {
		if b := d.Button(c, "播放全部"); b.Clicked() {
			PlayAll(s, s.ArtistTracks(artist))
		}
		if artist.Count > 20 {
			label := "全部展开"
			if s.ArtistExpanded() {
				label = "收起"
			}
			if b := d.Button(c, label); b.Clicked() {
				s.ToggleArtistExpanded()
			}
		}
	}
	Page(c, d, s, artist.Name, model.FormatCount(artist.Count, "首"), back, actions, func() {
		ui.Row(c).Gap(tokens.Space16).AlignItems(ui.Center).Children(func() {
			components.Cover(c, d, s, artist.Cover, 88, 44)
			ui.Column(c).Gap(tokens.Space4).Children(func() {
				d.Textf(c, tokens.BodyM, "%d 张专辑 · %d 首", artist.Albums, artist.Count).
					TextColor(d.P.TextPrimary)
				d.Text(c, tokens.BodyS, model.FormatTotal(artist.Duration)).TextColor(d.P.TextSecondary)
			})
		})
		albums := detail.Albums.Items()
		if len(albums) > 0 {
			components.SectionTitle(c, d, "专辑", "")
			ui.ScrollHorizontal(c).Height(176).Children(func() {
				for _, album := range albums {
					album := album
					ui.Column(c).Width(128).Gap(tokens.Space6).Children(func() {
						card := ui.Column(c).Gap(tokens.Space4).Focusable().OnClick(func() { s.OpenAlbum(album) })
						card.Children(func() {
							components.CoverFill(c, d, s, album.Cover, tokens.RadiusMD)
							d.Text(c, tokens.BodyS, album.Name).TextColor(d.P.TextPrimary).SingleLine()
						})
					})
				}
			})
		}
		components.SectionTitle(c, d, "全部曲目", "")
		tracks := detail.Tracks
		list := s.DetailList()
		table := ui.List(c, list, len(tracks), func(row int) {
			track := tracks[row]
			components.TrackRow(c, d, s, track, s.Player().Track != nil && s.Player().Track.ID == track.ID, func() {
				PlayFrom(s, s.ArtistTracks(artist), row)
			})
		}).Grow(1)
		if table.Submitted() {
			if row := *list.Selected; row >= 0 && row < len(tracks) {
				PlayFrom(s, s.ArtistTracks(artist), row)
			}
		}
	})
}

// ArtistsHeaderInitial is the fallback avatar text for an artist without a
// cover: the first rune of the name.
func ArtistsHeaderInitial(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "?"
	}
	for _, r := range name {
		return string(r)
	}
	return "?"
}
