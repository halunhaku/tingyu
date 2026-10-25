package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Playlists is the playlist browser. The kernel exposes no playlist queries or
// writes yet (library only reads tracks and sources), so this page states that
// instead of drawing empty rows that look functional. The create action is
// wired to the same capability notice every other missing write uses.
func Playlists(c *ui.Context, d components.Design, s *model.State) {
	playlists := s.Playlists()
	actions := func() {
		if b := d.Button(c, "新建歌单"); b.Clicked() {
			s.AskKernel("歌单创建（playlists 表写入）")
		}
	}
	Page(c, d, s, "歌单", model.FormatCount(len(playlists), "个"), nil, actions, func() {
		if len(playlists) == 0 {
			components.Empty(c, d, components.IconQueue, "歌单尚未接入数据层",
				"界面（新建 / 重命名 / 删除 / 拖拽重排 / 移出歌单）已就位，但内核的 library 包目前只提供曲目与来源查询："+
					"读歌单需要 playlist/playlist_items 查询，写歌单需要创建、重命名、删除、加曲、移出与重排六个方法。"+
					"在这些方法就位前，本页不会伪造歌单数据。", func() {
					d.Button(c, "新建歌单（需内核）").OnClick(func() {
						s.AskKernel("歌单创建（playlists 表写入）")
					})
					d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
				})
			return
		}
		ui.Column(c).Gap(tokens.Space4).Children(func() {
			for _, playlist := range playlists {
				playlist := playlist
				row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
					Padding(tokens.Space10, tokens.Space8).Radius(tokens.RadiusSM)
				if row.Hovered() {
					row.Background(d.P.Hover)
				}
				row.Children(func() {
					components.Cover(c, d, s, "", 44, tokens.RadiusMD)
					ui.Column(c).Gap(2).Grow(1).Children(func() {
						d.Text(c, tokens.BodyM, playlist.Name).TextColor(d.P.TextPrimary).SingleLine()
						d.Textf(c, tokens.BodyS, "%d 首", playlist.Count).TextColor(d.P.TextSecondary)
					})
				})
			}
		})
	})
}
