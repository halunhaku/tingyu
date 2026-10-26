package model

// fakeBackend answers the model's reads from memory. It implements the same
// filters, ordering, paging and aggregates as the kernel's SQL so the model's
// paging and refresh rules can be tested without a database; the SQL itself is
// proved against a real SQLite fixture in the library package, and the window's
// end-to-end rendering is proved in the shell package over that same fixture.

import (
	"sort"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
)

type fakeBackend struct {
	tracks    []library.Track
	sources   []library.Source
	playlists []library.Playlist
	items     map[string][]string // playlist id → track ids in saved order
	rowRevs   map[string]uint64

	revision uint64
	// hang, when set, keeps LoadTracks from answering: the model must show the
	// loading state and keep the rows it already has.
	hang map[uint64]bool
}

func newFakeBackend(tracks []library.Track) *fakeBackend {
	return &fakeBackend{tracks: tracks, rowRevs: map[string]uint64{}, items: map[string][]string{}}
}

func (f *fakeBackend) Revision() uint64             { return f.revision }
func (f *fakeBackend) RowRevision(id string) uint64 { return f.rowRevs[id] }

func (f *fakeBackend) bump(ids ...string) {
	f.revision++
	for _, id := range ids {
		f.rowRevs[id]++
	}
}

func (f *fakeBackend) LoadTracks(q library.TrackQuery) <-chan library.TrackPage {
	rows, total := f.pageTracks(q)
	page := library.TrackPage{Rows: rows, Total: total}
	ch := make(chan library.TrackPage, 1)
	if f.hang != nil && f.hang[f.revision] {
		// Never answers: the model keeps its rows and stays loading.
		return ch
	}
	ch <- page
	return ch
}

func (f *fakeBackend) LoadAlbums(q library.AlbumQuery) <-chan library.AlbumPage {
	rows, total := f.albums(q)
	ch := make(chan library.AlbumPage, 1)
	ch <- library.AlbumPage{Rows: rows, Total: total}
	return ch
}

func (f *fakeBackend) LoadArtists(q library.ArtistQuery) <-chan library.ArtistPage {
	rows, total := f.artists(q)
	ch := make(chan library.ArtistPage, 1)
	ch <- library.ArtistPage{Rows: rows, Total: total}
	return ch
}

func (f *fakeBackend) TracksPage(q library.TrackQuery) ([]library.Track, error) {
	rows, _ := f.pageTracks(q)
	return rows, nil
}

func (f *fakeBackend) CountTracks(q library.TrackQuery) (int, error) {
	_, total := f.pageTracks(q)
	return total, nil
}

func (f *fakeBackend) AlbumsPage(q library.AlbumQuery) ([]library.AlbumSummary, error) {
	rows, _ := f.albums(q)
	return rows, nil
}

func (f *fakeBackend) CountAlbums(q library.AlbumQuery) (int, error) {
	_, total := f.albums(q)
	return total, nil
}

func (f *fakeBackend) ArtistsPage(q library.ArtistQuery) ([]library.ArtistSummary, error) {
	rows, _ := f.artists(q)
	return rows, nil
}

func (f *fakeBackend) CountArtists(q library.ArtistQuery) (int, error) {
	_, total := f.artists(q)
	return total, nil
}

func (f *fakeBackend) Sources() ([]library.Source, error) { return f.sources, nil }

func (f *fakeBackend) Playlists() ([]library.Playlist, error) {
	out := make([]library.Playlist, 0, len(f.playlists))
	for _, playlist := range f.playlists {
		playlist.TrackCount = len(f.items[playlist.ID])
		out = append(out, playlist)
	}
	return out, nil
}

func (f *fakeBackend) Counts() (library.Counts, error) {
	albums, _ := f.albums(library.AlbumQuery{})
	artists, _ := f.artists(library.ArtistQuery{})
	return library.Counts{
		Tracks:    len(f.tracks),
		Albums:    len(albums),
		Artists:   len(artists),
		Playlists: len(f.playlists),
		Sources:   len(f.sources),
	}, nil
}

