// Package images is the M5 image pipeline: a content-addressed cover store,
// the HTTP fetch in front of it, and the palette (cover tint) the stage uses.
//
// The rules are translated from the Flutter client, which stays the reference
// for behaviour during the dual-track period: app/lib/data/cover_store.dart
// (FNV-1a file names, orphan pruning) and
// app/lib/features/player/stage_palette.dart (24 px thumbnail, 12 hue buckets,
// lightness/saturation gates, gray fallback, per-theme clamps, 7:1 contrast,
// 35% canvas flatten). The mygo-cloudmusic research report suggests 18 buckets
// with an s²·v weight; that is its own variant and is not adopted here, because
// the report itself says the Flutter palette is our specification
// (docs/research/2026-10-26-mygo-cloudmusic-reference.md §3.8).
package images

import (
	"math"

	"github.com/egoist/mygo/ui"
)

// RGB is one opaque sRGB color.
type RGB struct {
	R, G, B uint8
}

// Color converts to the UI's color type.
func (c RGB) Color() ui.Color { return ui.RGB(c.R, c.G, c.B) }

// Hex renders the color as #rrggbb, which is what the acceptance record quotes.
func (c RGB) Hex() string {
	const digits = "0123456789ABCDEF"
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	out[1] = digits[c.R>>4]
	out[2] = digits[c.R&0xF]
	out[3] = digits[c.G>>4]
	out[4] = digits[c.G&0xF]
	out[5] = digits[c.B>>4]
	out[6] = digits[c.B&0xF]
	return string(out)
}

// ColorOf converts a UI color back to RGB (alpha is dropped: the pipeline only
// ever handles opaque token colors).
func ColorOf(c ui.Color) RGB { return RGB{R: c.R, G: c.G, B: c.B} }

// hsl is hue in degrees, saturation and lightness in 0..1 — the same shape as
// Flutter's HSLColor, so the thresholds below are the Dart ones unchanged.
type hsl struct {
	h, s, l float64
}

// toHSL is Flutter's HSLColor.fromColor: sRGB to HSL.
func toHSL(c RGB) hsl {
	r := float64(c.R) / 255
	g := float64(c.G) / 255
	b := float64(c.B) / 255
	maxv := math.Max(r, math.Max(g, b))
	minv := math.Min(r, math.Min(g, b))
	l := (maxv + minv) / 2
	var h, s float64
	if maxv != minv {
		d := maxv - minv
		if l > 0.5 {
			s = d / (2 - maxv - minv)
		} else {
			s = d / (maxv + minv)
		}
		switch maxv {
		case r:
			h = (g - b) / d
			if g < b {
				h += 6
			}
		case g:
			h = (b-r)/d + 2
		default:
			h = (r-g)/d + 4
		}
		h *= 60
	}
	return hsl{h: h, s: s, l: l}
}

// toRGB is HSLColor.toColor.
func (v hsl) toRGB() RGB {
	if v.s == 0 {
		gray := channel(v.l)
		return RGB{gray, gray, gray}
	}
	var q float64
	if v.l < 0.5 {
		q = v.l * (1 + v.s)
	} else {
		q = v.l + v.s - v.l*v.s
	}
	p := 2*v.l - q
	hue := math.Mod(v.h, 360) / 360
	if hue < 0 {
		hue += 1
	}
	return RGB{
		R: channel(hueToChannel(p, q, hue+1.0/3)),
		G: channel(hueToChannel(p, q, hue)),
		B: channel(hueToChannel(p, q, hue-1.0/3)),
	}
}

func hueToChannel(p, q, t float64) float64 {
	if t < 0 {
		t++
	}
	if t > 1 {
		t--
	}
	switch {
	case t < 1.0/6:
		return p + (q-p)*6*t
	case t < 1.0/2:
		return q
	case t < 2.0/3:
		return p + (q-p)*(2.0/3-t)*6
	default:
		return p
	}
}

func channel(value float64) uint8 {
	if value <= 0 {
		return 0
	}
	if value >= 1 {
		return 255
	}
	return uint8(math.Round(value * 255))
}

// luminance is WCAG relative luminance (what Flutter's computeLuminance does).
func luminance(c RGB) float64 {
	linear := func(v uint8) float64 {
		s := float64(v) / 255
		if s <= 0.03928 {
			return s / 12.92
		}
		return math.Pow((s+0.055)/1.055, 2.4)
	}
	return 0.2126*linear(c.R) + 0.7152*linear(c.G) + 0.0722*linear(c.B)
}

// contrast is the WCAG ratio between two colors.
func contrast(a, b RGB) float64 {
	la, lb := luminance(a), luminance(b)
	hi, lo := math.Max(la, lb), math.Min(la, lb)
	return (hi + 0.05) / (lo + 0.05)
}

// blend is Flutter's Color.alphaBlend(source over background) with an alpha in
// 0..1, non-premultiplied sRGB: straight channel interpolation.
func blend(source RGB, alpha float64, background RGB) RGB {
	if alpha <= 0 {
		return background
	}
	if alpha >= 1 {
		return source
	}
	mix := func(s, d uint8) uint8 {
		return uint8(math.Round(float64(s)*alpha + float64(d)*(1-alpha)))
	}
	return RGB{R: mix(source.R, background.R), G: mix(source.G, background.G), B: mix(source.B, background.B)}
}
