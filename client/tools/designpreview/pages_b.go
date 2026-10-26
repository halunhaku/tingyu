package main

// pages_b.go draws Direction B (舞台「潮汐」): cover-led. A glass top bar
// replaces the sidebar, the library is a cover grid, and the stage fills the
// window with the cover's own colours. The floating transport is the only
// persistent chrome.

import (
	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
)

func (s *scene) pageB(page string) {
	switch page {
	case "library":
		s.bLibrary()
	case "stage":
		s.bStage()
	case "sources":
		s.bSources()
	case "settings":
		s.bSettings()
	}
}

// bPage opens a B page: the cover-derived wash behind, the page in front. The
// wash is built inside the page's column because absolute children paint in
// document order, and a background added before the column would cover it.
func (s *scene) bPage(page func(w, h float32)) {
	p := s.p
	w, h := s.c.Size()
	s.c.Root().Background(s.col(p.Canvas))
	from, to, ok := s.stageColors(s.at.Now.Cover)
	if !ok {
		from, to = s.col(p.SurfaceSunken), s.col(p.Canvas)
	}
	top := mix(from, s.col(p.Canvas), 0.84)
	bottom := mix(to, s.col(p.Canvas), 0.92)
	root := ui.Column(s.c).Fill().Gradient(top, bottom, 168)
	root.Draw(func(p *ui.Painter, r ui.Rect) {
		s.paintAmbient(p, r, s.at.Now.Cover, ui.Rect{X: -200, Y: -240, W: 1600, H: 1200}, 0.88)
	})
	root.Children(func() { page(w, h) })
}

// bGlassCircle is the round material button the B top bars use.
func (s *scene) bGlassCircle(size float32, svg *ui.SVG, color ui.Color) {
	e := s.glass(size, size, size/2, 0.45)
	e.Border(1, s.col(s.p.Border))
	e.Center()
	e.Children(func() { s.icon(svg, size*0.44, color) })
}

// bTopBar is the glass bar and the five destinations, shared by B pages that
// keep the library chrome.
func (s *scene) bTopBar(active string, back bool) {
	p := s.p
	w, _ := s.c.Size()
	bar := ui.Row(s.c).Width(w).Height(64).PaddingX(48).Gap(34).AlignItems(ui.Center)
	bar.Children(func() {
		if back {
			s.bGlassCircle(36, glyphBack, s.col(p.Text2))
			ui.Box(s.c).Width(14)
		}
		ui.Row(s.c).Gap(10).AlignItems(ui.Center).Children(func() {
			logo := ui.Box(s.c).Size(26, 26).Radius(8).Background(s.col(p.Accent)).Center()
			logo.Children(func() { s.icon(glyphNote, 14, s.col(p.OnAccent)) })
			s.t("h2", "听屿", s.col(p.Text))
		})
		ui.Box(s.c).Width(14)
		for _, item := range []string{"曲库", "专辑", "艺术家", "收藏", "来源"} {
			item := item
			ui.Column(s.c).Gap(7).AlignItems(ui.Center).Children(func() {
				color := s.col(p.Text2)
				if item == active {
					color = s.col(p.Text)
				}
				s.t("label", item, color)
				mark := ui.Box(s.c).Width(14).Height(2).Radius(1)
				if item == active {
					mark.Background(s.col(p.Accent))
				}
				_ = mark
			})
		}
		ui.Spacer(s.c)
		s.bGlassCircle(32, glyphSearch, s.col(p.Text2))
		s.bGlassCircle(32, glyphSettings, s.col(p.Text2))
	})
}

