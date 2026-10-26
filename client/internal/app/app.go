//go:build darwin

// Package app assembles the M1 client: one library connection, one in-process
// libmpv, one playback controller, one window and one menu bar item.
//
// The production library is opened read-write only when TINGYU_DATA_DIR is
// set. Without it the client stays read-only, so a development build can never
// write the user's real library (plan §8.1 rule 2): M1's only writes are the
// scan merge and the play history, and both require the copy.
package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/enrich"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/scan"
	"github.com/halunhaku/tingyu/client/internal/shell"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

type application struct {
	startup *startup
	dataDir string
	covers  string
	path    string
	lib     *library.Library
	engine  *mpv.Player
	control *player.Controller
	model   *shell.Model

	winMu sync.Mutex
	win   *mygo.Window

	tray     *mygo.Tray
	trayPlay *mygo.MenuItem

	session sessionPublisher
	awake   atomic.Bool

	// M3 source layer: credentials, adapters, sync and direct-link refresh.
	creds     *sources.Credentials
	sourceMgr *sources.Manager
	syncer    *sources.Syncer
	recoverer *sources.Recoverer

	// M5 metadata pipeline: four HTTP sources, the cover fetcher and the two
	// write paths (see metadata.go).
	enricher     *metadata.Enricher
	enrich       *enrich.Service
	metadataHTTP *http.Client
	enrichMu     sync.Mutex
	enrichCancel context.CancelFunc
	enrichActive atomic.Bool

	sourceLoginMu     sync.Mutex
	sourceLoginCancel context.CancelFunc
	sourceLoginSeq    atomic.Uint64
	sourceLoginActive uint64
	sourceSyncMu      sync.Mutex
	sourceSyncCancel  context.CancelFunc
	sourceSyncID      string
	sourceSyncSeq     atomic.Uint64
	sourceSyncActive  uint64

	scanning   atomic.Bool
	scanCancel atomic.Bool
	quitting   atomic.Bool
	scanDone   chan struct{}
	scanOnce   sync.Once
	readyCh    chan struct{}
	readyOnce  sync.Once

	playRequest time.Time
	soundAt     time.Time
	soundMu     sync.Mutex

	lastUpdateMu sync.Mutex
	lastUpdate   player.Update

	// updates carries controller snapshots to one worker goroutine. The
	// listener must never do media-session work on the caller's thread: a
	// double click calls PlayTracks (and therefore the listener) on the UI
	// thread, and driving MediaPlayer from inside a UI callback deadlocked the
	// main thread. Publishing from the window, the tray and the session also
	// all become single-threaded from here, which is what their dedup state
	// assumes.
	updates chan player.Update
	done    chan struct{}
}

