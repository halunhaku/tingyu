package components

import (
	"fmt"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Header is a page title with an optional back button and trailing actions.
func Header(c *ui.Context, d Design, title, subtitle string, back func(), actions func()) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space12).Height(tokens.PageHeaderHeight).Children(func() {
		if back != nil {
			ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).Label("返回").Tooltip("返回").
				OnClick(back).Children(func() {
				ui.Icon(c, IconBack).FontSize(tokens.IconNormal)
			})
		}
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
			d.Text(c, tokens.TitleXL, title).TextColor(d.P.TextPrimary).SingleLine()
			if subtitle != "" {
				d.Text(c, tokens.BodyS, subtitle).TextColor(d.P.TextSecondary).SingleLine()
			}
		})
		ui.Spacer(c)
		if actions != nil {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(actions)
		}
	})
}

// Empty is the empty state used by every list page.
func Empty(c *ui.Context, d Design, icon *ui.SVG, title, text string, actions func()) {
	ui.Column(c).Grow(1).Justify(ui.Center).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
		ui.Box(c).Size(56, 56).Radius(tokens.RadiusLG).Background(d.P.SurfaceSunken).Center().Children(func() {
			ui.Icon(c, icon).FontSize(26).TextColor(d.P.TextTertiary)
		})
		d.Text(c, tokens.TitleL, title).TextColor(d.P.TextPrimary)
		if text != "" {
			ui.Text(c, text).FontSize(13).TextColor(d.P.TextSecondary).Wrap().TextAlign(ui.Center)
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
	bg := d.P.AccentSoft
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

// Pager is the library's pagination footer: the true total and one page per
// explicit click (the accessibility path; the scroll gate also exists).
func Pager(c *ui.Context, d Design, list *model.TrackList) {
	total := list.Total()
	loaded := list.Loaded()
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		if total == 0 {
			return
		}
		d.Textf(c, tokens.NumericS, "已显示 %d / 共 %d 首", loaded, total).TextColor(d.P.TextSecondary)
		if list.Done() {
			d.Textf(c, tokens.BodyS, "已全部加载 · 共 %d 首", total).TextColor(d.P.TextTertiary)
			return
		}
		if list.Loading() {
			ui.Spinner(c)
			d.Text(c, tokens.BodyS, "正在加载…").TextColor(d.P.TextSecondary)
			return
		}
		d.Button(c, "加载更多").OnClick(list.RequestMore)
	})
}

// LoadMore is the footer of a list that is not a TrackList (albums, artists,
// playlists): the loaded and true counts, and one page per click. The scroll
// gates live with the lists themselves.
func LoadMore(c *ui.Context, d Design, loaded, total int, done, loading bool, more func()) {
	if total == 0 {
		return
	}
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
		d.Textf(c, tokens.NumericS, "已显示 %d / 共 %d 项", loaded, total).TextColor(d.P.TextSecondary)
		if done || loaded >= total {
			d.Textf(c, tokens.BodyS, "已全部加载 · 共 %d 项", total).TextColor(d.P.TextTertiary)
			return
		}
		if loading {
			ui.Spinner(c)
			d.Text(c, tokens.BodyS, "正在加载…").TextColor(d.P.TextSecondary)
			return
		}
		if more != nil {
			d.Button(c, "加载更多").OnClick(more)
		}
	})
}

// Stat is a label + value pair for settings and summaries.
func Stat(c *ui.Context, d Design, label string, value any) {
	ui.Column(c).Gap(2).Children(func() {
		d.Textf(c, tokens.NumericM, "%v", value).TextColor(d.P.TextPrimary)
		d.Text(c, tokens.BodyS, label).TextColor(d.P.TextSecondary)
	})
}

// SectionTitle is a settings group title.
func SectionTitle(c *ui.Context, d Design, title, subtitle string) {
	ui.Column(c).Gap(4).Children(func() {
		d.Text(c, tokens.TitleM, title).TextColor(d.P.TextPrimary)
		if subtitle != "" {
			d.Text(c, tokens.BodyS, subtitle).TextColor(d.P.TextSecondary).Wrap()
		}
	})
}

// SettingRow is a labelled row with a control at the right.
func SettingRow(c *ui.Context, d Design, title, detail string, control func()) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space8).Children(func() {
		ui.Column(c).Gap(3).Grow(1).Children(func() {
			d.Text(c, tokens.BodyM, title).TextColor(d.P.TextPrimary)
			if detail != "" {
				d.Text(c, tokens.BodyS, detail).TextColor(d.P.TextSecondary).Wrap()
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
		d.Text(c, tokens.LabelS, keys).TextColor(d.P.TextTertiary)
	})
}

// StatRow is a read-only label/value line in settings.
func StatRow(c *ui.Context, d Design, label, value string) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space6).Children(func() {
		d.Text(c, tokens.BodyS, label).TextColor(d.P.TextSecondary).Width(160)
		d.Text(c, tokens.BodyM, value).TextColor(d.P.TextPrimary).Grow(1).Wrap()
	})
}

// PathRow is a path with a copy button.
func PathRow(c *ui.Context, d Design, state *model.State, label, path string) {
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space16).PaddingY(tokens.Space6).Children(func() {
		d.Text(c, tokens.BodyS, label).TextColor(d.P.TextSecondary).Width(160)
		d.Text(c, tokens.BodyS, path).TextColor(d.P.TextPrimary).Grow(1).SingleLine()
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
	d.Textf(c, tokens.BodyS, "%d %s", n, unit).TextColor(d.P.TextSecondary)
}

// ErrorState is a page-level failure (the library could not be opened).
func ErrorState(c *ui.Context, d Design, title, message, path string) {
	ui.Column(c).Grow(1).Justify(ui.Center).AlignItems(ui.Center).Gap(tokens.Space10).Children(func() {
		d.Text(c, tokens.TitleL, title).TextColor(d.P.Danger)
		ui.Text(c, message).FontSize(12).TextColor(d.P.TextSecondary).Wrap().TextAlign(ui.Center).MaxWidth(620)
		if path != "" {
			d.Text(c, tokens.BodyS, path).TextColor(d.P.TextTertiary).SingleLine().MaxWidth(620)
		}
		ui.Text(c, "不创建、不迁移、不修复数据库；请检查数据目录（可用 TINGYU_DATA_DIR 指向副本）").FontSize(11).
			TextColor(d.P.TextTertiary).TextAlign(ui.Center)
	})
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
			d.Text(c, tokens.BodyM, sourceName).TextColor(d.P.TextPrimary).SingleLine()
			d.Textf(c, tokens.BodyS, "%s · %d 首", kind, tracks).TextColor(d.P.TextSecondary)
		})
	})
}

// ItemCount formats the "N 项" footer of the palette.
func ItemCount(n int) string { return fmt.Sprintf("%d 项", n) }
