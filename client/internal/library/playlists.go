package library

// Playlists: read, and the six writes M4 listed as missing (create, rename,
// delete, add, remove, reorder). The semantics are the Flutter client's
// (app/lib/data/repositories/playlist_repository.dart), because the two
// clients share this table during the dual-track period:
//
//   - a playlist's order is playlist_items.position, and position is only
//     meaningful after compaction to 0..n-1. Deleting a track cascades its
//     playlist_items rows away without renumbering the rest, so holes appear;
//     every write here renumbers first, which is what keeps "row i" equal to
//     "position i" (the old client hit a primary-key conflict or removed the
//     wrong track otherwise);
//   - adding appends in the order given, duplicates included: a playlist may
//     hold the same track twice;
//   - deleting a playlist removes its items by foreign key (ON DELETE
//     CASCADE, enabled on every writable connection).

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// Playlist is one row of playlists plus its live track count.
type Playlist struct {
	ID         string
	Name       string
	CreatedAt  time.Time
	TrackCount int
}

// Playlists returns every playlist with its track count, by name.
func (l *Library) Playlists(ctx context.Context) ([]Playlist, error) {
	const sql = `
SELECT p.id, p.name, p.created_at, COUNT(pi.track_id)
FROM playlists p
LEFT JOIN playlist_items pi ON pi.playlist_id = p.id
GROUP BY p.id
ORDER BY p.name COLLATE NOCASE, p.id`
	rows, err := l.db.Query(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("library: query playlists: %w", err)
	}
	out := make([]Playlist, 0, len(rows.Values))
	for i, value := range rows.Values {
		if len(value) != 4 {
			return nil, fmt.Errorf("library: playlist row %d has %d columns, want 4", i+1, len(value))
		}
		created, _ := timeValue(value[2])
		out = append(out, Playlist{
			ID:         stringValue(value[0]),
			Name:       stringValue(value[1]),
			CreatedAt:  created,
			TrackCount: int(int64Value(value[3])),
		})
	}
	return out, nil
}

// Playlist returns one playlist by id.
func (l *Library) Playlist(ctx context.Context, id string) (Playlist, bool, error) {
	playlists, err := l.Playlists(ctx)
	if err != nil {
		return Playlist{}, false, err
	}
	for _, playlist := range playlists {
		if playlist.ID == id {
			return playlist, true, nil
		}
	}
	return Playlist{}, false, nil
}

// NewPlaylistID is the id the Flutter client's 新建歌单 uses
// ('pl-' + microseconds since the epoch).
func NewPlaylistID(now time.Time) string {
	return fmt.Sprintf("pl-%d", now.UnixMicro())
}

// CreatePlaylist inserts a playlist. An empty name is refused instead of
// silently creating a row the list page would show as blank.
func (l *Library) CreatePlaylist(ctx context.Context, name string) (Playlist, error) {
	if !l.writes {
		return Playlist{}, errors.New("library: connection is read-only")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return Playlist{}, errors.New("library: playlist name is empty")
	}
	now := time.Now().UTC()
	playlist := Playlist{ID: NewPlaylistID(now), Name: name, CreatedAt: now}
	_, err := l.db.Execute(ctx,
		`INSERT INTO playlists (id, name, created_at) VALUES (?, ?, ?)`,
		playlist.ID, playlist.Name, formatTime(playlist.CreatedAt))
	if err != nil {
		return Playlist{}, fmt.Errorf("library: create playlist: %w", err)
	}
	l.bump()
	return playlist, nil
}

// RenamePlaylist sets a new name.
func (l *Library) RenamePlaylist(ctx context.Context, id, name string) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("library: playlist name is empty")
	}
	result, err := l.db.Execute(ctx, `UPDATE playlists SET name = ? WHERE id = ?`, name, id)
	if err != nil {
		return fmt.Errorf("library: rename playlist %s: %w", id, err)
	}
	if result.Changes == 0 {
		return fmt.Errorf("library: playlist %s not found", id)
	}
	l.bump()
	return nil
}

// PlaylistDeletion counts what deleting a playlist removed.
type PlaylistDeletion struct {
	Name  string
	Items int
}

// DeletePlaylist removes a playlist; its items go with it through the foreign
// key, never the tracks themselves.
func (l *Library) DeletePlaylist(ctx context.Context, id string) (PlaylistDeletion, error) {
	if !l.writes {
		return PlaylistDeletion{}, errors.New("library: connection is read-only")
	}
	playlist, found, err := l.Playlist(ctx, id)
	if err != nil {
		return PlaylistDeletion{}, err
	}
	if !found {
		return PlaylistDeletion{}, fmt.Errorf("library: playlist %s not found", id)
	}
	result, err := l.db.Execute(ctx, `DELETE FROM playlists WHERE id = ?`, id)
	if err != nil {
		return PlaylistDeletion{}, fmt.Errorf("library: delete playlist %s: %w", id, err)
	}
	if result.Changes == 0 {
		return PlaylistDeletion{}, fmt.Errorf("library: playlist %s not found", id)
	}
	l.bump()
	return PlaylistDeletion{Name: playlist.Name, Items: playlist.TrackCount}, nil
}

