// Package library reads and writes Tingyu's SQLite library.
//
// The schema, the indexes and PRAGMA user_version=2 are shared with the
// Flutter client (app/lib/data/db/schema.dart), which must keep working until
// M7. Migration is "补差" (create what is missing, add nullable columns) and
// never bumps the version (plan §8.1 rule 3).
//
// M1 opens the library read-write for exactly two writes (plan §6 M1, last
// item): the scan merge and the play history/play count. Everything else —
// favourites, playlists, metadata enrichment — stays out until a later
// milestone, and no code here writes it.
//
// The production library is never the one opened during development: the
// caller points TINGYU_DATA_DIR at a copy (plan §8.1 rule 2).
package library

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// SchemaVersion is the PRAGMA user_version this client reads and writes. The
// migration plan freezes it at 2 for the dual-track period (plan §8.1), so a
// different value is refused instead of guessed at.
const SchemaVersion = 2

const bundleID = "com.halunhaku.tingyu"

// TimeLayout is how the Flutter client stores DateTimes (drift's
// storeDateTimeAsText): UTC, microseconds, trailing Z. Writing any other
// shape makes the other client read the value as an invalid DateTime.
const TimeLayout = "2006-01-02T15:04:05.000000Z"

// ErrSchemaVersion reports a library whose user_version is not the one this
// client understands. It never repairs the database.
type ErrSchemaVersion struct {
	Path string
	Got  int
	Want int
}

func (e *ErrSchemaVersion) Error() string {
	return fmt.Sprintf("library: %s has user_version %d, want %d (not migrating)", e.Path, e.Got, e.Want)
}

// Track is one row of the tracks table. Only the columns M1 shows or needs
// are mapped; the rest stay in the database untouched.
type Track struct {
	ID           string
	SourceID     string
	Title        string
	Artist       string
	Album        string
	Duration     time.Duration
	TrackNumber  int
	DiscNumber   int
	Year         int
	Genre        string
	Bitrate      int
	SampleRate   int
	FileFormat   string
	FilePath     string
	FileSize     int64
	LastModified time.Time
	CoverArtPath string
	CoverArtURL  string
	Lyrics       string
	IsFavorite   bool
	DateAdded    time.Time
	PlayCount    int64
	LastPlayedAt time.Time
}

// Source is one row of music_sources.
type Source struct {
	ID              string
	Name            string
	Kind            string
	LocalFolderPath string
	SyncStatus      string
	LastSyncedAt    time.Time
	TrackCount      int64
}

// DataDir returns the directory holding library.sqlite: TINGYU_DATA_DIR
// when set, otherwise ~/Library/Application Support/com.halunhaku.tingyu.
// Development and acceptance runs must point TINGYU_DATA_DIR at a copy of
// the production library (plan §8.1 rule 2).
func DataDir() (string, error) {
	if dir := strings.TrimSpace(os.Getenv("TINGYU_DATA_DIR")); dir != "" {
		return expandHome(dir)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("library: home directory: %w", err)
	}
	return filepath.Join(home, "Library", "Application Support", bundleID), nil
}

// Path returns the library file inside dataDir.
func Path(dataDir string) string {
	return filepath.Join(dataDir, "library.sqlite")
}

// CoversDir returns the cover cache directory inside dataDir.
func CoversDir(dataDir string) string {
	return filepath.Join(dataDir, "covers")
}

func expandHome(path string) (string, error) {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("library: home directory: %w", err)
		}
		return filepath.Join(home, strings.TrimPrefix(path, "~")), nil
	}
	return path, nil
}

// Library is an open connection. A read-only Library accepts no write; the
// writable one is what the M1 app uses.
type Library struct {
	db     *sqlite.DB
	path   string
	writes bool

	mu     sync.Mutex
	rev    uint64
	rowRev map[string]uint64
}

// Open opens path read-only and checks its schema version. It never creates
// the file: a missing library is an error, not a new empty one.
func Open(ctx context.Context, path string) (*Library, error) {
	return open(ctx, path, false)
}

// OpenWritable opens path read-write, checks its schema version and brings a
// legacy schema up to date by adding missing tables, indexes and nullable
// columns. It never creates the file and never bumps user_version.
func OpenWritable(ctx context.Context, path string) (*Library, error) {
	return open(ctx, path, true)
}

func open(ctx context.Context, path string, writes bool) (*Library, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("library: open %s: %w", path, err)
	}
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{ReadOnly: !writes})
	if err != nil {
		return nil, fmt.Errorf("library: open %s: %w", path, err)
	}
	rows, err := db.Query(ctx, "PRAGMA user_version")
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("library: read user_version: %w", err)
	}
	version, ok := schemaVersion(rows)
	if !ok {
		db.Close()
		return nil, fmt.Errorf("library: %s returned no user_version", path)
	}
	if version != SchemaVersion {
		db.Close()
		return nil, &ErrSchemaVersion{Path: path, Got: version, Want: SchemaVersion}
	}
	if writes {
		if err := ensureSchema(ctx, db); err != nil {
			db.Close()
			return nil, err
		}
		// Foreign keys are what makes deleting a track clean up its playlist
		// entries (schema.dart relies on ON DELETE CASCADE).
		if _, err := db.Execute(ctx, "PRAGMA foreign_keys = ON"); err != nil {
			db.Close()
			return nil, fmt.Errorf("library: enable foreign keys: %w", err)
		}
	}
	return &Library{db: db, path: path, writes: writes, rowRev: map[string]uint64{}}, nil
}

