package library

// Deleting a music source. plan §2.1 #2: a source owns exactly the tracks
// whose source_id is its id, so removing it removes those tracks and nothing
// else; playlist_items rows go with the tracks through the foreign key, and
// the cover files those tracks referenced are collected afterwards only if no
// remaining track uses them (plan §2.1 #4: content-addressed covers are shared
// across tracks and sources, so deleting files per track would strip another
// album's artwork).
//
// Credentials are not part of this: a local source has none, and the WebDAV /
// Quark secrets live in the system Keychain under the source layer, so the
// caller (internal/app) drops them together with the source; keeping that out
// of the library keeps it free of keychain access.

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/egoist/mygo/plugins/sqlite"
)

// SourceDeletion is what deleting a source removed.
type SourceDeletion struct {
	Source        string
	Tracks        int
	PlaylistItems int
	Covers        []string // cover file names that may now be orphans
}

// DeleteSource removes a source and its tracks in one transaction and reports
// what went. The caller decides whether the reported covers are unreferenced
// yet (a cover can be shared with another source's tracks).
func (l *Library) DeleteSource(ctx context.Context, sourceID string) (SourceDeletion, error) {
	if !l.writes {
		return SourceDeletion{}, errors.New("library: connection is read-only")
	}
	if strings.TrimSpace(sourceID) == "" {
		return SourceDeletion{}, errors.New("library: delete source needs an id")
	}
	rows, err := l.db.Query(ctx,
		`SELECT name FROM music_sources WHERE id = ?`, sourceID)
	if err != nil {
		return SourceDeletion{}, fmt.Errorf("library: read source %s: %w", sourceID, err)
	}
	if len(rows.Values) == 0 {
		return SourceDeletion{}, fmt.Errorf("library: source %s not found", sourceID)
	}
	deletion := SourceDeletion{Source: stringValue(rows.Values[0][0])}

	counts, err := l.db.Query(ctx,
		`SELECT COUNT(*) FROM tracks WHERE source_id = ?`, sourceID)
	if err != nil {
		return SourceDeletion{}, fmt.Errorf("library: count source tracks: %w", err)
	}
	if deletion.Tracks, err = countValue(counts); err != nil {
		return SourceDeletion{}, err
	}
	items, err := l.db.Query(ctx,
		`SELECT COUNT(*) FROM playlist_items
		 WHERE track_id IN (SELECT id FROM tracks WHERE source_id = ?)`, sourceID)
	if err != nil {
		return SourceDeletion{}, fmt.Errorf("library: count source playlist items: %w", err)
	}
	if deletion.PlaylistItems, err = countValue(items); err != nil {
		return SourceDeletion{}, err
	}
	covers, err := l.db.Query(ctx,
		`SELECT DISTINCT cover_art_path FROM tracks
		 WHERE source_id = ? AND cover_art_path IS NOT NULL AND cover_art_path != ''`,
		sourceID)
	if err != nil {
		return SourceDeletion{}, fmt.Errorf("library: read source covers: %w", err)
	}
	for _, value := range covers.Values {
		deletion.Covers = append(deletion.Covers, stringValue(value[0]))
	}

	// The tracks first: the playlist_items rows cascade on that delete
	// (PRAGMA foreign_keys is on for every writable connection).
	if _, err := l.db.Transaction(ctx, []sqlite.Statement{
		{SQL: `DELETE FROM tracks WHERE source_id = ?`, Args: []any{sourceID}},
		{SQL: `DELETE FROM music_sources WHERE id = ?`, Args: []any{sourceID}},
	}); err != nil {
		return SourceDeletion{}, fmt.Errorf("library: delete source %s: %w", sourceID, err)
	}
	l.bump()
	return deletion, nil
}

// ReferencedCovers is every cover file name some track still points at, which
// is what decides whether a deleted source leaves an orphan behind.
func (l *Library) ReferencedCovers(ctx context.Context) (map[string]bool, error) {
	rows, err := l.db.Query(ctx,
		`SELECT DISTINCT cover_art_path FROM tracks
		 WHERE cover_art_path IS NOT NULL AND cover_art_path != ''`)
	if err != nil {
		return nil, fmt.Errorf("library: read referenced covers: %w", err)
	}
	out := make(map[string]bool, len(rows.Values))
	for _, value := range rows.Values {
		out[stringValue(value[0])] = true
	}
	return out, nil
}
