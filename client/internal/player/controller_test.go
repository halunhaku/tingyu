package player

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
)

type fakeEngine struct {
	mu       sync.Mutex
	items    []mpv.Item
	index    int
	calls    []string
	snapshot mpv.Snapshot
	subs     map[int]chan mpv.Snapshot
	nextID   int
	closed   bool
	// silentIndex keeps PlayIndex from emitting a Ready snapshot, so a test
	// can observe the completed-transition guard without a real mpv.
	silentIndex bool
	// silentPlay likewise keeps Play from emitting, for the same reason.
	silentPlay bool
	// loopFile is mpv's loop-file: what RepeatOne means to the engine.
	loopFile bool
}

func newFakeEngine() *fakeEngine {
	return &fakeEngine{
		subs:     map[int]chan mpv.Snapshot{},
		snapshot: mpv.Snapshot{Processing: mpv.Idle, Paused: true, Volume: 1, Rate: 1},
	}
}

func (f *fakeEngine) record(call string) []string {
	f.calls = append(f.calls, call)
	return f.calls
}

func (f *fakeEngine) set(snapshot mpv.Snapshot) {
	f.snapshot = snapshot
	for _, ch := range f.subs {
		select {
		case ch <- snapshot:
		default:
		}
	}
}

func (f *fakeEngine) push(snapshot mpv.Snapshot) {
	f.mu.Lock()
	f.set(snapshot)
	f.mu.Unlock()
}

func (f *fakeEngine) SetQueue(items []mpv.Item, start int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("SetQueue")
	f.items = append([]mpv.Item(nil), items...)
	f.index = start
	f.snapshot = mpv.Snapshot{Processing: mpv.Ready, Paused: true, Index: start, Volume: 1, Rate: 1, Path: items[start].URI}
	f.set(f.snapshot)
	return nil
}

func (f *fakeEngine) Append(item mpv.Item) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Append")
	f.items = append(f.items, item)
	return nil
}

func (f *fakeEngine) Play() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Play")
	f.snapshot.Paused = false
	f.snapshot.Playing = true
	f.snapshot.Processing = mpv.Ready
	if !f.silentPlay {
		f.set(f.snapshot)
	}
	return nil
}

func (f *fakeEngine) Pause() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Pause")
	f.snapshot.Paused = true
	f.snapshot.Playing = false
	f.set(f.snapshot)
	return nil
}

func (f *fakeEngine) Seek(position time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record(fmt.Sprintf("Seek(%v)", position))
	f.snapshot.Position = position
	f.set(f.snapshot)
	return nil
}

func (f *fakeEngine) SetRate(rate float64) error {
	f.snapshot.Rate = rate
	return nil
}

func (f *fakeEngine) SetVolume(volume float64) error {
	f.snapshot.Volume = volume
	return nil
}

func (f *fakeEngine) SetRepeatOne(on bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.loopFile = on
	f.record(fmt.Sprintf("SetRepeatOne(%v)", on))
	return nil
}

func (f *fakeEngine) Next() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Next")
	if f.index+1 < len(f.items) {
		f.index++
	}
	f.snapshot.Index = f.index
	f.set(f.snapshot)
	return nil
}

func (f *fakeEngine) Prev() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Prev")
	if f.index > 0 {
		f.index--
	}
	f.snapshot.Index = f.index
	f.set(f.snapshot)
	return nil
}

func (f *fakeEngine) PlayIndex(index int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record(fmt.Sprintf("PlayIndex(%d)", index))
	f.index = index
	f.snapshot.Index = index
	if !f.silentIndex {
		f.snapshot.Processing = mpv.Ready
		f.set(f.snapshot)
	}
	return nil
}

func (f *fakeEngine) Snapshot() mpv.Snapshot {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.snapshot
}

func (f *fakeEngine) Subscribe() (<-chan mpv.Snapshot, func()) {
	ch := make(chan mpv.Snapshot, 64)
	f.mu.Lock()
	id := f.nextID
	f.nextID++
	f.subs[id] = ch
	f.mu.Unlock()
	return ch, func() {
		f.mu.Lock()
		delete(f.subs, id)
		f.mu.Unlock()
	}
}

func (f *fakeEngine) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record("Close")
	if !f.closed {
		f.closed = true
		for _, ch := range f.subs {
			close(ch)
		}
		f.subs = map[int]chan mpv.Snapshot{}
	}
	return nil
}

func (f *fakeEngine) callList() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeEngine) itemURIs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.items))
	for i, item := range f.items {
		out[i] = item.URI
	}
	return out
}

func (f *fakeEngine) hasCall(want string) bool {
	for _, call := range f.callList() {
		if call == want {
			return true
		}
	}
	return false
}

type fakeHistory struct {
	mu       sync.Mutex
	plays    []string
	counts   map[string]int64
	backfill []string
}

func newFakeHistory() *fakeHistory { return &fakeHistory{counts: map[string]int64{}} }

