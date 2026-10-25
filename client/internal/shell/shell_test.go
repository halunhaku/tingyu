package shell

import (
	"errors"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
)

func TestViewShowsSidebarAndRealTrackColumns(t *testing.T) {
	tracks := []library.Track{
		{ID: "a", Title: "西西里", Artist: "周杰伦", Album: "太阳之子", Duration: 229 * time.Second},
		{ID: "b", Title: "湘女多情", Artist: "周杰伦", Album: "太阳之子", Duration: 238 * time.Second},
	}
	m := New(tracks, "/tmp/tingyu-m0/library.sqlite", nil)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)

	for _, want := range []string{
		"听屿", "曲库", "收藏", "专辑", "艺术家", "歌单", "设置",
		"2 首",
		"曲名", "艺术家", "时长",
		"西西里", "周杰伦", "太阳之子", "3:49",
		"湘女多情", "3:58",
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
