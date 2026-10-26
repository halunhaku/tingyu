package shell

// M6 contract tests (plan §6 M6): the four behaviours the delivery checklist
// names, driven through the real window (ui.Tester) over a real SQLite library
// rather than through the model alone. Each test states the contract it guards
// in its comment; the kernel-level halves live in internal/player,
// internal/library and internal/mpv.

import (
	"context"
	"testing"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// loopActions cycles the loop mode the way player.Controller.CycleRepeat does
// (列表循环 → 单曲循环 → 不循环 → 列表循环).
type loopActions struct {
	fakeActions
	repeat player.RepeatMode
	calls  int
}

func (a *loopActions) CycleRepeat() player.RepeatMode {
	a.calls++
	switch a.repeat {
	case player.RepeatOne:
		a.repeat = player.RepeatOff
	case player.RepeatOff:
		a.repeat = player.RepeatAll
	default:
		a.repeat = player.RepeatOne
	}
	return a.repeat
}

// The queue contract: playing a row queues the whole list from that row and
// wraps to the beginning, and the queue page shows that order. The keyboard is
// the input, so this also proves Enter is the same act as a click.
func TestEnterOnARowQueuesTheWholeListFromIt(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	list := m.State().Library()
	for i := 0; i < 40 && list.Selected() < 0; i++ {
		tt.Key(0, ui.KeyTab)
		tt.KeyDown(ui.KeyDown)
		frame(tt)
	}
	if list.Selected() < 0 {
		t.Fatalf("the track list never took the keyboard focus; texts %q", tt.Texts())
	}
	tt.KeyDown(ui.KeyDown)
	frame(tt)
	tt.Key(0, ui.KeyEnter)
	frame(tt)

	if len(actions.played) != 2 || actions.start != 1 {
		t.Fatalf("Enter queued %d tracks from %d, want both from row 1", len(actions.played), actions.start)
	}
	items := m.State().Library().Items()
	want := []string{items[1].Title, items[0].Title}
	if got := []string{actions.queue[0].Title, actions.queue[1].Title}; got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("queue = %v, want the chosen track then the rest of the list (%v)", got, want)
	}
	// What the assembly does with PlayTracks' queue: hand it to the window.
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true},
		Track:    &actions.played[actions.start],
		Repeat:   player.RepeatAll,
	})
	m.SetQueue(actions.queue, 0)
	m.State().OpenPage(model.PageQueue)
	frame(tt)
	if !tt.HasText("当前播放") || !tt.HasText("接下来 1 首") {
		t.Fatalf("queue page does not show the current track and one next; texts %q", tt.Texts())
	}
	if !tt.HasText("湘女多情") || !tt.HasText("西西里") {
		t.Fatalf("queue page lost a track; texts %q", tt.Texts())
	}
}

// The loop contract: three states, cycled by the transport button, and the
// window's label names the state it is actually in.
func TestLoopButtonCyclesAllThreeStates(t *testing.T) {
	m := newModel(t)
	actions := &loopActions{repeat: player.RepeatAll}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	if m.State().Repeat() != player.RepeatAll {
		t.Fatalf("a fresh window starts in %v, want 列表循环", m.State().Repeat())
	}
	steps := []struct {
		label string
		mode  player.RepeatMode
	}{
		{"循环：单曲循环", player.RepeatOne},
		{"循环：不循环", player.RepeatOff},
		{"循环：列表循环", player.RepeatAll},
	}
	for _, step := range steps {
		if err := tt.Click("循环：" + model.RepeatLabel(m.State().Repeat())); err != nil {
			t.Fatalf("the loop button is not clickable: %v", err)
		}
		frame(tt)
		if m.State().Repeat() != step.mode {
			t.Fatalf("loop = %v, want %v", m.State().Repeat(), step.mode)
		}
		if _, ok := tt.Find(step.label); !ok {
			t.Fatalf("the transport does not show %q; texts %q", step.label, tt.Texts())
		}
	}
	if actions.calls != 3 {
		t.Fatalf("the loop button asked for %d changes, want 3", actions.calls)
	}
}

