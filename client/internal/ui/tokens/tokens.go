// Package tokens is the design-token layer of direction A (声档 1.5「静室」,
// docs/design/2026-10-26-ui-redesign-directions.md §4.2). It is the only place
// where a color, a size or a duration is spelled out; components and pages take
// them from here, so the shell and the pages stay one design.
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

// Space is the 4pt grid of §4.2 (4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 56 / 72).
// The odd steps in between are kept for the few places that need half a step.
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
	Space56 float32 = 56
	Space72 float32 = 72
)

// PagePadding is the page inset (§4.2: 32).
const PagePadding float32 = 32

// Radii (§4.2: XS 4 / SM 8 / MD 12 / LG 16 / XL 22 / Pill 999).
const (
	RadiusXS   float32 = 4
	RadiusSM   float32 = 8
	RadiusMD   float32 = 12
	RadiusLG   float32 = 16
	RadiusXL   float32 = 22
	RadiusFull float32 = 999
)

// Sizes (§4.2): fixed geometry that does not follow density.
const (
	SidebarWidth      float32 = 236
	TransportHeight   float32 = 88
	PageHeaderHeight  float32 = 64
	TableRowHeight    float32 = 44
	TableHeaderHeight float32 = 26
	// The track table's fixed column rhythm (§10-4):
	// 序号 22 + 封面 44 + 曲名 330 + 艺术家 170 + 专辑 210 + 弹性 + 时长 56 + 收藏 30.
	TableIndex    float32 = 22
	TableCoverCol float32 = 44
	TableCover    float32 = 30
	TableTitle    float32 = 330
	TableArtist   float32 = 170
	TableAlbum    float32 = 210
	TableDuration float32 = 56
	TableFavorite float32 = 30
	TableSource   float32 = 130
	// StageCoverMax is the stage cover of §4.3 (raised from M4's 360 to 392).
	StageCoverMax float32 = 392
	// StageTopBar is the stage's top row (§4.3: 顶部 60).
	StageTopBar float32 = 60
	// StagePadding is the stage content's horizontal inset (§4.3): the 392
	// cover + 72 gap + the lyrics column, 76 on each side at 1200 wide.
	StagePadding float32 = 76
	// StageContentGap is the gap between the stage's cover column and its
	// lyrics column (§4.3).
	StageContentGap float32 = 72
	// CoverShelf is the "最近添加" cover card (§4.3).
	CoverShelf float32 = 104
	// ToolbarControl is the height of every control in a page's toolbar (§10-8).
	ToolbarControl float32 = 32
	// SidebarItem is the sidebar's row height (§10-1: 44 → 34).
	SidebarItem float32 = 34
	// EmptyIcon is the empty state's icon tile (§10-13: 56).
	EmptyIcon float32 = 56
	// ErrorCard is the error card's width (§10-13: 440).
	ErrorCard float32 = 440

	IconInline  float32 = 14
	IconCompact float32 = 16
	IconNormal  float32 = 20

	// SearchPaletteWide is the command palette's width (§4.4: 560).
	SearchPaletteWide float32 = 560
	// SourcePanel is the source form / QR panel (§4.4: 360×420, QR 168).
	SourcePanelWidth  float32 = 360
	SourcePanelHeight float32 = 420
	SourceQR          float32 = 168

	// SettingsContent is the settings page's content column (§10-12: 620),
	// beside the about card; direction A's horizontal tabs replace the second
	// navigation column the first batch still carried.
	SettingsContent float32 = 620
	// AboutCardMax caps the about card in settings, so the pair stays a reading
	// column on a very wide window.
	AboutCardMax float32 = 280
	// SourceCardMax is the source card's width (§4.3: 最大 620) and
	// SourceInfoWidth its right-hand information column (288).
	SourceCardMax   float32 = 620
	SourceInfoWidth float32 = 288

	CompactPagePad   float32 = 24
	CompactSidebar   float32 = 208
	CompactRowHeight float32 = 40
)

// Glass is the material of a surface (§1.2, §10-14): Clear glass keeps the
// surface's own tone, which is what large panes framing content must do.
const (
	// GlassSidebarAlpha and GlassTransportAlpha are the tint alpha of the two
	// long surfaces (§4.2 GlassTint @ 0.72 light / 0.56 dark; §10-14 0.72/0.56).
	GlassSidebarAlpha   float32 = 0.72
	GlassTransportAlpha float32 = 0.56
	// GlassBlur is the panes' clarity input (§4.2 blur 24).
	GlassBlur float32 = 24
	// GlassPopoverAlpha is the tint of a popover's Regular glass (§10-14): the
	// frost is what raises the panel, so the tint stays low enough for the page
	// under it to read through.
	GlassPopoverAlpha float32 = 0.6
	// SidebarAmbientWash leaves 30% of the current cover showing behind the
	// sidebar (§10-1: 30% 封面氛围).
	SidebarAmbientWash float32 = 0.7
	// StageAmbientWash is the stage's own atmosphere (§4.3): a 28 px thumbnail
	// stretched over the window and washed 86%, so it is light, not a picture.
	StageAmbientWash float32 = 0.86
)

