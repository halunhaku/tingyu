package main

// pages_a.go draws Direction A (声档 1.5「静室」): the current shell, corrected.
// A full-width glass transport, a translucent sidebar, a cover shelf and a
// track table with a real column rhythm; the stage keeps the two-column
// cover/lyrics split and drops the pill-highlighted lyric line.

import (
	"sort"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
)

func (s *scene) pageA(page string) {
	s.c.Root().Background(s.col(s.p.Canvas))
	switch page {
	case "library":
		s.aLibrary()
	case "stage":
		s.aStage()
	case "sources":
		s.aSources()
	case "settings":
		s.aSettings()
	}
}

// aShell is the sidebar + page + transport frame every non-stage A page uses.
func (s *scene) aShell(page func(mainW, mainH float32)) {
	w, h := s.c.Size()
	root := ui.Column(s.c).Fill().Background(s.col(s.p.Canvas))
	root.Draw(func(p *ui.Painter, r ui.Rect) {
		s.paintAmbient(p, r, s.at.Now.Cover, ui.Rect{X: -200, Y: -280, W: 980, H: 980}, 0.9)
	})
	root.Children(func() {
		ui.Row(s.c).FillWidth().Grow(1).AlignItems(ui.Stretch).Children(func() {
			s.aSidebar(s.d.Metric.Sidebar, h-s.d.Metric.Transport)
			main := ui.Column(s.c).Grow(1).FillHeight()
			main.Children(func() {
				s.aPage(page, w-s.d.Metric.Sidebar, h-s.d.Metric.Transport)
			})
		})
		s.aTransport(w)
	})
}

func (s *scene) aPage(page func(mainW, mainH float32), w, h float32) {
	main := ui.Column(s.c).FillWidth().FillHeight()
	main.Children(func() { page(w, h) })
}

