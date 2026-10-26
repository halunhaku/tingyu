package pages

import (
	"fmt"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

var settingsSections = []string{"外观", "播放", "音乐库", "元数据", "来源", "数据", "关于"}

// Settings is the settings page of §4.3 / §10-12: seven horizontal section tabs
// instead of the second 208 px navigation column, one 620 wide content column
// with grouped cards, and the "关于" card beside it. Every control the M4 page
// had is still here; what changed is where it sits and how it reads — the copy
// is the user's language, not the pipeline's.
func Settings(c *ui.Context, d components.Design, s *model.State) {
	// No back arrow: the stills' settings page is a sidebar destination, and
	// the rail is always on screen (§4.3). ⌘, reaches it from anywhere.
	Page(c, d, s, "设置", "改动会立即保存，不需要重启。", nil, nil, func() {
		components.Notice(c, d, s.SettingsErr(), nil)
		settingsTabs(c, d, s)
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Box(c).Height(tokens.Space20)
		width, _ := c.Size()
		available := width - d.SidebarWidth() - 2*d.PagePadding()
		ui.Scroll(c).Grow(1).Children(func() {
			settingsBody(c, d, s, available)
		})
	})
}

// settingsBody lays out the content column and the about card: side by side
// when there is room for both (§4.3: 620 + 40 + 240 at 1200), stacked below the
// 1000 DIP floor the window can take.
func settingsBody(c *ui.Context, d components.Design, s *model.State, available float32) {
	section := s.SettingsSection()
	// The 关于 tab is the full about card itself: it uses the whole width
	// instead of repeating the summary beside it.
	if section == len(settingsSections)-1 {
		ui.Column(c).Gap(tokens.Space20).Width(min(tokens.SettingsContent+tokens.Space40+tokens.AboutCardMax, available)).
			Children(func() { settingsSection(c, d, s) })
		return
	}
	contentWidth := min(tokens.SettingsContent, available)
	sideBySide := available >= tokens.SettingsContent+tokens.Space40+180
	if !sideBySide {
		ui.Column(c).Gap(tokens.Space20).Width(contentWidth).Children(func() {
			settingsSection(c, d, s)
		})
		ui.Box(c).Height(tokens.Space20)
		ui.Column(c).Width(min(tokens.SettingsContent, available)).Children(func() {
			aboutCard(c, d, s)
		})
		return
	}
	block := min(available, tokens.SettingsContent+tokens.Space40+tokens.AboutCardMax)
	ui.Row(c).Width(block).Gap(tokens.Space40).AlignItems(ui.Start).Children(func() {
		ui.Column(c).Width(tokens.SettingsContent).Gap(tokens.Space20).Children(func() {
			settingsSection(c, d, s)
		})
		ui.Column(c).Grow(1).Children(func() { aboutCard(c, d, s) })
	})
}

// settingsTabs is the horizontal section switch: the current label in the
// primary colour over a 2 px accent underline (§10-12).
func settingsTabs(c *ui.Context, d components.Design, s *model.State) {
	ui.Row(c).FillWidth().Height(36).Gap(tokens.Space24).AlignItems(ui.Center).Children(func() {
		for i, label := range settingsSections {
			i, label := i, label
			active := i == s.SettingsSection()
			cell := ui.Column(c).Gap(tokens.Space8).AlignItems(ui.Center).Focusable()
			cell.OnClick(func() { s.SetSettingsSection(i) })
			cell.Children(func() {
				color := d.P.TextSecondary
				if active {
					color = d.P.TextPrimary
				}
				d.Text(c, tokens.Body, label).TextColor(color)
				bar := ui.Box(c).Width(18).Height(2).Radius(1)
				if active {
					bar.Background(d.P.Accent)
				}
			})
		}
	})
}

// settingsSection draws the current section's cards.
func settingsSection(c *ui.Context, d components.Design, s *model.State) {
	switch s.SettingsSection() {
	case 0:
		appearanceSettings(c, d, s)
	case 1:
		playbackSettings(c, d, s)
	case 2:
		librarySettings(c, d, s)
	case 3:
		metadataSettings(c, d, s)
	case 4:
		sourceSettings(c, d, s)
	case 5:
		dataSettings(c, d, s)
	default:
		aboutSettings(c, d, s)
	}
}

// settingsCard is a grouped card: the raised surface of §4.3 with no padding of
// its own, because every row carries the design's 20/18 inset.
func settingsCard(c *ui.Context, d components.Design, build func()) {
	ui.Column(c).FillWidth().Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).
		Border(1, d.P.Border).Children(build)
}

