package images

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// solid builds a test cover of one color.
func solid(w, h int, c RGB) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, color.RGBA{R: c.R, G: c.G, B: c.B, A: 255})
		}
	}
	return img
}

// twoTone builds a cover split down the middle.
func twoTone(w, h int, left, right RGB) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := left
			if x >= w/2 {
				c = right
			}
			img.SetRGBA(x, y, color.RGBA{R: c.R, G: c.G, B: c.B, A: 255})
		}
	}
	return img
}

func TestExtractRejectsGrayAndFallsBack(t *testing.T) {
	dark := Options{Dark: true, Canvas: RGB{0x0C, 0x0C, 0x0F}, TextPrimary: RGB{0xF4, 0xF4, 0xF7}}
	for name, cover := range map[string]*image.RGBA{
		"gray":       solid(48, 48, RGB{128, 128, 128}),
		"near-black": solid(48, 48, RGB{10, 10, 10}),
		"near-white": solid(48, 48, RGB{250, 250, 250}),
	} {
		if palette, ok := Extract(cover, dark); ok {
			t.Errorf("%s: got a palette %+v, want the neutral fallback", name, palette)
		}
	}
}

func TestExtractPicksTheDominantHueAndKeepsContrast(t *testing.T) {
	opts := Options{Dark: true, Canvas: RGB{0x0C, 0x0C, 0x0F}, TextPrimary: RGB{0xF4, 0xF4, 0xF7}}
	palette, ok := Extract(solid(64, 64, RGB{0xC0, 0x28, 0x28}), opts)
	if !ok {
		t.Fatal("a red cover must yield a palette")
	}
	primary := toHSL(palette.Primary)
	if primary.h > 30 && primary.h < 330 {
		t.Errorf("primary hue %.1f is not red", primary.h)
	}
	if got := contrast(palette.Primary, opts.TextPrimary); got < minContrast {
		t.Errorf("primary %s has contrast %.2f against the text, want >= %.0f", palette.Primary.Hex(), got, minContrast)
	}
	if got := contrast(palette.Secondary, opts.TextPrimary); got < minContrast {
		t.Errorf("secondary %s has contrast %.2f against the text, want >= %.0f", palette.Secondary.Hex(), got, minContrast)
	}
}

func TestExtractSecondaryIsFarEnoughInHue(t *testing.T) {
	opts := Options{Dark: false, Canvas: RGB{0xF7, 0xF7, 0xF9}, TextPrimary: RGB{0x16, 0x16, 0x1A}}
	palette, ok := Extract(twoTone(64, 64, RGB{0xC0, 0x28, 0x28}, RGB{0x28, 0x40, 0xC0}), opts)
	if !ok {
		t.Fatal("a two-colour cover must yield a palette")
	}
	gap := hueGap(toHSL(palette.Primary).h, toHSL(palette.Secondary).h)
	if gap < secondaryHueGap {
		t.Errorf("primary %s / secondary %s differ by %.1f°, want >= %.0f°",
			palette.Primary.Hex(), palette.Secondary.Hex(), gap, secondaryHueGap)
	}
}

// TestExtractSameCoverInBothThemes is the acceptance's palette evidence: one
// cover, the two themes' real stage background colors, logged for the record.
func TestExtractSameCoverInBothThemes(t *testing.T) {
	cover := twoTone(96, 96, RGB{0x1F, 0x6F, 0x4A}, RGB{0xC8, 0x9A, 0x30})
	darkOpts := Options{Dark: true, Canvas: RGB{0x0C, 0x0C, 0x0F}, TextPrimary: RGB{0xF4, 0xF4, 0xF7}}
	lightOpts := Options{Dark: false, Canvas: RGB{0xF7, 0xF7, 0xF9}, TextPrimary: RGB{0x16, 0x16, 0x1A}}
	dark, ok := Extract(cover, darkOpts)
	if !ok {
		t.Fatal("dark extraction failed")
	}
	light, ok := Extract(cover, lightOpts)
	if !ok {
		t.Fatal("light extraction failed")
	}
	t.Logf("same-cover dark=%s→%s light=%s→%s",
		dark.Primary.Hex(), dark.Secondary.Hex(), light.Primary.Hex(), light.Secondary.Hex())
	if dark.Primary.Hex() == light.Primary.Hex() {
		t.Fatalf("both themes produced %s: the per-theme clamps did not apply", dark.Primary.Hex())
	}
	for _, check := range []struct {
		name    string
		palette Palette
		opts    Options
	}{
		{"dark", dark, darkOpts}, {"light", light, lightOpts},
	} {
		for _, c := range []RGB{check.palette.Primary, check.palette.Secondary} {
			if got := contrast(c, check.opts.TextPrimary); got < minContrast {
				t.Errorf("%s: %s has contrast %.2f, want >= %.0f", check.name, c.Hex(), got, minContrast)
			}
		}
	}
}