// Main runs the client until the app quits.
func Main() error {
	a := &application{
		startup:  newStartup(),
		scanDone: make(chan struct{}),
		readyCh:  make(chan struct{}),
		updates:  make(chan player.Update, 8),
		done:     make(chan struct{}),
	}
	defer a.startup.Close()
	if err := a.prepare(); err != nil {
		// A library that cannot be opened is not fatal: the window opens and
		// explains why, so the failure is visible.
		a.startup.printf("startup library: %v", err)
	}
	// The worker starts once the model exists; listener calls made while
	// prepare runs wait in the channel.
	go a.updateLoop()

	mygo.App.OnWindowAllClosed(func() {
		// Closing the window keeps the process (and the music) alive; the menu
		// bar item is the way back (plan §5.6).
		a.logf("window: all closed, playback continues")
	})
	mygo.App.OnActivate(func(hasVisibleWindows bool) {
		if !hasVisibleWindows {
			a.showWindow()
		}
	})
	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) {
		a.shutdown()
	})

	mygo.App.WhenReady(func() {
		a.installMenu()
		a.showWindow()
		a.initSession()
		a.initTray()
		go func() {
			// Only after the first frame: the pass reports progress into the
			// window, and a pass before it exists would drop every report.
			<-a.readyCh
			a.maybeAutoEnrich("startup")
		}()
		if dir := strings.TrimSpace(os.Getenv("TINGYU_AUTO_SCAN_DIR")); dir != "" {
			// Acceptance aid: run the same scan the picker runs, so a bundle
			// can be verified without driving a native file dialog. It waits
			// for the first frame, like a user clicking the button does, so the
			// progress panel is actually on screen while the scan runs.
			go func() {
				<-a.readyCh
				a.scanFolder(dir)
			}()
		}
		if title := strings.TrimSpace(os.Getenv("TINGYU_AUTO_PLAY_TITLE")); title != "" {
			go a.acceptancePlayTitle(title)
		}
		if index := strings.TrimSpace(os.Getenv("TINGYU_AUTO_PLAY_INDEX")); index != "" {
			// Acceptance aid: play a row through the same entry a double click
			// uses (PlayTracks), after the window is up.
			if n, err := strconv.Atoi(index); err == nil {
				go a.acceptancePlay(n)
			}
		}
		if count := strings.TrimSpace(os.Getenv("TINGYU_STRESS_PLAYS")); count != "" {
			if n, err := strconv.Atoi(count); err == nil {
				go a.acceptanceStress(n)
			}
		}
		if ms := strings.TrimSpace(os.Getenv("TINGYU_POPUP_TRAY_MS")); ms != "" {
			if n, err := strconv.Atoi(ms); err == nil && n > 0 {
				time.AfterFunc(time.Duration(n)*time.Millisecond, func() {
					if a.tray != nil {
						a.logf("tray: pop up menu")
						a.tray.PopUpMenu()
					}
				})
			}
		}
		if ms := strings.TrimSpace(os.Getenv("TINGYU_AUTO_QUIT_MS")); ms != "" {
			if n, err := strconv.Atoi(ms); err == nil && n > 0 {
				time.AfterFunc(time.Duration(n)*time.Millisecond, func() {
					a.logf("app: auto quit")
					mygo.App.Quit()
				})
			}
		}
	})
	return mygo.App.Run()
}

// prepare opens the library and starts the playback kernel. It returns the
// library error (if any) after the model exists, so the window can show it.
func (a *application) prepare() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var loadErr error
	dataDir, err := library.DataDir()
	if err != nil {
		loadErr = err
	} else {
		a.dataDir = dataDir
		a.covers = library.CoversDir(dataDir)
		a.path = library.Path(dataDir)
		a.startup.mark("data dir")
		mode := "read-only"
		lib, openErr := library.Open(ctx, a.path)
		if os.Getenv("TINGYU_DATA_DIR") != "" {
			mode = "read-write"
			lib, openErr = library.OpenWritable(ctx, a.path)
		} else {
			a.logf("library: TINGYU_DATA_DIR is unset; staying read-only so the production library is never written")
		}
		if openErr != nil {
			loadErr = openErr
		} else {
			a.lib = lib
			counts, countErr := lib.Counts(ctx)
			if countErr != nil {
				loadErr = fmt.Errorf("%s: %w", a.path, countErr)
			} else {
				a.logf("library: %d tracks / %d albums / %d artists / %d playlists from %s (%s, user_version %d)",
					counts.Tracks, counts.Albums, counts.Artists, counts.Playlists, a.path, mode, library.SchemaVersion)
				a.startup.mark("library read")
			}
		}
	}

	if a.lib != nil {
		a.model = shell.New(a.lib.Queries(), a.lib, a.path, loadErr)
	} else {
		a.model = shell.New(nil, nil, a.path, loadErr)
	}
	a.model.SetActions(a)
	if a.dataDir != "" {
		a.model.ConfigureDataDir(a.dataDir, a.lib != nil && a.lib.Writable())
	}
	if a.covers != "" {
		a.model.SetCoversDir(a.covers)
	}

	a.initMetadata()
	a.initSources()
	a.engine, err = a.newEngine()
	if err != nil {
		a.logf("playback: %v", err)
		a.model.SetError("播放内核不可用：" + err.Error())
	} else if a.lib != nil {
		a.control = player.New(a.engine, a.resolveTrack, a.lib)
		a.recoverer = sources.NewRecoverer(a.sourceMgr, a.control, a.logf)
		a.control.SetListener(a.onUpdate)
		a.model.SetPlayer(a.control.Snapshot())
		switch strings.ToLower(strings.TrimSpace(os.Getenv("TINGYU_REPEAT"))) {
		case "off":
			a.control.SetRepeat(player.RepeatOff)
		case "one":
			a.control.SetRepeat(player.RepeatOne)
		case "all":
			a.control.SetRepeat(player.RepeatAll)
		}
		major, minor := a.engine.ClientAPIVersion()
		a.logf("playback: libmpv %s client API %d.%d", filepath.Base(mpv.LibraryPath()), major, minor)
	}
	if a.lib != nil {
		a.reloadSources()
	}
	return loadErr
}

