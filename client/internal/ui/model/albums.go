package model

// Albums, artists and playlists as the pages show them. Each list is one SQL
// aggregate page: the kernel groups in SQL and returns summaries, and a
// detail page asks for that album's or artist's rows when it opens. Nothing
// here holds a whole table (plan §2.5), and nothing groups in Go except the
// playlists table, which is bounded by how many playlists the user created.

import (
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// Album is one artist+album group. The key is stable across refreshes.
type Album struct {
	Key      string
	Name     string
	Artist   string
	Year     int
	Count    int
	Duration time.Duration
	Cover    string // content-addressed cover file name, empty when missing
}

// TrackCount is the album's number of songs.
func (a Album) TrackCount() int { return a.Count }

// Artist is one artist group.
type Artist struct {
	Key      string
	Name     string
	Count    int
	Albums   int
	Duration time.Duration
	Cover    string
}

// TrackCount is the artist's number of songs.
func (a Artist) TrackCount() int { return a.Count }

// AlbumDetail is one album page: its row and its tracks (a second query,
// taken when the album opens).
type AlbumDetail struct {
	Album  Album
	Tracks []library.Track
}

// ArtistDetail is one artist page: the summary, the tracks shown (20 until
// expanded) and the artist's albums.
type ArtistDetail struct {
	Artist Artist
	Tracks []library.Track
	Albums AlbumList
}

// PlaylistDetail is one playlist page: the row and its items in saved order.
type PlaylistDetail struct {
	Playlist library.Playlist
	Tracks   TrackList
}

func albumFromSummary(summary library.AlbumSummary) Album {
	return Album{
		Key:      strings.ToLower(summary.Artist) + "\x00" + strings.ToLower(summary.Name),
		Name:     summary.Name,
		Artist:   summary.Artist,
		Year:     summary.Year,
		Count:    summary.TrackCount,
		Duration: summary.Duration,
		Cover:    summary.Cover,
	}
}

func artistFromSummary(summary library.ArtistSummary) Artist {
	return Artist{
		Key:      strings.ToLower(summary.Name),
		Name:     summary.Name,
		Count:    summary.TrackCount,
		Albums:   summary.AlbumCount,
		Duration: summary.Duration,
		Cover:    summary.Cover,
	}
}

// AlbumList is one paged album aggregate.
type AlbumList struct {
	query library.AlbumQuery

	pages   int
	more    bool
	loading bool
	done    bool
	total   int
	items   []Album

	built   string
	request string
	pending <-chan library.AlbumPage
	err     string
}

// Configure changes the album filter. A different filter returns the list to
// its first page, as a page change does.
func (l *AlbumList) Configure(query library.AlbumQuery) {
	if l.key(query) != l.key(l.query) {
		l.pages = 1
		l.more = false
		l.items = nil
		l.built = ""
		l.request = ""
		l.total = 0
		l.done = false
	}
	l.query = query
}

func (l *AlbumList) key(q library.AlbumQuery) string {
	return q.SourceID + "|" + q.Artist + "|" + boolKey(q.Favorite) + "|" + q.Search
}

func (l *AlbumList) queryFor() library.AlbumQuery {
	q := l.query
	q.Limit = l.pages * AlbumPageSize
	q.Offset = 0
	return q
}

// Tick applies an arrived page and asks for a new one when the rows held do
// not match the current key.
func (l *AlbumList) Tick(load Backend, revision, epoch uint64) {
	if l.pages == 0 {
		l.pages = 1
	}
	l.poll()
	l.step()
	if load == nil {
		return
	}
	key := l.key(l.query) + "#" + itoa(revision) + "." + itoa(epoch) + "." + itoa(uint64(l.pages))
	if key == l.built {
		return
	}
	if l.pending != nil {
		if l.request == key {
			return
		}
		l.pending = nil
		l.loading = false
	}
	l.request = key
	l.loading = true
	l.pending = load.LoadAlbums(l.queryFor())
	l.poll()
}

func (l *AlbumList) poll() {
	if l.pending == nil {
		return
	}
	select {
	case page := <-l.pending:
		l.pending = nil
		l.loading = false
		if page.Err != nil {
			l.err = page.Err.Error()
			l.built = l.request
			return
		}
		l.err = ""
		l.items = make([]Album, 0, len(page.Rows))
		for _, summary := range page.Rows {
			l.items = append(l.items, albumFromSummary(summary))
		}
		l.total = page.Total
		l.done = len(l.items) == 0 || len(l.items) >= l.total
		if pages := (len(l.items) + AlbumPageSize - 1) / AlbumPageSize; pages > 0 {
			l.pages = pages
		}
		l.built = l.request
	default:
	}
}

func (l *AlbumList) step() {
	if !l.more {
		return
	}
	l.more = false
	if l.done {
		return
	}
	l.pages++
}

// Items are the albums loaded so far.
func (l *AlbumList) Items() []Album { return l.items }

// Total is the true number of albums.
func (l *AlbumList) Total() int { return l.total }

// Done reports that no more albums exist.
func (l *AlbumList) Done() bool { return l.done }

// Loading reports an album page in flight.
func (l *AlbumList) Loading() bool { return l.loading || l.more }

// Err is the last request's failure, if any.
func (l *AlbumList) Err() string { return l.err }

func (l *AlbumList) settled(revision, epoch uint64) bool {
	key := l.key(l.query) + "#" + itoa(revision) + "." + itoa(epoch) + "." + itoa(uint64(l.pages))
	return l.pending == nil && l.built != "" && l.built == key
}

// RequestMore asks for one more page.
func (l *AlbumList) RequestMore() {
	if l.more || l.loading || l.done || l.total == 0 {
		return
	}
	if l.pages*AlbumPageSize >= l.total {
		l.done = true
		return
	}
	l.more = true
}

// ArtistList is one paged artist aggregate.
type ArtistList struct {
	query library.ArtistQuery

	pages   int
	more    bool
	loading bool
	done    bool
	total   int
	items   []Artist

	built   string
	request string
	pending <-chan library.ArtistPage
	err     string
}

// Configure changes the artist filter.
func (l *ArtistList) Configure(query library.ArtistQuery) {
	if l.key(query) != l.key(l.query) {
		l.pages = 1
		l.more = false
		l.items = nil
		l.built = ""
		l.request = ""
		l.total = 0
		l.done = false
	}
	l.query = query
}

func (l *ArtistList) key(q library.ArtistQuery) string {
	return q.SourceID + "|" + q.Search
}

func (l *ArtistList) queryFor() library.ArtistQuery {
	q := l.query
	q.Limit = l.pages * ArtistPageSize
	q.Offset = 0
	return q
}

// Tick applies an arrived page and asks for a new one when needed.
func (l *ArtistList) Tick(load Backend, revision, epoch uint64) {
	if l.pages == 0 {
		l.pages = 1
	}
	l.poll()
	l.step()
	if load == nil {
		return
	}
	key := l.key(l.query) + "#" + itoa(revision) + "." + itoa(epoch) + "." + itoa(uint64(l.pages))
	if key == l.built {
		return
	}
	if l.pending != nil {
		if l.request == key {
			return
		}
		l.pending = nil
		l.loading = false
	}
	l.request = key
	l.loading = true
	l.pending = load.LoadArtists(l.queryFor())
	l.poll()
}

func (l *ArtistList) poll() {
	if l.pending == nil {
		return
	}
	select {
	case page := <-l.pending:
		l.pending = nil
		l.loading = false
		if page.Err != nil {
			l.err = page.Err.Error()
			l.built = l.request
			return
		}
		l.err = ""
		l.items = make([]Artist, 0, len(page.Rows))
		for _, summary := range page.Rows {
			l.items = append(l.items, artistFromSummary(summary))
		}
		l.total = page.Total
		l.done = len(l.items) == 0 || len(l.items) >= l.total
		if pages := (len(l.items) + ArtistPageSize - 1) / ArtistPageSize; pages > 0 {
			l.pages = pages
		}
		l.built = l.request
	default:
	}
}

func (l *ArtistList) step() {
	if !l.more {
		return
	}
	l.more = false
	if l.done {
		return
	}
	l.pages++
}

// Items are the artists loaded so far.
func (l *ArtistList) Items() []Artist { return l.items }

// Total is the true number of artists.
func (l *ArtistList) Total() int { return l.total }

// Done reports that no more artists exist.
func (l *ArtistList) Done() bool { return l.done }

// Loading reports an artist page in flight.
func (l *ArtistList) Loading() bool { return l.loading || l.more }

// Err is the last request's failure, if any.
func (l *ArtistList) Err() string { return l.err }

func (l *ArtistList) settled(revision, epoch uint64) bool {
	key := l.key(l.query) + "#" + itoa(revision) + "." + itoa(epoch) + "." + itoa(uint64(l.pages))
	return l.pending == nil && l.built != "" && l.built == key
}

// RequestMore asks for one more page.
func (l *ArtistList) RequestMore() {
	if l.more || l.loading || l.done || l.total == 0 {
		return
	}
	if l.pages*ArtistPageSize >= l.total {
		l.done = true
		return
	}
	l.more = true
}

// Albums returns the albums page's list.
func (s *State) Albums() *AlbumList { return &s.albumList }

// FavoriteAlbums returns the albums that contain a favourite track.
func (s *State) FavoriteAlbums() *AlbumList { return &s.favAlbums }

// Artists returns the artists page's list.
func (s *State) Artists() *ArtistList { return &s.artistList }

// AlbumTracks returns one album's tracks in disc/track order (the album card's
// play button and the detail page).
func (s *State) AlbumTracks(album Album) []library.Track {
	if s.backend == nil {
		return nil
	}
	if detail := s.albumDetail; detail != nil && detail.Album.Key == album.Key && len(detail.Tracks) > 0 {
		return detail.Tracks
	}
	tracks, err := s.backend.TracksPage(library.TrackQuery{
		Artist: album.Artist, Album: album.Name, Sort: library.SortAlbum,
	})
	if err != nil {
		s.failure = "无法读取专辑曲目：" + err.Error()
		return nil
	}
	return tracks
}

// ArtistTracks returns every track of an artist in album order (播放全部 on an
// artist row, and the detail page's rows).
func (s *State) ArtistTracks(artist Artist) []library.Track {
	if s.backend == nil {
		return nil
	}
	tracks, err := s.backend.TracksPage(library.TrackQuery{Artist: artist.Name, Sort: library.SortAlbum})
	if err != nil {
		s.failure = "无法读取艺术家曲目：" + err.Error()
		return nil
	}
	return tracks
}

// ArtistByName finds an artist group by display name (the album page's
// 「在艺人中查看」).
func (s *State) ArtistByName(name string) *Artist {
	if s.backend == nil {
		return nil
	}
	page, err := s.backend.ArtistsPage(library.ArtistQuery{Search: name, Limit: 50})
	if err != nil {
		return nil
	}
	for _, summary := range page {
		if strings.EqualFold(summary.Name, name) {
			artist := artistFromSummary(summary)
			return &artist
		}
	}
	return nil
}

// FormatCount is "N 首"/"N 张".
func FormatCount(n int, unit string) string { return itoa(uint64(n)) + " " + unit }

// RecentlyPlayed returns the tracks played most recently, newest first.
func (s *State) RecentlyPlayed(limit int) []library.Track {
	if s.backend == nil {
		return nil
	}
	tracks, err := s.backend.RecentlyPlayed(limit)
	if err != nil {
		return nil
	}
	return tracks
}
