package shell

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

func visibleControl(t *testing.T, tt *ui.Tester, label string, width, height int, minWidth, minHeight float32) ui.Rect {
	t.Helper()
	r, ok := tt.Find(label)
	if !ok || r.W < minWidth || r.H < minHeight || r.X < 0 || r.Y < 0 || r.X+r.W > float32(width)+.1 || r.Y+r.H > float32(height)+.1 {
		t.Fatalf("%q is clipped or outside %dx%d: %+v (found=%v)", label, width, height, r, ok)
	}
	return r
}

func TestTransportRemainsVisibleAcrossPagesAndSizes(t *testing.T) {
	for _, size := range [][2]int{{900, 600}, {1200, 760}, {1440, 900}} {
		for _, compact := range []bool{false, true} {
			for _, playing := range []bool{false, true} {
				t.Run(fmt.Sprintf("%dx%d/compact=%v/playing=%v", size[0], size[1], compact, playing), func(t *testing.T) {
					rows := sampleTracks()
					rows[0].CoverArtPath = "missing-cover.png"
					_, m := newLibrary(t, rows)
					settings := m.State().Settings()
					if compact {
						settings.Density = "compact"
					}
					m.State().SetSettings(settings)
					label := "播放"
					if playing {
						tr := m.State().Library().Items()[0]
						m.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Playing: true, Volume: .8, Duration: tr.Duration}, Track: &tr})
						label = "暂停"
					}
					tt := ui.NewTester(m.View, size[0], size[1])
					frame(tt)
					for _, page := range []string{model.PageLibrary, model.PageFavorites, model.PageSearch, model.PageSettings, model.PageSources, model.PageQueue, model.PageAlbums, model.PageArtists, model.PagePlaylists, model.PageLyrics} {
						m.State().OpenPage(page)
						frame(tt)
						bar := visibleControl(t, tt, "播放控制栏", size[0], size[1], 600, tokens.TransportHeight)
						if bar.Y != float32(size[1])-tokens.TransportHeight || bar.H != tokens.TransportHeight {
							t.Fatalf("%s: transport lost its reserved height: %+v", page, bar)
						}
						for _, control := range []string{label, "上一首", "下一首", "播放队列", "歌词", "打开播放舞台"} {
							// Find matches the first text/label: these page headings share
							// names with transport buttons. Their clicks are tested below.
							if (control == "播放" && page == model.PageSettings) || (control == "播放队列" && page == model.PageQueue) || (control == "歌词" && page == model.PageLyrics && !playing) {
								continue
							}
							t.Run(page+"/"+control, func(t *testing.T) {
								r := visibleControl(t, tt, control, size[0], size[1], 32, 30)
								if r.Y < float32(size[1])-tokens.TransportHeight {
									t.Fatalf("transport control escaped bottom bar: %+v", r)
								}
							})
						}
						visibleControl(t, tt, "播放进度", size[0], size[1], 80, 15)
					}
					// Error banners must take room from the page, never the transport.
					m.State().OpenPage(model.PageSettings)
					m.State().SetError("测试错误：来源暂时无法访问，请检查连接后重试。")
					frame(tt)
					visibleControl(t, tt, "播放控制栏", size[0], size[1], 600, tokens.TransportHeight)
				})
			}
		}
	}
}

func TestAmbientCoverReachesWindowBottom(t *testing.T) {
	for _, size := range [][2]int{{900, 600}, {1200, 760}, {1440, 900}} {
		root := ui.Rect{W: float32(size[0]), H: float32(size[1])}
		cover := ambientCoverRect(root)
		if cover.Y >= root.Y || cover.X >= root.X {
			t.Fatalf("%dx%d: cover leaves a top or left gap: root=%+v cover=%+v", size[0], size[1], root, cover)
		}
		if cover.Y+cover.H <= root.Y+root.H || cover.X+cover.W <= root.X+root.W {
			t.Fatalf("%dx%d: cover leaves a bottom or right gap: root=%+v cover=%+v", size[0], size[1], root, cover)
		}
	}
}

