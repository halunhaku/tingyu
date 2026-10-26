package model

import (
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// PaletteItem kinds.
const (
	PaletteSong    = "song"
	PaletteAlbum   = "album"
	PaletteArtist  = "artist"
	PaletteCommand = "command"
)

// PaletteItem is one row of the command palette.
type PaletteItem struct {
	Group    string
	Label    string
	Detail   string
	Shortcut string
	Kind     string
	Track    library.Track
	Album    Album
	Artist   Artist
	Command  string
}

// PaletteState is the Cmd+K palette (its own text, so it never disturbs the
// sidebar's or the search page's query).
type PaletteState struct {
	Open     bool
	Input    string
	Query    string
	pending  time.Time
	Selected int
	Items    []PaletteItem
}

// Command is one fixed palette shortcut.
type Command struct {
	ID       string
	Label    string
	Shortcut string
}

// Commands lists the palette's shortcut entries, in the Flutter order.
var Commands = []Command{
	{"media.toggle", "暂停 / 播放", "Space"},
	{"media.next", "下一首", "⌘→"},
	{"media.prev", "上一首", "⌘←"},
	{"go.stage", "打开播放舞台", "⌘⇧P"},
	{"go.library", "曲库", "⌘1"},
	{"go.favorites", "收藏", "⌘3"},
	{"go.sources", "音乐来源", "⌘4"},
	{"go.settings", "设置", "⌘,"},
	{"go.queue", "播放队列", "⌘U"},
	{"go.lyrics", "歌词", "⌘L"},
	{"action.newPlaylist", "新建歌单", "⌘N"},
}

// OpenPalette opens the palette with a fresh query.
func (s *State) OpenPalette() {
	s.palette.Open = true
	s.palette.Input = ""
	s.palette.Query = ""
	s.palette.Selected = 0
	s.palette.pending = time.Time{}
	s.buildPalette()
}

// ClosePalette closes it.
func (s *State) ClosePalette() { s.palette.Open = false }

// Palette returns the palette state.
func (s *State) Palette() *PaletteState { return &s.palette }

// OnInput starts the palette's 250 ms debounce.
func (p *PaletteState) OnInput(now time.Time) { p.pending = now }

// Pending reports a debounce clock still running.
func (p *PaletteState) Pending() bool { return !p.pending.IsZero() }

// Tick applies the debounced palette query.
func (p *PaletteState) Tick(now time.Time, s *State) {
	if !p.Open {
		return
	}
	if !p.pending.IsZero() && now.Sub(p.pending) >= SearchDebounceTime {
		p.pending = time.Time{}
		p.Query = strings.TrimSpace(p.Input)
		p.Selected = 0
		s.buildPalette()
	}
}

// Move moves the selection by delta, wrapping around the items.
func (p *PaletteState) Move(delta int) {
	if len(p.Items) == 0 {
		return
	}
	p.Selected = (p.Selected + delta + len(p.Items)) % len(p.Items)
}

func (s *State) buildPalette() {
	p := &s.palette
	p.Items = p.Items[:0]
	query := strings.ToLower(strings.TrimSpace(p.Query))
	if query == "" {
		for _, track := range s.RecentlyPlayed(PreviewSize) {
			p.Items = append(p.Items, songItem("最近播放", track))
		}
	} else if s.backend != nil {
		// Each group is one LIMIT query; the palette never filters the
		// library in memory (plan §2.5).
		if songs, err := s.backend.TracksPage(library.TrackQuery{
			Search: query, Sort: library.SortTitle, Limit: PreviewSize,
		}); err == nil {
			for _, track := range songs {
				p.Items = append(p.Items, songItem("歌曲", track))
			}
		}
		if albums, err := s.backend.AlbumsPage(library.AlbumQuery{
			Search: query, Limit: PreviewSize,
		}); err == nil {
			for _, summary := range albums {
				album := albumFromSummary(summary)
				p.Items = append(p.Items, PaletteItem{
					Group: "专辑", Label: album.Name, Detail: album.Artist,
					Kind: PaletteAlbum, Album: album,
				})
			}
		}
		if artists, err := s.backend.ArtistsPage(library.ArtistQuery{
			Search: query, Limit: PreviewSize,
		}); err == nil {
			for _, summary := range artists {
				artist := artistFromSummary(summary)
				p.Items = append(p.Items, PaletteItem{
					Group: "艺术家", Label: artist.Name,
					Detail: trackCountLabel(artist.Count),
					Kind:   PaletteArtist, Artist: artist,
				})
			}
		}
	}
	for _, command := range Commands {
		if query != "" && !strings.Contains(fold(command.Label), query) {
			continue
		}
		p.Items = append(p.Items, PaletteItem{
			Group: "快捷入口", Label: command.Label, Shortcut: command.Shortcut,
			Kind: PaletteCommand, Command: command.ID,
		})
	}
	if p.Selected >= len(p.Items) {
		p.Selected = max(0, len(p.Items)-1)
	}
}

func songItem(group string, track library.Track) PaletteItem {
	detail := track.Artist
	if track.Album != "" {
		detail += " · " + track.Album
	}
	return PaletteItem{Group: group, Label: track.Title, Detail: detail, Kind: PaletteSong, Track: track}
}

// ActivatePalette runs the selected item and closes the palette.
func (s *State) ActivatePalette() {
	p := &s.palette
	if p.Selected < 0 || p.Selected >= len(p.Items) {
		return
	}
	item := p.Items[p.Selected]
	switch item.Kind {
	case PaletteSong:
		s.closeAndPlay(item.Track)
	case PaletteAlbum:
		s.ClosePalette()
		s.OpenAlbum(item.Album)
	case PaletteArtist:
		s.ClosePalette()
		s.OpenArtist(item.Artist)
	case PaletteCommand:
		s.ClosePalette()
		s.RunCommand(item.Command)
	}
}

// RunCommand runs a palette shortcut by ID.
func (s *State) RunCommand(id string) {
	switch id {
	case "media.toggle":
		if s.actions != nil {
			_ = s.actions.TogglePlayPause()
		}
	case "media.next":
		if s.actions != nil {
			_ = s.actions.Next()
		}
	case "media.prev":
		if s.actions != nil {
			_ = s.actions.Previous()
		}
	case "go.stage":
		s.OpenStage()
	case "go.library":
		s.OpenPage(PageLibrary)
	case "go.favorites":
		s.OpenPage(PageFavorites)
	case "go.sources":
		s.OpenPage(PageSources)
	case "go.settings":
		s.OpenPage(PageSettings)
	case "go.queue":
		s.OpenPage(PageQueue)
	case "go.lyrics":
		s.OpenPage(PageLyrics)
	case "action.newPlaylist":
		s.BeginCreatePlaylist()
		s.OpenPage(PagePlaylists)
	}
}

func (s *State) closeAndPlay(track library.Track) {
	s.ClosePalette()
	if s.actions != nil {
		_ = s.actions.PlayTracks([]library.Track{track}, 0)
	}
}