func (a *application) newEngine() (*mpv.Player, error) {
	libPath := mpv.LibraryPath()
	if libPath == "" {
		return nil, errors.New("找不到 libmpv（设置 MPV_LIB 或用 scripts/bundle.sh 出包）")
	}
	lib, err := mpv.Load(libPath)
	if err != nil {
		return nil, err
	}
	return mpv.NewPlayer(lib, mpv.Config{AudioClientName: "听屿", Debug: a.logf})
}

// --- window ---------------------------------------------------------

func (a *application) showWindow() {
	a.winMu.Lock()
	defer a.winMu.Unlock()
	if a.win != nil {
		a.win.Show()
		a.win.Focus()
		return
	}
	win := mygo.NewWindow(mygo.WindowOptions{
		Title:     "听屿",
		Width:     shell.DefaultWidth,
		Height:    shell.DefaultHeight,
		MinWidth:  shell.MinimumWidth,
		MinHeight: shell.MinimumHeight,
		Content:   ui.View(a.model.View),
	})
	a.win = win
	a.logf("window: %dx%d, minimum %dx%d", shell.DefaultWidth, shell.DefaultHeight, shell.MinimumWidth, shell.MinimumHeight)
	a.startup.mark("window created")
	var ready bool
	win.OnReadyToShow(func() {
		if ready {
			return
		}
		ready = true
		a.startup.mark("ready")
		a.readyOnce.Do(func() { close(a.readyCh) })
	})
	win.OnFocus(func() { a.startup.mark("focused") })
	win.OnClosed(func() {
		a.winMu.Lock()
		if a.win == win {
			a.win = nil
		}
		a.winMu.Unlock()
		a.logf("window: closed")
	})
}

func (a *application) updateWindow(fn func()) {
	a.winMu.Lock()
	win := a.win
	a.winMu.Unlock()
	if win != nil {
		win.Update(fn)
	}
}

func (a *application) reloadSources() {
	if a.lib == nil {
		return
	}
	sources, err := a.lib.Sources(context.Background())
	if err != nil {
		a.logf("library: reload sources: %v", err)
		return
	}
	a.updateWindow(func() { a.model.SetSources(sources) })
}

// refresh tells the window that the library changed. The lists read SQL
// through their revision keys, so this is a counter bump, not a data copy:
// nothing loads the whole tracks table into the window any more.
func (a *application) refresh() {
	if a.lib == nil {
		return
	}
	a.reloadSources()
	revision := a.lib.Revision()
	a.updateWindow(func() { a.model.Invalidate() })
	a.logf("library: revision %d", revision)
}

// write runs one library write on a worker thread and refreshes the window,
// or reports why it could not. Every write goes through here: a read-only
// build says so instead of pretending the change stuck.
func (a *application) write(what string, fn func(ctx context.Context) error) bool {
	if a.lib == nil {
		a.setStatus(what + "失败：曲库未打开")
		return false
	}
	if !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能" + what + "（生产库绝不被写）")
		return false
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := fn(ctx); err != nil {
			a.logf("%s: failed: %v", what, err)
			a.updateWindow(func() {
				a.model.SetError(what + "失败：" + err.Error())
			})
			return
		}
		a.logf("%s: ok", what)
		a.refresh()
	}()
	return true
}

// --- library writes (shell.Actions) ----------------------------------

// SetFavorite writes tracks.is_favorite, the store the row heart, the row menu
// and the stage all use.
func (a *application) SetFavorite(track library.Track, favorite bool) {
	a.write("收藏写入", func(ctx context.Context) error {
		if err := a.lib.SetFavorite(ctx, track.ID, favorite); err != nil {
			return err
		}
		// The status follows the write, not the click: a refused write (a
		// read-only copy) must not look like a success.
		status := "已取消收藏「" + track.Title + "」"
		if favorite {
			status = "已收藏「" + track.Title + "」"
		}
		a.updateWindow(func() { a.model.SetStatus(status); a.model.SetError("") })
		return nil
	})
}

