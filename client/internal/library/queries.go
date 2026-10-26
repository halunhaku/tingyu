package library

// The read side of the library as the view model consumes it.
//
// Paged lists are asynchronous on purpose. A page request is a SQL round trip
// over ten thousand rows, and a scan can hold the write lock for the whole
// busy timeout: running that inside a frame would show up as a dropped frame
// (or a frozen window) rather than as a slow query. LoadTracks and its
// siblings therefore run the query on their own goroutine and deliver one
// result on a buffered channel, which the model polls once per frame. The
// buffered channel means an abandoned request never blocks its goroutine.
//
// Everything that is not a list page (counts, the playlists table, recently
// played, 播放全部) is small or explicitly requested once, so it stays
// synchronous.

import (
	"context"
	"time"
)

// pageTimeout bounds one list request when the database is busy elsewhere.
const pageTimeout = 10 * time.Second

// TrackPage is one page of tracks plus the true total of its query.
type TrackPage struct {
	Rows  []Track
	Total int
	Err   error
}

// AlbumPage is one page of albums plus the total number of albums.
type AlbumPage struct {
	Rows  []AlbumSummary
	Total int
	Err   error
}

// ArtistPage is one page of artists plus the total number of artists.
type ArtistPage struct {
	Rows  []ArtistSummary
	Total int
	Err   error
}

// Queries is *Library adapted to the view model's read interface. It owns no
// state: every method forwards to the connection.
type Queries struct {
	lib *Library
}

// Queries returns the view model's read side.
func (l *Library) Queries() *Queries { return &Queries{lib: l} }

// LoadTracks answers a page request off the caller's goroutine.
func (q *Queries) LoadTracks(query TrackQuery) <-chan TrackPage {
	out := make(chan TrackPage, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), pageTimeout)
		defer cancel()
		rows, err := q.lib.TracksPage(ctx, query)
		if err != nil {
			out <- TrackPage{Err: err}
			return
		}
		total, err := q.lib.CountTracks(ctx, query)
		out <- TrackPage{Rows: rows, Total: total, Err: err}
	}()
	return out
}

// LoadAlbums answers a page of the album aggregate off the caller's goroutine.
func (q *Queries) LoadAlbums(query AlbumQuery) <-chan AlbumPage {
	out := make(chan AlbumPage, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), pageTimeout)
		defer cancel()
		rows, err := q.lib.AlbumsPage(ctx, query)
		if err != nil {
			out <- AlbumPage{Err: err}
			return
		}
		total, err := q.lib.CountAlbums(ctx, query)
		out <- AlbumPage{Rows: rows, Total: total, Err: err}
	}()
	return out
}

// LoadArtists answers a page of the artist aggregate off the caller's
// goroutine.
func (q *Queries) LoadArtists(query ArtistQuery) <-chan ArtistPage {
	out := make(chan ArtistPage, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), pageTimeout)
		defer cancel()
		rows, err := q.lib.ArtistsPage(ctx, query)
		if err != nil {
			out <- ArtistPage{Err: err}
			return
		}
		total, err := q.lib.CountArtists(ctx, query)
		out <- ArtistPage{Rows: rows, Total: total, Err: err}
	}()
	return out
}

// TracksPage answers a page synchronously: 播放全部, an album's tracks and the
// acceptance aids need the rows in hand before they act on them.
func (q *Queries) TracksPage(query TrackQuery) ([]Track, error) {
	return q.lib.TracksPage(context.Background(), query)
}

// AlbumsPage answers the album aggregate synchronously (the album detail
// rail and the search previews need the rows before they can act).
func (q *Queries) AlbumsPage(query AlbumQuery) ([]AlbumSummary, error) {
	return q.lib.AlbumsPage(context.Background(), query)
}

// ArtistsPage answers the artist aggregate synchronously.
func (q *Queries) ArtistsPage(query ArtistQuery) ([]ArtistSummary, error) {
	return q.lib.ArtistsPage(context.Background(), query)
}

// CountTracks is the true total of a track query.
func (q *Queries) CountTracks(query TrackQuery) (int, error) {
	return q.lib.CountTracks(context.Background(), query)
}

// CountAlbums is the true total of an album query.
func (q *Queries) CountAlbums(query AlbumQuery) (int, error) {
	return q.lib.CountAlbums(context.Background(), query)
}

// CountArtists is the true total of an artist query.
func (q *Queries) CountArtists(query ArtistQuery) (int, error) {
	return q.lib.CountArtists(context.Background(), query)
}

// Sources returns every music source.
func (q *Queries) Sources() ([]Source, error) {
	return q.lib.Sources(context.Background())
}

// Playlists returns every playlist with its track count.
func (q *Queries) Playlists() ([]Playlist, error) {
	return q.lib.Playlists(context.Background())
}

// Counts summarises the library for the settings page.
func (q *Queries) Counts() (Counts, error) {
	return q.lib.Counts(context.Background())
}

// RecentlyPlayed returns the most recently played tracks.
func (q *Queries) RecentlyPlayed(limit int) ([]Track, error) {
	return q.lib.RecentlyPlayed(context.Background(), limit)
}
