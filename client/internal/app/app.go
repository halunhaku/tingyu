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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/scan"
	"github.com/halunhaku/tingyu/client/internal/shell"
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
		a.showWindow()
		a.initSession()
		a.initTray()
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

	var tracks []library.Track
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
			tracks, err = lib.Tracks(ctx)
			if err != nil {
				loadErr = fmt.Errorf("%s: %w", a.path, err)
			} else {
				a.logf("library: %d tracks from %s (%s, user_version %d)", len(tracks), a.path, mode, library.SchemaVersion)
				a.startup.mark("library read")
			}
		}
	}

	a.model = shell.New(tracks, a.path, loadErr)
	a.model.SetActions(a)

	a.engine, err = a.newEngine()
	if err != nil {
		a.logf("playback: %v", err)
		a.model.SetError("播放内核不可用：" + err.Error())
	} else if a.lib != nil {
		a.control = player.New(a.engine, localResolver, a.lib)
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
		a.reloadTracks()
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

// localResolver is the M1 resolver: a library track is a local file.
func localResolver(track library.Track) (player.Item, error) {
	if track.FilePath == "" {
		return player.Item{}, errors.New("曲目没有文件路径")
	}
	return player.Item{
		ID:       track.ID,
		TrackID:  track.ID,
		URI:      track.FilePath,
		Title:    track.Title,
		Artist:   track.Artist,
		Album:    track.Album,
		Duration: track.Duration,
		ArtPath:  "",
	}, nil
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

func (a *application) reloadTracks() {
	if a.lib == nil {
		return
	}
	tracks, err := a.lib.Tracks(context.Background())
	if err != nil {
		a.logf("library: reload: %v", err)
		return
	}
	revisions := make(map[string]uint64, len(tracks))
	for _, track := range tracks {
		revisions[track.ID] = a.lib.RowRevision(track.ID)
	}
	revision := a.lib.Revision()
	a.updateWindow(func() { a.model.SetTracks(tracks, revision, revisions) })
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
	tracks, err := a.lib.Tracks(context.Background())
	if err != nil || index < 0 || index >= len(tracks) {
		a.logf("accept: track index %d unavailable: %v", index, err)
		return
	}
	_ = a.PlayTracks(tracks, index)
}

// acceptancePlayTitle starts the first local track whose title contains title.
func (a *application) acceptancePlayTitle(title string) {
	a.waitForScan()
	if a.lib == nil || a.control == nil {
		a.logf("accept: cannot play: library or engine unavailable")
		return
	}
	tracks, err := a.lib.Tracks(context.Background())
	if err != nil {
		a.logf("accept: cannot read tracks: %v", err)
		return
	}
	for i, track := range tracks {
		if strings.Contains(track.Title, title) && filepath.IsAbs(track.FilePath) {
			a.logf("accept: title %q matched %q at %d", title, track.Title, i)
			_ = a.PlayTracks(tracks, i)
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
	tracks, err := a.lib.Tracks(context.Background())
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
	a.reloadTracks()
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
