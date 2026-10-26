package main

// pages_c.go draws Direction C (控制台「灰阶」): dense, keyboard-first, numbers
// in tabular figures. The sidebar is narrow, the table is the page, the
// inspector shows what is playing and what it is made of, and the transport is
// a 56 DIP bar across the whole window.

import (
	"fmt"
	"os"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
)

func (s *scene) pageC(page string) {
	s.c.Root().Background(s.col(s.p.Canvas))
	switch page {
	case "library":
		s.cLibrary()
	case "stage":
		s.cStage()
	case "sources":
		s.cSources()
	case "settings":
		s.cSettings()
	}
}

// cShell is the sidebar + page + 56 DIP transport every non-stage C page uses.
func (s *scene) cShell(page func(mainW, mainH float32)) {
	w, h := s.c.Size()
	ui.Column(s.c).Fill().Children(func() {
		ui.Row(s.c).FillWidth().Grow(1).AlignItems(ui.Stretch).Children(func() {
			s.cSidebar(s.d.Metric.Sidebar, h-s.d.Metric.Transport)
			ui.Column(s.c).Grow(1).FillHeight().Children(func() {
				page(w-s.d.Metric.Sidebar, h-s.d.Metric.Transport)
			})
		})
		s.cTransport(w)
	})
}

func (s *scene) cSidebar(w, h float32) {
	p := s.p
	bar := ui.Column(s.c).Width(w).Height(h).Padding(12, 12).Gap(0).
		Material(glass.Glass{Style: glass.Clear, Tint: s.col(p.GlassTint).Alpha(s.p.GlassAlpha), Clarity: 0.2}).
		BorderWidth(0, 1, 0, 0).BorderColor(s.col(p.Border))
	bar.Children(func() {
		ui.Row(s.c).Height(30).PaddingX(8).Gap(8).AlignItems(ui.Center).Children(func() {
			logo := ui.Box(s.c).Size(22, 22).Radius(5).Background(s.col(p.Accent)).Center()
			logo.Children(func() { s.icon(glyphNote, 12, s.col(p.OnAccent)) })
			s.t("h2", "听屿", s.col(p.Text))
			ui.Spacer(s.c)
			s.tn("numSm", appVersion, s.col(p.Text3))
		})
		ui.Box(s.c).Height(14)
		s.cSideSection("资料库")
		for i, item := range []struct {
			icon  *ui.SVG
			label string
			count string
		}{
			{glyphLibrary, "曲库", itoa(s.at.Total)},
			{glyphHeart, "收藏", itoa(s.at.Favorites)},
			{glyphAlbum, "专辑", itoa(s.at.AlbumCount)},
			{glyphArtist, "艺术家", itoa(s.at.ArtistCount)},
			{glyphPlaylist, "歌单", itoa(len(s.at.Playlists))},
		} {
			item := item
			s.cSideItem(item.icon, item.label, item.count, i == 0)
		}
		ui.Box(s.c).Height(14)
		s.cSideSection("来源")
		s.cSideItem(glyphFolder, s.at.SourceName, itoa(s.at.Total), false)
		ui.Box(s.c).Height(14)
		s.cSideSection("工具")
		s.cSideItem(glyphSearch, "搜索", "⌘K", false)
		s.cSideItem(glyphSettings, "设置", "", false)
		ui.Spacer(s.c)
		ui.Box(s.c).Height(1).FillWidth().Background(s.col(p.Border))
		ui.Box(s.c).Height(8)
		syncLabel, syncWarning, _, syncWhen := s.syncState()
		syncColor := p.Success
		if syncWarning {
			syncColor = p.Warning
		}
		ui.Row(s.c).PaddingX(8).Gap(6).AlignItems(ui.Center).Children(func() {
			ui.Box(s.c).Size(6, 6).Radius(3).Background(s.col(syncColor))
			s.t("numSm", syncLabel+" · "+syncWhen[:10], s.col(p.Text3)).SingleLine()
		})
	})
}

