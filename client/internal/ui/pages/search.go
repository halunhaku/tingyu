package pages

import (
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Search is the search page: 250 ms debounce, four groups, per-group
// previews with 「查看全部」, and 40-per-page lists for a single scope.
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
		field := d.SearchBox(c, &search.Input, "曲库搜索", "搜索歌曲、专辑、艺术家", true,
			func() { search.OnInput(s.Now()) },
			func() { submitSearch(s) }, nil).FillWidth()
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
				d.Text(c, tokens.BodyS, "正在搜索…").TextColor(d.P.TextSecondary)
			})
			return
		}
		if results.SongTotal+results.AlbumTotal+results.ArtistTotal == 0 {
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
			albumsResults(c, d, s, results)
		case model.ScopeArtists:
			artistsResults(c, d, s, results)
		case model.ScopePlaylists:
			components.Empty(c, d, components.IconQueue, "歌单搜索尚未接入",
				"歌单的读取需要内核提供 playlist 查询；当前只搜索曲目、专辑与艺术家。", nil)
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

func submitSearch(s *model.State) {
	search := s.Search()
	query := strings.TrimSpace(search.Input)
	if query == "" {
		return
	}
	search.Query = query
	search.Remember(query)
	search.Recompute(s.Albums(), s.Artists(), s.AllTracks())
	results := search.Results()
	if len(results.Songs) > 0 {
		PlayFrom(s, results.Songs, 0)
	}
}

func recentSearches(c *ui.Context, d components.Design, s *model.State) {
	search := s.Search()
	ui.Column(c).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			d.Text(c, tokens.TitleM, "最近搜索").TextColor(d.P.TextPrimary)
			ui.Spacer(c)
			if len(search.Recent()) > 0 {
				if b := d.Button(c, "清除"); b.Clicked() {
					search.ForgetRecent()
				}
			}
		})
		if len(search.Recent()) == 0 {
			d.Text(c, tokens.BodyS, "输入关键词搜索歌曲、专辑与艺术家；歌单搜索待内核提供查询。").TextColor(d.P.TextSecondary)
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
	list.Ensure(s.AllTracks(), s.LibraryRevision(), s.RowRevisions())
	components.TrackTable(c, d, components.TableOptions{State: s, List: list})
	components.Pager(c, d, list)
}

func albumsResults(c *ui.Context, d components.Design, s *model.State, results model.SearchResults) {
	search := s.Search()
	pages := max(1, search.Pages(model.ScopeAlbums))
	limit := min(len(results.Albums), pages*model.PageSize)
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for _, album := range results.Albums[:limit] {
				album := album
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
					Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenAlbum(album) })
				row.Children(func() {
					components.Cover(c, d, s, album.Cover, 44, tokens.RadiusSM)
					ui.Column(c).Gap(2).Grow(1).Children(func() {
						d.Text(c, tokens.BodyM, album.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Text(c, tokens.BodyS, album.Artist+" · "+model.FormatCount(album.TrackCount(), "首")).
							TextColor(d.P.TextSecondary).SingleLine()
					})
					play := ui.Button(c, "").Padding(5).Radius(tokens.RadiusXS).
						Label("播放专辑 " + album.Name).Tooltip("播放专辑")
					play.Children(func() {
						ui.Icon(c, components.IconPlay).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
					})
					if play.Clicked() {
						PlayAll(s, album.Tracks)
					}
				})
			}
			if search.HasMore(model.ScopeAlbums, len(results.Albums)) {
				if b := d.Button(c, "加载更多"); b.Clicked() {
					search.RequestMore(model.ScopeAlbums, len(results.Albums))
				}
			}
		})
	})
}

func artistsResults(c *ui.Context, d components.Design, s *model.State, results model.SearchResults) {
	search := s.Search()
	pages := max(1, search.Pages(model.ScopeArtists))
	limit := min(len(results.Artists), pages*model.PageSize)
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for _, artist := range results.Artists[:limit] {
				artist := artist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
					Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenArtist(artist) })
				row.Children(func() {
					components.Cover(c, d, s, artist.Cover, 44, 22)
					ui.Column(c).Gap(2).Grow(1).Children(func() {
						d.Text(c, tokens.BodyM, artist.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Textf(c, tokens.BodyS, "%d 首 · %d 张专辑", len(artist.Tracks), len(artist.Albums)).
							TextColor(d.P.TextSecondary)
					})
				})
			}
			if search.HasMore(model.ScopeArtists, len(results.Artists)) {
				if b := d.Button(c, "加载更多"); b.Clicked() {
					search.RequestMore(model.ScopeArtists, len(results.Artists))
				}
			}
		})
	})
}

func allResults(c *ui.Context, d components.Design, s *model.State, results model.SearchResults) {
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Column(c).Gap(tokens.Space16).Children(func() {
			groupHeader(c, d, "歌曲", results.SongTotal, func() {
				s.Search().ShowScope(model.ScopeSongs)
			})
			songs := model.Preview(results.Songs, model.PreviewSize)
			for i, track := range songs {
				i, track := i, track
				components.TrackRow(c, d, s, track, s.Player().Track != nil && s.Player().Track.ID == track.ID, func() {
					PlayFrom(s, results.Songs, i)
				})
			}
			groupHeader(c, d, "专辑", results.AlbumTotal, func() {
				s.Search().ShowScope(model.ScopeAlbums)
			})
			ui.ScrollHorizontal(c).Height(178).Children(func() {
				for _, album := range model.Preview(results.Albums, model.PreviewSize) {
					album := album
					card := ui.Column(c).Width(132).Gap(tokens.Space6).OnClick(func() { s.OpenAlbum(album) })
					card.Children(func() {
						components.CoverFill(c, d, s, album.Cover, tokens.RadiusMD)
						d.Text(c, tokens.BodyS, album.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Text(c, tokens.LabelS, album.Artist).TextColor(d.P.TextSecondary).SingleLine()
					})
				}
			})
			groupHeader(c, d, "艺术家", results.ArtistTotal, func() {
				s.Search().ShowScope(model.ScopeArtists)
			})
			for _, artist := range model.Preview(results.Artists, model.PreviewSize) {
				artist := artist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space10).
					Padding(tokens.Space6, tokens.Space4).Radius(tokens.RadiusSM)
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.OnClick(func() { s.OpenArtist(artist) })
				row.Children(func() {
					components.Cover(c, d, s, artist.Cover, 36, 18)
					d.Text(c, tokens.BodyM, artist.Name).TextColor(d.P.TextPrimary).Grow(1).SingleLine()
					d.Textf(c, tokens.BodyS, "%d 首", len(artist.Tracks)).TextColor(d.P.TextSecondary)
				})
			}
			groupHeader(c, d, "歌单", 0, nil)
			d.Text(c, tokens.BodyS, "歌单搜索待内核提供查询。").TextColor(d.P.TextTertiary)
		})
	})
}

func groupHeader(c *ui.Context, d components.Design, title string, total int, more func()) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
		d.Text(c, tokens.TitleM, title).TextColor(d.P.TextPrimary)
		if total >= 0 {
			d.Textf(c, tokens.BodyS, "%d 项", total).TextColor(d.P.TextSecondary)
		}
		ui.Spacer(c)
		if more != nil && total > model.PreviewSize {
			if b := d.Button(c, "查看全部"); b.Clicked() {
				more()
			}
		}
	})
}
