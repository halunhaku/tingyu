package model

import (
	"testing"
	"time"
)

// TestScrubberSeeksOnceOnRelease is the invariant the transport and the stage
// promise: a drag changes only the display, and the release seeks once. The
// frame count is what used to become that many seeks (one per Range request on
// a remote source).
func TestScrubberSeeksOnceOnRelease(t *testing.T) {
	var scrubber Scrubber
	frames := []struct {
		value   float64
		pressed bool
		changed bool
	}{
		{10, true, false}, // pressed the knob, no movement yet
		{20, true, true},  // dragging
		{40, true, true},
		{60, true, true},
		{60, false, false}, // released
	}
	seeks := 0
	var target time.Duration
	for index, frame := range frames {
		position, ok := scrubber.Seek(frame.value, 200, frame.pressed, frame.changed)
		if ok {
			seeks++
			target = position
		}
		if index < len(frames)-1 && ok {
			t.Fatalf("frame %d seeked while the drag was in progress", index)
		}
	}
	if seeks != 1 {
		t.Fatalf("drag emitted %d seeks, want exactly 1", seeks)
	}
	if target != 60*time.Second {
		t.Fatalf("released seek target = %v, want 60s", target)
	}
}

// TestScrubberKeyboardStillSeeks keeps arrow-key scrubbing: the slider changes
// its value with no press, which must seek once per change.
func TestScrubberKeyboardStillSeeks(t *testing.T) {
	var scrubber Scrubber
	position, ok := scrubber.Seek(30, 200, false, true)
	if !ok || position != 30*time.Second {
		t.Fatalf("keyboard change = (%v, %v), want (30s, true)", position, ok)
	}
	if _, ok := scrubber.Seek(30, 200, false, false); ok {
		t.Fatal("an unchanged keyboard frame seeked")
	}
}

// TestScrubberClickWithoutMovementDoesNotSeek: pressing a knob and letting go
// without moving is not a scrub.
func TestScrubberClickWithoutMovementDoesNotSeek(t *testing.T) {
	var scrubber Scrubber
	if _, ok := scrubber.Seek(10, 200, true, false); ok {
		t.Fatal("press seeked")
	}
	if _, ok := scrubber.Seek(10, 200, false, false); ok {
		t.Fatal("release without movement seeked")
	}
}

// TestScrubberKeepsOneSecondBeforeTheEnd: seeking to the very end would read as
// the track finishing and skip to the next one.
func TestScrubberKeepsOneSecondBeforeTheEnd(t *testing.T) {
	var scrubber Scrubber
	scrubber.Seek(200, 200, true, true)
	position, ok := scrubber.Seek(200, 200, false, false)
	if !ok || position != 199*time.Second {
		t.Fatalf("seek to the end = (%v, %v), want (199s, true)", position, ok)
	}
	// A duration shorter than the one-second guard must not produce a
	// negative target.
	scrubber.Seek(0.5, 0.5, true, true)
	if position, ok := scrubber.Seek(0.5, 0.5, false, false); !ok || position != 500*time.Millisecond {
		t.Fatalf("short track seek = (%v, %v), want (500ms, true)", position, ok)
	}
}
