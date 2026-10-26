package shell

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

type fakeActions struct {
	played   []library.Track
	start    int
	toggles  int
	next     int
	previous int
	seek     time.Duration
	seeks    []time.Duration
	volume   float64
	repeat   player.RepeatMode
	chosen   int
	revealed int
	synced   int
	queue    []library.Track
}

func (f *fakeActions) PlayTracks(tracks []library.Track, start int) error {
	f.played = tracks
	f.start = start
	f.queue = append(append([]library.Track{}, tracks[start:]...), tracks[:start]...)
	return nil
}
func (f *fakeActions) TogglePlayPause() error { f.toggles++; return nil }
func (f *fakeActions) Next() error            { f.next++; return nil }
func (f *fakeActions) Previous() error        { f.previous++; return nil }
func (f *fakeActions) Seek(position time.Duration) error {
	f.seek = position
	f.seeks = append(f.seeks, position)
	return nil
}
func (f *fakeActions) SetVolume(volume float64) error   { f.volume = volume; return nil }
func (f *fakeActions) CycleRepeat() player.RepeatMode   { f.repeat = player.RepeatOne; return f.repeat }
func (f *fakeActions) ChooseDirectory()                 { f.chosen++ }
func (f *fakeActions) SyncSource(source library.Source) { f.synced++ }
func (f *fakeActions) SyncAllSources()                  { f.synced++ }
func (f *fakeActions) RevealInFinder(track library.Track) {
	f.revealed++
}
func (f *fakeActions) Queue() []library.Track { return f.queue }

func sampleTracks() []library.Track {
	return []library.Track{
		{ID: "a", Title: "西西里", Artist: "周杰伦", Album: "太阳之子", Duration: 229 * time.Second, PlayCount: 3, IsFavorite: true, Lyrics: "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句"},
		{ID: "b", Title: "湘女多情", Artist: "周杰伦", Album: "太阳之子", Duration: 238 * time.Second},
	}
}

func newModel(tracks []library.Track) *Model {
	m := New(tracks, "/tmp/tingyu-m0/library.sqlite", nil)
	m.State().FinishOnboarding()
	return m
}

