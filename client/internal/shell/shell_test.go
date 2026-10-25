package shell

import (
	"errors"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
)

type fakeActions struct {
	played   []library.Track
	start    int
	toggles  int
	next     int
	previous int
	seek     time.Duration
	volume   float64
	repeat   player.RepeatMode
	chosen   int
}

func (f *fakeActions) PlayTracks(tracks []library.Track, start int) error {
	f.played = tracks
	f.start = start
	return nil
}
func (f *fakeActions) TogglePlayPause() error            { f.toggles++; return nil }
func (f *fakeActions) Next() error                       { f.next++; return nil }
func (f *fakeActions) Previous() error                   { f.previous++; return nil }
func (f *fakeActions) Seek(position time.Duration) error { f.seek = position; return nil }
func (f *fakeActions) SetVolume(volume float64) error {
	f.volume = volume
	return nil
}
func (f *fakeActions) CycleRepeat() player.RepeatMode {
	f.repeat = player.RepeatOne
	return f.repeat
}
func (f *fakeActions) ChooseDirectory() { f.chosen++ }

func sampleTracks() []library.Track {
	return []library.Track{
		{ID: "a", Title: "西西里", Artist: "周杰伦", Album: "太阳之子", Duration: 229 * time.Second, PlayCount: 3},
		{ID: "b", Title: "湘女多情", Artist: "周杰伦", Album: "太阳之子", Duration: 238 * time.Second},
	}
}

func TestViewShowsSidebarTrackColumnsAndEmptyScanState(t *testing.T) {
	m := New(sampleTracks(), "/tmp/tingyu-m0/library.sqlite", nil)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{
		"听屿", "曲库", "收藏", "专辑", "艺术家", "歌单", "设置",
		"2 首",
		"曲名", "艺术家", "专辑", "时长", "播放",
		"西西里", "周杰伦", "太阳之子", "3:49", "3",
		"湘女多情", "3:58",
		"添加目录…",
		"未在播放",
		"/tmp/tingyu-m0/library.sqlite",
	} {
		if !tt.HasText(want) {
			t.Errorf("view does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestViewExplainsALibraryItCannotRead(t *testing.T) {
	m := New(nil, "/tmp/tingyu-m0/library.sqlite", errors.New("user_version 3, want 2"))
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	for _, want := range []string{"无法打开曲库", "user_version 3, want 2", "/tmp/tingyu-m0/library.sqlite"} {
		if !tt.HasText(want) {
			t.Errorf("view does not show %q; texts are %q", want, tt.Texts())
		}
	}
}

func TestScanProgressIsVisible(t *testing.T) {
	m := New(nil, "/tmp/library.sqlite", nil)
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

func TestDoubleClickPlaysTheSelectedTrack(t *testing.T) {
	m := New(sampleTracks(), "/tmp/library.sqlite", nil)
	actions := &fakeActions{}
	m.SetActions(actions)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("湘女多情"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if err := tt.Click("湘女多情"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if len(actions.played) != 2 || actions.start != 1 {
		t.Fatalf("double click played %v at %d, texts %q", actions.played, actions.start, tt.Texts())
	}
}

func TestTransportButtonsCallActions(t *testing.T) {
	m := New(sampleTracks(), "/tmp/library.sqlite", nil)
	actions := &fakeActions{}
	m.SetActions(actions)
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Paused: false, Duration: 229 * time.Second, Position: 10 * time.Second, Volume: 0.5},
		Track:    &m.tracks[0],
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
	if err := tt.Click("循环：全部循环"); err != nil {
		t.Fatalf("click repeat: %v", err)
	}
	if actions.repeat != player.RepeatOne {
		t.Fatalf("repeat = %v", actions.repeat)
	}
}

func TestAddDirectoryButton(t *testing.T) {
	m := New(nil, "/tmp/library.sqlite", nil)
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

func TestPlayerFailureIsShown(t *testing.T) {
	m := New(sampleTracks(), "/tmp/library.sqlite", nil)
	m.SetPlayer(player.Update{Failure: &mpv.Failure{Message: "无法播放：LOADING_FAILED"}})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	if !tt.HasText("⚠ 无法播放：LOADING_FAILED") {
		t.Errorf("failure missing; texts are %q", tt.Texts())
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