// aSidebar is the translucent navigation column.
func (s *scene) aSidebar(w, h float32) {
	p := s.p
	sidebar := ui.Column(s.c).Width(w).Height(h).Padding(16, 20, 16, 20).Gap(0).
		Material(glass.Glass{Style: glass.Clear, Tint: s.col(p.GlassTint).Alpha(p.GlassAlpha), Clarity: 0.35}).
		BorderWidth(0, 1, 0, 0).BorderColor(s.col(p.Border))
	sidebar.Children(func() {
		// Brand.
		ui.Row(s.c).Height(34).Gap(10).AlignItems(ui.Center).Children(func() {
			logo := ui.Box(s.c).Size(30, 30).Radius(s.d.Radius.SM).Background(s.col(p.Accent)).Center()
			logo.Children(func() { s.icon(glyphNote, 16, s.col(p.OnAccent)) })
			ui.Column(s.c).Gap(1).Children(func() {
				s.t("h3", "听屿", s.col(p.Text))
				s.t("overline", "声档 1.5", s.col(p.Text3))
			})
		})
		ui.Box(s.c).Height(18)
		s.field("搜索歌曲、专辑", w-40, 32, "⌘K")
		ui.Box(s.c).Height(18)

		items := []struct {
			icon   *ui.SVG
			label  string
			active bool
			count  string
		}{
			{glyphLibrary, "曲库", true, itoa(s.at.Total)},
			{glyphHeart, "收藏", false, itoa(s.at.Favorites)},
			{glyphAlbum, "专辑", false, ""},
			{glyphArtist, "艺术家", false, ""},
			{glyphPlaylist, "歌单", false, ""},
			{glyphSearch, "搜索", false, ""},
		}
		for _, it := range items {
			it := it
			row := ui.Row(s.c).FillWidth().Height(34).PaddingX(10).Gap(10).
				Radius(s.d.Radius.SM).AlignItems(ui.Center)
			if it.active {
				row.Background(s.col(p.AccentSoft))
			}
			row.Children(func() {
				color := s.col(p.Text2)
				labelColor := s.col(p.Text2)
				if it.active {
					color = s.col(p.Accent)
					labelColor = s.col(p.Accent)
				}
				s.icon(it.icon, 16, color)
				s.t("body", it.label, labelColor).Grow(1)
				if it.count != "" {
					s.tn("numSm", it.count, s.col(p.Text3))
				}
			})
		}

		ui.Box(s.c).Height(22)
		s.aSidebarSection("来源", "1")
		row := ui.Row(s.c).FillWidth().Height(30).PaddingX(10).Gap(8).Radius(s.d.Radius.SM).AlignItems(ui.Center)
		row.Children(func() {
			s.icon(glyphFolder, 14, s.col(p.Text3))
			s.t("small", s.at.SourceName, s.col(p.Text2)).Grow(1).SingleLine()
			s.tn("numSm", itoa(s.at.Total), s.col(p.Text3))
		})

		ui.Box(s.c).Height(22)
		s.aSidebarSection("歌单", "")
		for _, list := range s.at.Playlists {
			list := list
			row := ui.Row(s.c).FillWidth().Height(30).PaddingX(10).Gap(8).
				Radius(s.d.Radius.SM).AlignItems(ui.Center)
			row.Children(func() {
				s.icon(glyphList, 14, s.col(p.Text3))
				s.t("small", list.Name, s.col(p.Text2)).Grow(1).SingleLine()
				s.tn("numSm", itoa(int(list.Count)), s.col(p.Text3))
			})
		}
		if len(s.at.Playlists) == 0 {
			ui.Row(s.c).PaddingX(10).Height(28).Gap(8).AlignItems(ui.Center).Children(func() {
				s.icon(glyphList, 14, s.col(p.Text3))
				s.t("small", "还没有歌单", s.col(p.Text3))
			})
		}

		ui.Spacer(s.c)
		ui.Box(s.c).Height(1).FillWidth().Background(s.col(p.Border))
		ui.Box(s.c).Height(10)
		setting := ui.Row(s.c).FillWidth().Height(32).PaddingX(10).Gap(10).
			Radius(s.d.Radius.SM).AlignItems(ui.Center)
		setting.Children(func() {
			s.icon(glyphSettings, 16, s.col(p.Text2))
			s.t("body", "设置", s.col(p.Text2)).Grow(1)
		})
		ui.Box(s.c).Height(6)
		ui.Row(s.c).PaddingX(10).Children(func() {
			s.t("numSm", appVersion+" · 内核数据", s.col(p.Text3))
		})
	})
}

func (s *scene) aSidebarSection(label, count string) {
	e := ui.Row(s.c).PaddingX(10).Height(24).AlignItems(ui.Center).Gap(6)
	e.Children(func() {
		s.t("overline", label, s.col(s.p.Text3))
		ui.Spacer(s.c)
		if count != "" {
			s.tn("numSm", count, s.col(s.p.Text3))
		}
	})
	e2 := e
	_ = e2
}

// aToolbar is a page header: big title, meta, and trailing actions.
func (s *scene) aToolbar(w float32, title, meta string, actions func()) {
	e := ui.Row(s.c).FillWidth().Height(64).AlignItems(ui.Center).Gap(16)
	e.Children(func() {
		ui.Column(s.c).Gap(3).Children(func() {
			s.t("h1", title, s.col(s.p.Text))
			s.t("small", meta, s.col(s.p.Text2))
		})
		ui.Spacer(s.c)
		if actions != nil {
			ui.Row(s.c).Gap(8).AlignItems(ui.Center).Children(actions)
		}
	})
}

// aTransport is the full-width glass bar at the bottom of the window.
func (s *scene) aTransport(w float32) {
	h := s.d.Metric.Transport
	s.aTransportBar(w, h)
}

