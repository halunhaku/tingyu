package main

// data.go reads a library copy (never writes it) and turns it into the small
// fixture the renders draw: the track list, the queue, one source, the demo
// track's lyrics and its decoded covers. The renders show the real library's
// shape — a Quark source with 周杰伦's covers — because a design judged on
// invented content is not evidence.

import (
	"context"
	"fmt"
	"image"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	xdraw "golang.org/x/image/draw"

	"github.com/halunhaku/tingyu/client/internal/library"
)

type track struct {
	Title      string
	Artist     string
	Album      string
	Duration   time.Duration
	Cover      string
	Format     string
	Bitrate    int
	SampleRate int
	Size       int64
	Path       string
	Favorite   bool
	Year       int
	DateAdded  time.Time
	RawLyrics  string
}

type source struct {
	Name     string
	Kind     string
	Count    int64
	Status   string
	SyncedAt time.Time
}

type playlist struct {
	Name  string
	Count int64
}

type lyricLine struct {
	At   time.Duration
	Text string
}

type data struct {
	Tracks         []track
	Queue          []track
	Now            track
	Position       time.Duration
	Sources        []source
	Playlists      []playlist
	Lyrics         []lyricLine
	covers         *coverCache
	Total          int
	AlbumCount     int
	ArtistCount    int
	Favorites      int
	SourceName     string
	SourceStatus   string
	SourceSyncedAt time.Time
	DataDir        string
	LibrarySize    int64
	CoverCount     int
}

// load reads the library at dir read-only. It copies nothing: library.Open is
// the read-only path the acceptance tools already use.
func load(dir string) (*data, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	lib, err := library.Open(ctx, library.Path(dir))
	if err != nil {
		return nil, err
	}
	defer lib.Close()
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		return nil, err
	}
	sources, err := lib.Sources(ctx)
	if err != nil {
		return nil, err
	}
	if len(tracks) == 0 {
		return nil, fmt.Errorf("no tracks in %s", dir)
	}
	d := &data{Total: len(tracks), covers: newCoverCache(library.CoversDir(dir)), DataDir: dir}
	if info, err := os.Stat(library.Path(dir)); err == nil {
		d.LibrarySize = info.Size()
	}
	if entries, err := os.ReadDir(library.CoversDir(dir)); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() {
				d.CoverCount++
			}
		}
	}
	albums := map[string]bool{}
	artists := map[string]bool{}
	for _, t := range tracks {
		row := track{
			Title: t.Title, Artist: t.Artist, Album: t.Album, Duration: t.Duration,
			Cover: t.CoverArtPath, Format: t.FileFormat, Bitrate: t.Bitrate,
			SampleRate: t.SampleRate, Size: t.FileSize, Path: t.FilePath,
			Favorite: t.IsFavorite, Year: t.Year, DateAdded: t.DateAdded, RawLyrics: t.Lyrics,
		}
		if row.Artist == "" {
			row.Artist = "未知艺术家"
		}
		if row.Album == "" {
			row.Album = "未知专辑"
		}
		albums[row.Album+"\x00"+row.Artist] = true
		artists[row.Artist] = true
		if row.Favorite {
			d.Favorites++
		}
		d.Tracks = append(d.Tracks, row)
	}
	d.AlbumCount, d.ArtistCount = len(albums), len(artists)
	for _, s := range sources {
		d.Sources = append(d.Sources, source{Name: s.Name, Kind: s.Kind, Count: s.TrackCount, Status: s.SyncStatus, SyncedAt: s.LastSyncedAt})
		d.SourceName = s.Name
		d.SourceStatus = s.SyncStatus
		d.SourceSyncedAt = s.LastSyncedAt
	}
	if lists, err := lib.Playlists(ctx); err == nil {
		for _, l := range lists {
			d.Playlists = append(d.Playlists, playlist{Name: l.Name, Count: int64(l.TrackCount)})
		}
	}
	d.Now = pickDemo(d.Tracks)
	d.Queue = queueAround(d.Tracks, d.Now, 24)
	d.Lyrics = parseLRC(d.Now.RawLyrics)
	d.Position = 96 * time.Second
	if len(d.Lyrics) > 10 {
		// Some way in, so the stage shows past, active and upcoming lines of
		// the song itself rather than its credits header.
		d.Position = d.Lyrics[8].At + 900*time.Millisecond
	}
	for _, t := range d.Tracks {
		if t.Cover != "" {
			d.covers.bitmap(t.Cover)
		}
	}
	return d, nil
}

