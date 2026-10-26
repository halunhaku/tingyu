package images

import (
	"image"
	"math"
)

// Extraction parameters, one for one with _Palette in
// app/lib/features/player/stage_palette.dart (DESIGN.md §2.5). Changing one
// here means changing it there too, or the two clients pick different colors
// from the same cover.
const (
	// PaletteWidth is the thumbnail width used for colour extraction: colour
	// needs no sharpness.
	PaletteWidth = 24

	minLightness  = 0.08
	maxLightness  = 0.92
	minSaturation = 0.08

	// grayRatio is the share of accepted pixels below which the cover counts
	// as gray and the caller falls back to the neutral gradient.
	grayRatio = 0.2

	minAlpha   = 20
	maxSamples = 4096

	hueBuckets      = 12
	secondaryHueGap = 24.0
	rotatedHue      = 18.0

	minClampSaturation = 0.28
	maxClampSaturation = 0.46
	lightMin           = 0.72
	lightMax           = 0.84
	darkMin            = 0.10
	darkMax            = 0.18

	minContrast   = 7.0
	lightnessStep = 0.05
	flattenAlpha  = 0.35
)

// Options are the inputs a theme contributes to extraction: the canvas the
// stage paints on, and the text color the background must keep readable.
type Options struct {
	Dark        bool
	Canvas      RGB
	TextPrimary RGB
}

// Palette is a cover's two stage colors, already flattened over the canvas at
// 35% and adjusted until the stage's text keeps its contrast. Gray reports the
// "no usable colour" case, where the caller draws the neutral token gradient
// instead (DESIGN.md §2.5 rule 8).
type Palette struct {
	Primary   RGB
	Secondary RGB
	Gray      bool
}

// Extract picks the stage palette of a cover. ok is false when the image has
// too few coloured pixels — a gray cover, a photo of a white wall, a failure
// to decode upstream: the caller then uses the neutral gradient, exactly as
// the Flutter palette returns null and FluidBackground falls back.
//
// The algorithm is stage_palette.dart's: shrink to 24 px wide, drop pixels that
// are too dark, too light or too gray, histogram their hue into 12 buckets, and
// take the two fullest buckets that are at least 24° apart (rotating the
// primary by 18° when there is only one). Saturation and lightness are then
// clamped per theme, and lightness is stepped until the flattened background
// keeps 7:1 against the stage's text.
func Extract(img image.Image, opts Options) (Palette, bool) {
	thumb := Thumbnail(img, PaletteWidth)
	if thumb == nil {
		return Palette{}, false
	}
	bounds := thumb.Bounds()
	total := bounds.Dx() * bounds.Dy()
	if total == 0 {
		return Palette{}, false
	}

	var hueSum, satSum, lightSum [hueBuckets]float64
	var counts [hueBuckets]int
	accepted := 0
	step := max(1, total/maxSamples)
	for i := 0; i < total; i += step {
		x := bounds.Min.X + i%bounds.Dx()
		y := bounds.Min.Y + i/bounds.Dx()
		r, g, b, a := thumb.At(x, y).RGBA()
		if a>>8 < minAlpha {
			continue
		}
		value := toHSL(RGB{R: uint8(r >> 8), G: uint8(g >> 8), B: uint8(b >> 8)})
		if value.l < minLightness || value.l > maxLightness || value.s < minSaturation {
			continue
		}
		accepted++
		bucket := int(value.h/(360.0/hueBuckets)) % hueBuckets
		if bucket < 0 {
			bucket += hueBuckets
		}
		hueSum[bucket] += value.h
		satSum[bucket] += value.s
		lightSum[bucket] += value.l
		counts[bucket]++
	}
	if accepted == 0 || float64(accepted)/float64(total/step) < grayRatio {
		return Palette{}, false
	}

	primaryBucket := peakBucket(&counts)
	if primaryBucket < 0 {
		return Palette{}, false
	}
	primary := bucketHSL(primaryBucket, &counts, &hueSum, &satSum, &lightSum, opts.Dark)
	secondary := primary
	secondary.h = math.Mod(primary.h+rotatedHue, 360)
	if bucket := secondaryBucket(primaryBucket, &counts, primary); bucket >= 0 {
		secondary = bucketHSL(bucket, &counts, &hueSum, &satSum, &lightSum, opts.Dark)
	}
	return Palette{
		Primary:   flatten(contrasted(primary, opts), opts.Canvas),
		Secondary: flatten(contrasted(secondary, opts), opts.Canvas),
	}, true
}

func peakBucket(counts *[hueBuckets]int) int {
	best := -1
	for i, count := range counts {
		if count > 0 && (best < 0 || count > counts[best]) {
			best = i
		}
	}
	return best
}

// secondaryBucket is the fullest bucket whose hue differs from the primary by
// at least 24°, or -1 when every other bucket is too close.
func secondaryBucket(primaryBucket int, counts *[hueBuckets]int, primary hsl) int {
	best := -1
	for i, count := range counts {
		if i == primaryBucket || count == 0 {
			continue
		}
		hue := (float64(i) + 0.5) * (360.0 / hueBuckets)
		if hueGap(primary.h, hue) < secondaryHueGap {
			continue
		}
		if best < 0 || count > counts[best] {
			best = i
		}
	}
	return best
}

func hueGap(a, b float64) float64 {
	raw := math.Mod(math.Abs(a-b), 360)
	if raw > 180 {
		return 360 - raw
	}
	return raw
}

func bucketHSL(bucket int, counts *[hueBuckets]int, hueSum, satSum, lightSum *[hueBuckets]float64, dark bool) hsl {
	count := float64(counts[bucket])
	saturation := clamp(satSum[bucket]/count, minClampSaturation, maxClampSaturation)
	low, high := lightMin, lightMax
	if dark {
		low, high = darkMin, darkMax
	}
	lightness := clamp(lightSum[bucket]/count, low, high)
	return hsl{h: math.Mod(hueSum[bucket]/count, 360), s: saturation, l: lightness}
}

// contrasted steps a color's lightness until the flattened background keeps
// 7:1 against the stage's text (DESIGN.md §2.5 rule 5). Dark themes get darker,
// light themes lighter, because the text sits at the opposite end.
func contrasted(value hsl, opts Options) hsl {
	for i := 0; i < 20; i++ {
		if contrast(flatten(value, opts.Canvas), opts.TextPrimary) >= minContrast {
			break
		}
		if opts.Dark {
			value.l -= lightnessStep
		} else {
			value.l += lightnessStep
		}
		value.l = clamp(value.l, 0, 1)
	}
	return value
}

// flatten is the 35% canvas layer the stage paints over its gradient, applied
// here so the palette returns the color that actually shows.
func flatten(value hsl, canvas RGB) RGB { return blend(value.toRGB(), flattenAlpha, canvas) }

func clamp(value, low, high float64) float64 {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}