// settingsRow is one labelled line of a card: the label at 14 and one user
// sentence at 11 under it, the control in its own column on the right.
func settingsRow(c *ui.Context, d components.Design, label, help string, control func(), divider bool) {
	ui.Row(c).FillWidth().Padding(tokens.Space20, tokens.Space20).
		Gap(tokens.Space24).AlignItems(ui.Center).Children(func() {
		ui.Column(c).Gap(tokens.Space2).Grow(1).Children(func() {
			d.Text(c, tokens.Body, label).TextColor(d.P.TextPrimary)
			if help != "" {
				d.Text(c, tokens.NumSm, help).TextColor(d.P.TextTertiary).Wrap()
			}
		})
		if control != nil {
			ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Center).Children(control)
		}
	})
	if divider {
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
	}
}

// settingsValue is a read-only value in the control column.
func settingsValue(c *ui.Context, d components.Design, value string) {
	d.Text(c, tokens.Small, value).TextColor(d.P.TextSecondary)
}

func appearanceSettings(c *ui.Context, d components.Design, s *model.State) {
	settings := s.Settings()
	settingsCard(c, d, func() {
		mode := 0
		switch settings.ThemeMode {
		case "light":
			mode = 1
		case "dark":
			mode = 2
		}
		settingsRow(c, d, "主题模式", "跟随系统时，随 macOS 的外观自动切换。", func() {
			m := mode
			seg := ui.Segmented(c, &m, "跟随系统", "浅色", "深色").Radius(tokens.RadiusSM).FontSize(12)
			if seg.Changed() {
				next := settings
				next.ThemeMode = [3]string{"system", "light", "dark"}[m]
				s.SetSettings(next)
			}
		}, true)
		density := 0
		if settings.Compact() {
			density = 1
		}
		settingsRow(c, d, "界面密度", "舒适行高 44，紧凑行高 40。", func() {
			v := density
			seg := ui.Segmented(c, &v, "舒适", "紧凑").Radius(tokens.RadiusSM).FontSize(12)
			if seg.Changed() {
				next := settings
				if v == 1 {
					next.Density = "compact"
				} else {
					next.Density = "comfortable"
				}
				s.SetSettings(next)
			}
		}, true)
		tint := settings.CoverTint
		settingsRow(c, d, "封面动态取色", "用当前封面的颜色铺舞台背景；关掉后使用中性色。", func() {
			sw := ui.Switch(c, &tint)
			if sw.Changed() {
				next := settings
				next.CoverTint = tint
				s.SetSettings(next)
			}
		}, false)
		ui.Row(c).Padding(tokens.Space20, tokens.Space20).Children(func() {
			if b := d.Button(c, "恢复默认外观"); b.Clicked() {
				s.ResetSettings()
			}
		})
		if !s.Writable() {
			ui.Row(c).Padding(0, tokens.Space20, tokens.Space20, tokens.Space20).Children(func() {
				d.Text(c, tokens.Small, "只读模式：本次以 TINGYU_READ_ONLY=1 打开，偏好不落盘。").
					TextColor(d.P.TextTertiary).Wrap()
			})
		}
	})
}

func playbackSettings(c *ui.Context, d components.Design, s *model.State) {
	settingsCard(c, d, func() {
		shuffle := s.Shuffle()
		settingsRow(c, d, "随机播放", "开启后新队列从选中曲目起随机排列。", func() {
			sw := ui.Switch(c, &shuffle)
			if sw.Changed() {
				s.ToggleShuffle()
			}
		}, true)
		settingsRow(c, d, "循环模式", "列表循环；菜单栏与媒体键使用同一状态。", func() {
			settingsValue(c, d, model.RepeatLabel(s.Repeat()))
		}, false)
	})
}