// The merge contract after a cancelled scan: a non-authoritative snapshot only
// reports what it saw. Tracks the cancelled scan never reached stay, and so do
// the user's own writes on them (favourite, playlist membership).
func TestACancelledScanMergeKeepsTracksAndUserWrites(t *testing.T) {
	lib, m := newLibrary(t, sampleTracks())
	ctx := context.Background()
	items := m.State().Library().Items()
	if len(items) != 2 {
		t.Fatalf("fixture has %d tracks", len(items))
	}
	first, second := items[0], items[1]
	if err := lib.SetFavorite(ctx, first.ID, true); err != nil {
		t.Fatalf("favourite: %v", err)
	}
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatalf("playlist: %v", err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{first.ID}); err != nil {
		t.Fatalf("playlist add: %v", err)
	}

	// The scan was cancelled after the first file: it reports one track and is
	// not authoritative, which is what scan.Result.Authoritative() gives the
	// assembly for a cancellation.
	partial := sampleTracks()[:1]
	merge, err := lib.MergeScan(ctx, "src-local", partial, false)
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	if merge.Removed != 0 {
		t.Fatalf("the cancelled merge removed %d tracks, want 0", merge.Removed)
	}
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		t.Fatalf("tracks: %v", err)
	}
	if len(tracks) != 2 {
		t.Fatalf("tracks after the cancelled merge = %d, want 2", len(tracks))
	}
	kept := false
	for _, track := range tracks {
		if track.ID == second.ID {
			kept = true
		}
		if track.ID == first.ID && !track.IsFavorite {
			t.Fatalf("the merge dropped the favourite flag")
		}
	}
	if !kept {
		t.Fatalf("the track the cancelled scan never reached is gone")
	}
	if got, ok, err := lib.Playlist(ctx, playlist.ID); err != nil || !ok || got.TrackCount != 1 {
		t.Fatalf("playlist after the merge = %+v ok=%v err=%v, want its one track", got, ok, err)
	}

	// And the window, refreshed from the revision the merge bumped, still
	// shows both rows.
	m.Invalidate()
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("西西里") || !tt.HasText("湘女多情") {
		t.Fatalf("the window lost a row to the cancelled scan; texts %q", tt.Texts())
	}
}

// The direct-link contract: each way a stream can fail gets its own actionable
// sentence, and none of them is the engine's raw text.
func TestDirectLinkFailuresReadAsDifferentSentences(t *testing.T) {
	m := newModel(t)
	track := m.State().Library().Items()[0]
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	cases := []struct {
		name   string
		kind   mpv.FailureKind
		status int
		detail string
	}{
		{"401", mpv.FailureUnauthorized, 401, "Failed to open"},
		{"403", mpv.FailureUnauthorized, 403, "Failed to open"},
		{"404", mpv.FailureNotFound, 404, "Failed to open"},
		{"network", mpv.FailureNetwork, 0, "Connection refused"},
		{"decode", mpv.FailureDecode, 0, "Failed to recognize file format"},
	}
	seen := map[string]string{}
	for _, tc := range cases {
		message := mpv.FailureMessage(tc.kind, tc.status, tc.detail)
		if previous, ok := seen[message]; ok {
			t.Fatalf("%s and %s share the sentence %q", previous, tc.name, message)
		}
		seen[message] = tc.name
		m.SetPlayer(player.Update{
			Snapshot: mpv.Snapshot{Processing: mpv.Ready},
			Track:    &track,
			Failure:  &mpv.Failure{Kind: tc.kind, Status: tc.status, Detail: tc.detail, Message: message},
		})
		frame(tt)
		if !tt.HasText(message) {
			t.Fatalf("%s: the window does not show %q; texts %q", tc.name, message, tt.Texts())
		}
	}
}
