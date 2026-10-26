package images

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"

	"golang.org/x/image/webp"
)

// ErrNoImage reports bytes that are not a static JPEG, PNG, GIF or WebP.
var ErrNoImage = errors.New("images: not a decodable image")

// Decode decodes the cover formats the three metadata sources serve: JPEG
// (QQ, iTunes and Netease all end up here), PNG, GIF's first frame and WebP.
// Animated WebP is refused with ErrNoImage instead of being guessed at; the
// caller then keeps the placeholder, and the failure is logged once.
func Decode(data []byte) (image.Image, error) {
	if len(data) == 0 {
		return nil, ErrNoImage
	}
	if img, err := jpeg.Decode(bytes.NewReader(data)); err == nil {
		return img, nil
	}
	if img, err := png.Decode(bytes.NewReader(data)); err == nil {
		return img, nil
	}
	if img, err := gif.Decode(bytes.NewReader(data)); err == nil {
		return img, nil
	}
	if img, err := webp.Decode(bytes.NewReader(data)); err == nil {
		return img, nil
	}
	return nil, ErrNoImage
}

// Thumbnail shrinks img to at most width pixels wide, keeping the aspect
// ratio, by averaging each destination pixel over the source box it covers —
// the same "block mean" sampling the Flutter palette gets from decoding at a
// target width. It never upscales.
func Thumbnail(img image.Image, width int) *image.RGBA {
	if img == nil || width <= 0 {
		return nil
	}
	bounds := img.Bounds()
	srcW, srcH := bounds.Dx(), bounds.Dy()
	if srcW == 0 || srcH == 0 {
		return nil
	}
	if srcW <= width {
		dst := image.NewRGBA(image.Rect(0, 0, srcW, srcH))
		for y := 0; y < srcH; y++ {
			for x := 0; x < srcW; x++ {
				dst.Set(x, y, img.At(bounds.Min.X+x, bounds.Min.Y+y))
			}
		}
		return dst
	}
	dstW := width
	dstH := max(1, srcH*width/srcW)
	dst := image.NewRGBA(image.Rect(0, 0, dstW, dstH))
	for dy := 0; dy < dstH; dy++ {
		y0 := dy * srcH / dstH
		y1 := max(y0+1, (dy+1)*srcH/dstH)
		for dx := 0; dx < dstW; dx++ {
			x0 := dx * srcW / dstW
			x1 := max(x0+1, (dx+1)*srcW/dstW)
			var rs, gs, bs, as, n uint64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					r, g, b, a := img.At(bounds.Min.X+x, bounds.Min.Y+y).RGBA()
					rs += uint64(r)
					gs += uint64(g)
					bs += uint64(b)
					as += uint64(a)
					n++
				}
			}
			if n == 0 {
				continue
			}
			dst.SetRGBA(dx, dy, color.RGBA{
				R: uint8((rs / n) >> 8), G: uint8((gs / n) >> 8),
				B: uint8((bs / n) >> 8), A: uint8((as / n) >> 8),
			})
		}
	}
	return dst
}
