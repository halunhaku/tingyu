package model

// Search. The 250 ms debounce, the five scopes and the previews are the
// Flutter page's; the matching itself is SQL now: each group is one query with
// LIMIT (the previews) or a paged list (a single scope), and the totals are
// COUNT queries, so search never loads the library to filter it (plan §2.5).
//
// A substring search cannot use a b-tree index, so the scan is the plan's cost
// and LIMIT is what bounds it: only the first preview rows and the first page
// of the chosen scope are read. The M4 record carries the EXPLAIN evidence.

import (
	"sort"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// Search scopes (search_scope.dart: all/songs/albums/artists/playlists).
const (
	ScopeAll = iota
	ScopeSongs
	ScopeAlbums
	ScopeArtists
	ScopePlaylists
)

// ScopeLabels are the segmented control's labels.
var ScopeLabels = []string{"全部", "歌曲", "专辑", "艺术家", "歌单"}

// SearchDebounceTime is the app-wide debounce (providers.dart:141).
const SearchDebounceTime = 250 * time.Millisecond

// SearchResults is one query's four groups, previews only.
type SearchResults struct {
	Query         string
	Revision      uint64
	Songs         []library.Track
	Albums        []Album
	Artists       []Artist
	Playlists     []library.Playlist
	SongTotal     int
	AlbumTotal    int
	ArtistTotal   int
	PlaylistTotal int
}

// SearchState is the search page and its 250 ms debounce.
type SearchState struct {
	Input   string
	Query   string
	Scope   int
	Focus   bool
	pending time.Time
	results SearchResults

	// songs, albums and artists are the full lists of a single scope,
	// paged 40 at a time like every other list.
	songs   TrackList
	albums  AlbumList
	artists ArtistList

	playlistPages int
	recent        []string
}

// OnInput marks the text changed and starts the debounce clock.
func (s *SearchState) OnInput(now time.Time) {
	s.pending = now
	if strings.TrimSpace(s.Input) == "" {
		s.Query = ""
		s.results = SearchResults{}
		s.playlistPages = 0
	}
}

// Pending reports a debounce clock still running.
func (s *SearchState) Pending() bool { return !s.pending.IsZero() }

// Tick applies a debounced query and recomputes the previews. The scope lists
// are ticked by State.Tick (they are paged lists like any other).
func (s *SearchState) Tick(now time.Time, load Backend, revision uint64) {
	if !s.pending.IsZero() && now.Sub(s.pending) >= SearchDebounceTime {
		s.pending = time.Time{}
		query := strings.TrimSpace(s.Input)
		if query != s.Query {
			s.Query = query
			s.applyQuery()
		}
	}
	if s.Query == "" {
		s.results = SearchResults{}
		return
	}
	if s.results.Query != s.Query || s.results.Revision != revision {
		s.recompute(load, revision)
	}
}

// applyQuery points the scope lists at a new query.
func (s *SearchState) applyQuery() {
	s.playlistPages = 0
	s.results = SearchResults{}
	s.songs.Configure(FilterAll, SortTitle, true, "")
	s.songs.SetQuery(s.Query)
	s.albums.Configure(library.AlbumQuery{Search: s.Query})
	s.artists.Configure(library.ArtistQuery{Search: s.Query})
}

// SetQuery applies a query at once (a recent search, a deep link).
func (s *SearchState) SetQuery(query string) {
	s.Input = query
	s.Query = strings.TrimSpace(query)
	s.pending = time.Time{}
	s.applyQuery()
}

// NeedsResults reports whether the debounced query has no results yet.
func (s *SearchState) NeedsResults() bool {
	return s.Query != "" && s.results.Query != s.Query
}

// recompute fills the previews and totals from the kernel.
func (s *SearchState) recompute(load Backend, revision uint64) {
	results := SearchResults{Query: s.Query, Revision: revision}
	if load == nil || s.Query == "" {
		s.results = results
		return
	}
	trackQuery := library.TrackQuery{Search: s.Query, Sort: library.SortTitle}
	albumQuery := library.AlbumQuery{Search: s.Query}
	artistQuery := library.ArtistQuery{Search: s.Query}

	preview := trackQuery
	preview.Limit = PreviewSize
	if songs, err := load.TracksPage(preview); err == nil {
		results.Songs = songs
	}
	if total, err := load.CountTracks(trackQuery); err == nil {
		results.SongTotal = total
	}

	albumPreview := albumQuery
	albumPreview.Limit = PreviewSize
	if albums, err := load.AlbumsPage(albumPreview); err == nil {
		results.Albums = make([]Album, 0, len(albums))
		for _, summary := range albums {
			results.Albums = append(results.Albums, albumFromSummary(summary))
		}
	}
	if total, err := load.CountAlbums(albumQuery); err == nil {
		results.AlbumTotal = total
	}

	artistPreview := artistQuery
	artistPreview.Limit = PreviewSize
	if artists, err := load.ArtistsPage(artistPreview); err == nil {
		results.Artists = make([]Artist, 0, len(artists))
		for _, summary := range artists {
			results.Artists = append(results.Artists, artistFromSummary(summary))
		}
	}
	if total, err := load.CountArtists(artistQuery); err == nil {
		results.ArtistTotal = total
	}

	results.Playlists = matchPlaylists(s.playlists(load), s.Query)
	results.PlaylistTotal = len(results.Playlists)
	s.results = results
}

// playlists is the playlist table, read once per search (it is small: the
// playlists a user created, not the library).
func (s *SearchState) playlists(load Backend) []library.Playlist {
	if load == nil {
		return nil
	}
	playlists, err := load.Playlists()
	if err != nil {
		return nil
	}
	return playlists
}

func matchPlaylists(playlists []library.Playlist, query string) []library.Playlist {
	needle := fold(strings.TrimSpace(query))
	if needle == "" {
		return nil
	}
	out := make([]library.Playlist, 0, 8)
	for _, playlist := range playlists {
		if strings.Contains(fold(playlist.Name), needle) {
			out = append(out, playlist)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return fold(out[i].Name) < fold(out[j].Name)
	})
	return out
}

// Results returns the current previews.
func (s *SearchState) Results() SearchResults { return s.results }

// OwnSongs is the paginated song list of the songs scope.
func (s *SearchState) OwnSongs() *TrackList { return &s.songs }

// OwnAlbums is the paginated album list of the albums scope.
func (s *SearchState) OwnAlbums() *AlbumList { return &s.albums }

// OwnArtists is the paginated artist list of the artists scope.
func (s *SearchState) OwnArtists() *ArtistList { return &s.artists }

// PlaylistPages is how many playlist pages the playlists scope shows.
func (s *SearchState) PlaylistPages() int {
	if s.playlistPages < 1 {
		return 1
	}
	return s.playlistPages
}

// PlaylistRows are the playlists the scope shows right now.
func (s *SearchState) PlaylistRows() []library.Playlist {
	rows := s.results.Playlists
	limit := s.PlaylistPages() * PageSize
	if limit >= len(rows) {
		return rows
	}
	return rows[:limit]
}

// RequestMorePlaylists loads the next page of the playlists scope.
func (s *SearchState) RequestMorePlaylists() {
	if s.playlistPages*PageSize >= len(s.results.Playlists) {
		return
	}
	s.playlistPages++
}

// HasMorePlaylists reports whether the playlists scope has more rows.
func (s *SearchState) HasMorePlaylists() bool {
	return s.playlistPages*PageSize < len(s.results.Playlists)
}

// ShowScope switches the segmented control and resets the playlist pages.
func (s *SearchState) ShowScope(scope int) {
	if scope < 0 || scope > ScopePlaylists {
		return
	}
	s.Scope = scope
	s.playlistPages = 0
}

// Recent returns the in-memory recent searches (≤10).
func (s *SearchState) Recent() []string { return s.recent }

// Remember adds a query to the recent list.
func (s *SearchState) Remember(query string) {
	query = strings.TrimSpace(query)
	if query == "" {
		return
	}
	out := []string{query}
	for _, old := range s.recent {
		if old != query && len(out) < 10 {
			out = append(out, old)
		}
	}
	s.recent = out
}

// ForgetRecent clears the recent searches.
func (s *SearchState) ForgetRecent() { s.recent = nil }

// Search returns the search state.
func (s *State) Search() *SearchState { return &s.search }

// PlaySearchHit plays the best match for the search field's text (Enter in the
// field: the Flutter page plays the hit list from its first row).
func (s *State) PlaySearchHit() {
	query := strings.TrimSpace(s.search.Input)
	if query == "" || s.backend == nil {
		return
	}
	s.search.Query = query
	s.search.Remember(query)
	tracks, err := s.backend.TracksPage(library.TrackQuery{Search: query, Sort: library.SortTitle})
	if err != nil || len(tracks) == 0 {
		return
	}
	s.Play(tracks, 0)
}

// Play starts a list at a row and records the queue the panel shows.
func (s *State) Play(tracks []library.Track, start int) {
	if len(tracks) == 0 {
		return
	}
	if start < 0 || start >= len(tracks) {
		start = 0
	}
	rotated := append(append([]library.Track{}, tracks[start:]...), tracks[:start]...)
	if a := s.actions; a != nil {
		if err := a.PlayTracks(tracks, start); err != nil {
			s.failure = err.Error()
			return
		}
	}
	s.SetQueue(rotated, 0)
}
