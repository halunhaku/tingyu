package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Library is the song library: paginated table, sort, source filter, play all
// and the scan panel.
func Library(c *ui.Context, d components.Design, s *model.State) {
	list := s.Library()
	total := list.Total()
	actions := func() {
		SortMenu(c, d, list)
		if s.HasMultipleSources() {
			SourceMenu(c, d, s, list)
		}
		if b := d.Button(c, "播放全部"); b.Clicked() {
			PlayAll(s, s.AllOf(list))
		}
		AddDirectoryButton(c, d, s)
	}
	Page(c, d, s, "曲库", trackSummary(total), nil, actions, func() {
		ScanPanel(c, d, s.Scan())
		if s.LoadErr() != nil {
			components.ErrorState(c, d, "无法打开曲库", s.LoadErr().Error(), s.DBPath())
			return
		}
		if list.Total() == 0 {
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
		components.TrackTable(c, d, components.TableOptions{
			State:      s,
			List:       list,
			ShowSource: s.HasMultipleSources(),
		})
		components.Pager(c, d, list)
		ui.Row(c).Gap(tokens.Space8).Children(func() {
			d.Text(c, tokens.LabelS, s.DBPath()).TextColor(d.P.TextTertiary).SingleLine()
			d.Text(c, tokens.LabelS, "· 分页与聚合来自 SQL（LIMIT/OFFSET）").TextColor(d.P.TextTertiary)
		})
	})
}

func trackSummary(total int) string {
	if total <= 0 {
		return ""
	}
	return model.FormatCount(total, "首")
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
			if b := d.Button(c, "播放全部"); b.Clicked() {
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
					d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
				})
			return
		}
		components.TrackTable(c, d, components.TableOptions{State: s, List: list})
		components.Pager(c, d, list)
	})
}

func favoritesSummary(s *model.State) string {
	return model.FormatCount(s.FavoriteAlbums().Total(), "张专辑")
}
