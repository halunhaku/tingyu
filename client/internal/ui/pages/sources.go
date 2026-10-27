package pages

// The source page of direction A (§4.3, §10-11): one card per source with its
// last sync and its outcome, a 288 wide information column instead of the three
// documentation cards the M4 page carried, and the library's real statistics at
// the bottom. The remote kinds (WebDAV form, Quark QR login, cancel, re-login)
// are unchanged.

import (
	"strconv"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Sources is the source management page.
func Sources(c *ui.Context, d components.Design, s *model.State) {
	actions := func() {
		// "添加来源" is the page's main action (§4.3): accent, 32 high, its menu
		// is where the three kinds start, and the plus is the icon of the still.
		add := ui.Row(c).Height(tokens.ToolbarControl).PaddingX(tokens.Space12).
			Gap(tokens.Space6).Radius(tokens.RadiusSM).AlignItems(ui.Center).
			Background(d.P.Accent).Focusable()
		add.Children(func() {
			ui.Icon(c, components.IconPlus).FontSize(12).TextColor(d.P.OnAccent)
			d.Text(c, tokens.Label, "添加来源").TextColor(d.P.OnAccent)
		})
		add.Menu(func(m *ui.Menu) {
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
		})
	}
	view := sourcesView(s)
	// The back arrow is gone for the same reason as settings: the sidebar is
	// the navigation, and the stills show the page without it (§4.3).
	Page(c, d, s, "来源", sourceSummary(s), nil, actions, func() {
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
		width, _ := c.Size()
		available := width - d.SidebarWidth() - 2*d.PagePadding()
		ui.Scroll(c).Grow(1).Children(func() {
			ui.Column(c).Gap(0).Children(func() {
				// The card and the information column sit side by side where
				// both fit (§4.3's 570 + 288 at 1200); at the 900 floor the
				// panel moves under the card instead of squeezing it into a
				// column of ellipses.
				cards := func() {
					ui.Column(c).Gap(tokens.Space16).Children(func() {
						for _, source := range s.Sources() {
							sourceCard(c, d, s, view, source)
						}
					})
				}
				if available < 760 {
					ui.Column(c).Width(min(tokens.SourceCardMax, available)).Gap(tokens.Space24).Children(func() {
						cards()
						sourceInfoPanel(c, d)
					})
				} else {
					ui.Row(c).FillWidth().Gap(tokens.Space32).AlignItems(ui.Start).Children(func() {
						ui.Column(c).Grow(1).MaxWidth(tokens.SourceCardMax).Gap(tokens.Space16).Children(cards)
						sourceInfoPanel(c, d)
					})
				}
				ui.Box(c).Height(tokens.Space32)
				sourceStats(c, d, s)
				ui.Box(c).Height(tokens.Space24)
			})
		})
	})
}

// sourceCard is §4.3's card: a 46 DIP icon tile, the name and one meta line, the
// status dot, then "上次同步 / 同步结果" and the actions row.
func sourceCard(c *ui.Context, d components.Design, s *model.State, view *sourcesPage, source library.Source) {
	card := ui.Column(c).FillWidth().Padding(tokens.Space20).Gap(tokens.Space20).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
	card.Shadow(0, 8, 24, -12, ui.RGBA(20, 20, 20, 40))
	label, detail := splitSyncStatus(source.SyncStatus)
	message := s.SourceError(source.ID)
	card.Children(func() {
		ui.Row(c).FillWidth().Gap(tokens.Space12).AlignItems(ui.Center).Children(func() {
			tile := ui.Box(c).Size(46, 46).Radius(tokens.RadiusMD).
				Background(tokens.Blend(d.P.SurfaceRaised, d.P.AccentSoft)).Center()
			tile.Children(func() {
				ui.Icon(c, components.SourceIcon(source.Kind)).FontSize(22).TextColor(d.P.Accent)
			})
			ui.Column(c).Gap(tokens.Space2).Grow(1).Children(func() {
				d.Text(c, tokens.H3, source.Name).TextColor(d.P.TextPrimary).SingleLine()
				d.Text(c, tokens.Small, sourceCardMeta(source)).TextColor(d.P.TextSecondary).SingleLine()
			})
			sourceStatusDot(c, d, label, message)
		})
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Row(c).FillWidth().Gap(tokens.Space24).Children(func() {
			ui.Column(c).Gap(tokens.Space4).Children(func() {
				d.Text(c, tokens.NumSm, "上次同步").TextColor(d.P.TextTertiary)
				d.Text(c, tokens.Small, sourceSyncTime(source)).TextColor(d.P.TextSecondary)
			})
			ui.Column(c).Gap(tokens.Space4).Grow(1).Children(func() {
				d.Text(c, tokens.NumSm, "同步结果").TextColor(d.P.TextTertiary)
				result := detail
				if result == "" {
					result = "—"
				}
				d.Text(c, tokens.Small, result).TextColor(d.P.TextSecondary).SingleLine().
					Tooltip(detail)
			})
		})
		ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Center).Wrap().Children(func() {
			scan := s.Scan()
			syncing := scan.Running && scan.SourceID == source.ID
			if syncing {
				if b := d.Button(c, "取消同步"); b.Clicked() {
					if a := s.SourceActionsOf(); a != nil {
						a.CancelSourceSync()
					}
				}
			} else if b := d.PrimaryButton(c, "立即同步"); b.Clicked() {
				if a := s.Actions(); a != nil {
					a.SyncSource(source)
				}
			}
			if message != "" {
				if b := d.Button(c, "重新登录"); b.Clicked() {
					s.OpenSourceForm(source.Kind, source.ID)
				}
			}
			if b := d.Button(c, "查看曲目"); b.Clicked() {
				s.Library().SetSource(source.ID)
				s.OpenPage(model.PageLibrary)
			}
			// The ••• menu keeps the destructive action out of the row, as
			// §4.3's action row asks.
			more := ui.Button(c, "").Size(tokens.ToolbarControl, tokens.ToolbarControl).Padding(6).
				Radius(tokens.RadiusSM).Label("来源操作").Tooltip("更多操作").
				Background(ui.Transparent).Border(0, ui.Transparent)
			more.Children(func() {
				ui.Icon(c, components.IconMore).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
			})
			more.Menu(func(m *ui.Menu) {
				if source.Kind == model.SourceKindQuark {
					if m.Item("更换文件夹…").Chosen() {
						values := s.OpenQuarkFolders(source.ID)
						if a := s.QuarkFolderActionsOf(); a != nil {
							a.BrowseQuarkFolders(values)
						}
					}
				}
				if m.Item("删除来源…").Chosen() {
					view.deleting = source
					view.confirmOpen = true
				}
			})
		})
		if message != "" {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6).Children(func() {
				ui.Icon(c, components.IconInfo).FontSize(tokens.IconCompact).TextColor(d.P.Danger)
				d.Text(c, tokens.Small, message).TextColor(d.P.Danger).Wrap()
			})
		}
		if target := sourceTarget(source); target != "" {
			d.Text(c, tokens.Small, target).TextColor(d.P.TextTertiary).SingleLine()
		}
	})
}

