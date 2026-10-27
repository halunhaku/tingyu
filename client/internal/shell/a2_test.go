package shell

// The direction A second batch (stage, sources, settings, and the first batch's
// three loose ends) has its own acceptance, next to the milestone contracts:
// what the design promises that a regression would take away silently — the
// stage's lyrics window and up-next rows, the source card with its real sync
// state and statistics, the settings page's horizontal tabs with every control
// still reachable, the single footer sentence, the sidebar without a
// development line, and the 资料库 group label.

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// TestSidebarDropsTheDevelopmentLine is the first batch's leftover #1: the rail
// shows destinations and their counts, never a build string. The version lives
// in settings → 关于.
func TestSidebarDropsTheDevelopmentLine(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	texts := strings.Join(tt.Texts(), "|")
	for _, banned := range []string{"内核数据", "0.5.0-dev", "声档", "静室"} {
		if strings.Contains(texts, banned) {
			t.Errorf("the sidebar still shows %q: %v", banned, tt.Texts())
		}
	}
	// Leftover #3: the third group's 11/600 label is back (§10-1's three
	// groups), with the counts on the rows that open them.
	for _, want := range []string{"资料库", "来源", "歌单"} {
		if !tt.HasText(want) {
			t.Errorf("the sidebar lacks the %q group label; texts %q", want, tt.Texts())
		}
	}
}

// TestFooterShowsOneCountRule is the first batch's leftover #2: while rows are
// still coming the footer shows the progress and the button; once they are all
// here it is the one sentence, never both at once.
func TestFooterShowsOneCountRule(t *testing.T) {
	rows := make([]library.ScannedTrack, 0, 100)
	for i := range 100 {
		rows = append(rows, library.ScannedTrack{
			FilePathOrURL: fmt.Sprintf("/music/footer-%03d.flac", i),
			Title:         fmt.Sprintf("曲目 %03d", i),
			Artist:        "艺术家",
			Album:         "专辑",
			Duration:      time.Duration(120+i) * time.Second,
			FileFormat:    "flac",
		})
	}
	_, m := newLibrary(t, rows)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("已显示 40 / 共 100 首") {
		t.Fatalf("the first page's progress line is missing; texts %q", tt.Texts())
	}
	if tt.HasText("已全部加载") {
		t.Fatalf("the footer claims a finished load while 40 of 100 are loaded; texts %q", tt.Texts())
	}
	list := m.State().Library()
	for !list.Done() && list.Loaded() < 100 {
		if err := tt.Click("加载更多"); err != nil {
			t.Fatalf("加载更多: %v", err)
		}
		frame(tt)
	}
	texts := strings.Join(tt.Texts(), "|")
	if !strings.Contains(texts, "已全部加载 · 共 100 首") {
		t.Fatalf("the finished footer is missing; texts %q", tt.Texts())
	}
	if strings.Contains(texts, "已显示 40 / 共 100 首") || strings.Contains(texts, "已显示 100 / 共 100 首") {
		t.Fatalf("the footer still shows both counts; texts %q", tt.Texts())
	}
}

// TestLibraryScrollsShelfAndRowsInOneSurface keeps the page header fixed while
// the recent shelf, column header and rows move together in one virtual list.
// This is the interaction the fixed table-only scroller used to miss.
func TestLibraryScrollsShelfAndRowsInOneSurface(t *testing.T) {
	tracks := perfTracks(80)
	for i := range tracks {
		tracks[i].CoverArtPath = fmt.Sprintf("/covers/%03d.jpg", i)
	}
	_, m := newLibrary(t, tracks)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	if _, ok := tt.Find("最近添加"); !ok {
		t.Fatalf("the recent shelf is missing before scrolling; texts %q", tt.Texts())
	}
	moving := []string{"曲名", "长列表曲目 00000"}
	before := map[string]ui.Rect{}
	for _, label := range moving {
		rect, ok := tt.Find(label)
		if !ok {
			t.Fatalf("%q is missing before scrolling; texts %q", label, tt.Texts())
		}
		before[label] = rect
	}
	toolbar, ok := tt.Find("添加目录…")
	if !ok {
		t.Fatalf("the page toolbar is missing; texts %q", tt.Texts())
	}

	tt.Scroll(700, 400, 0, 80)
	frame(tt)
	for _, label := range moving {
		after, ok := tt.Find(label)
		if !ok {
			t.Fatalf("%q is missing after scrolling; texts %q", label, tt.Texts())
		}
		if after.Y >= before[label].Y-40 {
			t.Errorf("%q moved from %v to %v; it did not scroll with the page", label, before[label].Y, after.Y)
		}
	}
	if shelf, ok := tt.Find("最近添加"); ok && shelf.W > 0 {
		t.Errorf("the recent shelf is still painted after scrolling: %v", shelf)
	}
	if after, _ := tt.Find("添加目录…"); after.Y != toolbar.Y {
		t.Errorf("the page toolbar moved from %v to %v; it should stay fixed", toolbar.Y, after.Y)
	}
}

