// Package player is the playback controller: the UI and the media session talk
// to it, never to libmpv directly.
//
// It owns the queue contract from plan §4.5 — lazy resolution, two items ahead
// of the current one, a generation number that makes results from an abandoned
// queue inert, and an "armed" gate that keeps prefetch results from landing on
// a queue that is being replaced. The three parallel arrays the Flutter
// controller had to keep aligned (items, track ids, source indexes) are one
// slice of resolvedItem here: alignment is structural, not a convention.
//
// M1 resolves local files; the Resolver indirection is what M3 will use for
// WebDAV and Quark direct links without touching the controller.
package player

import (
	"context"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
)

// RepeatMode is the loop mode.
type RepeatMode int

const (
	RepeatOff RepeatMode = iota
	RepeatAll
	RepeatOne
)

func (r RepeatMode) String() string {
	switch r {
	case RepeatAll:
		return "全部循环"
	case RepeatOne:
		return "单曲循环"
	}
	return "不循环"
}

// Item is a resolved queue entry: what the engine needs, plus what the media
// session shows.
type Item struct {
	ID       string
	URI      string
	Headers  map[string]string
	Title    string
	Artist   string
	Album    string
	Duration time.Duration
	ArtPath  string
	TrackID  string
}

// Resolver turns a library track into a playable item. M1 resolves the file
// path; M3 will add direct-link fetching and per-track headers.
type Resolver func(track library.Track) (Item, error)

// History is the only library write the controller performs: play count and
// duration backfill.
type History interface {
	RecordPlay(ctx context.Context, id string) (int64, error)
	BackfillDuration(ctx context.Context, id string, duration time.Duration) (bool, error)
}

// Engine is the subset of an audio engine the controller needs.
type Engine interface {
	SetQueue(items []mpv.Item, start int) error
	Append(item mpv.Item) error
	Play() error
	Pause() error
	Seek(position time.Duration) error
	SetRate(rate float64) error
	SetVolume(volume float64) error
	SetRepeatOne(on bool) error
	Next() error
	Prev() error
	PlayIndex(index int) error
	Snapshot() mpv.Snapshot
	Subscribe() (<-chan mpv.Snapshot, func())
	Close() error
}

// Update is what listeners (window and media session) receive.
type Update struct {
	Snapshot  mpv.Snapshot
	Index     int
	Track     *library.Track
	Repeat    RepeatMode
	Failure   *mpv.Failure
	PlayCount int64
}

// Controller drives an engine.
type Controller struct {
	engine  Engine
	resolve Resolver
	history History

	mu           sync.Mutex
	queue        []library.Track // rotated so queue[0] is what the user picked
	resolved     []resolvedItem  // appended to the engine, in order
	resolvedNext int             // next queue index to resolve
	generation   uint64
	armed        bool
	prefetching  bool
	repeat       RepeatMode
	closed       bool

	currentIndex int
	currentTrack *library.Track
	update       Update
	failure      *mpv.Failure

	lastRecordedID   string
	durationRecordID string
	completionDone   bool

	listener func(Update)

	unsubscribe func()
	done        chan struct{}
}

type resolvedItem struct {
	item        Item
	sourceIndex int
}

// New creates a controller for engine.
func New(engine Engine, resolve Resolver, history History) *Controller {
	c := &Controller{
		engine:       engine,
		resolve:      resolve,
		history:      history,
		repeat:       RepeatAll, // the Flutter client's default
		currentIndex: 0,
		done:         make(chan struct{}),
	}
	c.update = Update{Snapshot: engine.Snapshot(), Repeat: c.repeat}
	events, unsubscribe := engine.Subscribe()
	c.unsubscribe = unsubscribe
	go c.loop(events)
	return c
}

func (c *Controller) loop(events <-chan mpv.Snapshot) {
	for {
		select {
		case <-c.done:
			return
		case snapshot, ok := <-events:
			if !ok {
				return
			}
			c.onSnapshot(snapshot)
		}
	}
}

