// Command iconpreview renders the installed SVGs with the actual MyGo renderer.
package main

import (
	"flag"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

func main() {
	out := flag.String("out", "../design/icon-proposals/runtime-preview.png", "PNG output")
	flag.Parse()
	paths, err := filepath.Glob("internal/ui/components/icons/*.svg")
	if err != nil || len(paths) == 0 {
		log.Fatal("run from client/; SVG assets not found")
	}
	type entry struct {
		name string
		icon *ui.SVG
	}
	entries := make([]entry, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}
		entries = append(entries, entry{strings.TrimSuffix(filepath.Base(path), ".svg"), ui.MustParseSVG(data)})
	}
	view := func(c *ui.Context) {
		ui.Row(c).Fill().Children(func() {
			for _, p := range []tokens.Palette{tokens.Light, tokens.Dark} {
				ui.Column(c).Width(440).FillHeight().Padding(20).Gap(4).Background(p.Canvas).Children(func() {
					ui.Text(c, "声屿 · 16 / 24 / 32 px").FontSize(18).TextColor(p.TextPrimary)
					for _, e := range entries {
						ui.Row(c).Height(40).AlignItems(ui.Center).Gap(28).Children(func() {
							ui.Text(c, e.name).Width(150).FontSize(13).TextColor(p.TextSecondary)
							for _, size := range []float32{16, 24, 32} {
								ui.Box(c).Size(36, 36).Center().Children(func() { ui.Icon(c, e.icon).FontSize(size).TextColor(p.TextPrimary) })
							}
						})
					}
				})
			}
		})
	}
	img := ui.Render(view, 880, 70+len(entries)*44, 1)
	if err := os.MkdirAll(filepath.Dir(*out), 0755); err != nil {
		log.Fatal(err)
	}
	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		log.Fatal(err)
	}
	log.Printf("rendered %d SVGs at 16/24/32px in both themes: %s", len(entries), *out)
}
