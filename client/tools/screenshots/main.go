// Command screenshots renders the M4 pages to PNG without a window, through the
// same view the app shows (ui.Render at 2×). It reads a library copy with
// TINGYU_DATA_DIR (never writing it) and writes docs/screenshots/m4-*.png.
//
//	go run ./tools/screenshots -data /tmp/tingyu-copy -out ../docs/screenshots
package main

import (
	"context"
	"flag"
	"fmt"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/shell"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

func main() {
	dataDir := flag.String("data", os.Getenv("TINGYU_DATA_DIR"), "library copy directory (default: TINGYU_DATA_DIR)")
	outDir := flag.String("out", "../docs/screenshots", "output directory")
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
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		log.Fatalf("tracks: %v", err)
	}
	sources, err := lib.Sources(ctx)
	if err != nil {
		log.Fatalf("sources: %v", err)
	}
	// The library stays open read-only: the pages now read their lists from
	// SQL, so the tool holds one read-only connection and never writes it.
	defer lib.Close()
	if len(tracks) == 0 {
		log.Fatal("the library has no tracks; point -data at a copy with music")
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		log.Fatal(err)
	}

	app := shell.New(lib.Queries(), lib, path, nil)
	st := app.State()
	warm(st)
	st.SetSources(sources)
	st.SetCoversDir(library.CoversDir(*dataDir))
	// Preferences go to a scratch directory: the library copy is read-only for
	// this tool, and the production directory is never touched.
	settingsDir, err := os.MkdirTemp("", "tingyu-m4-screenshots")
	if err != nil {
		log.Fatal(err)
	}
	st.ConfigureDataDir(settingsDir, true)
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
			Paused:     false,
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

	shots := []struct {
		name, dark string
		prepare    func()
	}{
		{"library", "", func() { st.OpenPage(model.PageLibrary) }},
		{"albums", "", func() { st.OpenPage(model.PageAlbums) }},
		{"artists", "", func() { st.OpenPage(model.PageArtists) }},
		{"favorites", "", func() { st.OpenPage(model.PageFavorites) }},
		{"playlists", "", func() { st.OpenPage(model.PagePlaylists) }},
		{"search", "", func() {
			st.OpenPage(model.PageSearch)
			st.Search().SetQuery(demo.Artist)
			warm(st)
		}},
		{"stage", "", func() { st.OpenStage() }},
		{"queue", "", func() { st.OpenPage(model.PageQueue) }},
		{"lyrics", "", func() {
			st.Player()
			st.OpenPage(model.PageLyrics)
		}},
		{"settings", "", func() {
			st.SetSettingsSection(0)
			st.OpenPage(model.PageSettings)
		}},
		{"sources", "", func() { st.OpenPage(model.PageSources) }},
		{"onboarding", "", func() {
			onboard := shell.New(nil, nil, path, nil)
			onboard.State().ConfigureDataDir(settingsDir, true)
			render(*outDir, "onboarding", "light", onboard)
			render(*outDir, "onboarding", "dark", onboard)
		}},
	}
	for _, shot := range shots {
		shot.prepare()
		if shot.name == "onboarding" {
			continue
		}
		render(*outDir, shot.name, "light", app)
		render(*outDir, shot.name, "dark", app)
	}
	fmt.Printf("screenshots written to %s\n", *outDir)
}

// warm ticks the model until its lists have their rows. The lists are read
// from SQL on a worker goroutine, so a renderer that drew one frame would
// photograph the loading state instead of the library.
func warm(st *model.State) {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		st.Tick(time.Now())
		if st.Library().Loaded() > 0 && st.Albums().Items() != nil && st.Artists().Items() != nil &&
			st.Counts().Tracks > 0 {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func render(outDir, page, theme string, app *shell.Model) {
	st := app.State()
	settings := st.Settings()
	settings.ThemeMode = theme
	st.SetSettings(settings)
	img := ui.Render(app.View, 1200, 760, 2)
	name := filepath.Join(outDir, "m4-"+page+"-"+theme+".png")
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
	// Put the demo first, as the controller rotates the queue to the click.
	return out
}
