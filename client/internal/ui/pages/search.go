package pages

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Search is the search page: 250 ms debounce, four groups of SQL matches with
// previews and 「查看全部」, and a 40-per-page list for a single scope.
func Search(c *ui.Context, d components.Design, s *model.State) {
	search := s.Search()
	results := search.Results()
	actions := func() {
		if search.Query != "" {
			if b := d.Button(c, "清除"); b.Clicked() {
				search.SetQuery("")
				s.SetSidebarQuery("")
			}
		}
	}
	Page(c, d, s, "搜索", searchHeadline(search), nil, actions, func() {
		field := d.SearchBox(c, &search.Input, "曲库搜索", "搜索歌曲、专辑、艺术家、歌单", true,
			func() { search.OnInput(s.Now()) },
			func() { s.PlaySearchHit() }, nil).FillWidth()
		_ = field
		if search.Pending() {
			c.After(model.SearchDebounceTime)
		}
		scope := search.Scope
		seg := ui.Segmented(c, &scope, model.ScopeLabels...).Radius(tokens.RadiusSM).FontSize(13)
		if seg.Changed() {
			search.ShowScope(scope)
		}
		if strings.TrimSpace(search.Input) == "" {
			recentSearches(c, d, s)
			return
		}
		if search.NeedsResults() || search.Query != strings.TrimSpace(search.Input) {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Padding(tokens.Space12).Children(func() {
				ui.Spinner(c)
				d.Text(c, tokens.Small, "正在搜索…").TextColor(d.P.TextSecondary)
			})
			return
		}
		if results.SongTotal+results.AlbumTotal+results.ArtistTotal+results.PlaylistTotal == 0 {
			components.Empty(c, d, components.IconSearch, "没有找到匹配的结果",
				"换一个关键词，或清除搜索。", func() {
					if b := d.Button(c, "清除搜索"); b.Clicked() {
						search.SetQuery("")
						s.SetSidebarQuery("")
					}
				})
			return
		}
		switch search.Scope {
		case model.ScopeSongs:
			songsTable(c, d, s)
		case model.ScopeAlbums:
			albumsResults(c, d, s)
		case model.ScopeArtists:
			artistsResults(c, d, s)
		case model.ScopePlaylists:
			playlistsResults(c, d, s)
		default:
			allResults(c, d, s, results)
		}
	})
}

func searchHeadline(search *model.SearchState) string {
	if search.Query == "" {
		return ""
	}
	return "“" + search.Query + "”"
}

func recentSearches(c *ui.Context, d components.Design, s *model.State) {
	search := s.Search()
	ui.Column(c).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			d.Text(c, tokens.H3, "最近搜索").TextColor(d.P.TextPrimary)
			ui.Spacer(c)
			if len(search.Recent()) > 0 {
				if b := d.Button(c, "清除"); b.Clicked() {
					search.ForgetRecent()
				}
			}
		})
		if len(search.Recent()) == 0 {
			d.Text(c, tokens.Small, "输入关键词搜索歌曲、专辑、艺术家与歌单。").TextColor(d.P.TextSecondary)
			return
		}
		ui.Row(c).Gap(tokens.Space8).Wrap().Children(func() {
			for _, term := range search.Recent() {
				term := term
				chip := ui.Button(c, term).Radius(tokens.RadiusFull).FontSize(12)
				if chip.Clicked() {
					search.SetQuery(term)
				}
			}
		})
	})
}

func songsTable(c *ui.Context, d components.Design, s *model.State) {
	search := s.Search()
	list := search.OwnSongs()
	components.TrackTable(c, d, components.TableOptions{State: s, List: list})
	components.Pager(c, d, list, "")
}

func albumsResults(c *ui.Context, d components.Design, s *model.State) {
	list := s.Search().OwnAlbums()
	albums := list.Items()
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for i, album := range albums {
				album := album
				if i >= len(albums)-4 {
					list.RequestMore()
				}
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
					Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM).Focusable()
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenAlbum(album) })
				row.Children(func() {
					components.Cover(c, d, s, album.Cover, 44, tokens.RadiusSM)
					ui.Column(c).Gap(2).Grow(1).Children(func() {
						d.Text(c, tokens.Body, album.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Text(c, tokens.Small, album.Artist+" · "+model.FormatCount(album.TrackCount(), "首")).
							TextColor(d.P.TextSecondary).SingleLine()
					})
					play := ui.Button(c, "").Padding(5).Radius(tokens.RadiusXS).
						Label("播放专辑 " + album.Name).Tooltip("播放专辑")
					play.Children(func() {
						ui.Icon(c, components.IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
					})
					if play.Clicked() {
						PlayAll(s, s.AlbumTracks(album))
					}
				})
			}
			components.LoadMore(c, d, len(albums), list.Total(), list.Done(), list.Loading(), list.RequestMore)
		})
	})
}

