package shell

// The window's tests run against a real library: a temporary SQLite file with
// the production schema, filled through the same write path the app uses
// (OpenWritable + MergeScan + the playlist and favourite writes). Nothing here
// fakes the data layer, so a page that renders rows proves the SQL it asked
// for actually answers.

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

type fakeActions struct {
	played    []library.Track
	start     int
	toggles   int
	next      int
	previous  int
	seek      time.Duration
	seeks     []time.Duration
	volume    float64
	repeat    player.RepeatMode
	shuffle   bool
	chosen    int
	revealed  int
	synced    int
	favorites []string
	playlists []string
	added     []string
	removed   []int
	moved     [][2]int
	deleted   []string
	queue     []library.Track
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
func (f *fakeActions) SetVolume(volume float64) error     { f.volume = volume; return nil }
func (f *fakeActions) CycleRepeat() player.RepeatMode     { f.repeat = player.RepeatOne; return f.repeat }
func (f *fakeActions) SetShuffle(on bool) bool            { f.shuffle = on; return on }
func (f *fakeActions) ChooseDirectory()                   { f.chosen++ }
func (f *fakeActions) SyncSource(source library.Source)   { f.synced++ }
func (f *fakeActions) SyncAllSources()                    { f.synced++ }
func (f *fakeActions) DeleteSource(source library.Source) { f.deleted = append(f.deleted, source.ID) }
func (f *fakeActions) RevealInFinder(track library.Track) { f.revealed++ }
func (f *fakeActions) CreatePlaylist(name string)         { f.playlists = append(f.playlists, "create:"+name) }
func (f *fakeActions) RenamePlaylist(id, name string) {
	f.playlists = append(f.playlists, "rename:"+id+":"+name)
}
func (f *fakeActions) DeletePlaylist(id string)                { f.playlists = append(f.playlists, "delete:"+id) }
func (f *fakeActions) RemoveFromPlaylist(id string, index int) { f.removed = append(f.removed, index) }
func (f *fakeActions) MovePlaylistItem(id string, from, to int) {
	f.moved = append(f.moved, [2]int{from, to})
}
func (f *fakeActions) Queue() []library.Track { return f.queue }
func (f *fakeActions) SetFavorite(track library.Track, favorite bool) {
	if favorite {
		f.favorites = append(f.favorites, "+"+track.ID)
		return
	}
	f.favorites = append(f.favorites, "-"+track.ID)
}
func (f *fakeActions) AddToPlaylist(id string, ids []string) {
	f.added = append(f.added, id+"="+strings.Join(ids, ","))
}

// sampleTracks is the two-row fixture the fixed expectations use.
func sampleTracks() []library.ScannedTrack {
	return []library.ScannedTrack{
		{
			FilePathOrURL: "/music/西西里.flac", Title: "西西里", Artist: "周杰伦", Album: "太阳之子",
			Duration: 229 * time.Second, FileFormat: "flac", TrackNumber: 1, DiscNumber: 1, Year: 2016,
			Lyrics: "[00:01.00]第一句\n[00:05.00]第二句\n[00:09.00]第三句",
		},
		{
			FilePathOrURL: "/music/湘女多情.flac", Title: "湘女多情", Artist: "周杰伦", Album: "太阳之子",
			Duration: 238 * time.Second, FileFormat: "flac", TrackNumber: 2, DiscNumber: 1, Year: 2016,
		},
	}
}

// newLibrary creates a temporary library and returns it with a window over it.
func newLibrary(t *testing.T, tracks []library.ScannedTrack) (*library.Library, *Model) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	ctx := context.Background()
	// A file with the frozen version and no tables: OpenWritable's 补差 pass
	// creates the production schema, which is exactly what it does for a
	// legacy library.
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("create library: %v", err)
	}
	if _, err := db.Execute(ctx, "PRAGMA user_version = 2"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	db.Close()

	lib, err := library.OpenWritable(ctx, path)
	if err != nil {
		t.Fatalf("open library: %v", err)
	}
	t.Cleanup(func() { lib.Close() })
	source := library.Source{ID: "src-local", Name: "本地目录", Kind: "local", LocalFolderPath: "/music", SyncStatus: "已同步"}
	if err := lib.UpsertLocalSource(ctx, source); err != nil {
		t.Fatalf("source: %v", err)
	}
	if len(tracks) > 0 {
		merge, err := lib.MergeScan(ctx, source.ID, tracks, true)
		if err != nil {
			t.Fatalf("merge: %v", err)
		}
		if merge.Added != len(tracks) {
			t.Fatalf("merge added %d of %d tracks", merge.Added, len(tracks))
		}
	}

	m := New(lib.Queries(), lib, path, nil)
	m.State().FinishOnboarding()
	sources, err := lib.Sources(ctx)
	if err != nil {
		t.Fatalf("sources: %v", err)
	}
	m.SetSources(sources)
	m.SetCoversDir(library.CoversDir(filepath.Dir(path)))
	warmModel(m)
	return lib, m
}

