package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// MatchDialog is the manual-match sheet (plan §6 M5 item 2): the sources'
// candidates, the fields the write-back will use, and the apply button. Every
// field is editable, so a user can fix a title by hand when no source has it —
// the write is the same path an automatic pass takes (library.ApplyEnrichment),
// which is what makes it survive a restart.
func MatchDialog(c *ui.Context, d Design, s *model.State) {
	match := s.Match()
	if !match.Open {
		return
	}
	open := &match.Open
	d.Overlay(c, open, func() {
		panel := ui.Column(c).Width(620).MaxHeight(600).Radius(tokens.RadiusXL).
			Material(d.RegularGlass()).Border(1, d.P.Border).Padding(tokens.Space20).
			Gap(tokens.Space12)
		panel.Children(func() {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
				ui.Column(c).Grow(1).Gap(2).Children(func() {
					d.Text(c, tokens.H3, "匹配元数据").TextColor(d.P.TextPrimary)
					d.Text(c, tokens.Small, "原值："+match.Track.Title).TextColor(d.P.TextTertiary).SingleLine()
				})
				if b := d.Button(c, "关闭"); b.Clicked() {
					s.CloseMatch()
				}
			})

			ui.Row(c).Gap(tokens.Space8).Children(func() {
				matchField(c, d, "标题", "title", &match.Title)
				matchField(c, d, "艺术家", "artist", &match.Artist)
				matchField(c, d, "专辑", "album", &match.Album)
			})

			ui.Column(c).Gap(tokens.Space6).Children(func() {
				ui.Row(c).AlignItems(ui.Center).Children(func() {
					d.Text(c, tokens.Overline, "候选").TextColor(d.P.TextTertiary)
					ui.Spacer(c)
					if match.Loading {
						ui.Spinner(c)
						d.Text(c, tokens.Overline, "正在搜索…").TextColor(d.P.TextTertiary)
					} else if match.Error != "" {
						d.Text(c, tokens.Overline, match.Error).TextColor(d.P.Danger).SingleLine()
					} else {
						d.Textf(c, tokens.Overline, "%d 条", len(match.Candidates)).TextColor(d.P.TextTertiary)
					}
				})
				if len(match.Candidates) > 0 {
					ui.Scroll(c).Height(240).Children(func() {
						ui.Column(c).Gap(2).Children(func() {
							for i, candidate := range match.Candidates {
								i, candidate := i, candidate
								row := ui.Row(c).FillWidth().Padding(tokens.Space8, tokens.Space6).
									Radius(tokens.RadiusSM).AlignItems(ui.Center).Gap(tokens.Space8)
								if i == match.Selected {
									row.Background(d.P.Selected)
								} else if row.Hovered() {
									row.Background(d.P.Hover)
								}
								row.OnClick(func() { s.UseMatchCandidate(i) })
								row.Children(func() {
									d.Tag(c, providerLabel(candidate.Provider))
									ui.Column(c).Grow(1).Gap(1).Children(func() {
										d.Text(c, tokens.Body, candidate.Title).TextColor(d.P.TextPrimary).SingleLine()
										detail := candidate.Artist
										if candidate.Album != "" {
											detail += " · " + candidate.Album
										}
										if candidate.Duration > 0 {
											detail += " · " + model.FormatDuration(candidate.Duration)
										}
										d.Text(c, tokens.Small, detail).TextColor(d.P.TextSecondary).SingleLine()
									})
									if candidate.CoverURL != "" {
										d.Text(c, tokens.Overline, "有封面").TextColor(d.P.Success)
									}
									if b := d.Button(c, "采用"); b.Clicked() {
										s.UseMatchCandidate(i)
									}
								})
							}
						})
					})
				}
			})

			if match.Message != "" {
				d.Text(c, tokens.Small, match.Message).TextColor(d.P.TextSecondary).Wrap()
			}
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
				d.Text(c, tokens.Overline, "写回曲库后列表与舞台会立即刷新；人工匹配不会在下次补全时被覆盖。").
					TextColor(d.P.TextTertiary)
				ui.Spacer(c)
				if match.Busy {
					ui.Spinner(c)
				}
				apply := d.PrimaryButton(c, "应用并写回")
				if apply.Clicked() {
					s.ApplyMatch()
				}
				if b := d.Button(c, "取消"); b.Clicked() {
					s.CloseMatch()
				}
			})
		})
	})
}

func matchField(c *ui.Context, d Design, label, placeholder string, value *string) {
	ui.Column(c).Grow(1).Gap(4).Children(func() {
		d.Text(c, tokens.Overline, label).TextColor(d.P.TextTertiary)
		ui.TextInput(c, value).Placeholder(placeholder).Label(label).FillWidth()
	})
}

// providerLabel is the source's Chinese name for the tag.
func providerLabel(provider string) string {
	switch provider {
	case "qqmusic":
		return "QQ 音乐"
	case "netease":
		return "网易云"
	case "itunes":
		return "iTunes"
	case "lrclib":
		return "LRCLIB"
	case "ai":
		return "AI"
	default:
		return provider
	}
}

// ProviderLabel is the exported form for the settings page.
func ProviderLabel(provider string) string { return providerLabel(provider) }
