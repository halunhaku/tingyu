package pages

import (
	"runtime"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

var settingsSections = []string{"外观", "播放", "音乐库", "元数据", "来源", "数据", "关于"}

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
						Radius(tokens.RadiusSM).Focusable()
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
						metadataSettings(c, d, s)
					case 4:
						sourceSettings(c, d, s)
					case 5:
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
		"开启时舞台按当前封面取主/次色（与 Flutter 版同一套 24px / 12 色相桶 / 7:1 对比规则）；关闭、灰封面或取色失败回退中性令牌渐变。", func() {
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
		d.Text(c, tokens.BodyS, "只读模式：本次以 TINGYU_READ_ONLY=1 打开，偏好不落盘。").
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
	shuffle := s.Shuffle()
	components.SettingRow(c, d, "随机播放",
		"开启后新队列从选中曲目起随机排列；关闭后同一列表回到顺序。当前："+shuffleLabel(shuffle),
		func() {
			sw := ui.Switch(c, &shuffle)
			if sw.Changed() {
				s.ToggleShuffle()
			}
		})
}

func shuffleLabel(on bool) string {
	if on {
		return "开"
	}
	return "关"
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
	components.SectionTitle(c, d, "来源", "本地目录、WebDAV 与夸克网盘；凭据只存系统钥匙串，缺失时重新登录。")
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
	components.SectionTitle(c, d, "数据", "M7 起真实曲库默认读写；开发/验收可用 TINGYU_DATA_DIR 指向副本，TINGYU_READ_ONLY=1 只读打开。")
	components.PathRow(c, d, s, "数据目录", s.DataDir())
	components.PathRow(c, d, s, "曲库文件", s.DBPath())
	components.PathRow(c, d, s, "封面缓存", s.CoversDir())
	mode := "只读（TINGYU_READ_ONLY=1）"
	if s.Writable() {
		mode = "读写（曲库与设置可写）"
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
	d.Text(c, tokens.BodyS, "本阶段完成 M5 元数据与图片：四源补全 + 可选 AI 兜底、人工匹配、封面缓存与取色、歌词逐行/逐字。分发与质量（M6）不在本阶段。").
		TextColor(d.P.TextTertiary).Wrap()
}

// Sources is the source management page. M3 adds the two remote kinds: a
// WebDAV credential form, a Quark login (QR or pasted Cookie), progress with a
// cancel button, and a "重新登录" entry when a credential failed. It is the
// smallest usable surface — the plan allows exactly that — and reuses the
// existing tokens and components rather than introducing a new design.
func Sources(c *ui.Context, d components.Design, s *model.State) {
	actions := func() {
		ui.MenuButton(c, "添加来源", func(m *ui.Menu) {
			if m.Item("本地目录…").Chosen() {
				if a := s.Actions(); a != nil {
					a.ChooseDirectory()
				}
			}
			if m.Item("WebDAV…").Chosen() {
				s.OpenSourceForm(model.SourceKindWebDAV, "")
			}
			if m.Item("夸克网盘…").Chosen() {
				s.OpenSourceForm(model.SourceKindQuark, "")
			}
		}).Radius(tokens.RadiusSM).FontSize(13)
	}
	view := sourcesView(s)
	Page(c, d, s, "来源管理", sourceSummary(s), s.Back, actions, func() {
		sourceDeleteDialog(c, s, view)
		ScanPanel(c, d, s.Scan())
		sourceForm(c, d, s)
		if len(s.Sources()) == 0 {
			components.Empty(c, d, components.IconFolder, "还没有音乐来源",
				"添加一个本地目录、一个 WebDAV 目录或登录夸克网盘。", func() {
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
						ui.Row(c).Gap(tokens.Space8).Wrap().Children(func() {
							scan := s.Scan()
							syncing := scan.Running && scan.SourceID == source.ID
							if syncing {
								if b := d.Button(c, "取消同步"); b.Clicked() {
									if a := s.SourceActionsOf(); a != nil {
										a.CancelSourceSync()
									}
								}
							} else if b := d.Button(c, "同步"); b.Clicked() {
								if a := s.Actions(); a != nil {
									a.SyncSource(source)
								}
							}
							if message := s.SourceError(source.ID); message != "" {
								if b := d.Button(c, "重新登录"); b.Clicked() {
									s.OpenSourceForm(source.Kind, source.ID)
								}
							}
							if b := d.Button(c, "查看曲目"); b.Clicked() {
								s.Library().SetSource(source.ID)
								s.OpenPage(model.PageLibrary)
							}
							if del := d.Button(c, "删除来源"); del.Clicked() {
								view.deleting = source
								view.confirmOpen = true
							}
						})
						if source.Kind == model.SourceKindWebDAV && source.WebDAVURL != "" {
							d.Text(c, tokens.BodyS, source.WebDAVURL).TextColor(d.P.TextTertiary).SingleLine()
						} else if source.Kind == model.SourceKindQuark {
							d.Text(c, tokens.BodyS, "夸克网盘（直链播放，登录凭据在系统钥匙串）").
								TextColor(d.P.TextTertiary).SingleLine()
						} else {
							d.Text(c, tokens.BodyS, source.LocalFolderPath).TextColor(d.P.TextTertiary).SingleLine()
						}
						if message := s.SourceError(source.ID); message != "" {
							ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6).Children(func() {
								ui.Icon(c, components.IconInfo).FontSize(tokens.IconCompact).TextColor(d.P.Danger)
								d.Text(c, tokens.BodyS, message).TextColor(d.P.Danger).Wrap()
							})
						}
						if !source.LastSyncedAt.IsZero() {
							d.Textf(c, tokens.BodyS, "上次同步：%s · %s",
								source.LastSyncedAt.Format("2006-01-02 15:04"), source.SyncStatus).
								TextColor(d.P.TextSecondary)
						} else if source.SyncStatus != "" {
							d.Text(c, tokens.BodyS, source.SyncStatus).TextColor(d.P.TextSecondary)
						}
					})
				}
				sourceLimits(c, d)
			})
		})
	})
}

