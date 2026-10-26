package library

// Metadata enrichment writes (plan §6 M5): the library side of the scraper
// pipeline. internal/metadata only fetches; internal/enrich decides; this file
// is the only place an enrichment result reaches SQLite.
//
// Two properties matter:
//   - a write is minimal — fields the pipeline left empty stay untouched, so a
//     later scan's real tags are never overwritten by a placeholder;
//   - every write bumps the revision and the row's revision, which is what
//     makes the list and the stage refresh without a restart (plan §2.5).
//
// Nothing here changes the schema: enrichment uses columns that already exist
// (user_version stays 2, plan §8.1 rule 3).

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// EnrichmentFields is what a metadata pass wants to write back. An empty
// string (or a zero duration) means "keep the library's value".
type EnrichmentFields struct {
	Title        string
	Artist       string
	Album        string
	Lyrics       string
	CoverArtPath string
	CoverArtURL  string
	Duration     time.Duration
}

// Empty reports nothing to write.
func (f EnrichmentFields) Empty() bool {
	return strings.TrimSpace(f.Title) == "" &&
		strings.TrimSpace(f.Artist) == "" &&
		strings.TrimSpace(f.Album) == "" &&
		strings.TrimSpace(f.Lyrics) == "" &&
		strings.TrimSpace(f.CoverArtPath) == "" &&
		strings.TrimSpace(f.CoverArtURL) == "" &&
		f.Duration <= 0
}

// EnrichmentTarget is one track the enrichment pass should look at, with the
// facts the pipeline needs to decide.
type EnrichmentTarget struct {
	Track       Track
	NeedsCover  bool
	NeedsLyrics bool
	NeedsTags   bool
}

// EnrichmentTargets lists the tracks with something missing, in a stable order
// (date added, then id), which is the "20 首无标签曲目" set the milestone
// acceptance triggers a pass over. A limit of 0 or less means no limit.
//
// "Missing" is deliberately broad: a placeholder artist/album, no cover file,
// or no lyrics. A track with real tags and both assets is not a target and
// costs no request.
func (l *Library) EnrichmentTargets(ctx context.Context, limit int) ([]EnrichmentTarget, error) {
	query := `
SELECT id, source_id, title, artist, album, duration,
       track_number, disc_number, year, genre, bitrate, sample_rate,
       file_format, file_path_or_url, file_size, last_modified,
       cover_art_path, cover_art_url, lyrics,
       is_favorite, date_added, play_count, last_played_at
FROM tracks
WHERE artist = ? OR album IN (?, ?, ?)
   OR cover_art_path IS NULL OR cover_art_path = ''
   OR lyrics IS NULL OR lyrics = ''
ORDER BY date_added, id`
	args := []any{UnknownArtist, UnknownAlbum, "夸克曲库", "WebDAV 曲库"}
	if limit > 0 {
		query += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := l.db.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("library: read enrichment targets: %w", err)
	}
	out := make([]EnrichmentTarget, 0, len(rows.Values))
	for i, value := range rows.Values {
		track, err := trackFromRow(value)
		if err != nil {
			return nil, fmt.Errorf("library: enrichment target row %d: %w", i+1, err)
		}
		out = append(out, EnrichmentTarget{
			Track:       track,
			NeedsCover:  strings.TrimSpace(track.CoverArtPath) == "" && strings.TrimSpace(track.CoverArtURL) == "",
			NeedsLyrics: strings.TrimSpace(track.Lyrics) == "",
			NeedsTags: track.Artist == UnknownArtist || track.Album == UnknownAlbum ||
				track.Album == "夸克曲库" || track.Album == "WebDAV 曲库",
		})
	}
	return out, nil
}

// CountEnrichmentTargets is the number of tracks a full pass would look at.
func (l *Library) CountEnrichmentTargets(ctx context.Context) (int, error) {
	rows, err := l.db.Query(ctx, `
SELECT COUNT(*) FROM tracks
WHERE artist = ? OR album IN (?, ?, ?)
   OR cover_art_path IS NULL OR cover_art_path = ''
   OR lyrics IS NULL OR lyrics = ''`,
		UnknownArtist, UnknownAlbum, "夸克曲库", "WebDAV 曲库")
	if err != nil {
		return 0, fmt.Errorf("library: count enrichment targets: %w", err)
	}
	return countValue(rows)
}

// ApplyEnrichment writes the non-empty fields of fields to one track and
// reports whether the row changed. Fields equal to what the row already holds
// are skipped, so a repeated pass neither rewrites the file nor bumps the
// revision. Duration is written only while the library still says 0, exactly
// like BackfillDuration: a decoder's duration is more accurate than a search
// hit's.
func (l *Library) ApplyEnrichment(ctx context.Context, id string, fields EnrichmentFields) (bool, error) {
	if !l.writes {
		return false, errors.New("library: connection is read-only")
	}
	if strings.TrimSpace(id) == "" {
		return false, errors.New("library: enrichment needs a track id")
	}
	if fields.Empty() {
		return false, nil
	}
	current, found, err := l.Track(ctx, id)
	if err != nil {
		return false, err
	}
	if !found {
		return false, fmt.Errorf("library: enrichment for unknown track %s", id)
	}
	sets := make([]string, 0, 6)
	args := make([]any, 0, 7)
	add := func(column, value, existing string) {
		if value != "" && value != existing {
			sets = append(sets, column+" = ?")
			args = append(args, value)
		}
	}
	add("title", strings.TrimSpace(fields.Title), current.Title)
	add("artist", strings.TrimSpace(fields.Artist), current.Artist)
	add("album", strings.TrimSpace(fields.Album), current.Album)
	add("lyrics", fields.Lyrics, current.Lyrics)
	add("cover_art_path", strings.TrimSpace(fields.CoverArtPath), current.CoverArtPath)
	add("cover_art_url", strings.TrimSpace(fields.CoverArtURL), current.CoverArtURL)
	changed := false
	if len(sets) > 0 {
		args = append(args, id)
		result, err := l.db.Execute(ctx, `UPDATE tracks SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...)
		if err != nil {
			return false, fmt.Errorf("library: apply enrichment %s: %w", id, err)
		}
		changed = result.Changes > 0
	}
	// Duration keeps its own statement: the decoder wins while the row says 0,
	// and a later enrichment pass cannot overwrite the real value.
	if fields.Duration > 0 && current.Duration <= 0 {
		result, err := l.db.Execute(ctx,
			`UPDATE tracks SET duration = ? WHERE id = ? AND duration = 0`,
			durationSeconds(fields.Duration), id)
		if err != nil {
			return false, fmt.Errorf("library: apply enrichment duration %s: %w", id, err)
		}
		changed = changed || result.Changes > 0
	}
	if changed {
		l.bump(id)
	}
	return changed, nil
}

// ManualMatch is the human override path: a candidate the user picked in the
// match dialog, written verbatim. It keeps the same minimal-write rule, so a
// user who fixes only the title does not lose the cover, and it shares
// ApplyEnrichment's revision bump (the UI refreshes the same way an automatic
// pass does).
func (l *Library) ManualMatch(ctx context.Context, id string, fields EnrichmentFields) (bool, error) {
	return l.ApplyEnrichment(ctx, id, fields)
}