// CreatePlaylist creates an empty playlist; the name comes from the page's
// inline field (trimmed and refused when empty by the kernel).
func (a *application) CreatePlaylist(name string) {
	a.write("新建歌单", func(ctx context.Context) error {
		playlist, err := a.lib.CreatePlaylist(ctx, name)
		if err != nil {
			return err
		}
		a.logf("playlist: created %s %q", playlist.ID, playlist.Name)
		return nil
	})
}

// RenamePlaylist renames one playlist.
func (a *application) RenamePlaylist(id, name string) {
	a.write("重命名歌单", func(ctx context.Context) error {
		return a.lib.RenamePlaylist(ctx, id, name)
	})
}

// DeletePlaylist removes a playlist; its items go with it, its tracks do not.
func (a *application) DeletePlaylist(id string) {
	a.write("删除歌单", func(ctx context.Context) error {
		deletion, err := a.lib.DeletePlaylist(ctx, id)
		if err != nil {
			return err
		}
		a.logf("playlist: deleted %q, %d items removed with it", deletion.Name, deletion.Items)
		return nil
	})
}

// AddToPlaylist appends tracks to a playlist in the order given.
func (a *application) AddToPlaylist(playlistID string, trackIDs []string) {
	a.write("加入歌单", func(ctx context.Context) error {
		added, err := a.lib.AddTracksToPlaylist(ctx, playlistID, trackIDs)
		if err != nil {
			return err
		}
		a.logf("playlist: %s appended %d tracks", playlistID, added)
		a.updateWindow(func() {
			a.model.SetStatus(fmt.Sprintf("已加入歌单：%d 首", added))
		})
		return nil
	})
}

// RemoveFromPlaylist removes the item at a row of the playlist's saved order.
func (a *application) RemoveFromPlaylist(playlistID string, index int) {
	a.write("移出歌单", func(ctx context.Context) error {
		return a.lib.RemovePlaylistItem(ctx, playlistID, index)
	})
}

// MovePlaylistItem reorders one item of a playlist.
func (a *application) MovePlaylistItem(playlistID string, from, to int) {
	a.write("调整歌单顺序", func(ctx context.Context) error {
		return a.lib.MovePlaylistItem(ctx, playlistID, from, to)
	})
}

// DeleteSource removes a source with its tracks, its playlist entries and any
// cover file nothing else references (plan §2.1 #2 and #4). A remote source's
// credential is removed with it: a secret whose source is gone is a leak, and
// the cached adapter would keep serving a source that no longer exists.
func (a *application) DeleteSource(source library.Source) {
	a.write("删除来源", func(ctx context.Context) error {
		// A sync of this source would race the delete: it merges tracks that
		// are about to go. Cancel it first; a merge that still lands after
		// the delete fails its foreign key and is only logged, it cannot
		// bring the source back.
		a.sourceSyncMu.Lock()
		if a.sourceSyncID == source.ID && a.sourceSyncCancel != nil {
			a.sourceSyncCancel()
		}
		a.sourceSyncMu.Unlock()
		deletion, err := a.lib.DeleteSource(ctx, source.ID)
		if err != nil {
			return err
		}
		a.logf("source: deleted %q: tracks=%d playlist_items=%d covers=%v",
			deletion.Source, deletion.Tracks, deletion.PlaylistItems, deletion.Covers)
		if a.sourceMgr != nil {
			a.sourceMgr.Invalidate(source.ID)
		}
		switch source.Kind {
		case model.SourceKindWebDAV:
			if a.creds != nil {
				if err := a.creds.DeleteWebDAVPassword(source.ID); err != nil {
					a.logf("source: delete credential of %q: %v", source.ID, err)
				}
			}
		case model.SourceKindQuark:
			if a.creds != nil {
				if err := a.creds.DeleteQuarkCookie(source.ID); err != nil {
					a.logf("source: delete credential of %q: %v", source.ID, err)
				}
			}
		}
		keep, err := a.lib.ReferencedCovers(ctx)
		if err != nil {
			return err
		}
		removed, err := scan.CollectOrphanCovers(a.covers, keep)
		if err != nil {
			return err
		}
		a.logf("source: %d orphan covers removed, %d still referenced", removed, len(keep))
		a.updateWindow(func() {
			a.model.SetStatus(fmt.Sprintf("已删除来源「%s」：%d 首曲目、%d 条歌单条目、%d 个孤儿封面",
				deletion.Source, deletion.Tracks, deletion.PlaylistItems, removed))
		})
		return nil
	})
}