func (s *scene) cSideSection(label string) {
	e := ui.Row(s.c).Height(22).PaddingX(8).AlignItems(ui.Center)
	e.Children(func() { s.t("overline", label, s.col(s.p.Text3)) })
}

func (s *scene) cSideItem(svg *ui.SVG, label, tail string, active bool) {
	p := s.p
	row := ui.Row(s.c).FillWidth().Height(30).PaddingX(8).Gap(9).Radius(s.d.Radius.SM).AlignItems(ui.Center)
	if active {
		row.Background(s.col(p.AccentSoft))
		bar := ui.Box(s.c).Width(2).Height(14).Radius(1).Background(s.col(p.Accent))
		_ = bar
	}
	row.Children(func() {
		color := s.col(p.Text2)
		if active {
			color = s.col(p.Accent)
		}
		s.icon(svg, 14, color)
		s.t("body", label, color).Grow(1).SingleLine()
		if tail != "" {
			s.tn("numSm", tail, s.col(p.Text3))
		}
	})
}

// cToolbar is the 48 DIP page bar: title, search, and view controls.
func (s *scene) cToolbar(w float32) {
	p := s.p
	bar := ui.Row(s.c).FillWidth().Height(48).PaddingX(20).Gap(10).AlignItems(ui.Center).
		Background(s.col(p.Surface))
	bar.Children(func() {
		s.t("h1", "曲库", s.col(p.Text)).SingleLine()
		s.tn("numSm", itoa(s.at.Total)+" 首 · "+itoa(s.at.AlbumCount)+" 张专辑", s.col(p.Text3)).SingleLine()
		ui.Spacer(s.c)
		s.field("搜索曲库", 230, 28, "⌘K")
		s.button("排序：曲名", false, 28)
		s.button("筛选", false, 28)
		ui.Row(s.c).Height(28).Padding(8, 2).Radius(s.d.Radius.SM).
			Background(s.col(p.SurfaceSunken)).Gap(2).AlignItems(ui.Center).Children(func() {
			s.icon(glyphList, 14, s.col(p.Text2))
			s.icon(glyphGrid, 14, s.col(p.Text3))
		})
		s.button("添加目录", true, 28)
	})
	ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
}

// cLibrary: the dense table, with the inspector on the right.
func (s *scene) cLibrary() {
	s.cShell(func(w, h float32) {
		ui.Column(s.c).FillWidth().Height(h).Children(func() {
			s.cToolbar(w)
			ui.Row(s.c).FillWidth().Grow(1).Children(func() {
				table := ui.Column(s.c).Grow(1).FillHeight()
				table.Children(func() {
					s.cTableHeader()
					rows := []track{}
					for _, tr := range s.at.Tracks {
						if tr.Duration <= 0 {
							continue
						}
						if tr.Title == s.at.Now.Title && tr.Album == s.at.Now.Album {
							continue
						}
						rows = append(rows, tr)
						if len(rows) == 15 {
							break
						}
					}
					out := []track{rows[0], rows[1], s.at.Now}
					out = append(out, rows[2:]...)
					for i, tr := range out {
						playing := tr.Title == s.at.Now.Title && tr.Album == s.at.Now.Album
						s.cTableRow(tr, i+1, playing, i == 4)
					}
					ui.Spacer(s.c)
					ui.Row(s.c).FillWidth().Height(32).PaddingX(20).AlignItems(ui.Center).Children(func() {
						s.tn("numSm", "已加载 "+itoa(s.at.Total)+" / "+itoa(s.at.Total)+" 首", p3(s))
						ui.Spacer(s.c)
						s.tn("numSm", "⌘K 命令面板 · ↑↓ 选择 · ↵ 播放", p3(s))
					})
				})
				s.cInspector(w, h-48)
			})
		})
	})
}

func p3(s *scene) ui.Color { return s.col(s.p.Text3) }

