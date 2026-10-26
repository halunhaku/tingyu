package sources

// Direct-link recovery. A Quark direct link carries its signature in the query
// string and expires; when the engine reports a 401/403 for a `quark://` track,
// the link is minted again and the track replayed from where it was.
//
// The replay goes through the controller's public PlayTracks entry, so the
// engine receives a *different* URI. That matters: mpv may reuse the demuxer of
// a URI it already loaded (M2 record §4.5), so rotating a token inside one URI
// would not be observed. The policy lives here, not in internal/app, so the
// acceptance harness exercises exactly the code the app runs.

import (
	"strings"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// RecoveryControl is what a recoverer drives: the production controller has all
// four methods.
type RecoveryControl interface {
	Queue() []library.Track
	PlayTracks(tracks []library.Track, start int) error
	Seek(position time.Duration) error
	Snapshot() player.Update
}

// Recoverer refreshes expired direct links.
type Recoverer struct {
	Manager *Manager
	Control RecoveryControl
	Logf    func(string, ...any)
	// Cooldown is how long a track is left alone after one refresh attempt
	// (default 30 s): a revoked login must not become a retry loop.
	Cooldown time.Duration
	// SeekTimeout bounds how long the replay waits for the engine to be ready
	// before seeking back to the old position (default 5 s).
	SeekTimeout time.Duration

	mu   sync.Mutex
	last map[string]time.Time
}

// NewRecoverer builds one for a controller.
func NewRecoverer(manager *Manager, control RecoveryControl, logf func(string, ...any)) *Recoverer {
	return &Recoverer{Manager: manager, Control: control, Logf: logf, last: map[string]time.Time{}}
}

// Handle inspects one playback update and starts a refresh when it is a
// Quark direct-link rejection. It reports whether a refresh was started; it
// never blocks (the replay runs in a goroutine).
func (r *Recoverer) Handle(update player.Update) bool {
	if r == nil || r.Manager == nil || r.Control == nil {
		return false
	}
	if update.Failure == nil || update.Track == nil {
		return false
	}
	if update.Failure.Kind != mpv.FailureUnauthorized {
		return false
	}
	track := *update.Track
	if !strings.HasPrefix(track.FilePath, QuarkURIScheme) {
		return false
	}
	cooldown := r.Cooldown
	if cooldown <= 0 {
		cooldown = 30 * time.Second
	}
	r.mu.Lock()
	if r.last == nil {
		r.last = map[string]time.Time{}
	}
	if last, ok := r.last[track.ID]; ok && time.Since(last) < cooldown {
		r.mu.Unlock()
		return false
	}
	r.last[track.ID] = time.Now()
	r.mu.Unlock()

	position := update.Snapshot.Position
	r.log("sources: quark direct link rejected for %q (HTTP %d, at %.1fs); refreshing",
		track.Title, update.Failure.Status, position.Seconds())
	go r.refresh(track, position)
	return true
}

// refresh mints a new link and replays the track at position.
func (r *Recoverer) refresh(track library.Track, position time.Duration) {
	r.Manager.RefreshTrack(track)
	queue := r.Control.Queue()
	index := -1
	for i := range queue {
		if queue[i].ID == track.ID {
			index = i
			break
		}
	}
	if index < 0 {
		r.log("sources: refreshed the link but %q left the queue", track.Title)
		return
	}
	if err := r.Control.PlayTracks(queue, index); err != nil {
		r.log("sources: replay after link refresh failed: %v", err)
		return
	}
	r.log("sources: refreshed direct link, replaying %q", track.Title)
	if position <= 0 {
		return
	}
	timeout := r.SeekTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		snapshot := r.Control.Snapshot().Snapshot
		if snapshot.Processing != mpv.Loading {
			if err := r.Control.Seek(position); err != nil {
				r.log("sources: seek after refresh: %v", err)
			} else {
				r.log("sources: resumed at %.1fs after link refresh", position.Seconds())
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	r.log("sources: engine did not become ready in %s; not seeking", timeout)
}

func (r *Recoverer) log(format string, args ...any) {
	if r.Logf != nil {
		r.Logf(format, args...)
	}
}
