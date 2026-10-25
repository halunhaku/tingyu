package pages

import (
	"runtime"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

var settingsSections = []string{"外观", "播放", "音乐库", "来源", "数据", "关于"}

// Settings is the settings page: appearance, playback information, library
// summary, sources, data paths and About. Appearance changes are persisted to
// settings.json when the library copy is writable (the same rule as M1's DB
// writes: a development build never writes the production directory).
func Settings(c *ui.Context, d components.Design, s *model.State) {
	Page(c, d, s, "设置", "", s.Back, nil, func() {
		components.Notice(c, d, s.SettingsErr(), nil)
		width, _ := c.Size()
		contentWidth := min(float32(760), width-d.SidebarWidth()-2*d.PagePadding()-tokens.SettingsNavWidth-tokens.Space24)
		ui.Row(c).Grow(1).FillWidth().AlignItems(ui.Start).Gap(tokens.Space24).Children(func() {
			nav := ui.Column(c).Width(tokens.SettingsNavWidth).Gap(2).Children(func() {
				for i, label := range settingsSections {
					i, label := i, label
					row := ui.Row(c).FillWidth().Padding(tokens.Space12, tokens.Space8).
						Radius(tokens.RadiusSM)
					if i == s.SettingsSection() {
						row.Background(d.P.Selected)
					} else if row.Hovered() {
						row.Background(d.P.Hover)
					}
					row.OnClick(func() { s.SetSettingsSection(i) })
					row.Children(func() {
						color := d.P.TextPrimary
						if i == s.SettingsSection() {
							color = d.P.Accent
						}
						d.Text(c, tokens.BodyM, label).TextColor(color)
					})
				}
			})
			_ = nav
			ui.Scroll(c).Grow(1).Children(func() {
				ui.Column(c).Gap(tokens.Space16).Width(contentWidth).Children(func() {
					switch s.SettingsSection() {
					case 0:
						appearanceSettings(c, d, s)
					case 1:
						playbackSettings(c, d, s)
					case 2:
						librarySettings(c, d, s)
					case 3:
						sourceSettings(c, d, s)
					case 4:
						dataSettings(c, d, s)
					default:
						aboutSettings(c, d, s)
					}
				})
			})
		})
	})
}

func appearanceSettings(c *ui.Context, d components.Design, s *model.State) {
	settings := s.Settings()
	components.SectionTitle(c, d, "外观", "颜色与密度来自 Flutter 版同一套「声档」令牌；写入 settings.json。")
	mode := 0
	switch settings.ThemeMode {
	case "light":
		mode = 1
	case "dark":
		mode = 2
	}
	components.SettingRow(c, d, "主题模式", settingModeLabel(settings.ThemeMode), func() {
		m := mode
		seg := ui.Segmented(c, &m, "跟随系统", "浅色", "深色").Radius(tokens.RadiusSM).FontSize(12)
		if seg.Changed() {
			next := settings
			next.ThemeMode = [3]string{"system", "light", "dark"}[m]
			s.SetSettings(next)
		}
	})
	density := 0
	if settings.Compact() {
		density = 1
	}
	components.SettingRow(c, d, "界面密度", densityLabel(settings.Density), func() {
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
	})
	tint := settings.CoverTint
	components.SettingRow(c, d, "封面动态取色",
		"关闭后舞台使用中性渐变；取色算法本身属于 M5 图片管线，当前两侧都使用令牌渐变。", func() {
			sw := ui.Switch(c, &tint)
			if sw.Changed() {
				next := settings
				next.CoverTint = tint
				s.SetSettings(next)
			}
		})
	reset := d.Button(c, "恢复默认外观").Width(160)
	if reset.Clicked() {
		s.ResetSettings()
	}
	if !s.Writable() {
		d.Text(c, tokens.BodyS, "只读模式：未设置 TINGYU_DATA_DIR 时偏好不落盘，生产目录不会被写。").
			TextColor(d.P.TextTertiary).Wrap()
	}
}

func settingModeLabel(mode string) string {
	switch mode {
	case "light":
		return "浅色"
	case "dark":
		return "深色"
	default:
		return "跟随系统"
	}
}

func densityLabel(density string) string {
	if density == "compact" {
		return "紧凑"
	}
	return "舒适"
}

func playbackSettings(c *ui.Context, d components.Design, s *model.State) {
	components.SectionTitle(c, d, "播放", "内核由 M1/M2 提供；界面只读它的快照。")
	components.StatRow(c, d, "播放引擎", "libmpv（进程内，purego）")
	components.StatRow(c, d, "系统媒体会话", "Now Playing / 媒体键（M1 已接入）")
	components.StatRow(c, d, "关窗行为", "继续播放，菜单栏可控制；Cmd+Q 干净退出")
	components.StatRow(c, d, "循环模式", model.RepeatLabel(s.Repeat()))
	components.StatRow(c, d, "随机播放", "内核控制器尚未提供 shuffle（需内核支持）")
}

func librarySettings(c *ui.Context, d components.Design, s *model.State) {
	counts := s.Counts()
	components.SectionTitle(c, d, "音乐库", "只读统计，来自当前打开的 library.sqlite。")
	ui.Row(c).Gap(tokens.Space32).Children(func() {
		components.Stat(c, d, "曲目", counts.Tracks)
		components.Stat(c, d, "专辑", counts.Albums)
		components.Stat(c, d, "艺术家", counts.Artists)
		components.Stat(c, d, "歌单", counts.Playlists)
		components.Stat(c, d, "来源", counts.Sources)
	})
	ui.Row(c).Gap(tokens.Space8).Children(func() {
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
	d.Text(c, tokens.BodyS, "「同步全部来源」只处理本地目录；WebDAV/夸克属 M3，不会伪造成功。").
		TextColor(d.P.TextTertiary)
}

func sourceSettings(c *ui.Context, d components.Design, s *model.State) {
	components.SectionTitle(c, d, "来源", "本地目录可用；WebDAV 与夸克网盘属于 M3，尚未接入。")
	if len(s.Sources()) == 0 {
		d.Text(c, tokens.BodyS, "还没有来源。到来源页添加一个本地音乐目录。").TextColor(d.P.TextSecondary)
	}
	for _, source := range s.Sources() {
		components.SourceRow(c, d, source.Name, source.Kind, source.TrackCount)
	}
	ui.Row(c).Gap(tokens.Space8).Children(func() {
		if b := d.Button(c, "来源管理"); b.Clicked() {
			s.OpenPage(model.PageSources)
		}
	})
}

func dataSettings(c *ui.Context, d components.Design, s *model.State) {
	components.SectionTitle(c, d, "数据", "开发/验收请把 TINGYU_DATA_DIR 指向库副本；生产库不会被写。")
	components.PathRow(c, d, s, "数据目录", s.DataDir())
	components.PathRow(c, d, s, "曲库文件", s.DBPath())
	components.PathRow(c, d, s, "封面缓存", s.CoversDir())
	mode := "只读（未设置 TINGYU_DATA_DIR）"
	if s.Writable() {
		mode = "读写（TINGYU_DATA_DIR 指向副本）"
	}
	components.StatRow(c, d, "打开方式", mode)
	components.StatRow(c, d, "schema", "user_version = 2（冻结，不提升）")
}

func aboutSettings(c *ui.Context, d components.Design, s *model.State) {
	components.SectionTitle(c, d, "关于", "")
	components.StatRow(c, d, "版本", model.Version)
	components.StatRow(c, d, "渲染", "MyGo v0.6.4 · ui（原生即时模式）")
	components.StatRow(c, d, "运行时", runtime.Version()+" · "+runtime.GOOS+"/"+runtime.GOARCH)
	components.StatRow(c, d, "设计", "「声档」令牌与 Flutter 版同源（app/lib/design/tokens）")
	d.Text(c, tokens.BodyS, "M4 只做界面与装配：远端来源（M3）、元数据与图片（M5）、签名公证（M6）不在本阶段。").
		TextColor(d.P.TextTertiary).Wrap()
}

// Sources is the source management page. Local directories are fully usable
// (add, re-scan); WebDAV and Quark show as out-of-scope M3 entries instead of
// forms that would fail.
func Sources(c *ui.Context, d components.Design, s *model.State) {
	actions := func() {
		ui.MenuButton(c, "添加来源", func(m *ui.Menu) {
			if m.Item("本地目录…").Chosen() {
				if a := s.Actions(); a != nil {
					a.ChooseDirectory()
				}
			}
			webdav := m.Item("WebDAV…（M3）")
			webdav.Disabled(true)
			quark := m.Item("夸克网盘…（M3）")
			quark.Disabled(true)
		}).Radius(tokens.RadiusSM).FontSize(13)
	}
	Page(c, d, s, "来源管理", sourceSummary(s), s.Back, actions, func() {
		ScanPanel(c, d, s.Scan())
		if len(s.Sources()) == 0 {
			components.Empty(c, d, components.IconFolder, "还没有音乐来源",
				"添加一个本地音乐目录开始扫描。WebDAV 与夸克网盘属于 M3，尚未接入。", func() {
					AddDirectoryButton(c, d, s)
				})
			return
		}
		ui.Scroll(c).Grow(1).Children(func() {
			ui.Column(c).Gap(tokens.Space10).Children(func() {
				for _, source := range s.Sources() {
					source := source
					card := ui.Column(c).Gap(tokens.Space8).Padding(tokens.Space16, tokens.Space12).
						Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
					card.Children(func() {
						components.SourceRow(c, d, source.Name, source.Kind, source.TrackCount)
						ui.Row(c).Gap(tokens.Space8).Children(func() {
							if source.Kind == "local" {
								if b := d.Button(c, "同步"); b.Clicked() {
									if a := s.Actions(); a != nil {
										a.SyncSource(source)
									}
								}
							} else {
								d.Tag(c, "远端来源 · M3 未接入")
							}
							if b := d.Button(c, "查看曲目"); b.Clicked() {
								s.Library().SetSource(source.ID)
								s.OpenPage(model.PageLibrary)
							}
							del := d.Button(c, "删除来源")
							if del.Clicked() {
								s.AskKernel("删除来源（music_sources + tracks 写入）")
							}
						})
						d.Text(c, tokens.BodyS, source.LocalFolderPath).TextColor(d.P.TextTertiary).SingleLine()
						if !source.LastSyncedAt.IsZero() {
							d.Textf(c, tokens.BodyS, "上次同步：%s · %s",
								source.LastSyncedAt.Format("2006-01-02 15:04"), source.SyncStatus).
								TextColor(d.P.TextSecondary)
						}
					})
				}
				outOfScopeSources(c, d)
			})
		})
	})
}

func outOfScopeSources(c *ui.Context, d components.Design) {
	components.SectionTitle(c, d, "尚未接入（M3）", "远端来源需要 M2 的远端播放能力；本阶段不建设。")
	ui.Row(c).Gap(tokens.Space12).Wrap().Children(func() {
		for _, item := range []struct{ name, detail string }{
			{"WebDAV", "PROPFIND 同步、Basic 鉴权、坚果云流控文案"},
			{"夸克网盘", "扫码/网页登录、直链鉴权、Cookie 生命周期"},
		} {
			card := ui.Column(c).Width(320).Gap(tokens.Space6).Padding(tokens.Space16, tokens.Space12).
				Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
			card.Children(func() {
				ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
					d.Text(c, tokens.BodyM, item.name).TextColor(d.P.TextPrimary)
					d.Tag(c, "M3 未接入")
				})
				d.Text(c, tokens.BodyS, item.detail).TextColor(d.P.TextSecondary).Wrap()
			})
		}
	})
}

func sourceSummary(s *model.State) string {
	if len(s.Sources()) == 0 {
		return ""
	}
	return model.FormatCount(len(s.Sources()), "个来源") + " · " + model.FormatCount(len(s.AllTracks()), "首")
}
