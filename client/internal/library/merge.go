package library

// Scan merging. The semantics are copied from app/lib/data/repositories/
// track_repository.dart (plan §2.1 #2): match on (sourceId, filePathOrUrl),
// overwrite file facts only, keep user assets (cover/lyrics/favourite/play
// stats), and delete missing tracks only for an authoritative snapshot. A
// cancelled, truncated or partially unreadable scan must never delete: a
// transient permission error would otherwise wipe a source and its playlist
// entries.

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// Placeholder values the Flutter client uses for unknown metadata. They are
// also the values merge is allowed to replace with real metadata.
const (
	UnknownArtist = "未知艺术家"
	UnknownAlbum  = "未知专辑"
)

var placeholderAlbums = map[string]bool{
	UnknownAlbum: true,
	"夸克曲库":       true,
	"WebDAV 曲库":  true,
}

// ScannedTrack is one fact set produced by a scan. Local scanning fills it
// from file metadata; remote sources will fill the same struct in M3.
type ScannedTrack struct {
	FilePathOrURL string
	Title         string
	Artist        string
	Album         string
	Duration      time.Duration
	TrackNumber   int // 0 when unknown
	DiscNumber    int // 0 when unknown
	Year          int // 0 when unknown
	Genre         string
	Bitrate       int
	SampleRate    int
	FileFormat    string
	FileSize      int64
	LastModified  time.Time
	CoverArtPath  string // content-addressed file name inside covers/
	CoverArtURL   string
	Lyrics        string
}

// MergeResult counts what a merge changed.
type MergeResult struct {
	Added   int
	Updated int
	Removed int
}

// TrackID is the stable id of a track inside a source. Scanning the same
// directory twice is idempotent because the id is derived, not random.
func TrackID(sourceID, filePathOrURL string) string {
	return sourceID + "::" + filePathOrURL
}

type existingTrack struct {
	id   string
	path string
	row  Track
}

// MergeScan writes a scan result into the library in one transaction.
// removeMissing may only be true for a complete, authoritative snapshot.
func (l *Library) MergeScan(ctx context.Context, sourceID string, scanned []ScannedTrack, removeMissing bool) (MergeResult, error) {
	if !l.writes {
		return MergeResult{}, fmt.Errorf("library: connection is read-only")
	}
	if strings.TrimSpace(sourceID) == "" {
		return MergeResult{}, fmt.Errorf("library: merge needs a source id")
	}
	existing, err := l.sourceTracks(ctx, sourceID)
	if err != nil {
		return MergeResult{}, err
	}
	byPath := make(map[string]existingTrack, len(existing))
	for _, track := range existing {
		byPath[track.path] = track
	}

	now := time.Now().UTC()
	seen := make(map[string]bool, len(scanned))
	statements := make([]sqlite.Statement, 0, len(scanned)+len(existing)+2)
	var result MergeResult
	var changedIDs []string

	for _, incoming := range scanned {
		path := incoming.FilePathOrURL
		if path == "" || seen[path] {
			continue
		}
		seen[path] = true
		old, found := byPath[path]
		if !found {
			id := TrackID(sourceID, path)
			statements = append(statements, insertTrack(id, sourceID, incoming, now))
			changedIDs = append(changedIDs, id)
			result.Added++
			continue
		}
		merged, changed := withFileFacts(old.row, incoming)
		if !changed {
			continue
		}
		statements = append(statements, updateTrack(merged))
		changedIDs = append(changedIDs, merged.ID)
		result.Updated++
	}

	if removeMissing {
		for _, track := range existing {
			if seen[track.path] {
				continue
			}
			statements = append(statements, sqlite.Statement{
				SQL:  `DELETE FROM tracks WHERE id = ?`,
				Args: []any{track.id},
			})
			changedIDs = append(changedIDs, track.id)
			result.Removed++
		}
	}

	if len(statements) == 0 {
		return result, nil
	}
	if _, err := l.db.Transaction(ctx, statements); err != nil {
		return MergeResult{}, fmt.Errorf("library: merge %s: %w", sourceID, err)
	}
	l.bump(changedIDs...)
	return result, nil
}

func (l *Library) sourceTracks(ctx context.Context, sourceID string) ([]existingTrack, error) {
	const query = `
SELECT id, source_id, title, artist, album, duration,
       track_number, disc_number, year, genre, bitrate, sample_rate,
       file_format, file_path_or_url, file_size, last_modified,
       cover_art_path, cover_art_url, lyrics,
       is_favorite, date_added, play_count, last_played_at
FROM tracks WHERE source_id = ?`
	rows, err := l.db.Query(ctx, query, sourceID)
	if err != nil {
		return nil, fmt.Errorf("library: read source tracks: %w", err)
	}
	out := make([]existingTrack, 0, len(rows.Values))
	for i, value := range rows.Values {
		track, err := trackFromRow(value)
		if err != nil {
			return nil, fmt.Errorf("library: source track row %d: %w", i+1, err)
		}
		out = append(out, existingTrack{id: track.ID, path: track.FilePath, row: track})
	}
	return out, nil
}