// bLibrary: cover grid and the floating transport.
func (s *scene) bLibrary() {
	p := s.p
	s.bPage(func(w, h float32) {
		s.bTopBar("曲库", false)
		content := ui.Column(s.c).FillWidth().Grow(1).Padding(12, 48, 0, 48)
		content.Children(func() {
			ui.Row(s.c).FillWidth().AlignItems(ui.End).Children(func() {
				ui.Column(s.c).Gap(4).Children(func() {
					s.t("h1", "曲库", s.col(p.Text))
					s.t("small", metaLine(s.at), s.col(p.Text2))
				})
				ui.Spacer(s.c)
				ui.Row(s.c).Gap(8).AlignItems(ui.Center).Children(func() {
					for i, label := range []string{"全部", "最近添加", "最近播放"} {
						s.pill(label, i == 0)
					}
				})
			})
			ui.Box(s.c).Height(26)
			seen := map[string]bool{}
			albums := []track{}
			for _, tr := range s.at.Tracks {
				if seen[tr.Album] || tr.Cover == "" {
					continue
				}
				seen[tr.Album] = true
				albums = append(albums, tr)
				if len(albums) == 15 {
					break
				}
			}
			// Three rows: the third scrolls under the floating transport, which
			// is what the material blurs.
			for row := 0; row < 3; row++ {
				ui.Row(s.c).FillWidth().Gap(44).Children(func() {
					for i := 0; i < 5; i++ {
						idx := row*5 + i
						if idx >= len(albums) {
							continue
						}
						tr := albums[idx]
						playing := tr.Album == s.at.Now.Album
						ui.Column(s.c).Width(180).Gap(10).Children(func() {
							cover := s.cover(tr.Cover, 180, 180, s.d.Radius.SM)
							cover.Shadow(0, 8, 22, -8, ui.RGBA(10, 12, 16, 50))
							_ = cover
							if playing {
								badge := s.glass(74, 22, 11, 0.4)
								badge.Center()
								badge.Absolute().Left(8).Top(150)
								badge.Children(func() {
									ui.Row(s.c).Gap(5).AlignItems(ui.Center).Children(func() {
										ui.Box(s.c).Size(5, 5).Radius(3).Background(s.col(p.Accent))
										s.t("numSm", "正在播放", s.col(p.Text))
									})
								})
							}
							s.t("label", tr.Album, s.col(p.Text)).SingleLine()
							s.t("numSm", tr.Artist, s.col(p.Text3)).SingleLine()
						})
					}
				})
				if row < 2 {
					ui.Box(s.c).Height(24)
				}
			}
		})
		s.bTransport(w, h)
	})
}

// bTransport is the 760×72 glass pill at the bottom of library pages.
func (s *scene) bTransport(w, h float32) {
	p := s.p
	pill := ui.Row(s.c).Width(760).Height(72).PaddingX(18).Gap(14).AlignItems(ui.Center).
		Material(glass.Glass{Style: glass.Regular, Tint: s.col(p.GlassTint).Alpha(p.GlassAlpha), Clarity: 0.3}).
		Border(1, s.col(p.Border)).
		Absolute().Left(w/2 - 380).Top(h - 96)
	pill.Shadow(0, 18, 44, -16, ui.RGBA(8, 10, 14, 60))
	pill.Children(func() {
		s.cover(s.at.Now.Cover, 48, 48, s.d.Radius.SM)
		ui.Column(s.c).Gap(2).Width(160).Children(func() {
			s.t("label", s.at.Now.Title, s.col(p.Text)).SingleLine()
			s.t("numSm", s.at.Now.Artist, s.col(p.Text3)).SingleLine()
		})
		s.transportButton(30, glyphPrev, s.col(p.Text))
		s.playButton(40, true)
		s.transportButton(30, glyphNext, s.col(p.Text))
		ui.Box(s.c).Width(4)
		s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
		s.progress(210, 0.33, 3, 9)
		s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
		ui.Spacer(s.c)
		s.icon(glyphVolume, 14, s.col(p.Text3))
		s.iconButton(28, glyphQueue, s.col(p.Text3))
	})
}