// SetListener installs the update callback. It is called from the engine's
// event goroutine and from controller methods; implementations must be quick
// and must not call back into the controller.
func (c *Controller) SetListener(listener func(Update)) {
	c.mu.Lock()
	c.listener = listener
	c.mu.Unlock()
	c.notify()
}

// Snapshot returns the latest update.
func (c *Controller) Snapshot() Update {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.update
}

// Repeat returns the loop mode.
func (c *Controller) Repeat() RepeatMode {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.repeat
}

// SetVolume sets 0..1.
func (c *Controller) SetVolume(volume float64) error {
	return c.engine.SetVolume(volume)
}

// PlayTracks starts playTracks at start. The queue is rotated so the chosen
// track plays first and the rest of the list follows, then the beginning:
// exactly the Flutter controller's sequential order.
func (c *Controller) PlayTracks(tracks []library.Track, start int) error {
	if len(tracks) == 0 {
		return nil
	}
	if start < 0 || start >= len(tracks) {
		start = 0
	}
	rotated := make([]library.Track, 0, len(tracks))
	rotated = append(rotated, tracks[start:]...)
	rotated = append(rotated, tracks[:start]...)

	c.mu.Lock()
	c.generation++
	generation := c.generation
	c.queue = rotated
	c.resolved = nil
	c.resolvedNext = 0
	c.armed = false
	c.prefetching = false
	c.currentIndex = 0
	c.currentTrack = &c.queue[0]
	c.failure = nil
	c.completionDone = false
	c.lastRecordedID = ""
	c.durationRecordID = ""
	c.mu.Unlock()

	// Resolve the clicked track first and start it; the rest is prefetched.
	item, err := c.resolve(rotated[0])
	if err != nil {
		c.fail(&mpv.Failure{Message: err.Error(), Title: rotated[0].Title})
		return err
	}
	if !c.stillCurrent(generation) {
		return nil
	}
	engineItems := []mpv.Item{{URI: item.URI, Headers: item.Headers}}
	if err := c.engine.SetQueue(engineItems, 0); err != nil {
		c.fail(&mpv.Failure{Message: err.Error(), Title: item.Title})
		return err
	}
	c.mu.Lock()
	if generation != c.generation {
		c.mu.Unlock()
		return nil
	}
	c.resolved = []resolvedItem{{item: item, sourceIndex: 0}}
	c.resolvedNext = 1
	// The engine queue is in place; only now may prefetch append to it.
	c.armed = true
	snapshot := c.engine.Snapshot()
	c.update = Update{Snapshot: snapshot, Index: 0, Track: &c.queue[0], Repeat: c.repeat}
	one := c.repeat == RepeatOne
	c.mu.Unlock()
	_ = c.engine.SetRepeatOne(one)

	if err := c.engine.Play(); err != nil {
		c.fail(&mpv.Failure{Message: err.Error(), Title: item.Title})
		return err
	}
	c.notify()
	go c.ensureAhead(prefetchCount, generation)
	return nil
}

const prefetchCount = 2

func (c *Controller) stillCurrent(generation uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed && generation == c.generation
}

// ensureAhead appends until min items are queued after the current one, or
// until the whole rotated queue is in. A generation check after every await
// makes an in-flight prefetch from a replaced queue inert.
func (c *Controller) ensureAhead(minimum int, generation uint64) {
	c.mu.Lock()
	if c.closed || !c.armed || c.prefetching || generation != c.generation {
		c.mu.Unlock()
		return
	}
	if c.resolvedNext >= len(c.queue) {
		c.mu.Unlock()
		return
	}
	if len(c.resolved)-c.currentIndex-1 >= minimum {
		c.mu.Unlock()
		return
	}
	c.prefetching = true
	c.mu.Unlock()

	defer func() {
		c.mu.Lock()
		if generation == c.generation {
			c.prefetching = false
		}
		c.mu.Unlock()
	}()

	for {
		c.mu.Lock()
		if c.closed || !c.armed || generation != c.generation {
			c.mu.Unlock()
			return
		}
		if c.resolvedNext >= len(c.queue) || len(c.resolved)-c.currentIndex-1 >= minimum {
			c.mu.Unlock()
			return
		}
		index := c.resolvedNext
		c.resolvedNext++
		track := c.queue[index]
		c.mu.Unlock()

		item, err := c.resolve(track)
		if !c.stillCurrent(generation) {
			return
		}
		if err != nil {
			if index == 0 {
				c.fail(&mpv.Failure{Message: err.Error(), Title: track.Title})
			}
			continue
		}
		if err := c.engine.Append(mpv.Item{URI: item.URI, Headers: item.Headers}); err != nil {
			c.fail(&mpv.Failure{Message: err.Error(), Title: item.Title})
			return
		}
		c.mu.Lock()
		if generation != c.generation {
			c.mu.Unlock()
			return
		}
		c.resolved = append(c.resolved, resolvedItem{item: item, sourceIndex: index})
		c.mu.Unlock()
	}
}