func (h *fakeHistory) RecordPlay(_ context.Context, id string) (int64, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.plays = append(h.plays, id)
	h.counts[id]++
	return h.counts[id], nil
}

func (h *fakeHistory) BackfillDuration(_ context.Context, id string, _ time.Duration) (bool, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.backfill = append(h.backfill, id)
	return true, nil
}

func (h *fakeHistory) playCount(id string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, played := range h.plays {
		if played == id {
			n++
		}
	}
	return n
}

func tracks(n int) []library.Track {
	out := make([]library.Track, n)
	for i := range n {
		out[i] = library.Track{
			ID:       fmt.Sprintf("t%d", i),
			Title:    fmt.Sprintf("Track %d", i),
			FilePath: fmt.Sprintf("/music/%d.flac", i),
			Duration: time.Minute,
		}
	}
	return out
}

func resolver(track library.Track) (Item, error) {
	return Item{ID: track.ID, URI: track.FilePath, Title: track.Title, TrackID: track.ID}, nil
}

func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func newController(t *testing.T, engine Engine, resolve Resolver, history History) *Controller {
	t.Helper()
	c := New(engine, resolve, history)
	t.Cleanup(func() { c.Close() })
	return c
}

func TestPlayTracksRotatesQueueAndPrefetchesTwo(t *testing.T) {
	engine := newFakeEngine()
	history := newFakeHistory()
	c := newController(t, engine, resolver, history)
	list := tracks(5)

	if err := c.PlayTracks(list, 1); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "two items prefetched", func() bool { return len(engine.itemURIs()) == 3 })
	got := engine.itemURIs()
	want := []string{"/music/1.flac", "/music/2.flac", "/music/3.flac"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("queue = %v, want %v", got, want)
		}
	}
	if !engine.hasCall("Play") {
		t.Fatal("Play was not called")
	}
	if len(c.Queue()) != 5 || c.Queue()[0].ID != "t1" {
		t.Fatalf("rotated queue = %+v", c.Queue())
	}
}

func TestRapidPlayTracksDropsTheAbandonedPrefetch(t *testing.T) {
	engine := newFakeEngine()
	gate := make(chan struct{})
	resolvedOld := make(chan struct{})
	slow := func(track library.Track) (Item, error) {
		if track.ID == "t1" {
			close(resolvedOld)
			<-gate
		}
		return resolver(track)
	}
	c := newController(t, engine, slow, newFakeHistory())
	list := tracks(5)
	if err := c.PlayTracks(list, 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "old prefetch blocked", func() bool {
		select {
		case <-resolvedOld:
			return true
		default:
			return false
		}
	})
	// Replace the queue while the first prefetch is still resolving.
	if err := c.PlayTracks(list, 3); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "new prefetch", func() bool { return len(engine.itemURIs()) == 3 })
	close(gate) // let the abandoned resolution finish
	time.Sleep(100 * time.Millisecond)

	got := engine.itemURIs()
	want := []string{"/music/3.flac", "/music/4.flac", "/music/0.flac"}
	if len(got) != len(want) {
		t.Fatalf("queue = %v, want %v (a stale append landed)", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("queue = %v, want %v", got, want)
		}
	}
}

func TestCompletionRepeatAllReplaysFromTheStart(t *testing.T) {
	engine := newFakeEngine()
	engine.silentIndex = true
	engine.silentPlay = true
	c := newController(t, engine, resolver, newFakeHistory())
	if err := c.PlayTracks(tracks(2), 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "both items", func() bool { return len(engine.itemURIs()) == 2 })

	playing := engine.Snapshot()
	playing.Playing = true
	playing.Index = 1
	playing.Position = time.Second
	engine.push(playing)
	completed := playing
	completed.Processing = mpv.Completed
	completed.Playing = false
	completed.Position = 60 * time.Second
	completed.Duration = 60 * time.Second
	engine.push(completed)

	waitFor(t, "replay", func() bool { return engine.hasCall("PlayIndex(0)") })
	// A second completed snapshot must not replay again until playback leaves
	// completed: mpv keeps eof set until sound starts again.
	before := len(engine.callList())
	engine.push(completed)
	time.Sleep(20 * time.Millisecond)
	if len(engine.callList()) != before {
		t.Fatalf("duplicate completed triggered actions: %v", engine.callList()[before:])
	}
}

func TestCompletionRepeatOffPausesAndRewinds(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, newFakeHistory())
	c.CycleRepeat() // all → one
	c.CycleRepeat() // one → off
	if err := c.PlayTracks(tracks(1), 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "first item", func() bool { return len(engine.itemURIs()) == 1 })
	snapshot := engine.Snapshot()
	snapshot.Playing = false
	snapshot.Processing = mpv.Completed
	snapshot.Index = 0
	engine.push(snapshot)
	waitFor(t, "pause", func() bool { return engine.hasCall("Pause") })
	if !engine.hasCall("Seek(0s)") {
		t.Fatalf("no rewind after completion: %v", engine.callList())
	}
}