// sourceStatusDot is the card's state: success, a partial sync (warning) or a
// failure (danger), with the label the library recorded.
func sourceStatusDot(c *ui.Context, d components.Design, label, message string) {
	color := d.P.Success
	switch {
	case message != "" || strings.Contains(label, "失败"):
		color = d.P.Danger
	case !strings.Contains(label, "完成") && !strings.Contains(label, "已同步"):
		color = d.P.Warning
	}
	ui.Row(c).Gap(tokens.Space6).AlignItems(ui.Center).Children(func() {
		ui.Box(c).Size(6, 6).Radius(3).Background(color)
		d.Text(c, tokens.Label, label).TextColor(d.P.TextSecondary)
	})
}

// sourceInfoPanel is the right-hand column that replaced the three cards: the
// three sentences that are true of every remote source, and what can be added.
func sourceInfoPanel(c *ui.Context, d components.Design) {
	ui.Column(c).Width(tokens.SourceInfoWidth).Gap(tokens.Space10).
		Padding(tokens.Space4, 0, 0, 0).Children(func() {
		d.Text(c, tokens.H3, "远程来源").TextColor(d.P.TextPrimary)
		for _, line := range []string{
			"凭据只保存在系统钥匙串，不写入曲库。",
			"同步可以随时取消，已经扫描的曲目会保留。",
			"直链过期时会在加载阶段自动刷新一次。",
		} {
			row := ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Start)
			row.Children(func() {
				dot := ui.Box(c).Size(4, 4).Radius(2).Background(d.P.TextTertiary)
				dot.Margin(7, 0, 0, 0)
				d.Text(c, tokens.Small, line).TextColor(d.P.TextSecondary).Wrap()
			})
		}
		ui.Box(c).Height(tokens.Space8)
		ui.Box(c).FillWidth().Height(1).Background(d.P.Border)
		ui.Box(c).Height(tokens.Space8)
		d.Text(c, tokens.NumSm, "可添加的类型").TextColor(d.P.TextTertiary)
		d.Text(c, tokens.Small, "本地目录 · WebDAV · 夸克网盘").TextColor(d.P.TextSecondary)
	})
}

// sourceStats is the real numbers at the bottom of the page (§4.3): the five
// figures the library can answer, including when it last synced.
func sourceStats(c *ui.Context, d components.Design, s *model.State) {
	counts := s.Counts()
	ui.Row(c).FillWidth().Gap(tokens.Space56).Children(func() {
		components.Stat(c, d, "曲目", counts.Tracks)
		components.Stat(c, d, "专辑", counts.Albums)
		components.Stat(c, d, "艺术家", counts.Artists)
		components.Stat(c, d, "来源", len(s.Sources()))
		components.Stat(c, d, "上次同步", lastSyncDate(s.Sources()))
	})
}