// warmModel runs the model's frame loop until its lists have their first page.
// The pages are read from SQL on a worker goroutine, so a window that drew one
// frame would photograph the loading state.
func warmModel(m *Model) {
	st := m.State()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		st.Tick(time.Now())
		if st.Settled() {
			return
		}
		time.Sleep(time.Millisecond)
	}
}

// trackByTitle finds a loaded row, so a test can play the one with lyrics.
func trackByTitle(t *testing.T, m *Model, title string) library.Track {
	t.Helper()
	for _, track := range m.State().Library().Items() {
		if track.Title == title {
			return track
		}
	}
	t.Fatalf("%q is not in the library", title)
	return library.Track{}
}

func newModel(t *testing.T) *Model {
	t.Helper()
	_, m := newLibrary(t, sampleTracks())
	return m
}

// frame draws one frame after letting the model tick (the window's own View
// ticks once; a page whose rows arrived meanwhile shows on this frame).
func frame(tt *ui.Tester) {
	tt.Frame()
	tt.Frame()
}

func TestViewShowsSidebarAndLibrary(t *testing.T) {
	m := newModel(t)
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
	m := New(nil, nil, "/tmp/tingyu-m0/library.sqlite", errors.New("user_version 3, want 2"))
	m.State().FinishOnboarding()
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"无法打开曲库", "user_version 3, want 2", "/tmp/tingyu-m0/library.sqlite"} {
		if !tt.HasText(want) {
			t.Errorf("view does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestScanProgressIsVisible(t *testing.T) {
	m := newModel(t)
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
	m := newModel(t)
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
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	track := m.State().Library().Items()[0]
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 10 * time.Second, Volume: 0.5},
		Track:    &track,
		Repeat:   player.RepeatAll,
	})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	for _, label := range []string{"上一首", "暂停", "下一首", "随机播放：关"} {
		if err := tt.Click(label); err != nil {
			t.Fatalf("click %q: %v (texts %q)", label, err, tt.Texts())
		}
	}
	if actions.previous != 1 || actions.toggles != 1 || actions.next != 1 {
		t.Fatalf("actions = %+v", actions)
	}
	if !actions.shuffle || !m.State().Shuffle() {
		t.Fatalf("shuffle = %v / %v", actions.shuffle, m.State().Shuffle())
	}
	if err := tt.Click("循环：列表循环"); err != nil {
		t.Fatalf("click repeat: %v", err)
	}
	if actions.repeat != player.RepeatOne || m.State().Repeat() != player.RepeatOne {
		t.Fatalf("repeat = %v / %v", actions.repeat, m.State().Repeat())
	}
}

func TestAddDirectoryButton(t *testing.T) {
	m := newModel(t)
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
	m := newModel(t)
	track := m.State().Library().Items()[0]
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
	m := newModel(t)
	track := trackByTitle(t, m, "西西里")
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
	m := newModel(t)
	track := trackByTitle(t, m, "西西里")
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
	m := newModel(t)
	track := trackByTitle(t, m, "西西里")
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
	m := newModel(t)
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
	frame(tt)
	if !tt.HasText("西西里") || !tt.HasText("1 项") {
		t.Fatalf("results missing; texts are %q", tt.Texts())
	}
	// The songs scope pages through the same SQL query.
	if err := tt.Click("歌曲"); err != nil {
		t.Fatalf("歌曲 scope: %v", err)
	}
	frame(tt)
	if !tt.HasText("已全部加载 · 共 1 首") {
		t.Fatalf("song scope did not list the hit; texts are %q", tt.Texts())
	}
}