func (c *Controller) onSnapshot(snapshot mpv.Snapshot) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if snapshot.Index >= 0 && snapshot.Index < len(c.resolved) {
		c.currentIndex = snapshot.Index
		c.currentTrack = &c.queue[c.resolved[snapshot.Index].sourceIndex]
	}
	if snapshot.Playing && snapshot.Index >= 0 && snapshot.Index < len(c.resolved) {
		c.failure = nil
	}
	c.update = Update{
		Snapshot: snapshot,
		Index:    c.currentIndex,
		Track:    c.currentTrack,
		Repeat:   c.repeat,
		Failure:  c.failure,
	}
	if snapshot.Failure != nil {
		c.update.Failure = snapshot.Failure
	}
	generation := c.generation
	track := c.currentTrack
	currentIndex := c.currentIndex
	itemCount := len(c.resolved)
	c.mu.Unlock()

	c.notify()
	c.recordPlay(snapshot, track)
	c.recordDuration(snapshot, track, currentIndex)
	c.handleCompletion(snapshot, currentIndex, itemCount, generation)
	c.ensureAhead(prefetchCount, generation)
}

// recordPlay counts a play once per track, only once it is actually playing.
func (c *Controller) recordPlay(snapshot mpv.Snapshot, track *library.Track) {
	if !snapshot.Playing || track == nil {
		return
	}
	c.mu.Lock()
	if c.lastRecordedID == track.ID {
		c.mu.Unlock()
		return
	}
	c.lastRecordedID = track.ID
	c.mu.Unlock()
	if c.history == nil {
		return
	}
	go func(id string) {
		count, err := c.history.RecordPlay(context.Background(), id)
		if err != nil {
			return
		}
		c.mu.Lock()
		if c.update.Track != nil && c.update.Track.ID == id {
			c.update.PlayCount = count
		}
		c.mu.Unlock()
		c.notify()
	}(track.ID)
}

// recordDuration fills a duration the library did not know, once per track.
func (c *Controller) recordDuration(snapshot mpv.Snapshot, track *library.Track, index int) {
	if track == nil || snapshot.Duration <= 0 || c.history == nil {
		return
	}
	c.mu.Lock()
	if c.durationRecordID == track.ID {
		c.mu.Unlock()
		return
	}
	c.durationRecordID = track.ID
	c.mu.Unlock()
	go func(id string, duration time.Duration) {
		_, _ = c.history.BackfillDuration(context.Background(), id, duration)
	}(track.ID, snapshot.Duration)
}

func (c *Controller) handleCompletion(snapshot mpv.Snapshot, index, itemCount int, generation uint64) {
	if snapshot.Processing != mpv.Completed {
		c.mu.Lock()
		c.completionDone = false
		c.mu.Unlock()
		return
	}
	c.mu.Lock()
	if c.completionDone {
		c.mu.Unlock()
		return
	}
	c.completionDone = true
	repeat := c.repeat
	atEnd := itemCount > 0 && index >= itemCount-1
	c.mu.Unlock()
	if generation != c.generation {
		return
	}

	switch repeat {
	case RepeatOne:
		// Normally mpv loops the file itself; this path is only reached if it
		// did not (for example after a manual seek to the end).
		_ = c.engine.Seek(0)
		_ = c.engine.Play()
	case RepeatAll:
		if atEnd {
			// Replay the queue the engine already holds: no re-resolution, no
			// gap, and the arrays cannot grow across loops.
			_ = c.engine.PlayIndex(0)
			_ = c.engine.Play()
			c.mu.Lock()
			c.currentIndex = 0
			c.mu.Unlock()
		}
	case RepeatOff:
		// Pause and rewind: play() on a completed engine is a no-op, and the
		// play button would look dead (playback_controller.dart learned this).
		_ = c.engine.Pause()
		_ = c.engine.Seek(0)
	}
}

