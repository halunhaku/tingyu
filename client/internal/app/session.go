//go:build darwin

package app

// Runtime logging, Now Playing publishing, the menu bar item, and shutdown.
// Split out of app.go to keep assembly readable.

import (
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

func (a *application) logf(format string, args ...any) {
	a.startup.printf(format, args...)
}

func (a *application) setStatus(status string) {
	a.logf("status: %s", status)
	a.updateWindow(func() { a.model.SetStatus(status) })
}

// onUpdate is called by the controller on whatever goroutine produced the
// snapshot (the engine loop, or the UI thread for a double click). It only
// queues, so the caller never waits on the main thread; one worker then fans
// the update out to the window, the menu bar and the media session, so the
// three cannot disagree.
func (a *application) onUpdate(update player.Update) {
	if a.quitting.Load() {
		return
	}
	select {
	case a.updates <- update:
	default:
		// The worker is behind; the next snapshot carries the full state.
	}
}

func (a *application) updateLoop() {
	for {
		select {
		case <-a.done:
			return
		case update := <-a.updates:
			a.applyUpdate(update)
		}
	}
}

func (a *application) applyUpdate(update player.Update) {
	if a.quitting.Load() {
		return
	}
	a.lastUpdateMu.Lock()
	a.lastUpdate = update
	a.lastUpdateMu.Unlock()
	a.updateWindow(func() { a.model.SetPlayer(update) })
	a.logLatency(update)
	a.updateTray(update)
	a.publishSession(update)
	// M3: an expired Quark direct link is refreshed once and replayed, instead
	// of leaving the user with a dead failure state.
	if a.recoverer != nil {
		a.recoverer.Handle(update)
	}
}

// logLatency reports click-to-sound. The clock starts in PlayTracks (the same
// entry a double click uses) and stops at the first snapshot that is playing
// with an advanced position, which is when libmpv is actually feeding the
// audio device.
func (a *application) logLatency(update player.Update) {
	if update.Track == nil || !update.Snapshot.Playing || update.Snapshot.Position <= 0 {
		return
	}
	a.soundMu.Lock()
	defer a.soundMu.Unlock()
	if !a.soundAt.IsZero() || a.playRequest.IsZero() {
		return
	}
	a.soundAt = time.Now()
	elapsed := a.soundAt.Sub(a.playRequest)
	a.logf("play: sound after %.1f ms for %q (index=%d)", float64(elapsed)/float64(time.Millisecond), update.Track.Title, update.Index)
}

// --- media session --------------------------------------------------
//
// The media session is mygo.NowPlaying's: the framework owns
// MPNowPlayingInfoCenter and MPRemoteCommandCenter (and SMTC/MPRIS on the
// other platforms), so the client only says what plays and listens for the
// system's commands. M1's own Objective-C implementation is gone; its App Nap
// and idle-sleep guard moved to mygo.Power.KeepAwake, which raises the same
// PreventUserIdleSystemSleep assertion `pmset -g assertions` reports.

type sessionPublisher struct {
	ready atomic.Bool
	force atomic.Bool

	lastID         string
	lastIndex      int
	lastDuration   time.Duration
	lastPlaying    bool
	lastProcessing mpv.Processing
	lastRate       float64
	lastCommands   mygo.MediaCommand
	lastPush       time.Time

	// artPath is the cover the session last showed and artData its bytes. The
	// framework takes artwork as bytes and clones them, so the app reads the
	// file only when the cover changes.
	artPath string
	artData []byte
}

// mediaControl is the subset of *player.Controller that the system's commands
// drive; session_test.go fakes it.
type mediaControl interface {
	Play() error
	Pause() error
	Next() error
	Previous() error
	Seek(time.Duration) error
}

// handleMediaCommand runs one command of the system's media session. It is a
// plain function so a test can prove every command reaches the right control
// call without a running app.
func handleMediaCommand(control mediaControl, logf func(string, ...any), command mygo.MediaCommand, position time.Duration) {
	if logf != nil {
		logf("media: command %s pos=%.3f", mediaCommandName(command), position.Seconds())
	}
	if control == nil {
		return
	}
	switch command {
	case mygo.MediaPlay:
		_ = control.Play()
	case mygo.MediaPause, mygo.MediaStop:
		_ = control.Pause()
	case mygo.MediaNext:
		_ = control.Next()
	case mygo.MediaPrevious:
		_ = control.Previous()
	case mygo.MediaSeek:
		_ = control.Seek(position)
	}
}

// mediaCommandName is the log name of a command, the one M1's log lines used.
// The play/pause key arrives as play or pause, as mygo.NowPlaying folds the
// system's toggle into the state it was told (see its OnCommand docs).
func mediaCommandName(command mygo.MediaCommand) string {
	switch command {
	case mygo.MediaPlay:
		return "play"
	case mygo.MediaPause:
		return "pause"
	case mygo.MediaStop:
		return "stop"
	case mygo.MediaNext:
		return "nextTrack"
	case mygo.MediaPrevious:
		return "previousTrack"
	case mygo.MediaSeek:
		return "changePlaybackPosition"
	}
	return fmt.Sprintf("MediaCommand(%#x)", uint32(command))
}

// nowPlayingCommands is the command set the system's controls should offer:
// play and pause always, seek when the track has a duration, and next and
// previous when the queue has one. The framework strips seek when the info's
// duration is zero, and adds the play/pause key itself.
func nowPlayingCommands(bounds queueBounds, duration time.Duration) mygo.MediaCommand {
	commands := mygo.MediaPlay | mygo.MediaPause
	if duration > 0 {
		commands |= mygo.MediaSeek
	}
	if bounds.hasNext {
		commands |= mygo.MediaNext
	}
	if bounds.hasPrev {
		commands |= mygo.MediaPrevious
	}
	return commands
}

func (a *application) initSession() {
	mygo.NowPlaying.OnCommand(func(command mygo.MediaCommand, position time.Duration) {
		var control mediaControl
		if a.control != nil {
			control = a.control
		}
		handleMediaCommand(control, a.logf, command, position)
	})
	a.session.ready.Store(true)
	a.logf("session: mygo.NowPlaying ready")
	a.lastUpdateMu.Lock()
	update := a.lastUpdate
	a.lastUpdateMu.Unlock()
	if update.Track != nil {
		a.session.force.Store(true)
		// Go through the worker like every other update: session state is
		// owned by that one goroutine.
		a.onUpdate(update)
	}
}

// publishSession pushes Now Playing with the Flutter handler's rules (plan
// §5.1): metadata is deduplicated by (id, index, duration, artwork, commands)
// and a new session always resends it; progress-only updates are throttled to
// 500 ms, while a change of playing/processing/index/rate is immediate.
func (a *application) publishSession(update player.Update) {
	session := &a.session
	if !session.ready.Load() || update.Track == nil {
		return
	}
	force := session.force.Load()
	track := update.Track
	// The library's duration is for this track; mpv's may still be the
	// previous file's for a moment after a track change, which would push a
	// wrong duration to Now Playing. Prefer the library's when it has one.
	duration := track.Duration
	if duration <= 0 {
		duration = update.Snapshot.Duration
	}
	artwork, artChanged := a.sessionArtwork(track)
	commands := nowPlayingCommands(a.queueSize(update), duration)
	state := mygo.PlaybackPaused
	if update.Snapshot.Playing {
		state = mygo.PlaybackPlaying
	}

	metadataChanged := force ||
		session.lastID != track.ID ||
		session.lastIndex != update.Index ||
		session.lastDuration != duration ||
		session.lastCommands != commands ||
		session.lastRate != update.Snapshot.Rate ||
		artChanged
	semanticsChanged := force ||
		session.lastPlaying != update.Snapshot.Playing ||
		session.lastProcessing != update.Snapshot.Processing ||
		session.lastIndex != update.Index

	if metadataChanged {
		mygo.NowPlaying.Set(mygo.NowPlayingInfo{
			Title:    track.Title,
			Artist:   track.Artist,
			Album:    track.Album,
			Artwork:  artwork,
			Duration: duration,
			Position: update.Snapshot.Position,
			Rate:     update.Snapshot.Rate,
			State:    state,
			Commands: commands,
		})
		readback := "unavailable"
		if info, ok := mygo.NowPlaying.Info(); ok {
			readback = fmt.Sprintf("title=%q artist=%q duration=%v state=%d", info.Title, info.Artist, info.Duration, info.State)
		}
		a.logf("session: metadata id=%s title=%q artist=%q artwork=%v commands=%#x readback=%s",
			track.ID, track.Title, track.Artist, len(artwork) > 0, commands, readback)
		session.lastID = track.ID
		session.lastIndex = update.Index
		session.lastDuration = duration
		session.lastCommands = commands
	}

	now := time.Now()
	if metadataChanged || semanticsChanged || now.Sub(session.lastPush) >= 500*time.Millisecond {
		if !metadataChanged {
			mygo.NowPlaying.SetPlayback(state, update.Snapshot.Position)
		}
		a.logf("session: state playing=%v rate=%.2f pos=%.3f dur=%.1f processing=%s",
			update.Snapshot.Playing, update.Snapshot.Rate, update.Snapshot.Position.Seconds(), duration.Seconds(), update.Snapshot.Processing)
		if metadataChanged || semanticsChanged {
			if info, ok := mygo.NowPlaying.Info(); ok {
				a.logf("session: state readback state=%d pos=%v duration=%v artworkPresent=%v",
					info.State, info.Position, info.Duration, len(info.Artwork) > 0)
			}
		}
		session.lastPlaying = update.Snapshot.Playing
		session.lastProcessing = update.Snapshot.Processing
		session.lastRate = update.Snapshot.Rate
		session.lastPush = now
	}
	session.force.Store(false)

	if a.awake.Load() != update.Snapshot.Playing {
		a.setKeepAwake(update.Snapshot.Playing)
	}
}

// sessionArtwork returns the cover bytes Now Playing should show, reading the
// file only when the cover changes. changed reports whether the session's
// artwork may differ from what it showed.
func (a *application) sessionArtwork(track *library.Track) (data []byte, changed bool) {
	session := &a.session
	path := ""
	if track.CoverArtPath != "" && a.covers != "" {
		candidate := filepath.Join(a.covers, track.CoverArtPath)
		if _, err := os.Stat(candidate); err == nil {
			path = candidate
		}
	}
	if path == session.artPath {
		return session.artData, false
	}
	session.artPath = path
	session.artData = nil
	if path != "" {
		if raw, err := os.ReadFile(path); err == nil {
			session.artData = raw
		} else {
			a.logf("session: artwork: %v", err)
		}
	}
	return session.artData, true
}

// setKeepAwake raises or releases the App Nap and idle-sleep guard while audio
// plays. mygo.Power.KeepAwake runs NSProcessInfo's activity (which keeps App
// Nap from throttling the process) and IOKit's power assertion; measured with
// `pmset -g assertions`, the assertion is the same
// `PreventUserIdleSystemSleep named: "…"` M1's own implementation raised
// (S2 item 7). The reason stays ASCII on purpose: with a Chinese reason the
// framework's darwin backend passes an empty string to the system, and pmset
// then shows `named: ""` (measured; recorded in the migration record).
func (a *application) setKeepAwake(on bool) {
	a.awakeMu.Lock()
	defer a.awakeMu.Unlock()
	if on {
		if a.awakeRelease == nil {
			a.awakeRelease = mygo.Power.KeepAwake("tingyu: playing audio", false)
		}
		a.awake.Store(true)
		a.logf("session: keeps awake true")
		return
	}
	if a.awakeRelease != nil {
		a.awakeRelease()
		a.awakeRelease = nil
	}
	a.awake.Store(false)
	a.logf("session: keeps awake false")
}

type queueBounds struct {
	hasNext bool
	hasPrev bool
}

func (a *application) queueSize(update player.Update) queueBounds {
	if a.control == nil {
		return queueBounds{}
	}
	queue := a.control.Queue()
	if len(queue) <= 1 {
		return queueBounds{}
	}
	repeat := a.control.Repeat()
	return queueBounds{
		hasNext: update.Index < len(queue)-1 || repeat == player.RepeatAll,
		hasPrev: update.Index > 0 || repeat == player.RepeatAll,
	}
}

// --- application menu ------------------------------------------------

// installMenu builds the macOS menu the design calls for: 听屿 (settings,
// sources, quit), 播放 (play/pause, previous/next, stage), 前往 (the pages),
// plus the standard Edit and Window menus. Menu actions run on the main
// thread; model changes go through updateWindow so the next frame shows them.
func (a *application) installMenu() {
	openPage := func(page string) func(*mygo.MenuItem, *mygo.Window) {
		return func(*mygo.MenuItem, *mygo.Window) {
			a.updateWindow(func() { a.model.State().OpenPage(page) })
		}
	}
	commands := func(id string) func(*mygo.MenuItem, *mygo.Window) {
		return func(*mygo.MenuItem, *mygo.Window) {
			a.updateWindow(func() { a.model.State().RunCommand(id) })
		}
	}
	menu := mygo.NewMenu([]*mygo.MenuItem{
		{Label: "听屿", Submenu: []*mygo.MenuItem{
			{Role: mygo.RoleAbout},
			mygo.Separator(),
			{Label: "设置…", Accelerator: "Cmd+,", Click: openPage("settings")},
			{Label: "来源管理…", Click: openPage("sources")},
			mygo.Separator(),
			{Role: mygo.RoleHide},
			{Role: mygo.RoleHideOthers},
			{Role: mygo.RoleUnhide},
			mygo.Separator(),
			{Role: mygo.RoleQuit},
		}},
		{Role: mygo.RoleEditMenu},
		{Label: "播放", Submenu: []*mygo.MenuItem{
			{Label: "播放 / 暂停", Accelerator: "Cmd+P", Click: commands("media.toggle")},
			{Label: "上一首", Accelerator: "Cmd+Left", Click: func(*mygo.MenuItem, *mygo.Window) { _ = a.Previous() }},
			{Label: "下一首", Accelerator: "Cmd+Right", Click: func(*mygo.MenuItem, *mygo.Window) { _ = a.Next() }},
			mygo.Separator(),
			{Label: "打开播放舞台", Accelerator: "Cmd+Shift+P", Click: commands("go.stage")},
		}},
		{Label: "前往", Submenu: []*mygo.MenuItem{
			{Label: "曲库", Accelerator: "Cmd+1", Click: openPage("library")},
			{Label: "搜索", Accelerator: "Cmd+2", Click: openPage("search")},
			{Label: "收藏", Accelerator: "Cmd+3", Click: openPage("favorites")},
			{Label: "音乐来源", Accelerator: "Cmd+4", Click: openPage("sources")},
			mygo.Separator(),
			{Label: "播放队列", Accelerator: "Cmd+U", Click: openPage("queue")},
			{Label: "歌词", Accelerator: "Cmd+L", Click: openPage("lyrics")},
		}},
		{Role: mygo.RoleWindowMenu},
		{Role: mygo.RoleHelp},
	})
	mygo.App.SetMenu(menu)
	a.logf("menu: application menu installed")
}

// --- menu bar -------------------------------------------------------

func (a *application) initTray() {
	show := &mygo.MenuItem{Label: "显示窗口", Click: func(*mygo.MenuItem, *mygo.Window) {
		a.showWindow()
	}}
	previous := &mygo.MenuItem{Label: "上一首", Click: func(*mygo.MenuItem, *mygo.Window) {
		_ = a.Previous()
	}}
	play := &mygo.MenuItem{Label: "播放", Click: func(*mygo.MenuItem, *mygo.Window) {
		_ = a.TogglePlayPause()
	}}
	next := &mygo.MenuItem{Label: "下一首", Click: func(*mygo.MenuItem, *mygo.Window) {
		_ = a.Next()
	}}
	quit := &mygo.MenuItem{Label: "退出听屿", Click: func(*mygo.MenuItem, *mygo.Window) {
		a.logf("app: quit from menu bar")
		mygo.App.Quit()
	}}
	menu := mygo.NewMenu([]*mygo.MenuItem{
		show,
		mygo.Separator(),
		previous,
		play,
		next,
		mygo.Separator(),
		quit,
	})
	tray, err := mygo.NewTray(mygo.TrayOptions{
		ID:             "tingyu",
		Icon:           trayIcon,
		IconIsTemplate: true,
		Title:          "听屿",
		ToolTip:        "听屿",
		Menu:           menu,
	})
	if err != nil {
		a.logf("tray: unavailable: %v", err)
		return
	}
	a.trayMu.Lock()
	a.trayPlay = play
	a.tray = tray
	a.trayMu.Unlock()
	bounds := tray.Bounds()
	a.logf("tray: menu bar item ready at x=%d y=%d w=%d h=%d", bounds.X, bounds.Y, bounds.Width, bounds.Height)
	go func() {
		time.Sleep(time.Second)
		late := tray.Bounds()
		a.logf("tray: bounds after 1s x=%d y=%d w=%d h=%d", late.X, late.Y, late.Width, late.Height)
	}()
}

func (a *application) updateTray(update player.Update) {
	a.trayMu.Lock()
	tray, play := a.tray, a.trayPlay
	a.trayMu.Unlock()
	if play != nil {
		label := "播放"
		if update.Snapshot.Playing {
			label = "暂停"
		}
		play.SetLabel(label)
	}
	if tray != nil {
		tip := "听屿"
		if update.Track != nil {
			tip = fmt.Sprintf("听屿 · %s — %s", update.Track.Title, update.Track.Artist)
		}
		tray.SetToolTip(tip)
	}
}

// --- shutdown -------------------------------------------------------

func (a *application) shutdown() {
	if !a.quitting.CompareAndSwap(false, true) {
		return
	}
	a.logf("app: quitting")
	close(a.done)
	a.scanCancel.Store(true)
	if a.session.ready.Load() {
		mygo.NowPlaying.Clear()
		a.logf("session: now playing cleared")
	}
	if a.awake.Load() {
		a.setKeepAwake(false)
	}
	a.trayMu.Lock()
	tray := a.tray
	a.tray = nil
	a.trayMu.Unlock()
	if tray != nil {
		tray.Destroy()
	}
	if a.control != nil {
		if err := a.control.Close(); err != nil {
			a.logf("playback: close: %v", err)
		} else {
			a.logf("playback: engine closed")
		}
	} else if a.engine != nil {
		_ = a.engine.Close()
	}
	if a.lib != nil {
		if err := a.lib.Close(); err != nil {
			a.logf("library: close: %v", err)
		}
	}
	a.logf("app: quit complete")
}