func (s *scene) aTransportBar(w, h float32) {
	p := s.p
	bar := ui.Row(s.c).Width(w).Height(h).Padding(0, 24).Gap(24).AlignItems(ui.Center).
		Material(glass.Glass{Style: glass.Clear, Tint: s.col(p.GlassTint).Alpha(p.GlassAlpha), Clarity: 0.25}).
		BorderWidth(1, 0, 0, 0).BorderColor(s.col(p.Border))
	bar.Children(func() {
		// Now playing.
		ui.Row(s.c).Gap(12).AlignItems(ui.Center).Children(func() {
			s.cover(s.at.Now.Cover, 48, 48, s.d.Radius.SM)
			ui.Column(s.c).Gap(2).Children(func() {
				s.t("h3", s.at.Now.Title, s.col(p.Text))
				s.t("small", s.at.Now.Artist, s.col(p.Text2))
			})
			s.iconButton(28, glyphHeart, s.col(p.Text3))
		})
		ui.Spacer(s.c)
		// Transport + progress.
		ui.Column(s.c).Gap(6).AlignItems(ui.Center).Children(func() {
			ui.Row(s.c).Gap(14).AlignItems(ui.Center).Children(func() {
				s.transportButton(30, glyphShuffle, s.col(p.Text3))
				s.transportButton(32, glyphPrev, s.col(p.Text))
				s.playButton(42, true)
				s.transportButton(32, glyphNext, s.col(p.Text))
				s.transportButton(30, glyphRepeat, s.col(p.Text3))
			})
			ui.Row(s.c).Gap(10).AlignItems(ui.Center).Children(func() {
				s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
				s.progress(300, 0.33, 3, 9)
				s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
			})
		})
		ui.Spacer(s.c)
		// Right controls.
		ui.Row(s.c).Gap(6).AlignItems(ui.Center).Children(func() {
			s.iconButton(28, glyphQueue, s.col(p.Text3))
			s.iconButton(28, glyphLyrics, s.col(p.Text3))
			ui.Row(s.c).Gap(8).AlignItems(ui.Center).Children(func() {
				s.icon(glyphVolume, 15, s.col(p.Text3))
				s.progress(76, 0.8, 3, 9)
			})
		})
	})
}