func TestViewShowsSidebarAndLibrary(t *testing.T) {
	m := newModel(sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{
		"听屿", "曲库", "收藏", "专辑", "艺术家", "歌单", "搜索", "设置",
		"2 首", "曲名", "艺术家", "专辑", "时长",
		"西西里", "周杰伦", "太阳之子", "3:49", "湘女多情", "3:58",
		"添加目录…", "未在播放", "已全部加载 · 共 2 首",
	} {
		if !tt.HasText(want) {
			t.Errorf("view does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestViewExplainsALibraryItCannotRead(t *testing.T) {
	m := New(nil, "/tmp/tingyu-m0/library.sqlite", errors.New("user_version 3, want 2"))
	m.State().FinishOnboarding()
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"无法打开曲库", "user_version 3, want 2", "/tmp/tingyu-m0/library.sqlite"} {
		if !tt.HasText(want) {
			t.Errorf("view does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestScanProgressIsVisible(t *testing.T) {
	m := newModel(nil)
	m.SetScan(ScanState{Running: true, Done: 12, Total: 50, Path: "/音乐/正在解析.flac"})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"正在扫描 12/50", "/音乐/正在解析.flac"} {
		if !tt.HasText(want) {
			t.Errorf("scan progress does not show %q; texts are %q", want, tt.Texts())
		}
	}
	m.SetScan(ScanState{Status: "扫描完成：文件 50，入库 50（新增 50 / 更新 0 / 移除 0）"})
	tt.Frame()
	if !tt.HasText("扫描完成：文件 50，入库 50（新增 50 / 更新 0 / 移除 0）") {
		t.Errorf("scan result missing; texts are %q", tt.Texts())
	}
}

func TestRowClickPlaysFromThatRow(t *testing.T) {
	m := newModel(sampleTracks())
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("湘女多情"); err != nil {
		t.Fatal(err)
	}
	if len(actions.played) != 2 || actions.start != 0 || actions.played[0].Title != "湘女多情" {
		t.Fatalf("row click: %d tracks at %d, texts %q", len(actions.played), actions.start, tt.Texts())
	}
	actions.played, actions.start = nil, 0
	if err := tt.Click("西西里"); err != nil {
		t.Fatal(err)
	}
	if len(actions.played) != 2 || actions.start != 1 || actions.played[actions.start].Title != "西西里" {
		t.Fatalf("second row click: %d tracks at %d, texts %q", len(actions.played), actions.start, tt.Texts())
	}
}

func TestTransportButtonsCallActions(t *testing.T) {
	m := newModel(sampleTracks())
	actions := &fakeActions{}
	m.SetActions(actions)
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 10 * time.Second, Volume: 0.5},
		Track:    &track,
		Repeat:   player.RepeatAll,
	})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	for _, label := range []string{"上一首", "暂停", "下一首"} {
		if err := tt.Click(label); err != nil {
			t.Fatalf("click %q: %v (texts %q)", label, err, tt.Texts())
		}
	}
	if actions.previous != 1 || actions.toggles != 1 || actions.next != 1 {
		t.Fatalf("actions = %+v", actions)
	}
	if err := tt.Click("循环：列表循环"); err != nil {
		t.Fatalf("click repeat: %v", err)
	}
	if actions.repeat != player.RepeatOne || m.State().Repeat() != player.RepeatOne {
		t.Fatalf("repeat = %v / %v", actions.repeat, m.State().Repeat())
	}
}

func TestAddDirectoryButton(t *testing.T) {
	m := newModel(nil)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	if err := tt.Click("添加目录…"); err != nil {
		t.Fatal(err)
	}
	if actions.chosen != 1 {
		t.Fatalf("directory picker opened %d times", actions.chosen)
	}
}

func TestPlayerFailureIsShownInTransportAndStage(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Processing: mpv.Ready},
		Track:    &track,
		Failure:  &mpv.Failure{Message: "无法播放：LOADING_FAILED"},
	})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	if !tt.HasText("无法播放：LOADING_FAILED") {
		t.Errorf("failure missing from library; texts are %q", tt.Texts())
	}
	m.State().OpenStage()
	tt.Frame()
	if !tt.HasText("播放失败：无法播放：LOADING_FAILED") {
		t.Errorf("failure missing from stage; texts are %q", tt.Texts())
	}
}

func TestStageExpandsAndCollapses(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("打开播放舞台"); err != nil {
		t.Fatalf("open stage: %v (texts %q)", err, tt.Texts())
	}
	tt.Frame()
	if m.State().Page() != model.PageStage {
		t.Fatalf("page = %s, want stage", m.State().Page())
	}
	for _, want := range []string{"关闭舞台", "西西里", "第一句", "第二句"} {
		if !tt.HasText(want) {
			t.Errorf("stage does not show %q; texts are %q", want, tt.Texts())
		}
	}
	if err := tt.Click("关闭舞台"); err != nil {
		t.Fatalf("close stage: %v", err)
	}
	tt.Frame()
	if m.State().Page() == model.PageStage {
		t.Fatalf("stage did not close")
	}
}

func TestLyricsHighlightAndSeek(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	actions := &fakeActions{}
	m.SetActions(actions)
	m.State().OpenPage(model.PageLyrics)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if !tt.HasText("随播放高亮 · 点击一行跳到该处") {
		t.Errorf("lyrics page header missing; texts are %q", tt.Texts())
	}
	if err := tt.Click("第三句"); err != nil {
		t.Fatalf("click lyric: %v", err)
	}
	if actions.seek != 9*time.Second {
		t.Fatalf("seek = %v, want 9s", actions.seek)
	}
}