func TestMinimumTransportControlsAreClickable(t *testing.T) {
	m := newModel(t)
	a := &fakeActions{}
	m.SetActions(a)
	tr := m.State().Library().Items()[0]
	m.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Playing: true, Volume: .8}, Track: &tr})
	tt := ui.NewTester(m.View, MinimumWidth, MinimumHeight)
	frame(tt)
	for _, label := range []string{"上一首", "暂停", "下一首"} {
		if err := tt.Click(label); err != nil {
			t.Fatal(err)
		}
	}
	if a.previous != 1 || a.toggles != 1 || a.next != 1 {
		t.Fatalf("controls did not reach actions: %+v", a)
	}
	for _, step := range []struct{ label, page string }{{"播放队列", model.PageQueue}, {"歌词", model.PageLyrics}, {"打开播放舞台", model.PageStage}} {
		if err := tt.Click(step.label); err != nil {
			t.Fatal(err)
		}
		frame(tt)
		if m.State().Page() != step.page {
			t.Fatalf("%s opened %s", step.label, m.State().Page())
		}
	}
}

func TestSearchInputsShareQueryAndClear(t *testing.T) {
	m := newModel(t)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	frame(tt)
	tt.Key(ui.Cmd, ui.KeyF)
	frame(tt)
	tt.Type("周杰伦")
	frame(tt)
	if m.State().SidebarQuery() != m.State().Search().Input || m.State().SidebarQuery() != "周杰伦" {
		t.Fatalf("inputs differ: sidebar=%q main=%q", m.State().SidebarQuery(), m.State().Search().Input)
	}
	tt.Advance(model.SearchDebounceTime + time.Millisecond)
	frame(tt)
	if m.State().Search().Query != "周杰伦" {
		t.Fatal("search did not debounce")
	}
	if err := tt.Click("清除"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().SidebarQuery() != "" || m.State().Search().Input != "" || m.State().Search().Query != "" {
		t.Fatal("clear left stale search text")
	}
	m.State().Search().Remember("西西里")
	frame(tt)
	if err := tt.Click("西西里"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if m.State().SidebarQuery() != "西西里" {
		t.Fatal("recent search left sidebar stale")
	}
}

func TestTransportVolumeUsesLatestState(t *testing.T) {
	m := newModel(t)
	a := &fakeActions{}
	m.SetActions(a)
	tr := m.State().Library().Items()[0]
	update := player.Update{Snapshot: mpv.Snapshot{Playing: true, Volume: .8}, Track: &tr}
	m.SetPlayer(update)
	tt := ui.NewTester(m.View, 1440, 900)
	frame(tt)
	update.Snapshot.Volume = .2
	m.SetPlayer(update)
	frame(tt)
	r := visibleControl(t, tt, "音量", 1440, 900, 72, 16)
	// Focus the slider with a pointer, then update externally before a keyboard
	// step. A cached .8 would jump back up instead of stepping from .2.
	tt.ClickAt(r.X+r.W/2, r.Y+r.H/2)
	m.SetPlayer(update)
	frame(tt)
	tt.Key(0, ui.KeyRight)
	frame(tt)
	if math.Abs(a.volume-.21) > .001 || math.Abs(m.State().Volume()-.21) > .001 {
		t.Fatalf("volume step used stale state: action=%v state=%v", a.volume, m.State().Volume())
	}
}

func TestTransportMainControlsShareVerticalCenter(t *testing.T) {
	m := newModel(t)
	tr := m.State().Library().Items()[0]
	m.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Playing: true, Volume: .8}, Track: &tr})
	tt := ui.NewTester(m.View, 1200, 760)
	frame(tt)
	for _, size := range [][2]int{{900, 600}, {1200, 760}, {1440, 900}} {
		tt.SetSize(size[0], size[1])
		frame(tt)
		play := visibleControl(t, tt, "暂停", size[0], size[1], 42, 42)
		for _, label := range []string{"上一首", "下一首", "播放队列", "歌词", "打开播放舞台"} {
			r := visibleControl(t, tt, label, size[0], size[1], 32, 32)
			if math.Abs(float64(r.Y+r.H/2-play.Y-play.H/2)) > .5 {
				t.Fatalf("%s center differs from play: %+v vs %+v", label, r, play)
			}
		}
		progress := visibleControl(t, tt, "播放进度", size[0], size[1], 80, 15)
		if progress.Y < play.Y+play.H {
			t.Fatal("progress overlaps main controls")
		}
	}
}