func schemaVersion(rows sqlite.Rows) (int, bool) {
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, false
	}
	version, ok := rows.Values[0][0].(int64)
	return int(version), ok
}

// Path returns the file this connection reads.
func (l *Library) Path() string { return l.path }

// Writable reports whether this connection accepts writes.
func (l *Library) Writable() bool { return l.writes }

// Revision is a query key that changes whenever a write can change what the
// library shows — inserts, deletes, metadata updates, duration backfills.
// The Flutter client's old fingerprint only covered length/favourites/latest,
// so a title/artist/cover change never refreshed the list (audit §2.5). This
// counter cannot miss such a change: every write path bumps it.
func (l *Library) Revision() uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.rev
}

// RowRevision is the per-row revision for id: M1's table uses it in the row
// key, so a metadata-only change rebuilds that row and nothing else.
func (l *Library) RowRevision(id string) uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.rowRev[id]
}

func (l *Library) bump(ids ...string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rev++
	for _, id := range ids {
		l.rowRev[id]++
	}
}

// Tracks returns every track, ordered for display. Paging is M4's job; M1
// still shows the whole library (178 rows on the real one).
func (l *Library) Tracks(ctx context.Context) ([]Track, error) {
	const query = `
SELECT id, source_id, title, artist, album, duration,
       track_number, disc_number, year, genre, bitrate, sample_rate,
       file_format, file_path_or_url, file_size, last_modified,
       cover_art_path, cover_art_url, lyrics,
       is_favorite, date_added, play_count, last_played_at
FROM tracks
ORDER BY artist COLLATE NOCASE, album COLLATE NOCASE,
         disc_number, track_number, title COLLATE NOCASE, id`
	rows, err := l.db.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("library: query tracks: %w", err)
	}
	tracks := make([]Track, 0, len(rows.Values))
	for i, value := range rows.Values {
		track, err := trackFromRow(value)
		if err != nil {
			return nil, fmt.Errorf("library: track row %d: %w", i+1, err)
		}
		tracks = append(tracks, track)
	}
	return tracks, nil
}

// Track returns one track by id.
func (l *Library) Track(ctx context.Context, id string) (Track, bool, error) {
	const query = `
SELECT id, source_id, title, artist, album, duration,
       track_number, disc_number, year, genre, bitrate, sample_rate,
       file_format, file_path_or_url, file_size, last_modified,
       cover_art_path, cover_art_url, lyrics,
       is_favorite, date_added, play_count, last_played_at
FROM tracks WHERE id = ?`
	rows, err := l.db.Query(ctx, query, id)
	if err != nil {
		return Track{}, false, fmt.Errorf("library: query track %s: %w", id, err)
	}
	if len(rows.Values) == 0 {
		return Track{}, false, nil
	}
	track, err := trackFromRow(rows.Values[0])
	if err != nil {
		return Track{}, false, fmt.Errorf("library: track %s: %w", id, err)
	}
	return track, true, nil
}

func trackFromRow(value []any) (Track, error) {
	if len(value) != 23 {
		return Track{}, fmt.Errorf("got %d columns, want 23", len(value))
	}
	var track Track
	var ok bool
	if track.ID, ok = value[0].(string); !ok {
		return Track{}, errors.New("id is not text")
	}
	if track.SourceID, ok = value[1].(string); !ok {
		return Track{}, errors.New("source_id is not text")
	}
	if track.Title, ok = value[2].(string); !ok {
		return Track{}, errors.New("title is not text")
	}
	if track.Artist, ok = value[3].(string); !ok {
		return Track{}, errors.New("artist is not text")
	}
	if track.Album, ok = value[4].(string); !ok {
		return Track{}, errors.New("album is not text")
	}
	seconds, ok := value[5].(float64)
	if !ok {
		return Track{}, errors.New("duration is not a number")
	}
	track.Duration = secondsDuration(seconds)
	track.TrackNumber = intValue(value[6])
	track.DiscNumber = intValue(value[7])
	track.Year = intValue(value[8])
	track.Genre = stringValue(value[9])
	track.Bitrate = intValue(value[10])
	track.SampleRate = intValue(value[11])
	track.FileFormat, _ = value[12].(string)
	track.FilePath, _ = value[13].(string)
	track.FileSize = int64Value(value[14])
	track.LastModified, _ = timeValue(value[15])
	track.CoverArtPath = stringValue(value[16])
	track.CoverArtURL = stringValue(value[17])
	track.Lyrics = stringValue(value[18])
	track.IsFavorite = intValue(value[19]) != 0
	track.DateAdded, _ = timeValue(value[20])
	track.PlayCount = int64Value(value[21])
	track.LastPlayedAt, _ = timeValue(value[22])
	return track, nil
}