func (s *scene) cTableHeader() {
	p := s.p
	ui.Row(s.c).FillWidth().Height(26).PaddingX(20).AlignItems(ui.Center).Children(func() {
		ui.Box(s.c).Width(26)
		s.t("overline", "曲名", s.col(p.Text3)).Grow(1)
		s.t("overline", "艺术家", s.col(p.Text3)).Width(120)
		s.t("overline", "专辑", s.col(p.Text3)).Width(150)
		s.t("overline", "来源", s.col(p.Text3)).Width(90)
		ui.Row(s.c).Width(52).Justify(ui.End).Children(func() { s.t("overline", "时长", s.col(p.Text3)) })
		ui.Box(s.c).Width(26)
	})
	ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
}

func (s *scene) cTableRow(tr track, index int, playing, selected bool) {
	p := s.p
	row := ui.Row(s.c).FillWidth().Height(s.d.Metric.Row).PaddingX(20).AlignItems(ui.Center)
	switch {
	case playing:
		row.Background(s.col(p.AccentSoft)).BorderWidth(0, 0, 0, 2).BorderColor(s.col(p.Accent))
	case selected:
		row.Background(s.col(p.SurfaceRaised)).Border(1, s.col(p.BorderStrong))
	}
	row.Children(func() {
		ui.Row(s.c).Width(26).Children(func() { s.tn("numSm", itoa2(index), s.col(p.Text3)) })
		title := s.t("body", tr.Title, s.col(p.Text))
		if playing {
			title.TextColor(s.col(p.Accent))
		}
		title.Grow(1).SingleLine()
		ui.Row(s.c).Width(120).Children(func() {
			s.t("small", tr.Artist, s.col(p.Text2)).MaxWidth(118).SingleLine()
		})
		ui.Row(s.c).Width(150).Children(func() {
			s.t("small", tr.Album, s.col(p.Text3)).MaxWidth(148).SingleLine()
		})
		ui.Row(s.c).Width(90).Children(func() {
			s.t("small", s.at.SourceName, s.col(p.Text3)).MaxWidth(88).SingleLine()
		})
		ui.Row(s.c).Width(52).Justify(ui.End).Children(func() {
			s.tn("numSm", fmtDuration(tr.Duration.Seconds()), s.col(p.Text3))
		})
		fav := ui.Box(s.c).Width(26).Center()
		fav.Children(func() {
			if tr.Favorite || playing {
				s.icon(glyphHeartOn, 11, s.col(p.Accent))
				return
			}
			s.icon(glyphHeart, 11, s.col(p.Text3))
		})
	})
	ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border).Alpha(0.6))
}

