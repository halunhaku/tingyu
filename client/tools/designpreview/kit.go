package main

// kit.go holds the drawing vocabulary the three directions share: text in a
// direction's type scale, covers, hairlines, glass materials, progress bars,
// segmented controls and the small glyph vocabulary. Everything here is built
// from MyGo ui primitives (Box, Column, Row, Text, Image, Material, Gradient,
// Shadow, Absolute), which is what makes the stills evidence: no page is drawn
// with an asset the app could not draw itself.

import (
	"fmt"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/images"
)

type scene struct {
	c  *ui.Context
	d  Direction
	p  Palette
	at *data
}

func (s *scene) col(hex string) ui.Color { return ui.Hex(hex) }

// t draws text in a role of the direction's scale.
func (s *scene) t(role, text string, color ui.Color) ui.Element {
	st, ok := s.d.Type[role]
	if !ok {
		st = s.d.Type["body"]
	}
	e := ui.Text(s.c, text).FontSize(st.Size).FontWeight(st.Weight).LineHeight(st.Height)
	if st.Track != 0 {
		e.LetterSpacing(st.Track)
	}
	return e.TextColor(color)
}

// tn draws a number, with tabular figures so times and counts do not dance.
func (s *scene) tn(role, text string, color ui.Color) ui.Element {
	return s.t(role, text, color).FontFeatures("tnum")
}

func (s *scene) fill(w, h float32, color ui.Color, radius float32) ui.Element {
	e := ui.Box(s.c).Width(w).Height(h).Background(color)
	if radius > 0 {
		e.Radius(radius)
	}
	return e
}

// hoverFace is the transient hover tint: a few percent of ink, or of light in
// the dark theme, so it works over any surface.
func (s *scene) hoverFace() ui.Color {
	if s.p.Dark {
		return ui.RGBA(255, 255, 255, 0.07)
	}
	return ui.RGBA(20, 20, 22, 0.05)
}

func (s *scene) hair(w float32, color ui.Color) ui.Element {
	return ui.Box(s.c).Width(w).Height(1).Background(color)
}

func (s *scene) icon(svg *ui.SVG, size float32, color ui.Color) ui.Element {
	return ui.Icon(s.c, svg).FontSize(size).TextColor(color)
}

// cover draws a cover file with a rounded square, or the note placeholder the
// app draws for a missing one.
func (s *scene) cover(name string, w, h, radius float32) ui.Element {
	if b := s.at.covers.bitmap(name); b != nil {
		return ui.Image(s.c, b).Size(w, h).Fit(ui.Cover).Radius(radius)
	}
	box := ui.Box(s.c).Size(w, h).Radius(radius).Background(s.col(s.p.SurfaceSunken)).Center()
	box.Children(func() {
		s.icon(glyphNote, min(w, h)*0.36, s.col(s.p.Text3))
	})
	return box
}

// paintAmbient paints the cover's colour field over a page's own background,
// then washes it toward the canvas: the atmosphere, never a picture. It runs
// in Element.Draw, before the children, so content sits on top of it.
func (s *scene) paintAmbient(p *ui.Painter, r ui.Rect, name string, box ui.Rect, wash float32) {
	thumb := s.at.covers.thumb(name)
	if thumb == nil {
		return
	}
	p.Image(thumb, box, ui.Cover)
	if wash > 0 {
		p.Fill(r, s.col(s.p.Canvas).Alpha(wash), 0)
	}
}

// glass is the translucent pane of large surfaces (sidebar, toolbar, cards):
// Clear glass, which keeps the surface's own tone instead of frosting it
// white, with the token tint on top. The measured reason: on the dark theme
// Regular glass lifts #0E0E10 to about #555556 whatever its tint, which would
// make a sidebar lighter than the content it frames.
func (s *scene) glass(w, h, radius, clarity float32) ui.Element {
	tint := s.col(s.p.GlassTint)
	return ui.Box(s.c).Width(w).Height(h).Radius(radius).Material(glass.Glass{
		Style:   glass.Clear,
		Tint:    tint.Alpha(s.p.GlassAlpha),
		Clarity: clarity,
	})
}

// glassFrost is the material of small floating surfaces over content, as the
// transport pill: Regular glass, which blurs what scrolls under it.
func (s *scene) glassFrost(w, h, radius, clarity float32) ui.Element {
	tint := s.col(s.p.GlassTint)
	return ui.Box(s.c).Width(w).Height(h).Radius(radius).Material(glass.Glass{
		Style:   glass.Regular,
		Tint:    tint.Alpha(s.p.GlassAlpha),
		Clarity: clarity,
	})
}

// playButton is the one filled accent control: a circle with pause or play.
func (s *scene) playButton(diameter float32, playing bool) ui.Element {
	e := ui.Box(s.c).Size(diameter, diameter).Radius(diameter / 2).Background(s.col(s.p.Accent)).Center()
	e.Children(func() {
		icon := glyphPlay
		if playing {
			icon = glyphPause
		}
		s.icon(icon, diameter*0.4, s.col(s.p.OnAccent))
	})
	return e
}

