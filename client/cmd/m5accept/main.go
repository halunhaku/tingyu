// Command m5accept runs the M5 acceptance (plan §6 M5): it copies the real
// library, demotes twenty tracks to untagged rows, runs the production
// enrichment pipeline against the four live sources, and writes the evidence —
// database before/after, screenshots, cover-cache counts, palette values and
// the offline and manual-match checks — into an evidence directory.
//
//	./scripts/run-m5-accept.sh                       # everything
//	./scripts/run-m5-accept.sh -tracks 5             # a quick run
//	./scripts/run-m5-accept.sh -skip-network         # offline phases only
//
// The production library is only ever read; TINGYU_DATA_DIR is ignored on
// purpose so a stray environment cannot point the harness at a source other
// than the one it was told to copy.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/m5accept"
)

func main() {
	source := flag.String("from", "", "production data directory to copy (default: the real Application Support directory)")
	work := flag.String("work", "", "working copy directory (default: build/m5-accept/<timestamp>/data)")
	out := flag.String("out", "", "evidence directory (default: build/m5-accept/<timestamp>)")
	tracks := flag.Int("tracks", 20, "how many untagged tracks the pass covers")
	skipNetwork := flag.Bool("skip-network", false, "run only the offline/deterministic phases")
	flag.Parse()

	sourceDir := *source
	if sourceDir == "" {
		dir, err := library.DataDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, "m5accept:", err)
			os.Exit(2)
		}
		sourceDir = dir
	}
	stamp := time.Now().Format("20060102-150405")
	outDir := *out
	if outDir == "" {
		outDir = filepath.Join("build", "m5-accept", stamp)
	}
	workDir := *work
	if workDir == "" {
		workDir = filepath.Join(outDir, "data")
	}
	if absolute, err := filepath.Abs(workDir); err == nil {
		workDir = absolute
	}
	if sameDir(workDir, sourceDir) {
		fmt.Fprintln(os.Stderr, "m5accept: -work is the production data directory; refusing to clear it (plan §8.1 rule 2)")
		os.Exit(2)
	}
	for _, stale := range []string{library.Path(workDir), library.CoversDir(workDir)} {
		// Only the two paths the harness owns are cleared; the check below is a
		// belt-and-braces against an operator pointing -work at a real folder.
		if err := os.RemoveAll(stale); err != nil {
			fmt.Fprintln(os.Stderr, "m5accept: clear", stale, ":", err)
			os.Exit(2)
		}
	}

	report, err := m5accept.Run(context.Background(), m5accept.Options{
		SourceDataDir: sourceDir,
		WorkDir:       workDir,
		OutDir:        outDir,
		Tracks:        *tracks,
		SkipNetwork:   *skipNetwork,
		Log: func(format string, args ...any) {
			fmt.Printf("%s "+format+"\n", append([]any{time.Now().Format("15:04:05.000")}, args...)...)
		},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "m5accept:", err)
		os.Exit(2)
	}
	fmt.Println()
	fmt.Println(report.Summary())
	fmt.Println("evidence:", outDir)
	fmt.Println("report:", filepath.Join(outDir, "m5-evidence.json"))
	if failed := report.Failed(); len(failed) > 0 {
		fmt.Println("failed:", failed)
		os.Exit(1)
	}
}

// sameDir reports whether two paths name the same directory.
func sameDir(a, b string) bool {
	left, errA := filepath.Abs(a)
	right, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return false
	}
	return filepath.Clean(left) == filepath.Clean(right)
}
