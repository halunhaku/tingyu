package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Palette is the Cmd+K command palette: one query field, grouped results
// (songs, albums, artists, shortcuts), 5 per group, arrow keys and Enter.
func Palette(c *ui.Context, d Design, s *model.State) {
	p := s.Palette()
	if !p.Open {
		return
	}
	open := &p.Open
	ui.Modal(c, open, func() {
		panel := ui.Column(c).Width(tokens.SearchPaletteWide).MaxHeight(520).
			Radius(tokens.RadiusXL).Background(d.P.Overlay).Border(1, d.P.Border).
			Padding(tokens.Space12).Gap(tokens.Space8)
		panel.Children(func() {
			d.SearchBox(c, &p.Input, "命令面板", "搜索歌曲、专辑、艺术家，或输入命令", true,
				func() { p.OnInput(s.Now()) },
				func() { s.ActivatePalette() },
				func(k ui.TextKey) bool {
					switch {
					case k.Mods == 0 && k.Key == ui.KeyDown:
						p.Move(1)
						return true
					case k.Mods == 0 && k.Key == ui.KeyUp:
						p.Move(-1)
						return true
					case k.Mods == 0 && k.Key == ui.KeyEscape:
						s.ClosePalette()
						return true
					case k.Mods == 0 && k.Key == ui.KeyEnter:
						s.ActivatePalette()
						return true
					}
					return false
				}).Grow(1)
			if p.Pending() {
				c.After(tokens.SearchDebounceTime)
			}
			ui.Scroll(c).Grow(1).Children(func() {
				ui.Column(c).Gap(2).Children(func() {
					lastGroup := ""
					for i, item := range p.Items {
						if item.Group != lastGroup {
							lastGroup = item.Group
							ui.Row(c).Padding(tokens.Space8, tokens.Space6).Children(func() {
								d.Text(c, tokens.LabelS, item.Group).TextColor(d.P.TextTertiary)
								ui.Spacer(c)
								if item.Group == "快捷入口" {
									d.Textf(c, tokens.LabelS, "%d 项", len(model.Commands)).TextColor(d.P.TextTertiary)
								}
							})
						}
						index := i
						row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space10).
							Padding(tokens.Space10, tokens.Space8).Radius(tokens.RadiusSM)
						if index == p.Selected {
							row.Background(d.P.Selected)
						} else if row.Hovered() {
							row.Background(d.P.Hover)
						}
						row.OnClick(func() {
							p.Selected = index
							s.ActivatePalette()
						})
						row.Children(func() {
							switch item.Kind {
							case model.PaletteSong:
								CoverFor(c, d, s, item.Track.CoverArtPath, 28)
							case model.PaletteAlbum:
								CoverFor(c, d, s, item.Album.Cover, 28)
							default:
								ui.Box(c).Size(28, 28).Radius(tokens.RadiusSM).
									Background(d.P.SurfaceSunken).Center().Children(func() {
									icon := IconSearch
									if item.Kind == model.PaletteCommand {
										icon = IconPlay
									}
									ui.Icon(c, icon).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
								})
							}
							ui.Column(c).Gap(1).Grow(1).Children(func() {
								d.Text(c, tokens.BodyM, item.Label).TextColor(d.P.TextPrimary).SingleLine()
								if item.Detail != "" {
									d.Text(c, tokens.BodyS, item.Detail).TextColor(d.P.TextSecondary).SingleLine()
								}
							})
							if item.Shortcut != "" {
								KeyHint(c, d, item.Shortcut)
							}
						})
					}
					if len(p.Items) == 0 {
						ui.Row(c).Padding(tokens.Space16).Children(func() {
							d.Text(c, tokens.BodyS, "没有匹配的结果").TextColor(d.P.TextSecondary)
						})
					}
				})
			})
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Padding(tokens.Space8, 2).Children(func() {
				d.Text(c, tokens.LabelS, "↑↓ 选择 · Enter 打开 · Esc 关闭").TextColor(d.P.TextTertiary)
				ui.Spacer(c)
				d.Text(c, tokens.LabelS, ItemCount(len(p.Items))).TextColor(d.P.TextTertiary)
			})
		})
	})
}
