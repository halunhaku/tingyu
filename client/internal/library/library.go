// Package library reads Tingyu's SQLite library.
//
// M0 is read-only on purpose. This package has no write path: the only
// statements it issues are PRAGMA user_version and SELECT. The connection
// is opened with sqlite.OpenOptions{ReadOnly: true}, which the MyGo SQLite
// plugin turns into SQLITE_OPEN_READONLY (flags 0x1). Opening or migrating
// the database is M1's job (plan §3.3, §8.1).
package library

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// SchemaVersion is the PRAGMA user_version this client understands. The
// migration plan freezes it at 2 for the dual-track period (plan §8.1), so
// a different value is refused instead of guessed at.
const SchemaVersion = 2

const bundleID = "com.halunhaku.tingyu"

// ErrSchemaVersion reports a library whose user_version is not the one
// this client reads. It never repairs the database.
type ErrSchemaVersion struct {
	Path string
	Got  int
	Want int
}

func (e *ErrSchemaVersion) Error() string {
	return fmt.Sprintf("library: %s has user_version %d, want %d (read-only: not migrating)", e.Path, e.Got, e.Want)
}

// Track is one row of the tracks table, in the columns the M0 table shows.
type Track struct {
	ID       string
	Title    string
	Artist   string
	Album    string
	Duration time.Duration
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

// Library is an open, read-only connection.
type Library struct {
	db   *sqlite.DB
	path string
}

// Open opens path read-only and checks its schema version. It never
// creates the file: a missing library is an error, not a new empty one.
func Open(ctx context.Context, path string) (*Library, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, fmt.Errorf("library: open %s: %w", path, err)
	}
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{ReadOnly: true})
	if err != nil {
		return nil, fmt.Errorf("library: open %s read-only: %w", path, err)
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
	return &Library{db: db, path: path}, nil
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

// Tracks returns every track, ordered for display. The M0 table shows all
// of them; paging (40 per page) is M4's job.
func (l *Library) Tracks(ctx context.Context) ([]Track, error) {
	const query = `
SELECT id, title, artist, album, duration
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

func trackFromRow(value []any) (Track, error) {
	if len(value) != 5 {
		return Track{}, fmt.Errorf("got %d columns, want 5", len(value))
	}
	var track Track
	var ok bool
	if track.ID, ok = value[0].(string); !ok {
		return Track{}, errors.New("id is not text")
	}
	if track.Title, ok = value[1].(string); !ok {
		return Track{}, errors.New("title is not text")
	}
	if track.Artist, ok = value[2].(string); !ok {
		return Track{}, errors.New("artist is not text")
	}
	if track.Album, ok = value[3].(string); !ok {
		return Track{}, errors.New("album is not text")
	}
	seconds, ok := value[4].(float64)
	if !ok {
		return Track{}, errors.New("duration is not a number")
	}
	track.Duration = time.Duration(seconds * float64(time.Second))
	return track, nil
}

// Close closes the read-only connection. It is safe to call twice.
func (l *Library) Close() error { return l.db.Close() }
