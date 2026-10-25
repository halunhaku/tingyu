// Package accept is the M2 acceptance harness: it drives the production
// playback kernel (internal/mpv + internal/player) through the cases the plan's
// M2 row lists — nine formats, remote playback over HTTP Range with per-track
// authentication, gapless album playback, the three loop modes, failure
// snapshots that recover, rate/volume, and a 200-track queue — and records what
// it measured.
//
// It is a development tool. Nothing in the app imports it, and it is not part
// of what ships.
package accept

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/mpv"
)

// Phases lists the phase names Run understands, in execution order.
var Phases = []string{"formats", "remote", "gapless", "queue", "loops", "controls"}

// Options configures a run.
type Options struct {
	// MediaDir is the generated media root (scripts/gen-m2-media.sh).
	MediaDir string
	// OutDir receives report.json and the server request log.
	OutDir string
	// Phases selects a subset; empty means every phase.
	Phases []string
	// Lib is the loaded libmpv.
	Lib *mpv.Lib
	// Logf receives progress lines.
	Logf func(format string, args ...any)
}

// Run executes the selected phases.
func Run(opts Options) (*Report, error) {
	log := opts.Logf
	if log == nil {
		log = func(string, ...any) {}
	}
	if opts.Lib == nil {
		return nil, fmt.Errorf("accept: no libmpv loaded")
	}
	selected, err := selectPhases(opts.Phases)
	if err != nil {
		return nil, err
	}
	report := &Report{StartedAt: time.Now(), MediaDir: opts.MediaDir}
	major, minor := clientAPI(opts.Lib)
	report.Host = hostInfo(mpv.LibraryPath(), fmt.Sprintf("%d.%d", major, minor), "coreaudio")
	if err := os.MkdirAll(opts.OutDir, 0o755); err != nil {
		return nil, err
	}

	for _, phase := range selected {
		log("== phase %s", phase)
		switch phase {
		case "formats":
			runFormats(opts.Lib, opts.MediaDir, log, report)
		case "remote":
			runRemote(opts.Lib, opts.MediaDir, opts.OutDir, log, report)
		case "gapless":
			runGapless(opts.Lib, opts.MediaDir, opts.OutDir, log, report)
		case "queue":
			runQueueReplace(opts.Lib, opts.MediaDir, log, report)
			runQueue(opts.Lib, opts.MediaDir, log, report)
		case "loops":
			runLoops(opts.Lib, opts.MediaDir, log, report)
		case "controls":
			runControls(opts.Lib, opts.MediaDir, log, report)
		}
	}
	report.FinishedAt = time.Now()
	return report, nil
}

func clientAPI(lib *mpv.Lib) (int, int) {
	version := lib.ClientAPIVersion()
	return int(version >> 16), int(version & 0xffff)
}

func selectPhases(requested []string) ([]string, error) {
	if len(requested) == 0 {
		return Phases, nil
	}
	var selected []string
	for _, want := range requested {
		want = strings.TrimSpace(want)
		if want == "" {
			continue
		}
		if want == "all" {
			return Phases, nil
		}
		known := false
		for _, phase := range Phases {
			if phase == want {
				known = true
				break
			}
		}
		if !known {
			return nil, fmt.Errorf("accept: unknown phase %q (known: %s)", want, strings.Join(Phases, ", "))
		}
		selected = append(selected, want)
	}
	return selected, nil
}

// requireMedia returns the path of a generated file, or an empty string and a
// note when it is missing.
func requireMedia(mediaDir, relative string) (string, string) {
	path := filepath.Join(mediaDir, relative)
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Sprintf("测试媒体缺失：%s（先跑 scripts/gen-m2-media.sh）", path)
	}
	return path, ""
}

// skip records a check that could not run because its media is missing.
func skip(report *Report, id, name, note string) {
	report.Add(Check{ID: id, Name: name, Skipped: true, Note: note})
}
