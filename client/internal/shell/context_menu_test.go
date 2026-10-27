package shell

import (
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

func assertSongMenu(t *testing.T, tt *ui.Tester, title string) {
	t.Helper()
	if err := tt.RightClick(title); err != nil {
		t.Fatalf("right-click %q: %v (texts %q)", title, err, tt.Texts())
	}
	menu := tt.Menu()
	for _, want := range []string{"播放", "收藏", "匹配元数据…", "在访达中显示"} {
		found := false
		for _, item := range menu {
			if item == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("menu for %q lacks %q: %v", title, want, menu)
		}
	}
	tt.CloseMenu()
}

func TestSongContextMenuAppearsOnEveryRowSurface(t *testing.T) {
	m := newModel(t)
	m.SetActions(&fakeActions{})
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)

	m.State().OpenAlbum(model.Album{Name: "太阳之子", Artist: "周杰伦", Count: 2})
	frame(tt)
	assertSongMenu(t, tt, "西西里")

	m.State().OpenArtist(model.Artist{Name: "周杰伦", Count: 2, Albums: 1})
	frame(tt)
	assertSongMenu(t, tt, "西西里")

	m.State().Search().SetQuery("西西里")
	m.State().OpenPage(model.PageSearch)
	warmModel(m)
	frame(tt)
	assertSongMenu(t, tt, "西西里")

	tracks := m.State().Library().Items()
	m.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{Playing: true, Duration: 229 * time.Second, Position: 5 * time.Second},
		Track:    &tracks[0],
	})
	m.State().SetQueue(tracks, 0)
	m.State().OpenPage(model.PageQueue)
	frame(tt)
	assertSongMenu(t, tt, "湘女多情")

	m.State().OpenStage()
	frame(tt)
	assertSongMenu(t, tt, tracks[1].Title)
}
