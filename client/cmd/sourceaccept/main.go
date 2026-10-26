// Command sourceaccept is the M3 acceptance harness (plan §6 M3). It scans a
// 120-track WebDAV source and a Quark source through the production source
// layer, plays remote tracks with Range and per-track headers, expires a Quark
// direct link mid-playback to watch it refresh, cancels a sync to prove nothing
// is deleted, and proves credentials live only in the Keychain.
//
// It measures the production packages (internal/sources, internal/mpv,
// internal/player) against local mock servers; it never touches the real
// WebDAV/Quark services or the production library. Build and run it with
// scripts/run-m3-accept.sh, which gives the binary libmpv's frameworks.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/sourceaccept"
)

func main() {
	outDir := flag.String("out", "", "evidence directory (default build/m3-evidence/<timestamp>)")
	mpvPath := flag.String("mpv", "", "libmpv path (default: MPV_LIB, app bundle, then the pub cache)")
	keychain := flag.String("keychain-service", "", "Keychain service for acceptance items (default: sourceaccept's own)")
	flag.Parse()

	libraryPath := *mpvPath
	if libraryPath == "" {
		libraryPath = mpv.LibraryPath()
	}
	if libraryPath == "" {
		fmt.Fprintln(os.Stderr, "sourceaccept: no libmpv found; set MPV_LIB or build the app bundle first")
		os.Exit(2)
	}
	out := *outDir
	if out == "" {
		out = filepath.Join("build", "m3-evidence", time.Now().Format("20060102-150405"))
	}
	lib, err := mpv.Load(libraryPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sourceaccept:", err)
		os.Exit(2)
	}
	report, err := sourceaccept.Run(sourceaccept.Options{
		OutDir:          out,
		Lib:             lib,
		KeychainService: *keychain,
		Logf: func(format string, args ...any) {
			fmt.Printf("%s "+format+"\n", append([]any{time.Now().Format("15:04:05.000")}, args...)...)
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "sourceaccept:", err)
		os.Exit(2)
	}
	path, err := report.Write(out)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sourceaccept: write report:", err)
		os.Exit(2)
	}
	fmt.Println()
	fmt.Println(report.Summary())
	fmt.Println("report:", path)
	if failed := report.Failed(); len(failed) > 0 {
		os.Exit(1)
	}
}
