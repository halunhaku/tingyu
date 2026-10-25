package model

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

// SearchResults is one query's four groups. Playlists stay empty until the
// kernel exposes them.
type SearchResults struct {
	Query       string
	Songs       []library.Track
	Albums      []Album
	Artists     []Artist
	Playlists   []Playlist
	SongTotal   int
	AlbumTotal  int
	ArtistTotal int
}

// SearchState is the search page and its 250 ms debounce.
type SearchState struct {
	Input   string
	Query   string
	Scope   int
	Focus   bool
	pending time.Time
	results SearchResults
	pages   [5]int
	recent  []string

	// songs is the single-scope song list, paginated 40 at a time.
	songs TrackList
}

// OwnSongs returns the paginated song list of the search page.
func (s *SearchState) OwnSongs() *TrackList { return &s.songs }

// OnInput marks the text changed and starts the debounce clock.
func (s *SearchState) OnInput(now time.Time) {
	s.pending = now
	if strings.TrimSpace(s.Input) == "" {
		s.Query = ""
		s.results = SearchResults{}
		s.pages = [5]int{}
	}
}

// Pending reports a debounce clock still running.
func (s *SearchState) Pending() bool { return !s.pending.IsZero() }

// Tick applies a debounced query and recomputes results.
func (s *SearchState) Tick(now time.Time, tracks []library.Track) {
	if s.pending.IsZero() || now.Sub(s.pending) < SearchDebounceTime {
		return
	}
	s.pending = time.Time{}
	query := strings.TrimSpace(s.Input)
	if query == s.Query {
		return
	}
	s.Query = query
	s.pages = [5]int{}
	s.songs.Configure(FilterAll, SortTitle, true, "")
	s.songs.SetQuery(query)
	s.results = SearchResults{}
}

// SetQuery applies a query at once (a recent search, 「查看全部」, a deep link).
func (s *SearchState) SetQuery(query string) {
	s.Input = query
	s.Query = strings.TrimSpace(query)
	s.pending = time.Time{}
	s.pages = [5]int{}
	s.results = SearchResults{}
	s.songs.Configure(FilterAll, SortTitle, true, "")
	s.songs.SetQuery(s.Query)
}

// NeedsResults reports whether the debounced query has no results yet.
func (s *SearchState) NeedsResults() bool {
	return s.Query != "" && s.results.Query != strings.ToLower(s.Query)
}

// Recompute fills the results from the current library snapshot.
func (s *SearchState) Recompute(albums []Album, artists []Artist, tracks []library.Track) {
	q := strings.ToLower(s.Query)
	if q == "" {
		s.results = SearchResults{}
		return
	}
	s.results = searchAllWith(tracks, albums, artists, q)
	s.songs.Ensure(tracks, 0, nil)
}

// ApplyResults stores computed results (used by the shell once per frame).
func (s *SearchState) ApplyResults(r SearchResults) { s.results = r }

// Results returns the current groups.
func (s *SearchState) Results() SearchResults { return s.results }

// Pages returns the pages loaded for a scope.
func (s *SearchState) Pages(scope int) int {
	if scope < 0 || scope >= len(s.pages) {
		return 1
	}
	return s.pages[scope]
}

// RequestMore loads one more page of a scope.
func (s *SearchState) RequestMore(scope int, total int) {
	if scope < 0 || scope >= len(s.pages) {
		return
	}
	if s.pages[scope] == 0 {
		s.pages[scope] = 1
	}
	if s.pages[scope]*PageSize >= total {
		return
	}
	s.pages[scope]++
}

// HasMore reports whether a scope has rows beyond the loaded pages.
func (s *SearchState) HasMore(scope, total int) bool {
	pages := s.Pages(scope)
	if pages == 0 {
		pages = 1
	}
	return pages*PageSize < total
}

// ShowScope switches the segmented control and resets pages.
func (s *SearchState) ShowScope(scope int) {
	if scope < 0 || scope > ScopePlaylists {
		return
	}
	s.Scope = scope
	s.pages = [5]int{}
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

// SearchResultsOf computes results for the current library.
func (s *State) SearchResultsOf(query string) SearchResults {
	return searchAllWith(s.tracks, s.Albums(), s.Artists(), strings.ToLower(query))
}

func searchAllWith(tracks []library.Track, albums []Album, artists []Artist, query string) SearchResults {
	query = strings.ToLower(strings.TrimSpace(query))
	out := SearchResults{Query: query}
	if query == "" {
		return out
	}
	out.Songs = searchTracks(tracks, query)
	out.SongTotal = len(out.Songs)
	for _, album := range albums {
		if strings.Contains(fold(album.Name), query) || strings.Contains(fold(album.Artist), query) {
			out.Albums = append(out.Albums, album)
		}
	}
	out.AlbumTotal = len(out.Albums)
	for _, artist := range artists {
		if strings.Contains(fold(artist.Name), query) {
			out.Artists = append(out.Artists, artist)
		}
	}
	out.ArtistTotal = len(out.Artists)
	return out
}

func searchTracks(tracks []library.Track, query string) []library.Track {
	out := make([]library.Track, 0, 16)
	for _, track := range tracks {
		if trackMatches(track, query) {
			out = append(out, track)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		return strings.Compare(fold(out[i].Title)+out[i].ID, fold(out[j].Title)+out[j].ID) < 0
	})
	return out
}

// Preview returns at most n rows of a group.
func Preview[T any](rows []T, n int) []T {
	if len(rows) <= n {
		return rows
	}
	return rows[:n]
}
