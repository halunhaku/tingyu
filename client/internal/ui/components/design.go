package components

import (
	"github.com/egoist/mygo/plugins/glass"
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

// SidebarWidth is the navigation rail's width at this density (§4.2: 236).
func (d Design) SidebarWidth() float32 {
	if d.Compact {
		return tokens.CompactSidebar
	}
	return tokens.SidebarWidth
}

// RowHeight is a track row's height at this density (§4.2: 44).
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

// Muted is Small in the secondary color.
func (d Design) Muted(c *ui.Context, s string) ui.Element {
	return d.Text(c, tokens.Small, s).TextColor(d.P.TextSecondary)
}

// Tertiary is Overline in the tertiary color (the group label / table header).
func (d Design) Tertiary(c *ui.Context, s string) ui.Element {
	return d.Text(c, tokens.Overline, s).TextColor(d.P.TextTertiary)
}

// Button is a secondary control: 32 high, radius 8, label 12/500 (§10-8).
func (d Design) Button(c *ui.Context, label string) ui.Element {
	return ui.Button(c, label).Height(tokens.ToolbarControl).Radius(tokens.RadiusSM).FontSize(12)
}

// PrimaryButton is the accent button of a toolbar (§10-8: 主按钮朱红).
func (d Design) PrimaryButton(c *ui.Context, label string) ui.Element {
	return ui.PrimaryButton(c, label).Height(tokens.ToolbarControl).Radius(tokens.RadiusSM).FontSize(12)
}

// IconButton is a button showing only an icon, named for assistive technology.
func (d Design) IconButton(c *ui.Context, icon *ui.SVG, label string) ui.Element {
	e := ui.Button(c, "").Size(tokens.ToolbarControl, tokens.ToolbarControl).Padding(6).
		Radius(tokens.RadiusSM).Tooltip(label).Label(label)
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
	return d.SearchBoxWidth(c, query, label, hint, 0, autoFocus, onChange, onSubmit, onKey)
}

// SearchBoxWidth is SearchBox with an explicit width (0 keeps the layout's).
func (d Design) SearchBoxWidth(c *ui.Context, query *string, label, hint string, width float32, autoFocus bool, onChange, onSubmit func(), onKey func(ui.TextKey) bool) ui.Element {
	row := ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6).Height(tokens.ToolbarControl).
		PaddingX(tokens.Space8).Radius(tokens.RadiusSM).Border(1, d.P.Border).
		Background(d.P.SurfaceRaised).Cursor(ui.CursorText)
	if width > 0 {
		row.Width(width)
	}
	clicked := row.Clicked()
	row.Children(func() {
		ui.Icon(c, IconSearch).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
		// Only the outer row owns the search field's decoration.
		input := ui.TextInputBase(c, query).Placeholder(hint).Label(label).
			Grow(1).MinWidth(0).FillHeight().TextColor(d.P.TextPrimary)
		if clicked {
			input.Focus()
		}
		if autoFocus {
			input.AutoFocus()
		}
		if input.Focused() {
			row.BorderColor(d.P.Accent)
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
		tokens.Tabular(d.Text(c, tokens.NumSm, label)).TextColor(d.P.TextSecondary)
	})
	return e
}

// AccentTag is the playing/count pill in the accent soft tint.
func (d Design) AccentTag(c *ui.Context, label string) ui.Element {
	e := ui.Row(c).Padding(tokens.Space8, 3).Radius(tokens.RadiusFull).
		Background(d.P.AccentSoft).AlignItems(ui.Center)
	e.Children(func() {
		tokens.Tabular(d.Text(c, tokens.NumSm, label)).TextColor(d.P.Accent)
	})
	return e
}

// ClearGlass is the material of the long surfaces that frame content: the
// sidebar and the transport bar (§10-14). Clear glass keeps the surface's own
// tone instead of frosting it white — the measured reason is in §1.2: Regular
// glass lifts the dark theme to about #555556 whatever its tint, which would
// make a sidebar lighter than the page it frames.
func (d Design) ClearGlass(clarity float32) glass.Glass {
	return glass.Glass{
		Style:   glass.Clear,
		Tint:    d.P.GlassTint.Alpha(d.P.GlassAlpha),
		Clarity: clarity,
	}
}

// Overlay is the popover frame of §10-14: the page under the palette's scrim,
// and the floating panel on top of it. MyGo's own Modal fixes its scrim at 40%
// black, which the dark palette asks to be 56%; DialogBase takes the backdrop's
// own colour, so the tokens decide here.
func (d Design) Overlay(c *ui.Context, open *bool, panel func()) {
	if !*open {
		return
	}
	ui.DialogBase(c, open, func(back, card ui.Element) {
		back.Background(d.P.Scrim)
		card.Shadow(0, 24, 60, -20, ui.RGBA(0, 0, 0, 80))
		panel()
	})
}

// RegularGlass is the material of a surface floating over content: the command
// palette, the match dialog, the source panel (§10-14). Its frost is the
// elevation cue, so it is only used where a surface really is raised.
func (d Design) RegularGlass() glass.Glass {
	return glass.Glass{
		Style:   glass.Regular,
		Tint:    d.P.GlassTint.Alpha(tokens.GlassPopoverAlpha),
		Clarity: 0.3,
	}
}