// bStage fills the window with the cover: the cover itself, a milky veil, and
// the lyrics as the second protagonist.
func (s *scene) bStage() {
	p := s.p
	w, h := s.c.Size()
	from, to, ok := s.stageColors(s.at.Now.Cover)
	if !ok {
		from, to = s.col(p.SurfaceSunken), s.col(p.Canvas)
	}
	veilAlpha := float32(0.52)
	base := float32(0)
	if p.Dark {
		veilAlpha = 0.78
		base = 0.55
	}
	from = mix(from, s.col(p.Canvas), base)
	to = mix(to, s.col(p.Canvas), base)
	root := ui.Column(s.c).Fill().Gradient(from, to, 155)
	root.Draw(func(p *ui.Painter, r ui.Rect) {
		s.paintAmbient(p, r, s.at.Now.Cover, ui.Rect{X: 0, Y: 0, W: w, H: h}, veilAlpha)
	})
	root.Children(func() {
		ui.Row(s.c).FillWidth().Height(72).PaddingX(48).Gap(14).AlignItems(ui.Center).Children(func() {
			s.bGlassCircle(36, glyphBack, s.col(p.Text2))
			ui.Box(s.c).Width(6)
			s.t("overline", "正在播放", s.col(p.Text2))
			ui.Spacer(s.c)
			s.bGlassCircle(34, glyphHeart, s.col(p.Text3))
			s.bGlassCircle(34, glyphLyrics, s.col(p.Text3))
			s.bGlassCircle(34, glyphQueue, s.col(p.Text3))
			s.bGlassCircle(34, glyphClose, s.col(p.Text3))
		})
		content := ui.Row(s.c).FillWidth().Grow(1).Padding(24, 96, 48, 96).Gap(64).AlignItems(ui.Center)
		content.Children(func() {
			left := ui.Column(s.c).Width(420).Gap(0)
			left.Children(func() {
				cover := s.cover(s.at.Now.Cover, 420, 420, s.d.Radius.SM)
				cover.Shadow(0, 36, 80, -24, ui.RGBA(8, 10, 14, 130))
				_ = cover
				ui.Box(s.c).Height(30)
				s.t("overline", "来自《"+s.at.Now.Album+"》", s.col(p.Text2)).SingleLine()
				ui.Box(s.c).Height(10)
				title := s.t("display", s.at.Now.Title, s.col(p.Text))
				title.SingleLine()
				ui.Box(s.c).Height(8)
				s.t("h2", s.at.Now.Artist, s.col(p.Text2))
				ui.Box(s.c).Height(26)
				s.progress(420, 0.33, 4, 13)
				ui.Box(s.c).Height(8)
				ui.Row(s.c).Width(420).Children(func() {
					s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text2))
					ui.Spacer(s.c)
					s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text2))
				})
				ui.Box(s.c).Height(22)
				ui.Row(s.c).Width(420).Gap(22).AlignItems(ui.Center).Justify(ui.Center).Children(func() {
					s.transportButton(26, glyphShuffle, s.col(p.Text2))
					s.transportButton(30, glyphPrev, s.col(p.Text))
					s.playButton(60, true)
					s.transportButton(30, glyphNext, s.col(p.Text))
					s.transportButton(26, glyphRepeat, s.col(p.Text2))
				})
			})

			// Lyrics: the second protagonist, word by word on the active line.
			right := ui.Column(s.c).Grow(1).FillHeight().Justify(ui.Center).Gap(0)
			right.Children(func() {
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("overline", "歌词", s.col(p.Text2))
					ui.Spacer(s.c)
					s.t("numSm", "LRC", s.col(p.Text3))
				})
				ui.Box(s.c).Height(26)
				active := s.at.activeLyric()
				first := max(0, active-3)
				last := min(len(s.at.Lyrics), active+4)
				for i := first; i < last; i++ {
					line := s.at.Lyrics[i]
					if i == active {
						sung, rest := splitSung(line.Text, 0.62)
						activeLine := ui.Row(s.c).FillWidth().Gap(16).AlignItems(ui.Center)
						activeLine.Children(func() {
							ui.Box(s.c).Width(3).Height(28).Radius(2).Background(s.col(p.Accent))
							s.lyricFill(sung, rest, s.col(p.Text), s.col(p.Text).Alpha(0.34)).
								FontSize(24).LineHeight(1.4).LetterSpacing(-0.5)
						})
						ui.Box(s.c).Height(16)
						continue
					}
					color := s.col(p.Text2)
					if i < active {
						color = s.col(p.Text3).Alpha(0.75)
					}
					ui.Box(s.c).Height(12)
					s.t("lyric", line.Text, color).SingleLine()
				}
				ui.Box(s.c).Height(26)
				ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Text).Alpha(0.12))
				ui.Box(s.c).Height(14)
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("overline", "下一首", s.col(p.Text3))
					ui.Spacer(s.c)
					s.t("label", s.at.Queue[1].Title, s.col(p.Text2)).SingleLine()
				})
			})
		})
	})
}