func TestCycleRepeatSendsOneToTheEngine(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, newFakeHistory())
	if mode := c.CycleRepeat(); mode != RepeatOne {
		t.Fatalf("mode = %v, want one", mode)
	}
	if !engine.hasCall("SetRepeatOne(true)") {
		t.Fatalf("engine did not get loop-file: %v", engine.callList())
	}
	if mode := c.CycleRepeat(); mode != RepeatOff {
		t.Fatalf("mode = %v, want off", mode)
	}
	if !engine.hasCall("SetRepeatOne(false)") || engine.loopFile {
		t.Fatal("engine did not clear loop-file")
	}
	// The third state closes the cycle: off → all, with loop-file still off.
	if mode := c.CycleRepeat(); mode != RepeatAll {
		t.Fatalf("mode = %v, want all", mode)
	}
	engine.mu.Lock()
	loopFile := engine.loopFile
	engine.mu.Unlock()
	if loopFile {
		t.Fatal("列表循环 must not leave loop-file on")
	}
}

func TestRecordPlayOncePerTrackAndBackfillDuration(t *testing.T) {
	engine := newFakeEngine()
	history := newFakeHistory()
	c := newController(t, engine, resolver, history)
	if err := c.PlayTracks(tracks(2), 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "two items", func() bool { return len(engine.itemURIs()) == 2 })

	snapshot := engine.Snapshot()
	snapshot.Playing = true
	snapshot.Index = 0
	snapshot.Position = time.Second
	snapshot.Duration = 61 * time.Second
	engine.push(snapshot)
	engine.push(snapshot)
	waitFor(t, "one play", func() bool { return history.playCount("t0") == 1 })
	time.Sleep(30 * time.Millisecond)
	if got := history.playCount("t0"); got != 1 {
		t.Fatalf("plays for t0 = %d, want 1 (one per track, not per tick)", got)
	}

	snapshot.Index = 1
	snapshot.Duration = 62 * time.Second
	engine.push(snapshot)
	waitFor(t, "second play", func() bool { return history.playCount("t1") == 1 })

	history.mu.Lock()
	backfills := append([]string(nil), history.backfill...)
	history.mu.Unlock()
	if len(backfills) != 2 {
		t.Fatalf("duration backfills = %v, want one per track", backfills)
	}
}

func TestToggleAfterCompletionSeeksToZero(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, newFakeHistory())
	c.CycleRepeat()
	c.CycleRepeat() // off
	if err := c.PlayTracks(tracks(1), 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "first item", func() bool { return len(engine.itemURIs()) == 1 })
	snapshot := engine.Snapshot()
	snapshot.Processing = mpv.Completed
	snapshot.Playing = false
	engine.push(snapshot)
	waitFor(t, "completion handled", func() bool { return engine.hasCall("Seek(0s)") })
	before := len(engine.callList())
	if err := c.TogglePlayPause(); err != nil {
		t.Fatal(err)
	}
	if len(engine.callList()) <= before {
		t.Fatal("play after completion did nothing")
	}
	if !engine.hasCall("Play") {
		t.Fatalf("play not sent: %v", engine.callList())
	}
}

func TestFirstTrackResolveFailureIsReported(t *testing.T) {
	engine := newFakeEngine()
	broken := func(track library.Track) (Item, error) {
		return Item{}, errors.New("无法打开文件")
	}
	c := newController(t, engine, broken, newFakeHistory())
	got := make(chan Update, 4)
	c.SetListener(func(update Update) {
		select {
		case got <- update:
		default:
		}
	})
	_ = c.PlayTracks(tracks(1), 0)
	var failure *mpv.Failure
	for len(got) > 0 {
		update := <-got
		if update.Failure != nil {
			failure = update.Failure
		}
	}
	if failure == nil || failure.Message == "" {
		t.Fatal("resolve failure did not reach the listener")
	}
}

func TestNextAtEndWrapsOnlyWithRepeatAll(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, newFakeHistory())
	if err := c.PlayTracks(tracks(2), 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "two items", func() bool { return len(engine.itemURIs()) == 2 })
	engine.push(mpv.Snapshot{Processing: mpv.Ready, Playing: true, Index: 1, Volume: 1, Rate: 1})
	waitFor(t, "index one", func() bool { return c.Snapshot().Index == 1 })
	if err := c.Next(); err != nil {
		t.Fatal(err)
	}
	if !engine.hasCall("PlayIndex(0)") {
		t.Fatalf("repeat-all did not wrap: %v", engine.callList())
	}
}

func TestPreviousAtStartRewinds(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, newFakeHistory())
	if err := c.PlayTracks(tracks(2), 0); err != nil {
		t.Fatal(err)
	}
	if err := c.Previous(); err != nil {
		t.Fatal(err)
	}
	if !engine.hasCall("Seek(0s)") {
		t.Fatalf("previous at the first track did not rewind: %v", engine.callList())
	}
}