// transportButton is a quiet circular button.
func (s *scene) transportButton(size float32, svg *ui.SVG, color ui.Color) ui.Element {
	e := ui.Box(s.c).Size(size, size).Radius(size / 2).Center()
	e.Children(func() { s.icon(svg, size*0.6, color) })
	return e
}

// progress draws a progress bar: the unfilled rail, the filled run and the
// thumb, all rounded, with the thumb's own shadow.
func (s *scene) progress(width, ratio, height, thumb float32) {
	if ratio < 0 {
		ratio = 0
	}
	if ratio > 1 {
		ratio = 1
	}
	filled := max(width*ratio, height)
	box := ui.Box(s.c).Width(width).Height(max(height, thumb)).Children(func() {
		track := ui.Box(s.c).Absolute().Left(0).Top((max(height, thumb) - height) / 2).
			Width(width).Height(height).Radius(height / 2).Background(s.col(s.p.Border))
		_ = track
		ui.Box(s.c).Absolute().Left(0).Top((max(height, thumb) - height) / 2).
			Width(filled).Height(height).Radius(height / 2).Background(s.col(s.p.Accent))
		if thumb > 0 {
			knob := ui.Box(s.c).Absolute().Left(filled-thumb/2).Top((max(height, thumb)-thumb)/2).
				Size(thumb, thumb).Radius(thumb / 2).Background(s.col(s.p.Accent))
			knob.Shadow(0, 1, 3, 0, ui.RGBA(0, 0, 0, 70))
		}
	})
	_ = box
}

// segmented draws a segmented control: a sunken trough with the chosen label
// on a raised pill.
func (s *scene) segmented(labels []string, active int, height float32) ui.Element {
	pad := float32(3)
	trough := ui.Row(s.c).Height(height).Padding(pad).Gap(2).
		Radius(s.d.Radius.SM + pad).Background(s.col(s.p.SurfaceSunken)).AlignItems(ui.Stretch)
	trough.Children(func() {
		for i, label := range labels {
			i := i
			cell := ui.Row(s.c).PaddingX(12).Radius(s.d.Radius.SM).AlignItems(ui.Center).Justify(ui.Center)
			if i == active {
				cell.Background(s.col(s.p.SurfaceRaised))
				cell.Shadow(1, 1, 2, 0, ui.RGBA(0, 0, 0, 20))
			}
			cell.Children(func() {
				color := s.col(s.p.Text2)
				if i == active {
					color = s.col(s.p.Text)
				}
				s.t("label", label, color)
			})
		}
	})
	return trough
}

// toggle is a switch in its on or off state.
func (s *scene) toggle(on bool) ui.Element {
	w, h := float32(36), float32(20)
	track := s.col(s.p.SurfaceSunken)
	knobColor := s.col(s.p.SurfaceRaised)
	offset := float32(2)
	if on {
		track = s.col(s.p.Accent)
		knobColor = ui.Hex("#FFFFFF")
		offset = w - h + 2
	}
	box := ui.Box(s.c).Size(w, h).Radius(h / 2).Background(track)
	if !on {
		box.Border(1, s.col(s.p.Border))
	}
	box.Children(func() {
		knob := ui.Box(s.c).Absolute().Left(offset).Top(2).Size(h-4, h-4).Radius((h-4)/2).
			Background(knobColor).Shadow(0, 1, 2, 0, ui.RGBA(0, 0, 0, 60))
		_ = knob
	})
	return box
}

// pill is a filter chip; active fills with the accent.
func (s *scene) pill(label string, active bool) ui.Element {
	e := ui.Row(s.c).Padding(12, 5).Radius(s.d.Radius.Pill).AlignItems(ui.Center)
	if active {
		e.Background(s.col(s.p.Accent))
	} else {
		e.Border(1, s.col(s.p.Border))
	}
	e.Children(func() {
		color := s.col(s.p.Text2)
		if active {
			color = s.col(s.p.OnAccent)
		}
		s.t("label", label, color)
	})
	return e
}

// field draws a search field or text input face.
func (s *scene) field(placeholder string, width, height float32, shortcut string) ui.Element {
	e := ui.Row(s.c).Width(width).Height(height).PaddingX(10).Gap(6).
		Radius(s.d.Radius.SM).Background(s.col(s.p.SurfaceRaised)).
		Border(1, s.col(s.p.Border)).AlignItems(ui.Center)
	e.Children(func() {
		s.icon(glyphSearch, 13, s.col(s.p.Text3))
		s.t("small", placeholder, s.col(s.p.Text3))
		ui.Spacer(s.c)
		if shortcut != "" {
			ui.Row(s.c).Padding(5, 2).Radius(s.d.Radius.XS).
				Background(s.col(s.p.SurfaceSunken)).Children(func() {
				s.t("numSm", shortcut, s.col(s.p.Text3))
			})
		}
	})
	return e
}