// aLibrary: shelf of recent covers + the track table.
func (s *scene) aLibrary() {
	s.aShell(func(w, h float32) {
		p := s.p
		page := ui.Column(s.c).FillWidth().Height(h).Padding(28, 36, 20, 36).Gap(0)
		page.Children(func() {
			s.aToolbar(w, "曲库", metaLine(s.at), func() {
				s.field("搜索", 196, 32, "⌘F")
				s.button("排序", false, 32)
				play := ui.Row(s.c).Height(32).PaddingX(14).Gap(6).Radius(s.d.Radius.SM).
					Background(s.col(p.Accent)).AlignItems(ui.Center)
				play.Children(func() {
					s.icon(glyphPlay, 11, s.col(p.OnAccent))
					s.t("label", "播放全部", s.col(p.OnAccent))
				})
			})

			ui.Box(s.c).Height(20)
			ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
				s.t("h3", "最近添加", s.col(p.Text))
				ui.Spacer(s.c)
				s.t("label", "查看全部", s.col(p.Text3))
			})
			ui.Box(s.c).Height(12)
			// Recent covers: six albums added last (the library fills
			// date_added at sync time, so the title is the tie-break).
			recent := make([]track, len(s.at.Tracks))
			copy(recent, s.at.Tracks)
			sort.SliceStable(recent, func(i, j int) bool {
				if !recent[i].DateAdded.Equal(recent[j].DateAdded) {
					return recent[i].DateAdded.After(recent[j].DateAdded)
				}
				return recent[i].Title < recent[j].Title
			})
			ui.Row(s.c).FillWidth().Gap(22).Children(func() {
				seen := map[string]bool{}
				shown := 0
				for _, tr := range recent {
					if shown == 6 || tr.Cover == "" || seen[tr.Album] {
						continue
					}
					seen[tr.Album] = true
					shown++
					tr := tr
					ui.Column(s.c).Width(104).Gap(8).Children(func() {
						cover := s.cover(tr.Cover, 104, 104, s.d.Radius.MD)
						cover.Shadow(0, 6, 16, -4, ui.RGBA(20, 20, 20, 44))
						_ = cover
						s.t("caption", tr.Album, s.col(p.Text)).SingleLine()
						s.t("numSm", tr.Artist, s.col(p.Text3)).SingleLine()
					})
				}
			})

			ui.Box(s.c).Height(26)
			s.aColumns()
			ui.Box(s.c).Height(6)
			// Rows: the current track sits third, the rest follow the library
			// order without repeating it.
			shown := []track{}
			for _, tr := range s.at.Tracks {
				if tr.Duration <= 0 {
					continue
				}
				if tr.Title == s.at.Now.Title && tr.Album == s.at.Now.Album {
					continue
				}
				shown = append(shown, tr)
				if len(shown) == 6 {
					break
				}
			}
			rows := []track{shown[0], shown[1]}
			rows = append(rows, s.at.Now)
			rows = append(rows, shown[2:]...)
			for i, tr := range rows {
				playing := tr.Title == s.at.Now.Title && tr.Album == s.at.Now.Album
				s.aRow(tr, playing, playing, i == 5)
			}
			ui.Spacer(s.c)
			ui.Row(s.c).FillWidth().PaddingY(8).AlignItems(ui.Center).Children(func() {
				s.t("numSm", "已全部加载 · 共 "+itoa(s.at.Total)+" 首", s.col(p.Text3))
				ui.Spacer(s.c)
				s.t("numSm", "按曲名排序", s.col(p.Text3))
			})
		})
	})
}

// aColumns draws the table header. aRow uses the same widths so header and
// rows line up: leading, cover, title, artist, album, spacer, duration, heart.
func (s *scene) aColumns() {
	p := s.p
	ui.Row(s.c).FillWidth().Height(26).AlignItems(ui.Center).Children(func() {
		ui.Box(s.c).Width(22)
		ui.Box(s.c).Width(44)
		s.t("overline", "曲名", s.col(p.Text3)).Width(330)
		s.t("overline", "艺术家", s.col(p.Text3)).Width(170)
		s.t("overline", "专辑", s.col(p.Text3)).Width(210)
		ui.Spacer(s.c)
		ui.Row(s.c).Width(56).Justify(ui.End).Children(func() { s.t("overline", "时长", s.col(p.Text3)) })
		ui.Box(s.c).Width(30)
	})
}

func (s *scene) aRow(tr track, playing, active, selected bool) {
	p := s.p
	row := ui.Row(s.c).FillWidth().Height(s.d.Metric.Row).AlignItems(ui.Center).
		PaddingX(2).Radius(s.d.Radius.SM)
	switch {
	case active:
		row.Background(s.col(p.AccentSoft))
	case selected:
		row.Background(s.col(p.SurfaceRaised)).Border(1, s.col(p.Border))
	}
	row.Children(func() {
		lead := ui.Box(s.c).Width(22).Center()
		lead.Children(func() {
			if playing {
				ui.Row(s.c).Gap(2).AlignItems(ui.End).Children(func() {
					for _, bh := range []float32{5, 11, 8} {
						ui.Box(s.c).Width(2).Height(bh).Radius(1).Background(s.col(p.Accent))
					}
				})
			} else {
				s.icon(glyphPlay, 11, s.col(p.Text3))
			}
		})
		ui.Box(s.c).Width(44).Children(func() {
			s.cover(tr.Cover, 30, 30, s.d.Radius.XS)
		})
		title := s.t("body", tr.Title, s.col(p.Text))
		if playing {
			title.TextColor(s.col(p.Accent))
		}
		title.Width(330).SingleLine()
		ui.Row(s.c).Width(170).Children(func() {
			s.t("small", tr.Artist, s.col(p.Text2)).SingleLine()
		})
		ui.Row(s.c).Width(210).Children(func() {
			s.t("small", tr.Album, s.col(p.Text3)).SingleLine()
		})
		ui.Spacer(s.c)
		ui.Row(s.c).Width(56).Justify(ui.End).Children(func() {
			s.tn("numSm", fmtDuration(tr.Duration.Seconds()), s.col(p.Text3))
		})
		fav := ui.Box(s.c).Width(30).Center()
		fav.Children(func() {
			icon := glyphHeart
			color := s.col(p.Text3)
			if tr.Favorite || active {
				icon = glyphHeartOn
				color = s.col(p.Accent)
			}
			s.icon(icon, 13, color)
		})
	})
}