// sourcesPage is the source page's view state: the delete confirmation.
type sourcesPage struct {
	confirmOpen bool
	deleting    library.Source
}

func sourcesView(s *model.State) *sourcesPage {
	if v, ok := s.Transient("sources").(*sourcesPage); ok {
		return v
	}
	v := &sourcesPage{}
	s.SetTransient("sources", v)
	return v
}

// sourceDeleteDialog confirms deleting a source. Its tracks go too — that is
// the point of deleting a source — so the message says how many and that the
// files on disk are not touched.
func sourceDeleteDialog(c *ui.Context, s *model.State, v *sourcesPage) {
	if !v.confirmOpen {
		return
	}
	title := "删除来源「" + v.deleting.Name + "」？"
	message := "曲库里属于它的 " + model.FormatCount(int(v.deleting.TrackCount), "首") +
		"会一并移除（含歌单条目与不再被引用的封面）；磁盘上的文件不会被删除。"
	switch ui.AlertDialog(c, &v.confirmOpen, title, message, "取消", "确认删除") {
	case 1:
		if a := s.Actions(); a != nil {
			a.DeleteSource(v.deleting)
		}
		s.DismissSource(v.deleting.ID)
	}
}

// sourceForm renders the add/re-login panel of one kind.
func sourceForm(c *ui.Context, d components.Design, s *model.State) {
	form := s.SourceForm()
	if !form.Open {
		return
	}
	card := ui.Column(c).Gap(tokens.Space10).Padding(tokens.Space16, tokens.Space12).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
	card.Children(func() {
		title := "添加 WebDAV 来源"
		if form.Kind == model.SourceKindQuark {
			title = "登录夸克网盘"
		}
		if form.Editing != "" {
			title = "重新登录：" + firstNonEmpty(form.Name, "来源")
		}
		d.Text(c, tokens.BodyM, title).TextColor(d.P.TextPrimary)

		sourceField(c, d, "名称", "可选，例如「家里的群晖」", &form.Name)
		if form.Kind == model.SourceKindWebDAV {
			sourceField(c, d, "地址", "https://dav.jianguoyun.com/dav/", &form.URL)
			sourceField(c, d, "账号", "登录名", &form.Username)
			sourceField(c, d, "密码 / 应用专用密码", "只写入系统钥匙串，不落明文", &form.Password)
			ui.Row(c).Gap(tokens.Space8).Children(func() {
				if b := d.Button(c, "添加并同步"); b.Clicked() {
					if a := s.SourceActionsOf(); a != nil {
						a.AddWebDAVSource(form.Values())
					}
				}
				if b := d.Button(c, "取消"); b.Clicked() {
					s.CloseSourceForm()
				}
			})
		} else {
			if form.QR != nil {
				ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Center).Children(func() {
					ui.Image(c, form.QR).Size(180, 180).Fit(ui.Contain)
					ui.Column(c).Gap(tokens.Space4).Children(func() {
						d.Text(c, tokens.BodyS, form.QRPhase).TextColor(d.P.TextSecondary).Wrap()
						d.Text(c, tokens.LabelS, "用手机夸克 App 扫码确认后会自动完成登录。").
							TextColor(d.P.TextTertiary).Wrap()
					})
				})
			}
			ui.Row(c).Gap(tokens.Space8).Children(func() {
				label := "扫码登录"
				if form.QR != nil {
					label = "刷新二维码"
				}
				if b := d.Button(c, label); b.Clicked() {
					if a := s.SourceActionsOf(); a != nil {
						a.LoginQuark(form.Values())
					}
				}
				if b := d.Button(c, "停止扫码"); b.Clicked() {
					if a := s.SourceActionsOf(); a != nil {
						a.CancelSourceLogin()
					}
				}
				if b := d.Button(c, "取消"); b.Clicked() {
					s.CloseSourceForm()
				}
			})
			d.Text(c, tokens.LabelS, "也可以把浏览器里的 Cookie 请求头粘贴到下面（明文仅显示在输入框里，保存进钥匙串）：").
				TextColor(d.P.TextTertiary).Wrap()
			sourceField(c, d, "Cookie", "__pus=…; __puus=…", &form.Cookie)
			if b := d.Button(c, "用 Cookie 登录"); b.Clicked() {
				if a := s.SourceActionsOf(); a != nil {
					a.AddQuarkSource(form.Values())
				}
			}
		}
		if form.Busy {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
				ui.Spinner(c)
				d.Text(c, tokens.BodyS, "正在处理…").TextColor(d.P.TextSecondary)
			})
		}
		if form.Message != "" {
			d.Text(c, tokens.BodyS, form.Message).TextColor(d.P.Danger).Wrap()
		}
	})
}

