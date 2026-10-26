// Command designpreview renders the three redesign directions to PNG without a
// window, through the same view pipeline the app shows (ui.Render at 2×). It
// reads a library copy read-only for real titles, artists, covers and lyrics,
// and writes docs/screenshots/design/<direction>/<page>-<theme>.png plus the
// token dump the design document quotes.
//
//	go run ./tools/designpreview -data "$HOME/Library/Application Support/com.halunhaku.tingyu" \
//	  -out ../docs/screenshots/design -tokens ../docs/design/2026-10-26-ui-redesign-tokens.json
//
// It never writes the library, never starts playback and touches no app code:
// internal/ui is used only for its read-only data shapes, and the three
// directions are drawn from ui primitives in this package.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
)

var pages = []string{"library", "stage", "sources", "settings"}

func main() {
	dataDir := flag.String("data", defaultDataDir(), "library directory (read-only); TINGYU_DATA_DIR also works")
	outDir := flag.String("out", "../docs/screenshots/design", "output directory for the PNGs")
	tokensPath := flag.String("tokens", "../docs/design/2026-10-26-ui-redesign-tokens.json", "where to write the token dump (empty to skip)")
	only := flag.String("only", "", "comma-separated direction keys to render (a,b,c); empty renders all")
	flag.Parse()
	if *dataDir == "" {
		log.Fatal("set -data to a library directory")
	}
	at, err := load(*dataDir)
	if err != nil {
		log.Fatalf("load library: %v", err)
	}
	wanted := map[string]bool{}
	for _, key := range strings.Split(*only, ",") {
		if key = strings.TrimSpace(key); key != "" {
			wanted[key] = true
		}
	}
	dirs := Directions
	if len(wanted) > 0 {
		dirs = nil
		for _, d := range Directions {
			if wanted[d.Key] {
				dirs = append(dirs, d)
			}
		}
	}
	for _, d := range dirs {
		for _, theme := range []string{"light", "dark"} {
			pal := d.Light
			if theme == "dark" {
				pal = d.Dark
			}
			for _, page := range pages {
				page, pal, d := page, pal, d
				view := func(c *ui.Context) {
					s := &scene{c: c, d: d, p: pal, at: at}
					switch d.Key {
					case "a":
						s.pageA(page)
					case "b":
						s.pageB(page)
					case "c":
						s.pageC(page)
					}
				}
				img := ui.Render(view, 1200, 760, 2)
				dir := filepath.Join(*outDir, d.Key)
				if err := os.MkdirAll(dir, 0o755); err != nil {
					log.Fatal(err)
				}
				name := filepath.Join(dir, page+"-"+theme+".png")
				f, err := os.Create(name)
				if err != nil {
					log.Fatal(err)
				}
				if err := png.Encode(f, img); err != nil {
					f.Close()
					log.Fatalf("encode %s: %v", name, err)
				}
				f.Close()
				log.Printf("wrote %s", name)
			}
		}
	}
	if *tokensPath != "" {
		if err := os.MkdirAll(filepath.Dir(*tokensPath), 0o755); err != nil {
			log.Fatal(err)
		}
		raw, err := json.MarshalIndent(map[string]any{
			"generatedBy": "client/tools/designpreview",
			"canvas":      "1200×760 DIP @2×",
			"directions":  Directions,
		}, "", "  ")
		if err != nil {
			log.Fatal(err)
		}
		if err := os.WriteFile(*tokensPath, append(raw, '\n'), 0o644); err != nil {
			log.Fatal(err)
		}
		log.Printf("wrote %s", *tokensPath)
	}
	fmt.Printf("rendered %d directions to %s\n", len(dirs), *outDir)
}

func defaultDataDir() string {
	if dir := os.Getenv("TINGYU_DATA_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "com.halunhaku.tingyu")
}

var _ = library.CoversDir
