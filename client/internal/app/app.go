// Package app assembles the M0 client: it reads the library once, builds
// the native UI shell, opens the window and reports the cold-start marks.
// It deliberately stops at reading: playback, scanning and media keys are
// M1 (plan §6), and no code here opens the library for writing.
package app

import (
	"context"
	"fmt"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/shell"
)

// Main reads the library, shows the window, and runs until the app quits.
// A library that cannot be read is not fatal for M0: the window opens and
// explains why, so the failure is visible instead of a silent blank table.
func Main() error {
	st := newStartup()
	defer st.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	dataDir, err := library.DataDir()
	var path string
	var tracks []library.Track
	if err != nil {
		st.printf("library: %v", err)
	} else {
		path = library.Path(dataDir)
		st.mark("data dir")
		tracks, err = loadLibrary(ctx, path)
		if err != nil {
			st.printf("library: %v", err)
		} else {
			st.printf("library: %d tracks from %s (read-only, user_version %d)", len(tracks), path, library.SchemaVersion)
			st.mark("library read")
		}
	}

	model := shell.New(tracks, path, err)
	mygo.App.WhenReady(func() {
		win := mygo.NewWindow(mygo.WindowOptions{
			Title:     "听屿",
			Width:     shell.DefaultWidth,
			Height:    shell.DefaultHeight,
			MinWidth:  shell.MinimumWidth,
			MinHeight: shell.MinimumHeight,
			Content:   ui.View(model.View),
		})
		st.printf("window: %dx%d, minimum %dx%d", shell.DefaultWidth, shell.DefaultHeight, shell.MinimumWidth, shell.MinimumHeight)
		st.mark("window created")
		var ready bool
		win.OnReadyToShow(func() {
			if ready {
				return
			}
			ready = true
			st.mark("ready")
		})
		win.OnFocus(func() { st.mark("focused") })
	})
	return mygo.App.Run()
}

// loadLibrary opens the database read-only, reads every track and closes
// the connection. Closing keeps M0's footprint and guarantees no handle
// outlives startup that could later be used for writes.
func loadLibrary(ctx context.Context, path string) ([]library.Track, error) {
	lib, err := library.Open(ctx, path)
	if err != nil {
		return nil, err
	}
	defer lib.Close()
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return tracks, nil
}
