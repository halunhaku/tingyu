package components

import (
	"fmt"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// AppMark uses the approved Sound Island brand glyph.
func AppMark(c *ui.Context, d Design, size, iconSize float32) ui.Element {
	radius := tokens.RadiusSM
	if size >= 40 {
		radius = tokens.RadiusMD
	}
	return ui.Box(c).Size(size, size).Radius(radius).Background(d.P.Accent).Center().Children(func() {
		ui.Icon(c, IconBrand).FontSize(iconSize).TextColor(d.P.OnAccent)
	})
}

// Header is a page title with an optional back button and trailing actions
// (§10-8): the title is 28/700, the metadata 13 on its own line, and every
// control to the right is 32 high with radius 8.
func Header(c *ui.Context, d Design, title, subtitle string, back func(), actions func()) {
	ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
		Height(tokens.PageHeaderHeight).Children(func() {
		if back != nil {
			ui.Button(c, "").Size(tokens.ToolbarControl, tokens.ToolbarControl).Padding(6).
				Radius(tokens.RadiusSM).Label("返回").Tooltip("返回").
				OnClick(back).Children(func() {
				ui.Icon(c, IconBack).FontSize(tokens.IconNormal)
			})
		}
		ui.Column(c).Gap(3).Justify(ui.Center).Children(func() {
			d.Text(c, tokens.H1, title).TextColor(d.P.TextPrimary).SingleLine()
			if subtitle != "" {
				d.Text(c, tokens.Small, subtitle).TextColor(d.P.TextSecondary).SingleLine()
			}
		})
		ui.Spacer(c)
		if actions != nil {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(actions)
		}
	})
}

// Empty is the empty state every list page uses (§4.4, §10-13): a 56 DIP icon
// tile, a 20/600 title, at most two lines of 13, and the page's main action.
func Empty(c *ui.Context, d Design, icon *ui.SVG, title, text string, actions func()) {
	ui.Column(c).Grow(1).Justify(ui.Center).AlignItems(ui.Center).Gap(tokens.Space12).Children(func() {
		ui.Box(c).Size(tokens.EmptyIcon, tokens.EmptyIcon).Radius(tokens.RadiusLG).
			Background(d.P.SurfaceSunken).Center().Children(func() {
			ui.Icon(c, icon).FontSize(26).TextColor(d.P.TextTertiary)
		})
		d.Text(c, tokens.H2, title).TextColor(d.P.TextPrimary)
		if text != "" {
			ui.Text(c, text).FontSize(13).LineHeight(1.55).TextColor(d.P.TextSecondary).
				Wrap().TextAlign(ui.Center).MaxWidth(tokens.ErrorCard)
		}
		if actions != nil {
			ui.Row(c).Gap(tokens.Space8).Children(actions)
		}
	})
}

// Notice shows a dismissible banner above the content. Kernel notices say what
// is missing instead of pretending the action worked.
func Notice(c *ui.Context, d Design, message string, dismiss func()) {
	if message == "" {
		return
	}
	bg := tokens.Blend(d.P.Canvas, d.P.AccentSoft)
	color := d.P.Accent
	if len(message) >= len("需内核支持") && message[:len("需内核支持")] == "需内核支持" {
		bg = d.P.SurfaceSunken
		color = d.P.TextSecondary
	}
	e := ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Padding(tokens.Space12, tokens.Space8).
		Radius(tokens.RadiusMD).Background(bg).Border(1, d.P.Border)
	e.Children(func() {
		ui.Icon(c, IconInfo).FontSize(tokens.IconCompact).TextColor(color)
		ui.Text(c, message).FontSize(12).TextColor(color).Grow(1).Wrap()
		if dismiss != nil {
			ui.Button(c, "").Padding(4).Radius(tokens.RadiusXS).Label("关闭提示").OnClick(dismiss).
				Children(func() {
					ui.Icon(c, IconClose).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
				})
		}
	})
}

// Pager is the library's pagination footer: one count rule, and one page per
// explicit click (the accessibility path; the scroll gate also exists). While
// rows are still coming the footer shows the progress and the button; once
// every row is loaded it is the single sentence "已全部加载 · 共 N 首" with the
// list's sort order on the right (§4.3, §10-7). The development footnote the
// M4 page carried (the database path and the SQL sentence) is gone.
func Pager(c *ui.Context, d Design, list *model.TrackList, hint string) {
	total := list.Total()
	if total == 0 {
		return
	}
	loaded := list.Loaded()
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		if list.Done() {
			d.Textf(c, tokens.Num, "已全部加载 · 共 %d 首", total).TextColor(d.P.TextTertiary)
			if hint != "" {
				ui.Spacer(c)
				d.Text(c, tokens.Num, hint).TextColor(d.P.TextTertiary)
			}
			return
		}
		d.Textf(c, tokens.Num, "已显示 %d / 共 %d 首", loaded, total).TextColor(d.P.TextSecondary)
		if list.Loading() {
			ui.Spinner(c)
			d.Text(c, tokens.Small, "正在加载…").TextColor(d.P.TextSecondary)
			return
		}
		d.Button(c, "加载更多").OnClick(list.RequestMore)
	})
}