func TestThumbnailKeepsAspect(t *testing.T) {
	thumb := Thumbnail(solid(96, 48, RGB{9, 9, 9}), 24)
	if thumb == nil {
		t.Fatal("no thumbnail")
	}
	if w, h := thumb.Bounds().Dx(), thumb.Bounds().Dy(); w != 24 || h != 12 {
		t.Fatalf("thumbnail %dx%d, want 24x12", w, h)
	}
	if got := Thumbnail(solid(10, 10, RGB{1, 2, 3}), 24); got.Bounds().Dx() != 10 {
		t.Fatalf("upscaled to %d, want the source width 10", got.Bounds().Dx())
	}
}

func TestStoreSavesByContentAndCounts(t *testing.T) {
	dir := t.TempDir()
	store := &Store{Dir: dir}
	data := []byte("\x89PNG\r\n\x1a\ncover-one")
	name, existed, err := store.Save(data)
	if err != nil || existed {
		t.Fatalf("first save: name=%q existed=%v err=%v", name, existed, err)
	}
	again, existed, err := store.Save(data)
	if err != nil || !existed || again != name {
		t.Fatalf("second save: name=%q existed=%v err=%v, want %q existed", again, existed, err, name)
	}
	stats := store.Stats()
	if stats.Saved != 1 || stats.Reused != 1 {
		t.Fatalf("stats %+v, want saved=1 reused=1", stats)
	}
	if _, ok := store.Path(name); !ok {
		t.Fatalf("cover %s not resolvable", name)
	}
}

func TestStorePruneKeepsSharedCovers(t *testing.T) {
	dir := t.TempDir()
	store := &Store{Dir: dir}
	shared, _, _ := store.Save([]byte("\xff\xd8shared"))
	orphan, _, _ := store.Save([]byte("\xff\xd8orphan"))
	keep := map[string]bool{shared: true}
	removed, err := store.Prune(keep)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 {
		t.Fatalf("removed %d covers, want 1", removed)
	}
	if _, ok := store.Path(shared); !ok {
		t.Fatal("a shared cover was removed")
	}
	if _, ok := store.Path(orphan); ok {
		t.Fatal("the orphan cover survived")
	}
	if stats := store.Stats(); stats.Pruned != 1 {
		t.Fatalf("prune counter %d, want 1", stats.Pruned)
	}
}

func jpegBytes(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, solid(32, 32, RGB{30, 90, 200}), nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestFetcherDownloadsOnceThenHitsTheDisk(t *testing.T) {
	dir := t.TempDir()
	store := &Store{Dir: dir}
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Header.Get("User-Agent") == "" {
			t.Error("no User-Agent")
		}
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write(jpegBytes(t))
	}))
	defer server.Close()
	fetcher := &Fetcher{Store: store, Client: server.Client()}
	url := server.URL + "/cover.jpg"
	first, data, err := fetcher.Cover(context.Background(), url)
	if err != nil || first == "" || len(data) == 0 {
		t.Fatalf("first fetch: name=%q bytes=%d err=%v", first, len(data), err)
	}
	second, data, err := fetcher.Cover(context.Background(), url)
	if err != nil || second != first || len(data) == 0 {
		t.Fatalf("second fetch: name=%q bytes=%d err=%v", second, len(data), err)
	}
	if requests != 1 {
		t.Fatalf("%d HTTP requests, want 1 (the second must come from disk)", requests)
	}
	stats := fetcher.Stats()
	if stats.Downloaded != 1 || stats.Reused != 1 || stats.HitRate() != 0.5 {
		t.Fatalf("stats %+v hitRate %.2f, want downloaded=1 reused=1 rate=0.50", stats, stats.HitRate())
	}
}

func TestFetcherFailsSilently(t *testing.T) {
	dir := t.TempDir()
	store := &Store{Dir: dir}
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		http.Error(w, "<html>not an image</html>", http.StatusNotFound)
	}))
	defer server.Close()
	fetcher := &Fetcher{Store: store, Client: server.Client()}
	url := server.URL + "/gone.jpg"
	for i := 0; i < 3; i++ {
		if _, _, err := fetcher.Cover(context.Background(), url); !errors.Is(err, ErrFetch) {
			t.Fatalf("attempt %d: err=%v, want ErrFetch", i, err)
		}
	}
	if requests != 1 {
		t.Fatalf("%d requests, want 1 while the failure is remembered", requests)
	}
	if stats := fetcher.Stats(); stats.Failed != 1 {
		t.Fatalf("failed=%d, want 1", stats.Failed)
	}
}

func TestFetcherOfflineIsAnErrorNotAPanic(t *testing.T) {
	fetcher := &Fetcher{
		Store: &Store{Dir: t.TempDir()},
		Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return nil, errors.New("network is unreachable")
		})},
	}
	if _, _, err := fetcher.Cover(context.Background(), "https://example.invalid/a.jpg"); !errors.Is(err, ErrFetch) {
		t.Fatalf("err=%v, want ErrFetch", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestDecodeRefusesGarbage(t *testing.T) {
	if _, err := Decode([]byte("not an image")); !errors.Is(err, ErrNoImage) {
		t.Fatalf("err=%v, want ErrNoImage", err)
	}
	// A real JPEG decodes.
	if _, err := Decode(jpegBytes(t)); err != nil {
		t.Fatalf("jpeg: %v", err)
	}
	// A file written by the store is readable by the resolver.
	path := filepath.Join(t.TempDir(), "x.jpg")
	if err := os.WriteFile(path, jpegBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
}
