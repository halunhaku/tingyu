package library

// Paged reads. Everything the pages show comes from SQL: a page of tracks is
// LIMIT/OFFSET, an album or artist list is one GROUP BY, and no caller ever
// needs the whole tracks table in memory (plan §2.5: "禁止把整表塞进内存做
// 筛选"). The M4 client filtered and paged a full in-memory snapshot; these
// queries replace that, and the ORDER BY/filters below are chosen so the
// existing indexes do the work wherever an index can.
//
// What an index cannot do is stated where it happens: a substring search
// (LIKE '%x%') and a sort on a column with no index (title, duration) still
// sort or scan, bounded by LIMIT. See the M4 record's EXPLAIN QUERY PLAN
// evidence.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// SortField is the order a page of tracks comes back in: the table header's
// five fields, the zero value first. Each order is exactly one index from
// schema.go (idx_tracks_sort_*), collation and direction included, so a page
// request walks the index instead of scanning and sorting the table.
type SortField int

const (
	SortTitle SortField = iota
	SortArtist
	SortAlbum
	SortDuration
	SortAdded
)

// orderTerms are the ORDER BY terms of each sort, ascending, in the order of
// the matching index. A descending sort reverses every term, so ties break the
// same way in both directions and the index still serves the scan.
var orderTerms = map[SortField][]string{
	SortTitle:    {"t.title COLLATE NOCASE", "t.artist COLLATE NOCASE", "t.id"},
	SortArtist:   {"t.artist COLLATE NOCASE", "t.album COLLATE NOCASE", "t.disc_number", "t.track_number", "t.title COLLATE NOCASE", "t.id"},
	SortAlbum:    {"t.album COLLATE NOCASE", "t.artist COLLATE NOCASE", "t.disc_number", "t.track_number", "t.title COLLATE NOCASE", "t.id"},
	SortDuration: {"t.duration", "t.id"},
	SortAdded:    {"t.date_added", "t.id"},
}

// order renders the ORDER BY of a sort.
func (s SortField) order(asc bool) string {
	terms, ok := orderTerms[s]
	if !ok {
		terms = orderTerms[SortTitle]
	}
	parts := make([]string, len(terms))
	for i, term := range terms {
		if asc {
			parts[i] = term + " ASC"
		} else {
			parts[i] = term + " DESC"
		}
	}
	return strings.Join(parts, ", ")
}

// TrackQuery selects one page of tracks. The zero value is the whole library
// in display order, unbounded, which only 播放全部 and the acceptance aids ask
// for; every page the UI shows sets Limit.
type TrackQuery struct {
	SourceID   string // one music source
	PlaylistID string // membership of one playlist, in its saved order
	Favorite   bool   // favourites only
	Artist     string // exact artist name (album/artist detail pages)
	Album      string // exact album name, with Artist (album detail pages)
	Search     string // substring of title, artist or album
	Sort       SortField
	Desc       bool // false (the zero value) is ascending
	Limit      int  // 0 or less: no limit
	Offset     int
}

// columns is the tracks projection trackFromRow parses, in its order.
const columns = `t.id, t.source_id, t.title, t.artist, t.album, t.duration,
	t.track_number, t.disc_number, t.year, t.genre, t.bitrate, t.sample_rate,
	t.file_format, t.file_path_or_url, t.file_size, t.last_modified,
	t.cover_art_path, t.cover_art_url, t.lyrics,
	t.is_favorite, t.date_added, t.play_count, t.last_played_at`

// from is the FROM clause of a track query. A playlist page joins the items
// table, which is keyed by (playlist_id, position) and has its own index on
// track_id — both directions of the join are indexed.
func (q TrackQuery) from() string {
	if q.PlaylistID == "" {
		return "tracks t"
	}
	return "tracks t JOIN playlist_items pi ON pi.track_id = t.id"
}