func artistsResults(c *ui.Context, d components.Design, s *model.State) {
	list := s.Search().OwnArtists()
	artists := list.Items()
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for i, artist := range artists {
				artist := artist
				if i >= len(artists)-4 {
					list.RequestMore()
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
						d.Text(c, tokens.Body, artist.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Textf(c, tokens.Small, "%d 首 · %d 张专辑", artist.Count, artist.Albums).
							TextColor(d.P.TextSecondary)
					})
				})
			}
			components.LoadMore(c, d, len(artists), list.Total(), list.Done(), list.Loading(), list.RequestMore)
		})
	})
}

func playlistsResults(c *ui.Context, d components.Design, s *model.State) {
	search := s.Search()
	rows := search.PlaylistRows()
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for _, playlist := range rows {
				playlist := playlist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
					Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM).Focusable()
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenPlaylist(playlist) })
				row.Children(func() {
					ui.Box(c).Size(44, 44).Radius(tokens.RadiusSM).Background(d.P.SurfaceSunken).Center().Children(func() {
						ui.Icon(c, components.IconQueue).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
					})
					ui.Column(c).Gap(2).Grow(1).Children(func() {
						d.Text(c, tokens.Body, playlist.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Textf(c, tokens.Small, "%d 首", playlist.TrackCount).TextColor(d.P.TextSecondary)
					})
				})
			}
			components.LoadMore(c, d, len(rows), len(search.Results().Playlists),
				!search.HasMorePlaylists(), false, search.RequestMorePlaylists)
		})
	})
}

func allResults(c *ui.Context, d components.Design, s *model.State, results model.SearchResults) {
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space16).Children(func() {
			groupHeader(c, d, "歌曲", results.SongTotal, func() {
				s.Search().ShowScope(model.ScopeSongs)
			})
			songs := results.Songs
			for i, track := range songs {
				i, track := i, track
				components.TrackRow(c, d, s, track, s.Player().Track != nil && s.Player().Track.ID == track.ID, func() {
					PlayFrom(s, songs, i)
				}).Focusable()
			}
			if len(songs) == 0 {
				emptyGroup(c, d, "没有匹配的歌曲")
			}
			groupHeader(c, d, "专辑", results.AlbumTotal, func() {
				s.Search().ShowScope(model.ScopeAlbums)
			})
			if len(results.Albums) == 0 {
				emptyGroup(c, d, "没有匹配的专辑")
			}
			ui.ScrollHorizontal(c).Height(178).Children(func() {
				for _, album := range results.Albums {
					album := album
					card := ui.Column(c).Width(132).Gap(tokens.Space6).Focusable().OnClick(func() { s.OpenAlbum(album) })
					card.Children(func() {
						components.CoverFill(c, d, s, album.Cover, tokens.RadiusMD)
						d.Text(c, tokens.Small, album.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Text(c, tokens.Overline, album.Artist).TextColor(d.P.TextSecondary).SingleLine()
					})
				}
			})
			groupHeader(c, d, "艺术家", results.ArtistTotal, func() {
				s.Search().ShowScope(model.ScopeArtists)
			})
			if len(results.Artists) == 0 {
				emptyGroup(c, d, "没有匹配的艺术家")
			}
			for _, artist := range results.Artists {
				artist := artist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space10).
					Padding(tokens.Space6, tokens.Space4).Radius(tokens.RadiusSM).Focusable()
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenArtist(artist) })
				row.Children(func() {
					components.Cover(c, d, s, artist.Cover, 36, 18)
					d.Text(c, tokens.Body, artist.Name).TextColor(d.P.TextPrimary).Grow(1).SingleLine()
					d.Textf(c, tokens.Small, "%d 首", artist.Count).TextColor(d.P.TextSecondary)
				})
			}
			groupHeader(c, d, "歌单", results.PlaylistTotal, func() {
				s.Search().ShowScope(model.ScopePlaylists)
			})
			if len(results.Playlists) == 0 {
				emptyGroup(c, d, "没有匹配的歌单")
			}
			for _, playlist := range results.Playlists {
				playlist := playlist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space10).
					Padding(tokens.Space6, tokens.Space4).Radius(tokens.RadiusSM).Focusable()
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenPlaylist(playlist) })
				row.Children(func() {
					ui.Icon(c, components.IconQueue).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
					d.Text(c, tokens.Body, playlist.Name).TextColor(d.P.TextPrimary).Grow(1).SingleLine()
					d.Textf(c, tokens.Small, "%d 首", playlist.TrackCount).TextColor(d.P.TextSecondary)
				})
			}
		})
	})
}

func emptyGroup(c *ui.Context, d components.Design, text string) {
	d.Text(c, tokens.Small, text).TextColor(d.P.TextTertiary)
}

func groupHeader(c *ui.Context, d components.Design, title string, total int, more func()) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
		d.Text(c, tokens.H3, title).TextColor(d.P.TextPrimary)
		if total >= 0 {
			d.Textf(c, tokens.Small, "%d 项", total).TextColor(d.P.TextSecondary)
		}
		ui.Spacer(c)
		if more != nil && total > model.PreviewSize {
			if b := d.Button(c, "查看全部"); b.Clicked() {
				more()
			}
		}
	})
}