// LoadMore is the footer of a list that is not a TrackList (albums, artists,
// playlists): the same one rule as Pager — the progress while more items come,
// the single "已全部加载 · 共 N 项" once they are all here — and one page per
// click. The scroll gates live with the lists themselves.
func LoadMore(c *ui.Context, d Design, loaded, total int, done, loading bool, more func()) {
	if total == 0 {
		return
	}
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		if done || loaded >= total {
			d.Textf(c, tokens.Num, "已全部加载 · 共 %d 项", total).TextColor(d.P.TextTertiary)
			return
		}
		d.Textf(c, tokens.Num, "已显示 %d / 共 %d 项", loaded, total).TextColor(d.P.TextSecondary)
		if loading {
			ui.Spinner(c)
			d.Text(c, tokens.Small, "正在加载…").TextColor(d.P.TextSecondary)
			return
		}
		if more != nil {
			d.Button(c, "加载更多").OnClick(more)
		}
	})
}

// Skeleton is the loading state of a list (§4.4, §10-13): 8 DIP bars, radius 4,
// a 1400 ms shimmer, one per row, inside a block as tall as the rows they stand
// in for. The desktop's Reduce Motion leaves a static skeleton (§4.5).
func Skeleton(c *ui.Context, d Design, rows int, height float32) {
	if rows <= 0 {
		return
	}
	still := c.Preferences().ReduceMotion
	// The widths step with the row's own rhythm, so the skeleton reads as a
	// table rather than as a stack of identical bars.
	widths := []float32{0.62, 0.44, 0.52, 0.36, 0.58, 0.40}
	ui.Column(c).Grow(1).Gap(tokens.Space12).Children(func() {
		for i := 0; i < rows; i++ {
			width := widths[i%len(widths)]
			row := ui.Row(c).FillWidth().Height(height).AlignItems(ui.Center)
			row.Children(func() {
				bar := ui.Box(c).Height(8).WidthPercent(width * 100).Radius(tokens.RadiusXS).
					Background(d.P.SkeletonBase)
				if !still {
					shimmer(c, d, bar, i)
				}
			})
		}
	})
}

// shimmer paints the moving highlight over one skeleton bar. MyGo's Loop keeps
// frames coming for as long as the element is built, so the 1400 ms period is
// the animation's own progress rather than a timer kept here.
func shimmer(c *ui.Context, d Design, bar ui.Element, key int) {
	phase := bar.Loop(key, tokens.DurationShimmer, ui.Linear)
	bar.DrawOver(func(p *ui.Painter, r ui.Rect) {
		clamp01 := func(v float32) float32 {
			if v < 0 {
				return 0
			}
			if v > 1 {
				return 1
			}
			return v
		}
		clear := d.P.SkeletonBase.Alpha(0)
		lit := d.P.SkeletonHighlight.Alpha(0.9)
		from := clamp01(phase - 0.18)
		mid := clamp01(phase)
		to := clamp01(phase + 0.18)
		if from == mid {
			mid = float32(0)
		}
		if mid == to {
			to = 1
		}
		p.FillGradient(r, ui.LinearGradient{Angle: 90, Stops: []ui.GradientStop{
			{Color: clear, At: from},
			{Color: lit, At: mid},
			{Color: clear, At: to},
		}}, tokens.RadiusXS)
	})
}

// Stat is the statistics rhythm of §4.3: the 11/600 label over its tabular
// value. 来源's bottom row and the settings counts use the same pair, so the
// numbers read the same wherever they appear.
func Stat(c *ui.Context, d Design, label string, value any) {
	ui.Column(c).Gap(tokens.Space4).Children(func() {
		d.Text(c, tokens.Overline, label).TextColor(d.P.TextTertiary)
		tokens.Tabular(d.Textf(c, tokens.H3, "%v", value)).TextColor(d.P.TextSecondary)
	})
}

// SectionTitle is a settings group title.
func SectionTitle(c *ui.Context, d Design, title, subtitle string) {
	ui.Column(c).Gap(4).Children(func() {
		d.Text(c, tokens.H3, title).TextColor(d.P.TextPrimary)
		if subtitle != "" {
			d.Text(c, tokens.Small, subtitle).TextColor(d.P.TextSecondary).Wrap()
		}
	})
}

// SettingRow is a labelled row with a control at the right.
func SettingRow(c *ui.Context, d Design, title, detail string, control func()) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space8).Children(func() {
		ui.Column(c).Gap(3).Grow(1).Children(func() {
			d.Text(c, tokens.Body, title).TextColor(d.P.TextPrimary)
			if detail != "" {
				d.Text(c, tokens.Small, detail).TextColor(d.P.TextSecondary).Wrap()
			}
		})
		if control != nil {
			ui.Row(c).Gap(tokens.Space8).Children(control)
		}
	})
}