func (s *scene) cInspector(w, h float32) {
	p := s.p
	insp := ui.Column(s.c).Width(280).Height(h).Padding(16, 16).Gap(0).
		Background(s.col(p.SurfaceSunken)).BorderWidth(0, 0, 0, 1).BorderColor(s.col(p.Border))
	insp.Children(func() {
		ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
			s.t("overline", "正在播放", s.col(p.Text3))
			ui.Spacer(s.c)
			s.iconButton(22, glyphMore, s.col(p.Text3))
		})
		ui.Box(s.c).Height(10)
		ui.Row(s.c).Gap(10).AlignItems(ui.Center).Children(func() {
			s.cover(s.at.Now.Cover, 52, 52, s.d.Radius.SM)
			ui.Column(s.c).Gap(2).Grow(1).Children(func() {
				s.t("body", s.at.Now.Title, s.col(p.Text)).SingleLine()
				s.t("numSm", s.at.Now.Artist, s.col(p.Text3)).SingleLine()
			})
			s.icon(glyphHeartOn, 12, s.col(p.Accent))
		})
		ui.Box(s.c).Height(12)
		s.progress(248, 0.33, 3, 9)
		ui.Box(s.c).Height(6)
		ui.Row(s.c).Width(248).Children(func() {
			s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
			ui.Spacer(s.c)
			s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
		})
		ui.Box(s.c).Height(10)
		ui.Row(s.c).Width(248).Gap(8).AlignItems(ui.Center).Justify(ui.Center).Children(func() {
			s.iconButton(24, glyphShuffle, s.col(p.Text3))
			s.transportButton(24, glyphPrev, s.col(p.Text))
			s.playButton(32, true)
			s.transportButton(24, glyphNext, s.col(p.Text))
			s.iconButton(24, glyphRepeat, s.col(p.Text3))
		})
		ui.Box(s.c).Height(14)
		ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
		ui.Box(s.c).Height(12)
		ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
			s.t("overline", "接下来", s.col(p.Text3))
			ui.Spacer(s.c)
			s.tn("numSm", "共 24 首", s.col(p.Text3))
		})
		ui.Box(s.c).Height(4)
		for i := 1; i < 6; i++ {
			q := s.at.Queue[i]
			row := ui.Row(s.c).FillWidth().Height(28).Gap(8).AlignItems(ui.Center)
			row.Children(func() {
				s.tn("numSm", itoa2(i+1), s.col(p.Text3)).Width(16)
				s.t("small", q.Title, s.col(p.Text2)).Grow(1).SingleLine()
				s.tn("numSm", fmtDuration(q.Duration.Seconds()), s.col(p.Text3))
			})
		}
		ui.Box(s.c).Height(14)
		ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
		ui.Box(s.c).Height(12)
		s.t("overline", "音频", s.col(p.Text3))
		ui.Box(s.c).Height(6)
		for _, row := range [][2]string{
			{"格式", valueOr(s.at.Now.Format, "—")},
			{"比特率", bitrate(s.at.Now.Bitrate)},
			{"采样率", sampleRate(s.at.Now.SampleRate)},
			{"文件大小", kmb(s.at.Now.Size)},
		} {
			ui.Row(s.c).FillWidth().Height(24).AlignItems(ui.Center).Children(func() {
				s.t("numSm", row[0], s.col(p.Text3))
				ui.Spacer(s.c)
				s.tn("numSm", row[1], s.col(p.Text2))
			})
		}
	})
}

// cTransport is the 56 DIP bar across the whole window.
func (s *scene) cTransport(w float32) {
	p := s.p
	bar := ui.Row(s.c).Width(w).Height(s.d.Metric.Transport).PaddingX(16).Gap(16).AlignItems(ui.Center).
		Background(s.col(p.SurfaceRaised)).BorderWidth(1, 0, 0, 0).BorderColor(s.col(p.Border))
	bar.Children(func() {
		ui.Row(s.c).Width(300).Gap(10).AlignItems(ui.Center).Children(func() {
			s.cover(s.at.Now.Cover, 36, 36, s.d.Radius.XS)
			ui.Column(s.c).Gap(1).Children(func() {
				s.t("label", s.at.Now.Title, s.col(p.Text)).SingleLine()
				s.t("numSm", s.at.Now.Artist, s.col(p.Text3)).SingleLine()
			})
			s.icon(glyphHeartOn, 12, s.col(p.Accent))
		})
		ui.Spacer(s.c)
		ui.Row(s.c).Gap(6).AlignItems(ui.Center).Children(func() {
			s.iconButton(24, glyphShuffle, s.col(p.Text3))
			s.transportButton(26, glyphPrev, s.col(p.Text))
			s.playButton(34, true)
			s.transportButton(26, glyphNext, s.col(p.Text))
			s.iconButton(24, glyphRepeat, s.col(p.Text3))
		})
		ui.Box(s.c).Width(10)
		s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
		s.progress(230, 0.33, 3, 8)
		s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
		ui.Spacer(s.c)
		s.iconButton(24, glyphLyrics, s.col(p.Text3))
		s.iconButton(24, glyphQueue, s.col(p.Text3))
		s.icon(glyphVolume, 13, s.col(p.Text3))
		s.progress(72, 0.8, 3, 8)
	})
}

