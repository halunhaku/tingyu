package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Design is the resolved token set of the frame: palette and density. Pages
// and components take it as a value; it changes only with the settings.
type Design struct {
	P       tokens.Palette
	Compact bool
}

// Resolve applies the settings to the frame's theme and returns the design.
// The theme a window gets follows the system; applying the palette here keeps
// built-in controls and hand-drawn elements in one appearance.
func Resolve(c *ui.Context, dark, compact bool) Design {
	base := *c.Theme()
	palette := tokens.For(dark)
	c.SetTheme(palette.Apply(&base, compact))
	return Design{P: palette, Compact: compact}
}

// PagePadding is the inset of a page at this density.
func (d Design) PagePadding() float32 {
	if d.Compact {
		return tokens.CompactPagePad
	}
	return tokens.PagePadding
}

// SidebarWidth is the navigation rail's width at this density.
func (d Design) SidebarWidth() float32 {
	if d.Compact {
		return tokens.CompactSidebar
	}
	return tokens.SidebarWidth
}

// RowHeight is a track row's height at this density.
func (d Design) RowHeight() float32 {
	if d.Compact {
		return tokens.CompactRowHeight
	}
	return tokens.TableRowHeight
}

// Bg is the page background.
func (d Design) Bg(c *ui.Context) ui.Element { return ui.Box(c).Fill().Background(d.P.Canvas) }

// Text is a token-typed text.
func (d Design) Text(c *ui.Context, role tokens.Role, s string) ui.Element {
	return tokens.Text(c, role, s)
}

// Textf is a token-typed formatted text.
func (d Design) Textf(c *ui.Context, role tokens.Role, format string, args ...any) ui.Element {
	return tokens.Textf(c, role, format, args...)
}

// Muted is BodyS in the secondary color.
func (d Design) Muted(c *ui.Context, s string) ui.Element {
	return d.Text(c, tokens.BodyS, s).TextColor(d.P.TextSecondary)
}

// Tertiary is LabelS in the tertiary color (the overline).
func (d Design) Tertiary(c *ui.Context, s string) ui.Element {
	return d.Text(c, tokens.LabelS, s).TextColor(d.P.TextTertiary)
}

// Button is a secondary button with the design's radius.
func (d Design) Button(c *ui.Context, label string) ui.Element {
	return ui.Button(c, label).Radius(tokens.RadiusSM).FontSize(13)
}

// PrimaryButton is the accent button.
func (d Design) PrimaryButton(c *ui.Context, label string) ui.Element {
	return ui.PrimaryButton(c, label).Radius(tokens.RadiusSM).FontSize(13)
}

// IconButton is a button showing only an icon, named for assistive technology.
func (d Design) IconButton(c *ui.Context, icon *ui.SVG, label string) ui.Element {
	e := ui.Button(c, "").Padding(6).Radius(tokens.RadiusSM).Tooltip(label).Label(label)
	e.Children(func() {
		ui.Icon(c, icon).FontSize(tokens.IconNormal).TextColor(d.P.TextSecondary)
	})
	return e
}

// IconSize is an icon-only element of a given size and color.
func (d Design) IconSize(c *ui.Context, icon *ui.SVG, size float32, color ui.Color) ui.Element {
	return ui.Icon(c, icon).FontSize(size).TextColor(color)
}

// SearchBox is a search affordance with the design's own Chinese placeholder:
// MyGo's SearchField fixes "Search"/"Clear" in English, which does not match
// the client, so the magnifier sits beside a normal text input. The callbacks
// run for the inner input (a wrapper element would never report Changed).
func (d Design) SearchBox(c *ui.Context, query *string, label, hint string, autoFocus bool, onChange, onSubmit func(), onKey func(ui.TextKey) bool) ui.Element {
	row := ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6)
	row.Children(func() {
		ui.Icon(c, IconSearch).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
		input := ui.TextInput(c, query).Placeholder(hint).Label(label).Grow(1)
		if autoFocus {
			input.AutoFocus()
		}
		if input.Changed() && onChange != nil {
			onChange()
		}
		if input.Submitted() && onSubmit != nil {
			onSubmit()
		}
		if onKey != nil {
			input.OnTextKey(onKey)
		}
	})
	return row
}

// Divider is a one-pixel rule.
func (d Design) Divider(c *ui.Context) ui.Element {
	return ui.Box(c).Height(1).FillWidth().Background(d.P.Border)
}

// Card is the surface panel the design uses for grouped content.
func (d Design) Card(c *ui.Context) ui.Element {
	return ui.Column(c).Padding(tokens.Space20).Gap(tokens.Space12).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
}

// Tag is a small count/label pill on the sunken surface.
func (d Design) Tag(c *ui.Context, label string) ui.Element {
	e := ui.Row(c).Padding(tokens.Space8, 3).Radius(tokens.RadiusFull).
		Background(d.P.SurfaceSunken).AlignItems(ui.Center)
	e.Children(func() {
		d.Text(c, tokens.LabelS, label).TextColor(d.P.TextSecondary)
	})
	return e
}

// AccentTag is the playing/count pill in the accent soft tint.
func (d Design) AccentTag(c *ui.Context, label string) ui.Element {
	e := ui.Row(c).Padding(tokens.Space8, 3).Radius(tokens.RadiusFull).
		Background(d.P.AccentSoft).AlignItems(ui.Center)
	e.Children(func() {
		d.Text(c, tokens.LabelS, label).TextColor(d.P.Accent)
	})
	return e
}
