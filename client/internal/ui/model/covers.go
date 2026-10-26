package model

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/images"
)

// CoverCache keeps decoded cover bitmaps in memory, bounded (a library of ten
// thousand tracks shares a few hundred covers). The M5 pieces — the HTTP fetch,
// the content-addressed store and the palette — live in internal/images; this
// is the read-only decode path the tables and the stage draw from, keyed by the
// content-addressed file name, so a new cover is a new entry.
type CoverCache struct {
	mu      sync.Mutex
	dir     string
	entries map[string]*ui.Bitmap
	missing map[string]bool
	order   []string
	max     int
	// thumbs are the 28 px versions the stage's atmosphere draws: scaling a
	// small bitmap over the window is the soft colour field without a shader
	// (§4.3 28 px 缩略图放大做 86% 洗过的氛围).
	thumbs map[string]*ui.Bitmap
	// thumbOrder bounds them: only the current stage cover is drawn, so a
	// handful covers a listening session.
	thumbOrder []string
}

// CoverThumbWidth is the stage's atmosphere thumbnail width (§4.3).
const CoverThumbWidth = 28

// thumbLimit is how many 28 px thumbnails the cache keeps.
const thumbLimit = 12

// SetDir points the cache at the covers directory, dropping decoded bitmaps
// when it changes.
func (c *CoverCache) SetDir(dir string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dir == dir {
		return
	}
	c.dir = dir
	c.entries = map[string]*ui.Bitmap{}
	c.missing = map[string]bool{}
	c.order = nil
	c.thumbs = map[string]*ui.Bitmap{}
	c.thumbOrder = nil
	if c.max == 0 {
		c.max = 96
	}
}

// Bitmap decodes a cover file once and keeps it. It returns nil for a missing
// or undecodable file; callers draw the placeholder instead.
func (c *CoverCache) Bitmap(name string) *ui.Bitmap {
	if name == "" {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dir == "" {
		return nil
	}
	if bitmap, ok := c.entries[name]; ok {
		return bitmap
	}
	if c.missing[name] {
		return nil
	}
	data, err := os.ReadFile(filepath.Join(c.dir, name))
	if err != nil {
		c.missing[name] = true
		return nil
	}
	bitmap, err := ui.DecodeBitmap(data)
	if err != nil {
		c.missing[name] = true
		return nil
	}
	if c.max == 0 {
		c.max = 96
	}
	c.entries[name] = bitmap
	c.order = append(c.order, name)
	for len(c.order) > c.max {
		oldest := c.order[0]
		c.order = c.order[1:]
		if oldest != name {
			delete(c.entries, oldest)
		}
	}
	return bitmap
}

// CoverBitmap returns a decoded cover for a track, through the shared cache.
func (s *State) CoverBitmap(name string) *ui.Bitmap {
	if s.coversDir == "" {
		return nil
	}
	return s.covers.Bitmap(name)
}

// CoverThumb returns the cover as a 28 px wide bitmap for the stage's
// atmosphere. The file is decoded once per cover and halved by block mean
// (images.Thumbnail), so the stage never samples a 1000 px texture across the
// whole window each frame.
func (c *CoverCache) Thumb(name string) *ui.Bitmap {
	if name == "" {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.dir == "" {
		return nil
	}
	if bitmap, ok := c.thumbs[name]; ok {
		return bitmap
	}
	data, err := os.ReadFile(filepath.Join(c.dir, name))
	if err != nil {
		return nil
	}
	img, err := images.Decode(data)
	if err != nil {
		return nil
	}
	small := images.Thumbnail(img, CoverThumbWidth)
	if small == nil {
		return nil
	}
	bitmap := ui.NewBitmap(small)
	if c.thumbs == nil {
		c.thumbs = map[string]*ui.Bitmap{}
	}
	c.thumbs[name] = bitmap
	c.thumbOrder = append(c.thumbOrder, name)
	for len(c.thumbOrder) > thumbLimit {
		oldest := c.thumbOrder[0]
		c.thumbOrder = c.thumbOrder[1:]
		if oldest != name {
			delete(c.thumbs, oldest)
		}
	}
	return bitmap
}

// CoverThumb returns the 28 px thumbnail of a track's cover through the state's
// shared cache (the stage's atmosphere).
func (s *State) CoverThumb(name string) *ui.Bitmap {
	if s.coversDir == "" {
		return nil
	}
	return s.covers.Thumb(name)
}