// aStage: cover and lyrics, one shared element between the table's row cover
// and the stage cover.
func (s *scene) aStage() {
	p := s.p
	from, to, ok := s.stageColors(s.at.Now.Cover)
	if !ok {
		from = s.col(p.SurfaceSunken)
		to = s.col(p.Canvas)
	}
	// A keeps the cover's colour at half strength: a quiet room, not a light
	// show.
	from = mix(from, s.col(p.Canvas), 0.5)
	to = mix(to, s.col(p.Canvas), 0.5)
	w, h := s.c.Size()
	root := ui.Column(s.c).Fill().Gradient(from, to, 165)
	root.Draw(func(p *ui.Painter, r ui.Rect) {
		s.paintAmbient(p, r, s.at.Now.Cover, ui.Rect{X: 0, Y: 0, W: w, H: h}, 0.86)
	})
	root.Children(func() {
		ui.Row(s.c).FillWidth().Height(60).Padding(0, 40).AlignItems(ui.Center).Children(func() {
			back := s.iconButton(32, glyphBack, s.col(p.Text2))
			_ = back
			ui.Box(s.c).Width(10)
			s.t("overline", "正在播放", s.col(p.Text3))
			ui.Spacer(s.c)
			s.iconButton(30, glyphHeart, s.col(p.Text3))
			s.iconButton(30, glyphSearch, s.col(p.Text3))
			s.iconButton(30, glyphClose, s.col(p.Text3))
		})
		content := ui.Row(s.c).FillWidth().Grow(1).Padding(24, 76, 40, 76).Gap(72).AlignItems(ui.Center)
		content.Children(func() {
			// Left: cover, title, progress, transport.
			left := ui.Column(s.c).Width(392).Gap(0).AlignItems(ui.Start)
			left.Children(func() {
				cover := s.cover(s.at.Now.Cover, 392, 392, s.d.Radius.LG)
				cover.Shadow(0, 28, 60, -18, ui.RGBA(0, 0, 0, 110))
				_ = cover
				ui.Box(s.c).Height(26)
				s.t("display", s.at.Now.Title, s.col(p.Text))
				ui.Box(s.c).Height(8)
				s.t("body", s.at.Now.Artist, s.col(p.Text2))
				ui.Box(s.c).Height(24)
				ui.Row(s.c).Width(392).AlignItems(ui.Center).Children(func() {
					s.progress(392, 0.33, 4, 12)
				})
				ui.Box(s.c).Height(6)
				ui.Row(s.c).Width(392).Children(func() {
					s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
					ui.Spacer(s.c)
					s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
				})
				ui.Box(s.c).Height(18)
				ui.Row(s.c).Width(392).Gap(18).AlignItems(ui.Center).Justify(ui.Center).Children(func() {
					s.transportButton(30, glyphShuffle, s.col(p.Text3))
					s.transportButton(34, glyphPrev, s.col(p.Text))
					s.playButton(52, true)
					s.transportButton(34, glyphNext, s.col(p.Text))
					s.transportButton(30, glyphRepeat, s.col(p.Text3))
				})
			})

			// Right: lyrics and up next.
			right := ui.Column(s.c).Grow(1).FillHeight().Justify(ui.Center).Gap(0)
			right.Children(func() {
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("overline", "歌词", s.col(p.Text3))
					ui.Spacer(s.c)
					s.t("numSm", "LRC · 行级", s.col(p.Text3))
				})
				ui.Box(s.c).Height(22)
				active := s.at.activeLyric()
				first := max(0, active-3)
				last := min(len(s.at.Lyrics), active+5)
				for i := first; i < last; i++ {
					line := s.at.Lyrics[i]
					if i == active {
						row := ui.Row(s.c).FillWidth().Gap(14).AlignItems(ui.Center).PaddingY(2)
						row.Children(func() {
							ui.Box(s.c).Width(2).Height(24).Radius(1).Background(s.col(p.Accent))
							s.t("lyricActive", line.Text, s.col(p.Text)).SingleLine()
						})
						ui.Box(s.c).Height(8)
					} else {
						dim := 0.55
						if i < active {
							dim = 0.45
						}
						color := s.col(p.Text2).Alpha(float32(dim))
						ui.Row(s.c).FillWidth().Padding(14, 0).Gap(14).AlignItems(ui.Center).Height(34).Children(func() {
							s.t("lyric", line.Text, color).SingleLine()
						})
					}
				}
				ui.Box(s.c).Height(24)
				ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
				ui.Box(s.c).Height(16)
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("overline", "接下来", s.col(p.Text3))
					ui.Spacer(s.c)
					s.t("numSm", "共 24 首", s.col(p.Text3))
				})
				ui.Box(s.c).Height(6)
				for i := 1; i < min(4, len(s.at.Queue)); i++ {
					q := s.at.Queue[i]
					row := ui.Row(s.c).FillWidth().Height(34).Gap(10).AlignItems(ui.Center)
					row.Children(func() {
						s.cover(q.Cover, 24, 24, s.d.Radius.XS)
						s.t("label", q.Title, s.col(p.Text2)).Grow(1).SingleLine()
						s.tn("numSm", fmtDuration(q.Duration.Seconds()), s.col(p.Text3))
					})
				}
			})
		})
	})
	_ = root
}

