// Package model is the M4 view state: what the pages show and the rules that
// turn the kernel's read-only data into lists, groups, search results and
// paginated pages. It owns no window, no database handle and no engine, so
// every rule here is a pure function of the data the app feeds it.
//
// Write operations the kernel does not provide yet (favourite toggles,
// playlists, metadata, lyrics fetching) are not faked: AskKernel names the
// missing capability, and the UI shows that notice.
package model

import (
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// Page constants for the session state machine.
const (
	PageLibrary      = "library"
	PageFavorites    = "favorites"
	PageAlbums       = "albums"
	PageArtists      = "artists"
	PagePlaylists    = "playlists"
	PageSearch       = "search"
	PageSettings     = "settings"
	PageSources      = "sources"
	PageStage        = "stage"
	PageQueue        = "queue"
	PageLyrics       = "lyrics"
	PageAlbumDetail  = "album"
	PageArtistDetail = "artist"
	PageOnboarding   = "onboarding"
)

// PageSize is the library page size (plan §2.5 / providers.dart:498).
const PageSize = 40

// PreviewSize is how many rows each search group previews (providers.dart:501).
const PreviewSize = 5

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

// ScanState is what the shell shows about a scan.
type ScanState struct {
	Running bool
	Done    int
	Total   int
	Path    string
	Status  string
	Error   string
}

// Actions are the side effects the view asks the app to perform. Every method
// maps to a capability the M1+ kernel already has.
type Actions interface {
	PlayTracks(tracks []library.Track, start int) error
	TogglePlayPause() error
	Next() error
	Previous() error
	Seek(position time.Duration) error
	SetVolume(volume float64) error
	CycleRepeat() player.RepeatMode
	ChooseDirectory()
	SyncSource(source library.Source)
	SyncAllSources()
	RevealInFinder(track library.Track)
	Queue() []library.Track
}

// StageState is the full-window now-playing page and its side panel.
type StageState struct {
	Open   bool
	Panel  int // 0 lyrics, 1 queue
	Lyrics bool
}

// State is everything a frame reads. The app mutates it on the UI thread (via
// Window.Update); background workers never touch it.
type State struct {
	actions Actions

	tracks   []library.Track
	rowRevs  map[string]uint64
	revision uint64
	sources  []library.Source

	dbPath    string
	dataDir   string
	coversDir string
	writable  bool
	loadErr   error

	scan    ScanState
	status  string
	failure string

	player   player.Update
	volume   float64
	repeat   player.RepeatMode
	queue    []library.Track
	queueIdx int

	settings     Settings
	settingsPath string
	settingsErr  string

	library        TrackList
	favorites      TrackList
	favoriteView   int // 0 songs, 1 albums
	albumDetail    *Album
	artistDetail   *Artist
	artistExpanded bool

	search       SearchState
	palette      PaletteState
	sidebarQuery string
	searchFocus  bool

	page            string
	back            []string
	stage           StageState
	queueOpen       bool
	settingsSection int
	onboardingDone  bool
	onboardingShown bool

	notice   string
	noticeAt time.Time
	now      time.Time

	albums      albumIndex
	favAlbums   albumIndex
	artists     artistIndex
	albumsList  ui.GridState
	artistsList ui.ListState
	queueList   ui.ListState
	lyricsList  ui.ListState
	detailList  ui.ListState

	lyrics    lyricsCache
	covers    CoverCache
	transient map[string]any
}

// New builds the state from the read-only library snapshot.
func New(tracks []library.Track, dbPath string, loadErr error) *State {
	s := &State{
		tracks:   tracks,
		dbPath:   dbPath,
		loadErr:  loadErr,
		volume:   1,
		repeat:   player.RepeatAll,
		settings: DefaultSettings(),
		page:     PageLibrary,
		rowRevs:  map[string]uint64{},
		now:      time.Now(),
	}
	s.library.Configure(FilterAll, SortTitle, true, "")
	s.favorites.Configure(FilterFavorites, SortTitle, true, "")
	s.library.selected = -1
	s.favorites.selected = -1
	s.palette.Selected = 0
	return s
}

// SetActions installs the callbacks.
func (s *State) SetActions(a Actions) { s.actions = a }

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
}

// SetTracks replaces the library snapshot. revision is the library's write
// counter and rowRevs the per-row counters: a metadata-only change rebuilds
// that row (and only that row) through the table's row keys.
func (s *State) SetTracks(tracks []library.Track, revision uint64, rowRevs map[string]uint64) {
	s.tracks = tracks
	s.revision = revision
	if rowRevs == nil {
		rowRevs = map[string]uint64{}
	}
	s.rowRevs = rowRevs
	s.library.Ensure(tracks, revision, rowRevs)
	s.favorites.Ensure(tracks, revision, rowRevs)
}