// splitSung cuts a lyric line at the share of its runes the word fill has
// reached: the still frame of the word-by-word highlight.
func splitSung(text string, share float64) (string, string) {
	runes := []rune(text)
	cut := int(float64(len(runes)) * share)
	if cut < 0 || cut > len(runes) {
		return text, ""
	}
	return string(runes[:cut]), string(runes[cut:])
}

// bSources: one glass card, one dashed add tile, one caption line.
func (s *scene) bSources() {
	p := s.p
	s.bPage(func(w, h float32) {
		s.bTopBar("来源", false)
		ui.Box(s.c).Height(16)
		ui.Row(s.c).FillWidth().Grow(1).Justify(ui.Center).AlignItems(ui.Center).Children(func() {
			col := ui.Column(s.c).Width(720).Gap(0)
			col.Children(func() {
				s.t("h1", "来源", s.col(p.Text))
				ui.Box(s.c).Height(6)
				label, warning, detail, when := s.syncState()
				statusColor := p.Success
				if warning {
					statusColor = p.Warning
				}
				s.t("small", "1 个来源 · "+itoa(s.at.Total)+" 首 · 凭据只存在系统钥匙串。", s.col(p.Text2))
				ui.Box(s.c).Height(26)
				card := ui.Column(s.c).FillWidth().Padding(26).Gap(18).
					Radius(s.d.Radius.MD).
					Material(glass.Glass{Tint: s.col(p.GlassTint).Alpha(p.GlassAlpha + 0.1), Clarity: 0.25}).
					Border(1, s.col(p.Border))
				card.Shadow(0, 18, 44, -20, ui.RGBA(8, 10, 14, 60))
				card.Children(func() {
					ui.Row(s.c).FillWidth().Gap(16).AlignItems(ui.Center).Children(func() {
						tile := ui.Box(s.c).Size(54, 54).Radius(s.d.Radius.SM).Background(s.col(p.AccentSoft)).Center()
						tile.Children(func() { s.icon(glyphFolder, 24, s.col(p.Accent)) })
						ui.Column(s.c).Gap(4).Children(func() {
							s.t("h2", s.at.SourceName, s.col(p.Text))
							s.t("small", "直链播放 · "+itoa(s.at.Total)+" 首", s.col(p.Text2)).SingleLine()
						})
						ui.Spacer(s.c)
						ui.Row(s.c).Padding(10, 5).Radius(s.d.Radius.Pill).
							Background(s.col(statusColor).Alpha(0.14)).Children(func() {
							s.t("label", label, s.col(statusColor))
						})
					})
					ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
						s.t("numSm", "上次同步 "+when+" · "+valueOr(detail, "无异常"), s.col(p.Text3)).SingleLine()
						ui.Spacer(s.c)
						ui.Row(s.c).Height(32).PaddingX(16).Radius(s.d.Radius.Pill).
							Background(s.col(p.Accent)).Center().Children(func() {
							s.t("label", "立即同步", s.col(p.OnAccent))
						})
						ui.Box(s.c).Width(8)
						s.button("查看曲目", false, 32)
					})
				})
				ui.Box(s.c).Height(26)
				ui.Row(s.c).PaddingX(4).Children(func() { s.t("overline", "添加来源", s.col(p.Text3)) })
				ui.Box(s.c).Height(10)
				ui.Row(s.c).FillWidth().Gap(16).Children(func() {
					for _, kind := range []struct{ name, note string }{
						{"本地目录", "直接扫描磁盘上的音乐文件"},
						{"WebDAV", "坚果云、NAS 等标准协议"},
						{"夸克网盘", "扫码登录，直链播放"},
					} {
						kind := kind
						tile := ui.Column(s.c).Grow(1).Padding(18).Gap(6).
							Radius(s.d.Radius.SM).Border(1, s.col(p.Border))
						tile.Children(func() {
							ui.Row(s.c).Gap(8).AlignItems(ui.Center).Children(func() {
								s.icon(glyphPlus, 13, s.col(p.Text2))
								s.t("label", kind.name, s.col(p.Text))
							})
							s.t("numSm", kind.note, s.col(p.Text3)).Wrap()
						})
					}
				})
				ui.Box(s.c).Height(16)
				s.t("numSm", "同步可随时取消，已扫描的曲目会保留；直链过期时自动刷新一次。", s.col(p.Text3)).Wrap()
			})
		})
	})
}