// aSources: one source card, an info panel, no documentation cards.
func (s *scene) aSources() {
	s.aShell(func(w, h float32) {
		p := s.p
		page := ui.Column(s.c).FillWidth().Height(h).Padding(32, 36, 28, 36).Gap(0)
		page.Children(func() {
			label, warning, detail, when := s.syncState()
			statusColor := p.Success
			if warning {
				statusColor = p.Warning
			}
			s.aToolbar(w, "来源", "1 个来源 · "+itoa(s.at.Total)+" 首", func() {
				add := ui.Row(s.c).Height(32).PaddingX(14).Gap(6).Radius(s.d.Radius.SM).
					Background(s.col(p.Accent)).AlignItems(ui.Center)
				add.Children(func() {
					s.icon(glyphPlus, 12, s.col(p.OnAccent))
					s.t("label", "添加来源", s.col(p.OnAccent))
				})
			})
			ui.Box(s.c).Height(24)
			ui.Row(s.c).FillWidth().Gap(32).AlignItems(ui.Start).Children(func() {
				// The card.
				card := ui.Column(s.c).Grow(1).Padding(22).Gap(18).
					Radius(s.d.Radius.LG).Background(s.col(p.SurfaceRaised)).
					Border(1, s.col(p.Border))
				card.Shadow(0, 8, 24, -12, ui.RGBA(20, 20, 20, 40))
				card.Children(func() {
					ui.Row(s.c).FillWidth().Gap(14).AlignItems(ui.Center).Children(func() {
						tile := ui.Box(s.c).Size(46, 46).Radius(s.d.Radius.MD).
							Background(s.col(p.AccentSoft)).Center()
						tile.Children(func() { s.icon(glyphFolder, 22, s.col(p.Accent)) })
						ui.Column(s.c).Gap(3).Children(func() {
							s.t("h3", s.at.SourceName, s.col(p.Text))
							s.t("small", "直链播放 · "+itoa(s.at.Total)+" 首", s.col(p.Text2))
						})
						ui.Spacer(s.c)
						s.statusDot(s.col(statusColor), label)
					})
					ui.Box(s.c).Height(1).FillWidth().Background(s.col(p.Border))
					ui.Row(s.c).FillWidth().Gap(24).Children(func() {
						ui.Column(s.c).Gap(4).Children(func() {
							s.t("numSm", "上次同步", s.col(p.Text3))
							s.t("small", when, s.col(p.Text2))
						})
						ui.Column(s.c).Gap(4).Children(func() {
							s.t("numSm", "同步结果", s.col(p.Text3))
							s.t("small", valueOr(detail, "—"), s.col(p.Text2)).SingleLine()
						})
					})
					ui.Row(s.c).Gap(8).AlignItems(ui.Center).Children(func() {
						primary := s.button("立即同步", true, 30)
						_ = primary
						s.button("查看曲目", false, 30)
						s.iconButton(30, glyphMore, s.col(p.Text3))
					})
				})

				// The info panel, replacing the three documentation cards.
				info := ui.Column(s.c).Width(288).Gap(10).Padding(4, 0, 0, 0)
				info.Children(func() {
					s.t("h3", "远程来源", s.col(p.Text))
					for _, line := range []string{
						"凭据只保存在系统钥匙串，不写入曲库。",
						"同步可以随时取消，已经扫描的曲目会保留。",
						"直链过期时会在加载阶段自动刷新一次。",
					} {
						row := ui.Row(s.c).Gap(8).AlignItems(ui.Start)
						row.Children(func() {
							dot := ui.Box(s.c).Size(4, 4).Radius(2).Background(s.col(p.Text3))
							dot.Margin(7, 0, 0, 0)
							_ = dot
							s.t("small", line, s.col(p.Text2)).Wrap()
						})
					}
					ui.Box(s.c).Height(8)
					ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
					ui.Box(s.c).Height(8)
					s.t("numSm", "可添加的类型", s.col(p.Text3))
					s.t("small", "本地目录 · WebDAV · 夸克网盘", s.col(p.Text2))
				})
			})
			ui.Box(s.c).Height(36)
			ui.Row(s.c).FillWidth().Gap(56).Children(func() {
				for _, stat := range [][2]string{
					{"曲目", itoa(s.at.Total)},
					{"专辑", itoa(s.at.AlbumCount)},
					{"艺术家", itoa(s.at.ArtistCount)},
					{"来源", "1"},
					{"上次同步", when[:10]},
				} {
					ui.Column(s.c).Gap(4).Children(func() {
						s.t("overline", stat[0], s.col(p.Text3))
						s.tn("h3", stat[1], s.col(p.Text2))
					})
				}
			})
		})
	})
}