// StageAtmosphere is how far the cover's two colours are mixed toward the
// canvas on the stage (§10-9: 向 Canvas 混合 50%). The extraction already
// flattens them 35% toward the canvas, so the page mixes the rest of the way.
const StageAtmosphere float32 = 0.5

// Mix blends a toward b by t (0..1) in sRGB — the same arithmetic the design
// stills used, so a colour token and a page can agree on "half strength".
func Mix(a, b ui.Color, t float32) ui.Color {
	m := func(x, y uint8) uint8 { return uint8(float32(x)*(1-t) + float32(y)*t) }
	return ui.RGBA(m(a.R, b.R), m(a.G, b.G), m(a.B, b.B), float32(a.A)/255)
}

// Motion durations (DESIGN.md §7.1 and §4.5).
const (
	DurationMicro   = 90 * time.Millisecond
	DurationFast    = 120 * time.Millisecond
	DurationBase    = 200 * time.Millisecond
	DurationSheet   = 240 * time.Millisecond
	DurationStage   = 320 * time.Millisecond
	DurationCover   = 180 * time.Millisecond
	DurationShimmer = 1400 * time.Millisecond
	DurationAmbient = 24 * time.Second

	LyricsManualPause  = 3 * time.Second
	SearchDebounceTime = 250 * time.Millisecond
)

// Easing follows TyCurve.standard: cubic-bezier(0.2, 0, 0, 1).
var Easing = ui.CubicBezier(0.2, 0, 0, 1)

// Palette is one brightness of the A palette (§4.2).
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

	// GlassTint and GlassAlpha are the sidebar/transport glass (§4.2).
	GlassTint  ui.Color
	GlassAlpha float32
	ScrimAlpha float32

	SkeletonBase      ui.Color
	SkeletonHighlight ui.Color
	CoverPlaceholder  ui.Color

	// Opaque hover/pressed faces for the built-in theme, which composites
	// nothing (the palette's hover is ink over an unknown base).
	SurfaceHoverSolid   ui.Color
	SurfacePressedSolid ui.Color
	Scrollbar           ui.Color
}

// Light is the A palette's light brightness.
var Light = Palette{
	Dark:                false,
	Canvas:              ui.Hex("#F4F4F1"),
	Surface:             ui.Hex("#FCFCFA"),
	SurfaceSunken:       ui.Hex("#ECECE7"),
	SurfaceRaised:       ui.Hex("#FFFFFF"),
	Overlay:             ui.Hex("#FFFFFF"),
	Hover:               ui.RGBA(20, 20, 22, 0.05),
	Pressed:             ui.RGBA(20, 20, 22, 0.08),
	Selected:            ui.RGBA(176, 27, 46, 0.12),
	Border:              ui.Hex("#E1E1DA"),
	BorderStrong:        ui.Hex("#CFCFC6"),
	TextPrimary:         ui.Hex("#17171A"),
	TextSecondary:       ui.Hex("#5E5E63"),
	TextTertiary:        ui.Hex("#6A6A71"),
	TextDisabled:        ui.Hex("#A9A9AE"),
	Accent:              ui.Hex("#B01B2E"),
	AccentHover:         ui.Hex("#C0182B"),
	AccentPressed:       ui.Hex("#A81226"),
	AccentSoft:          ui.RGBA(176, 27, 46, 0.12),
	OnAccent:            ui.Hex("#FFFFFF"),
	Success:             ui.Hex("#1F6B45"),
	Warning:             ui.Hex("#8A5209"),
	Danger:              ui.Hex("#A8201A"),
	Focus:               ui.Hex("#B01B2E"),
	Scrim:               ui.RGBA(0, 0, 0, 0.38),
	GlassTint:           ui.Hex("#FCFCFA"),
	GlassAlpha:          0.72,
	ScrimAlpha:          0.38,
	SkeletonBase:        ui.Hex("#E6E6E0"),
	SkeletonHighlight:   ui.Hex("#F6F6F2"),
	CoverPlaceholder:    ui.Hex("#E7E7E1"),
	SurfaceHoverSolid:   ui.Hex("#E9E9E4"),
	SurfacePressedSolid: ui.Hex("#E1E1DA"),
	Scrollbar:           ui.RGBA(0, 0, 0, 0.32),
}