// cStage: cover and technical facts on the left, lyrics in the middle, queue on
// the right; no global transport, the page owns its controls.
func (s *scene) cStage() {
	p := s.p
	ui.Column(s.c).Fill().Children(func() {
		ui.Row(s.c).FillWidth().Height(44).PaddingX(20).Gap(12).AlignItems(ui.Center).
			Background(s.col(p.Surface)).Children(func() {
			s.iconButton(24, glyphBack, s.col(p.Text2))
			s.t("overline", "正在播放", s.col(p.Text3))
			ui.Spacer(s.c)
			s.iconButton(24, glyphHeartOn, s.col(p.Accent))
			s.iconButton(24, glyphMore, s.col(p.Text3))
			s.iconButton(24, glyphClose, s.col(p.Text3))
		})
		ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
		ui.Row(s.c).FillWidth().Grow(1).Children(func() {
			// Left: cover + facts.
			left := ui.Column(s.c).Width(392).FillHeight().Padding(36, 32).Gap(0).
				BorderWidth(0, 1, 0, 0).BorderColor(s.col(p.Border))
			left.Children(func() {
				cover := s.cover(s.at.Now.Cover, 328, 328, s.d.Radius.SM)
				cover.Shadow(0, 18, 40, -18, ui.RGBA(0, 0, 0, 90))
				_ = cover
				ui.Box(s.c).Height(22)
				s.t("display", s.at.Now.Title, s.col(p.Text)).SingleLine()
				ui.Box(s.c).Height(6)
				s.t("body", s.at.Now.Artist, s.col(p.Text2))
				ui.Box(s.c).Height(4)
				meta := s.at.Now.Album
				if s.at.Now.Year > 0 {
					meta += " · " + itoa(s.at.Now.Year)
				}
				s.t("numSm", meta, s.col(p.Text3)).SingleLine()
				ui.Box(s.c).Height(20)
				s.progress(328, 0.33, 3, 11)
				ui.Box(s.c).Height(6)
				ui.Row(s.c).Width(328).Children(func() {
					s.tn("numSm", fmtDuration(float64(s.at.Position.Seconds())), s.col(p.Text3))
					ui.Spacer(s.c)
					s.tn("numSm", fmtDuration(s.at.Now.Duration.Seconds()), s.col(p.Text3))
				})
				ui.Box(s.c).Height(14)
				ui.Row(s.c).Width(328).Gap(10).AlignItems(ui.Center).Justify(ui.Center).Children(func() {
					s.transportButton(26, glyphShuffle, s.col(p.Text3))
					s.transportButton(28, glyphPrev, s.col(p.Text))
					s.playButton(40, true)
					s.transportButton(28, glyphNext, s.col(p.Text))
					s.transportButton(26, glyphRepeat, s.col(p.Text3))
				})
				ui.Spacer(s.c)
				ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
				ui.Box(s.c).Height(10)
				for _, row := range [][2]string{
					{"格式", valueOr(s.at.Now.Format, "—")},
					{"比特率", bitrate(s.at.Now.Bitrate)},
					{"采样率", sampleRate(s.at.Now.SampleRate)},
					{"大小", kmb(s.at.Now.Size)},
				} {
					ui.Row(s.c).FillWidth().Height(22).AlignItems(ui.Center).Children(func() {
						s.t("numSm", row[0], s.col(p.Text3))
						ui.Spacer(s.c)
						s.tn("numSm", row[1], s.col(p.Text2))
					})
				}
			})
			// Middle: lyrics.
			lyrics := ui.Column(s.c).Grow(1).FillHeight().Padding(36, 32).Gap(0).
				BorderWidth(0, 1, 0, 0).BorderColor(s.col(p.Border))
			lyrics.Children(func() {
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("h2", "歌词", s.col(p.Text))
					ui.Spacer(s.c)
					s.t("numSm", "行级 LRC", s.col(p.Text3))
				})
				ui.Box(s.c).Height(18)
				active := s.at.activeLyric()
				first := max(0, active-4)
				last := min(len(s.at.Lyrics), active+6)
				for i := first; i < last; i++ {
					line := s.at.Lyrics[i]
					if i == active {
						row := ui.Row(s.c).FillWidth().Gap(12).AlignItems(ui.Center).PaddingY(4)
						row.Children(func() {
							ui.Box(s.c).Width(2).Height(22).Radius(1).Background(s.col(p.Accent))
							s.t("lyricActive", line.Text, s.col(p.Accent)).SingleLine()
						})
						ui.Box(s.c).Height(6)
						continue
					}
					ui.Box(s.c).Height(10)
					color := s.col(p.Text3)
					if i < active {
						color = s.col(p.Text3).Alpha(0.7)
					}
					s.t("lyric", line.Text, color).SingleLine()
				}
			})
			// Right: queue.
			right := ui.Column(s.c).Width(300).FillHeight().Padding(16, 16).Gap(0)
			right.Children(func() {
				ui.Row(s.c).FillWidth().AlignItems(ui.Center).Children(func() {
					s.t("overline", "接下来", s.col(p.Text3))
					ui.Spacer(s.c)
					s.tn("numSm", "共 24 首", s.col(p.Text3))
				})
				ui.Box(s.c).Height(8)
				for i := 1; i < min(11, len(s.at.Queue)); i++ {
					q := s.at.Queue[i]
					row := ui.Row(s.c).FillWidth().Height(28).Gap(8).AlignItems(ui.Center)
					if i == 1 {
						row.Background(s.col(p.AccentSoft))
					}
					row.Children(func() {
						s.tn("numSm", itoa2(i+1), s.col(p.Text3)).Width(16)
						s.t("small", q.Title, s.col(p.Text2)).Grow(1).SingleLine()
						s.tn("numSm", fmtDuration(q.Duration.Seconds()), s.col(p.Text3))
					})
				}
				ui.Spacer(s.c)
				ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
				ui.Box(s.c).Height(10)
				s.t("overline", "操作", s.col(p.Text3))
				ui.Box(s.c).Height(6)
				for _, hint := range []string{"Space 播放 / 暂停", "← → 快退快进 5 秒", "Esc 关闭舞台"} {
					ui.Row(s.c).FillWidth().Height(22).Children(func() {
						s.t("numSm", hint, s.col(p.Text3))
					})
				}
			})
		})
	})
}

