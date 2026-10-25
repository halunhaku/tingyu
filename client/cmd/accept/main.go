// Command accept is the M2 acceptance harness (plan §6 M2). It plays the nine
// supported formats, streams from a local Range+auth server, renders an album
// transition to measure gapless, runs the three loop modes, exercises failure
// and recovery, and plays a 200-track queue.
//
// It measures the production kernel (internal/mpv + internal/player); it is not
// part of the app. Build and run it with scripts/run-m2-accept.sh, which also
// gives the binary the LC_RPATH libmpv's frameworks need.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/accept"
	"github.com/halunhaku/tingyu/client/internal/mpv"
)

func main() {
	mediaDir := flag.String("media", filepath.Join("build", "m2-media"), "generated media root (scripts/gen-m2-media.sh)")
	outDir := flag.String("out", "", "evidence directory (default build/m2-evidence/<timestamp>)")
	phases := flag.String("phases", "", "comma-separated phases: "+strings.Join(accept.Phases, ","))
	mpvPath := flag.String("mpv", "", "libmpv path (default: MPV_LIB, app bundle, then the pub cache)")
	flag.Parse()

	libraryPath := *mpvPath
	if libraryPath == "" {
		libraryPath = mpv.LibraryPath()
	}
	if libraryPath == "" {
		fmt.Fprintln(os.Stderr, "accept: no libmpv found; set MPV_LIB or build the app bundle first")
		os.Exit(2)
	}
	out := *outDir
	if out == "" {
		out = filepath.Join("build", "m2-evidence", time.Now().Format("20060102-150405"))
	}
	lib, err := mpv.Load(libraryPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "accept:", err)
		os.Exit(2)
	}

	var selected []string
	if strings.TrimSpace(*phases) != "" {
		selected = strings.Split(*phases, ",")
	}
	report, err := accept.Run(accept.Options{
		MediaDir: *mediaDir,
		OutDir:   out,
		Phases:   selected,
		Lib:      lib,
		Logf: func(format string, args ...any) {
			fmt.Printf("%s "+format+"\n", append([]any{time.Now().Format("15:04:05.000")}, args...)...)
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "accept:", err)
		os.Exit(2)
	}
	path, err := report.Write(out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "accept: write report:", err)
		os.Exit(2)
	}
	fmt.Println()
	fmt.Println(report.Summary())
	fmt.Println("report:", path)
	if failed := report.Failed(); len(failed) > 0 {
		os.Exit(1)
	}
}
