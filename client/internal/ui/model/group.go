package model

import (
	"sort"
	"strconv"
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
	Tracks   []library.Track
	Duration time.Duration
	Cover    string // content-addressed cover file name, empty when missing
}

// TrackCount is the album's number of songs.
func (a Album) TrackCount() int { return len(a.Tracks) }

// Artist is one artist group.
type Artist struct {
	Name     string
	Key      string
	Tracks   []library.Track
	Albums   []Album
	Duration time.Duration
	Cover    string
}

// TrackCount is the artist's number of songs.
func (a Artist) TrackCount() int { return len(a.Tracks) }

type albumIndex struct {
	rev     uint64
	source  string
	favOnly bool
	albums  []Album
	built   bool
}

type artistIndex struct {
	rev     uint64
	artists []Artist
	built   bool
}

// Albums returns every album, alphabetically.
func (s *State) Albums() []Album {
	if s.albums.built && s.albums.rev == s.revision {
		return s.albums.albums
	}
	s.albums = albumIndex{rev: s.revision, albums: groupAlbums(s.tracks, FilterAll), built: true}
	return s.albums.albums
}

// FavoriteAlbums returns the albums that contain a favourite track.
func (s *State) FavoriteAlbums() []Album {
	if s.favAlbums.built && s.favAlbums.rev == s.revision {
		return s.favAlbums.albums
	}
	s.favAlbums = albumIndex{rev: s.revision, albums: groupAlbums(s.tracks, FilterFavorites), built: true}
	return s.favAlbums.albums
}

// Artists returns every artist, alphabetically.
func (s *State) Artists() []Artist {
	if s.artists.built && s.artists.rev == s.revision {
		return s.artists.artists
	}
	s.artists = artistIndex{rev: s.revision, artists: groupArtists(s.tracks), built: true}
	return s.artists.artists
}

func groupAlbums(tracks []library.Track, filter Filter) []Album {
	byKey := map[string]*Album{}
	order := make([]string, 0, 64)
	for _, track := range tracks {
		if filter == FilterFavorites && !track.IsFavorite {
			continue
		}
		name := strings.TrimSpace(track.Album)
		if name == "" {
			name = "未知专辑"
		}
		artist := strings.TrimSpace(track.Artist)
		if artist == "" {
			artist = "未知艺术家"
		}
		key := artist + "\x00" + name
		album, ok := byKey[key]
		if !ok {
			album = &Album{Key: key, Name: name, Artist: artist}
			byKey[key] = album
			order = append(order, key)
		}
		album.Tracks = append(album.Tracks, track)
		album.Duration += track.Duration
		if album.Year == 0 {
			album.Year = track.Year
		}
		if album.Cover == "" {
			album.Cover = track.CoverArtPath
		}
	}
	out := make([]Album, 0, len(order))
	for _, key := range order {
		album := *byKey[key]
		sort.SliceStable(album.Tracks, func(i, j int) bool {
			a, b := album.Tracks[i], album.Tracks[j]
			if a.DiscNumber != b.DiscNumber {
				return a.DiscNumber < b.DiscNumber
			}
			if a.TrackNumber != b.TrackNumber && a.TrackNumber > 0 && b.TrackNumber > 0 {
				return a.TrackNumber < b.TrackNumber
			}
			return fold(a.Title) < fold(b.Title)
		})
		out = append(out, album)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if fold(out[i].Name) == fold(out[j].Name) {
			return fold(out[i].Artist) < fold(out[j].Artist)
		}
		return fold(out[i].Name) < fold(out[j].Name)
	})
	return out
}