// SetShuffle turns shuffle on or off and returns the mode the controller is in.
func (a *application) SetShuffle(on bool) bool {
	if a.control == nil {
		return on
	}
	mode := a.control.SetShuffle(on)
	a.logf("play: shuffle %v", mode)
	return mode
}

// --- playback actions (shell.Actions) --------------------------------

func (a *application) PlayTracks(tracks []library.Track, start int) error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	if start < 0 || start >= len(tracks) {
		return fmt.Errorf("曲目下标 %d 超出范围", start)
	}
	a.soundMu.Lock()
	a.playRequest = time.Now()
	a.soundAt = time.Time{}
	a.soundMu.Unlock()
	a.session.force.Store(true)
	track := tracks[start]
	a.logf("play: request %q (%s) index=%d", track.Title, track.FilePath, start)
	rotated := append(append([]library.Track{}, tracks[start:]...), tracks[:start]...)
	a.updateWindow(func() { a.model.SetQueue(rotated, 0) })
	if err := a.control.PlayTracks(tracks, start); err != nil {
		a.logf("play: failed %q: %v", track.Title, err)
		a.updateWindow(func() { a.model.SetError(err.Error()) })
		return err
	}
	return nil
}

func (a *application) TogglePlayPause() error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	return a.control.TogglePlayPause()
}

func (a *application) Next() error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	return a.control.Next()
}

func (a *application) Previous() error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	return a.control.Previous()
}

func (a *application) Seek(position time.Duration) error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	a.logf("play: seek %.2fs", position.Seconds())
	return a.control.Seek(position)
}

func (a *application) SetVolume(volume float64) error {
	if a.control == nil {
		return errors.New("播放内核不可用")
	}
	a.logf("play: volume %.2f", volume)
	return a.control.SetVolume(volume)
}

// Queue returns the controller's current queue for the queue page.
func (a *application) Queue() []library.Track {
	if a.control == nil {
		return nil
	}
	return a.control.Queue()
}

// SyncSource syncs one source: a local folder through the scanner, a remote
// source through the M3 source layer (progress, cancel and re-login included).
func (a *application) SyncSource(source library.Source) {
	if source.Kind != "local" {
		go a.syncRemote(source)
		return
	}
	if strings.TrimSpace(source.LocalFolderPath) == "" {
		a.setStatus("来源 " + source.Name + " 没有本地目录，无法同步")
		return
	}
	go a.scanFolder(source.LocalFolderPath)
}

// SyncAllSources syncs every source in turn: local folders, then remote ones.
func (a *application) SyncAllSources() {
	if a.lib == nil || !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能同步")
		return
	}
	go func() {
		sources, err := a.lib.Sources(context.Background())
		if err != nil {
			a.setStatus("无法读取来源：" + err.Error())
			return
		}
		for _, source := range sources {
			if source.Kind == "local" {
				if strings.TrimSpace(source.LocalFolderPath) != "" {
					a.scanFolder(source.LocalFolderPath)
				}
				continue
			}
			a.syncRemote(source)
		}
	}()
}

// RevealInFinder shows a local file in Finder; remote paths are ignored.
func (a *application) RevealInFinder(track library.Track) {
	if !filepath.IsAbs(track.FilePath) {
		return
	}
	if err := exec.Command("open", "-R", track.FilePath).Start(); err != nil {
		a.setStatus("无法在访达中显示：" + err.Error())
		return
	}
	a.logf("finder: reveal %s", track.FilePath)
}

func (a *application) CycleRepeat() player.RepeatMode {
	if a.control == nil {
		return player.RepeatOff
	}
	mode := a.control.CycleRepeat()
	a.logf("play: repeat %s", mode)
	return mode
}

// acceptancePlay starts index through the normal PlayTracks entry.
func (a *application) waitForScan() {
	if strings.TrimSpace(os.Getenv("TINGYU_AUTO_SCAN_DIR")) != "" {
		<-a.scanDone
	}
}