func insertTrack(id, sourceID string, incoming ScannedTrack, now time.Time) sqlite.Statement {
	return sqlite.Statement{
		SQL: `INSERT INTO tracks
		  (id, source_id, title, artist, album, duration,
		   track_number, disc_number, year, genre, bitrate, sample_rate,
		   file_format, file_path_or_url, file_size,
		   etag, last_modified, cover_art_path, cover_art_url, lyrics,
		   is_favorite, date_added, play_count, last_played_at)
		  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, 0, ?, 0, NULL)`,
		Args: []any{
			id, sourceID, incoming.Title, nonEmpty(incoming.Artist, UnknownArtist),
			nonEmpty(incoming.Album, UnknownAlbum), durationSeconds(incoming.Duration),
			nullableInt(incoming.TrackNumber), nullableInt(incoming.DiscNumber),
			nullableInt(incoming.Year), nullableString(incoming.Genre),
			nullableInt(incoming.Bitrate), nullableInt(incoming.SampleRate),
			nonEmpty(incoming.FileFormat, "mp3"), incoming.FilePathOrURL, incoming.FileSize,
			nullableTime(incoming.LastModified), nullableString(incoming.CoverArtPath),
			nullableString(incoming.CoverArtURL), nullableString(incoming.Lyrics),
			formatTime(now),
		},
	}
}

// withFileFacts applies the incoming file facts to an existing row and
// reports whether anything changed. User assets stay: cover, lyrics,
// favourite, play count and last played. Placeholders are replaced by real
// metadata, which is the only metadata an incoming scan may overwrite.
func withFileFacts(old Track, incoming ScannedTrack) (Track, bool) {
	merged := old
	changed := false

	setDuration := func(d time.Duration) {
		if d > 0 && d != old.Duration {
			merged.Duration = d
			changed = true
		}
	}
	setDuration(incoming.Duration)
	if incoming.FileSize != old.FileSize {
		merged.FileSize = incoming.FileSize
		changed = true
	}
	if incoming.FileFormat != "" && incoming.FileFormat != old.FileFormat {
		merged.FileFormat = incoming.FileFormat
		changed = true
	}
	if modifiedChanged(old, incoming.LastModified) {
		merged.LastModified = incoming.LastModified
		changed = true
	}
	if isPlaceholderText(old.Title) && strings.TrimSpace(incoming.Title) != "" {
		merged.Title = incoming.Title
		changed = true
	}
	if isPlaceholderArtist(old.Artist) && !isPlaceholderArtist(incoming.Artist) {
		merged.Artist = incoming.Artist
		changed = true
	}
	if placeholderAlbums[old.Album] && incoming.Album != "" && !placeholderAlbums[incoming.Album] {
		merged.Album = incoming.Album
		changed = true
	}
	if old.CoverArtPath == "" && incoming.CoverArtPath != "" {
		merged.CoverArtPath = incoming.CoverArtPath
		changed = true
	}
	if old.CoverArtURL == "" && incoming.CoverArtURL != "" {
		merged.CoverArtURL = incoming.CoverArtURL
		changed = true
	}
	if old.TrackNumber == 0 && incoming.TrackNumber != 0 {
		merged.TrackNumber = incoming.TrackNumber
		changed = true
	}
	if old.DiscNumber == 0 && incoming.DiscNumber != 0 {
		merged.DiscNumber = incoming.DiscNumber
		changed = true
	}
	if old.Year == 0 && incoming.Year != 0 {
		merged.Year = incoming.Year
		changed = true
	}
	if old.Genre == "" && incoming.Genre != "" {
		merged.Genre = incoming.Genre
		changed = true
	}
	if old.Bitrate == 0 && incoming.Bitrate != 0 {
		merged.Bitrate = incoming.Bitrate
		changed = true
	}
	if old.SampleRate == 0 && incoming.SampleRate != 0 {
		merged.SampleRate = incoming.SampleRate
		changed = true
	}
	if old.Lyrics == "" && incoming.Lyrics != "" {
		merged.Lyrics = incoming.Lyrics
		changed = true
	}
	return merged, changed
}

func updateTrack(track Track) sqlite.Statement {
	return sqlite.Statement{
		SQL: `UPDATE tracks SET
		  title = ?, artist = ?, album = ?, duration = ?,
		  track_number = ?, disc_number = ?, year = ?, genre = ?,
		  bitrate = ?, sample_rate = ?, file_format = ?, file_size = ?,
		  last_modified = ?, cover_art_path = ?, cover_art_url = ?, lyrics = ?
		 WHERE id = ?`,
		Args: []any{
			track.Title, track.Artist, track.Album, durationSeconds(track.Duration),
			nullableInt(track.TrackNumber), nullableInt(track.DiscNumber),
			nullableInt(track.Year), nullableString(track.Genre),
			nullableInt(track.Bitrate), nullableInt(track.SampleRate),
			nonEmpty(track.FileFormat, "mp3"), track.FileSize,
			nullableTime(track.LastModified), nullableString(track.CoverArtPath),
			nullableString(track.CoverArtURL), nullableString(track.Lyrics),
			track.ID,
		},
	}
}

// modifiedChanged compares two file times at the precision the database
// stores (microseconds). Comparing raw time.Time values would see every file
// as changed after a round trip and re-parse the whole library on each scan.
func modifiedChanged(old Track, incoming time.Time) bool {
	if incoming.IsZero() {
		return false
	}
	if old.LastModified.IsZero() {
		// A zero old value means "unknown" only when the row also has no file
		// size; otherwise the file was scanned before and legitimately had no
		// modification time.
		return true
	}
	return old.LastModified.UnixMicro() != incoming.Truncate(time.Microsecond).UnixMicro()
}

func durationSeconds(d time.Duration) float64 {
	return float64(d) / float64(time.Second)
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func isPlaceholderText(value string) bool { return strings.TrimSpace(value) == "" }

func isPlaceholderArtist(value string) bool {
	return value == "" || value == UnknownArtist
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func nullableInt(value int) any {
	if value == 0 {
		return nil
	}
	return value
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return formatTime(value)
}
