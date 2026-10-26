package player

import (
	"math/rand/v2"
	"testing"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// shuffled builds a controller with a fixed seed, so "shuffled" is a real
// order a test can compare against rather than a coin flip.
func shuffled(t *testing.T, engine Engine, seed int64) *Controller {
	t.Helper()
	c := newController(t, engine, resolver, nil)
	c.mu.Lock()
	c.rnd = rand.New(rand.NewPCG(uint64(seed), uint64(seed)<<1))
	c.mu.Unlock()
	return c
}

func TestShufflePlaysTheChosenTrackFirstThenRandomOrder(t *testing.T) {
	engine := newFakeEngine()
	c := shuffled(t, engine, 7)
	list := tracks(6)
	if !c.SetShuffle(true) || !c.Shuffle() {
		t.Fatal("shuffle was not turned on")
	}
	if err := c.PlayTracks(list, 2); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the queue resolved", func() bool { return len(c.Queue()) == 6 })

	order := c.Queue()
	if order[0].ID != "t2" {
		t.Fatalf("queue starts with %q, want the chosen t2", order[0].ID)
	}
	// Every track appears exactly once: shuffling must not drop or duplicate.
	seen := map[string]int{}
	for _, track := range order {
		seen[track.ID]++
	}
	for _, track := range list {
		if seen[track.ID] != 1 {
			t.Fatalf("track %s appears %d times in %v", track.ID, seen[track.ID], idsOf(order))
		}
	}
	// The rest is not the sequential order (six tracks with a fixed seed: the
	// probability of coincidence is 1/120, and the seed makes it deterministic
	// rather than flaky).
	sequential := []string{"t2", "t3", "t4", "t5", "t0", "t1"}
	if idsOf(order)[0] == sequential[0] && idsOf(order)[1] == sequential[1] &&
		idsOf(order)[2] == sequential[2] && idsOf(order)[3] == sequential[3] {
		t.Fatalf("queue %v is still the sequential order", idsOf(order))
	}
}

func TestShuffleOffRestoresTheSequentialOrder(t *testing.T) {
	engine := newFakeEngine()
	c := shuffled(t, engine, 11)
	list := tracks(6)
	c.SetShuffle(true)
	if err := c.PlayTracks(list, 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the queue resolved", func() bool { return len(c.Queue()) == 6 })
	shuffledOrder := idsOf(c.Queue())

	// Nothing has been handed to the engine beyond the first entry (the
	// prefetch may have appended a couple); turning shuffle off restores the
	// tail in the list's own order and leaves the played prefix alone.
	c.mu.Lock()
	prefix := c.resolvedNext
	c.mu.Unlock()
	if c.SetShuffle(false) || c.Shuffle() {
		t.Fatal("shuffle was not turned off")
	}
	restored := idsOf(c.Queue())
	if restored[0] != "t0" {
		t.Fatalf("the prefix moved: %v -> %v", shuffledOrder, restored)
	}
	for i := 0; i < prefix && i < len(restored); i++ {
		if restored[i] != shuffledOrder[i] {
			t.Fatalf("the already-queued prefix changed: %v -> %v", shuffledOrder, restored)
		}
	}
	// The tail must be in the original list's order (not merely some order):
	// each remaining track's index in the list increases down the tail.
	position := map[string]int{}
	for i, track := range list {
		position[track.ID] = i
	}
	last := -1
	for _, id := range restored[prefix:] {
		if position[id] <= last {
			t.Fatalf("tail %v is not in the original order", restored[prefix:])
		}
		last = position[id]
	}
	// And nothing was lost in the round trip.
	if len(restored) != len(list) {
		t.Fatalf("queue = %v, want %d tracks", restored, len(list))
	}
}

func TestShuffleToggleKeepsDuplicateTracks(t *testing.T) {
	engine := newFakeEngine()
	c := shuffled(t, engine, 3)
	list := tracks(4)
	// A playlist may hold the same track twice; restore-by-id would collapse
	// the duplicates into the set of ids.
	list = append(list, list[1])
	c.SetShuffle(true)
	if err := c.PlayTracks(list, 0); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the queue resolved", func() bool { return len(c.Queue()) == 5 })
	c.SetShuffle(false)
	order := c.Queue()
	if len(order) != 5 {
		t.Fatalf("queue = %v, want the duplicate kept", idsOf(order))
	}
	count := 0
	for _, track := range order {
		if track.ID == "t1" {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("t1 appears %d times in %v, want 2", count, idsOf(order))
	}
}

func TestShuffleCoexistsWithRepeat(t *testing.T) {
	engine := newFakeEngine()
	c := shuffled(t, engine, 5)
	list := tracks(4)
	c.SetShuffle(true)
	for _, mode := range []RepeatMode{RepeatOne, RepeatOff, RepeatAll} {
		c.SetRepeat(mode)
		if got := c.Snapshot().Repeat; got != mode {
			t.Fatalf("repeat = %v, want %v", got, mode)
		}
		if !c.Snapshot().Shuffle {
			t.Fatalf("shuffle turned off with repeat %v", mode)
		}
	}
	if err := c.PlayTracks(list, 1); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the queue resolved", func() bool { return len(c.Queue()) == 4 })
	update := c.Snapshot()
	if !update.Shuffle || update.Repeat != RepeatAll {
		t.Fatalf("update = shuffle %v repeat %v", update.Shuffle, update.Repeat)
	}
	if update.Track == nil || update.Track.ID != "t1" {
		t.Fatalf("track = %+v, want the chosen t1", update.Track)
	}
}

func idsOf(list []library.Track) []string {
	out := make([]string, len(list))
	for i, track := range list {
		out[i] = track.ID
	}
	return out
}
