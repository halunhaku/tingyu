package model

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/egoist/mygo/ui"
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
}

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