func sourceField(c *ui.Context, d components.Design, label, hint string, value *string) {
	ui.Column(c).Gap(4).FillWidth().Children(func() {
		d.Text(c, tokens.LabelS, label).TextColor(d.P.TextTertiary)
		ui.TextInput(c, value).Placeholder(hint).Label(label).FillWidth()
	})
}

// sourceLimits is the honesty block: what M3 covers and what it does not.
func sourceLimits(c *ui.Context, d components.Design) {
	components.SectionTitle(c, d, "远端来源说明",
		"凭据只存系统钥匙串；同步可取消，取消或截断时保留未扫描曲目；夸克直链过期会自动刷新一次。")
	ui.Row(c).Gap(tokens.Space12).Wrap().Children(func() {
		for _, item := range []struct{ name, detail string }{
			{"WebDAV", "PROPFIND 扫描、Basic 鉴权播放、坚果云流控文案、列目录失败与重试"},
			{"夸克网盘", "扫码网页登录流程、Cookie 生命周期、分页目录、直链与过期刷新"},
			{"尚未包含", "歌词翻译与艺术家头像；动图 WebP 封面（只取静态帧）；跨设备凭据迁移"},
		} {
			card := ui.Column(c).Width(300).Gap(tokens.Space6).Padding(tokens.Space16, tokens.Space12).
				Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
			card.Children(func() {
				d.Text(c, tokens.BodyM, item.name).TextColor(d.P.TextPrimary)
				d.Text(c, tokens.BodyS, item.detail).TextColor(d.P.TextSecondary).Wrap()
			})
		}
	})
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func sourceSummary(s *model.State) string {
	if len(s.Sources()) == 0 {
		return ""
	}
	return model.FormatCount(len(s.Sources()), "个来源") + " · " + model.FormatCount(s.Counts().Tracks, "首")
}
