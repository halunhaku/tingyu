package shell

// M6 accessibility: the keyboard alone reaches the main flow. The plan keeps
// full keyboard access plus a focus ring when the screen-reader experience is
// simplified (plan §2.4 row 47), so these tests are the contract:
//
//   * Tab reaches the sidebar's rows and Enter opens the page it names — the
//     rows are custom clickable elements, and a click handler alone does not
//     put an element in the Tab order (MyGo only visits Focusable elements);
//   * Tab reaches a track list, the arrows choose a row and Enter plays it;
//   * Tab reaches the transport's loop button and Enter cycles the three
//     states;
//   * Esc closes the command palette and the stage.

import (
	"testing"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// tabTo presses Tab until the window reports s focused, and says how many
// presses it took. limit bounds a broken layout: the window must not be a
// keyboard maze.
func tabTo(t *testing.T, tt *ui.Tester, s string, limit int) int {
	t.Helper()
	for i := 1; i <= limit; i++ {
		tt.Key(0, ui.KeyTab)
		tt.Frame()
		if tt.Focused(s) {
			return i
		}
	}
	t.Fatalf("%q is not a Tab stop within %d presses; texts %q", s, limit, tt.Texts())
	return 0
}

func TestTabReachesTheSidebarAndEnterOpensThePage(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	tabTo(t, tt, "收藏", 40)
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	if m.State().Page() != model.PageFavorites {
		t.Fatalf("Enter on the focused 收藏 row did not open favourites: page=%s", m.State().Page())
	}

	// Shift+Tab walks back out of the row rather than nowhere: the focus stays
	// on something the window can name.
	tt.Key(ui.Shift, ui.KeyTab)
	frame(tt)
	if !tt.Focused("收藏") && !tt.Focused("曲库") {
		t.Fatalf("Shift+Tab left the sidebar; texts %q", tt.Texts())
	}
}

func TestArrowKeysChooseATrackAndEnterPlaysIt(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	list := m.State().Library()
	if list.Selected() != -1 {
		t.Fatalf("a fresh list has row %d chosen", list.Selected())
	}
	// Down only moves the choice while the list has the focus, so this walks
	// the Tab order until the list is the focused element.
	reached := false
	for i := 0; i < 40 && !reached; i++ {
		tt.Key(0, ui.KeyTab)
		tt.KeyDown(ui.KeyDown)
		frame(tt)
		reached = list.Selected() >= 0
	}
	if !reached {
		t.Fatalf("the track list never took the keyboard focus; texts %q", tt.Texts())
	}
	tt.KeyDown(ui.KeyDown)
	frame(tt)
	if list.Selected() != 1 {
		t.Fatalf("Down chose row %d, want 1", list.Selected())
	}
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	if len(actions.played) != 2 || actions.start != 1 {
		t.Fatalf("Enter played %d tracks from %d, want the whole list from row 1", len(actions.played), actions.start)
	}
	if chosen := list.Items()[list.Selected()]; actions.played[1].ID != chosen.ID {
		t.Fatalf("Enter played %q, want the chosen row %q", actions.played[1].Title, chosen.Title)
	}
}

func TestEnterCyclesTheLoopButtonItself(t *testing.T) {
	m := newModel(t)
	actions := &loopActions{repeat: player.RepeatAll}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	tabTo(t, tt, "循环：列表循环", 60)
	for _, want := range []string{"循环：单曲循环", "循环：不循环", "循环：列表循环"} {
		tt.Key(0, ui.KeyEnter)
		frame(tt)
		if _, ok := tt.Find(want); !ok {
			t.Fatalf("Enter did not move the loop button to %q; texts %q", want, tt.Texts())
		}
	}
	if actions.calls != 3 {
		t.Fatalf("the loop button asked for %d changes, want 3", actions.calls)
	}
}

func TestEscapeClosesThePaletteAndTheStage(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	tt.Key(ui.Cmd, ui.KeyK)
	frame(tt)
	if !m.State().Palette().Open {
		t.Fatalf("the palette did not open")
	}
	tt.Key(0, ui.KeyEscape)
	frame(tt)
	if m.State().Palette().Open {
		t.Fatalf("Esc left the palette open")
	}

	tt.Key(ui.Cmd|ui.Shift, ui.KeyP)
	frame(tt)
	if m.State().Page() != model.PageStage {
		t.Fatalf("the stage did not open: page=%s", m.State().Page())
	}
	tt.Key(0, ui.KeyEscape)
	frame(tt)
	if m.State().Page() == model.PageStage {
		t.Fatalf("Esc left the stage open")
	}
}

// The queue and the album/artist details are lists with a bound choice, so
// Tab reaches them, the arrows choose a row and Enter plays it from there.
func TestQueuePageRowsTakeTheKeyboard(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tracks := m.State().Library().Items()
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true},
		Track:    &tracks[0],
		Repeat:   player.RepeatAll,
	})
	m.SetQueue(tracks, 0)
	m.State().OpenPage(model.PageQueue)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	selected := m.State().QueueList().Selected
	for i := 0; i < 40 && *selected < 0; i++ {
		tt.Key(0, ui.KeyTab)
		tt.KeyDown(ui.KeyDown)
		frame(tt)
	}
	if *selected < 0 {
		t.Fatalf("the queue's next list never took the keyboard focus; texts %q", tt.Texts())
	}
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	if len(actions.played) != 2 || actions.start != 1+*selected {
		t.Fatalf("Enter played %d tracks from %d, want both from %d", len(actions.played), actions.start, 1+*selected)
	}
}

func TestAlbumDetailRowsTakeTheKeyboard(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if err := tt.Click("专辑"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if err := tt.Click("太阳之子"); err != nil {
		t.Fatal(err)
	}
	frame(tt)

	selected := m.State().DetailList().Selected
	for i := 0; i < 40 && *selected < 0; i++ {
		tt.Key(0, ui.KeyTab)
		tt.KeyDown(ui.KeyDown)
		frame(tt)
	}
	if *selected < 0 {
		t.Fatalf("the album's track list never took the keyboard focus; texts %q", tt.Texts())
	}
	tt.KeyDown(ui.KeyDown)
	frame(tt)
	chosen := *selected
	if chosen < 1 {
		t.Fatalf("the second Down chose row %d, want 1", chosen)
	}
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	if len(actions.played) != 2 || actions.start != chosen {
		t.Fatalf("Enter played %d tracks from %d, want both from %d", len(actions.played), actions.start, chosen)
	}
}
