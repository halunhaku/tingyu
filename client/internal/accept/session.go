package accept

import (
	"fmt"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// session is one engine plus the controller that drives it, exactly as the app
// wires them (minus the window). Acceptance therefore exercises the production
// queue, loop, failure and prefetch code, not a parallel implementation.
type session struct {
	engine  *mpv.Player
	control *player.Controller
	log     func(format string, args ...any)
}

func newSession(lib *mpv.Lib, options map[string]string, logLevel string, headers map[string]map[string]string, log func(string, ...any)) (*session, error) {
	engine, err := mpv.NewPlayer(lib, mpv.Config{
		AudioClientName: "听屿M2",
		Options:         options,
		LogLevel:        logLevel,
		Debug:           log,
	})
	if err != nil {
		return nil, err
	}
	control := player.New(engine, resolver(headers), nil)
	var (
		mu       sync.Mutex
		lastText string
	)
	control.SetListener(func(update player.Update) {
		failure := update.Failure
		if failure == nil {
			return
		}
		text := fmt.Sprintf("kind=%s status=%d message=%q detail=%q",
			failure.Kind, failure.Status, failure.Message, failure.Detail)
		mu.Lock()
		changed := text != lastText
		lastText = text
		mu.Unlock()
		if changed {
			log("failure: %s", text)
		}
	})
	return &session{engine: engine, control: control, log: log}, nil
}

func (s *session) close() {
	if s.control != nil {
		_ = s.control.Close()
		return
	}
	if s.engine != nil {
		_ = s.engine.Close()
	}
}

// resolver turns a track's path into a playable item, adding the per-source
// headers acceptance configured for that URI.
func resolver(headers map[string]map[string]string) player.Resolver {
	return func(track library.Track) (player.Item, error) {
		if track.FilePath == "" {
			return player.Item{}, fmt.Errorf("track %s has no path", track.ID)
		}
		return player.Item{
			ID:       track.ID,
			TrackID:  track.ID,
			URI:      track.FilePath,
			Headers:  headers[track.FilePath],
			Title:    track.Title,
			Artist:   track.Artist,
			Album:    track.Album,
			Duration: track.Duration,
		}, nil
	}
}

// localTrack makes a track for a file on disk.
func localTrack(path string) library.Track {
	return library.Track{ID: path, Title: path, FilePath: path}
}

// waitUntil polls cond until it is true or the timeout passes. Polling is fine
// here: the controller publishes snapshots and its Snapshot() is a lock read.
func waitUntil(timeout time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return cond()
}

// snapshot is shorthand for the controller's latest update.
func (s *session) snapshot() player.Update {
	return s.control.Snapshot()
}

// play starts one or more tracks at index 0.
func (s *session) play(tracks []library.Track) error {
	return s.control.PlayTracks(tracks, 0)
}