// Play resumes, restarting a finished queue when needed.
func (c *Controller) Play() error {
	c.mu.Lock()
	snapshot := c.update.Snapshot
	repeat := c.repeat
	hasQueue := len(c.resolved) > 0
	c.mu.Unlock()
	if snapshot.Processing == mpv.Completed {
		if repeat == RepeatAll && hasQueue {
			_ = c.engine.PlayIndex(0)
			c.mu.Lock()
			c.currentIndex = 0
			c.mu.Unlock()
		} else {
			_ = c.engine.Seek(0)
		}
	}
	return c.engine.Play()
}

// Pause pauses.
func (c *Controller) Pause() error { return c.engine.Pause() }

// TogglePlayPause flips playback.
func (c *Controller) TogglePlayPause() error {
	c.mu.Lock()
	playing := c.update.Snapshot.Playing
	c.mu.Unlock()
	if playing {
		return c.Pause()
	}
	return c.Play()
}

// Next advances in the queue, wrapping only in repeat-all mode.
func (c *Controller) Next() error {
	c.mu.Lock()
	repeat := c.repeat
	index := c.currentIndex
	itemCount := len(c.resolved)
	allResolved := len(c.resolved) >= len(c.queue)
	c.mu.Unlock()
	if index+1 < itemCount {
		return c.engine.Next()
	}
	if repeat == RepeatAll && allResolved && itemCount > 0 {
		_ = c.engine.PlayIndex(0)
		return c.engine.Play()
	}
	return c.engine.Next()
}

// Previous goes back, or restarts the current track at the beginning.
func (c *Controller) Previous() error {
	c.mu.Lock()
	index := c.currentIndex
	c.mu.Unlock()
	if index <= 0 {
		return c.engine.Seek(0)
	}
	return c.engine.Prev()
}

// Seek jumps to an absolute position.
func (c *Controller) Seek(position time.Duration) error { return c.engine.Seek(position) }

// CycleRepeat moves all → one → off → all.
func (c *Controller) CycleRepeat() RepeatMode {
	c.mu.Lock()
	var mode RepeatMode
	switch c.repeat {
	case RepeatAll:
		mode = RepeatOne
	case RepeatOne:
		mode = RepeatOff
	default:
		mode = RepeatAll
	}
	c.mu.Unlock()
	c.SetRepeat(mode)
	return mode
}

// SetRepeat selects a loop mode. Repeat-one is pushed to the engine, which
// loops the file itself and is therefore gapless.
func (c *Controller) SetRepeat(mode RepeatMode) {
	c.mu.Lock()
	c.repeat = mode
	c.mu.Unlock()
	_ = c.engine.SetRepeatOne(mode == RepeatOne)
	c.notify()
}

// Queue returns the rotated queue (the original order is not kept; M1 has no
// shuffle).
func (c *Controller) Queue() []library.Track {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]library.Track(nil), c.queue...)
}

func (c *Controller) fail(failure *mpv.Failure) {
	c.mu.Lock()
	c.failure = failure
	c.update.Failure = failure
	listener := c.listener
	c.mu.Unlock()
	if listener != nil {
		listener(c.update)
	}
}

func (c *Controller) notify() {
	c.mu.Lock()
	listener := c.listener
	update := c.update
	c.mu.Unlock()
	if listener != nil {
		listener(update)
	}
}

// Close stops the engine and the controller.
func (c *Controller) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()
	close(c.done)
	if c.unsubscribe != nil {
		c.unsubscribe()
	}
	return c.engine.Close()
}