// Dark is the A palette's dark brightness.
var Dark = Palette{
	Dark:                true,
	Canvas:              ui.Hex("#0E0E10"),
	Surface:             ui.Hex("#161618"),
	SurfaceSunken:       ui.Hex("#101012"),
	SurfaceRaised:       ui.Hex("#1C1C20"),
	Overlay:             ui.Hex("#1C1C20"),
	Hover:               ui.RGBA(255, 255, 255, 0.07),
	Pressed:             ui.RGBA(255, 255, 255, 0.10),
	Selected:            ui.RGBA(242, 109, 126, 0.15),
	Border:              ui.Hex("#2B2B31"),
	BorderStrong:        ui.Hex("#3B3B43"),
	TextPrimary:         ui.Hex("#F3F3F5"),
	TextSecondary:       ui.Hex("#A0A0A8"),
	TextTertiary:        ui.Hex("#7C7C85"),
	TextDisabled:        ui.Hex("#5A5A62"),
	Accent:              ui.Hex("#F26D7E"),
	AccentHover:         ui.Hex("#FF8A97"),
	AccentPressed:       ui.Hex("#E8455A"),
	AccentSoft:          ui.RGBA(242, 109, 126, 0.15),
	OnAccent:            ui.Hex("#0E0E10"),
	Success:             ui.Hex("#5BD98F"),
	Warning:             ui.Hex("#E3A85B"),
	Danger:              ui.Hex("#FF7066"),
	Focus:               ui.Hex("#F26D7E"),
	Scrim:               ui.RGBA(0, 0, 0, 0.56),
	GlassTint:           ui.Hex("#161618"),
	GlassAlpha:          0.56,
	ScrimAlpha:          0.56,
	SkeletonBase:        ui.Hex("#1E1E22"),
	SkeletonHighlight:   ui.Hex("#2A2A30"),
	CoverPlaceholder:    ui.Hex("#22222A"),
	SurfaceHoverSolid:   ui.Hex("#232326"),
	SurfacePressedSolid: ui.Hex("#2C2C30"),
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
	// The built-in list/table hover paints an opaque face; blending the ink
	// token over the canvas keeps §4.4's "悬停（墨 5%）" over any page.
	t.SurfaceHover = Blend(p.Canvas, p.Hover)
	t.SurfacePressed = Blend(p.Canvas, p.Pressed)
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
	t.Selection = Blend(p.Canvas, p.Selected)
	t.Focus = p.Focus
	t.Scrollbar = p.Scrollbar
	t.ScrollbarWidth = 8
	t.Radius = RadiusSM
	t.Spacing = 4
	if compact {
		t.Spacing = 3
	}
	return &t
}

// Role is a typography step of §4.2. Sizes are the Flutter sizes in DIPs.
type Role int

const (
	Display     Role = iota // 40 / 700 / 1.08 / -0.8 — stage title
	H1                      // 28 / 700 / 1.18 / -0.4 — page title
	H2                      // 20 / 600 / 1.28 / -0.2 — group title
	H3                      // 15 / 600 / 1.40 /  0   — card title
	Body                    // 14 / 400 / 1.60 /  0   — body, row titles
	Small                   // 13 / 400 / 1.55 /  0   — row artist/album
	Caption                 // 13 / 500 / 1.40 / +0.05 — cover card title
	Label                   // 12 / 500 / 1.35 / +0.2 — buttons, tags, nav
	Overline                // 11 / 600 / 1.25 / +0.8 — table header, group label
	Num                     // 12 / 500 / 1.35 /  0 tnum — durations
	NumSm                   // 11 / 500 / 1.30 / +0.2 tnum — counts
	Lyric                   // 15 / 400 / 1.90 /  0   — inactive lyric line
	LyricActive             // 18 / 600 / 1.55 / -0.1 — current lyric line
)

type roleSpec struct {
	size    float32
	weight  int
	height  float32
	track   float32
	numeric bool
}

var roles = [...]roleSpec{
	Display:     {40, 700, 1.08, -0.8, false},
	H1:          {28, 700, 1.18, -0.4, false},
	H2:          {20, 600, 1.28, -0.2, false},
	H3:          {15, 600, 1.40, 0, false},
	Body:        {14, 400, 1.60, 0, false},
	Small:       {13, 400, 1.55, 0, false},
	Caption:     {13, 500, 1.40, 0.05, false},
	Label:       {12, 500, 1.35, 0.2, false},
	Overline:    {11, 600, 1.25, 0.8, false},
	Num:         {12, 500, 1.35, 0, true},
	NumSm:       {11, 500, 1.30, 0.2, true},
	Lyric:       {15, 400, 1.90, 0, false},
	LyricActive: {18, 600, 1.55, -0.1, false},
}

// RoleSpec is a role's numbers — size in DIP, weight, line-height multiple,
// tracking in DIP and whether the figures are tabular — for layout that has to
// know them and for the test that locks §4.2's ladder.
func RoleSpec(role Role) (size float32, weight int, height, track float32, numeric bool) {
	spec := roles[role]
	return spec.size, spec.weight, spec.height, spec.track, spec.numeric
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
		// §10-6: durations and counts are tabular, so a changing time does not
		// shift the row.
		e.FontFeatures("tnum")
	}
	return e
}

// Textf is Text with a format string.
func Textf(c *ui.Context, role Role, format string, args ...any) ui.Element {
	return Text(c, role, fmt.Sprintf(format, args...))
}

// Tabular marks any other text as tabular figures (§10-6).
func Tabular(e ui.Element) ui.Element { return e.FontFeatures("tnum") }
