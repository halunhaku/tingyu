package pages

import (
	"cmp"
	"slices"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Library is the song library (§4.3): the page header, the "最近添加" shelf of
// six albums, the track table and the honest footer. The development footnote
// the M4 page carried (the database path and the SQL sentence) is gone
// (§10-7).
func Library(c *ui.Context, d components.Design, s *model.State) {
	list := s.Library()
	total := list.Total()
	actions := func() {
		// The toolbar's own filter goes when the window is narrow: the sidebar's
		// search and ⌘F still reach the search page, and the row of controls is
		// what has to fit at the 900 wide minimum.
		if width, _ := c.Size(); width >= 1000 {
			query := list.Query()
			d.SearchBoxWidth(c, &query, "搜索曲库", "搜索曲库", 200, false,
				func() { list.SetQuery(query) }, nil, nil)
		}
		SortMenu(c, d, list)
		if s.HasMultipleSources() {
			SourceMenu(c, d, s, list)
		}
		if b := d.PrimaryButton(c, "播放全部"); b.Clicked() {
			PlayAll(s, s.AllOf(list))
		}
		AddDirectoryButton(c, d, s)
	}
	Page(c, d, s, "曲库", librarySummary(s, total), nil, actions, func() {
		ScanPanel(c, d, s.Scan())
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if list.Total() == 0 {
			if query := list.Query(); query != "" {
				components.Empty(c, d, components.IconSearch, "没有匹配「"+query+"」的曲目",
					"换个关键词，或清除筛选回到整个曲库。", func() {
						d.PrimaryButton(c, "清除筛选").OnClick(func() { list.SetQuery("") })
					})
				return
			}
			if s.SourceFilter() != "" {
				components.Empty(c, d, components.IconSearch, "这个来源没有曲目",
					"换一个来源，或在来源页同步这个目录。", func() {
						d.Button(c, "显示全部来源").OnClick(func() { list.SetSource("") })
					})
			} else {
				components.Empty(c, d, components.IconMusic, "曲库是空的",
					"点「添加目录…」选一个音乐文件夹，扫描后会出现在这里。", func() {
						AddDirectoryButton(c, d, s)
					})
			}
			return
		}
		if list.Loaded() == 0 && list.Loading() {
			// The first page is on its way: the skeleton stands in for the rows
			// (§4.4), six of them, so the page keeps its shape.
			components.Skeleton(c, d, 6, d.RowHeight())
			return
		}
		RecentShelf(c, d, s)
		ui.Box(c).Height(tokens.Space20)
		components.TrackTable(c, d, components.TableOptions{
			State:      s,
			List:       list,
			ShowSource: s.HasMultipleSources(),
		})
		components.Pager(c, d, list, "按"+list.Sort().String()+"排序")
	})
}

// librarySummary is the header's second line (§4.3): tracks · source · albums.
func librarySummary(s *model.State, total int) string {
	if total <= 0 {
		return ""
	}
	line := model.FormatCount(total, "首")
	if name := s.SourceName(s.SourceFilter()); name != "" {
		line += " · " + name
	}
	if albums := s.Counts().Albums; albums > 0 {
		line += " · " + model.FormatCount(albums, "张专辑")
	}
	return line
}

// shelfRows is how many of the newest rows the shelf reads to find its six
// albums: three pages, which is what the library's own paging asks for.
const shelfRows = 3 * model.PageSize

// RecentShelf is the six-cover "最近添加" shelf (§4.3): the albums added last,
// one cover each, newest first, ties broken by title (the library writes one
// date_added per sync, so the tie-break is the usual case — §13-6).
func RecentShelf(c *ui.Context, d components.Design, s *model.State) {
	albums := recentAlbums(s, shelfCount(c, d))
	if len(albums) == 0 {
		return
	}
	ui.Row(c).FillWidth().AlignItems(ui.Center).Children(func() {
		d.Text(c, tokens.H3, "最近添加").TextColor(d.P.TextPrimary)
		ui.Spacer(c)
		link := d.Text(c, tokens.Label, "查看全部").TextColor(d.P.TextTertiary)
		link.Cursor(ui.CursorPointer).OnClick(func() { s.OpenPage(model.PageAlbums) })
	})
	ui.Box(c).Height(tokens.Space12)
	ui.Row(c).FillWidth().Gap(tokens.Space20).Children(func() {
		for _, album := range albums {
			album := album
			card := ui.Column(c).Width(tokens.CoverShelf).Gap(tokens.Space8).Focusable()
			card.OnClick(func() { s.OpenAlbum(album) })
			card.Children(func() {
				cover := components.Cover(c, d, s, album.Cover, tokens.CoverShelf, tokens.RadiusMD)
				// Hover lifts the shadow, never the cover (§4.4).
				if card.Hovered() {
					cover.Shadow(0, 10, 24, -6, ui.RGBA(20, 20, 20, 56))
				} else {
					cover.Shadow(0, 6, 16, -4, ui.RGBA(20, 20, 20, 44))
				}
				d.Text(c, tokens.Caption, album.Name).TextColor(d.P.TextPrimary).SingleLine()
				ui.Text(c, album.Artist).FontSize(11).LineHeight(1.3).TextColor(d.P.TextTertiary).SingleLine()
			})
		}
	})
}

// shelfCount is how many 104 DIP covers fit beside the sidebar at this window
// width: six at the design's 1200, five at the 900 minimum.
func shelfCount(c *ui.Context, d components.Design) int {
	width, _ := c.Size()
	avail := width - d.SidebarWidth() - 2*d.PagePadding()
	const gap = tokens.Space20
	count := int((avail + gap) / (tokens.CoverShelf + gap))
	if count < 1 {
		return 1
	}
	if count > 6 {
		return 6
	}
	return count
}

// recentAlbums picks distinct albums from the newest-added page of the library:
// date_added descending, titles ascending when the dates agree (§4.3, §13-6).
func recentAlbums(s *model.State, want int) []model.Album {
	list := s.Recent()
	// Three pages of the newest rows are enough for six albums; asking every
	// frame is a no-op once they are loaded (the request is the list's, so the
	// shelf never holds a query of its own).
	list.RequestRowsUpTo(shelfRows)
	rows := slices.Clone(list.Items())
	slices.SortStableFunc(rows, func(a, b library.Track) int {
		if c := b.DateAdded.Compare(a.DateAdded); c != 0 {
			return c
		}
		if c := cmp.Compare(a.Title, b.Title); c != 0 {
			return c
		}
		return cmp.Compare(a.ID, b.ID)
	})
	out := make([]model.Album, 0, want)
	seen := map[string]bool{}
	for _, track := range rows {
		if len(out) >= want {
			break
		}
		if track.CoverArtPath == "" || track.Album == "" || seen[track.Album] {
			continue
		}
		seen[track.Album] = true
		out = append(out, model.Album{
			Key:    track.Album,
			Name:   track.Album,
			Artist: track.Artist,
			Year:   track.Year,
			Cover:  track.CoverArtPath,
		})
	}
	return out
}

// Favorites is the favourites page, reusing the library table for songs and a
// cover grid for the albums those songs belong to.
func Favorites(c *ui.Context, d components.Design, s *model.State) {
	list := s.Favorites()
	view := s.FavoriteView()
	actions := func() {
		section := view
		seg := ui.Segmented(c, &section, "歌曲", "专辑").Radius(tokens.RadiusSM).FontSize(13)
		if seg.Changed() {
			s.SetFavoriteView(section)
		}
		if view == 0 {
			SortMenu(c, d, list)
		}
		if view == 0 {
			if b := d.PrimaryButton(c, "播放全部"); b.Clicked() {
				PlayAll(s, s.AllOf(list))
			}
		}
	}
	Page(c, d, s, "收藏", favoritesSummary(s), nil, actions, func() {
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if view == 1 {
			albums := s.FavoriteAlbums()
			if albums.Total() == 0 {
				components.Empty(c, d, components.IconHeart, "还没有收藏的专辑",
					"收藏的单曲会自动归入它所在的专辑。", nil)
				return
			}
			AlbumGrid(c, d, s, albums)
			return
		}
		if list.Total() == 0 {
			components.Empty(c, d, components.IconHeart, "还没有收藏的歌曲",
				"点击曲目右侧的 ♥ 即可收藏，写入 tracks.is_favorite 并立即生效。", func() {
					d.PrimaryButton(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
				})
			return
		}
		components.TrackTable(c, d, components.TableOptions{State: s, List: list})
		components.Pager(c, d, list, "")
	})
}

func favoritesSummary(s *model.State) string {
	return model.FormatCount(s.FavoriteAlbums().Total(), "张专辑")
}