func groupArtists(tracks []library.Track) []Artist {
	byName := map[string]*Artist{}
	order := make([]string, 0, 32)
	for _, track := range tracks {
		name := strings.TrimSpace(track.Artist)
		if name == "" {
			name = "未知艺术家"
		}
		key := fold(name)
		artist, ok := byName[key]
		if !ok {
			artist = &Artist{Name: name, Key: key}
			byName[key] = artist
			order = append(order, key)
		}
		artist.Tracks = append(artist.Tracks, track)
		artist.Duration += track.Duration
		if artist.Cover == "" {
			artist.Cover = track.CoverArtPath
		}
	}
	out := make([]Artist, 0, len(order))
	for _, key := range order {
		artist := *byName[key]
		sort.SliceStable(artist.Tracks, func(i, j int) bool {
			a, b := artist.Tracks[i], artist.Tracks[j]
			if fold(a.Album) != fold(b.Album) {
				return fold(a.Album) < fold(b.Album)
			}
			return fold(a.Title) < fold(b.Title)
		})
		artist.Albums = albumsOf(artist.Tracks)
		out = append(out, artist)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Name == "未知艺术家" {
			return false
		}
		if out[j].Name == "未知艺术家" {
			return true
		}
		return fold(out[i].Name) < fold(out[j].Name)
	})
	return out
}

func albumsOf(tracks []library.Track) []Album {
	byKey := map[string]*Album{}
	order := []string{}
	for _, track := range tracks {
		name := strings.TrimSpace(track.Album)
		if name == "" {
			name = "未知专辑"
		}
		key := fold(name)
		album, ok := byKey[key]
		if !ok {
			album = &Album{Key: key, Name: name, Artist: track.Artist}
			byKey[key] = album
			order = append(order, key)
		}
		album.Tracks = append(album.Tracks, track)
		album.Duration += track.Duration
		if album.Year == 0 {
			album.Year = track.Year
		}
		if album.Cover == "" {
			album.Cover = track.CoverArtPath
		}
	}
	out := make([]Album, 0, len(order))
	for _, key := range order {
		out = append(out, *byKey[key])
	}
	sort.SliceStable(out, func(i, j int) bool { return fold(out[i].Name) < fold(out[j].Name) })
	return out
}

// ArtistByName finds an artist group by display name.
func (s *State) ArtistByName(name string) *Artist {
	key := fold(name)
	for _, artist := range s.Artists() {
		if artist.Key == key || artist.Name == name {
			copy := artist
			return &copy
		}
	}
	return nil
}

// TracksOf returns all tracks of a source (the source detail page).
func (s *State) TracksOf(sourceID string) []library.Track {
	out := make([]library.Track, 0, 16)
	for _, track := range s.tracks {
		if track.SourceID == sourceID {
			out = append(out, track)
		}
	}
	return out
}

// FormatCount is "N 首"/"N 张".
func FormatCount(n int, unit string) string { return strconv.Itoa(n) + " " + unit }

// Playlist is a UI row for the playlists page. The kernel has no playlist
// queries yet, so Playlists is always empty in this milestone and the page
// says why instead of inventing rows.
type Playlist struct {
	ID    string
	Name  string
	Count int
}

// Playlists returns the playlists the kernel exposes. It is empty until the
// library package grows playlist queries (recorded in the milestone record).
func (s *State) Playlists() []Playlist { return nil }

// LibraryCounts is the settings page's summary.
type LibraryCounts struct {
	Tracks    int
	Albums    int
	Artists   int
	Playlists int
	Sources   int
}

// Counts summarises the library for settings.
func (s *State) Counts() LibraryCounts {
	return LibraryCounts{
		Tracks:    len(s.tracks),
		Albums:    len(s.Albums()),
		Artists:   len(s.Artists()),
		Playlists: len(s.Playlists()),
		Sources:   len(s.sources),
	}
}

// RecentlyPlayed returns the tracks played most recently, newest first.
func (s *State) RecentlyPlayed(limit int) []library.Track {
	out := make([]library.Track, 0, len(s.tracks))
	for _, track := range s.tracks {
		if !track.LastPlayedAt.IsZero() {
			out = append(out, track)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LastPlayedAt.After(out[j].LastPlayedAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}
