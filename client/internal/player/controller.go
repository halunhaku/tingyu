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
	"errors"
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

	// resolveGate serializes resolve+append for the current queue generation:
	// the prefetch goroutine and a user-visible Next() would otherwise append
	// entries out of queue order, which is exactly the misaligned index the
	// 200-track acceptance run looks for. A new queue gets a new gate, so an
	// abandoned prefetch (still resolving a replaced queue) cannot stall it.
	resolveGate chan struct{}

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
	// wg covers every goroutine that may call the engine. Close waits for it
	// before the engine is destroyed: a prefetch that resolved while the app
	// quit must never append to a destroyed mpv core (a SIGSEGV in mpv, not a
	// recoverable error).
	wg sync.WaitGroup
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
		resolveGate:  make(chan struct{}, 1),
		done:         make(chan struct{}),
	}
	c.resolveGate <- struct{}{}
	c.update = Update{Snapshot: engine.Snapshot(), Repeat: c.repeat}
	events, unsubscribe := engine.Subscribe()
	c.unsubscribe = unsubscribe
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		c.loop(events)
	}()
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

// SetRate sets the playback speed. Audio is pitch-preserved only up to what
// the engine does by default; the Flutter client exposed 0.5–3.0.
func (c *Controller) SetRate(rate float64) error {
	return c.engine.SetRate(rate)
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
	if c.closed {
		c.mu.Unlock()
		return errors.New("播放器正在关闭")
	}
	// Reserve the prefetch goroutine's slot under the same lock that Close
	// uses to set closed: otherwise it could be added after Close's Wait had
	// already returned, which is undefined for sync.WaitGroup.
	c.wg.Add(1)
	prefetched := false
	defer func() {
		if !prefetched {
			c.wg.Done()
		}
	}()
	c.generation++
	generation := c.generation
	c.queue = rotated
	c.resolved = nil
	c.resolvedNext = 0
	c.armed = false
	c.prefetching = false
	c.resolveGate = make(chan struct{}, 1)
	c.resolveGate <- struct{}{}
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
	prefetched = true
	go func() {
		defer c.wg.Done()
		c.ensureAhead(prefetchCount, generation)
	}()
	return nil
}

const prefetchCount = 2

// nextResolveWait is how long Next waits for a prefetch already in flight
// before it gives up and lets the engine decide. A variable so tests do not
// have to wait two seconds.
var nextResolveWait = 2 * time.Second

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
		enough := c.closed || !c.armed || generation != c.generation ||
			c.resolvedNext >= len(c.queue) || len(c.resolved)-c.currentIndex-1 >= minimum
		c.mu.Unlock()
		if enough {
			return
		}
		if !c.appendNextBlocking(generation) {
			return
		}
	}
}

// gate returns this generation's resolve gate, or nil once it is stale.
func (c *Controller) gate(generation uint64) chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation {
		return nil
	}
	return c.resolveGate
}

// appendNextBlocking resolves and appends the next unresolved queue entry,
// waiting for a resolve already in flight. The prefetch goroutine uses it.
func (c *Controller) appendNextBlocking(generation uint64) bool {
	gate := c.gate(generation)
	if gate == nil {
		return false
	}
	<-gate
	defer func() { gate <- struct{}{} }()
	return c.appendNext(generation)
}

// appendNextWithin is the user-visible variant: a click waits at most wait for
// a prefetch already in flight, then gives up instead of stalling the UI.
func (c *Controller) appendNextWithin(generation uint64, wait time.Duration) bool {
	gate := c.gate(generation)
	if gate == nil {
		return false
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-gate:
	case <-timer.C:
		return false
	}
	defer func() { gate <- struct{}{} }()
	return c.appendNext(generation)
}

// appendNext resolves and appends one entry. The gate must be held: the
// prefetch goroutine and Next() would otherwise append out of queue order,
// which is exactly the misaligned index the 200-track acceptance run hunts.
func (c *Controller) appendNext(generation uint64) bool {
	for {
		c.mu.Lock()
		if c.closed || !c.armed || generation != c.generation || c.resolvedNext >= len(c.queue) {
			c.mu.Unlock()
			return false
		}
		index := c.resolvedNext
		c.resolvedNext++
		track := c.queue[index]
		c.mu.Unlock()

		item, err := c.resolve(track)
		if !c.stillCurrent(generation) {
			return false
		}
		if err != nil {
			// An unplayable entry is skipped, not fatal: the rest of the queue
			// is still the user's queue.
			continue
		}
		if err := c.engine.Append(mpv.Item{URI: item.URI, Headers: item.Headers}); err != nil {
			c.fail(&mpv.Failure{Kind: mpv.FailureUnknown, Message: err.Error(), Detail: err.Error(), Title: item.Title})
			return false
		}
		c.mu.Lock()
		if generation != c.generation {
			c.mu.Unlock()
			return false
		}
		c.resolved = append(c.resolved, resolvedItem{item: item, sourceIndex: index})
		c.mu.Unlock()
		return true
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
	// The engine classifies its own failures (status, transport, decode) from
	// the lines FFmpeg logs; the controller only adds the title it knows and
	// keeps the failure until playback actually resumes.
	if snapshot.Failure != nil && (c.failure == nil || c.failure.Detail != snapshot.Failure.Detail) {
		failure := *snapshot.Failure
		if failure.Title == "" && c.currentTrack != nil {
			failure.Title = c.currentTrack.Title
		}
		c.failure = &failure
	}
	if c.failure != nil {
		c.update.Failure = c.failure
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
//
// A click can arrive before the prefetch has appended the next entry (a slow
// resolver, or 200 short tracks); calling the engine then would do nothing at
// all and look like a dead button. Resolve one entry first, waiting for a
// prefetch already in flight but never indefinitely.
func (c *Controller) Next() error {
	c.mu.Lock()
	generation := c.generation
	index := c.currentIndex
	itemCount := len(c.resolved)
	pending := c.resolvedNext < len(c.queue)
	c.mu.Unlock()
	if index+1 >= itemCount && pending {
		if c.appendNextWithin(generation, nextResolveWait) {
			c.mu.Lock()
			index = c.currentIndex
			itemCount = len(c.resolved)
			c.mu.Unlock()
		}
	}
	if index+1 < itemCount {
		return c.engine.Next()
	}
	c.mu.Lock()
	repeat := c.repeat
	// Wrap only when nothing is left to resolve. Wrapping while the prefetch
	// lagged would jump to the first track instead of advancing.
	wrapped := RepeatAll == repeat && itemCount > 0 && c.resolvedNext >= len(c.queue)
	c.mu.Unlock()
	if wrapped {
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
	c.wg.Wait()
	return c.engine.Close()
}
