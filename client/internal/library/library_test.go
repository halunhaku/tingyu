package library

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

const fixtureSchema = `
CREATE TABLE tracks (
	id TEXT NOT NULL PRIMARY KEY,
	source_id TEXT NOT NULL,
	title TEXT NOT NULL,
	artist TEXT NOT NULL DEFAULT '未知艺术家',
	album TEXT NOT NULL DEFAULT '未知专辑',
	duration REAL NOT NULL DEFAULT 0.0,
	track_number INTEGER NULL,
	disc_number INTEGER NULL
)`

type fixtureTrack struct {
	id, title, artist, album string
	duration                 float64
	track, disc              int
}

// newFixture writes a throwaway library shaped like the real one and
// returns its path. The test owns the file, so the read-only rule for the
// production library is not bent here.
func newFixture(t *testing.T, version int, tracks []fixtureTrack) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	db, err := sqlite.Open(context.Background(), path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	defer db.Close()
	if _, err := db.Execute(context.Background(), fixtureSchema); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	for _, track := range tracks {
		if _, err := db.Execute(context.Background(),
			`INSERT INTO tracks (id, source_id, title, artist, album, duration, track_number, disc_number)
			 VALUES (?, 'src', ?, ?, ?, ?, ?, ?)`,
			track.id, track.title, track.artist, track.album, track.duration, track.track, track.disc); err != nil {
			t.Fatalf("insert %s: %v", track.id, err)
		}
	}
	if _, err := db.Execute(context.Background(), "PRAGMA user_version = "+strconv.Itoa(version)); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	return path
}

func TestOpenRejectsOtherSchemaVersion(t *testing.T) {
	path := newFixture(t, 1, nil)
	_, err := Open(context.Background(), path)
	var mismatch *ErrSchemaVersion
	if !errors.As(err, &mismatch) {
		t.Fatalf("Open error = %v, want ErrSchemaVersion", err)
	}
	if mismatch.Got != 1 || mismatch.Want != SchemaVersion {
		t.Errorf("mismatch = %+v, want got 1 want %d", mismatch, SchemaVersion)
	}
}

func TestOpenMissingFileDoesNotCreateIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.sqlite")
	if _, err := Open(context.Background(), path); err == nil {
		t.Fatal("Open succeeded on a missing library")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Open left %s: stat error = %v, want ErrNotExist", path, err)
	}
}

func TestWriteIsRejectedByTheReadOnlyConnection(t *testing.T) {
	path := newFixture(t, SchemaVersion, []fixtureTrack{{id: "a", title: "A", artist: "X", album: "Y", duration: 10}})
	lib, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer lib.Close()

	var sqliteErr *sqlite.Error
	if _, err := lib.db.Execute(context.Background(), "CREATE TABLE forbidden (a TEXT)"); !errors.As(err, &sqliteErr) {
		t.Fatalf("CREATE error = %v, want *sqlite.Error", err)
	}
	const sqliteReadOnly = 8
	if sqliteErr.Code != sqliteReadOnly {
		t.Fatalf("CREATE error code = %d (%s), want %d", sqliteErr.Code, sqliteErr.Message, sqliteReadOnly)
	}
}

func TestTracksOrdersForDisplay(t *testing.T) {
	path := newFixture(t, SchemaVersion, []fixtureTrack{
		{id: "3", title: "B", artist: "周杰伦", album: "太阳之子", duration: 229, track: 2, disc: 1},
		{id: "1", title: "A", artist: "Adele", album: "25", duration: 285.5, track: 1, disc: 1},
		{id: "2", title: "A", artist: "周杰伦", album: "太阳之子", duration: 238, track: 1, disc: 1},
	})
	lib, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer lib.Close()

	tracks, err := lib.Tracks(context.Background())
	if err != nil {
		t.Fatalf("Tracks: %v", err)
	}
	want := []string{"1", "2", "3"}
	if len(tracks) != len(want) {
		t.Fatalf("got %d tracks, want %d", len(tracks), len(want))
	}
	for i, id := range want {
		if tracks[i].ID != id {
			t.Errorf("track %d = %s, want %s", i, tracks[i].ID, id)
		}
	}
	if tracks[0].Title != "A" || tracks[0].Artist != "Adele" || tracks[0].Album != "25" {
		t.Errorf("track 0 = %+v", tracks[0])
	}
	if tracks[0].Duration != 285*time.Second+500*time.Millisecond {
		t.Errorf("duration = %v, want 4m45.5s", tracks[0].Duration)
	}
}

func TestDataDirHonoursEnvironment(t *testing.T) {
	t.Setenv("TINGYU_DATA_DIR", "/tmp/tingyu-copy")
	dir, err := DataDir()
	if err != nil {
		t.Fatal(err)
	}
	if dir != "/tmp/tingyu-copy" {
		t.Errorf("DataDir = %q, want /tmp/tingyu-copy", dir)
	}
	if got := Path(dir); got != "/tmp/tingyu-copy/library.sqlite" {
		t.Errorf("Path = %q", got)
	}
}
