package player

import (
	"sync"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
)

// TestNextResolvesBeforeAdvancing covers the dead-button case: a click on next
// before the prefetch appended anything must still move to the next track.
func TestNextResolvesBeforeAdvancing(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, nil)

	first := Item{ID: "t0", URI: "/music/0.flac", Title: "t0"}
	c.mu.Lock()
	c.generation++
	c.queue = tracks(3)
	c.resolved = []resolvedItem{{item: first, sourceIndex: 0}}
	c.resolvedNext = 1
	c.armed = true
	c.resolveGate = make(chan struct{}, 1)
	c.resolveGate <- struct{}{}
	c.mu.Unlock()
	engine.items = []mpv.Item{{URI: "/music/0.flac"}}
	engine.snapshot = mpv.Snapshot{Processing: mpv.Ready, Playing: true, Index: 0, Path: "/music/0.flac", Volume: 1, Rate: 1}

	if err := c.Next(); err != nil {
		t.Fatal(err)
	}
	uris := engine.itemURIs()
	if len(uris) != 2 || uris[1] != "/music/1.flac" {
		t.Fatalf("queue = %v, want the next track appended before advancing", uris)
	}
	if !engine.hasCall("Next") {
		t.Fatalf("engine did not advance: %v", engine.callList())
	}
	if engine.index != 1 {
		t.Fatalf("engine index = %d, want 1", engine.index)
	}
}

// TestNextDoesNotHangBehindAStuckPrefetch: the click may wait, but not forever,
// and it must not wrap to the first track while entries are still unresolved.
func TestNextDoesNotHangBehindAStuckPrefetch(t *testing.T) {
	engine := newFakeEngine()
	gate := make(chan struct{})
	blocked := make(chan struct{})
	slow := func(track library.Track) (Item, error) {
		if track.ID == "t1" {
			close(blocked)
			<-gate
		}
		return resolver(track)
	}
	c := newController(t, engine, slow, nil)
	previous := nextResolveWait
	nextResolveWait = 50 * time.Millisecond
	t.Cleanup(func() { nextResolveWait = previous })

	if err := c.PlayTracks(tracks(4), 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-blocked:
	case <-time.After(2 * time.Second):
		t.Fatal("prefetch never reached the blocked resolve")
	}
	done := make(chan error, 1)
	go func() { done <- c.Next() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Next returned %v", err)
		}
	case <-time.After(2 * time.Second):
		close(gate)
		t.Fatal("Next waited behind a stuck prefetch")
	}
	if engine.hasCall("PlayIndex(0)") {
		t.Fatalf("Next wrapped while the queue still had unresolved entries: %v", engine.callList())
	}
	close(gate)
	if !engine.hasCall("Next") {
		t.Fatalf("engine did not advance: %v", engine.callList())
	}
}

// TestConcurrentPrefetchKeepsQueueOrder is the regression guard for index
// drift: several appenders (prefetch plus clicks) may never reorder or
// duplicate the engine's playlist.
func TestConcurrentPrefetchKeepsQueueOrder(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, nil)

	list := tracks(20)
	c.mu.Lock()
	c.generation++
	generation := c.generation
	c.queue = list
	c.armed = true
	c.resolveGate = make(chan struct{}, 1)
	c.resolveGate <- struct{}{}
	c.mu.Unlock()

	var wg sync.WaitGroup
	for range 6 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for c.appendNextBlocking(generation) {
			}
		}()
	}
	wg.Wait()

	uris := engine.itemURIs()
	if len(uris) != len(list) {
		t.Fatalf("appended %d entries, want %d", len(uris), len(list))
	}
	for index, track := range list {
		if uris[index] != track.FilePath {
			t.Fatalf("entry %d = %s, want %s (out of order)", index, uris[index], track.FilePath)
		}
	}
}

// TestEngineFailureGetsTheTrackTitle: the engine does not know which library
// track failed, so the controller must attach it before the UI sees it.
func TestEngineFailureGetsTheTrackTitle(t *testing.T) {
	engine := newFakeEngine()
	c := newController(t, engine, resolver, nil)
	list := tracks(2)
	if err := c.PlayTracks(list, 0); err != nil {
		t.Fatal(err)
	}
	engine.push(mpv.Snapshot{Processing: mpv.Ready, Index: 0, Path: list[0].FilePath, Volume: 1, Rate: 1,
		Failure: &mpv.Failure{Kind: mpv.FailureNetwork, Message: "无法连接到服务器", Detail: "Connection refused"}})
	waitFor(t, "failure with title", func() bool {
		failure := c.Snapshot().Failure
		return failure != nil && failure.Title == list[0].Title
	})
	// Resuming playback is the only thing that withdraws it.
	engine.push(mpv.Snapshot{Processing: mpv.Ready, Playing: true, Index: 0, Path: list[0].FilePath, Volume: 1, Rate: 1})
	waitFor(t, "failure withdrawn", func() bool { return c.Snapshot().Failure == nil })
}

// TestCloseWaitsForThePrefetch: destroying the engine while a prefetch is
// still resolving used to let it append to a dead mpv core (a SIGSEGV seen in
// the gapless acceptance run). Close must drain it first.
func TestCloseWaitsForThePrefetch(t *testing.T) {
	engine := newFakeEngine()
	gate := make(chan struct{})
	blocked := make(chan struct{})
	slow := func(track library.Track) (Item, error) {
		if track.ID == "t1" {
			close(blocked)
			<-gate
		}
		return resolver(track)
	}
	c := New(engine, slow, nil)
	if err := c.PlayTracks(tracks(4), 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-blocked:
	case <-time.After(2 * time.Second):
		t.Fatal("prefetch never started")
	}
	closed := make(chan error, 1)
	go func() { closed <- c.Close() }()
	select {
	case <-closed:
		t.Fatal("Close returned while a prefetch was still resolving")
	case <-time.After(100 * time.Millisecond):
	}
	close(gate)
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close never returned after the prefetch finished")
	}
	calls := engine.callList()
	engineClosed := -1
	for index, call := range calls {
		if call == "Close" {
			engineClosed = index
		}
	}
	if engineClosed < 0 {
		t.Fatalf("engine was not closed: %v", calls)
	}
	for _, call := range calls[engineClosed+1:] {
		if call == "Append" || call == "SetQueue" || call == "Play" {
			t.Fatalf("%s happened after the engine was closed: %v", call, calls)
		}
	}
}