func librarySettings(c *ui.Context, d components.Design, s *model.State) {
	counts := s.Counts()
	settingsCard(c, d, func() {
		ui.Row(c).FillWidth().Padding(tokens.Space20, tokens.Space20).Gap(tokens.Space32).Children(func() {
			components.Stat(c, d, "曲目", counts.Tracks)
			components.Stat(c, d, "专辑", counts.Albums)
			components.Stat(c, d, "艺术家", counts.Artists)
			components.Stat(c, d, "歌单", counts.Playlists)
			components.Stat(c, d, "来源", counts.Sources)
		})
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Column(c).Padding(tokens.Space20, tokens.Space20).Gap(tokens.Space10).Children(func() {
			d.Text(c, tokens.Small, "同步会扫描本地目录；WebDAV 与夸克网盘在来源页各自同步。").
				TextColor(d.P.TextTertiary).Wrap()
			ui.Row(c).Gap(tokens.Space8).Wrap().Children(func() {
				AddDirectoryButton(c, d, s)
				if b := d.Button(c, "同步全部来源"); b.Clicked() {
					if a := s.Actions(); a != nil {
						a.SyncAllSources()
					}
				}
				if b := d.Button(c, "来源管理"); b.Clicked() {
					s.OpenPage(model.PageSources)
				}
			})
		})
	})
}

func sourceSettings(c *ui.Context, d components.Design, s *model.State) {
	settingsCard(c, d, func() {
		ui.Column(c).Padding(tokens.Space20, tokens.Space20).Gap(tokens.Space10).Children(func() {
			d.Text(c, tokens.Small, "本地目录、WebDAV 与夸克网盘；登录凭据只存系统钥匙串。").
				TextColor(d.P.TextTertiary).Wrap()
			if len(s.Sources()) == 0 {
				d.Text(c, tokens.Small, "还没有来源。到来源页添加一个本地音乐目录。").
					TextColor(d.P.TextSecondary)
			}
			for _, source := range s.Sources() {
				components.SourceRow(c, d, source.Name, sourceKindLabel(source.Kind), source.TrackCount)
			}
			ui.Row(c).Children(func() {
				if b := d.Button(c, "来源管理"); b.Clicked() {
					s.OpenPage(model.PageSources)
				}
			})
		})
	})
}

func dataSettings(c *ui.Context, d components.Design, s *model.State) {
	settingsCard(c, d, func() {
		ui.Column(c).Padding(tokens.Space20, tokens.Space20).Gap(tokens.Space10).Children(func() {
			d.Text(c, tokens.Small, "曲库、封面与偏好都在下面这个目录里；把整个目录复制走就是一次备份。").
				TextColor(d.P.TextTertiary).Wrap()
			components.PathRow(c, d, s, "数据目录", s.DataDir())
			components.PathRow(c, d, s, "曲库文件", s.DBPath())
			components.PathRow(c, d, s, "封面缓存", s.CoversDir())
			ui.Box(c).Height(tokens.Space4)
			mode := "只读"
			if s.Writable() {
				mode = "读写"
			}
			components.StatRow(c, d, "打开方式", mode)
		})
	})
}

// aboutCard is the right-hand summary of §4.3: the real version, one sentence,
// and the three facts a listener may wonder about — no Flutter build, no M5
// pipeline, no settings.json.
func aboutCard(c *ui.Context, d components.Design, s *model.State) {
	counts := s.Counts()
	ui.Column(c).FillWidth().Padding(tokens.Space20).Gap(tokens.Space12).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border).Children(func() {
		d.Text(c, tokens.Overline, "关于").TextColor(d.P.TextTertiary)
		d.Text(c, tokens.H3, "听屿 "+model.Version).TextColor(d.P.TextPrimary)
		d.Text(c, tokens.Small, "私人音乐库播放器，直连你的来源。").TextColor(d.P.TextSecondary).Wrap()
		ui.Box(c).Height(tokens.Space6)
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Box(c).Height(tokens.Space4)
		aboutRow(c, d, "播放内核", "libmpv")
		aboutRow(c, d, "媒体会话", "系统 Now Playing")
		aboutRow(c, d, "数据", fmt.Sprintf("%s · %s",
			model.FormatCount(counts.Tracks, "首"), model.FormatCount(len(s.Sources()), "个来源")))
	})
}

func aboutRow(c *ui.Context, d components.Design, label, value string) {
	ui.Row(c).FillWidth().Height(26).AlignItems(ui.Center).Children(func() {
		d.Text(c, tokens.Small, label).TextColor(d.P.TextTertiary)
		ui.Spacer(c)
		d.Text(c, tokens.Small, value).TextColor(d.P.TextSecondary)
	})
}

// aboutSettings is the 关于 tab: the same card, full width, with the facts the
// summary cannot hold.
func aboutSettings(c *ui.Context, d components.Design, s *model.State) {
	aboutCard(c, d, s)
}
