// Package tokens is the M4 design-token layer: the numbers and colors of the
// Flutter client's "声档" design system (app/lib/design/tokens), translated to
// Go. It is the only place where a color, a size or a duration is spelled out;
// components and pages take them from here, so the two clients stay one design
// rather than two that resemble each other.
//
// The tokens are compile-time values; only the palette and the density change
// at runtime (light/dark, comfortable/compact). Palette.Apply maps them onto a
// MyGo theme so built-in widgets (buttons, fields, tables, sliders) follow the
// same colors as the elements drawn here.
package tokens

import (
	"fmt"
	"time"

	"github.com/egoist/mygo/ui"
)

// Space is the 4pt grid (DESIGN.md §3.1).
const (
	Space2  float32 = 2
	Space4  float32 = 4
	Space6  float32 = 6
	Space8  float32 = 8
	Space10 float32 = 10
	Space12 float32 = 12
	Space16 float32 = 16
	Space20 float32 = 20
	Space24 float32 = 24
	Space32 float32 = 32
	Space40 float32 = 40
	Space48 float32 = 48
	Space64 float32 = 64
)

// PagePadding is the expanded page inset (the window minimum is 900 wide, so
// the compact inset of 20 is not reachable; plan §2.4 #39).
const PagePadding float32 = 32

// Radii (DESIGN.md §3.2).
const (
	RadiusXS   float32 = 4
	RadiusSM   float32 = 8
	RadiusMD   float32 = 10
	RadiusLG   float32 = 14
	RadiusXL   float32 = 20
	RadiusFull float32 = 999
)

// Sizes (DESIGN.md §3.4): fixed geometry that does not follow density.
const (
	TrackLeading      float32 = 40
	TableCoverColumn  float32 = 32
	TableDuration     float32 = 56
	TableFavorite     float32 = 36
	TableMore         float32 = 32
	TableHeaderTail   float32 = 68
	IconInline        float32 = 14
	IconCompact       float32 = 16
	IconNormal        float32 = 20
	IconToolbar       float32 = 24
	TransportSecond   float32 = 28
	PlayControl       float32 = 56
	SidebarWidth      float32 = 224
	TransportHeight   float32 = 88
	StageCoverMax     float32 = 360
	PageHeaderHeight  float32 = 64
	SettingsNavWidth  float32 = 208
	TableRowHeight    float32 = 44
	RowHeightCompact  float32 = 40
	SearchPaletteWide float32 = 560
	CompactPagePad    float32 = 24
	CompactSidebar    float32 = 208
	CompactRowHeight  float32 = 40
)

// Motion durations (DESIGN.md §7.1).
const (
	DurationMicro      = 90 * time.Millisecond
	DurationFast       = 120 * time.Millisecond
	DurationBase       = 200 * time.Millisecond
	DurationSheet      = 240 * time.Millisecond
	DurationStage      = 320 * time.Millisecond
	DurationCover      = 180 * time.Millisecond
	DurationShimmer    = 1400 * time.Millisecond
	DurationAmbient    = 24 * time.Second
	LyricsManualPause  = 3 * time.Second
	SearchDebounceTime = 250 * time.Millisecond
)

// Easing follows TyCurve.standard: cubic-bezier(0.2, 0, 0, 1).
var Easing = ui.CubicBezier(0.2, 0, 0, 1)

// Palette is one brightness of TyColors.
type Palette struct {
	Dark bool

	Canvas        ui.Color
	Surface       ui.Color
	SurfaceSunken ui.Color
	SurfaceRaised ui.Color
	Overlay       ui.Color
	Hover         ui.Color // translucent, for rows and cards
	Pressed       ui.Color
	Selected      ui.Color
	Border        ui.Color
	BorderStrong  ui.Color

	TextPrimary   ui.Color
	TextSecondary ui.Color
	TextTertiary  ui.Color
	TextDisabled  ui.Color

	Accent        ui.Color
	AccentHover   ui.Color
	AccentPressed ui.Color
	AccentSoft    ui.Color
	OnAccent      ui.Color

	Success ui.Color
	Warning ui.Color
	Danger  ui.Color
	Focus   ui.Color
	Scrim   ui.Color

	SkeletonBase      ui.Color
	SkeletonHighlight ui.Color
	CoverPlaceholder  ui.Color

	// Opaque hover/pressed faces for the built-in theme, which composites
	// nothing (the Flutter palette uses alpha over an unknown base).
	SurfaceHoverSolid   ui.Color
	SurfacePressedSolid ui.Color
	Scrollbar           ui.Color
}

