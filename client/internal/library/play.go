package library

// The two playback writes M1 allows (plan §6 M1 item 4): play history and the
// play count. Both go through this file; nothing else in the client updates
// tracks.

import (
	"context"
	"fmt"
	"time"
)

// FileFacts is what a previous scan recorded about one file, so a rescan can
// skip parsing files whose size and modification time did not change.
type FileFacts map[string]struct {
	Size     int64
	Modified time.Time
}

// FileFacts returns the recorded size and modification time of every file of
// a source, keyed by absolute path.
func (l *Library) FileFacts(ctx context.Context, sourceID string) (FileFacts, error) {
	rows, err := l.db.Query(ctx,
		`SELECT file_path_or_url, file_size, last_modified FROM tracks WHERE source_id = ?`, sourceID)
	if err != nil {
		return nil, fmt.Errorf("library: file facts %s: %w", sourceID, err)
	}
	out := make(FileFacts, len(rows.Values))
	for _, value := range rows.Values {
		if len(value) != 3 {
			return nil, fmt.Errorf("library: file fact row has %d columns, want 3", len(value))
		}
		path := stringValue(value[0])
		if path == "" {
			continue
		}
		modified, _ := timeValue(value[2])
		out[path] = struct {
			Size     int64
			Modified time.Time
		}{Size: int64Value(value[1]), Modified: modified}
	}
	return out, nil
}

// RecordPlay counts one play of id and stamps last_played_at, returning the
// new count. The increment is done in SQL, not read-modify-write: two plays
// reported close together cannot lose a count.
func (l *Library) RecordPlay(ctx context.Context, id string) (int64, error) {
	if !l.writes {
		return 0, fmt.Errorf("library: connection is read-only")
	}
	if _, err := l.db.Execute(ctx,
		`UPDATE tracks SET play_count = play_count + 1, last_played_at = ? WHERE id = ?`,
		formatTime(time.Now()), id); err != nil {
		return 0, fmt.Errorf("library: record play %s: %w", id, err)
	}
	rows, err := l.db.Query(ctx, `SELECT play_count FROM tracks WHERE id = ?`, id)
	if err != nil {
		return 0, fmt.Errorf("library: read play count %s: %w", id, err)
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, fmt.Errorf("library: track %s disappeared while recording a play", id)
	}
	l.bump(id)
	return int64Value(rows.Values[0][0]), nil
}

// BackfillDuration fills a track's duration from the decoder, but only while
// the library still says 0 (a remote source's directory listing has no
// duration). It reports whether a row changed.
func (l *Library) BackfillDuration(ctx context.Context, id string, duration time.Duration) (bool, error) {
	if !l.writes {
		return false, fmt.Errorf("library: connection is read-only")
	}
	if duration <= 0 {
		return false, nil
	}
	result, err := l.db.Execute(ctx,
		`UPDATE tracks SET duration = ? WHERE id = ? AND duration = 0`,
		durationSeconds(duration), id)
	if err != nil {
		return false, fmt.Errorf("library: backfill duration %s: %w", id, err)
	}
	if result.Changes == 0 {
		return false, nil
	}
	l.bump(id)
	return true, nil
}
