package shell

// The direction A first batch (tokens, shell, library, shared states) has its
// own acceptance, next to the milestone contracts: what the design promises that
// a regression would take away silently — the shortcuts, the routes, the footer
// without the database sentence, the column rhythm and its minimum-window
// degradation, and the type scale the pages draw with.

import (
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// TestShortcutsStillOpenEveryPage walks the eight shortcut groups of §11: each
// one still lands on its page or act after the shell was rebuilt.
func TestShortcutsStillOpenEveryPage(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	pages := []struct {
		mods ui.Modifiers
		key  ui.Key
		want string
		name string
	}{
		{ui.Cmd, ui.Key1, model.PageLibrary, "⌘1 曲库"},
		{ui.Cmd, ui.Key2, model.PageSearch, "⌘2 搜索"},
		{ui.Cmd, ui.Key3, model.PageFavorites, "⌘3 收藏"},
		{ui.Cmd, ui.Key4, model.PageSources, "⌘4 来源"},
		{ui.Cmd, ui.KeyComma, model.PageSettings, "⌘, 设置"},
		{ui.Cmd, ui.KeyL, model.PageLyrics, "⌘L 歌词"},
		{ui.Cmd, ui.KeyU, model.PageQueue, "⌘U 队列"},
	}
	for _, step := range pages {
		m.State().OpenPage(model.PageAlbums)
		frame(tt)
		tt.Key(step.mods, step.key)
		frame(tt)
		if got := m.State().Page(); got != step.want {
			t.Errorf("%s opened %q, want %q", step.name, got, step.want)
		}
	}

	// ⌘⇧P still opens the stage, ⌘K the command palette, and Esc closes both.
	tt.Key(ui.Cmd|ui.Shift, ui.KeyP)
	frame(tt)
	if !m.State().Stage().Open {
		t.Errorf("⌘⇧P did not open the stage")
	}
	tt.Key(0, ui.KeyEscape)
	frame(tt)
	if m.State().Stage().Open {
		t.Errorf("Esc did not close the stage")
	}
	tt.Key(ui.Cmd, ui.KeyK)
	frame(tt)
	if !m.State().Palette().Open {
		t.Errorf("⌘K did not open the command palette")
	}
	tt.Key(0, ui.KeyEscape)
	frame(tt)
	if m.State().Palette().Open {
		t.Errorf("Esc did not close the command palette")
	}

	// ⌘F still lands on the search page with its field focused.
	m.State().OpenPage(model.PageLibrary)
	frame(tt)
	tt.Key(ui.Cmd, ui.KeyF)
	frame(tt)
	if m.State().Page() != model.PageSearch || !m.State().Search().Focus {
		t.Errorf("⌘F: page=%q focus=%v", m.State().Page(), m.State().Search().Focus)
	}
}

// TestPlaybackShortcutsStillReachTheKernel covers the transport keys: Space,
// the two track keys, the seek pair and the volume pair.
func TestPlaybackShortcutsStillReachTheKernel(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tracks := m.State().Library().Items()
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: tracks[0].Duration, Position: 30 * time.Second},
		Track:    &tracks[0],
		Repeat:   player.RepeatAll,
	})
	m.State().SetVolume(0.5)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	tt.Key(0, ui.KeySpace)
	tt.Key(ui.Cmd, ui.KeyRight)
	tt.Key(ui.Cmd, ui.KeyLeft)
	tt.Key(ui.Cmd|ui.Shift, ui.KeyRight)
	tt.Key(ui.Cmd, ui.KeyUp)
	tt.Key(ui.Cmd, ui.KeyDown)
	frame(tt)
	if actions.toggles != 1 || actions.next != 1 || actions.previous != 1 {
		t.Fatalf("toggles=%d next=%d previous=%d", actions.toggles, actions.next, actions.previous)
	}
	if len(actions.seeks) == 0 || actions.seeks[0] != 40*time.Second {
		t.Fatalf("⌘⇧→ seeked to %v, want 40s", actions.seeks)
	}
	// The volume keys leave 0.5 + 5% - 5% = 0.5, and each one reached the app.
	if actions.volume != 0.5 || m.State().Volume() != 0.5 {
		t.Fatalf("volume keys left %v (state %v), want 0.5", actions.volume, m.State().Volume())
	}
}