// where renders the filter and its arguments.
func (q TrackQuery) where() (string, []any) {
	var clauses []string
	var args []any
	add := func(clause string, values ...any) {
		clauses = append(clauses, clause)
		args = append(args, values...)
	}
	if q.SourceID != "" {
		// idx_tracks_source
		add("t.source_id = ?", q.SourceID)
	}
	if q.PlaylistID != "" {
		// PRIMARY KEY (playlist_id, position)
		add("pi.playlist_id = ?", q.PlaylistID)
	}
	if q.Favorite {
		// idx_tracks_favorite
		add("t.is_favorite = 1")
	}
	if q.Artist != "" {
		clause, values := textMatch("t.artist", q.Artist, UnknownArtist)
		add(clause, values...)
	}
	if q.Album != "" {
		clause, values := textMatch("t.album", q.Album, UnknownAlbum)
		add(clause, values...)
	}
	if needle := strings.TrimSpace(q.Search); needle != "" {
		pattern := likePattern(needle)
		// A substring cannot use a b-tree index; LIMIT bounds the work.
		add(`(t.title LIKE ? ESCAPE '\' OR t.artist LIKE ? ESCAPE '\' OR t.album LIKE ? ESCAPE '\')`,
			pattern, pattern, pattern)
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

// textMatch compares a column with a display name. The empty string is read
// as the unknown placeholder on both sides, so a legacy row with ” and a
// scanned row with '未知专辑' land in the same album.
func textMatch(column, value, placeholder string) (string, []any) {
	if value == placeholder {
		// The placeholder itself, or a legacy empty value ensureSchema has not
		// normalised yet.
		return "(" + column + " = ? OR TRIM(" + column + ") = '')", []any{placeholder}
	}
	return column + " = ?", []any{value}
}

// likePattern turns a search into a LIKE pattern with the wildcards escaped,
// so a user typing % or _ searches for them instead of matching everything.
func likePattern(needle string) string {
	var b strings.Builder
	b.Grow(len(needle) + 4)
	b.WriteByte('%')
	for _, r := range needle {
		switch r {
		case '\\', '%', '_':
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	b.WriteByte('%')
	return b.String()
}

// pageSQL renders the page query. It is a value method so the acceptance
// harness can EXPLAIN exactly the statement TracksPage runs.
func (q TrackQuery) pageSQL() (string, []any) {
	where, args := q.where()
	sql := "SELECT " + columns + " FROM " + q.from() + where
	if q.PlaylistID != "" {
		// A playlist is shown in its saved order; sorting it would be a
		// different list than the one the user arranged.
		sql += " ORDER BY pi.position ASC"
	} else {
		sql += " ORDER BY " + q.Sort.order(!q.Desc)
	}
	limit := q.Limit
	if limit <= 0 {
		limit = -1 // SQLite: no upper bound, but OFFSET still applies.
	}
	if limit > 0 || q.Offset > 0 {
		sql += " LIMIT ? OFFSET ?"
		args = append(args, limit, q.Offset)
	}
	return sql, args
}

// countSQL renders the count query of the same filter.
func (q TrackQuery) countSQL() (string, []any) {
	where, args := q.where()
	return "SELECT COUNT(*) FROM " + q.from() + where, args
}

// TracksPage returns one page of tracks matching q.
func (l *Library) TracksPage(ctx context.Context, q TrackQuery) ([]Track, error) {
	sql, args := q.pageSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("library: query tracks page: %w", err)
	}
	return tracksFromRows(rows)
}

// CountTracks is the true number of rows a query matches, which the pager
// footer and "play all" both need without loading them.
func (l *Library) CountTracks(ctx context.Context, q TrackQuery) (int, error) {
	sql, args := q.countSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return 0, fmt.Errorf("library: count tracks: %w", err)
	}
	return countValue(rows)
}

// tracksFromRows parses a tracks projection (columns, in order).
func tracksFromRows(rows sqlite.Rows) ([]Track, error) {
	out := make([]Track, 0, len(rows.Values))
	for i, value := range rows.Values {
		track, err := trackFromRow(value)
		if err != nil {
			return nil, fmt.Errorf("library: track row %d: %w", i+1, err)
		}
		out = append(out, track)
	}
	return out, nil
}

// countValue reads a single COUNT(*) cell.
func countValue(rows sqlite.Rows) (int, error) {
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, errors.New("library: COUNT(*) returned no row")
	}
	return int(int64Value(rows.Values[0][0])), nil
}

// numberValue reads a REAL cell (SUM(duration), MAX(year) through COALESCE).
func numberValue(v any) float64 {
	if number, ok := v.(float64); ok {
		return number
	}
	return float64(int64Value(v))
}

// Albums and artists are grouped by the raw columns, not by a CASE that
// would normalise ” to the placeholder: a group expression that is not the
// indexed column cannot be served by idx_tracks_artist_album, and SQLite then
// builds a temporary b-tree for every group. The empty string is mapped to the
// placeholder in Go instead (albumDisplay, artistDisplay), which costs nothing
// and keeps the aggregate index-ordered. A legacy row storing ” therefore
// forms its own group, shown with the same placeholder name; the Flutter
// client and merge both write the placeholder itself, so this is a display
// edge, not a duplicate album in practice.
const (
	albumDisplay  = UnknownAlbum
	artistDisplay = UnknownArtist
)

func albumDisplayOf(name string) string {
	if strings.TrimSpace(name) == "" {
		return albumDisplay
	}
	return name
}

func artistDisplayOf(name string) string {
	if strings.TrimSpace(name) == "" {
		return artistDisplay
	}
	return name
}

// AlbumQuery selects albums: one row per (artist, album) pair, aggregated in
// SQL. The list pages page through it; a detail page asks for one artist.
type AlbumQuery struct {
	SourceID string
	Artist   string
	Favorite bool
	Search   string
	Limit    int
	Offset   int
}

// AlbumSummary is one album group as the grid and the detail header show it.
// Its tracks are a separate query, taken when the album is opened or played.
type AlbumSummary struct {
	Name       string
	Artist     string
	Year       int
	TrackCount int
	Duration   time.Duration
	Cover      string
}

// ArtistQuery selects artists, aggregated in SQL.
type ArtistQuery struct {
	SourceID string
	Search   string
	Limit    int
	Offset   int
}

// ArtistSummary is one artist group.
type ArtistSummary struct {
	Name       string
	TrackCount int
	AlbumCount int
	Duration   time.Duration
	Cover      string
}

// albumWhere renders the filter of an album or artist aggregate.
func (q AlbumQuery) where() (string, []any) {
	var clauses []string
	var args []any
	if q.SourceID != "" {
		clauses = append(clauses, "t.source_id = ?")
		args = append(args, q.SourceID)
	}
	if q.Artist != "" {
		clause, values := textMatch("t.artist", q.Artist, UnknownArtist)
		clauses = append(clauses, clause)
		args = append(args, values...)
	}
	if q.Favorite {
		clauses = append(clauses, "t.is_favorite = 1")
	}
	if needle := strings.TrimSpace(q.Search); needle != "" {
		pattern := likePattern(needle)
		clauses = append(clauses,
			`(t.album LIKE ? ESCAPE '\' OR t.artist LIKE ? ESCAPE '\')`)
		args = append(args, pattern, pattern)
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

// pageSQL renders the album page query.
func (q AlbumQuery) pageSQL() (string, []any) {
	where, args := q.where()
	sql := `SELECT t.album, t.artist,
		COALESCE(MAX(t.year), 0), COUNT(*), COALESCE(SUM(t.duration), 0),
		COALESCE(MIN(NULLIF(t.cover_art_path, '')), '')
	FROM tracks t` + where + `
	GROUP BY t.artist, t.album
	ORDER BY t.album COLLATE NOCASE, t.artist COLLATE NOCASE`
	limit := q.Limit
	if limit <= 0 {
		limit = -1
	}
	if limit > 0 || q.Offset > 0 {
		sql += " LIMIT ? OFFSET ?"
		args = append(args, limit, q.Offset)
	}
	return sql, args
}

// countSQL renders the album count query.
func (q AlbumQuery) countSQL() (string, []any) {
	where, args := q.where()
	return `SELECT COUNT(*) FROM (
		SELECT 1 FROM tracks t` + where + `
		GROUP BY t.artist, t.album)`, args
}

// AlbumsPage returns one page of albums, alphabetically. Grouping by
// (artist, album) is served by idx_tracks_artist_album, so the aggregate does
// not build a temporary b-tree for its groups.
func (l *Library) AlbumsPage(ctx context.Context, q AlbumQuery) ([]AlbumSummary, error) {
	sql, args := q.pageSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("library: query albums: %w", err)
	}
	out := make([]AlbumSummary, 0, len(rows.Values))
	for i, value := range rows.Values {
		if len(value) != 6 {
			return nil, fmt.Errorf("library: album row %d has %d columns, want 6", i+1, len(value))
		}
		out = append(out, AlbumSummary{
			Name:       albumDisplayOf(stringValue(value[0])),
			Artist:     artistDisplayOf(stringValue(value[1])),
			Year:       intValue(value[2]),
			TrackCount: int(int64Value(value[3])),
			Duration:   secondsDuration(numberValue(value[4])),
			Cover:      stringValue(value[5]),
		})
	}
	return out, nil
}

// CountAlbums counts the album groups a query matches.
func (l *Library) CountAlbums(ctx context.Context, q AlbumQuery) (int, error) {
	sql, args := q.countSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return 0, fmt.Errorf("library: count albums: %w", err)
	}
	return countValue(rows)
}

// artistWhere renders the filter of an artist aggregate (no album filter: an
// artist is not an album).
func (q ArtistQuery) where() (string, []any) {
	var clauses []string
	var args []any
	if q.SourceID != "" {
		clauses = append(clauses, "t.source_id = ?")
		args = append(args, q.SourceID)
	}
	if needle := strings.TrimSpace(q.Search); needle != "" {
		pattern := likePattern(needle)
		clauses = append(clauses, `t.artist LIKE ? ESCAPE '\'`)
		args = append(args, pattern)
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

// pageSQL renders the artist page query.
func (q ArtistQuery) pageSQL() (string, []any) {
	where, args := q.where()
	sql := `SELECT t.artist, COUNT(*), COUNT(DISTINCT TRIM(t.album)),
		COALESCE(SUM(t.duration), 0), COALESCE(MIN(NULLIF(t.cover_art_path, '')), '')
	FROM tracks t` + where + `
	GROUP BY t.artist
	ORDER BY t.artist COLLATE NOCASE`
	limit := q.Limit
	if limit <= 0 {
		limit = -1
	}
	if limit > 0 || q.Offset > 0 {
		sql += " LIMIT ? OFFSET ?"
		args = append(args, limit, q.Offset)
	}
	return sql, args
}

// countSQL renders the artist count query.
func (q ArtistQuery) countSQL() (string, []any) {
	where, args := q.where()
	return `SELECT COUNT(*) FROM (
		SELECT 1 FROM tracks t` + where + `
		GROUP BY t.artist)`, args
}

// ArtistsPage returns one page of artists, alphabetically.
func (l *Library) ArtistsPage(ctx context.Context, q ArtistQuery) ([]ArtistSummary, error) {
	sql, args := q.pageSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("library: query artists: %w", err)
	}
	out := make([]ArtistSummary, 0, len(rows.Values))
	for i, value := range rows.Values {
		if len(value) != 5 {
			return nil, fmt.Errorf("library: artist row %d has %d columns, want 5", i+1, len(value))
		}
		out = append(out, ArtistSummary{
			Name:       artistDisplayOf(stringValue(value[0])),
			TrackCount: int(int64Value(value[1])),
			AlbumCount: int(int64Value(value[2])),
			Duration:   secondsDuration(numberValue(value[3])),
			Cover:      stringValue(value[4]),
		})
	}
	return out, nil
}

// CountArtists counts the artist groups a query matches.
func (l *Library) CountArtists(ctx context.Context, q ArtistQuery) (int, error) {
	sql, args := q.countSQL()
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return 0, fmt.Errorf("library: count artists: %w", err)
	}
	return countValue(rows)
}

// Counts is the settings page's summary, in one round trip.
type Counts struct {
	Tracks    int
	Albums    int
	Artists   int
	Playlists int
	Sources   int
}

// Counts summarises the library.
func (l *Library) Counts(ctx context.Context) (Counts, error) {
	const sql = `SELECT
		(SELECT COUNT(*) FROM tracks),
		(SELECT COUNT(*) FROM (SELECT 1 FROM tracks t GROUP BY t.artist, t.album)),
		(SELECT COUNT(*) FROM (SELECT 1 FROM tracks t GROUP BY t.artist)),
		(SELECT COUNT(*) FROM playlists),
		(SELECT COUNT(*) FROM music_sources)`
	rows, err := l.db.Query(ctx, sql)
	if err != nil {
		return Counts{}, fmt.Errorf("library: counts: %w", err)
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 5 {
		return Counts{}, errors.New("library: counts returned no row")
	}
	value := rows.Values[0]
	return Counts{
		Tracks:    int(int64Value(value[0])),
		Albums:    int(int64Value(value[1])),
		Artists:   int(int64Value(value[2])),
		Playlists: int(int64Value(value[3])),
		Sources:   int(int64Value(value[4])),
	}, nil
}

// RecentlyPlayed returns the most recently played tracks, newest first.
func (l *Library) RecentlyPlayed(ctx context.Context, limit int) ([]Track, error) {
	sql := "SELECT " + columns + ` FROM tracks t
		WHERE t.last_played_at IS NOT NULL AND t.last_played_at != ''
		ORDER BY t.last_played_at DESC, t.id`
	args := []any{}
	if limit > 0 {
		sql += " LIMIT ?"
		args = append(args, limit)
	}
	rows, err := l.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, fmt.Errorf("library: recently played: %w", err)
	}
	return tracksFromRows(rows)
}