func TestSettingsThemePersistsOnlyWhenWritable(t *testing.T) {
	m := newModel(t)
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
	m := New(nil, nil, "/tmp/library.sqlite", nil)
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

func TestFavoriteClickWritesThroughTheApp(t *testing.T) {
	m := newModel(t)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	// The first row is not a favourite in this fixture.
	if err := tt.Click("收藏此曲"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if len(actions.favorites) != 1 || !strings.HasPrefix(actions.favorites[0], "+") {
		t.Fatalf("favourite did not reach the write path: %v (texts %q)", actions.favorites, tt.Texts())
	}
	if strings.Contains(strings.Join(tt.Texts(), "|"), "需内核支持") {
		t.Fatal("the window still reports a missing kernel for favourites")
	}
}

func TestFavoriteSurvivesTheRowMenuAndTheStage(t *testing.T) {
	lib, m := newLibrary(t, sampleTracks())
	actions := &fakeActions{}
	m.SetActions(actions)
	ctx := context.Background()
	tracks, err := lib.TracksPage(ctx, library.TrackQuery{Sort: library.SortTitle})
	if err != nil || len(tracks) == 0 {
		t.Fatalf("tracks: %v", err)
	}
	// The write path itself (the app calls the same method).
	if err := lib.SetFavorite(ctx, tracks[0].ID, true); err != nil {
		t.Fatal(err)
	}
	m.Invalidate()
	warmModel(m)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("取消收藏此曲") {
		t.Fatalf("the row does not show the favourite it has; texts %q", tt.Texts())
	}
	// Read the row again: the value read before the write still says "not a
	// favourite", and the stage draws what it is given.
	refreshed, _, err := lib.Track(ctx, tracks[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	m.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Playing: true}, Track: &refreshed, Repeat: player.RepeatAll})
	m.State().OpenStage()
	frame(tt)
	if !tt.HasText("取消收藏") {
		t.Fatalf("the stage does not show the favourite; texts %q", tt.Texts())
	}
}

func TestPaginationFooterLoadsOnePagePerClick(t *testing.T) {
	rows := make([]library.ScannedTrack, 0, 100)
	for i := range 100 {
		rows = append(rows, library.ScannedTrack{
			FilePathOrURL: fmt.Sprintf("/music/%03d.flac", i),
			Title:         fmt.Sprintf("曲目 %03d", i),
			Artist:        fmt.Sprintf("艺术家 %02d", i%7),
			Album:         fmt.Sprintf("专辑 %02d", i%5),
			Duration:      time.Duration(120+i%60) * time.Second,
			FileFormat:    "flac",
		})
	}
	_, m := newLibrary(t, rows)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if !tt.HasText("已显示 40 / 共 100 首") {
		t.Fatalf("first page footer missing; texts %q", tt.Texts())
	}
	if err := tt.Click("加载更多"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().Library().Loaded() != 80 || !tt.HasText("已显示 80 / 共 100 首") {
		t.Fatalf("one click loaded %d, texts %q", m.State().Library().Loaded(), tt.Texts())
	}
	if err := tt.Click("加载更多"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().Library().Loaded() != 100 || !tt.HasText("已全部加载 · 共 100 首") {
		t.Fatalf("end footer missing; loaded=%d texts=%q", m.State().Library().Loaded(), tt.Texts())
	}
}

func TestSettingsPersistWhenWritable(t *testing.T) {
	dir := t.TempDir()
	m := newModel(t)
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
	lib, m := newLibrary(t, sampleTracks())
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	tracks, err := lib.TracksPage(ctx, library.TrackQuery{Sort: library.SortTitle})
	if err != nil || len(tracks) == 0 {
		t.Fatalf("tracks: %v", err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{tracks[0].ID}); err != nil {
		t.Fatal(err)
	}
	m.Invalidate()
	warmModel(m)
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &tracks[0], Repeat: player.RepeatAll,
	})
	if err := lib.SetFavorite(ctx, tracks[0].ID, true); err != nil {
		t.Fatal(err)
	}
	m.Invalidate()
	warmModel(m)
	m.State().SetQueue(tracks, 0)
	trackWithLyrics := trackByTitle(t, m, "西西里")
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 6 * time.Second},
		Track:    &trackWithLyrics, Repeat: player.RepeatAll,
	})
	tt := ui.NewTester(m.View, MinimumWidth, MinimumHeight)
	shots := []struct {
		page    string
		prepare func()
		want    string
	}{
		{model.PageLibrary, nil, "播放全部"},
		{model.PageFavorites, nil, "已全部加载 · 共 1 首"},
		{model.PageAlbums, nil, "太阳之子"},
		{model.PageArtists, nil, "周杰伦"},
		{model.PagePlaylists, nil, "通勤"},
		{model.PagePlaylistDetail, func() { m.State().OpenPlaylist(playlist) }, "随机播放"},
		{model.PageSearch, nil, "最近搜索"},
		{model.PageSettings, nil, "主题模式"},
		{model.PageSources, nil, "本地目录"},
		{model.PageQueue, nil, "当前播放"},
		{model.PageLyrics, nil, "随播放高亮"},
	}
	for _, shot := range shots {
		if shot.prepare != nil {
			shot.prepare()
		} else {
			m.State().OpenPage(shot.page)
		}
		tt.SetSize(MinimumWidth, MinimumHeight)
		frame(tt)
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
	m := newModel(t)
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

func TestPaletteOpensFiltersAndPlays(t *testing.T) {
	m := newModel(t)
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
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("专辑"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if !tt.HasText("太阳之子") {
		t.Fatalf("albums page missing the album; texts %q", tt.Texts())
	}
	if err := tt.Click("太阳之子"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().Page() != model.PageAlbumDetail || !tt.HasText("在艺人中查看") {
		t.Fatalf("album detail not shown; page=%s texts=%q", m.State().Page(), tt.Texts())
	}
	if !tt.HasText("西西里") || !tt.HasText("湘女多情") {
		t.Fatalf("album detail did not read its tracks from SQL; texts %q", tt.Texts())
	}
	m.State().Back()
	frame(tt)
	if err := tt.Click("艺术家"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if err := tt.Click("周杰伦"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().Page() != model.PageArtistDetail || !tt.HasText("全部曲目") {
		t.Fatalf("artist detail not shown; page=%s texts=%q", m.State().Page(), tt.Texts())
	}
	if !tt.HasText("2 首 · 1 张专辑 · 7 分钟") && !tt.HasText("1 张专辑 · 2 首") {
		t.Fatalf("artist summary missing; texts %q", tt.Texts())
	}
}

func TestQueuePageListsCurrentAndNext(t *testing.T) {
	m := newModel(t)
	tracks := m.State().Library().Items()
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 5 * time.Second},
		Track:    &tracks[0], Repeat: player.RepeatAll,
	})
	m.State().SetQueue(tracks, 0)
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

func TestPlaylistCreateRenameAndDeleteThroughTheWindow(t *testing.T) {
	lib, m := newLibrary(t, sampleTracks())
	ctx := context.Background()
	actions := &fakeActions{}
	m.SetActions(actions)
	m.State().OpenPage(model.PagePlaylists)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("还没有歌单") {
		t.Fatalf("empty playlist page missing; texts %q", tt.Texts())
	}
	if err := tt.Click("新建歌单"); err != nil {
		t.Fatalf("新建歌单: %v", err)
	}
	tt.Frame()
	// The inline field takes the name; Enter commits it.
	tt.Type("通勤")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if len(actions.playlists) != 1 || actions.playlists[0] != "create:通勤" {
		t.Fatalf("create = %v (texts %q)", actions.playlists, tt.Texts())
	}

	// A real playlist, so the page has a row to rename and delete.
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	m.Invalidate()
	frame(tt)
	if !tt.HasText("通勤") {
		t.Fatalf("the created playlist is not listed; texts %q", tt.Texts())
	}

	// Rename: the row menu opens the inline field.
	if err := tt.Click("歌单操作"); err != nil {
		t.Fatalf("歌单操作: %v", err)
	}
	if err := tt.ChooseMenuItem("重命名…"); err != nil {
		t.Fatalf("重命名…: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	tt.Type("·夜跑")
	tt.Key(0, ui.KeyEnter)
	tt.Frame()
	if got := actions.playlists[len(actions.playlists)-1]; got != "rename:"+playlist.ID+":通勤·夜跑" {
		t.Fatalf("rename = %q", got)
	}

	// Delete asks first, and only the dialog's confirm writes.
	if err := tt.Click("歌单操作"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("删除歌单…"); err != nil {
		t.Fatalf("删除歌单…: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if !tt.HasText("删除歌单「通勤」？") {
		t.Fatalf("no confirmation; texts %q", tt.Texts())
	}
	if len(actions.playlists) != 2 {
		t.Fatalf("the delete wrote before the confirmation: %v", actions.playlists)
	}
	if err := tt.Click("确认删除"); err != nil {
		t.Fatalf("确认删除: %v", err)
	}
	tt.Frame()
	if got := actions.playlists[len(actions.playlists)-1]; got != "delete:"+playlist.ID {
		t.Fatalf("delete = %q", got)
	}
}

func TestPlaylistPageOffersReorderAndRemove(t *testing.T) {
	lib, m := newLibrary(t, sampleTracks())
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	tracks, err := lib.TracksPage(ctx, library.TrackQuery{Sort: library.SortTitle})
	if err != nil || len(tracks) != 2 {
		t.Fatalf("tracks: %v", err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{tracks[0].ID, tracks[1].ID}); err != nil {
		t.Fatal(err)
	}
	actions := &fakeActions{}
	m.SetActions(actions)
	m.Invalidate()
	warmModel(m)
	m.State().OpenPlaylist(playlist)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("西西里") || !tt.HasText("湘女多情") {
		t.Fatalf("the playlist page did not list its items; texts %q", tt.Texts())
	}
	// The first row's menu can only move down and remove.
	openRowMenu(t, tt, m.State().PlaylistTracks().Items()[0].Title)
	if err := tt.ChooseMenuItem("下移"); err != nil {
		t.Fatalf("下移: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if len(actions.moved) != 1 || actions.moved[0] != [2]int{0, 1} {
		t.Fatalf("move = %v", actions.moved)
	}
	openRowMenu(t, tt, m.State().PlaylistTracks().Items()[0].Title)
	if err := tt.ChooseMenuItem("移出歌单"); err != nil {
		t.Fatalf("移出歌单: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if len(actions.removed) != 1 || actions.removed[0] != 0 {
		t.Fatalf("remove = %v", actions.removed)
	}
	// 「添加到播放列表」 on a row reaches the app with the playlist it chose.
	openRowMenu(t, tt, m.State().PlaylistTracks().Items()[0].Title)
	if err := tt.ChooseMenuItem("添加到播放列表", "通勤"); err != nil {
		t.Fatalf("添加到播放列表: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if len(actions.added) != 1 || !strings.HasPrefix(actions.added[0], playlist.ID+"=") {
		t.Fatalf("add = %v", actions.added)
	}
}

func TestSourceDeleteNeedsConfirmation(t *testing.T) {
	_, m := newLibrary(t, sampleTracks())
	actions := &fakeActions{}
	m.SetActions(actions)
	m.State().OpenPage(model.PageSources)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	if !tt.HasText("本地目录") {
		t.Fatalf("source missing; texts %q", tt.Texts())
	}
	if err := tt.Click("来源操作"); err != nil {
		t.Fatal(err)
	}
	if err := tt.ChooseMenuItem("删除来源…"); err != nil {
		t.Fatalf("删除来源…: %v (menu %v)", err, tt.Menu())
	}
	tt.Frame()
	if !tt.HasText("删除来源「本地目录」？") {
		t.Fatalf("no confirmation; texts %q", tt.Texts())
	}
	if len(actions.deleted) != 0 {
		t.Fatalf("the delete wrote before the confirmation: %v", actions.deleted)
	}
	if err := tt.Click("确认删除"); err != nil {
		t.Fatalf("确认删除: %v", err)
	}
	tt.Frame()
	if len(actions.deleted) != 1 || actions.deleted[0] != "src-local" {
		t.Fatalf("deleted = %v", actions.deleted)
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

func TestSourcesPageShowsRemoteFormsAndRelogin(t *testing.T) {
	m := newModel(t)
	m.State().SetSources([]library.Source{{
		ID: "src-quark", Name: "我的夸克", Kind: "quark", TrackCount: 4, SyncStatus: "未同步",
	}})
	m.State().OpenPage(model.PageSources)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"添加来源", "远程来源", "我的夸克", "立即同步", "同步目录：/（全部文件）"} {
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