func surfaceOf(s *scene) ui.Color { return s.col(s.p.Surface) }

// cSources: a table of sources and the three ways to add one, no cards.
func (s *scene) cSources() {
	s.cShell(func(w, h float32) {
		p := s.p
		label, warning, detail, when := s.syncState()
		statusColor := p.Success
		if warning {
			statusColor = p.Warning
		}
		ui.Column(s.c).FillWidth().Height(h).Children(func() {
			ui.Row(s.c).FillWidth().Height(48).PaddingX(20).Gap(10).AlignItems(ui.Center).
				Background(surfaceOf(s)).Children(func() {
				s.t("h1", "来源", s.col(p.Text)).SingleLine()
				s.tn("numSm", "1 个来源 · "+itoa(s.at.Total)+" 首 · 最近同步 "+when, s.col(p.Text3)).SingleLine()
				ui.Spacer(s.c)
				s.button("添加来源", true, 28)
			})
			ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
			ui.Row(s.c).FillWidth().Height(26).PaddingX(20).AlignItems(ui.Center).Children(func() {
				s.t("overline", "名称", s.col(p.Text3)).Grow(1)
				s.t("overline", "类型", s.col(p.Text3)).Width(110)
				s.t("overline", "曲目", s.col(p.Text3)).Width(70)
				s.t("overline", "上次同步", s.col(p.Text3)).Width(150)
				s.t("overline", "状态", s.col(p.Text3)).Width(90)
				ui.Box(s.c).Width(150)
			})
			ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
			row := ui.Row(s.c).FillWidth().Height(44).PaddingX(20).AlignItems(ui.Center)
			row.Children(func() {
				ui.Row(s.c).Grow(1).Gap(10).AlignItems(ui.Center).Children(func() {
					s.icon(glyphFolder, 14, s.col(p.Text2))
					s.t("body", s.at.SourceName, s.col(p.Text))
				})
				ui.Row(s.c).Width(110).Children(func() { s.t("small", "夸克网盘", s.col(p.Text2)) })
				ui.Row(s.c).Width(70).Children(func() { s.tn("numSm", itoa(s.at.Total), s.col(p.Text2)) })
				ui.Row(s.c).Width(150).Children(func() { s.tn("numSm", when, s.col(p.Text3)) })
				ui.Row(s.c).Width(120).Gap(6).AlignItems(ui.Center).Children(func() {
					ui.Box(s.c).Size(6, 6).Radius(3).Background(s.col(statusColor))
					s.t("small", label, s.col(p.Text2)).SingleLine()
				})
				ui.Row(s.c).Width(150).Gap(6).Children(func() {
					s.button("立即同步", false, 24)
					s.iconButton(24, glyphMore, s.col(p.Text3))
				})
			})
			ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
			ui.Box(s.c).Height(26)
			ui.Row(s.c).PaddingX(20).Children(func() { s.t("overline", "添加来源", s.col(p.Text3)) })
			ui.Box(s.c).Height(4)
			for _, kind := range []struct{ name, note string }{
				{"本地目录", "扫描磁盘上的音乐文件；不复制、不改名。"},
				{"WebDAV", "坚果云、NAS 等标准协议；用户名与密码存在钥匙串。"},
				{"夸克网盘", "扫码登录，直链播放；过期时自动刷新一次。"},
			} {
				kind := kind
				row := ui.Row(s.c).FillWidth().Height(44).PaddingX(20).Gap(12).AlignItems(ui.Center)
				row.Children(func() {
					s.t("small", kind.name, s.col(p.Text)).Width(110)
					s.t("numSm", kind.note, s.col(p.Text3)).Grow(1).SingleLine()
					s.button("添加", false, 24)
				})
				ui.Box(s.c).FillWidth().Height(1).Background(s.col(p.Border))
			}
			ui.Spacer(s.c)
			ui.Column(s.c).PaddingX(20).PaddingY(14).Gap(4).Children(func() {
				ui.Row(s.c).Gap(16).Children(func() {
					s.t("numSm", "凭据只保存在系统钥匙串，不写入曲库。", s.col(p.Text3))
					s.t("numSm", "同步可随时取消，已扫描的曲目会保留。", s.col(p.Text3))
				})
				if detail != "" {
					s.t("numSm", "本次同步："+detail, s.col(p.Warning)).SingleLine()
				}
			})
		})
	})
}