// aSettings: horizontal section tabs, grouped rows, no second nav column.
func (s *scene) aSettings() {
	s.aShell(func(w, h float32) {
		p := s.p
		page := ui.Column(s.c).FillWidth().Height(h).Padding(32, 36, 28, 36).Gap(0)
		page.Children(func() {
			s.aToolbar(w, "设置", "改动会立即保存，不需要重启。", nil)
			ui.Box(s.c).Height(14)
			// Section tabs.
			tabs := []string{"外观", "播放", "音乐库", "元数据", "来源", "数据", "关于"}
			ui.Row(s.c).FillWidth().Height(36).Gap(24).AlignItems(ui.Center).Children(func() {
				for i, label := range tabs {
					i, label := i, label
					cell := ui.Column(s.c).Gap(8).AlignItems(ui.Center).Children(func() {
						color := s.col(p.Text2)
						if i == 0 {
							color = s.col(p.Text)
						}
						s.t("body", label, color)
						bar := ui.Box(s.c).Width(18).Height(2).Radius(1)
						if i == 0 {
							bar.Background(s.col(p.Accent))
						}
						_ = bar
					})
					_ = cell
				}
			})
			ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
			ui.Box(s.c).Height(24)
			ui.Row(s.c).FillWidth().Gap(40).AlignItems(ui.Start).Children(func() {
				ui.Column(s.c).Width(620).Gap(20).Children(func() {
					// Appearance group.
					card := ui.Column(s.c).FillWidth().Radius(s.d.Radius.LG).
						Background(s.col(p.SurfaceRaised)).Border(1, s.col(p.Border))
					card.Children(func() {
						s.aSettingRow("主题模式", "跟随系统时，随 macOS 的外观自动切换。", func() {
							s.segmented([]string{"跟随系统", "浅色", "深色"}, 0, 30)
						}, true)
						s.aSettingRow("界面密度", "舒适行高 44，紧凑行高 40。", func() {
							s.segmented([]string{"舒适", "紧凑"}, 0, 30)
						}, true)
						s.aSettingRow("封面动态取色", "用当前封面的颜色铺舞台背景；关掉后使用中性色。", func() {
							s.toggle(true)
						}, false)
						ui.Row(s.c).Padding(20, 20).Children(func() {
							s.button("恢复默认外观", false, 30)
						})
					})
					// Playback group.
					card2 := ui.Column(s.c).FillWidth().Radius(s.d.Radius.LG).
						Background(s.col(p.SurfaceRaised)).Border(1, s.col(p.Border))
					card2.Children(func() {
						s.aSettingRow("随机播放", "开启后新队列从选中曲目起随机排列。", func() {
							s.toggle(false)
						}, true)
						s.aSettingRow("循环模式", "列表循环；菜单栏与媒体键使用同一状态。", func() {
							s.t("small", "列表循环", s.col(p.Text2))
						}, false)
					})
				})
				// Right: about, the real version and engine rows.
				about := ui.Column(s.c).Grow(1).Padding(22).Gap(12).
					Radius(s.d.Radius.LG).Background(s.col(p.SurfaceRaised)).
					Border(1, s.col(p.Border))
				about.Children(func() {
					s.t("overline", "关于", s.col(p.Text3))
					s.t("h3", "听屿 "+appVersion, s.col(p.Text))
					s.t("small", "私人音乐库播放器，直连你的来源。", s.col(p.Text2)).Wrap()
					ui.Box(s.c).Height(6)
					ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
					ui.Box(s.c).Height(4)
					for _, row := range [][2]string{
						{"播放内核", "libmpv"},
						{"媒体会话", "系统 Now Playing"},
						{"数据", itoa(s.at.Total) + " 首 · 1 个来源"},
					} {
						ui.Row(s.c).FillWidth().Height(26).AlignItems(ui.Center).Children(func() {
							s.t("small", row[0], s.col(p.Text3))
							ui.Spacer(s.c)
							s.t("small", row[1], s.col(p.Text2))
						})
					}
				})
			})
		})
	})
}

func (s *scene) aSettingRow(label, help string, control func(), divider bool) {
	p := s.p
	row := ui.Row(s.c).FillWidth().Padding(20, 18).Gap(24).AlignItems(ui.Center)
	row.Children(func() {
		ui.Column(s.c).Gap(2).Grow(1).Children(func() {
			s.t("body", label, s.col(p.Text))
			s.t("numSm", help, s.col(p.Text3)).Wrap()
		})
		control()
	})
	if divider {
		ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
	}
}

func metaLine(at *data) string {
	return itoa(at.Total) + " 首 · " + at.SourceName + " · " + itoa(at.AlbumCount) + " 张专辑"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