// TestProgressSliderSeeksOnceOnRelease is the transport contract behind the
// remote-source fix (research report §3.2): dragging the progress bar only
// moves the display, and letting go seeks once. Before the fix the view called
// Seek on every Changed() frame, which a remote source answers with a fresh
// HTTP Range request each time.
func TestProgressSliderSeeksOnceOnRelease(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 10 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()

	rect, ok := tt.Find("播放进度")
	if !ok {
		t.Fatalf("progress slider not found; texts are %q", tt.Texts())
	}
	y := rect.Y + rect.H/2
	startX := rect.X + rect.W*0.1
	endX := rect.X + rect.W*0.7
	tt.Press(startX, y)
	for step := 1; step <= 10; step++ {
		x := startX + (endX-startX)*float32(step)/10
		tt.Move(x, y)
		tt.Frame()
		if len(actions.seeks) != 0 {
			t.Fatalf("the drag seeked %d times before release (step %d)", len(actions.seeks), step)
		}
	}
	tt.Release(endX, y)
	tt.Frame()
	if len(actions.seeks) != 1 {
		t.Fatalf("release produced %d seeks, want 1 (targets %v)", len(actions.seeks), actions.seeks)
	}
	if got := actions.seeks[0]; got < 120*time.Second || got > 200*time.Second {
		t.Fatalf("seek target = %v, want about 70%% of 3:49 (120–200s)", got)
	}
}

func TestSearchDebounceAndResults(t *testing.T) {
	m := newModel(sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyF)
	tt.Frame()
	if err := tt.Click("曲库搜索"); err != nil {
		t.Fatalf("click search field: %v", err)
	}
	tt.Frame()
	tt.Type("西西里")
	tt.Frame()
	if !tt.HasText("正在搜索…") {
		t.Fatalf("debounce state missing; texts are %q", tt.Texts())
	}
	tt.Advance(model.SearchDebounceTime + 10*time.Millisecond)
	tt.Frame()
	if !tt.HasText("西西里") || !tt.HasText("1 项") {
		t.Fatalf("results missing; texts are %q", tt.Texts())
	}
}

