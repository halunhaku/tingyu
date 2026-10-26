package library

// The schema below mirrors app/lib/data/db/schema.dart column for column, so
// the two clients can keep sharing one library.sqlite during the dual-track
// period (plan §2.1 #1, §3.3). Migration is by "补差": read sqlite_master and
// PRAGMA table_info, create what is missing, add nullable columns only, and
// never touch PRAGMA user_version — it stays 2 (plan §8.1 rule 3). A database
// built by the old Swift client or by a half-migrated Flutter build therefore
// opens without a version bump, which is what makes the fallback possible.

import (
	"context"
	"fmt"
	"strings"

	"github.com/egoist/mygo/plugins/sqlite"
)

// createStatements are the tables in their current production shape. Each is
// IF NOT EXISTS, so running them against the real library is a no-op.
var createStatements = []string{
	`CREATE TABLE IF NOT EXISTS "tracks" (
		"id" TEXT NOT NULL,
		"source_id" TEXT NOT NULL,
		"title" TEXT NOT NULL,
		"artist" TEXT NOT NULL DEFAULT '未知艺术家',
		"album" TEXT NOT NULL DEFAULT '未知专辑',
		"duration" REAL NOT NULL DEFAULT 0.0,
		"track_number" INTEGER NULL,
		"disc_number" INTEGER NULL,
		"year" INTEGER NULL,
		"genre" TEXT NULL,
		"bitrate" INTEGER NULL,
		"sample_rate" INTEGER NULL,
		"file_format" TEXT NOT NULL DEFAULT 'mp3',
		"file_path_or_url" TEXT NOT NULL,
		"file_size" INTEGER NOT NULL DEFAULT 0,
		"etag" TEXT NULL,
		"last_modified" TEXT NULL,
		"cover_art_path" TEXT NULL,
		"cover_art_url" TEXT NULL,
		"lyrics" TEXT NULL,
		"is_favorite" INTEGER NOT NULL DEFAULT 0 CHECK ("is_favorite" IN (0, 1)),
		"date_added" TEXT NOT NULL,
		"play_count" INTEGER NOT NULL DEFAULT 0,
		"last_played_at" TEXT NULL,
		PRIMARY KEY ("id")
	)`,
	`CREATE TABLE IF NOT EXISTS "music_sources" (
		"id" TEXT NOT NULL,
		"name" TEXT NOT NULL,
		"kind" TEXT NOT NULL,
		"local_folder_path" TEXT NULL,
		"local_bookmark" TEXT NULL,
		"webdav_url" TEXT NULL,
		"webdav_username" TEXT NULL,
		"webdav_root_path" TEXT NULL,
		"quark_folder_fid" TEXT NULL,
		"quark_account_name" TEXT NULL,
		"sync_status" TEXT NOT NULL DEFAULT '未同步',
		"last_synced_at" TEXT NULL,
		"track_count" INTEGER NOT NULL DEFAULT 0,
		PRIMARY KEY ("id")
	)`,
	`CREATE TABLE IF NOT EXISTS "playlists" (
		"id" TEXT NOT NULL,
		"name" TEXT NOT NULL,
		"created_at" TEXT NOT NULL,
		PRIMARY KEY ("id")
	)`,
	`CREATE TABLE IF NOT EXISTS "playlist_items" (
		"playlist_id" TEXT NOT NULL REFERENCES playlists (id) ON DELETE CASCADE,
		"track_id" TEXT NOT NULL REFERENCES tracks (id) ON DELETE CASCADE,
		"position" INTEGER NOT NULL,
		PRIMARY KEY ("playlist_id", "position")
	)`,
}

// indexDef is one business index of the production library (six on tracks,
// one on music_sources, one on playlist_items). The last one is not an
// optimisation to skip: without it ON DELETE CASCADE scans the whole
// playlist_items table for every deleted track.
type indexDef struct {
	name    string
	table   string
	columns []string
	sql     string
}

