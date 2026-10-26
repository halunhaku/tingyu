//go:build darwin

package app

import (
	"testing"
	"time"

	"github.com/egoist/mygo"
)

// fakeMediaControl records what the media session asked the player to do.
type fakeMediaControl struct {
	calls []string
	seek  time.Duration
}

func (f *fakeMediaControl) Play() error     { f.calls = append(f.calls, "play"); return nil }
func (f *fakeMediaControl) Pause() error    { f.calls = append(f.calls, "pause"); return nil }
func (f *fakeMediaControl) Next() error     { f.calls = append(f.calls, "next"); return nil }
func (f *fakeMediaControl) Previous() error { f.calls = append(f.calls, "previous"); return nil }
func (f *fakeMediaControl) Seek(position time.Duration) error {
	f.calls = append(f.calls, "seek")
	f.seek = position
	return nil
}

// TestMediaCommandsReachTheController is the behavioural contract M1's S2
// item 3 checked against the ObjC bridge: every command the system sends
// must reach the matching controller call. The official API folds the
// play/pause key into play or pause by the state it was told, so those two
// are what arrive.
func TestMediaCommandsReachTheController(t *testing.T) {
	cases := []struct {
		command mygo.MediaCommand
		call    string
		name    string
	}{
		{mygo.MediaPlay, "play", "play"},
		{mygo.MediaPause, "pause", "pause"},
		{mygo.MediaStop, "pause", "stop"},
		{mygo.MediaNext, "next", "nextTrack"},
		{mygo.MediaPrevious, "previous", "previousTrack"},
		{mygo.MediaSeek, "seek", "changePlaybackPosition"},
	}
	for _, test := range cases {
		control := &fakeMediaControl{}
		var logged string
		handleMediaCommand(control, func(format string, args ...any) { logged = format }, test.command, 42*time.Second)
		if len(control.calls) != 1 || control.calls[0] != test.call {
			t.Errorf("%s: calls = %v, want one %q", test.name, control.calls, test.call)
		}
		if test.command == mygo.MediaSeek && control.seek != 42*time.Second {
			t.Errorf("seek went to %v, want 42s", control.seek)
		}
		if got := mediaCommandName(test.command); got != test.name {
			t.Errorf("name of %#x = %q, want %q", uint32(test.command), got, test.name)
		}
		if logged == "" {
			t.Errorf("%s: no log line", test.name)
		}
	}
	// A missing controller must be a no-op, not a panic: the app registers
	// commands before initSession, when a.control may still be nil.
	handleMediaCommand(nil, nil, mygo.MediaNext, 0)
}

// TestNowPlayingCommandsFollowQueueAndDuration pins the enabled command set:
// next/previous only when the queue has one, seek only when the duration is
// known.
func TestNowPlayingCommandsFollowQueueAndDuration(t *testing.T) {
	cases := []struct {
		name     string
		bounds   queueBounds
		duration time.Duration
		want     mygo.MediaCommand
	}{
		{"single track", queueBounds{}, 3 * time.Minute, mygo.MediaPlay | mygo.MediaPause | mygo.MediaSeek},
		{"unknown duration", queueBounds{}, 0, mygo.MediaPlay | mygo.MediaPause},
		{"queue both ways", queueBounds{hasNext: true, hasPrev: true}, time.Minute,
			mygo.MediaPlay | mygo.MediaPause | mygo.MediaSeek | mygo.MediaNext | mygo.MediaPrevious},
		{"last track", queueBounds{hasPrev: true}, time.Minute,
			mygo.MediaPlay | mygo.MediaPause | mygo.MediaSeek | mygo.MediaPrevious},
	}
	for _, test := range cases {
		if got := nowPlayingCommands(test.bounds, test.duration); got != test.want {
			t.Errorf("%s: commands = %#x, want %#x", test.name, uint32(got), uint32(test.want))
		}
	}
}