// Sources returns every music source, by name.
func (l *Library) Sources(ctx context.Context) ([]Source, error) {
	const query = `
SELECT id, name, kind, local_folder_path, sync_status, last_synced_at, track_count
FROM music_sources ORDER BY name COLLATE NOCASE, id`
	rows, err := l.db.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("library: query sources: %w", err)
	}
	out := make([]Source, 0, len(rows.Values))
	for _, value := range rows.Values {
		if len(value) != 7 {
			return nil, fmt.Errorf("library: source row has %d columns, want 7", len(value))
		}
		source := Source{
			ID:              stringValue(value[0]),
			Name:            stringValue(value[1]),
			Kind:            stringValue(value[2]),
			LocalFolderPath: stringValue(value[3]),
			SyncStatus:      stringValue(value[4]),
			TrackCount:      int64Value(value[6]),
		}
		source.LastSyncedAt, _ = timeValue(value[5])
		out = append(out, source)
	}
	return out, nil
}

// SourceByFolder finds the local source that already owns folder, so picking
// the same directory again reuses its source id and its tracks instead of
// creating a second source with duplicate rows.
func (l *Library) SourceByFolder(ctx context.Context, folder string) (Source, bool, error) {
	sources, err := l.Sources(ctx)
	if err != nil {
		return Source{}, false, err
	}
	for _, source := range sources {
		if source.Kind == "local" && sameFolder(source.LocalFolderPath, folder) {
			return source, true, nil
		}
	}
	return Source{}, false, nil
}

// sameFolder compares two absolute paths leniently: trailing slashes and
// "/private" prefixes are noise (NSOpenPanel returns either form).
func sameFolder(a, b string) bool {
	clean := func(p string) string {
		p = filepath.Clean(strings.TrimSpace(p))
		p = strings.TrimPrefix(p, "/private")
		return p
	}
	return a != "" && clean(a) == clean(b)
}

// UpsertLocalSource inserts a local source, or updates its name, folder and
// sync status when the id already exists.
func (l *Library) UpsertLocalSource(ctx context.Context, source Source) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	if source.LastSyncedAt.IsZero() {
		source.LastSyncedAt = time.Now()
	}
	_, err := l.db.Execute(ctx,
		`INSERT INTO music_sources
		   (id, name, kind, local_folder_path, sync_status, last_synced_at, track_count)
		 VALUES (?, ?, 'local', ?, ?, ?, ?)
		 ON CONFLICT(id) DO UPDATE SET
		   name = excluded.name,
		   kind = 'local',
		   local_folder_path = excluded.local_folder_path,
		   sync_status = excluded.sync_status,
		   last_synced_at = excluded.last_synced_at,
		   track_count = excluded.track_count`,
		source.ID, source.Name, source.LocalFolderPath, source.SyncStatus,
		formatTime(source.LastSyncedAt), source.TrackCount)
	if err != nil {
		return fmt.Errorf("library: upsert source %s: %w", source.ID, err)
	}
	l.bump()
	return nil
}

// UpdateSourceSync records the outcome of a scan on its source.
func (l *Library) UpdateSourceSync(ctx context.Context, id, status string, syncedAt time.Time, trackCount int64) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	_, err := l.db.Execute(ctx,
		`UPDATE music_sources SET sync_status = ?, last_synced_at = ?, track_count = ? WHERE id = ?`,
		status, formatTime(syncedAt), trackCount, id)
	if err != nil {
		return fmt.Errorf("library: update source %s: %w", id, err)
	}
	l.bump()
	return nil
}

// CountSourceTracks is the real row count for a source, the number the scan
// acceptance compares with the number of files on disk.
func (l *Library) CountSourceTracks(ctx context.Context, sourceID string) (int64, error) {
	rows, err := l.db.Query(ctx, `SELECT COUNT(*) FROM tracks WHERE source_id = ?`, sourceID)
	if err != nil {
		return 0, fmt.Errorf("library: count source %s: %w", sourceID, err)
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, errors.New("library: COUNT(*) returned no row")
	}
	return int64Value(rows.Values[0][0]), nil
}

// Close closes the connection. It is safe to call twice.
func (l *Library) Close() error { return l.db.Close() }

// formatTime writes the drift-compatible text timestamp.
func formatTime(t time.Time) string { return t.UTC().Format(TimeLayout) }

func secondsDuration(seconds float64) time.Duration {
	return time.Duration(seconds * float64(time.Second))
}

func stringValue(v any) string {
	s, _ := v.(string)
	return s
}

func intValue(v any) int {
	return int(int64Value(v))
}

func int64Value(v any) int64 {
	switch n := v.(type) {
	case int64:
		return n
	case int:
		return int64(n)
	case float64:
		return int64(n)
	}
	return 0
}

func timeValue(v any) (time.Time, bool) {
	text, ok := v.(string)
	if !ok || text == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{TimeLayout, "2006-01-02T15:04:05.000Z", time.RFC3339Nano, time.RFC3339} {
		if t, err := time.Parse(layout, text); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