// KeyHint prints a shortcut as a muted chip.
func KeyHint(c *ui.Context, d Design, keys string) {
	if keys == "" {
		return
	}
	ui.Row(c).Padding(tokens.Space6, 2).Radius(tokens.RadiusXS).
		Background(d.P.SurfaceSunken).Children(func() {
		d.Text(c, tokens.Overline, keys).TextColor(d.P.TextTertiary)
	})
}

// StatRow is a read-only label/value line in settings.
func StatRow(c *ui.Context, d Design, label, value string) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space6).Children(func() {
		d.Text(c, tokens.Small, label).TextColor(d.P.TextSecondary).Width(160)
		d.Text(c, tokens.Body, value).TextColor(d.P.TextPrimary).Grow(1).Wrap()
	})
}

// PathRow is a path with a copy button.
func PathRow(c *ui.Context, d Design, state *model.State, label, path string) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space6).Children(func() {
		d.Text(c, tokens.Small, label).TextColor(d.P.TextSecondary).Width(160)
		d.Text(c, tokens.Small, path).TextColor(d.P.TextPrimary).Grow(1).SingleLine()
		if path != "" {
			if b := d.Button(c, "复制"); b.Clicked() {
				c.WriteClipboard(path)
			}
		}
	})
	_ = state
}

// Count is "N 首"/"N 张" as muted metadata.
func Count(c *ui.Context, d Design, n int, unit string) {
	tokens.Tabular(d.Textf(c, tokens.Small, "%d %s", n, unit)).TextColor(d.P.TextSecondary)
}

// ErrorCard is the failure surface of §4.4/§10-13: 440 wide, the raised surface
// with a danger border, the reason, and up to two actions.
func ErrorCard(c *ui.Context, d Design, title, message string, actions func()) {
	ui.Column(c).Width(tokens.ErrorCard).Padding(tokens.Space20).Gap(tokens.Space12).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Danger).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			ui.Icon(c, IconInfo).FontSize(tokens.IconCompact).TextColor(d.P.Danger)
			d.Text(c, tokens.H3, title).TextColor(d.P.Danger)
		})
		ui.Text(c, message).FontSize(13).LineHeight(1.55).TextColor(d.P.TextSecondary).Wrap()
		if actions != nil {
			ui.Row(c).Gap(tokens.Space8).Children(actions)
		}
	})
}

// ErrorState is a page-level failure (the library could not be opened): the
// error card, centred, with the two actions the page really has — show the
// directory in Finder, or copy its path.
func ErrorState(c *ui.Context, d Design, title, message, path string) {
	ui.Column(c).Grow(1).Justify(ui.Center).AlignItems(ui.Center).Gap(tokens.Space16).Children(func() {
		ErrorCard(c, d, title, message, func() {
			if dir := parentDir(path); dir != "" {
				if b := d.Button(c, "在访达中打开"); b.Clicked() {
					c.OpenURL("file://" + dir)
				}
			}
			if b := d.PrimaryButton(c, "复制路径"); b.Clicked() {
				c.WriteClipboard(path)
			}
		})
		if path != "" {
			d.Text(c, tokens.Num, path).TextColor(d.P.TextTertiary).SingleLine().MaxWidth(tokens.ErrorCard)
		}
		ui.Text(c, "曲库暂未更改。请检查数据文件是否存在，以及是否有访问权限。").FontSize(11).
			TextColor(d.P.TextTertiary).TextAlign(ui.Center).MaxWidth(tokens.ErrorCard)
	})
}

// parentDir is the directory of a database path, for "show in Finder".
func parentDir(path string) string {
	for i := len(path) - 1; i > 0; i-- {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return ""
}

// ProgressBar is a filled meter drawn from the desktop tokens.
func ProgressBar(c *ui.Context, d Design, fraction float64) {
	if fraction < 0 {
		fraction = 0
	}
	if fraction > 1 {
		fraction = 1
	}
	ui.Box(c).Height(4).FillWidth().Radius(tokens.RadiusFull).Background(d.P.SurfaceSunken).Children(func() {
		ui.Box(c).WidthPercent(float32(fraction * 100)).Height(4).Radius(tokens.RadiusFull).
			Background(d.P.Accent)
	})
}

// SourceRow is one source line in settings: name, kind and track count.
func SourceRow(c *ui.Context, d Design, sourceName, kind string, tracks int64) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).PaddingY(tokens.Space6).Children(func() {
		ui.Box(c).Size(30, 30).Radius(tokens.RadiusSM).Background(d.P.SurfaceSunken).Center().Children(func() {
			ui.Icon(c, IconFolder).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
		})
		ui.Column(c).Gap(2).Grow(1).Children(func() {
			d.Text(c, tokens.Body, sourceName).TextColor(d.P.TextPrimary).SingleLine()
			d.Textf(c, tokens.Small, "%s · %d 首", kind, tracks).TextColor(d.P.TextSecondary)
		})
	})
}

// ItemCount formats the "N 项" footer of the palette.
func ItemCount(n int) string { return fmt.Sprintf("%d 项", n) }
