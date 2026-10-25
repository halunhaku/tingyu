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

	"github.com/halunhaku/tingyu/client/internal/mediasession"
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

type sessionPublisher struct {
	ready atomic.Bool
	force atomic.Bool

	lastID         string
	lastIndex      int
	lastDuration   time.Duration
	lastPlaying    bool
	lastProcessing mpv.Processing
	lastRate       float64
	lastPush       time.Time
}

func (a *application) initSession() {
	if err := mediasession.Init(); err != nil {
		a.logf("session: unavailable: %v", err)
		return
	}
	a.session.ready.Store(true)
	mediasession.SetHandler(func(command mediasession.Command, arg float64) {
		a.logf("media: command %s arg=%.3f", command, arg)
		if a.control == nil {
			return
		}
		switch command {
		case mediasession.CmdPlay:
			_ = a.control.Play()
		case mediasession.CmdPause:
			_ = a.control.Pause()
		case mediasession.CmdToggle:
			_ = a.control.TogglePlayPause()
		case mediasession.CmdNext:
			_ = a.control.Next()
		case mediasession.CmdPrev:
			_ = a.control.Previous()
		case mediasession.CmdSeek:
			_ = a.control.Seek(time.Duration(arg * float64(time.Second)))
		}
	})
	a.lastUpdateMu.Lock()
	update := a.lastUpdate
	a.lastUpdateMu.Unlock()
	if update.Track != nil {
		a.session.force.Store(true)
		// Go through the worker like every other update: session state is
		// owned by that one goroutine.
		a.onUpdate(update)
	}
	commands, err := mediasession.CommandStatus()
	if err == nil {
		a.logf("session: commands enabled %v", commands)
	}
}

// publishSession pushes Now Playing with the Flutter handler's rules (plan
// §5.1): metadata is deduplicated by (id, index, duration) and a new session
// always resends it; progress-only updates are throttled to 500 ms, while a
// change of playing/processing/index/rate is immediate.
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
	artwork := ""
	if track.CoverArtPath != "" && a.covers != "" {
		path := filepath.Join(a.covers, track.CoverArtPath)
		if _, err := os.Stat(path); err == nil {
			artwork = path
		}
	}

	semanticsChanged := force ||
		session.lastPlaying != update.Snapshot.Playing ||
		session.lastProcessing != update.Snapshot.Processing ||
		session.lastIndex != update.Index ||
		session.lastRate != update.Snapshot.Rate
	metadataChanged := force ||
		session.lastID != track.ID ||
		session.lastIndex != update.Index ||
		session.lastDuration != duration

	if metadataChanged {
		err := mediasession.SetMetadata(mediasession.Metadata{
			Title:       track.Title,
			Artist:      track.Artist,
			Album:       track.Album,
			DurationSec: duration.Seconds(),
			ArtPath:     artwork,
		})
		if err != nil {
			a.logf("session: metadata: %v", err)
		} else {
			info, _ := mediasession.NowPlayingInfo()
			a.logf("session: metadata id=%s title=%q artist=%q artwork=%v readback=%v", track.ID, track.Title, track.Artist, artwork != "", info)
		}
		session.lastID = track.ID
		session.lastIndex = update.Index
		session.lastDuration = duration
	}

	now := time.Now()
	if metadataChanged || semanticsChanged || now.Sub(session.lastPush) >= 500*time.Millisecond {
		if err := mediasession.SetState(mediasession.State{
			Playing:  update.Snapshot.Playing,
			Rate:     update.Snapshot.Rate,
			Position: update.Snapshot.Position.Seconds(),
			Duration: duration.Seconds(),
		}); err != nil {
			a.logf("session: state: %v", err)
		} else {
			a.logf("session: state playing=%v rate=%.2f pos=%.3f dur=%.1f processing=%s",
				update.Snapshot.Playing, update.Snapshot.Rate, update.Snapshot.Position.Seconds(), duration.Seconds(), update.Snapshot.Processing)
			if metadataChanged || semanticsChanged {
				if info, err := mediasession.NowPlayingInfo(); err == nil {
					a.logf("session: state readback playbackState=%v rate=%v elapsed=%v artworkPresent=%v",
						info["playbackState"], info["rate"], info["elapsed"], info["artworkPresent"])
				}
			}
		}
		queue := a.queueSize(update)
		if err := mediasession.SetEnabledCommands(queue.hasNext, queue.hasPrev); err != nil {
			a.logf("session: commands: %v", err)
		}
		session.lastPlaying = update.Snapshot.Playing
		session.lastProcessing = update.Snapshot.Processing
		session.lastRate = update.Snapshot.Rate
		session.lastPush = now
	}
	session.force.Store(false)

	if a.awake.Load() != update.Snapshot.Playing {
		if err := mediasession.SetKeepsAwake(update.Snapshot.Playing); err == nil {
			a.awake.Store(update.Snapshot.Playing)
			a.logf("session: keeps awake %v", update.Snapshot.Playing)
		}
	}
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

// --- menu bar -------------------------------------------------------

func (a *application) initTray() {
	show := &mygo.MenuItem{Label: "显示窗口", Click: func(*mygo.MenuItem, *mygo.Window) {
		a.showWindow()
	}}
	previous := &mygo.MenuItem{Label: "上一首", Click: func(*mygo.MenuItem, *mygo.Window) {
		_ = a.Previous()
	}}
	a.trayPlay = &mygo.MenuItem{Label: "播放", Click: func(*mygo.MenuItem, *mygo.Window) {
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
		a.trayPlay,
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
	a.tray = tray
	bounds := tray.Bounds()
	a.logf("tray: menu bar item ready at x=%d y=%d w=%d h=%d", bounds.X, bounds.Y, bounds.Width, bounds.Height)
	go func() {
		time.Sleep(time.Second)
		late := tray.Bounds()
		a.logf("tray: bounds after 1s x=%d y=%d w=%d h=%d", late.X, late.Y, late.Width, late.Height)
	}()
}

func (a *application) updateTray(update player.Update) {
	if a.trayPlay != nil {
		label := "播放"
		if update.Snapshot.Playing {
			label = "暂停"
		}
		a.trayPlay.SetLabel(label)
	}
	if a.tray != nil {
		tip := "听屿"
		if update.Track != nil {
			tip = fmt.Sprintf("听屿 · %s — %s", update.Track.Title, update.Track.Artist)
		}
		a.tray.SetToolTip(tip)
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
		if err := mediasession.Clear(); err != nil {
			a.logf("session: clear: %v", err)
		} else {
			a.logf("session: now playing cleared")
		}
		_ = mediasession.SetKeepsAwake(false)
	}
	if a.tray != nil {
		a.tray.Destroy()
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