func (a *application) markScanDone() { a.scanOnce.Do(func() { close(a.scanDone) }) }

func (a *application) acceptancePlay(index int) {
	a.waitForScan()
	if a.lib == nil || a.control == nil {
		a.logf("accept: cannot play: library or engine unavailable")
		return
	}
	if index < 0 {
		a.logf("accept: track index %d is negative", index)
		return
	}
	// Start at the index and queue everything after it: one paged read, no
	// full-table copy.
	tracks, err := a.lib.TracksPage(context.Background(), library.TrackQuery{
		Sort: library.SortTitle, Offset: index,
	})
	if err != nil || len(tracks) == 0 {
		a.logf("accept: track index %d unavailable: %v", index, err)
		return
	}
	_ = a.PlayTracks(tracks, 0)
}

// acceptancePlayTitle starts the first local track whose title contains title.
func (a *application) acceptancePlayTitle(title string) {
	a.waitForScan()
	if a.lib == nil || a.control == nil {
		a.logf("accept: cannot play: library or engine unavailable")
		return
	}
	matches, err := a.lib.TracksPage(context.Background(), library.TrackQuery{
		Search: title, Sort: library.SortTitle,
	})
	if err != nil {
		a.logf("accept: cannot search tracks: %v", err)
		return
	}
	for _, track := range matches {
		if filepath.IsAbs(track.FilePath) {
			a.logf("accept: title %q matched %q", title, track.Title)
			_ = a.PlayTracks(matches, 0)
			return
		}
	}
	a.logf("accept: no local track matching %q", title)
}

// acceptanceStress clicks n different tracks quickly, the way a user hammering
// rows does. Each click goes through PlayTracks, so the generation gate,
// stop→clear and prefetch paths are the ones under test.
func (a *application) acceptanceStress(count int) {
	a.waitForScan()
	if count <= 0 {
		return
	}
	if a.lib == nil || a.control == nil {
		a.logf("stress: library or engine unavailable")
		return
	}
	tracks, err := a.lib.TracksPage(context.Background(), library.TrackQuery{Sort: library.SortTitle})
	if err != nil || len(tracks) == 0 {
		a.logf("stress: no tracks: %v", err)
		return
	}
	// Only files this milestone can actually decode: remote sources are M3.
	local := tracks[:0]
	for _, track := range tracks {
		if filepath.IsAbs(track.FilePath) && !strings.Contains(track.FilePath, "://") {
			if info, err := os.Stat(track.FilePath); err == nil && !info.IsDir() {
				local = append(local, track)
			}
		}
	}
	if len(local) == 0 {
		a.logf("stress: no local tracks")
		return
	}
	a.logf("stress: %d local tracks available", len(local))
	tracks = local
	for i := range count {
		index := i % len(tracks)
		a.logf("stress: click %d/%d track %q", i+1, count, tracks[index].Title)
		if err := a.PlayTracks(tracks, index); err != nil {
			a.logf("stress: click %d failed: %v", i+1, err)
		}
		time.Sleep(120 * time.Millisecond)
	}
	a.logf("stress: done %d clicks", count)
}

func (a *application) ChooseDirectory() {
	go a.chooseDirectory()
}

func (a *application) chooseDirectory() {
	if a.lib == nil || !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能扫描入库（生产库绝不被写）")
		return
	}
	paths, err := mygo.Dialog.Open(mygo.OpenDialogOptions{
		Title:       "选择音乐目录",
		ButtonLabel: "选择",
		Message:     "扫描这个目录里的音乐并加入曲库",
		Directory:   true,
	})
	if err != nil {
		a.setStatus("无法打开目录选择器：" + err.Error())
		return
	}
	if len(paths) == 0 {
		return
	}
	a.scanFolder(paths[0])
}

// --- scanning -------------------------------------------------------

