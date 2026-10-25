package scan

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// Options configure one scan.
type Options struct {
	// CoversDir receives embedded covers; empty skips cover extraction.
	CoversDir string
	// Known is what the library already recorded for this source, so files
	// whose size and mtime are unchanged skip tag parsing.
	Known library.FileFacts
	// MaxFiles caps the walk (MaxFiles when 0).
	MaxFiles int
	// Progress is called after each file, from the scanning goroutine.
	Progress func(done, total int, path string)
	// Cancelled is polled before each file.
	Cancelled func() bool
}

// Result is one directory scan.
type Result struct {
	Tracks          []library.ScannedTrack
	Files           int
	UnreadableFiles int
	UnreadableDirs  int
	Cancelled       bool
	Truncated       bool
}

// Authoritative reports whether this snapshot may delete tracks missing from
// it. A cancelled, truncated or partly unreadable scan must not: a transient
// permission error would otherwise wipe the source.
func (r Result) Authoritative() bool {
	return !r.Cancelled && !r.Truncated && r.UnreadableFiles == 0 && r.UnreadableDirs == 0
}

// Scan walks root and reads metadata for every supported file.
func Scan(root string, opts Options) Result {
	if opts.MaxFiles <= 0 {
		opts.MaxFiles = MaxFiles
	}
	files, unreadableDirs, truncated := collect(root, opts.MaxFiles, opts.Cancelled)
	result := Result{Files: len(files), UnreadableDirs: unreadableDirs, Truncated: truncated}
	if result.Cancelled = opts.Cancelled != nil && opts.Cancelled(); result.Cancelled {
		return result
	}
	result.Tracks = make([]library.ScannedTrack, 0, len(files))
	for i, path := range files {
		if opts.Cancelled != nil && opts.Cancelled() {
			result.Cancelled = true
			return result
		}
		track, ok := trackFor(path, opts)
		if ok {
			result.Tracks = append(result.Tracks, track)
		} else {
			result.UnreadableFiles++
		}
		if opts.Progress != nil {
			opts.Progress(i+1, len(files), path)
		}
	}
	return result
}

// collect lists supported files, sorted, skipping dot entries and symlinks.
func collect(root string, maxFiles int, cancelled func() bool) (files []string, unreadableDirs int, truncated bool) {
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return nil, 1, false
	}
	step := func(path string, entry fs.DirEntry, err error) error {
		if cancelled != nil && cancelled() {
			return filepath.SkipAll
		}
		if err != nil {
			unreadableDirs++
			if entry != nil && entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		name := entry.Name()
		if strings.HasPrefix(name, ".") {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if !isSupported(path) {
			return nil
		}
		files = append(files, path)
		if len(files) >= maxFiles {
			return filepath.SkipAll
		}
		return nil
	}
	_ = filepath.WalkDir(root, step)
	sort.Strings(files)
	if len(files) >= maxFiles {
		truncated = true
	}
	return files, unreadableDirs, truncated
}

func isSupported(path string) bool {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	return SupportedExtensions[ext]
}

// trackFor turns one file into facts. It never returns !ok for a metadata
// error: a file whose tags cannot be read still belongs in the library with
// its name and file facts (metadata enrichment is M5).
func trackFor(path string, opts Options) (library.ScannedTrack, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return library.ScannedTrack{}, false
	}
	modified := info.ModTime()
	format := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	if fact, ok := opts.Known[path]; ok &&
		fact.Size == info.Size() &&
		fact.Modified.UnixMicro() == modified.Truncate(time.Microsecond).UnixMicro() {
		return factTrack(path, format, info.Size(), modified), true
	}

	meta, metaErr := ReadMeta(path)
	track := library.ScannedTrack{
		FilePathOrURL: path,
		Title:         fallbackTitle(path, meta.Title),
		Artist:        meta.Artist,
		Album:         meta.Album,
		Duration:      meta.Duration,
		TrackNumber:   meta.TrackNumber,
		DiscNumber:    meta.DiscNumber,
		Year:          meta.Year,
		Genre:         meta.Genre,
		Bitrate:       meta.Bitrate,
		SampleRate:    meta.SampleRate,
		FileFormat:    format,
		FileSize:      info.Size(),
		LastModified:  modified,
		Lyrics:        meta.Lyrics,
	}
	if metaErr == nil && len(meta.Picture) > 0 && opts.CoversDir != "" {
		// A cover that cannot be written is not a scan failure: the track and
		// its tags are still valid.
		if name, err := SaveCover(opts.CoversDir, meta.Picture); err == nil {
			track.CoverArtPath = name
		}
	}
	return track, true
}

func fallbackTitle(path, title string) string {
	if strings.TrimSpace(title) != "" {
		return title
	}
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}