// Light is TyColors.light.
var Light = Palette{
	Dark:                false,
	Canvas:              ui.Hex("#F7F7F9"),
	Surface:             ui.Hex("#FFFFFF"),
	SurfaceSunken:       ui.Hex("#F1F1F4"),
	SurfaceRaised:       ui.Hex("#FFFFFF"),
	Overlay:             ui.Hex("#FFFFFF"),
	Hover:               ui.RGBA(22, 22, 26, 0.04),
	Pressed:             ui.RGBA(22, 22, 26, 0.08),
	Selected:            ui.RGBA(216, 30, 50, 0.12),
	Border:              ui.Hex("#E4E4EA"),
	BorderStrong:        ui.Hex("#D3D3DC"),
	TextPrimary:         ui.Hex("#16161A"),
	TextSecondary:       ui.Hex("#5A5A66"),
	TextTertiary:        ui.Hex("#6A6A76"),
	TextDisabled:        ui.Hex("#A0A0AC"),
	Accent:              ui.Hex("#D81E32"),
	AccentHover:         ui.Hex("#C0182B"),
	AccentPressed:       ui.Hex("#A81226"),
	AccentSoft:          ui.RGBA(216, 30, 50, 0.12),
	OnAccent:            ui.Hex("#FFFFFF"),
	Success:             ui.Hex("#1C7A4A"),
	Warning:             ui.Hex("#96560A"),
	Danger:              ui.Hex("#B32219"),
	Focus:               ui.Hex("#D81E32"),
	Scrim:               ui.RGBA(0, 0, 0, 0.4),
	SkeletonBase:        ui.Hex("#EAEAF0"),
	SkeletonHighlight:   ui.Hex("#F5F5F8"),
	CoverPlaceholder:    ui.Hex("#E7E7EC"),
	SurfaceHoverSolid:   ui.Hex("#EEEEF0"),
	SurfacePressedSolid: ui.Hex("#E5E5E7"),
	Scrollbar:           ui.RGBA(0, 0, 0, 0.32),
}

// Dark is TyColors.dark.
var Dark = Palette{
	Dark:                true,
	Canvas:              ui.Hex("#0C0C0F"),
	Surface:             ui.Hex("#141418"),
	SurfaceSunken:       ui.Hex("#101014"),
	SurfaceRaised:       ui.Hex("#1B1B21"),
	Overlay:             ui.Hex("#232329"),
	Hover:               ui.RGBA(255, 255, 255, 0.06),
	Pressed:             ui.RGBA(255, 255, 255, 0.10),
	Selected:            ui.RGBA(255, 92, 110, 0.14),
	Border:              ui.Hex("#2A2A33"),
	BorderStrong:        ui.Hex("#3A3A45"),
	TextPrimary:         ui.Hex("#F4F4F7"),
	TextSecondary:       ui.Hex("#A6A6B3"),
	TextTertiary:        ui.Hex("#8C8C99"),
	TextDisabled:        ui.Hex("#5A5A64"),
	Accent:              ui.Hex("#FF5C6E"),
	AccentHover:         ui.Hex("#FF7A89"),
	AccentPressed:       ui.Hex("#E8455A"),
	AccentSoft:          ui.RGBA(255, 92, 110, 0.14),
	OnAccent:            ui.Hex("#0C0C0F"),
	Success:             ui.Hex("#5BD98F"),
	Warning:             ui.Hex("#F0B45C"),
	Danger:              ui.Hex("#FF7066"),
	Focus:               ui.Hex("#FF5C6E"),
	Scrim:               ui.RGBA(0, 0, 0, 0.6),
	SkeletonBase:        ui.Hex("#1E1E24"),
	SkeletonHighlight:   ui.Hex("#2A2A32"),
	CoverPlaceholder:    ui.Hex("#22222A"),
	SurfaceHoverSolid:   ui.Hex("#222226"),
	SurfacePressedSolid: ui.Hex("#2C2C2F"),
	Scrollbar:           ui.RGBA(255, 255, 255, 0.35),
}

