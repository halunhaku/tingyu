//go:build darwin

package mediasession

import (
	"runtime"
	"testing"

	"github.com/halunhaku/tingyu/client/internal/mainq"
)

func TestCommandNames(t *testing.T) {
	want := map[Command]string{
		CmdPlay:   "play",
		CmdPause:  "pause",
		CmdToggle: "togglePlayPause",
		CmdNext:   "nextTrack",
		CmdPrev:   "previousTrack",
		CmdSeek:   "changePlaybackPosition",
	}
	for cmd, name := range want {
		if got := cmd.String(); got != name {
			t.Errorf("%d.String() = %q, want %q", int(cmd), got, name)
		}
	}
	if got := Command(42).String(); got != "Command(42)" {
		t.Errorf("unknown command String() = %q", got)
	}
}

// TestCommandSpecs checks the invariant apply() and commandObject() rely on:
// the spec array is indexed by Command.
func TestCommandSpecs(t *testing.T) {
	if len(commandSpecs) != int(CmdSeek)+1 {
		t.Fatalf("commandSpecs has %d entries, want %d", len(commandSpecs), int(CmdSeek)+1)
	}
	for i := range commandSpecs {
		if int(commandSpecs[i].cmd) != i {
			t.Errorf("commandSpecs[%d].cmd = %d, want %d", i, int(commandSpecs[i].cmd), i)
		}
		if commandSpecs[i].selector == "" || commandSpecs[i].name == "" {
			t.Errorf("commandSpecs[%d] is missing a selector or name", i)
		}
	}
	if !commandSpecs[CmdSeek].seek {
		t.Error("CmdSeek must be the seek command")
	}
}

func TestExternalContentID(t *testing.T) {
	cases := []struct {
		meta Metadata
		want string
	}{
		{Metadata{}, ""},
		{Metadata{Title: "a"}, "tingyu:a"},
		{Metadata{Title: "a", Artist: "b"}, "tingyu:a|b"},
		{Metadata{Title: "a", Album: "c"}, "tingyu:a|c"},
		{Metadata{Title: "a", Artist: "b", Album: "c"}, "tingyu:a|b|c"},
	}
	for _, c := range cases {
		if got := externalContentID(c.meta); got != c.want {
			t.Errorf("externalContentID(%+v) = %q, want %q", c.meta, got, c.want)
		}
	}
}

func TestArtBounds(t *testing.T) {
	cases := []struct {
		in, want cgSize
	}{
		{cgSize{Width: 300, Height: 300}, cgSize{Width: 300, Height: 300}},
		{cgSize{Width: 1024, Height: 1024}, cgSize{Width: 512, Height: 512}},
		{cgSize{Width: 1024, Height: 512}, cgSize{Width: 512, Height: 256}},
		{cgSize{Width: 512, Height: 1024}, cgSize{Width: 256, Height: 512}},
		{cgSize{}, cgSize{Width: maxArtSide, Height: maxArtSide}},
		{cgSize{Width: -1, Height: 10}, cgSize{Width: maxArtSide, Height: maxArtSide}},
	}
	for _, c := range cases {
		if got := artBounds(c.in); got != c.want {
			t.Errorf("artBounds(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestPlaybackState(t *testing.T) {
	if got := playbackState(State{Playing: true}); got != playbackStatePlaying {
		t.Errorf("playing -> %d, want %d", got, playbackStatePlaying)
	}
	if got := playbackState(State{}); got != playbackStatePaused {
		t.Errorf("not playing -> %d, want %d", got, playbackStatePaused)
	}
}

// TestNowPlayingRoundTrip drives the real MediaPlayer objects. It only runs when
// the test happens to execute on the main thread, since there is no run loop to
// hop onto here; spike-session --verify is the unconditional version.
func TestNowPlayingRoundTrip(t *testing.T) {
	if !mainq.OnMainThread() {
		t.Skip("test goroutine is not on the main thread")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if err := Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	if err := Init(); err != nil {
		t.Fatalf("second Init: %v", err)
	}

	meta := Metadata{Title: "测试曲目", Artist: "Tingyu", Album: "P1 spike", DurationSec: 123.5}
	if err := SetMetadata(meta); err != nil {
		t.Fatalf("SetMetadata: %v", err)
	}
	state := State{Playing: true, Rate: 1, Position: 12.5, Duration: 123.5}
	if err := SetState(state); err != nil {
		t.Fatalf("SetState: %v", err)
	}

	info, err := NowPlayingInfo()
	if err != nil {
		t.Fatalf("NowPlayingInfo: %v", err)
	}
	for key, want := range map[string]any{
		"title":         meta.Title,
		"artist":        meta.Artist,
		"album":         meta.Album,
		"duration":      meta.DurationSec,
		"elapsed":       state.Position,
		"rate":          state.Rate,
		"playbackState": int64(playbackStatePlaying),
	} {
		if got := info[key]; got != want {
			t.Errorf("%s = %v, want %v", key, got, want)
		}
	}

	commands, err := CommandStatus()
	if err != nil {
		t.Fatalf("CommandStatus: %v", err)
	}
	if len(commands) == 0 {
		t.Error("CommandStatus is empty")
	}

	if err := SetKeepsAwake(true); err != nil {
		t.Fatalf("SetKeepsAwake(true): %v", err)
	}
	if err := SetKeepsAwake(false); err != nil {
		t.Fatalf("SetKeepsAwake(false): %v", err)
	}

	if err := Clear(); err != nil {
		t.Fatalf("Clear: %v", err)
	}
	info, err = NowPlayingInfo()
	if err != nil {
		t.Fatalf("NowPlayingInfo after Clear: %v", err)
	}
	if len(info) != 0 {
		t.Fatalf("nowPlayingInfo after Clear = %v, want empty", info)
	}
}
