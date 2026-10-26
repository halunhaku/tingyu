package model

// Cover tint for the stage (plan §6 M5 item 4, DESIGN.md §2.5).
//
// The extraction itself is internal/images (a straight port of the Flutter
// stage_palette.dart rules); this file is the cache around it. The cache key is
// the cover file name, its modification time and the theme, which is what the
// Flutter provider keys on: a new cover, a rewritten file and a theme switch
// each get their own entry, so a fast track change can never paint the previous
// cover's colour (DESIGN.md §2.5 rule 7).

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/images"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// paletteLimit is the Flutter client's LRU size for extracted palettes.
const paletteLimit = 64

type paletteKey struct {
	name     string
	modified int64
	dark     bool
}

type paletteEntry struct {
	palette images.Palette
	ok      bool
}

type paletteCache struct {
	mu      sync.Mutex
	dir     string
	entries map[paletteKey]paletteEntry
	order   []paletteKey
}

func (c *paletteCache) setDir(dir string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dir == dir {
		return
	}
	c.dir = dir
	c.entries = map[paletteKey]paletteEntry{}
	c.order = nil
}

// Palette returns the cover's stage palette for a theme. ok is false for a
// missing cover, a cover that cannot be decoded, or a gray one — the caller
// then draws the neutral gradient.
func (c *paletteCache) Palette(name string, dark bool) (images.Palette, bool) {
	if name == "" || c.dir == "" {
		return images.Palette{}, false
	}
	path := filepath.Join(c.dir, name)
	info, err := os.Stat(path)
	if err != nil {
		return images.Palette{}, false
	}
	key := paletteKey{name: name, modified: info.ModTime().UnixNano(), dark: dark}
	c.mu.Lock()
	if entry, hit := c.entries[key]; hit {
		c.touch(key)
		c.mu.Unlock()
		return entry.palette, entry.ok
	}
	c.mu.Unlock()

	palette, ok := extractPalette(path, dark)

	c.mu.Lock()
	if c.entries == nil {
		c.entries = map[paletteKey]paletteEntry{}
	}
	c.entries[key] = paletteEntry{palette: palette, ok: ok}
	c.touch(key)
	for len(c.order) > paletteLimit {
		oldest := c.order[0]
		c.order = c.order[1:]
		if oldest != key {
			delete(c.entries, oldest)
		}
	}
	c.mu.Unlock()
	return palette, ok
}

// touch moves key to the young end, under the lock.
func (c *paletteCache) touch(key paletteKey) {
	for i, existing := range c.order {
		if existing == key {
			c.order = append(c.order[:i], c.order[i+1:]...)
			break
		}
	}
	c.order = append(c.order, key)
}

// extractPalette reads and decodes one cover file and runs the extraction with
// the theme's canvas and text color.
func extractPalette(path string, dark bool) (images.Palette, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return images.Palette{}, false
	}
	img, err := images.Decode(data)
	if err != nil {
		return images.Palette{}, false
	}
	palette := tokens.For(dark)
	return images.Extract(img, images.Options{
		Dark:        dark,
		Canvas:      images.ColorOf(palette.Canvas),
		TextPrimary: images.ColorOf(palette.TextPrimary),
	})
}

// SetCoversDir points the palette cache at the cover directory too.
func (s *State) setPaletteDir(dir string) { s.palettes.setDir(dir) }

// NeutralStageColors is the gradient the stage falls back to when tinting is
// off, there is no cover, the cover is gray, or extraction failed (DESIGN.md
// §2.5 rule 8). The two endpoints are exactly M4's (canvas → surfaceSunken, or
// canvas → surface in a dark theme): the fallback must look unchanged, because
// M5 only adds the cover's colours on top of the existing stage (plan §6 M5
// constraint "不改视觉设计语言").
func NeutralStageColors(dark bool) (from, to ui.Color) {
	palette := tokens.For(dark)
	if dark {
		return palette.Canvas, palette.Surface
	}
	return palette.Canvas, palette.SurfaceSunken
}

// StageColors is the stage background for a track's cover in this theme: the
// two palette colors when tinting is on and extraction succeeded, the neutral
// token gradient otherwise. The colors already carry the 35% canvas flatten, so
// the stage paints the same surface the Flutter client shows.
func (s *State) StageColors(coverName string, dark bool) (from, to ui.Color) {
	if !s.settings.CoverTint || coverName == "" {
		return NeutralStageColors(dark)
	}
	palette, ok := s.palettes.Palette(coverName, dark)
	if !ok {
		if s.logf != nil && coverName != "" {
			s.logf("palette: no usable colour in %s, using the neutral gradient", coverName)
		}
		return NeutralStageColors(dark)
	}
	return palette.Primary.Color(), palette.Secondary.Color()
}