// TestStageShowsTheLyricsWindowAndUpNext is §10-9/§10-10: the current line in
// the accent-barred 18/600 style with no pill, the LRC label, and the three
// "接下来" rows — the queue itself is the ⌘U page.
func TestStageShowsTheLyricsWindowAndUpNext(t *testing.T) {
	m := newModel(t)
	tracks := make([]library.Track, 0, 2)
	for _, title := range []string{"西西里", "湘女多情"} {
		tracks = append(tracks, trackByTitle(t, m, title))
	}
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &tracks[0], Repeat: player.RepeatAll,
	})
	m.SetQueue(tracks, 0)
	m.State().OpenStage()
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	for _, want := range []string{
		"正在播放", "歌词", "LRC · 行级", "接下来",
		"第一句", "第二句", "第三句", "湘女多情", "共 2 首",
	} {
		if !tt.HasText(want) {
			t.Errorf("the stage lacks %q; texts %q", want, tt.Texts())
		}
	}
	// The queue keeps its page, so the stage no longer switches panels.
	for _, gone := range []string{"歌词显示", "播放队列"} {
		if tt.HasText(gone) {
			t.Errorf("the stage still shows the %q panel control; texts %q", gone, tt.Texts())
		}
	}
}

// TestSourcesPageCardInfoAndStatistics is §10-11: one card with the last sync
// and its result, the three-sentence information column, and the real five
// statistics — and none of the three documentation cards.
func TestSourcesPageCardInfoAndStatistics(t *testing.T) {
	_, m := newLibrary(t, sampleTracks())
	m.State().SetSources([]library.Source{{
		ID: "src-quark", Name: "夸克网盘", Kind: model.SourceKindQuark, TrackCount: 2,
		SyncStatus:   "部分同步（目录层级超过 5 层；保留未扫描曲目；新增 23 / 更新 0）",
		LastSyncedAt: time.Date(2026, 10, 26, 12, 13, 0, 0, time.Local),
	}})
	m.State().OpenPage(model.PageSources)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	for _, want := range []string{
		"来源", "1 个来源 · 2 首", "夸克网盘", "部分同步",
		"上次同步", "2026-10-26 12:13", "同步结果",
		"目录层级超过 5 层；保留未扫描曲目；新增 23 / 更新 0",
		"立即同步", "查看曲目", "来源操作",
		"远程来源", "凭据只保存在系统钥匙串，不写入曲库。",
		"可添加的类型", "本地目录 · WebDAV · 夸克网盘",
		"曲目", "专辑", "艺术家", "2026-10-26",
	} {
		if !tt.HasText(want) {
			t.Errorf("the sources page lacks %q; texts %q", want, tt.Texts())
		}
	}
	for _, gone := range []string{"PROPFIND", "尚未包含", "远端来源说明"} {
		if tt.HasText(gone) {
			t.Errorf("the sources page still shows the documentation card text %q", gone)
		}
	}
	// The main action really opens the three-kind menu.
	if err := tt.Click("添加来源"); err != nil {
		t.Fatalf("添加来源: %v", err)
	}
	if err := tt.ChooseMenuItem("WebDAV…"); err != nil {
		t.Fatalf("WebDAV…: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if !tt.HasText("添加 WebDAV 来源") {
		t.Fatalf("the add-source menu did not open the WebDAV form; texts %q", tt.Texts())
	}
}

// TestSettingsTabsReachEverySectionAndResetAppearance is §10-12: seven
// horizontal tabs instead of the second column, every section still there, the
// about card in the user's words, and "恢复默认外观" putting the three
// appearance preferences back.
func TestSettingsTabsReachEverySectionAndResetAppearance(t *testing.T) {
	m := newModel(t)
	m.State().SetSettings(model.Settings{ThemeMode: "dark", Density: "compact", CoverTint: false})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if err := tt.Click("设置"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	for _, want := range []string{
		"外观", "播放", "音乐库", "元数据", "来源", "数据", "关于",
		"主题模式", "界面密度", "封面动态取色", "恢复默认外观",
	} {
		if !tt.HasText(want) {
			t.Errorf("settings lacks %q; texts %q", want, tt.Texts())
		}
	}
	for _, gone := range []string{"听屿应用图标", "听屿 " + model.Version, "播放内核", "libmpv", "媒体会话", "系统 Now Playing"} {
		if tt.HasText(gone) {
			t.Errorf("the about card leaked into appearance (%q); texts %q", gone, tt.Texts())
		}
	}
	for _, gone := range []string{"Flutter", "settings.json", "M5", "M1/M2", "libmpv（进程内", "user_version"} {
		if tt.HasText(gone) {
			t.Errorf("settings still speaks development language (%q); texts %q", gone, tt.Texts())
		}
	}
	appearanceContent, ok := tt.Find("设置内容")
	if !ok {
		t.Fatalf("the settings content area is missing; texts %q", tt.Texts())
	}
	// The tabs are the page's only navigation: every one of the seven opens.
	sections := []struct {
		tab  string
		want string
	}{
		{"音乐库", "同步全部来源"},
		{"元数据", "补全全部"},
		{"数据", "数据目录"},
		{"关于", "私人音乐库播放器"},
	}
	for _, section := range sections {
		if err := tt.Click(section.tab); err != nil {
			t.Fatalf("tab %q: %v", section.tab, err)
		}
		frame(tt)
		if !tt.HasText(section.want) {
			t.Fatalf("the %q tab does not show %q; texts %q", section.tab, section.want, tt.Texts())
		}
	}
	for _, gone := range []string{"听屿应用图标", "听屿 " + model.Version, "数据"} {
		if !tt.HasText(gone) {
			t.Fatalf("the about tab lacks %q; texts %q", gone, tt.Texts())
		}
	}
	aboutContent, ok := tt.Find("设置内容")
	if !ok {
		t.Fatalf("the About content area is missing; texts %q", tt.Texts())
	}
	if aboutContent.X != appearanceContent.X || aboutContent.W != appearanceContent.W {
		t.Fatalf("About content is %+v, want the same width and inset as appearance %+v",
			aboutContent, appearanceContent)
	}
	if err := tt.Click("外观"); err != nil {
		t.Fatalf("外观: %v", err)
	}
	frame(tt)
	if err := tt.Click("恢复默认外观"); err != nil {
		t.Fatalf("恢复默认外观: %v", err)
	}
	frame(tt)
	if got := m.State().Settings(); got != model.DefaultSettings() {
		t.Fatalf("恢复默认外观 left %+v, want %+v", got, model.DefaultSettings())
	}
}

// TestStageFrameBudget measures the stage's new atmosphere where it costs the
// most: a full-window wash drawn every frame. The gate is the same 16.7 ms the
// library's scroll uses, and the numbers are logged so the record can compare
// the two themes and the tint switch.
func TestStageFrameBudget(t *testing.T) {
	if raceEnabled {
		t.Skip("frame-time gate measured without -race: race instrumentation dominates each frame")
	}
	dir := t.TempDir()
	cover := image.NewRGBA(image.Rect(0, 0, 320, 320))
	for y := range 320 {
		for x := range 320 {
			cover.Set(x, y, color.RGBA{R: uint8(120 + x/4), G: uint8(90 + y/5), B: uint8(200 - x/6), A: 255})
		}
	}
	file, err := os.Create(filepath.Join(dir, "cover.png"))
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(file, cover); err != nil {
		file.Close()
		t.Fatal(err)
	}
	file.Close()

	m := newModel(t)
	m.State().SetCoversDir(dir)
	track := trackByTitle(t, m, "西西里")
	track.CoverArtPath = "cover.png"
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	m.SetQueue([]library.Track{track}, 0)
	m.State().OpenStage()
	measure := func(theme string) (cold, steady time.Duration) {
		settings := m.State().Settings()
		settings.ThemeMode = theme
		m.State().SetSettings(settings)
		// The cold frame is the one that paints the atmosphere for the first
		// time in a window; the steady ones are what a static stage costs once
		// the frame is retained.
		colds := make([]time.Duration, 0, 12)
		for range 12 {
			st := time.Now()
			shot := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
			colds = append(colds, time.Since(st))
			if shot.Image() == nil {
				t.Fatal("the stage drew no image")
			}
		}
		tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
		for range 8 {
			tt.Frame()
		}
		samples := make([]time.Duration, 0, 60)
		for range 60 {
			st := time.Now()
			tt.Frame()
			samples = append(samples, time.Since(st))
		}
		sort.Slice(colds, func(i, j int) bool { return colds[i] < colds[j] })
		sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
		cold = colds[int(float64(len(colds)-1)*0.95)]
		steady = samples[int(float64(len(samples)-1)*0.95)]
		t.Logf("stage_frame theme=%s painted=%v cold_p95=%v steady_p95=%v", theme, tt.Image() != nil, cold, steady)
		return cold, steady
	}
	lightCold, lightSteady := measure("light")
	darkCold, darkSteady := measure("dark")
	settings := m.State().Settings()
	settings.CoverTint = false
	m.State().SetSettings(settings)
	plainCold, plainSteady := measure("light")
	for name, value := range map[string]time.Duration{
		"light cold": lightCold, "light steady": lightSteady,
		"dark cold": darkCold, "dark steady": darkSteady,
		"untinted cold": plainCold, "untinted steady": plainSteady,
	} {
		if value > 16700*time.Microsecond {
			t.Errorf("the stage's %s frame %v exceeds 16.7 ms", name, value)
		}
	}
}

// painted reports whether a frame built anything, so a silently skipped draw
// cannot make the budget look good.
func painted(tt *ui.Tester) bool { return tt.Image() != nil }