// AddTracksToPlaylist appends tracks to a playlist, in the order given.
func (l *Library) AddTracksToPlaylist(ctx context.Context, playlistID string, trackIDs []string) (int, error) {
	if !l.writes {
		return 0, errors.New("library: connection is read-only")
	}
	if len(trackIDs) == 0 {
		return 0, nil
	}
	items, err := l.playlistItems(ctx, playlistID)
	if err != nil {
		return 0, err
	}
	next := len(items)
	statements := make([]sqlite.Statement, 0, len(trackIDs)+1)
	if !denseItems(items) {
		// Positions have holes (a track was deleted): rewrite them first, or
		// appending at len(items) would collide with a primary key.
		statements = append(statements, rewriteItems(playlistID, items)...)
	}
	for _, trackID := range trackIDs {
		statements = append(statements, sqlite.Statement{
			SQL:  `INSERT INTO playlist_items (playlist_id, track_id, position) VALUES (?, ?, ?)`,
			Args: []any{playlistID, trackID, next},
		})
		next++
	}
	return len(trackIDs), l.run(ctx, statements, "add tracks to playlist")
}

// RemovePlaylistItem removes the item at index (its row in the playlist's
// saved order) and closes the gap.
func (l *Library) RemovePlaylistItem(ctx context.Context, playlistID string, index int) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	items, err := l.playlistItems(ctx, playlistID)
	if err != nil {
		return err
	}
	if index < 0 || index >= len(items) {
		return fmt.Errorf("library: playlist %s has no row %d", playlistID, index)
	}
	remaining := append(append([]item{}, items[:index]...), items[index+1:]...)
	return l.run(ctx, rewriteItems(playlistID, remaining), "remove playlist item")
}

// MovePlaylistItem moves the item at from to to (both rows in the saved
// order), reordering the whole list.
func (l *Library) MovePlaylistItem(ctx context.Context, playlistID string, from, to int) error {
	if !l.writes {
		return errors.New("library: connection is read-only")
	}
	if from == to {
		return nil
	}
	items, err := l.playlistItems(ctx, playlistID)
	if err != nil {
		return err
	}
	if from < 0 || from >= len(items) || to < 0 || to >= len(items) {
		return fmt.Errorf("library: playlist %s has %d rows, cannot move %d to %d", playlistID, len(items), from, to)
	}
	moved := items[from]
	rest := append(append([]item{}, items[:from]...), items[from+1:]...)
	reordered := make([]item, 0, len(items))
	reordered = append(reordered, rest[:to]...)
	reordered = append(reordered, moved)
	reordered = append(reordered, rest[to:]...)
	return l.run(ctx, rewriteItems(playlistID, reordered), "move playlist item")
}

// item is one playlist_items row: the track and the position it had.
type item struct {
	trackID  string
	position int
}

// playlistItems reads a playlist's items in saved order.
func (l *Library) playlistItems(ctx context.Context, playlistID string) ([]item, error) {
	rows, err := l.db.Query(ctx,
		`SELECT track_id, position FROM playlist_items WHERE playlist_id = ? ORDER BY position ASC`,
		playlistID)
	if err != nil {
		return nil, fmt.Errorf("library: read playlist %s: %w", playlistID, err)
	}
	out := make([]item, 0, len(rows.Values))
	for _, value := range rows.Values {
		if len(value) != 2 {
			return nil, fmt.Errorf("library: playlist item has %d columns, want 2", len(value))
		}
		out = append(out, item{trackID: stringValue(value[0]), position: intValue(value[1])})
	}
	return out, nil
}

// denseItems reports whether positions are already 0..n-1.
func denseItems(items []item) bool {
	for i, it := range items {
		if it.position != i {
			return false
		}
	}
	return true
}

// rewriteItems replaces a playlist's items with ids, numbered from zero. Doing
// it as one delete followed by ordered inserts avoids every transient primary
// key conflict a per-row UPDATE would hit while a swap is in progress.
func rewriteItems(playlistID string, items []item) []sqlite.Statement {
	statements := make([]sqlite.Statement, 0, len(items)+1)
	statements = append(statements, sqlite.Statement{
		SQL:  `DELETE FROM playlist_items WHERE playlist_id = ?`,
		Args: []any{playlistID},
	})
	for position, it := range items {
		statements = append(statements, sqlite.Statement{
			SQL:  `INSERT INTO playlist_items (playlist_id, track_id, position) VALUES (?, ?, ?)`,
			Args: []any{playlistID, it.trackID, position},
		})
	}
	return statements
}

// run executes statements in one transaction and bumps the revision, so every
// query keyed by it refreshes.
func (l *Library) run(ctx context.Context, statements []sqlite.Statement, what string) error {
	if len(statements) == 0 {
		return nil
	}
	if _, err := l.db.Transaction(ctx, statements); err != nil {
		return fmt.Errorf("library: %s: %w", what, err)
	}
	l.bump()
	return nil
}