// bSettings: a narrow centred column, sections as captions over glass rows.
func (s *scene) bSettings() {
	p := s.p
	s.bPage(func(w, h float32) {
		s.bTopBar("", true)
		ui.Box(s.c).Height(12)
		ui.Row(s.c).FillWidth().Grow(1).Justify(ui.Center).AlignItems(ui.Center).Children(func() {
			col := ui.Column(s.c).Width(680).Gap(0)
			col.Children(func() {
				s.t("h1", "设置", s.col(p.Text))
				ui.Box(s.c).Height(6)
				s.t("small", "改动会立即保存，不需要重启。", s.col(p.Text2))
				ui.Box(s.c).Height(26)
				s.bSection("外观", func() {
					s.bSettingRow("主题模式", "跟随系统时，随 macOS 的外观自动切换。", func() {
						s.segmented([]string{"跟随系统", "浅色", "深色"}, 0, 32)
					}, true)
					s.bSettingRow("界面密度", "舒适行高 56，紧凑行高 44。", func() {
						s.segmented([]string{"舒适", "紧凑"}, 0, 32)
					}, true)
					s.bSettingRow("封面动态取色", "用当前封面的颜色铺舞台背景。", func() {
						s.toggle(true)
					}, false)
				})
				ui.Box(s.c).Height(20)
				s.bSection("播放", func() {
					s.bSettingRow("随机播放", "开启后新队列从选中曲目起随机排列。", func() {
						s.toggle(false)
					}, true)
					s.bSettingRow("循环模式", "列表循环；菜单栏与媒体键使用同一状态。", func() {
						s.t("small", "列表循环", s.col(p.Text2))
					}, false)
				})
				ui.Box(s.c).Height(20)
				s.t("numSm", "听屿 "+appVersion+" · libmpv 进程内播放 · "+itoa(s.at.Total)+" 首", s.col(p.Text3))
			})
		})
	})
}

func (s *scene) bSection(title string, rows func()) {
	p := s.p
	ui.Row(s.c).PaddingX(4).Children(func() { s.t("overline", title, s.col(p.Text3)) })
	ui.Box(s.c).Height(8)
	card := ui.Column(s.c).FillWidth().Radius(s.d.Radius.MD).
		Material(glass.Glass{Tint: s.col(p.GlassTint).Alpha(s.p.GlassAlpha + 0.12), Clarity: 0.2}).
		Border(1, s.col(p.Border))
	card.Children(rows)
}

func (s *scene) bSettingRow(label, help string, control func(), divider bool) {
	p := s.p
	row := ui.Row(s.c).FillWidth().Padding(20, 24).Gap(24).AlignItems(ui.Center)
	row.Children(func() {
		ui.Column(s.c).Gap(3).Grow(1).Children(func() {
			s.t("body", label, s.col(p.Text))
			s.t("numSm", help, s.col(p.Text3)).Wrap()
		})
		control()
	})
	if divider {
		ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
	}
}
