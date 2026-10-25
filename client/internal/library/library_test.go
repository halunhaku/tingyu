package library

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

type fixtureTrack struct {
	id, title, artist, album string
	duration                 float64
	track, disc              int
}

// newFixture writes a throwaway library shaped like the real one (full
// schema, indexes and all) and returns its path. The test owns the file, so
// the read-only rule for the production library is not bent here.
func newFixture(t *testing.T, version int, tracks []fixtureTrack) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	db, err := sqlite.Open(context.Background(), path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	defer db.Close()
	if err := ensureSchema(context.Background(), db); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	for _, track := range tracks {
		if _, err := db.Execute(context.Background(),
			`INSERT INTO tracks (id, source_id, title, artist, album, duration,
			   track_number, disc_number, file_path_or_url, date_added)
			 VALUES (?, 'src', ?, ?, ?, ?, ?, ?, ?, ?)`,
			track.id, track.title, track.artist, track.album, track.duration,
			nullableInt(track.track), nullableInt(track.disc), track.id, formatTime(time.Now())); err != nil {
			t.Fatalf("insert %s: %v", track.id, err)
		}
	}
	if _, err := db.Execute(context.Background(), "PRAGMA user_version = "+strconv.Itoa(version)); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	return path
}

func openWritable(t *testing.T, path string) *Library {
	t.Helper()
	lib, err := OpenWritable(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenWritable: %v", err)
	}
	t.Cleanup(func() { lib.Close() })
	return lib
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

func TestOpenWritableAddsMissingSchemaWithoutBumpingVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	db, err := sqlite.Open(context.Background(), path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatal(err)
	}
	// A half-migrated build: the NOT NULL core is there, the nullable columns
	// and the other tables are not. Only nullable columns may be added
	// (plan §8.1 rule 3), which is exactly what this exercises.
	if _, err := db.Execute(context.Background(), `CREATE TABLE tracks (
		id TEXT NOT NULL PRIMARY KEY, source_id TEXT NOT NULL, title TEXT NOT NULL,
		artist TEXT NOT NULL DEFAULT '未知艺术家', album TEXT NOT NULL DEFAULT '未知专辑',
		duration REAL NOT NULL DEFAULT 0.0, file_path_or_url TEXT NOT NULL,
		file_format TEXT NOT NULL DEFAULT 'mp3', file_size INTEGER NOT NULL DEFAULT 0,
		is_favorite INTEGER NOT NULL DEFAULT 0, date_added TEXT NOT NULL,
		play_count INTEGER NOT NULL DEFAULT 0)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Execute(context.Background(), "PRAGMA user_version = 2"); err != nil {
		t.Fatal(err)
	}
	db.Close()

	lib := openWritable(t, path)
	if _, err := lib.Tracks(context.Background()); err != nil {
		t.Fatalf("Tracks on a supplemented schema: %v", err)
	}
	rows, err := lib.db.Query(context.Background(), "PRAGMA user_version")
	if err != nil {
		t.Fatal(err)
	}
	if got := schemaVersionValue(t, rows); got != SchemaVersion {
		t.Errorf("user_version = %d, want %d", got, SchemaVersion)
	}
	if got := len(mustSources(t, lib)); got != 0 {
		t.Errorf("sources = %d, want 0", got)
	}
	for _, column := range []string{"last_played_at", "cover_art_path", "track_number"} {
		if _, err := lib.db.Query(context.Background(), "SELECT "+column+" FROM tracks LIMIT 1"); err != nil {
			t.Errorf("%s was not added: %v", column, err)
		}
	}
}

func TestMergeScanKeepsUserAssetsAndIdempotentIDs(t *testing.T) {
	lib := openWritable(t, newFixture(t, SchemaVersion, nil))
	ctx := context.Background()
	folder := "/tmp/听屿 测试 音乐"
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: folder, SyncStatus: "未同步"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}

	path := folder + "/一 首歌.flac"
	modified := time.Unix(1_700_000_000, 0).UTC()
	first := ScannedTrack{
		FilePathOrURL: path, Title: "一 首歌", Artist: "歌手", Album: "专辑",
		Duration: 3 * time.Minute, FileFormat: "flac", FileSize: 1000,
		LastModified: modified, CoverArtPath: "abc.png",
	}
	result, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{first}, true)
	if err != nil {
		t.Fatal(err)
	}
	if result != (MergeResult{Added: 1}) {
		t.Fatalf("first merge = %+v, want added 1", result)
	}
	tracks := mustTracks(t, lib)
	if len(tracks) != 1 || tracks[0].ID != TrackID(source.ID, path) {
		t.Fatalf("tracks = %+v", tracks)
	}
	if tracks[0].Title != "一 首歌" || tracks[0].Duration != 3*time.Minute || !tracks[0].LastModified.Equal(modified) {
		t.Fatalf("track = %+v", tracks[0])
	}

	// Make the row a user asset: favourite, lyrics, play count, a cover.
	if _, err := lib.db.Execute(ctx,
		`UPDATE tracks SET is_favorite = 1, lyrics = 'lrc', play_count = 7, cover_art_path = 'user.png' WHERE id = ?`,
		tracks[0].ID); err != nil {
		t.Fatal(err)
	}

	// The same scan again changes nothing: size and mtime are unchanged.
	again, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{first}, true)
	if err != nil {
		t.Fatal(err)
	}
	if again != (MergeResult{}) {
		t.Fatalf("second merge = %+v, want no change", again)
	}

	// A rescanned file with a new size and no metadata: file facts update,
	// user assets survive, placeholders are not overwritten by the sparse
	// result (the scanner sends an empty title for unchanged files only when
	// it skipped parsing; here it sends a real one).
	second := first
	second.FileSize = 2000
	second.Title = "新标题"
	second.CoverArtPath = "new.png"
	result, err = lib.MergeScan(ctx, source.ID, []ScannedTrack{second}, true)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 1 {
		t.Fatalf("third merge = %+v, want updated 1", result)
	}
	track := mustTracks(t, lib)[0]
	if track.FileSize != 2000 || track.Duration != 3*time.Minute {
		t.Errorf("file facts not updated: %+v", track)
	}
	if track.Title != "一 首歌" {
		t.Errorf("title = %q, want the existing metadata kept", track.Title)
	}
	if !track.IsFavorite || track.Lyrics != "lrc" || track.PlayCount != 7 || track.CoverArtPath != "user.png" {
		t.Errorf("user assets were overwritten: %+v", track)
	}

	// An authoritative scan that no longer lists the file removes it.
	result, err = lib.MergeScan(ctx, source.ID, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if result.Removed != 1 {
		t.Fatalf("authoritative empty merge = %+v, want removed 1", result)
	}
	if got := mustTracks(t, lib); len(got) != 0 {
		t.Fatalf("tracks after removal = %+v", got)
	}
}

func TestNonAuthoritativeMergeKeepsMissingTracks(t *testing.T) {
	lib := openWritable(t, newFixture(t, SchemaVersion, nil))
	ctx := context.Background()
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: "/tmp/x"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	keep := ScannedTrack{FilePathOrURL: "/tmp/x/a.mp3", Title: "A", FileFormat: "mp3", FileSize: 1}
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{keep}, true); err != nil {
		t.Fatal(err)
	}
	// A cancelled/truncated scan only reports what it saw; the rest stays.
	if _, err := lib.MergeScan(ctx, source.ID, nil, false); err != nil {
		t.Fatal(err)
	}
	if got := len(mustTracks(t, lib)); got != 1 {
		t.Fatalf("tracks = %d, want 1 (a partial scan must not delete)", got)
	}
}

func TestMergeFillsPlaceholdersWithRealMetadata(t *testing.T) {
	lib := openWritable(t, newFixture(t, SchemaVersion, nil))
	ctx := context.Background()
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: "/tmp/x"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	path := "/tmp/x/a.flac"
	first := ScannedTrack{FilePathOrURL: path, Title: "a", Artist: UnknownArtist, Album: UnknownAlbum, FileFormat: "flac"}
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{first}, true); err != nil {
		t.Fatal(err)
	}
	second := first
	second.Artist = "真歌手"
	second.Album = "真专辑"
	second.CoverArtPath = "cover.jpg"
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{second}, true); err != nil {
		t.Fatal(err)
	}
	track := mustTracks(t, lib)[0]
	if track.Artist != "真歌手" || track.Album != "真专辑" || track.CoverArtPath != "cover.jpg" {
		t.Fatalf("placeholders not filled: %+v", track)
	}
}

func TestRevisionChangesForMetadataOnlyWrites(t *testing.T) {
	lib := openWritable(t, newFixture(t, SchemaVersion, nil))
	ctx := context.Background()
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: "/tmp/x"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	incoming := ScannedTrack{FilePathOrURL: "/tmp/x/a.flac", Title: "A", FileFormat: "flac", Duration: 0}
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{incoming}, true); err != nil {
		t.Fatal(err)
	}
	id := TrackID(source.ID, incoming.FilePathOrURL)
	if lib.Revision() == 0 || lib.RowRevision(id) == 0 {
		t.Fatalf("revision = %d, row = %d, want both bumped by the insert", lib.Revision(), lib.RowRevision(id))
	}
	before := lib.Revision()
	rowBefore := lib.RowRevision(id)

	// The only change is metadata (duration), which the old length/favourite/
	// latest fingerprint missed entirely.
	changed, err := lib.BackfillDuration(ctx, id, 4*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("duration backfill did not change the row")
	}
	if lib.Revision() <= before || lib.RowRevision(id) <= rowBefore {
		t.Fatalf("revision = %d (was %d), row = %d (was %d): a metadata-only write must bump both",
			lib.Revision(), before, lib.RowRevision(id), rowBefore)
	}
	if got := mustTracks(t, lib)[0].Duration; got != 4*time.Minute {
		t.Errorf("duration = %v, want 4m", got)
	}
}

func TestRecordPlayPersistsAfterReopen(t *testing.T) {
	path := newFixture(t, SchemaVersion, nil)
	lib := openWritable(t, path)
	ctx := context.Background()
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: "/tmp/x"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	incoming := ScannedTrack{FilePathOrURL: "/tmp/x/a.flac", Title: "A", FileFormat: "flac"}
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{incoming}, true); err != nil {
		t.Fatal(err)
	}
	id := TrackID(source.ID, incoming.FilePathOrURL)
	for want := int64(1); want <= 2; want++ {
		got, err := lib.RecordPlay(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("play count = %d, want %d", got, want)
		}
	}
	lib.Close()

	reopened := openWritable(t, path)
	track := mustTracks(t, reopened)[0]
	if track.PlayCount != 2 {
		t.Errorf("play count after reopen = %d, want 2", track.PlayCount)
	}
	if track.LastPlayedAt.IsZero() {
		t.Error("last_played_at was not written")
	}
}

func TestFileFactsAndSourceReuse(t *testing.T) {
	lib := openWritable(t, newFixture(t, SchemaVersion, nil))
	ctx := context.Background()
	source := Source{ID: "src-1", Name: "测试", Kind: "local", LocalFolderPath: "/tmp/音乐 目录"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	modified := time.Unix(1_700_000_000, 123_000_000).UTC()
	incoming := ScannedTrack{FilePathOrURL: "/tmp/音乐 目录/a.flac", Title: "A", FileFormat: "flac", FileSize: 42, LastModified: modified}
	if _, err := lib.MergeScan(ctx, source.ID, []ScannedTrack{incoming}, true); err != nil {
		t.Fatal(err)
	}
	facts, err := lib.FileFacts(ctx, source.ID)
	if err != nil {
		t.Fatal(err)
	}
	fact, ok := facts[incoming.FilePathOrURL]
	if !ok {
		t.Fatalf("facts = %+v", facts)
	}
	if fact.Size != 42 || fact.Modified.UnixMicro() != modified.Truncate(time.Microsecond).UnixMicro() {
		t.Errorf("fact = %+v", fact)
	}

	// A trailing slash and the /private prefix are noise from NSOpenPanel.
	found, ok, err := lib.SourceByFolder(ctx, "/private/tmp/音乐 目录/")
	if err != nil {
		t.Fatal(err)
	}
	if !ok || found.ID != source.ID {
		t.Fatalf("SourceByFolder = %+v, %v", found, ok)
	}

	// Re-upserting the same id (re-scan of the same folder) keeps one row.
	source.Name = "改名"
	source.SyncStatus = "已同步（新增 1 / 更新 0 / 移除 0）"
	source.TrackCount = 1
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatal(err)
	}
	sources := mustSources(t, lib)
	if len(sources) != 1 || sources[0].Name != "改名" || sources[0].TrackCount != 1 {
		t.Fatalf("sources = %+v", sources)
	}
}

func TestTrackIDUsesSourceAndPath(t *testing.T) {
	if got := TrackID("src-1", "/a/b/中文 名字.flac"); got != "src-1::/a/b/中文 名字.flac" {
		t.Fatalf("TrackID = %q", got)
	}
	if !strings.Contains(TrackID("src-1", "/a"), "::/a") {
		t.Fatal("TrackID must keep the absolute path verbatim")
	}
}

func mustTracks(t *testing.T, lib *Library) []Track {
	t.Helper()
	tracks, err := lib.Tracks(context.Background())
	if err != nil {
		t.Fatalf("Tracks: %v", err)
	}
	return tracks
}

func mustSources(t *testing.T, lib *Library) []Source {
	t.Helper()
	sources, err := lib.Sources(context.Background())
	if err != nil {
		t.Fatalf("Sources: %v", err)
	}
	return sources
}

func schemaVersionValue(t *testing.T, rows sqlite.Rows) int {
	t.Helper()
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		t.Fatalf("PRAGMA user_version returned %+v", rows)
	}
	value, ok := rows.Values[0][0].(int64)
	if !ok {
		t.Fatalf("user_version value = %T", rows.Values[0][0])
	}
	return int(value)
}