// button is a quiet button face; primary fills with the accent.
func (s *scene) button(label string, primary bool, height float32) ui.Element {
	e := ui.Row(s.c).Height(height).PaddingX(13).Radius(s.d.Radius.SM).
		AlignItems(ui.Center).Justify(ui.Center)
	if primary {
		e.Background(s.col(s.p.Accent))
	} else {
		e.Background(s.col(s.p.SurfaceRaised)).Border(1, s.col(s.p.Border))
	}
	e.Children(func() {
		color := s.col(s.p.Text)
		if primary {
			color = s.col(s.p.OnAccent)
		}
		s.t("label", label, color)
	})
	return e
}

// iconButton is a square quiet icon target.
func (s *scene) iconButton(size float32, svg *ui.SVG, color ui.Color) ui.Element {
	e := ui.Box(s.c).Size(size, size).Radius(s.d.Radius.SM).Center()
	e.Children(func() { s.icon(svg, size*0.5, color) })
	return e
}

// statusDot is a small filled dot with a label.
func (s *scene) statusDot(color ui.Color, label string) ui.Element {
	e := ui.Row(s.c).Gap(6).AlignItems(ui.Center)
	e.Children(func() {
		ui.Box(s.c).Size(6, 6).Radius(3).Background(color)
		s.t("label", label, s.col(s.p.Text2))
	})
	return e
}

// lyricFill draws a lyric line with the sung part in full contrast and the
// rest dimmed: the static frame of the word-by-word fill, made of two text
// runs so it is the same primitive the live transition would use.
func (s *scene) lyricFill(sung, rest string, on, off ui.Color) ui.Element {
	return ui.RichText(s.c,
		ui.Span{Text: sung, Weight: 600, Color: on},
		ui.Span{Text: rest, Weight: 600, Color: off},
	)
}

// stageColors extracts the cover's stage palette the way the app does, so the
// stills show the real M5 colour pipeline rather than hand-picked gradients.
func (s *scene) stageColors(name string) (ui.Color, ui.Color, bool) {
	if name == "" {
		return ui.Transparent, ui.Transparent, false
	}
	path := name
	if !filepath.IsAbs(path) {
		path = filepath.Join(s.at.covers.dir, name)
	}
	f, err := os.Open(path)
	if err != nil {
		return ui.Transparent, ui.Transparent, false
	}
	defer f.Close()
	var img image.Image
	if decoded, err := jpeg.Decode(f); err == nil {
		img = decoded
	} else {
		if _, seekErr := f.Seek(0, 0); seekErr != nil {
			return ui.Transparent, ui.Transparent, false
		}
		decoded, _, err := image.Decode(f)
		if err != nil {
			return ui.Transparent, ui.Transparent, false
		}
		img = decoded
	}
	pal, ok := images.Extract(img, images.Options{
		Dark: s.p.Dark, Canvas: hexRGB(s.p.Canvas), TextPrimary: hexRGB(s.p.Text),
	})
	if !ok {
		return ui.Transparent, ui.Transparent, false
	}
	return pal.Primary.Color(), pal.Secondary.Color(), true
}

// mix blends two colours, t=0 returning a and t=1 returning b, in sRGB space
// (the stage tint stays in the same gamut as its tokens).
func mix(a, b ui.Color, t float32) ui.Color {
	m := func(x, y uint8) uint8 { return uint8(float32(x)*(1-t) + float32(y)*t) }
	return ui.RGBA(m(a.R, b.R), m(a.G, b.G), m(a.B, b.B), float32(a.A)/255)
}

func hexRGB(hex string) images.RGB {
	c := ui.Hex(hex)
	return images.RGB{R: c.R, G: c.G, B: c.B}
}

// appVersion is mygo.json's version; the stills quote it instead of inventing
// one.
const appVersion = "0.1.0"

// syncState reads the real source status into what the pages show: a short
// label, whether it means trouble, the detail the library recorded, and when it
// last ran. The current library syncs partially (its directory nesting limit),
// so the renders show that state rather than a mocked success.
func (s *scene) syncState() (label string, warning bool, detail, when string) {
	label, warning = "尚未同步", false
	if len(s.at.Sources) > 0 {
		raw := s.at.Sources[0].Status
		label = raw
		if i := strings.IndexRune(raw, '（'); i >= 0 {
			label = raw[:i]
			detail = strings.TrimSuffix(strings.TrimPrefix(raw[i:], "（"), "）")
		}
		if label == "" {
			label = "尚未同步"
		}
		warning = !strings.Contains(label, "完成") && !strings.Contains(label, "已同步")
	}
	if !s.at.SourceSyncedAt.IsZero() {
		when = s.at.SourceSyncedAt.Local().Format("2006-01-02 15:04")
	} else {
		when = "—"
	}
	return label, warning, detail, when
}

// fmtDuration renders a duration as m:ss.
func fmtDuration(seconds float64) string {
	if seconds < 0 {
		seconds = 0
	}
	return fmt.Sprintf("%d:%02d", int(seconds)/60, int(seconds)%60)
}

func kmb(size int64) string {
	if size >= 1<<20 {
		return fmt.Sprintf("%.1f MB", float64(size)/(1<<20))
	}
	return fmt.Sprintf("%d KB", size>>10)
}