// For returns the palette of a brightness.
func For(dark bool) Palette {
	if dark {
		return Dark
	}
	return Light
}

// Blend mixes a translucent token over a base, for elements that must paint an
// opaque face (the built-in theme cannot composite an alpha face).
func Blend(base, over ui.Color) ui.Color { return over.Over(base) }

// Apply writes the palette into a copy of a MyGo theme. base is the theme of
// the current frame, which already follows the system (radius, font size and
// platform metrics), so the tokens only override what the design decides.
func (p Palette) Apply(base *ui.Theme, compact bool) *ui.Theme {
	t := *base
	t.Dark = p.Dark
	t.Background = p.Canvas
	t.Surface = p.SurfaceRaised
	t.SurfaceHover = p.SurfaceHoverSolid
	t.SurfacePressed = p.SurfacePressedSolid
	t.Border = p.Border
	t.Text = p.TextPrimary
	t.TextMuted = p.TextSecondary
	t.Accent = p.Accent
	t.AccentHover = p.AccentHover
	t.AccentPressed = p.AccentPressed
	t.AccentText = p.OnAccent
	t.Danger = p.Danger
	t.Warning = p.Warning
	t.Success = p.Success
	t.Selection = p.Selected
	t.Focus = p.Focus
	t.Scrollbar = p.Scrollbar
	t.ScrollbarWidth = 8
	t.Radius = RadiusMD
	t.Spacing = 4
	if compact {
		t.Spacing = 3
	}
	return &t
}

// Role is a typography step (DESIGN.md §4). Sizes are the Flutter sizes in DIPs.
type Role int

const (
	DisplayL Role = iota // 40 / 700 / 1.20 — stage title
	DisplayM             // 32 / 700 / 1.25 — detail title
	TitleXL              // 26 / 600 / 1.30 — page title
	TitleL               // 20 / 600 / 1.35 — panel title
	TitleM               // 17 / 600 / 1.40 — group title
	BodyL                // 16 / 400 / 1.60 — stage artist, paragraphs
	BodyM                // 15 / 400 / 1.50 — track names, body
	BodyS                // 13 / 400 / 1.50 — metadata
	LabelL               // 15 / 500 / 1.40 — buttons
	LabelM               // 13 / 500 / 1.40 — chips, nav
	LabelS               // 11 / 600 / 1.30 / ls .3 — overline
	NumericM             // 15 / 500 / 1.40 tabular — times
	NumericS             // 13 / 500 / 1.40 tabular — counts
)

type roleSpec struct {
	size    float32
	weight  int
	height  float32
	track   float32
	numeric bool
}

var roles = [...]roleSpec{
	DisplayL: {40, 700, 1.20, 0, false},
	DisplayM: {32, 700, 1.25, 0, false},
	TitleXL:  {26, 600, 1.30, 0, false},
	TitleL:   {20, 600, 1.35, 0, false},
	TitleM:   {17, 600, 1.40, 0, false},
	BodyL:    {16, 400, 1.60, 0, false},
	BodyM:    {15, 400, 1.50, 0, false},
	BodyS:    {13, 400, 1.50, 0, false},
	LabelL:   {15, 500, 1.40, 0, false},
	LabelM:   {13, 500, 1.40, 0, false},
	LabelS:   {11, 600, 1.30, 0.3, false},
	NumericM: {15, 500, 1.40, 0, true},
	NumericS: {13, 500, 1.40, 0, true},
}

// Text builds styled text of a role. The caller chooses the color by meaning:
// text roles carry no color, exactly as TyType does.
func Text(c *ui.Context, role Role, s string) ui.Element {
	spec := roles[role]
	e := ui.Text(c, s).FontSize(spec.size).FontWeight(spec.weight).LineHeight(spec.height)
	if spec.track != 0 {
		e.LetterSpacing(spec.track)
	}
	if spec.numeric {
		e.FontFeatures("tnum")
	}
	return e
}

// Textf is Text with a format string.
func Textf(c *ui.Context, role Role, format string, args ...any) ui.Element {
	return Text(c, role, fmt.Sprintf(format, args...))
}