var indexDefs = []indexDef{
	{"idx_tracks_source", "tracks", []string{"source_id"}, `CREATE INDEX IF NOT EXISTS idx_tracks_source ON tracks (source_id)`},
	{"idx_tracks_artist", "tracks", []string{"artist"}, `CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks (artist)`},
	{"idx_tracks_album", "tracks", []string{"album"}, `CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks (album)`},
	{"idx_tracks_artist_album", "tracks", []string{"artist", "album"}, `CREATE INDEX IF NOT EXISTS idx_tracks_artist_album ON tracks (artist, album)`},
	{"idx_tracks_date_added", "tracks", []string{"date_added"}, `CREATE INDEX IF NOT EXISTS idx_tracks_date_added ON tracks (date_added)`},
	{"idx_tracks_favorite", "tracks", []string{"is_favorite"}, `CREATE INDEX IF NOT EXISTS idx_tracks_favorite ON tracks (is_favorite)`},
	{"idx_sources_kind", "music_sources", []string{"kind"}, `CREATE INDEX IF NOT EXISTS idx_sources_kind ON music_sources (kind)`},
	{"idx_playlist_items_track", "playlist_items", []string{"track_id"}, `CREATE INDEX IF NOT EXISTS idx_playlist_items_track ON playlist_items (track_id)`},

	// Sort indexes, added by this client for SQL paging (plan §2.5). The
	// production set above indexes the filters; a page also needs its ORDER BY
	// served, or every page request sorts the whole table (10,000 rows measured
	// at ~10 ms for the last page, close to a frame). Each index below is
	// exactly one sort's ORDER BY, collation and direction included, so
	// "LIMIT 40 OFFSET n" walks the index instead of scanning and sorting.
	//
	// Indexes are additive: PRAGMA user_version stays 2 and the Flutter client
	// (which creates its own six) never reads a schema it does not know. Only
	// columns are frozen (plan §8.1 rule 3), and no column changes here.
	{"idx_tracks_sort_title", "tracks", []string{"title"},
		`CREATE INDEX IF NOT EXISTS idx_tracks_sort_title ON tracks (title COLLATE NOCASE, artist COLLATE NOCASE, id)`},
	{"idx_tracks_sort_artist", "tracks", []string{"artist", "album"},
		`CREATE INDEX IF NOT EXISTS idx_tracks_sort_artist ON tracks (artist COLLATE NOCASE, album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE, id)`},
	{"idx_tracks_sort_album", "tracks", []string{"album", "artist"},
		`CREATE INDEX IF NOT EXISTS idx_tracks_sort_album ON tracks (album COLLATE NOCASE, artist COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE, id)`},
	{"idx_tracks_sort_duration", "tracks", []string{"duration"},
		`CREATE INDEX IF NOT EXISTS idx_tracks_sort_duration ON tracks (duration, id)`},
	{"idx_tracks_sort_added", "tracks", []string{"date_added"},
		`CREATE INDEX IF NOT EXISTS idx_tracks_sort_added ON tracks (date_added, id)`},
}

// nullableColumns are the columns a legacy library may miss. Only nullable
// columns are added: an existing NOT NULL column cannot be backfilled without
// a data decision, and PRAGMA user_version must not move (plan §8.1 rule 3).
var nullableColumns = []struct{ table, column, kind string }{
	{"tracks", "track_number", "INTEGER"},
	{"tracks", "disc_number", "INTEGER"},
	{"tracks", "year", "INTEGER"},
	{"tracks", "genre", "TEXT"},
	{"tracks", "bitrate", "INTEGER"},
	{"tracks", "sample_rate", "INTEGER"},
	{"tracks", "etag", "TEXT"},
	{"tracks", "last_modified", "TEXT"},
	{"tracks", "cover_art_path", "TEXT"},
	{"tracks", "cover_art_url", "TEXT"},
	{"tracks", "lyrics", "TEXT"},
	{"tracks", "last_played_at", "TEXT"},
	{"music_sources", "local_folder_path", "TEXT"},
	{"music_sources", "local_bookmark", "TEXT"},
	{"music_sources", "webdav_url", "TEXT"},
	{"music_sources", "webdav_username", "TEXT"},
	{"music_sources", "webdav_root_path", "TEXT"},
	{"music_sources", "quark_folder_fid", "TEXT"},
	{"music_sources", "quark_account_name", "TEXT"},
	{"music_sources", "last_synced_at", "TEXT"},
}