func TestSettingsThemePersistsOnlyWhenWritable(t *testing.T) {
	m := newModel(sampleTracks())
	m.State().SetSettings(model.Settings{ThemeMode: "dark", Density: "compact", CoverTint: false})
	if m.State().Settings().ThemeMode != "dark" {
		t.Fatalf("settings = %+v", m.State().Settings())
	}
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("设置"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	for _, want := range []string{"外观", "主题模式", "深色", "界面密度", "紧凑"} {
		if !tt.HasText(want) {
			t.Errorf("settings does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestOnboardingShowsWhenLibraryAndSourcesAreEmpty(t *testing.T) {
	m := New(nil, "/tmp/library.sqlite", nil)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"听屿", "本地文件夹", "WebDAV", "夸克网盘", "添加音乐来源", "跳过"} {
		if !tt.HasText(want) {
			t.Errorf("onboarding does not show %q; texts are %q", want, tt.Texts())
		}
	}
	if err := tt.Click("跳过"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().ShouldOnboard() {
		t.Fatal("onboarding did not dismiss")
	}
}

func TestKernelNoticeInsteadOfFakeFavorite(t *testing.T) {
	m := newModel(sampleTracks())
	m.State().AskKernel("收藏写入（tracks.is_favorite）")
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	if !tt.HasText("需内核支持：收藏写入（tracks.is_favorite）。本里程碑只做界面，未改内核；该操作尚未接入数据层。") {
		t.Errorf("kernel notice missing; texts are %q", tt.Texts())
	}
	if strings.Contains(strings.Join(tt.Texts(), "|"), "收藏成功") {
		t.Fatal("a write was faked")
	}
}

func TestFormatDuration(t *testing.T) {
	for _, test := range []struct {
		in   time.Duration
		want string
	}{
		{229 * time.Second, "3:49"},
		{59 * time.Second, "0:59"},
		{3600 * time.Second, "1:00:00"},
		{3723 * time.Second, "1:02:03"},
		{-5 * time.Second, "0:00"},
	} {
		if got := formatDuration(test.in); got != test.want {
			t.Errorf("formatDuration(%v) = %q, want %q", test.in, got, test.want)
		}
	}
}

func TestPaletteOpensFiltersAndPlays(t *testing.T) {
	m := newModel(sampleTracks())
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyK)
	tt.Frame()
	if !tt.HasText("快捷入口") || !tt.HasText("命令面板") {
		t.Fatalf("palette did not open; texts %q", tt.Texts())
	}
	if err := tt.Click("命令面板"); err != nil {
		t.Fatalf("click palette field: %v", err)
	}
	tt.KeyDown(ui.KeyDown)
	tt.Frame()
	if m.State().Palette().Selected != 1 {
		t.Fatalf("arrow keys did not move the palette selection: %d", m.State().Palette().Selected)
	}
	tt.KeyDown(ui.KeyUp)
	tt.Frame()
	if m.State().Palette().Selected != 0 {
		t.Fatalf("arrow up did not return: %d", m.State().Palette().Selected)
	}
	tt.Type("西西里")
	tt.Frame()
	tt.Advance(model.SearchDebounceTime + 10*time.Millisecond)
	tt.Frame()
	if !tt.HasText("西西里") {
		t.Fatalf("palette results missing; texts %q", tt.Texts())
	}
	m.State().Palette().Selected = 0
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if len(actions.played) == 0 || actions.played[actions.start].Title != "西西里" {
		t.Fatalf("palette did not play; played=%v start=%d texts=%q", actions.played, actions.start, tt.Texts())
	}
}

func TestAlbumAndArtistNavigation(t *testing.T) {
	m := newModel(sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("专辑"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText("太阳之子") {
		t.Fatalf("albums page missing the album; texts %q", tt.Texts())
	}
	if err := tt.Click("太阳之子"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().Page() != model.PageAlbumDetail || !tt.HasText("在艺人中查看") {
		t.Fatalf("album detail not shown; page=%s texts=%q", m.State().Page(), tt.Texts())
	}
	m.State().Back()
	tt.Frame()
	if err := tt.Click("艺术家"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if err := tt.Click("周杰伦"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().Page() != model.PageArtistDetail || !tt.HasText("全部曲目") {
		t.Fatalf("artist detail not shown; page=%s texts=%q", m.State().Page(), tt.Texts())
	}
}

func TestQueuePageListsCurrentAndNext(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 5 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	m.State().SetQueue(m.Tracks(), 0)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("播放队列"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	for _, want := range []string{"当前播放", "接下来 1 首", "湘女多情"} {
		if !tt.HasText(want) {
			t.Errorf("queue does not show %q; texts %q", want, tt.Texts())
		}
	}
}

func TestFavoriteClickReportsKernelNotFakeSuccess(t *testing.T) {
	m := newModel(sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("收藏此曲"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if !tt.HasText("需内核支持：收藏写入（tracks.is_favorite）") {
		t.Fatalf("favorite did not report the missing kernel write; texts %q", tt.Texts())
	}
	if m.Tracks()[1].IsFavorite {
		t.Fatal("favorite state changed without a kernel write")
	}
}

func TestPaginationFooterLoadsOnePagePerClick(t *testing.T) {
	tracks := perfTracks(100)
	m := newModel(tracks)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if !tt.HasText("已显示 40 / 共 100 首") {
		t.Fatalf("first page footer missing; texts %q", tt.Texts())
	}
	if err := tt.Click("加载更多"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().Library().Loaded() != 80 || !tt.HasText("已显示 80 / 共 100 首") {
		t.Fatalf("one click loaded %d, texts %q", m.State().Library().Loaded(), tt.Texts())
	}
	if err := tt.Click("加载更多"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().Library().Loaded() != 100 || !tt.HasText("已全部加载 · 共 100 首") {
		t.Fatalf("end footer missing; loaded=%d texts=%q", m.State().Library().Loaded(), tt.Texts())
	}
}

func TestSettingsPersistWhenWritable(t *testing.T) {
	dir := t.TempDir()
	m := newModel(sampleTracks())
	m.State().ConfigureDataDir(dir, true)
	m.State().SetSettings(model.Settings{ThemeMode: "dark", Density: "compact", CoverTint: false})
	settings, corrupt, err := model.LoadSettings(dir)
	if err != nil || corrupt {
		t.Fatalf("load: %v corrupt=%v", err, corrupt)
	}
	if settings.ThemeMode != "dark" || settings.Density != "compact" || settings.CoverTint {
		t.Fatalf("persisted settings = %+v", settings)
	}
}

func TestPagesFitTheMinimumWindow(t *testing.T) {
	m := newModel(sampleTracks())
	track := m.Tracks()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &track, Repeat: player.RepeatAll,
	})
	m.State().SetQueue(m.Tracks(), 0)
	tt := ui.NewTester(m.View, MinimumWidth, MinimumHeight)
	shots := []struct {
		page string
		want string
	}{
		{model.PageLibrary, "播放全部"},
		{model.PageFavorites, "已显示 1 / 共 1 首"},
		{model.PageAlbums, "太阳之子"},
		{model.PageArtists, "周杰伦"},
		{model.PagePlaylists, "歌单尚未接入数据层"},
		{model.PageSearch, "最近搜索"},
		{model.PageSettings, "主题模式"},
		{model.PageSources, "还没有音乐来源"},
		{model.PageQueue, "当前播放"},
		{model.PageLyrics, "随播放高亮"},
	}
	for _, shot := range shots {
		m.State().OpenPage(shot.page)
		tt.SetSize(MinimumWidth, MinimumHeight)
		tt.Frame()
		if !tt.HasText(shot.want) {
			t.Errorf("%s at %dx%d does not show %q; texts %q", shot.page, MinimumWidth, MinimumHeight, shot.want, tt.Texts())
		}
	}
	m.State().OpenStage()
	tt.Frame()
	if !tt.HasText("关闭舞台") {
		t.Errorf("stage at %dx%d missing; texts %q", MinimumWidth, MinimumHeight, tt.Texts())
	}
}

func TestPaletteFocusesItsFieldOnOpen(t *testing.T) {
	m := newModel(sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	tt.Key(ui.Cmd, ui.KeyK)
	tt.Frame()
	tt.Type("西西里")
	tt.Frame()
	tt.Advance(model.SearchDebounceTime + 10*time.Millisecond)
	tt.Frame()
	if m.State().Palette().Query != "西西里" {
		t.Fatalf("palette field was not focused (query %q, texts %q)", m.State().Palette().Query, tt.Texts())
	}
}

func TestSourcesPageShowsRemoteFormsAndRelogin(t *testing.T) {
	m := newModel(nil)
	m.State().SetSources([]library.Source{{
		ID: "src-quark", Name: "我的夸克", Kind: "quark", TrackCount: 4, SyncStatus: "未同步",
	}})
	m.State().OpenPage(model.PageSources)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"来源管理", "我的夸克", "同步", "夸克网盘（直链播放"} {
		if !tt.HasText(want) {
			t.Errorf("sources page does not show %q; texts are %q", want, tt.Texts())
		}
	}

	// A credential failure becomes a re-login entry with the reason.
	m.State().SetSourceError("src-quark", "夸克网盘登录凭据已失效，请重新登录")
	tt = ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"重新登录", "夸克网盘登录凭据已失效，请重新登录"} {
		if !tt.HasText(want) {
			t.Errorf("re-login entry missing %q; texts are %q", want, tt.Texts())
		}
	}

	// Progress of a remote sync is visible and cancellable.
	m.State().SetScan(model.ScanState{Running: true, Done: 5, SourceID: "src-quark", SourceName: "我的夸克", Path: "我的夸克 · 晴天"})
	tt = ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"正在同步「我的夸克」", "取消同步"} {
		if !tt.HasText(want) {
			t.Errorf("sync progress missing %q; texts are %q", want, tt.Texts())
		}
	}
	m.State().SetScan(model.ScanState{})

	// The quark form offers the QR flow and the Cookie escape hatch.
	m.State().OpenSourceForm(model.SourceKindQuark, "")
	tt = ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"登录夸克网盘", "扫码登录", "用 Cookie 登录", "Cookie"} {
		if !tt.HasText(want) {
			t.Errorf("quark form missing %q; texts are %q", want, tt.Texts())
		}
	}

	// The WebDAV form asks for the four fields and writes nothing yet.
	m.State().OpenSourceForm(model.SourceKindWebDAV, "")
	tt = ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"添加 WebDAV 来源", "地址", "账号", "密码 / 应用专用密码", "添加并同步", "取消"} {
		if !tt.HasText(want) {
			t.Errorf("webdav form missing %q; texts are %q", want, tt.Texts())
		}
	}
}