// SetSources replaces the source list.
func (s *State) SetSources(sources []library.Source) { s.sources = sources }

// AllTracks returns the raw library snapshot.
func (s *State) AllTracks() []library.Track { return s.tracks }

// LibraryRevision returns the library's write counter.
func (s *State) LibraryRevision() uint64 { return s.revision }

// RowRevisions returns the per-row revisions.
func (s *State) RowRevisions() map[string]uint64 { return s.rowRevs }

// Version is the About page's version line.
const Version = "M4 · 0.4.0-dev"

// Sources returns the sources.
func (s *State) Sources() []library.Source { return s.sources }

// SetPlayer applies a playback update.
func (s *State) SetPlayer(update player.Update) {
	s.player = update
	if update.Track != nil && update.PlayCount > 0 {
		for i := range s.tracks {
			if s.tracks[i].ID == update.Track.ID {
				s.tracks[i].PlayCount = update.PlayCount
				break
			}
		}
	}
	if update.Failure != nil {
		s.failure = update.Failure.Message
	} else if update.Snapshot.Playing {
		s.failure = ""
	}
	s.repeat = update.Repeat
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

// Tick runs the per-frame state machine: debounced search, paging steps and
// notices. The shell calls it once at the top of every frame.
func (s *State) Tick(now time.Time) {
	s.now = now
	s.library.Step()
	s.favorites.Step()
	s.library.Ensure(s.tracks, s.revision, s.rowRevs)
	s.favorites.Ensure(s.tracks, s.revision, s.rowRevs)
	s.search.Tick(now, s.tracks)
	if s.search.NeedsResults() {
		s.search.Recompute(s.Albums(), s.Artists(), s.tracks)
	}
	s.palette.Tick(now, s)
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
	if s.page == PageStage {
		s.stage.Open = false
	}
	s.page = last
}

// CanBack reports whether Back goes anywhere but the library.
func (s *State) CanBack() bool { return len(s.back) > 0 }

// OpenAlbum opens an album detail page.
func (s *State) OpenAlbum(album Album) {
	s.albumDetail = &album
	s.OpenPage(PageAlbumDetail)
}

// OpenArtist opens an artist detail page.
func (s *State) OpenArtist(artist Artist) {
	s.artistDetail = &artist
	s.OpenPage(PageArtistDetail)
}

// ArtistExpanded reports whether the artist page shows every track.
func (s *State) ArtistExpanded() bool { return s.artistExpanded }

// ToggleArtistExpanded expands or collapses the artist's track list.
func (s *State) ToggleArtistExpanded() { s.artistExpanded = !s.artistExpanded }

// AlbumDetail returns the album detail shown, if any.
func (s *State) AlbumDetail() *Album { return s.albumDetail }

// ArtistDetail returns the artist detail shown, if any.
func (s *State) ArtistDetail() *Artist { return s.artistDetail }

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

// ToggleQueue opens or closes the queue panel.
func (s *State) ToggleQueue() { s.queueOpen = !s.queueOpen }

// QueueOpen reports whether the queue panel shows.
func (s *State) QueueOpen() bool { return s.queueOpen }

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
	return !s.onboardingDone && s.loadErr == nil && len(s.tracks) == 0 && len(s.sources) == 0
}

// Notice returns the current notice and whether it still shows.
func (s *State) Notice() string { return s.notice }

// DismissNotice clears the notice.
func (s *State) DismissNotice() { s.notice = "" }

// AskKernel reports a missing kernel capability instead of pretending the
// operation worked. The string names the feature, e.g. "收藏写入".
func (s *State) AskKernel(feature string) {
	s.notice = "需内核支持：" + feature + "。本里程碑只做界面，未改内核；该操作尚未接入数据层。"
	s.noticeAt = s.now
}

// SetNotice shows an informational notice.
func (s *State) SetNotice(message string) {
	s.notice = message
	s.noticeAt = s.now
}

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

// TableState returns the list state of a page's table.
func (s *State) TableState(page string) *ui.ListState {
	switch page {
	case PageFavorites:
		return &s.favorites.table
	case PageArtists:
		return &s.artistsList
	case PageQueue:
		return &s.queueList
	case PageLyrics:
		return &s.lyricsList
	case PageAlbumDetail, PageArtistDetail:
		return &s.detailList
	default:
		return &s.library.table
	}
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