// cSettings: a two-pane form: section list on the left, dense rows on the right.
func (s *scene) cSettings() {
	s.cShell(func(w, h float32) {
		ui.Column(s.c).FillWidth().Height(h).Children(func() {
			ui.Row(s.c).FillWidth().Height(48).PaddingX(20).AlignItems(ui.Center).
				Background(s.col(s.p.Surface)).Children(func() {
				s.t("h1", "设置", s.col(s.p.Text))
				ui.Spacer(s.c)
				s.tn("numSm", "改动会立即保存", s.col(s.p.Text3))
			})
			ui.Box(s.c).FillWidth().Height(1).Background(s.col(s.p.Border))
			ui.Row(s.c).FillWidth().Grow(1).Children(func() {
				nav := ui.Column(s.c).Width(168).FillHeight().Padding(10, 10).Gap(1).
					BorderWidth(0, 1, 0, 0).BorderColor(s.col(s.p.Border))
				nav.Children(func() {
					for i, item := range []string{"外观", "播放", "音乐库", "元数据", "来源", "数据", "关于"} {
						i, item := i, item
						row := ui.Row(s.c).FillWidth().Height(30).PaddingX(8).Gap(8).
							Radius(s.d.Radius.SM).AlignItems(ui.Center)
						if i == 5 {
							row.Background(s.col(s.p.AccentSoft)).BorderWidth(0, 0, 0, 2).
								BorderColor(s.col(s.p.Accent))
						}
						row.Children(func() {
							color := s.col(s.p.Text2)
							if i == 5 {
								color = s.col(s.p.Accent)
							}
							s.t("body", item, color).Grow(1)
							s.tn("numSm", "", s.col(s.p.Text3))
						})
					}
				})
				content := ui.Column(s.c).Grow(1).FillHeight().Padding(20, 24).Gap(0)
				content.Children(func() {
					// 外观
					s.t("h2", "外观", s.col(s.p.Text))
					ui.Box(s.c).Height(8)
					s.cSettingRow("主题模式", "", func() {
						s.segmented([]string{"跟随系统", "浅色", "深色"}, 0, 26)
					})
					s.cSettingRow("界面密度", "", func() {
						s.segmented([]string{"舒适", "紧凑"}, 0, 26)
					})
					s.cSettingRow("封面动态取色", "开", func() { s.toggle(true) })
					ui.Box(s.c).Height(20)
					// 数据
					s.t("h2", "数据", s.col(s.p.Text))
					ui.Box(s.c).Height(8)
					for _, row := range [][2]string{
						{"库文件", s.shortPath(s.at.DataDir + "/library.sqlite")},
						{"库大小", kmb(s.at.LibrarySize)},
						{"音轨", itoa(s.at.Total) + " 首 · " + itoa(s.at.AlbumCount) + " 张专辑 · " + itoa(s.at.ArtistCount) + " 位艺术家"},
						{"封面缓存", itoa(s.at.CoverCount) + " 个文件"},
						{"内核数据", appVersion + " · schema 2"},
					} {
						ui.Row(s.c).FillWidth().Height(34).Gap(20).AlignItems(ui.Center).Children(func() {
							s.t("small", row[0], s.col(s.p.Text3)).Width(120)
							s.tn("numSm", row[1], s.col(s.p.Text2)).Grow(1).SingleLine()
						})
						ui.Box(s.c).FillWidth().Height(1).Background(s.col(s.p.Border))
					}
					ui.Box(s.c).Height(14)
					ui.Row(s.c).Gap(8).Children(func() {
						s.button("立即备份", false, 28)
						s.button("在访达中显示", false, 28)
					})
					ui.Box(s.c).Height(14)
					s.t("numSm", "只读模式打开时，设置不会写盘；本次以读写打开。", s.col(s.p.Text3))
				})
			})
		})
	})
}

func (s *scene) cSettingRow(label, value string, control func()) {
	row := ui.Row(s.c).FillWidth().Height(38).Gap(20).AlignItems(ui.Center)
	row.Children(func() {
		s.t("small", label, s.col(s.p.Text2)).Width(140)
		s.tn("numSm", value, s.col(s.p.Text3))
		ui.Spacer(s.c)
		control()
	})
	ui.Box(s.c).FillWidth().Height(1).Background(s.col(s.p.Border))
}

// shortPath trims a home directory path to ~/… for the technical rows.
func (s *scene) shortPath(path string) string {
	home, err := os.UserHomeDir()
	if err == nil && len(path) > len(home) && path[:len(home)] == home {
		return "~" + path[len(home):]
	}
	return path
}

func valueOr(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func bitrate(kbps int) string {
	if kbps <= 0 {
		return "—"
	}
	return itoa(kbps) + " kbps"
}

func sampleRate(hz int) string {
	if hz <= 0 {
		return "—"
	}
	return fmt.Sprintf("%.1f kHz", float64(hz)/1000)
}

func itoa2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}