// pickDemo prefers a track with both lyrics and a cover, as the M4 screenshot
// tool does, so the stage can show the design's hardest case.
func pickDemo(tracks []track) track {
	best := tracks[0]
	for _, t := range tracks {
		if t.RawLyrics != "" && t.Cover != "" {
			return t
		}
	}
	for _, t := range tracks {
		if t.Cover != "" {
			best = t
		}
	}
	return best
}

func queueAround(tracks []track, now track, n int) []track {
	out := []track{now}
	for _, t := range tracks {
		if len(out) >= n {
			break
		}
		if t.Title != now.Title || t.Album != now.Album {
			out = append(out, t)
		}
	}
	return out
}

// activeLyric is the index of the line playing at the demo position.
func (d *data) activeLyric() int {
	active := 0
	for i, l := range d.Lyrics {
		if l.At <= d.Position {
			active = i
		}
	}
	return active
}

// parseLRC reads the simple LRC the library stores: [mm:ss.xx] text, with
// blank text lines dropped.
func parseLRC(raw string) []lyricLine {
	var out []lyricLine
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "[") {
			continue
		}
		end := strings.Index(line, "]")
		if end < 0 {
			continue
		}
		stamp := line[1:end]
		text := strings.TrimSpace(line[end+1:])
		if text == "" {
			continue
		}
		parts := strings.Split(stamp, ":")
		if len(parts) != 2 {
			continue
		}
		mm, err1 := strconv.Atoi(parts[0])
		ss, err2 := strconv.ParseFloat(parts[1], 64)
		if err1 != nil || err2 != nil {
			continue
		}
		out = append(out, lyricLine{At: time.Duration(mm)*time.Minute + time.Duration(ss*float64(time.Second)), Text: text})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At < out[j].At })
	return out
}

// coverCache decodes cover files once. The renders share it, so 24 stills cost
// one decode per distinct cover.
type coverCache struct {
	dir    string
	byName map[string]*ui.Bitmap
	thumbs map[string]*ui.Bitmap
}

func newCoverCache(dir string) *coverCache {
	return &coverCache{dir: dir, byName: map[string]*ui.Bitmap{}, thumbs: map[string]*ui.Bitmap{}}
}

// thumb returns the cover as a 28-pixel-wide bitmap. Stretched to the window,
// it is the soft colour field the materials blur: the same "paint it small and
// scale it up" trick the reference client uses for its backdrop, with no
// effect shader needed.
func (c *coverCache) thumb(name string) *ui.Bitmap {
	if name == "" {
		return nil
	}
	if b, ok := c.thumbs[name]; ok {
		return b
	}
	path := name
	if !strings.ContainsRune(name, os.PathSeparator) {
		path = c.dir + string(os.PathSeparator) + name
	}
	f, err := os.Open(path)
	if err != nil {
		c.thumbs[name] = nil
		return nil
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		c.thumbs[name] = nil
		return nil
	}
	bounds := img.Bounds()
	w := 28
	h := max(1, int(float64(bounds.Dy())*float64(w)/float64(bounds.Dx())))
	small := image.NewRGBA(image.Rect(0, 0, w, h))
	xdraw.CatmullRom.Scale(small, small.Bounds(), img, bounds, xdraw.Src, nil)
	b := ui.NewBitmap(small)
	c.thumbs[name] = b
	return b
}

func (c *coverCache) bitmap(name string) *ui.Bitmap {
	if name == "" {
		return nil
	}
	if b, ok := c.byName[name]; ok {
		return b
	}
	path := name
	if !strings.ContainsRune(name, os.PathSeparator) {
		path = c.dir + string(os.PathSeparator) + name
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		c.byName[name] = nil
		return nil
	}
	b, err := ui.DecodeBitmap(raw)
	if err != nil {
		c.byName[name] = nil
		return nil
	}
	c.byName[name] = b
	return b
}
