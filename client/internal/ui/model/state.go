// Package model is the view state: what the pages show and the rules that
// turn the library's SQL reads into lists, search results and pages.
//
// Every list comes from SQL through Backend: a page of tracks is
// LIMIT/OFFSET, an album or artist list is one GROUP BY, and nothing here
// holds the whole tracks table (plan §2.5). The model still owns no database
// handle: the app hands it the library's read side and its write counter, so
// every rule below is a function of what the kernel reports.
package model

import (
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// Page constants for the session state machine.
const (
	PageLibrary        = "library"
	PageFavorites      = "favorites"
	PageAlbums         = "albums"
	PageArtists        = "artists"
	PagePlaylists      = "playlists"
	PagePlaylistDetail = "playlist"
	PageSearch         = "search"
	PageSettings       = "settings"
	PageSources        = "sources"
	PageStage          = "stage"
	PageQueue          = "queue"
	PageLyrics         = "lyrics"
	PageAlbumDetail    = "album"
	PageArtistDetail   = "artist"
	PageOnboarding     = "onboarding"
)

// PageSize is the library page size (plan §2.5 / providers.dart:498).
const PageSize = 40

// AlbumPageSize is how many albums one grid page holds.
const AlbumPageSize = 60

// ArtistPageSize is how many artists one list page holds.
const ArtistPageSize = 40

// PreviewSize is how many rows each search group previews (providers.dart:501).
const PreviewSize = 5

// Backend is the library's read side. Paged lists are asynchronous: a page
// request is a SQL round trip and must not run inside a frame, so the kernel
// answers it on its own goroutine and the model polls once per frame.
type Backend interface {
	// Paged lists, answered off the UI thread.
	LoadTracks(q library.TrackQuery) <-chan library.TrackPage
	LoadAlbums(q library.AlbumQuery) <-chan library.AlbumPage
	LoadArtists(q library.ArtistQuery) <-chan library.ArtistPage

	// Requests that are small or explicit: 播放全部, an album's tracks, the
	// search previews, the counts.
	TracksPage(q library.TrackQuery) ([]library.Track, error)
	AlbumsPage(q library.AlbumQuery) ([]library.AlbumSummary, error)
	ArtistsPage(q library.ArtistQuery) ([]library.ArtistSummary, error)
	CountTracks(q library.TrackQuery) (int, error)
	CountAlbums(q library.AlbumQuery) (int, error)
	CountArtists(q library.ArtistQuery) (int, error)
	Playlists() ([]library.Playlist, error)
	Sources() ([]library.Source, error)
	Counts() (library.Counts, error)
	RecentlyPlayed(limit int) ([]library.Track, error)
}

// Live is the library's write counter, read once per frame. Any write — a
// scan, a favourite, a playlist edit, a play count — bumps it, and every list
// whose key includes the revision refreshes (plan §2.5's refresh contract).
type Live interface {
	Revision() uint64
	RowRevision(id string) uint64
}

// Settings are the three appearance preferences of settings.json. The keys and
// values are exactly the Flutter client's (data/settings_store.dart), so the
// two clients share one file.
type Settings struct {
	ThemeMode string // system / light / dark
	Density   string // comfortable / compact
	CoverTint bool
}

// DefaultSettings is AppPreferences.defaults.
func DefaultSettings() Settings {
	return Settings{ThemeMode: "system", Density: "comfortable", CoverTint: true}
}

// Dark resolves the theme mode against the system's appearance.
func (s Settings) Dark(systemDark bool) bool {
	switch s.ThemeMode {
	case "light":
		return false
	case "dark":
		return true
	default:
		return systemDark
	}
}

// Compact reports whether the compact density is chosen.
func (s Settings) Compact() bool { return s.Density == "compact" }

// ScanState is what the shell shows about a scan. SourceID/SourceName are set
// for remote syncs so the source card can show its own progress and a cancel
// button (M3).
type ScanState struct {
	Running    bool
	Done       int
	Total      int
	Path       string
	Status     string
	Error      string
	SourceID   string
	SourceName string
}

// Actions are the side effects the view asks the app to perform. Every method
// is a capability the kernel now has: the writes land in library.sqlite and
// come back through the revision, never as a local-only change.
type Actions interface {
	PlayTracks(tracks []library.Track, start int) error
	TogglePlayPause() error
	Next() error
	Previous() error
	Seek(position time.Duration) error
	SetVolume(volume float64) error
	CycleRepeat() player.RepeatMode
	SetShuffle(on bool) bool
	ChooseDirectory()
	SyncSource(source library.Source)
	SyncAllSources()
	DeleteSource(source library.Source)
	RevealInFinder(track library.Track)
	SetFavorite(track library.Track, favorite bool)
	CreatePlaylist(name string)
	RenamePlaylist(id, name string)
	DeletePlaylist(id string)
	AddToPlaylist(playlistID string, trackIDs []string)
	RemoveFromPlaylist(playlistID string, index int)
	MovePlaylistItem(playlistID string, from, to int)
	Queue() []library.Track
}

// StageState is the full-window now-playing page and its side panel.
type StageState struct {
	Open  bool
	Panel int // 0 lyrics, 1 queue
}

// State is everything a frame reads. The app mutates it on the UI thread (via
// Window.Update); background workers never touch it.
type State struct {
	actions         Actions
	metadataActions MetadataActions

	backend Backend
	live    Live

	revision uint64
	epoch    uint64 // bumped by Invalidate, so lists refresh with it
	stale    bool
	sources  []library.Source

	dbPath    string
	dataDir   string
	coversDir string
	writable  bool
	loadErr   error

	scan    ScanState
	status  string
	failure string

	sourceForm   SourceForm
	sourceErrors map[string]string

	player   player.Update
	volume   float64
	repeat   player.RepeatMode
	shuffle  bool
	queue    []library.Track
	queueIdx int

	settings     Settings
	settingsPath string
	settingsErr  string

	library    TrackList
	favorites  TrackList
	albumList  AlbumList
	favAlbums  AlbumList
	artistList ArtistList

	favoriteView   int // 0 songs, 1 albums
	albumDetail    *AlbumDetail
	artistDetail   *ArtistDetail
	artistExpanded bool

	playlists      []library.Playlist
	playlistDetail *PlaylistDetail
	playlistEdit   *playlistEdit

	search       SearchState
	palette      PaletteState
	sidebarQuery string
	searchFocus  bool

	page            string
	back            []string
	stage           StageState
	settingsSection int
	onboardingDone  bool

	notice   string
	noticeAt time.Time
	now      time.Time

	counts      library.Counts
	countsAt    time.Time
	playlistsAt time.Time

	albumsList  ui.GridState
	artistsList ui.ListState
	queueList   ui.ListState
	lyricsList  ui.ListState
	detailList  ui.ListState

	lyrics    lyricsCache
	covers    CoverCache
	palettes  paletteCache
	transient map[string]any

	// M5: the enrichment panel, the AI fallback settings and the match dialog
	// (see enrichment.go).
	enrichment EnrichmentView
	match      MatchState
	ai         metadata.AISettings
	aiError    string
	lyricsMode int
	logf       func(format string, args ...any)
}

// New builds the state from the library's read side.
func New(backend Backend, live Live, dbPath string, loadErr error) *State {
	s := &State{
		backend:  backend,
		live:     live,
		dbPath:   dbPath,
		loadErr:  loadErr,
		volume:   1,
		repeat:   player.RepeatAll,
		settings: DefaultSettings(),
		page:     PageLibrary,
		now:      time.Now(),
	}
	s.library.Configure(FilterAll, SortTitle, true, "")
	s.favorites.Configure(FilterFavorites, SortTitle, true, "")
	s.albumList.Configure(library.AlbumQuery{})
	s.favAlbums.Configure(library.AlbumQuery{Favorite: true})
	s.artistList.Configure(library.ArtistQuery{})
	if live != nil {
		for _, list := range s.lists() {
			list.SetRowRevision(live.RowRevision)
		}
	}
	s.library.bind()
	s.favorites.bind()
	s.search.songs.bind()
	s.library.selected = -1
	s.favorites.selected = -1
	s.palette.Selected = 0
	return s
}

// lists are every track list the state owns.
func (s *State) lists() []*TrackList {
	out := []*TrackList{&s.library, &s.favorites, &s.search.songs}
	if s.playlistDetail != nil {
		out = append(out, &s.playlistDetail.Tracks)
	}
	return out
}

// SetActions installs the callbacks.
func (s *State) SetActions(a Actions) { s.actions = a }

// SetLogf installs a logger for the choices the model makes that the app's log
// should show (a palette that fell back to the neutral gradient, for example).
func (s *State) SetLogf(logf func(format string, args ...any)) { s.logf = logf }

// Actions returns the installed callbacks (nil in tests that need none).
func (s *State) Actions() Actions { return s.actions }

// ConfigureDataDir records where settings.json lives and loads it. Writable is
// false in a development build that did not point TINGYU_DATA_DIR at a copy,
// and then settings only live for the process: the production directory is
// never written (plan §8.1 rule 2).
func (s *State) ConfigureDataDir(dataDir string, writable bool) {
	s.dataDir = dataDir
	s.writable = writable
	if dataDir == "" {
		return
	}
	settings, corrupt, err := LoadSettings(dataDir)
	s.settings = settings
	s.settingsPath = dataDir
	if corrupt {
		s.settingsErr = "settings.json 损坏，原文件保留未覆盖；当前使用默认外观"
	}
	if err != nil {
		s.settingsErr = err.Error()
	}
}

// SetCoversDir is where content-addressed cover files live.
func (s *State) SetCoversDir(dir string) {
	s.coversDir = dir
	s.covers.SetDir(dir)
	s.setPaletteDir(dir)
}

// SetSources replaces the source list.
func (s *State) SetSources(sources []library.Source) { s.sources = sources }

// Settled reports that every list holds the rows its current query asks for and
// no page is in flight. The window's acceptance harness waits on it; the UI
// itself never needs it (an unsettled list just shows its loading state).
func (s *State) Settled() bool {
	if s.backend == nil {
		return true
	}
	for _, list := range s.lists() {
		if !list.settled(s.revision, s.epoch) {
			return false
		}
	}
	if !s.albumList.settled(s.revision, s.epoch) || !s.favAlbums.settled(s.revision, s.epoch) {
		return false
	}
	if !s.artistList.settled(s.revision, s.epoch) {
		return false
	}
	if !s.search.albums.settled(s.revision, s.epoch) || !s.search.artists.settled(s.revision, s.epoch) {
		return false
	}
	if s.artistDetail != nil && !s.artistDetail.Albums.settled(s.revision, s.epoch) {
		return false
	}
	return true
}

// Invalidate forces the next frame to re-read the library even if the
// revision looks unchanged (the app uses it after a write it performed
// itself).
func (s *State) Invalidate() { s.stale = true }

// Revision is the library revision the lists are keyed by.
func (s *State) Revision() uint64 { return s.revision }

// Version is the About page's version line.
const Version = "内核数据 · 0.5.0-dev"

// Sources returns the sources.
func (s *State) Sources() []library.Source { return s.sources }

// SetPlayer applies a playback update.
func (s *State) SetPlayer(update player.Update) {
	s.player = update
	if update.Failure != nil {
		s.failure = update.Failure.Message
	} else if update.Snapshot.Playing {
		s.failure = ""
	}
	s.repeat = update.Repeat
	s.shuffle = update.Shuffle
	if update.Snapshot.Volume > 0 {
		s.volume = update.Snapshot.Volume
	}
	s.queueIdx = update.Index
}

// SetQueue records the queue the player was given (the UI cannot ask the
// controller for it every frame without copying ten thousand tracks).
func (s *State) SetQueue(queue []library.Track, index int) {
	s.queue = append(s.queue[:0], queue...)
	s.queueIdx = index
}

// Queue returns the queue shown in the queue panel.
func (s *State) Queue() []library.Track { return s.queue }

// QueueIndex returns the current queue index.
func (s *State) QueueIndex() int { return s.queueIdx }

// SetScan updates the scan panel.
func (s *State) SetScan(scan ScanState) { s.scan = scan }

// Scan returns the scan state.
func (s *State) Scan() ScanState { return s.scan }

// pageError is the first failed page request among the lists.
func (s *State) pageError() string {
	for _, list := range s.lists() {
		if message := list.Err(); message != "" {
			return "无法读取曲目：" + message
		}
	}
	if message := s.albumList.Err(); message != "" {
		return "无法读取专辑：" + message
	}
	if message := s.artistList.Err(); message != "" {
		return "无法读取艺术家：" + message
	}
	return ""
}

// SetStatus sets the line beside a page title.
func (s *State) SetStatus(status string) { s.status = status }

// Status returns that line.
func (s *State) Status() string { return s.status }

// SetError sets the error line.
func (s *State) SetError(message string) { s.failure = message }

// Error returns the error line.
func (s *State) Error() string { return s.failure }

// LoadErr is why the library could not be opened, if it could not.
func (s *State) LoadErr() error { return s.loadErr }

// DBPath is the library file shown in settings.
func (s *State) DBPath() string { return s.dbPath }

// DataDir is the app data directory.
func (s *State) DataDir() string { return s.dataDir }

// CoversDir is the cover cache directory.
func (s *State) CoversDir() string { return s.coversDir }

// Writable reports whether the library copy may be written.
func (s *State) Writable() bool { return s.writable }

// Player returns the last playback update.
func (s *State) Player() player.Update { return s.player }

// Volume returns the volume the transport shows.
func (s *State) Volume() float64 { return s.volume }

// SetVolume records a new volume locally.
func (s *State) SetVolume(v float64) { s.volume = v }

// Repeat returns the repeat mode.
func (s *State) Repeat() player.RepeatMode { return s.repeat }

// SetRepeat records a repeat mode.
func (s *State) SetRepeat(mode player.RepeatMode) { s.repeat = mode }

// Shuffle reports whether the play queue is shuffled.
func (s *State) Shuffle() bool { return s.shuffle }

// ToggleShuffle asks the controller to flip shuffle and records the result.
func (s *State) ToggleShuffle() {
	if a := s.actions; a != nil {
		s.shuffle = a.SetShuffle(!s.shuffle)
		return
	}
	s.shuffle = !s.shuffle
}

// Settings returns the appearance preferences.
func (s *State) Settings() Settings { return s.settings }

// SettingsErr is a settings load/save problem.
func (s *State) SettingsErr() string { return s.settingsErr }

// SetSettings applies and persists preferences. Persistence is refused in a
// read-only build, with a notice instead of a silent lie.
func (s *State) SetSettings(next Settings) {
	s.settings = next
	if s.settingsPath == "" {
		return
	}
	if !s.writable {
		s.settingsErr = "只读模式：外观偏好仅在本次运行生效（设置 TINGYU_DATA_DIR 后可保存）"
		return
	}
	if err := SaveSettings(s.settingsPath, next); err != nil {
		s.settingsErr = "保存 settings.json 失败：" + err.Error()
		return
	}
	s.settingsErr = ""
}

// ResetSettings restores AppPreferences.defaults.
func (s *State) ResetSettings() { s.SetSettings(DefaultSettings()) }

// Now returns the frame's clock.
func (s *State) Now() time.Time { return s.now }

// refreshInterval is how often the small summaries (counts, playlists) are
// re-read. A play count bumps the revision on every track start and the
// summaries do not change then; a second of staleness is invisible, a
// GROUP BY over the whole table on every track start is not.
const refreshInterval = time.Second

// Tick runs the per-frame state machine: the library revision, the paged
// lists, the debounced search and the palette. The shell calls it once at the
// top of every frame.
func (s *State) Tick(now time.Time) {
	s.now = now
	s.refresh()
	for _, list := range s.lists() {
		list.Tick(s.backend, s.revision, s.epoch)
	}

	s.albumList.Tick(s.backend, s.revision, s.epoch)
	// The search page's scope lists are paged lists too, ticked here rather
	// than inside the debounce so their pages arrive while the user reads.
	s.search.albums.Tick(s.backend, s.revision, s.epoch)
	s.search.artists.Tick(s.backend, s.revision, s.epoch)
	s.favAlbums.Tick(s.backend, s.revision, s.epoch)
	s.artistList.Tick(s.backend, s.revision, s.epoch)
	if s.artistDetail != nil {
		s.artistDetail.Albums.Tick(s.backend, s.revision, s.epoch)
	}
	s.search.Tick(now, s.backend, s.revision)
	s.palette.Tick(now, s)
	if message := s.pageError(); message != "" && s.failure == "" {
		// A page request that failed is not an empty list: say so.
		s.failure = message
	}
}

// refresh polls the library's write counter and re-reads what changed. The
// paged lists key themselves on the revision; the summaries are throttled,
// because a play count bumps the revision on every track start while the
// counts and the playlists do not change with it.
func (s *State) refresh() {
	if s.live == nil {
		return
	}
	revision := s.live.Revision()
	forced := s.stale
	s.stale = false
	if revision == s.revision && !forced && !s.countsAt.IsZero() {
		return
	}
	if revision != s.revision {
		s.revision = revision
	}
	if forced {
		s.epoch++
	}
	if !forced && !s.countsAt.IsZero() && s.now.Sub(s.countsAt) < refreshInterval {
		// A play count or a scan bumped the revision but the summaries were
		// read a moment ago: the lists still refresh (their key carries the
		// revision), the counts and playlists wait for the next second. An
		// explicit Invalidate (a write the app made itself) is not throttled.
		return
	}
	s.countsAt = s.now
	s.reloadSummaries()
}

// reloadSummaries re-reads the playlists and the counts, and refreshes the
// open detail pages.
func (s *State) reloadSummaries() {
	if s.backend == nil {
		return
	}
	if playlists, err := s.backend.Playlists(); err == nil {
		s.playlists = playlists
		if s.playlistDetail != nil {
			for _, playlist := range playlists {
				if playlist.ID == s.playlistDetail.Playlist.ID {
					s.playlistDetail.Playlist = playlist
				}
			}
		}
	} else {
		s.failure = "无法读取歌单：" + err.Error()
	}
	if counts, err := s.backend.Counts(); err == nil {
		s.counts = counts
	}
	if sources, err := s.backend.Sources(); err == nil {
		s.sources = sources
	}
	s.reloadDetails()
}

// reloadDetails re-reads the open album or artist detail.
func (s *State) reloadDetails() {
	if s.albumDetail != nil {
		tracks, err := s.albumTracks(s.albumDetail.Album)
		if err == nil {
			s.albumDetail.Tracks = tracks
		}
	}
	if s.artistDetail != nil {
		s.loadArtistDetail(s.artistDetail.Artist.Name, s.artistExpanded)
	}
}

// --- navigation ------------------------------------------------------

// Page returns the page shown.
func (s *State) Page() string { return s.page }

// SidebarQuery is the sidebar search text.
func (s *State) SidebarQuery() string { return s.sidebarQuery }

// SetSidebarQuery forwards the sidebar field to the search page and opens it,
// as the Flutter shell does (app_shell.dart :321-334).
func (s *State) SetSidebarQuery(query string) {
	s.sidebarQuery = query
	s.search.Input = query
	s.search.OnInput(s.now)
	if query != "" {
		s.OpenPage(PageSearch)
	}
}

// RequestSearchFocus asks the next frame to focus the search field (Cmd+F).
func (s *State) RequestSearchFocus() { s.searchFocus = true }

// TakeSearchFocus consumes that request.
func (s *State) TakeSearchFocus() bool {
	requested := s.searchFocus
	s.searchFocus = false
	return requested
}

// OpenPage goes to a page, remembering the one it leaves.
func (s *State) OpenPage(page string) {
	if page == s.page {
		return
	}
	s.back = append(s.back, s.page)
	s.page = page
	if page != PageStage {
		s.stage.Open = false
	}
	s.playlistEdit = nil
	switch page {
	case PageSearch:
		s.search.Focus = true
	case PageLibrary, PageFavorites, PageAlbums, PageArtists, PagePlaylists:
		s.search.Focus = false
	}
}

// Back returns to the page before, or the library.
func (s *State) Back() {
	if len(s.back) == 0 {
		s.page = PageLibrary
		return
	}
	last := s.back[len(s.back)-1]
	s.back = s.back[:len(s.back)-1]
	if s.page == PageAlbumDetail {
		s.albumDetail = nil
	}
	if s.page == PageArtistDetail {
		s.artistDetail = nil
	}
	if s.page == PagePlaylistDetail {
		s.playlistDetail = nil
	}
	if s.page == PageStage {
		s.stage.Open = false
	}
	s.page = last
}

// CanBack reports whether Back goes anywhere but the library.
func (s *State) CanBack() bool { return len(s.back) > 0 }

// OpenAlbum opens an album detail page, taking its tracks from SQL once.
func (s *State) OpenAlbum(album Album) {
	detail := &AlbumDetail{Album: album}
	if tracks, err := s.albumTracks(album); err == nil {
		detail.Tracks = tracks
	} else {
		s.failure = "无法读取专辑曲目：" + err.Error()
	}
	s.albumDetail = detail
	s.OpenPage(PageAlbumDetail)
}

// albumTracks is one album's tracks in disc/track order.
func (s *State) albumTracks(album Album) ([]library.Track, error) {
	if s.backend == nil {
		return nil, nil
	}
	return s.backend.TracksPage(library.TrackQuery{
		Artist: album.Artist,
		Album:  album.Name,
		Sort:   library.SortAlbum,
	})
}

// OpenArtist opens an artist detail page.
func (s *State) OpenArtist(artist Artist) {
	detail := &ArtistDetail{Artist: artist}
	detail.Albums.Configure(library.AlbumQuery{Artist: artist.Name})
	s.artistDetail = detail
	s.artistExpanded = false
	s.loadArtistDetail(artist.Name, false)
	s.OpenPage(PageArtistDetail)
}

// loadArtistDetail reads the artist's tracks (20 until expanded) and albums.
func (s *State) loadArtistDetail(name string, expanded bool) {
	detail := s.artistDetail
	if detail == nil || s.backend == nil {
		return
	}
	limit := 20
	if expanded {
		limit = 0
	}
	tracks, err := s.backend.TracksPage(library.TrackQuery{Artist: name, Sort: library.SortAlbum, Limit: limit})
	if err != nil {
		s.failure = "无法读取艺术家曲目：" + err.Error()
		return
	}
	detail.Tracks = tracks
}

// ArtistExpanded reports whether the artist page shows every track.
func (s *State) ArtistExpanded() bool { return s.artistExpanded }

// ToggleArtistExpanded expands or collapses the artist's track list.
func (s *State) ToggleArtistExpanded() {
	s.artistExpanded = !s.artistExpanded
	if s.artistDetail != nil {
		s.loadArtistDetail(s.artistDetail.Artist.Name, s.artistExpanded)
	}
}

// AlbumDetail returns the album detail shown, if any.
func (s *State) AlbumDetail() *AlbumDetail { return s.albumDetail }

// ArtistDetail returns the artist detail shown, if any.
func (s *State) ArtistDetail() *ArtistDetail { return s.artistDetail }

// OpenStage shows the now-playing page.
func (s *State) OpenStage() {
	if s.page != PageStage {
		s.back = append(s.back, s.page)
	}
	s.page = PageStage
	s.stage.Open = true
	s.stage.Panel = 0
}

// CloseStage leaves the now-playing page.
func (s *State) CloseStage() {
	if s.page != PageStage {
		s.stage.Open = false
		return
	}
	s.page = PageLibrary
	if len(s.back) > 0 {
		s.page = s.back[len(s.back)-1]
		s.back = s.back[:len(s.back)-1]
	}
	s.stage.Open = false
}

// Stage returns the stage state.
func (s *State) Stage() StageState { return s.stage }

// SetStagePanel selects the stage side panel (0 lyrics, 1 queue).
func (s *State) SetStagePanel(panel int) { s.stage.Panel = panel }

// SettingsSection is the selected settings group.
func (s *State) SettingsSection() int { return s.settingsSection }

// SetSettingsSection selects a settings group.
func (s *State) SetSettingsSection(section int) { s.settingsSection = section }

// OnboardingDone reports whether the user left onboarding.
func (s *State) OnboardingDone() bool { return s.onboardingDone }

// FinishOnboarding dismisses onboarding for this process.
func (s *State) FinishOnboarding() { s.onboardingDone = true }

// ShouldOnboard is the Flutter trigger: sources and tracks are both empty.
func (s *State) ShouldOnboard() bool {
	return !s.onboardingDone && s.loadErr == nil && s.counts.Tracks == 0 && len(s.sources) == 0
}

// Notice returns the current notice.
func (s *State) Notice() string { return s.notice }

// DismissNotice clears the notice.
func (s *State) DismissNotice() { s.notice = "" }

// SetNotice shows an informational notice.
func (s *State) SetNotice(message string) { s.notice = message }

// Transient returns a place for view-only state that must survive frames
// (element handles, scroll positions) without becoming app state.
func (s *State) Transient(key string) any { return s.transient[key] }

// SetTransient stores such state.
func (s *State) SetTransient(key string, value any) any {
	if s.transient == nil {
		s.transient = map[string]any{}
	}
	s.transient[key] = value
	return value
}

// AlbumsList returns the albums grid state.
func (s *State) AlbumsList() *ui.GridState { return &s.albumsList }

// ArtistsList returns the artists list state.
func (s *State) ArtistsList() *ui.ListState { return &s.artistsList }

// QueueList returns the queue's list state.
func (s *State) QueueList() *ui.ListState { return &s.queueList }

// LyricsList returns the lyrics list state.
func (s *State) LyricsList() *ui.ListState { return &s.lyricsList }

// DetailList returns the detail page's table state.
func (s *State) DetailList() *ui.ListState { return &s.detailList }

// AllOf returns every row of a list's query, beyond the pages loaded so far:
// 「播放全部」must play the whole query, not only what the user scrolled past.
func (s *State) AllOf(list *TrackList) []library.Track {
	if s.backend == nil {
		return nil
	}
	q := list.kernelQuery()
	q.Limit = 0
	q.Offset = 0
	tracks, err := s.backend.TracksPage(q)
	if err != nil {
		s.failure = "无法读取曲目：" + err.Error()
		return nil
	}
	return tracks
}

// AddToPlaylist adds tracks to a playlist through the app, which appends them
// in the order given (duplicates included, as the Flutter client does).
func (s *State) AddToPlaylist(playlistID string, tracks []library.Track) {
	if len(tracks) == 0 {
		return
	}
	ids := make([]string, 0, len(tracks))
	for _, track := range tracks {
		ids = append(ids, track.ID)
	}
	if a := s.actions; a != nil {
		a.AddToPlaylist(playlistID, ids)
	}
}

// ToggleFavorite flips a track's favourite flag through the app, which writes
// tracks.is_favorite and bumps the revision the lists refresh on.
func (s *State) ToggleFavorite(track library.Track) {
	if a := s.actions; a != nil {
		a.SetFavorite(track, !track.IsFavorite)
	}
}

// DismissSource forgets a deleted source from the filter if it was chosen.
func (s *State) DismissSource(id string) {
	if s.library.SourceFilter() == id {
		s.library.SetSource("")
		s.favorites.SetSource("")
	}
}

// PlaylistList returns the playlists (name + track count), by name.
func (s *State) Playlists() []library.Playlist { return s.playlists }

// PlaylistDetail returns the open playlist page, if any.
func (s *State) PlaylistDetail() *PlaylistDetail { return s.playlistDetail }

// OpenPlaylist opens a playlist's tracks.
func (s *State) OpenPlaylist(playlist library.Playlist) {
	detail := &PlaylistDetail{Playlist: playlist}
	detail.Tracks.Configure(FilterAll, SortTitle, true, "")
	detail.Tracks.SetPlaylist(playlist.ID)
	if s.live != nil {
		detail.Tracks.SetRowRevision(s.live.RowRevision)
	}
	s.playlistDetail = detail
	s.OpenPage(PagePlaylistDetail)
}

// PlaylistEdit is the inline name field of the playlists page.
type playlistEdit struct {
	PlaylistID string // "" while creating
	Title      string
	Value      string
}

// PlaylistEdit returns the open name field, if any.
func (s *State) PlaylistEditID() (string, bool) {
	if s.playlistEdit == nil {
		return "", false
	}
	return s.playlistEdit.PlaylistID, true
}

// BeginCreatePlaylist opens the name field for a new playlist.
func (s *State) BeginCreatePlaylist() {
	s.playlistEdit = &playlistEdit{Title: "新建歌单", Value: ""}
}

// BeginRenamePlaylist opens the name field with the current name.
func (s *State) BeginRenamePlaylist(playlist library.Playlist) {
	s.playlistEdit = &playlistEdit{PlaylistID: playlist.ID, Title: "重命名歌单", Value: playlist.Name}
}

// PlaylistEditTitle is the heading of the name field.
func (s *State) PlaylistEditTitle() string {
	if s.playlistEdit == nil {
		return ""
	}
	return s.playlistEdit.Title
}

// PlaylistEditValue is the text the field edits.
func (s *State) PlaylistEditValue() *string {
	if s.playlistEdit == nil {
		return nil
	}
	return &s.playlistEdit.Value
}

// CommitPlaylistEdit writes the playlist (create or rename) through the app.
func (s *State) CommitPlaylistEdit() {
	edit := s.playlistEdit
	if edit == nil {
		return
	}
	s.playlistEdit = nil
	name := strings.TrimSpace(edit.Value)
	if name == "" {
		return
	}
	if a := s.actions; a != nil {
		if edit.PlaylistID == "" {
			a.CreatePlaylist(name)
			return
		}
		a.RenamePlaylist(edit.PlaylistID, name)
	}
}

// CancelPlaylistEdit closes the name field without writing.
func (s *State) CancelPlaylistEdit() { s.playlistEdit = nil }

// DeletePlaylist removes a playlist (its items go with it, never its tracks).
func (s *State) DeletePlaylist(playlist library.Playlist) {
	if a := s.actions; a != nil {
		a.DeletePlaylist(playlist.ID)
	}
	if s.playlistDetail != nil && s.playlistDetail.Playlist.ID == playlist.ID {
		s.playlistDetail = nil
		if s.page == PagePlaylistDetail {
			// The page that showed it is gone with it: show the list of
			// playlists, not whatever page happened to precede it.
			s.OpenPage(PagePlaylists)
		}
	}
}

// RemoveFromPlaylist removes one row of the open playlist.
func (s *State) RemoveFromPlaylist(index int) {
	if s.playlistDetail == nil || s.actions == nil {
		return
	}
	s.actions.RemoveFromPlaylist(s.playlistDetail.Playlist.ID, index)
}

// MovePlaylistItem moves one row of the open playlist up or down.
func (s *State) MovePlaylistItem(from, to int) {
	if s.playlistDetail == nil || s.actions == nil {
		return
	}
	if to < 0 || to >= s.playlistDetail.Tracks.Total() {
		return
	}
	s.actions.MovePlaylistItem(s.playlistDetail.Playlist.ID, from, to)
}

// Counts is the settings page's summary.
func (s *State) Counts() library.Counts { return s.counts }
