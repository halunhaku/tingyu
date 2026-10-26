// Command uipreview renders the real window of direction A's first batch to PNG
// without a window, through the same view the app shows (ui.Tester at 2×), and
// builds the side-by-side page an acceptance reads: each page next to the design
// still it implements (docs/screenshots/design/a).
//
//	go run ./tools/uipreview -data /tmp/tingyu-copy -out ../docs/screenshots/ui-a1
//
// It never writes the library and never starts playback: the library copy is
// opened read-only, settings go to a scratch directory, and the "playing" track
// is set on the model only, so the transport and the stage have something to
// show.
package main

import (
	"context"
	"flag"
	"fmt"
	"image"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"
	"golang.org/x/image/draw"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/shell"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// pages are the four pages the design stills cover, in the stills' names.
var pages = []string{"library", "stage", "sources", "settings"}

func main() {
	dataDir := flag.String("data", os.Getenv("TINGYU_DATA_DIR"), "library copy directory (default: TINGYU_DATA_DIR)")
	outDir := flag.String("out", "../docs/screenshots/ui-a1", "output directory")
	targetDir := flag.String("target", "../docs/screenshots/design/a", "the design stills to compare against (empty to skip)")
	flag.Parse()
	if *dataDir == "" {
		log.Fatal("set -data or TINGYU_DATA_DIR to a library copy")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := library.Path(*dataDir)
	lib, err := library.Open(ctx, path)
	if err != nil {
		log.Fatalf("open library: %v", err)
	}
	defer lib.Close()
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		log.Fatalf("tracks: %v", err)
	}
	if len(tracks) == 0 {
		log.Fatal("the library has no tracks; point -data at a copy with music")
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatal(err)
	}

	// Settings go to a scratch directory: the copy is read-only for this tool
	// and the production directory is never touched.
	settingsDir, err := os.MkdirTemp("", "tingyu-uipreview")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(settingsDir)

	app := shell.New(lib.Queries(), lib, path, nil)
	st := app.State()
	st.ConfigureDataDir(settingsDir, true)
	st.SetCoversDir(library.CoversDir(*dataDir))
	st.FinishOnboarding()

	demo := pickDemoTrack(tracks)
	queue := pickQueue(tracks, demo, 24)
	index := 0
	for i, track := range queue {
		if track.ID == demo.ID {
			index = i
		}
	}
	st.SetPlayer(player.Update{
		Snapshot: mpv.Snapshot{
			Processing: mpv.Ready,
			Playing:    true,
			Position:   96 * time.Second,
			Duration:   demo.Duration,
			Volume:     0.8,
			Rate:       1,
		},
		Index:  index,
		Track:  &demo,
		Repeat: player.RepeatAll,
	})
	st.SetQueue(queue, index)

	// The after-stills: the real window at the design's canvas, both themes.
	for _, page := range pages {
		open(page, st)
		for _, theme := range []string{"light", "dark"} {
			setTheme(st, theme)
			shot := run(app, page, shell.DefaultWidth, shell.DefaultHeight, theme)
			write(*outDir, page, theme, shot)
			if page == "library" {
				first, last := st.Library().Table().Visible()
				log.Printf("%s-%s: table rows %d..%d of %d loaded, %d visible",
					page, theme, first, last, st.Library().Loaded(), last-first+1)
			}
		}
	}

	// The minimum window (900×600): the fixed column rhythm drops 专辑 first,
	// so the page keeps a readable row there instead of clipping.
	open("library", st)
	setTheme(st, "light")
	write(*outDir, "library-min", "light", run(app, "library", shell.MinimumWidth, shell.MinimumHeight, "light"))

	// The keyboard's focus ring on a table row: Tab into the list, choose a row
	// with Down, then photograph the frame.
	open("library", st)
	setTheme(st, "light")
	write(*outDir, "library-focus", "light", focusShot(app, st))

	// The materials and the shared states of the batch: the palette over its
	// scrim (Regular glass), an empty list, and the error card.
	open("library", st)
	setTheme(st, "light")
	st.OpenPalette()
	palette := st.Palette()
	palette.Input = "epiphany"
	palette.OnInput(st.Now())
	write(*outDir, "palette", "light", run(app, "library", shell.DefaultWidth, shell.DefaultHeight, "light"))
	st.ClosePalette()

	st.Library().SetQuery("没有这一首")
	write(*outDir, "empty", "light", run(app, "library", shell.DefaultWidth, shell.DefaultHeight, "light"))
	st.Library().SetQuery("")

	failed := shell.New(nil, nil, filepath.Join(*dataDir, "library.sqlite"), context.DeadlineExceeded)
	failed.State().ConfigureDataDir(settingsDir, false)
	failed.State().FinishOnboarding()
	write(*outDir, "error", "light", run(failed, "library", shell.DefaultWidth, shell.DefaultHeight, "light"))

	// The comparison page, with the design stills copied next to the renders so
	// the page reads on its own.
	if *targetDir != "" {
		copyTargets(*targetDir, *outDir)
	}
	writeIndex(*outDir)
	fmt.Printf("renders written to %s\n", *outDir)
}

// open shows a page of the four.
func open(page string, st *model.State) {
	switch page {
	case "stage":
		st.OpenPage(model.PageLibrary)
		st.OpenStage()
	case "sources":
		st.OpenPage(model.PageSources)
	case "settings":
		st.SetSettingsSection(0)
		st.OpenPage(model.PageSettings)
	default:
		st.OpenPage(model.PageLibrary)
	}
}

func setTheme(st *model.State, theme string) {
	settings := st.Settings()
	settings.ThemeMode = theme
	st.SetSettings(settings)
}

// run renders one page in a window of width×height DIPs at 2× after letting the
// paged lists hold their rows (the lists read SQL on a worker goroutine, so a
// single frame would photograph the loading state).
func run(app *shell.Model, page string, width, height int, theme string) *ui.Tester {
	tt := ui.NewTester(app.View, width, height)
	settle(tt, app)
	return tt
}

// settle draws frames until every list holds its rows, with a cap so a broken
// page fails the run instead of hanging.
func settle(tt *ui.Tester, app *shell.Model) {
	for i := 0; i < 40; i++ {
		tt.Frame()
		if i > 2 && app.State().Settled() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// focusShot tab-walks to the track list, moves the choice once and returns the
// frame, so the ring the keyboard draws is in the picture.
func focusShot(app *shell.Model, st *model.State) *ui.Tester {
	tt := ui.NewTester(app.View, shell.DefaultWidth, shell.DefaultHeight)
	settle(tt, app)
	for i := 0; i < 40 && st.Library().Selected() < 0; i++ {
		tt.Key(0, ui.KeyTab)
		tt.KeyDown(ui.KeyDown)
		tt.Frame()
	}
	tt.KeyDown(ui.KeyDown)
	tt.Frame()
	tt.Frame()
	return tt
}

func write(outDir, page, theme string, tt *ui.Tester) {
	img := tt.Image()
	if img == nil {
		log.Fatalf("%s-%s: no image", page, theme)
	}
	name := filepath.Join(outDir, page+"-"+theme+".png")
	file, err := os.Create(name)
	if err != nil {
		log.Fatalf("create %s: %v", name, err)
	}
	defer file.Close()
	if err := png.Encode(file, img); err != nil {
		log.Fatalf("encode %s: %v", name, err)
	}
	log.Printf("wrote %s", name)
}

// copyTargets brings the design stills next to the renders, so the comparison
// page needs no path outside its own directory. They are halved to 1200 wide:
// the originals stay the reference in docs/screenshots/design/a, and the page
// only has to show them beside the render.
func copyTargets(targetDir, outDir string) {
	for _, page := range pages {
		for _, theme := range []string{"light", "dark"} {
			name := page + "-" + theme + ".png"
			file, err := os.Open(filepath.Join(targetDir, name))
			if err != nil {
				log.Printf("no design still %s: %v", name, err)
				continue
			}
			src, err := png.Decode(file)
			file.Close()
			if err != nil {
				log.Fatalf("decode %s: %v", name, err)
			}
			bounds := src.Bounds()
			half := image.NewRGBA(image.Rect(0, 0, bounds.Dx()/2, bounds.Dy()/2))
			draw.ApproxBiLinear.Scale(half, half.Bounds(), src, bounds, draw.Src, nil)
			out, err := os.Create(filepath.Join(outDir, "target-"+name))
			if err != nil {
				log.Fatalf("create %s: %v", name, err)
			}
			if err := png.Encode(out, half); err != nil {
				out.Close()
				log.Fatalf("encode %s: %v", name, err)
			}
			out.Close()
		}
	}
}

// writeIndex writes the three-column comparison: the design still, the real
// window after this batch, and the same page in the other theme.
func writeIndex(outDir string) {
	var b strings.Builder
	b.WriteString(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>方向 A 第一批 · 渲染对比</title>
<style>
 :root { color-scheme: light dark; }
 body { margin: 0; padding: 32px; font: 14px/1.6 -apple-system, "PingFang SC", system-ui, sans-serif;
        background: #F4F4F1; color: #17171A; }
 @media (prefers-color-scheme: dark) { body { background: #0E0E10; color: #F3F3F5; } }
 h1 { font-size: 24px; letter-spacing: -0.4px; margin: 0 0 4px; }
 p.note { color: #6A6A71; margin: 0 0 28px; }
 section { margin: 0 0 40px; }
 h2 { font-size: 16px; letter-spacing: -0.2px; margin: 0 0 12px; }
 .pair { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: start; }
 figure { margin: 0; }
 figure img { width: 100%; height: auto; border-radius: 12px; border: 1px solid #E1E1DA; display: block; }
 figcaption { font-size: 12px; color: #6A6A71; margin-top: 6px; }
 code { font-size: 12px; }
</style></head><body>
<h1>方向 A · 第一批：真实窗口渲染对比</h1>
<p class="note">左为设计定稿图（<code>docs/screenshots/design/a/</code>，由 <code>tools/designpreview</code> 画出），
右为本次改动后由 <code>go run ./tools/uipreview</code> 用真实 <code>shell.View</code> 离屏渲染的同一页（1200×760 DIP @2×）。
舞台 / 来源 / 设置页的 A 化属于下一批，这里只有令牌与外壳的连带效果。</p>
`)
	for _, page := range pages {
		fmt.Fprintf(&b, "<section><h2>%s</h2>\n", pageTitle(page))
		for _, theme := range []string{"light", "dark"} {
			fmt.Fprintf(&b, `<div class="pair">
  <figure><img src="target-%s-%s.png" alt="设计图"><figcaption>目标：%s · %s</figcaption></figure>
  <figure><img src="%s-%s.png" alt="实现渲染"><figcaption>实现：%s · %s</figcaption></figure>
</div>
`, page, theme, pageTitle(page), themeName(theme), page, theme, page, themeName(theme))
		}
		b.WriteString("</section>\n")
	}
	b.WriteString(`<section><h2>材质与通用状态</h2>
<div class="pair">
  <figure><img src="palette-light.png" alt="命令面板"><figcaption>⌘K 命令面板：Regular 玻璃 + 遮罩</figcaption></figure>
  <figure><img src="empty-light.png" alt="空态"><figcaption>空态：56 图标砖 + 20/600 + 13 + 主操作</figcaption></figure>
</div>
<div class="pair">
  <figure><img src="error-light.png" alt="错误卡"><figcaption>错误卡：440 宽 + 两个动作</figcaption></figure>
</div>
</section>
<section><h2>最小窗口与键盘焦点</h2>
<div class="pair">
  <figure><img src="library-min-light.png" alt="900×600"><figcaption>最小窗口 900×600：固定列宽整列让位（先「专辑」，再「艺术家」），不裁切行</figcaption></figure>
  <figure><img src="library-focus-light.png" alt="键盘焦点"><figcaption>Tab 进入表格、↓ 选中一行：2 px 朱红焦点环</figcaption></figure>
</div>
</section>
</body></html>
`)
	name := filepath.Join(outDir, "index.html")
	if err := os.WriteFile(name, []byte(b.String()), 0o644); err != nil {
		log.Fatalf("write %s: %v", name, err)
	}
	log.Printf("wrote %s", name)
}

func pageTitle(page string) string {
	switch page {
	case "library":
		return "曲库"
	case "stage":
		return "舞台"
	case "sources":
		return "来源"
	case "settings":
		return "设置"
	}
	return page
}

func themeName(theme string) string {
	if theme == "dark" {
		return "深色"
	}
	return "浅色"
}

// pickDemoTrack prefers a track with both lyrics and a cover, so the stage has
// something to show; the transport and the table reuse it.
func pickDemoTrack(tracks []library.Track) library.Track {
	best := tracks[0]
	for _, track := range tracks {
		if track.Lyrics != "" && track.CoverArtPath != "" {
			return track
		}
		if track.Lyrics != "" {
			best = track
		}
	}
	if best.CoverArtPath == "" {
		for _, track := range tracks {
			if track.CoverArtPath != "" {
				best.CoverArtPath = track.CoverArtPath
				break
			}
		}
	}
	return best
}

func pickQueue(tracks []library.Track, demo library.Track, n int) []library.Track {
	out := make([]library.Track, 0, n)
	out = append(out, demo)
	for _, track := range tracks {
		if len(out) >= n {
			break
		}
		if track.ID != demo.ID {
			out = append(out, track)
		}
	}
	return out
}

var _ = tokens.SidebarWidth