func (a *application) scanFolder(folder string) {
	defer a.markScanDone()
	if a.lib == nil || !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能扫描入库")
		return
	}
	if a.scanning.Swap(true) {
		return
	}
	defer a.scanning.Store(false)
	a.scanCancel.Store(false)
	started := time.Now()
	a.logf("scan: start %q", folder)

	source, found, err := a.lib.SourceByFolder(context.Background(), folder)
	if err != nil {
		a.finishScan("", err, started)
		return
	}
	if !found {
		source = library.Source{
			ID:              fmt.Sprintf("src-%d", time.Now().UnixMicro()),
			Name:            folderName(folder),
			Kind:            "local",
			LocalFolderPath: folder,
			SyncStatus:      "未同步",
		}
		if err := a.lib.UpsertLocalSource(context.Background(), source); err != nil {
			a.finishScan("", err, started)
			return
		}
	}
	known, err := a.lib.FileFacts(context.Background(), source.ID)
	if err != nil {
		a.finishScan("", err, started)
		return
	}
	a.updateWindow(func() {
		a.model.SetScan(shell.ScanState{Running: true, Total: 0, Path: folder})
	})

	last := time.Time{}
	result := scan.Scan(folder, scan.Options{
		CoversDir: a.covers,
		Known:     known,
		Progress: func(done, total int, path string) {
			if done == 1 || done%50 == 0 || done == total {
				a.logf("scan: progress %d/%d %s", done, total, path)
			}
			if time.Since(last) < 30*time.Millisecond && done != total {
				return
			}
			last = time.Now()
			a.updateWindow(func() {
				a.model.SetScan(shell.ScanState{Running: true, Done: done, Total: total, Path: path})
			})
		},
		Cancelled: func() bool { return a.scanCancel.Load() },
	})
	if result.Cancelled {
		a.logf("scan: cancelled after %d/%d files", len(result.Tracks), result.Files)
	}
	merge, err := a.lib.MergeScan(context.Background(), source.ID, result.Tracks, result.Authoritative())
	if err != nil {
		a.finishScan("", err, started)
		return
	}
	count, err := a.lib.CountSourceTracks(context.Background(), source.ID)
	if err != nil {
		a.finishScan("", err, started)
		return
	}
	status := scanStatus(result, merge, count)
	if err := a.lib.UpdateSourceSync(context.Background(), source.ID, status, time.Now(), count); err != nil {
		a.logf("scan: update source: %v", err)
	}
	a.finishScan(status, nil, started)
	a.logf("scan: folder=%q files=%d stored=%d added=%d updated=%d removed=%d authoritative=%v elapsed=%s",
		folder, result.Files, count, merge.Added, merge.Updated, merge.Removed, result.Authoritative(), time.Since(started).Round(time.Millisecond))
	a.refresh()
	// A fresh scan just produced rows that miss tags; enrich them through the
	// same quota-bound pass the startup trigger uses.
	a.maybeAutoEnrich("scan")
}

func (a *application) finishScan(status string, err error, started time.Time) {
	if err != nil {
		a.logf("scan: failed: %v", err)
		a.updateWindow(func() {
			a.model.SetScan(shell.ScanState{Error: "扫描失败：" + err.Error()})
			a.model.SetError(err.Error())
		})
		return
	}
	a.updateWindow(func() {
		a.model.SetScan(shell.ScanState{Status: status})
	})
	a.logf("scan: done in %s: %s", time.Since(started).Round(time.Millisecond), status)
}

// scanStatus is the user-visible outcome. An authoritative scan states the
// file count and the stored count next to each other, which is exactly what
// acceptance rule 2 compares.
func scanStatus(result scan.Result, merge library.MergeResult, stored int64) string {
	if result.Authoritative() {
		return fmt.Sprintf("扫描完成：文件 %d，入库 %d（新增 %d / 更新 %d / 移除 %d）",
			result.Files, stored, merge.Added, merge.Updated, merge.Removed)
	}
	reason := fmt.Sprintf("跳过 %d 项", result.UnreadableFiles+result.UnreadableDirs)
	if result.Cancelled {
		reason = "已取消"
	} else if result.Truncated {
		reason = fmt.Sprintf("文件数达到上限 %d（可能未枚举完）", scan.MaxFiles)
	}
	return fmt.Sprintf("部分同步（%s；保留未扫描曲目；入库 %d；新增 %d / 更新 %d）",
		reason, stored, merge.Added, merge.Updated)
}

func folderName(folder string) string {
	cleaned := strings.TrimRight(folder, "/")
	if cleaned == "" {
		return folder
	}
	if index := strings.LastIndex(cleaned, "/"); index >= 0 && index+1 < len(cleaned) {
		return cleaned[index+1:]
	}
	return cleaned
}