// placeholderUpdates replace the empty string with the placeholder the UI
// shows and the Flutter client writes. An album or artist aggregate groups by
// the raw columns (a CASE in GROUP BY cannot use idx_tracks_artist_album), so a
// legacy row storing ” would otherwise form a second group with the same
// displayed name. It only touches rows that have no text at all, and running it
// again changes nothing.
var placeholderUpdates = []struct{ table, column, value string }{
	{"tracks", "artist", UnknownArtist},
	{"tracks", "album", UnknownAlbum},
}

// ensureSchema creates missing tables and indexes and adds nullable columns.
// It runs inside one transaction so a half-applied schema never survives a
// failure, and it never writes PRAGMA user_version.
func ensureSchema(ctx context.Context, db *sqlite.DB) error {
	statements := make([]sqlite.Statement, 0, len(createStatements))
	for _, sql := range createStatements {
		statements = append(statements, sqlite.Statement{SQL: sql})
	}
	if _, err := db.Transaction(ctx, statements); err != nil {
		return fmt.Errorf("library: create schema: %w", err)
	}
	for _, add := range nullableColumns {
		has, err := hasColumn(ctx, db, add.table, add.column)
		if err != nil {
			return err
		}
		if has {
			continue
		}
		// The identifiers are package constants, never user input.
		sql := fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s %s NULL", quoteIdent(add.table), quoteIdent(add.column), add.kind)
		if _, err := db.Execute(ctx, sql); err != nil {
			return fmt.Errorf("library: add %s.%s: %w", add.table, add.column, err)
		}
	}
	// Legacy empty metadata takes the placeholder, so the aggregates group it
	// with the rows that already store the placeholder.
	for _, update := range placeholderUpdates {
		has, err := hasColumn(ctx, db, update.table, update.column)
		if err != nil {
			return err
		}
		if !has {
			continue
		}
		sql := fmt.Sprintf("UPDATE %s SET %s = ? WHERE TRIM(%s) = ''",
			quoteIdent(update.table), quoteIdent(update.column), quoteIdent(update.column))
		if _, err := db.Execute(ctx, sql, update.value); err != nil {
			return fmt.Errorf("library: normalise %s.%s: %w", update.table, update.column, err)
		}
	}
	// Indexes last, and only over columns that exist: a legacy table without
	// a NOT NULL column (is_favorite on a very old Swift build) cannot have
	// it added here — only nullable columns are added (plan §8.1 rule 3) — so
	// its index is skipped instead of failing the whole open.
	for _, index := range indexDefs {
		ok := true
		for _, column := range index.columns {
			has, err := hasColumn(ctx, db, index.table, column)
			if err != nil {
				return err
			}
			if !has {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		if _, err := db.Execute(ctx, index.sql); err != nil {
			return fmt.Errorf("library: create index %s: %w", index.name, err)
		}
	}
	return nil
}

func hasColumn(ctx context.Context, db *sqlite.DB, table, column string) (bool, error) {
	rows, err := db.Query(ctx, "PRAGMA table_info("+quoteIdent(table)+")")
	if err != nil {
		return false, fmt.Errorf("library: table_info %s: %w", table, err)
	}
	name := columnIndex(rows.Columns, "name")
	if name < 0 {
		return false, fmt.Errorf("library: table_info %s has no name column", table)
	}
	for _, row := range rows.Values {
		if value, ok := row[name].(string); ok && value == column {
			return true, nil
		}
	}
	return false, nil
}

func columnIndex(columns []string, want string) int {
	for i, name := range columns {
		if strings.EqualFold(name, want) {
			return i
		}
	}
	return -1
}

func quoteIdent(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}