// splitSyncStatus splits the library's sentence into its short state and the
// parenthesised detail ("部分同步（…；新增 23 / 更新 0）").
func splitSyncStatus(status string) (label, detail string) {
	label = strings.TrimSpace(status)
	if i := strings.IndexRune(label, '（'); i >= 0 {
		detail = strings.TrimSuffix(strings.TrimPrefix(label[i:], "（"), "）")
		label = strings.TrimSpace(label[:i])
	}
	if label == "" {
		label = "尚未同步"
	}
	return label, detail
}

// sourceCardMeta is the card's one meta line: the kind and the track count.
func sourceCardMeta(source library.Source) string {
	kind := sourceKindLabel(source.Kind)
	if source.Kind == model.SourceKindQuark {
		// What a quark source actually does, in the card's one line (§4.3).
		kind = "直链播放"
	}
	return kind + " · " + strconv.FormatInt(source.TrackCount, 10) + " 首"
}

// sourceKindLabel is the user's name for a source kind.
func sourceKindLabel(kind string) string {
	switch kind {
	case model.SourceKindQuark:
		return "夸克网盘"
	case model.SourceKindWebDAV:
		return "WebDAV"
	default:
		return "本地目录"
	}
}

// sourceTarget is the address line under the card's actions.
func sourceTarget(source library.Source) string {
	switch {
	case source.Kind == model.SourceKindWebDAV && source.WebDAVURL != "":
		return source.WebDAVURL
	case source.Kind == model.SourceKindQuark:
		folder := source.QuarkFolderPath
		if folder == "" {
			if source.QuarkFolderFID == "" || source.QuarkFolderFID == "0" {
				folder = "/（全部文件）"
			} else {
				folder = "已选文件夹"
			}
		}
		return "同步目录：" + folder
	default:
		return source.LocalFolderPath
	}
}

// sourceSyncTime is the card's "上次同步" value.
func sourceSyncTime(source library.Source) string {
	if source.LastSyncedAt.IsZero() {
		return "—"
	}
	return source.LastSyncedAt.Local().Format("2006-01-02 15:04")
}

// lastSyncDate is the newest sync among the sources, for the statistics row.
func lastSyncDate(sources []library.Source) string {
	var newest library.Source
	for _, source := range sources {
		if source.LastSyncedAt.After(newest.LastSyncedAt) {
			newest = source
		}
	}
	if newest.LastSyncedAt.IsZero() {
		return "—"
	}
	return newest.LastSyncedAt.Local().Format("2006-01-02")
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
		if form.Choosing {
			if a := s.SourceActionsOf(); a != nil {
				a.CancelSourceLogin()
			}
			s.CloseSourceForm()
		}
		return
	}
	if form.Choosing {
		quarkFolderPicker(c, d, s)
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
		d.Text(c, tokens.Body, title).TextColor(d.P.TextPrimary)

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
					if a := s.SourceActionsOf(); a != nil {
						a.CancelSourceLogin()
					}
					s.CloseSourceForm()
				}
			})
		} else {
			if form.QR != nil {
				ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Center).Children(func() {
					ui.Image(c, form.QR).Size(tokens.SourceQR, tokens.SourceQR).Fit(ui.Contain)
					ui.Column(c).Gap(tokens.Space4).Children(func() {
						d.Text(c, tokens.Small, form.QRPhase).TextColor(d.P.TextSecondary).Wrap()
						d.Text(c, tokens.Overline, "用手机夸克 App 扫码确认后会自动完成登录。").
							TextColor(d.P.TextTertiary).Wrap()
					})
				})
			}
			ui.Row(c).Gap(tokens.Space8).Children(func() {
				label := "扫码登录"
				if form.QR != nil {
					label = "刷新二维码"
				}
				if b := d.Button(c, label).Disabled(form.Busy); b.Clicked() {
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
					if a := s.SourceActionsOf(); a != nil {
						a.CancelSourceLogin()
					}
					s.CloseSourceForm()
				}
			})
			d.Text(c, tokens.Overline, "也可以把浏览器里的 Cookie 请求头粘贴到下面（明文仅显示在输入框里，保存进钥匙串）：").
				TextColor(d.P.TextTertiary).Wrap()
			sourceField(c, d, "Cookie", "__pus=…; __puus=…", &form.Cookie)
			if b := d.Button(c, "用 Cookie 登录").Disabled(form.Busy); b.Clicked() {
				if a := s.SourceActionsOf(); a != nil {
					a.AddQuarkSource(form.Values())
				}
			}
		}
		if form.Busy {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
				ui.Spinner(c)
				d.Text(c, tokens.Small, "正在处理…").TextColor(d.P.TextSecondary)
			})
		}
		if form.Message != "" {
			d.Text(c, tokens.Small, form.Message).TextColor(d.P.Danger).Wrap()
		}
	})
}

func sourceField(c *ui.Context, d components.Design, label, hint string, value *string) {
	ui.Column(c).Gap(4).FillWidth().Children(func() {
		d.Text(c, tokens.Overline, label).TextColor(d.P.TextTertiary)
		ui.TextInput(c, value).Placeholder(hint).Label(label).FillWidth()
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