func (f *fakeBackend) RecentlyPlayed(limit int) ([]library.Track, error) {
	out := make([]library.Track, 0, len(f.tracks))
	for _, track := range f.tracks {
		if !track.LastPlayedAt.IsZero() {
			out = append(out, track)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LastPlayedAt.After(out[j].LastPlayedAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeBackend) pageTracks(q library.TrackQuery) ([]library.Track, int) {
	allowed := map[string]int{}
	if q.PlaylistID != "" {
		position := map[string]int{}
		for i, id := range f.items[q.PlaylistID] {
			position[id] = i
		}
		allowed = position
	}
	out := make([]library.Track, 0, len(f.tracks))
	for _, track := range f.tracks {
		if q.Favorite && !track.IsFavorite {
			continue
		}
		if q.SourceID != "" && track.SourceID != q.SourceID {
			continue
		}
		if q.Artist != "" && track.Artist != q.Artist {
			continue
		}
		if q.Album != "" && track.Album != q.Album {
			continue
		}
		if q.Search != "" && !trackMatches(track, strings.ToLower(q.Search)) {
			continue
		}
		if q.PlaylistID != "" {
			if _, ok := allowed[track.ID]; !ok {
				continue
			}
		}
		out = append(out, track)
	}
	total := len(out)
	if q.PlaylistID != "" {
		sort.SliceStable(out, func(i, j int) bool { return allowed[out[i].ID] < allowed[out[j].ID] })
	} else {
		sort.SliceStable(out, func(i, j int) bool {
			less := sortLess(q.Sort, out[i], out[j])
			if q.Desc {
				return !less
			}
			return less
		})
	}
	if q.Offset > 0 {
		if q.Offset >= len(out) {
			return nil, total
		}
		out = out[q.Offset:]
	}
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, total
}

func sortLess(field library.SortField, a, b library.Track) bool {
	switch field {
	case library.SortArtist:
		if !strings.EqualFold(a.Artist, b.Artist) {
			return strings.ToLower(a.Artist) < strings.ToLower(b.Artist)
		}
		return a.ID < b.ID
	case library.SortAlbum:
		if !strings.EqualFold(a.Album, b.Album) {
			return strings.ToLower(a.Album) < strings.ToLower(b.Album)
		}
		return a.ID < b.ID
	case library.SortDuration:
		if a.Duration != b.Duration {
			return a.Duration < b.Duration
		}
		return a.ID < b.ID
	case library.SortAdded:
		if !a.DateAdded.Equal(b.DateAdded) {
			return a.DateAdded.Before(b.DateAdded)
		}
		return a.ID < b.ID
	default:
		if !strings.EqualFold(a.Title, b.Title) {
			return strings.ToLower(a.Title) < strings.ToLower(b.Title)
		}
		return a.ID < b.ID
	}
}

func (f *fakeBackend) albums(q library.AlbumQuery) ([]library.AlbumSummary, int) {
	byKey := map[string]*library.AlbumSummary{}
	order := make([]string, 0, 16)
	for _, track := range f.tracks {
		if q.SourceID != "" && track.SourceID != q.SourceID {
			continue
		}
		if q.Favorite && !track.IsFavorite {
			continue
		}
		if q.Artist != "" && track.Artist != q.Artist {
			continue
		}
		if q.Search != "" && !strings.Contains(strings.ToLower(track.Album+" "+track.Artist), strings.ToLower(q.Search)) {
			continue
		}
		key := track.Artist + "\x00" + track.Album
		summary, ok := byKey[key]
		if !ok {
			summary = &library.AlbumSummary{Name: track.Album, Artist: track.Artist, Year: track.Year, Cover: track.CoverArtPath}
			byKey[key] = summary
			order = append(order, key)
		}
		summary.TrackCount++
		summary.Duration += track.Duration
	}
	out := make([]library.AlbumSummary, 0, len(order))
	for _, key := range order {
		out = append(out, *byKey[key])
	}
	sort.SliceStable(out, func(i, j int) bool {
		if !strings.EqualFold(out[i].Name, out[j].Name) {
			return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
		}
		return strings.ToLower(out[i].Artist) < strings.ToLower(out[j].Artist)
	})
	return paginate(out, q.Limit, q.Offset)
}

func (f *fakeBackend) artists(q library.ArtistQuery) ([]library.ArtistSummary, int) {
	byName := map[string]*library.ArtistSummary{}
	order := make([]string, 0, 16)
	albums := map[string]map[string]bool{}
	for _, track := range f.tracks {
		if q.SourceID != "" && track.SourceID != q.SourceID {
			continue
		}
		if q.Search != "" && !strings.Contains(strings.ToLower(track.Artist), strings.ToLower(q.Search)) {
			continue
		}
		key := strings.ToLower(track.Artist)
		summary, ok := byName[key]
		if !ok {
			summary = &library.ArtistSummary{Name: track.Artist, Cover: track.CoverArtPath}
			byName[key] = summary
			albums[key] = map[string]bool{}
			order = append(order, key)
		}
		summary.TrackCount++
		summary.Duration += track.Duration
		albums[key][track.Album] = true
	}
	out := make([]library.ArtistSummary, 0, len(order))
	for _, key := range order {
		summary := *byName[key]
		summary.AlbumCount = len(albums[key])
		out = append(out, summary)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return paginate(out, q.Limit, q.Offset)
}

func paginate[T any](rows []T, limit, offset int) ([]T, int) {
	total := len(rows)
	if offset > 0 {
		if offset >= len(rows) {
			return nil, total
		}
		rows = rows[offset:]
	}
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, total
}

// fakeActions records what the view asked for.
type fakeActions struct {
	played     []library.Track
	start      int
	favorites  []string
	playlists  []string
	added      []string
	removed    []int
	moved      [][2]int
	shuffle    bool
	directory  int
	sources    []string
	revealed   int
	queue      []library.Track
	playErrors error
}

func (f *fakeActions) PlayTracks(tracks []library.Track, start int) error {
	f.played = tracks
	f.start = start
	f.queue = append(append([]library.Track{}, tracks[start:]...), tracks[:start]...)
	return f.playErrors
}
func (f *fakeActions) TogglePlayPause() error             { return nil }
func (f *fakeActions) Next() error                        { return nil }
func (f *fakeActions) Previous() error                    { return nil }
func (f *fakeActions) Seek(time.Duration) error           { return nil }
func (f *fakeActions) SetVolume(float64) error            { return nil }
func (f *fakeActions) CycleRepeat() player.RepeatMode     { return player.RepeatOne }
func (f *fakeActions) SetShuffle(on bool) bool            { f.shuffle = on; return on }
func (f *fakeActions) ChooseDirectory()                   { f.directory++ }
func (f *fakeActions) SyncSource(library.Source)          {}
func (f *fakeActions) SyncAllSources()                    {}
func (f *fakeActions) DeleteSource(source library.Source) { f.sources = append(f.sources, source.ID) }
func (f *fakeActions) RevealInFinder(library.Track)       { f.revealed++ }
func (f *fakeActions) SetFavorite(track library.Track, favorite bool) {
	if favorite {
		f.favorites = append(f.favorites, "+"+track.ID)
		return
	}
	f.favorites = append(f.favorites, "-"+track.ID)
}
func (f *fakeActions) CreatePlaylist(name string) { f.playlists = append(f.playlists, "create:"+name) }
func (f *fakeActions) RenamePlaylist(id, name string) {
	f.playlists = append(f.playlists, "rename:"+id+":"+name)
}
func (f *fakeActions) DeletePlaylist(id string) { f.playlists = append(f.playlists, "delete:"+id) }
func (f *fakeActions) AddToPlaylist(id string, ids []string) {
	f.added = append(f.added, id+"="+strings.Join(ids, ","))
}
func (f *fakeActions) RemoveFromPlaylist(id string, index int) { f.removed = append(f.removed, index) }
func (f *fakeActions) MovePlaylistItem(id string, from, to int) {
	f.moved = append(f.moved, [2]int{from, to})
}
func (f *fakeActions) Queue() []library.Track { return f.queue }
