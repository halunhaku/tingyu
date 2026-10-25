package mpv

import (
	"testing"
	"time"
)

// These tests exercise snapshotLocked directly: it reads only the fields mpv
// reports, so no core (and no audio device) is needed. They pin the two rules
// the UI depends on and that a real remote link made obvious.

func TestDurationZeroIsReadyNotLoading(t *testing.T) {
	player := &Player{
		items:  []Item{{URI: "/music/a.flac"}},
		path:   "/music/a.flac",
		index:  0,
		volume: 100,
		speed:  1,
	}
	snapshot := player.snapshotLocked()
	if snapshot.Duration != 0 {
		t.Fatalf("duration = %v, want 0", snapshot.Duration)
	}
	if snapshot.Processing != Ready {
		t.Fatalf("processing with an unknown duration = %v, want ready (a spinner for a playing song looks broken)", snapshot.Processing)
	}
	if !snapshot.Playing {
		t.Fatal("a loaded, unpaused item with an unknown duration must report playing")
	}

	player.pausedForCache = true
	if got := player.snapshotLocked().Processing; got != Buffering {
		t.Fatalf("processing while paused for cache = %v, want buffering", got)
	}

	empty := &Player{volume: 100, speed: 1}
	if got := empty.snapshotLocked().Processing; got != Idle {
		t.Fatalf("processing of an empty queue = %v, want idle", got)
	}
}

func TestCompletionOnlyComesFromEndFileAtTheLastEntry(t *testing.T) {
	player := &Player{
		items:  []Item{{URI: "/a"}, {URI: "/b"}},
		path:   "/a",
		index:  0,
		volume: 100,
		speed:  1,
	}
	// A gapless boundary must not look like the end of the queue.
	if got := player.snapshotLocked().Processing; got == Completed {
		t.Fatal("mid-album reported completed")
	}
	player.completed = true
	if got := player.snapshotLocked().Processing; got != Completed {
		t.Fatalf("processing after the last end-file = %v, want completed", got)
	}
}

func TestBufferedIsClampedToTheDuration(t *testing.T) {
	player := &Player{
		items:     []Item{{URI: "/a"}},
		path:      "/a",
		index:     0,
		volume:    100,
		speed:     1,
		position:  30,
		duration:  60,
		cacheTime: 100, // demuxer-cache-time can run past the end
	}
	if got := player.snapshotLocked().Buffered; got != time.Minute {
		t.Fatalf("buffered = %v, want the duration", got)
	}
	// After a seek the cached range can be behind the play position.
	player.cacheTime = -10
	if got := player.snapshotLocked().Buffered; got != 30*time.Second {
		t.Fatalf("buffered = %v, want the position", got)
	}
}