// TestLibraryFooterHidesTheDatabase is §10-7: the page ends with the honest
// count and the sort order, never with the database path or the SQL sentence.
func TestLibraryFooterHidesTheDatabase(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	texts := strings.Join(tt.Texts(), "|")
	for _, banned := range []string{"library.sqlite", "LIMIT/OFFSET", "分页与聚合来自 SQL"} {
		if strings.Contains(texts, banned) {
			t.Errorf("the library page still shows %q: %v", banned, tt.Texts())
		}
	}
	for _, want := range []string{"已全部加载 · 共 2 首", "按曲名排序"} {
		if !strings.Contains(texts, want) {
			t.Errorf("the footer lacks %q; texts %q", want, tt.Texts())
		}
	}
}

// TestTheTableStillFitsTheMinimumWindow is §10-4 under §11's 900×600 floor: the
// table keeps its name and its duration instead of clipping a row. The column
// arithmetic itself is locked in internal/ui/components (table_test.go).
func TestTheTableStillFitsTheMinimumWindow(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	for _, label := range []string{"曲名", "艺术家", "专辑", "时长"} {
		if !tt.HasText(label) {
			t.Errorf("the design width lacks the %q column; texts %q", label, tt.Texts())
		}
	}
	tt.SetSize(MinimumWidth, MinimumHeight)
	frame(tt)
	if !tt.HasText("曲名") || !tt.HasText("时长") {
		t.Errorf("the minimum window lost 曲名 or 时长; texts %q", tt.Texts())
	}
}

// TestTokensAreTheDesignScale locks §4.2's ladder and §10-6's tabular figures:
// a later page that reaches for a size gets the design's, not a local guess.
func TestTokensAreTheDesignScale(t *testing.T) {
	steps := []struct {
		role    tokens.Role
		size    float32
		weight  int
		track   float32
		numeric bool
	}{
		{tokens.Display, 40, 700, -0.8, false},
		{tokens.H1, 28, 700, -0.4, false},
		{tokens.H2, 20, 600, -0.2, false},
		{tokens.H3, 15, 600, 0, false},
		{tokens.Body, 14, 400, 0, false},
		{tokens.Small, 13, 400, 0, false},
		{tokens.Caption, 13, 500, 0.05, false},
		{tokens.Label, 12, 500, 0.2, false},
		{tokens.Overline, 11, 600, 0.8, false},
		{tokens.Num, 12, 500, 0, true},
		{tokens.NumSm, 11, 500, 0.2, true},
	}
	for _, step := range steps {
		size, weight, _, track, numeric := tokens.RoleSpec(step.role)
		if size != step.size || weight != step.weight || track != step.track || numeric != step.numeric {
			t.Errorf("role %d = %v/%v/%v tabular=%v, want %v/%v/%v tabular=%v",
				step.role, size, weight, track, numeric, step.size, step.weight, step.track, step.numeric)
		}
	}
	if tokens.SidebarWidth != 236 || tokens.TransportHeight != 88 ||
		tokens.TableRowHeight != 44 || tokens.TableHeaderHeight != 26 ||
		tokens.TableCover != 30 || tokens.PagePadding != 32 {
		t.Fatalf("the A metrics moved: sidebar=%v transport=%v row=%v header=%v cover=%v padding=%v",
			tokens.SidebarWidth, tokens.TransportHeight, tokens.TableRowHeight,
			tokens.TableHeaderHeight, tokens.TableCover, tokens.PagePadding)
	}
	if tokens.Light.Canvas != ui.Hex("#F4F4F1") || tokens.Dark.Canvas != ui.Hex("#0E0E10") ||
		tokens.Light.Accent != ui.Hex("#B01B2E") || tokens.Dark.Accent != ui.Hex("#F26D7E") {
		t.Fatalf("the A palette moved: light %v/%v dark %v/%v",
			tokens.Light.Canvas, tokens.Light.Accent, tokens.Dark.Canvas, tokens.Dark.Accent)
	}
	if tokens.Light.GlassAlpha != 0.72 || tokens.Dark.GlassAlpha != 0.56 {
		t.Fatalf("the glass tint moved: light %v dark %v", tokens.Light.GlassAlpha, tokens.Dark.GlassAlpha)
	}
}
