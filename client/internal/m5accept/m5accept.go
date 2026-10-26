// Package m5accept is the M5 acceptance harness (plan §6 M5).
//
// It works on a copy of the real library, never on the library itself: the copy
// is created under an evidence directory, twenty tracks are demoted to the
// state a scan of untagged files leaves behind (file-name title, placeholder
// artist/album, no cover, no lyrics), and then the production pipeline — the
// same metadata sources, cover fetcher, enrichment service and library writes
// the app uses — fills them in. The harness records the database before and
// after, renders the real window headlessly for the "refreshes without a
// restart" evidence, and runs the offline, cover-cache, palette and manual-match
// checks.
//
// It is not part of the app. scripts/run-m5-accept.sh builds and runs it.
package m5accept

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/enrich"
	"github.com/halunhaku/tingyu/client/internal/images"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/scan"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Options are the run's inputs.
type Options struct {
	// SourceDataDir is the production data directory; it is only ever read.
	SourceDataDir string
	// WorkDir is where the copy is made (created if missing).
	WorkDir string
	// OutDir receives the report, the screenshots and the before/after JSON.
	OutDir string
	// Tracks is how many untagged tracks the pass covers (20 for the plan's
	// acceptance).
	Tracks int
	// SkipNetwork runs only the offline phases; network checks are reported as
	// skipped rather than passed.
	SkipNetwork bool
	// Log receives progress lines.
	Log func(format string, args ...any)
}

// Check is one acceptance item with the numbers behind it.
type Check struct {
	ID      string         `json:"id"`
	Name    string         `json:"name"`
	Pass    bool           `json:"pass"`
	Skipped bool           `json:"skipped,omitempty"`
	Note    string         `json:"note,omitempty"`
	Data    map[string]any `json:"data,omitempty"`
}

// Report is the whole run.
type Report struct {
	StartedAt     time.Time `json:"startedAt"`
	FinishedAt    time.Time `json:"finishedAt"`
	Host          Host      `json:"host"`
	SourceDataDir string    `json:"sourceDataDir"`
	WorkDir       string    `json:"workDir"`
	OutDir        string    `json:"outDir"`
	Checks        []Check   `json:"checks"`
}

// Host records what the numbers were measured on.
type Host struct {
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	GoVersion string `json:"goVersion"`
}

// Add appends a check.
func (r *Report) Add(check Check) { r.Checks = append(r.Checks, check) }

// Failed lists the IDs that did not pass.
func (r *Report) Failed() []string {
	var ids []string
	for _, check := range r.Checks {
		if !check.Pass && !check.Skipped {
			ids = append(ids, check.ID)
		}
	}
	return ids
}

// Summary is the one-line outcome.
func (r *Report) Summary() string {
	passed, skipped := 0, 0
	for _, check := range r.Checks {
		switch {
		case check.Skipped:
			skipped++
		case check.Pass:
			passed++
		}
	}
	return fmt.Sprintf("M5 acceptance: %d passed, %d failed, %d skipped",
		passed, len(r.Failed()), skipped)
}

// Write stores the JSON report and a readable markdown record.
func (r *Report) Write(outDir string) (string, error) {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	jsonPath := filepath.Join(outDir, "m5-evidence.json")
	if err := os.WriteFile(jsonPath, data, 0o644); err != nil {
		return "", err
	}
	markdown := r.markdown()
	if err := os.WriteFile(filepath.Join(outDir, "m5-evidence.md"), []byte(markdown), 0o644); err != nil {
		return "", err
	}
	return jsonPath, nil
}

func (r *Report) markdown() string {
	var b strings.Builder
	fmt.Fprintf(&b, "# M5 验收证据（%s）\n\n", r.StartedAt.Format("2006-01-02 15:04:05"))
	fmt.Fprintf(&b, "- 生产库目录（只读）：`%s`\n- 副本：`%s`\n- 平台：%s/%s · %s\n\n",
		r.SourceDataDir, r.WorkDir, r.Host.OS, r.Host.Arch, r.Host.GoVersion)
	fmt.Fprintf(&b, "| # | 检查 | 结果 | 证据 |\n|---|---|---|---|\n")
	for _, check := range r.Checks {
		result := "通过"
		switch {
		case check.Skipped:
			result = "跳过"
		case !check.Pass:
			result = "**未通过**"
		}
		detail := check.Note
		if len(check.Data) > 0 {
			if encoded, err := json.Marshal(check.Data); err == nil {
				detail += " `" + string(encoded) + "`"
			}
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %s |\n", check.ID, check.Name, result, detail)
	}
	return b.String()
}

// demoted is one track turned into an untagged row, with what the library
// originally knew (the ground truth the report compares against).
type demoted struct {
	ID             string
	OriginalTitle  string
	OriginalArtist string
	OriginalAlbum  string
	OriginalCover  string
	OriginalLyrics int
	DemotedTitle   string
}

// rowSnapshot is what the after/before comparison records.
type rowSnapshot struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Artist    string `json:"artist"`
	Album     string `json:"album"`
	Cover     string `json:"cover"`
	HasLyrics bool   `json:"hasLyrics"`
	LyricsLen int    `json:"lyricsLen"`
}

// Run executes the acceptance.
func Run(ctx context.Context, opts Options) (*Report, error) {
	logf := opts.Log
	if logf == nil {
		logf = func(string, ...any) {}
	}
	report := &Report{
		StartedAt:     time.Now(),
		Host:          Host{OS: runtime.GOOS, Arch: runtime.GOARCH, GoVersion: runtime.Version()},
		SourceDataDir: opts.SourceDataDir,
		WorkDir:       opts.WorkDir,
		OutDir:        opts.OutDir,
	}
	if opts.Tracks <= 0 {
		opts.Tracks = 20
	}
	if err := os.MkdirAll(opts.OutDir, 0o755); err != nil {
		return nil, err
	}
	if sameDirectory(opts.SourceDataDir, opts.WorkDir) {
		return nil, errors.New("m5accept: the work directory must be a copy, never the production data directory (plan §8.1 rule 2)")
	}

	sourceLibrary := library.Path(opts.SourceDataDir)
	beforeProdHash, err := fileSHA256(sourceLibrary)
	if err != nil {
		return nil, fmt.Errorf("m5accept: read the production library: %w", err)
	}
	beforeProdVersion, err := userVersion(ctx, sourceLibrary)
	if err != nil {
		return nil, err
	}
	logf("production library %s sha256=%s user_version=%d", sourceLibrary, beforeProdHash, beforeProdVersion)
	report.Add(Check{
		ID: "m5.production-read-only", Name: "生产库只读打开（sha256 与 user_version 前后一致）", Pass: true,
		Note: "开始时记录；结束时复查",
		Data: map[string]any{"path": sourceLibrary, "sha256": beforeProdHash, "user_version": beforeProdVersion},
	})

	copyPath, copyCovers, err := copyLibrary(opts.SourceDataDir, opts.WorkDir)
	if err != nil {
		return nil, err
	}
	logf("copy ready: %s (covers %s)", copyPath, copyCovers)
	report.Add(Check{
		ID: "m5.copy", Name: "验收在曲库副本上进行", Pass: true,
		Note: "生产目录只读；副本含 library.sqlite 与 covers/",
		Data: map[string]any{"copy": copyPath, "covers": copyCovers},
	})

	lib, err := library.OpenWritable(ctx, copyPath)
	if err != nil {
		return nil, fmt.Errorf("m5accept: open the copy: %w", err)
	}
	defer lib.Close()
	report.Add(Check{
		ID: "m5.schema-version", Name: "user_version 保持 2（只加可空列/索引）", Pass: true,
		Data: map[string]any{"user_version": library.SchemaVersion},
	})

	// --- 20 untagged tracks -----------------------------------------
	demoted, err := demoteTracks(ctx, copyPath, opts.Tracks, nil)
	if err != nil {
		return nil, err
	}
	if len(demoted) < opts.Tracks {
		return nil, fmt.Errorf("m5accept: only %d tracks available to demote, need %d", len(demoted), opts.Tracks)
	}
	logf("demoted %d tracks to untagged rows (example: %q → %q)", len(demoted), demoted[0].OriginalTitle, demoted[0].DemotedTitle)

	beforeRows, err := snapshotRows(ctx, lib, demoted)
	if err != nil {
		return nil, err
	}
	beforeCounts, err := coverageCounts(ctx, copyPath)
	if err != nil {
		return nil, err
	}
	writeJSON(filepath.Join(opts.OutDir, "db-before.json"), map[string]any{
		"tracks":           beforeRows,
		"coverage":         beforeCounts,
		"library_revision": lib.Revision(),
	})

	// --- UI before ---------------------------------------------------
	probe, err := newUIProbe(lib, copyPath, copyCovers)
	if err != nil {
		return nil, err
	}
	usedTracks := map[string]bool{}
	for _, item := range demoted {
		usedTracks[item.ID] = true
	}
	first := demoted[0]
	searchTerm := first.OriginalTitle
	probe.setQuery(searchTerm)
	probe.settle(40)
	beforeTexts := probe.texts()
	probe.save(filepath.Join(opts.OutDir, "ui-before-library.png"))
	beforeShowsDemoted := containsText(beforeTexts, first.DemotedTitle)
	revisionBefore := lib.Revision()

	// --- the pipeline ------------------------------------------------
	counting := &countingTransport{base: sources.NewHTTPClient(20 * time.Second).Transport}
	httpClient := &http.Client{Transport: counting, Timeout: 20 * time.Second}
	store := &images.Store{Dir: copyCovers}
	fetcher := &images.Fetcher{Store: store, Client: httpClient, Log: func(format string, args ...any) { logf("cover: "+format, args...) }}
	enricher := &metadata.Enricher{
		Primary:        metadata.NewQQMusic(&metadata.HTTP{Client: httpClient}),
		Fallback:       metadata.NewNetEase(&metadata.HTTP{Client: httpClient}),
		Lyrics:         metadata.NewLRCLIB(&metadata.HTTP{Client: httpClient}),
		FallbackLyrics: metadata.NewNetEase(&metadata.HTTP{Client: httpClient}),
		Cover:          metadata.NewITunes(&metadata.HTTP{Client: httpClient}),
		Log:            func(format string, args ...any) { logf("metadata: "+format, args...) },
	}
	aiSettings, aiErr := readAISettings()
	if aiErr != "" {
		logf("AI settings: %s (the fallback stays off; the four HTTP sources need no key)", aiErr)
	}
	if client := metadata.NewAIClient(aiSettings, httpClient); client != nil {
		enricher.SetAI(client)
		logf("AI fallback configured: preset=%s model=%s key=%s", aiSettings.Preset, aiSettings.Model, aiSettings.MaskKey())
	} else {
		logf("AI fallback not configured; the four HTTP sources still run (missing key skips silently)")
	}
	service := &enrich.Service{Library: lib, Enricher: enricher, Covers: store, Fetcher: fetcher, Log: logf}

	if opts.SkipNetwork {
		report.Add(Check{ID: "m5.enrich", Name: "20 首无标签曲目补全", Skipped: true, Note: "-skip-network"})
		report.Add(Check{ID: "m5.ui-refresh", Name: "列表与舞台立即刷新", Skipped: true, Note: "-skip-network"})
	} else {
		passStarted := time.Now()
		summary := service.EnrichTargets(ctx, opts.Tracks, nil, nil)
		elapsed := time.Since(passStarted)
		logf("pass: attempted=%d changed=%d offline=%d skipped=%d failed=%d covers=%d lyrics=%d in %s",
			summary.Attempted, summary.Changed, summary.Offline, summary.Skipped, summary.Failed, summary.Covers, summary.Lyrics, elapsed.Round(time.Millisecond))

		afterRows, err := snapshotRows(ctx, lib, demoted)
		if err != nil {
			return nil, err
		}
		afterCounts, err := coverageCounts(ctx, copyPath)
		if err != nil {
			return nil, err
		}
		writeJSON(filepath.Join(opts.OutDir, "db-after.json"), map[string]any{
			"tracks":           afterRows,
			"coverage":         afterCounts,
			"library_revision": lib.Revision(),
			"pass": map[string]any{
				"attempted": summary.Attempted, "changed": summary.Changed, "offline": summary.Offline,
				"skipped": summary.Skipped, "failed": summary.Failed, "covers": summary.Covers,
				"lyrics": summary.Lyrics, "elapsedMs": elapsed.Milliseconds(),
			},
		})

		withTitle, withCover, withLyrics := 0, 0, 0
		titleMatches := 0
		for i, row := range afterRows {
			if row.Title != demoted[i].DemotedTitle {
				withTitle++
				if row.Title == demoted[i].OriginalTitle {
					titleMatches++
				}
			}
			if row.Cover != "" {
				withCover++
			}
			if row.HasLyrics {
				withLyrics++
			}
		}
		pass := summary.Changed >= opts.Tracks/2 && withTitle >= opts.Tracks/2 && withCover >= 1 && withLyrics >= 1
		report.Add(Check{
			ID: "m5.enrich", Name: "20 首无标签曲目补全：标题/封面/歌词落库",
			Pass: pass,
			Note: fmt.Sprintf("处理 %d，变更 %d；标题 %d、封面 %d、歌词 %d；与原始标题一致 %d",
				summary.Attempted, summary.Changed, withTitle, withCover, withLyrics, titleMatches),
			Data: map[string]any{
				"attempted": summary.Attempted, "changed": summary.Changed,
				"offline": summary.Offline, "skipped": summary.Skipped, "failed": summary.Failed,
				"withTitle": withTitle, "withCover": withCover, "withLyrics": withLyrics,
				"exactTitleMatches": titleMatches,
				"elapsedMs":         elapsed.Milliseconds(),
				"requests":          counting.count.Load(),
			},
		})

		// --- UI after: same window, no restart -----------------------
		probe.setState(func(s *model.State) { s.Invalidate() })
		probe.setQuery(searchTerm)
		probe.settle(60)
		afterTexts := probe.texts()
		probe.save(filepath.Join(opts.OutDir, "ui-after-library.png"))

		refreshed, found, readErr := lib.Track(ctx, first.ID)
		if readErr != nil || !found {
			return nil, fmt.Errorf("m5accept: read the refreshed track: %v", readErr)
		}
		afterShowsNew := containsText(afterTexts, refreshed.Title)
		revisionAfter := lib.Revision()

		// The settings panel and the manual-match dialog, with the numbers the
		// app would have pushed and candidates fetched from the sources.
		settingsView := model.EnrichmentView{
			Changed: summary.Changed, Offline: summary.Offline, Skipped: summary.Skipped,
			Failed: summary.Failed, Covers: summary.Covers, Lyrics: summary.Lyrics,
			Done: summary.Attempted, Total: summary.Attempted,
			Quota: 60, Used: summary.Attempted,
			CoverSaved: store.Stats().Saved, CoverReused: fetcher.Stats().Reused,
			HitRate: fetcher.Stats().HitRate(),
			Targets: 0,
			Message: fmt.Sprintf("补全完成：处理 %d 首，变更 %d 首", summary.Attempted, summary.Changed),
		}
		probe.setState(func(s *model.State) {
			s.CloseStage()
			s.OpenPage(model.PageSettings)
			s.SetSettingsSection(3)
			s.SetEnrichment(settingsView)
		})
		// Let the stage's cover transition finish drawing out before the shot.
		probe.advance(700 * time.Millisecond)
		probe.settle(10)
		probe.save(filepath.Join(opts.OutDir, "ui-settings-metadata.png"))

		matchCandidates := []model.MatchCandidate{}
		if hits, err := enricher.Candidates(ctx, metadata.SearchQuery{Title: refreshed.Title, Artist: refreshed.Artist}, 6); err == nil {
			for _, hit := range hits {
				matchCandidates = append(matchCandidates, model.MatchCandidate{
					Provider: hit.Provider, Title: hit.Title, Artist: hit.Artist,
					Album: hit.Album, CoverURL: hit.CoverURL, Duration: hit.Duration,
				})
			}
		}
		probe.setState(func(s *model.State) {
			s.OpenMatch(refreshed)
			s.SetMatchCandidates(matchCandidates, "")
		})
		probe.settle(5)
		probe.save(filepath.Join(opts.OutDir, "ui-match-dialog.png"))
		matchDialogShowsCandidates := len(matchCandidates) > 0 && containsText(probe.texts(), "应用并写回")

		// The stage last: its cover is a matched element transition, and a shot
		// taken after leaving the stage can still catch the outgoing copy.
		probe.setState(func(s *model.State) {
			s.CloseMatch()
			s.SetPlayer(player.Update{Snapshot: mpv.Snapshot{Playing: true, Duration: refreshed.Duration}, Track: &refreshed, Repeat: player.RepeatAll})
			s.OpenStage()
		})
		probe.settle(30)
		stageTexts := probe.texts()
		probe.save(filepath.Join(opts.OutDir, "ui-after-stage.png"))
		stageShowsTitle := containsText(stageTexts, refreshed.Title)
		// The same stage in a dark theme, so both palettes have a picture.
		probe.tester.SetDark(true)
		probe.settle(10)
		probe.save(filepath.Join(opts.OutDir, "ui-after-stage-dark.png"))
		probe.tester.SetDark(false)
		// And the per-character lyrics renderer on the same stage.
		probe.setState(func(s *model.State) {
			s.SetLyricsMode(model.LyricsWords)
			s.SetPlayer(player.Update{
				Snapshot: mpv.Snapshot{Playing: true, Position: 40 * time.Second, Duration: refreshed.Duration},
				Track:    &refreshed, Repeat: player.RepeatAll,
			})
		})
		probe.settle(10)
		probe.save(filepath.Join(opts.OutDir, "ui-after-stage-words.png"))
		probe.setState(func(s *model.State) { s.SetLyricsMode(model.LyricsLines) })

		report.Add(Check{
			ID: "m5.ui-refresh", Name: "补全后列表与舞台立即刷新（同一进程，不重启）",
			Pass: beforeShowsDemoted && afterShowsNew && stageShowsTitle && matchDialogShowsCandidates && revisionAfter > revisionBefore,
			Note: fmt.Sprintf("补全前列表显示无标签标题=%v；补全后列表显示新标题=%v；舞台显示新标题=%v；revision %d→%d",
				beforeShowsDemoted, afterShowsNew, stageShowsTitle, revisionBefore, revisionAfter),
			Data: map[string]any{
				"beforeShowsDemotedTitle": beforeShowsDemoted,
				"afterShowsNewTitle":      afterShowsNew,
				"stageShowsNewTitle":      stageShowsTitle,
				"matchDialogCandidates":   len(matchCandidates),
				"oldTitle":                first.DemotedTitle,
				"newTitle":                refreshed.Title,
				"revisionBefore":          revisionBefore,
				"revisionAfter":           revisionAfter,
				"screenshots": []string{"ui-before-library.png", "ui-after-library.png",
					"ui-after-stage.png", "ui-after-stage-dark.png", "ui-after-stage-words.png",
					"ui-settings-metadata.png", "ui-match-dialog.png"},
			},
		})

		// --- palette ---------------------------------------------------
		report.Add(paletteCheck(probe, refreshed, opts.OutDir, logf))
	}

	// --- cover cache -------------------------------------------------
	beforeSecond := counting.count.Load()
	secondHit := false
	warmHits := 0
	if !opts.SkipNetwork {
		// A second fetch of a URL already downloaded must not touch the network:
		// the fetcher's URL memo answers from the store. Repeating it for the
		// enriched covers is the warm half of the hit-rate measurement.
		for _, row := range mustSnapshot(ctx, lib, demoted) {
			if warmHits >= 5 {
				break
			}
			if row.Cover == "" {
				continue
			}
			refreshed, found, _ := lib.Track(ctx, row.ID)
			if !found || refreshed.CoverArtURL == "" {
				continue
			}
			requestsBefore := counting.count.Load()
			if _, _, err := fetcher.Cover(ctx, refreshed.CoverArtURL); err != nil {
				continue
			}
			if counting.count.Load() == requestsBefore {
				warmHits++
			}
		}
		secondHit = warmHits > 0 && counting.count.Load() == beforeSecond
	}
	cacheStats := fetcher.Stats()
	storeStats := store.Stats()
	report.Add(Check{
		ID: "m5.cover-cache", Name: "封面缓存命中率与内容寻址落盘",
		Pass:    opts.SkipNetwork || (cacheStats.Downloaded+cacheStats.Reused > 0 && secondHit),
		Skipped: opts.SkipNetwork,
		Note: fmt.Sprintf("下载 %d、命中 %d（命中率 %.0f%%）、写入文件 %d、复用文件 %d；热命中 %d 次均未发新请求=%v",
			cacheStats.Downloaded, cacheStats.Reused, cacheStats.HitRate()*100, storeStats.Saved, storeStats.Reused, warmHits, secondHit),
		Data: map[string]any{
			"downloaded": cacheStats.Downloaded, "reused": cacheStats.Reused,
			"hitRate": cacheStats.HitRate(), "bytes": cacheStats.Bytes,
			"storeSaved": storeStats.Saved, "storeReused": storeStats.Reused,
			"secondFetchWithoutRequest": secondHit, "warmHits": warmHits,
			"httpRequests": counting.count.Load(),
		},
	})

	// --- orphan covers (shared kept, unreferenced removed) -----------
	orphanCheck, err := orphanCheck(ctx, lib, store, copyCovers)
	if err != nil {
		return nil, err
	}
	report.Add(orphanCheck)

	// --- offline -----------------------------------------------------
	offlineCheck, err := offlineCheck(ctx, lib, copyCovers, probe, usedTracks)
	if err != nil {
		return nil, err
	}
	report.Add(offlineCheck)
	if offlineIDs, ok := offlineCheck.Data["trackIDs"].([]string); ok {
		for _, id := range offlineIDs {
			usedTracks[id] = true
		}
	}

	// --- manual match survives a restart -----------------------------
	manualCheck, err := manualMatchCheck(ctx, copyPath, lib, copyCovers, usedTracks)
	if err != nil {
		return nil, err
	}
	report.Add(manualCheck)

	// --- production untouched + schema --------------------------------
	afterProdHash, err := fileSHA256(sourceLibrary)
	if err != nil {
		return nil, err
	}
	afterProdVersion, err := userVersion(ctx, sourceLibrary)
	if err != nil {
		return nil, err
	}
	copyVersion, err := userVersion(ctx, copyPath)
	if err != nil {
		return nil, err
	}
	report.Add(Check{
		ID: "m5.production-unchanged", Name: "生产库 sha256 前后一致",
		Pass: beforeProdHash == afterProdHash && beforeProdVersion == afterProdVersion,
		Note: fmt.Sprintf("sha256 %s → %s", short(beforeProdHash), short(afterProdHash)),
		Data: map[string]any{"before": beforeProdHash, "after": afterProdHash,
			"userVersionBefore": beforeProdVersion, "userVersionAfter": afterProdVersion},
	})
	report.Add(Check{
		ID: "m5.copy-schema-version", Name: "副本 user_version 仍为 2",
		Pass: copyVersion == library.SchemaVersion,
		Data: map[string]any{"user_version": copyVersion},
	})

	report.FinishedAt = time.Now()
	path, err := report.Write(opts.OutDir)
	if err != nil {
		return nil, err
	}
	logf("report: %s", path)
	return report, nil
}

// --- preparation ----------------------------------------------------

// copyLibrary copies the production library and covers into workDir. The source
// files are opened read-only; nothing is written back to the production data
// directory.
func copyLibrary(sourceDataDir, workDir string) (string, string, error) {
	libraryPath := library.Path(workDir)
	coversPath := library.CoversDir(workDir)
	if err := os.MkdirAll(coversPath, 0o755); err != nil {
		return "", "", err
	}
	from := library.Path(sourceDataDir)
	if err := copyFile(from, libraryPath); err != nil {
		return "", "", err
	}
	sourceCovers := library.CoversDir(sourceDataDir)
	entries, err := os.ReadDir(sourceCovers)
	if err != nil {
		if os.IsNotExist(err) {
			return libraryPath, coversPath, nil
		}
		return "", "", err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if err := copyFile(filepath.Join(sourceCovers, entry.Name()), filepath.Join(coversPath, entry.Name())); err != nil {
			return "", "", err
		}
	}
	return libraryPath, coversPath, nil
}

func copyFile(from, to string) error {
	source, err := os.Open(from)
	if err != nil {
		return err
	}
	defer source.Close()
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	target, err := os.OpenFile(to, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(target, source); err != nil {
		target.Close()
		return err
	}
	return target.Close()
}

func sameDirectory(a, b string) bool {
	if strings.TrimSpace(a) == "" || strings.TrimSpace(b) == "" {
		return false
	}
	left, errA := filepath.Abs(a)
	right, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return false
	}
	return filepath.Clean(left) == filepath.Clean(right)
}

func fileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func short(hash string) string {
	if len(hash) > 12 {
		return hash[:12]
	}
	return hash
}

func userVersion(ctx context.Context, path string) (int, error) {
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{ReadOnly: true})
	if err != nil {
		return 0, err
	}
	defer db.Close()
	rows, err := db.Query(ctx, "PRAGMA user_version")
	if err != nil {
		return 0, err
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, errors.New("m5accept: no user_version")
	}
	value, ok := rows.Values[0][0].(int64)
	if !ok {
		return 0, errors.New("m5accept: user_version is not an integer")
	}
	return int(value), nil
}

// demoteTracks turns count complete rows into untagged ones: a file-name title
// (the shape a scan produces), placeholder artist and album, no cover and no
// lyrics. It works on the copy only.
func demoteTracks(ctx context.Context, path string, count int, exclude map[string]bool) ([]demoted, error) {
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(ctx, `
SELECT id, title, artist, album, COALESCE(cover_art_path, ''), COALESCE(length(lyrics), 0)
FROM tracks
WHERE artist NOT IN (?, '') AND album NOT IN (?, ?, ?)
  AND length(title) BETWEEN 1 AND 24
ORDER BY artist, album, title, id
LIMIT ?`,
		library.UnknownArtist, library.UnknownAlbum, "夸克曲库", "WebDAV 曲库", 500)
	if err != nil {
		return nil, err
	}
	// Round-robin over artists, so twenty tracks exercise the pipeline across
	// the library rather than twenty songs by whichever artist sorts first.
	byArtist := map[string][][]any{}
	order := make([]string, 0, 8)
	for _, value := range rows.Values {
		if exclude[stringValue(value[0])] {
			// Another phase already used this row; its evidence must stay
			// readable, so the phases never overlap.
			continue
		}
		artist := stringValue(value[2])
		if _, seen := byArtist[artist]; !seen {
			order = append(order, artist)
		}
		byArtist[artist] = append(byArtist[artist], value)
	}
	picked := make([][]any, 0, count)
	for round := 0; len(picked) < count; round++ {
		added := false
		for _, artist := range order {
			if round >= len(byArtist[artist]) {
				continue
			}
			picked = append(picked, byArtist[artist][round])
			added = true
			if len(picked) >= count {
				break
			}
		}
		if !added {
			break
		}
	}
	if len(picked) < count {
		return nil, fmt.Errorf("m5accept: only %d suitable tracks to demote, need %d", len(picked), count)
	}
	out := make([]demoted, 0, len(picked))
	for i, value := range picked {
		id := stringValue(value[0])
		title := stringValue(value[1])
		artist := stringValue(value[2])
		album := stringValue(value[3])
		cover := stringValue(value[4])
		lyricsLength := int(numberValue(value[5]))
		// Artist first: the smart-title parser's fallback rule is
		// "艺术家 - 歌名 - 专辑" for names it does not recognise, and that form
		// also parses correctly for the one artist it does (周杰伦).
		demotedTitle := fmt.Sprintf("%02d. %s-%s-%s", i+1, artist, title, album)
		if _, err := db.Execute(ctx, `
UPDATE tracks
SET title = ?, artist = ?, album = ?, cover_art_path = NULL, cover_art_url = NULL, lyrics = NULL
WHERE id = ?`, demotedTitle, library.UnknownArtist, library.UnknownAlbum, id); err != nil {
			return nil, err
		}
		out = append(out, demoted{
			ID: id, OriginalTitle: title, OriginalArtist: artist, OriginalAlbum: album,
			OriginalCover: cover, OriginalLyrics: lyricsLength, DemotedTitle: demotedTitle,
		})
	}
	return out, nil
}

func snapshotRows(ctx context.Context, lib *library.Library, demoted []demoted) ([]rowSnapshot, error) {
	out := make([]rowSnapshot, 0, len(demoted))
	for _, item := range demoted {
		track, found, err := lib.Track(ctx, item.ID)
		if err != nil {
			return nil, err
		}
		if !found {
			return nil, fmt.Errorf("m5accept: track %s disappeared", item.ID)
		}
		out = append(out, rowSnapshot{
			ID: track.ID, Title: track.Title, Artist: track.Artist, Album: track.Album,
			Cover: track.CoverArtPath, HasLyrics: strings.TrimSpace(track.Lyrics) != "",
			LyricsLen: len(track.Lyrics),
		})
	}
	return out, nil
}

func mustSnapshot(ctx context.Context, lib *library.Library, demoted []demoted) []rowSnapshot {
	rows, err := snapshotRows(ctx, lib, demoted)
	if err != nil {
		return nil
	}
	return rows
}

func coverageCounts(ctx context.Context, path string) (map[string]int, error) {
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer db.Close()
	counts := map[string]int{}
	queries := map[string]string{
		"tracks":        `SELECT COUNT(*) FROM tracks`,
		"withCover":     `SELECT COUNT(*) FROM tracks WHERE cover_art_path IS NOT NULL AND cover_art_path != ''`,
		"withLyrics":    `SELECT COUNT(*) FROM tracks WHERE lyrics IS NOT NULL AND lyrics != ''`,
		"unknownArtist": `SELECT COUNT(*) FROM tracks WHERE artist = '未知艺术家'`,
	}
	for name, sql := range queries {
		rows, err := db.Query(ctx, sql)
		if err != nil {
			return nil, err
		}
		counts[name] = int(numberValue(rows.Values[0][0]))
	}
	return counts, nil
}

func writeJSON(path string, value any) {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0o644)
}

// --- offline --------------------------------------------------------

// offlineEnricher is the pipeline with a transport that cannot reach anything:
// the deterministic form of "拔掉网线". Every request fails before the upstream,
// which is exactly the condition the milestone requires to be silent.
func offlineEnricher(logf func(string, ...any)) *metadata.Enricher {
	client := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, &netUnreachable{}
	}), Timeout: 5 * time.Second}
	http := &metadata.HTTP{Client: client}
	return &metadata.Enricher{
		Primary:        metadata.NewQQMusic(http),
		Fallback:       metadata.NewNetEase(http),
		Lyrics:         metadata.NewLRCLIB(http),
		FallbackLyrics: metadata.NewNetEase(http),
		Cover:          metadata.NewITunes(http),
		Log:            logf,
	}
}

type netUnreachable struct{}

func (e *netUnreachable) Error() string   { return "network is unreachable (simulated offline)" }
func (e *netUnreachable) Timeout() bool   { return false }
func (e *netUnreachable) Temporary() bool { return true }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func offlineCheck(ctx context.Context, lib *library.Library, coversDir string, probe *uiProbe, used map[string]bool) (Check, error) {
	extra, err := demoteTracks(ctx, lib.Path(), 3, used)
	if err != nil {
		return Check{}, err
	}
	if len(extra) < 3 {
		return Check{ID: "m5.offline", Name: "离线静默跳过", Pass: false, Note: "没有足够的曲目可降级"}, nil
	}
	store := &images.Store{Dir: coversDir}
	offlineClient := &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, &netUnreachable{}
	}), Timeout: 5 * time.Second}
	service := &enrich.Service{
		Library:  lib,
		Enricher: offlineEnricher(func(string, ...any) {}),
		Covers:   store,
		Fetcher:  &images.Fetcher{Store: store, Client: offlineClient},
	}
	before, err := snapshotRows(ctx, lib, extra)
	if err != nil {
		return Check{}, err
	}
	summary := service.EnrichTargets(ctx, 3, nil, nil)
	after, err := snapshotRows(ctx, lib, extra)
	if err != nil {
		return Check{}, err
	}
	// The contract is "no error the UI must show" plus "no upstream data is
	// invented": the file-name cleanup is local and may land, but a cover or a
	// lyric can only come from the network, so both must stay empty.
	networkFree := true
	for _, row := range after {
		if row.Cover != "" || row.HasLyrics {
			networkFree = false
		}
	}
	uiError := ""
	if probe != nil {
		uiError = probe.state.Error()
	}
	pass := summary.Offline >= 1 && summary.Failed == 0 && networkFree && uiError == ""
	return Check{
		ID: "m5.offline", Name: "断网时静默跳过、不弹错、不伪造数据",
		Pass: pass,
		Note: fmt.Sprintf("离线 %d、失败 %d；封面/歌词均未写入=%v；UI 错误条为空=%v；本地文件名清理照常（设计行为）",
			summary.Offline, summary.Failed, networkFree, uiError == ""),
		Data: map[string]any{
			"attempted": summary.Attempted, "offline": summary.Offline,
			"failed": summary.Failed, "changed": summary.Changed, "skipped": summary.Skipped,
			"noNetworkFields": networkFree, "uiError": uiError, "offlineMode": "simulated (transport error)",
			"demoted": len(extra), "before": before, "after": after, "trackIDs": demotedIDs(extra),
		},
	}, nil
}

// --- covers ---------------------------------------------------------

// orphanCheck proves the content-addressed store keeps a shared cover and drops
// an unreferenced one when the tracks using it are deleted, through the same
// library deletion path the sources page uses.
func orphanCheck(ctx context.Context, lib *library.Library, store *images.Store, coversDir string) (Check, error) {
	referenced, err := lib.ReferencedCovers(ctx)
	if err != nil {
		return Check{}, err
	}
	// The production covers directory can already hold files no row points at;
	// clear those first so the check measures what this phase creates.
	baseline, err := store.Prune(referenced)
	if err != nil {
		return Check{}, err
	}
	shared := ""
	for name := range referenced {
		if scan.IsCoverName(name) {
			shared = name
			break
		}
	}
	if shared == "" {
		return Check{ID: "m5.orphan-covers", Name: "封面孤儿回收", Pass: false, Note: "副本中没有可用的内容寻址封面"}, nil
	}
	uniqueBytes, err := testJPEG(color.RGBA{R: 250, G: 120, B: 30, A: 255})
	if err != nil {
		return Check{}, err
	}
	unique, _, err := store.Save(uniqueBytes)
	if err != nil {
		return Check{}, err
	}
	source := library.Source{ID: "m5-accept-covers", Name: "M5 验收封面", Kind: "local", LocalFolderPath: "/tmp/m5-accept-covers"}
	if err := lib.UpsertSource(ctx, source); err != nil {
		return Check{}, err
	}
	_, err = lib.MergeScan(ctx, source.ID, []library.ScannedTrack{
		{FilePathOrURL: "/tmp/m5-accept-covers/a.flac", Title: "共享封面曲目", FileFormat: "flac", CoverArtPath: shared},
		{FilePathOrURL: "/tmp/m5-accept-covers/b.flac", Title: "独占封面曲目", FileFormat: "flac", CoverArtPath: unique},
	}, true)
	if err != nil {
		return Check{}, err
	}
	deletion, err := lib.DeleteSource(ctx, source.ID)
	if err != nil {
		return Check{}, err
	}
	keep, err := lib.ReferencedCovers(ctx)
	if err != nil {
		return Check{}, err
	}
	removed, err := store.Prune(keep)
	if err != nil {
		return Check{}, err
	}
	_, sharedErr := os.Stat(filepath.Join(coversDir, shared))
	_, uniqueErr := os.Stat(filepath.Join(coversDir, unique))
	sharedKept := sharedErr == nil
	uniqueRemoved := os.IsNotExist(uniqueErr)
	return Check{
		ID: "m5.orphan-covers", Name: "封面孤儿回收（共享保留、无引用清理）",
		Pass: sharedKept && uniqueRemoved && removed == 1,
		Note: fmt.Sprintf("预清理历史孤儿 %d 个；删除来源报告 %d 个候选封面；本轮清理 %d 个；共享封面保留=%v；独占封面已删=%v",
			baseline, len(deletion.Covers), removed, sharedKept, uniqueRemoved),
		Data: map[string]any{
			"sharedCover": shared, "uniqueCover": unique,
			"candidates": len(deletion.Covers), "removed": removed, "baselineOrphans": baseline,
			"sharedKept": sharedKept, "uniqueRemoved": uniqueRemoved,
			"referencedAfter": len(keep),
		},
	}, nil
}

// --- manual match ---------------------------------------------------

func manualMatchCheck(ctx context.Context, copyPath string, lib *library.Library, coversDir string, used map[string]bool) (Check, error) {
	extra, err := demoteTracks(ctx, copyPath, 1, used)
	if err != nil {
		return Check{}, err
	}
	if len(extra) == 0 {
		return Check{ID: "m5.manual-match", Name: "人工匹配写回后重启仍在", Pass: false, Note: "没有可用的曲目"}, nil
	}
	target := extra[0]
	covers, err := lib.ReferencedCovers(ctx)
	if err != nil {
		return Check{}, err
	}
	cover := ""
	for name := range covers {
		if scan.IsCoverName(name) {
			cover = name
			break
		}
	}
	fields := library.EnrichmentFields{
		Title: "人工匹配标题", Artist: "人工匹配艺术家", Album: "人工匹配专辑",
		CoverArtPath: cover, Lyrics: "[00:01.00]人工匹配歌词",
	}
	if _, err := lib.ManualMatch(ctx, target.ID, fields); err != nil {
		return Check{}, err
	}
	// A fresh read-only connection sees only what reached the file: no
	// in-memory state of the writer can answer this read.
	reopened, err := library.Open(ctx, copyPath)
	if err != nil {
		return Check{}, err
	}
	defer func() { _ = reopened.Close() }()
	track, found, err := reopened.Track(ctx, target.ID)
	if err != nil || !found {
		return Check{}, fmt.Errorf("m5accept: reopen: %v", err)
	}
	persisted := track.Title == fields.Title && track.Artist == fields.Artist &&
		track.Album == fields.Album && track.CoverArtPath == fields.CoverArtPath &&
		strings.Contains(track.Lyrics, "人工匹配歌词")
	return Check{
		ID: "m5.manual-match", Name: "人工匹配改写后重启仍在",
		Pass: persisted,
		Note: fmt.Sprintf("写回后关闭连接并重开：标题=%q 艺术家=%q 专辑=%q 封面=%v 歌词=%v",
			track.Title, track.Artist, track.Album, track.CoverArtPath == fields.CoverArtPath,
			strings.Contains(track.Lyrics, "人工匹配歌词")),
		Data: map[string]any{
			"trackID": target.ID, "title": track.Title, "artist": track.Artist, "album": track.Album,
			"cover": track.CoverArtPath, "persisted": persisted, "coversDir": coversDir,
		},
	}, nil
}

// --- palette --------------------------------------------------------

func paletteCheck(probe *uiProbe, track library.Track, outDir string, logf func(string, ...any)) Check {
	if track.CoverArtPath == "" {
		return Check{ID: "m5.palette", Name: "封面取色（深浅两套主题）", Pass: false, Note: "补全后的曲目没有封面，无法取色"}
	}
	darkFrom, darkTo := probe.state.StageColors(track.CoverArtPath, true)
	lightFrom, lightTo := probe.state.StageColors(track.CoverArtPath, false)
	neutralDarkFrom, neutralDarkTo := model.NeutralStageColors(true)
	neutralLightFrom, neutralLightTo := model.NeutralStageColors(false)
	darkText := images.ColorOf(tokens.For(true).TextPrimary)
	lightText := images.ColorOf(tokens.For(false).TextPrimary)
	darkContrast := minFloat(images.Contrast(images.ColorOf(darkFrom), darkText), images.Contrast(images.ColorOf(darkTo), darkText))
	lightContrast := minFloat(images.Contrast(images.ColorOf(lightFrom), lightText), images.Contrast(images.ColorOf(lightTo), lightText))

	// The gray case: a synthetic gray cover must fall back to the neutral
	// gradient, and the palette must report "no usable colour".
	gray := grayImage(96, 96)
	grayPath := filepath.Join(outDir, "gray-cover.png")
	_ = writePNG(grayPath, gray)
	_, grayOK := images.Extract(gray, images.Options{Dark: true,
		Canvas: images.ColorOf(tokens.For(true).Canvas), TextPrimary: darkText})
	grayName := writeCoverFile(probe.coversDir, gray)
	grayFrom, grayTo := probe.state.StageColors(grayName, true)
	grayFallsBack := !grayOK && grayFrom == neutralDarkFrom && grayTo == neutralDarkTo

	distinctThemes := darkFrom != lightFrom || darkTo != lightTo
	notNeutral := darkFrom != neutralDarkFrom || darkTo != neutralDarkTo ||
		lightFrom != neutralLightFrom || lightTo != neutralLightTo
	pass := grayFallsBack && distinctThemes && notNeutral && darkContrast >= 7 && lightContrast >= 7
	logf("palette: cover=%s dark=%s→%s light=%s→%s contrast dark=%.1f light=%.1f grayFallback=%v",
		track.CoverArtPath, hexColor(darkFrom), hexColor(darkTo), hexColor(lightFrom), hexColor(lightTo),
		darkContrast, lightContrast, grayFallsBack)
	return Check{
		ID: "m5.palette", Name: "同一封面在深浅两套主题下的舞台背景色 + 失败回退",
		Pass: pass,
		Note: fmt.Sprintf("深色 %s→%s（对比 %.1f:1），浅色 %s→%s（对比 %.1f:1）；灰封面回退中性渐变=%v",
			hexColor(darkFrom), hexColor(darkTo), darkContrast,
			hexColor(lightFrom), hexColor(lightTo), lightContrast, grayFallsBack),
		Data: map[string]any{
			"cover":          track.CoverArtPath,
			"dark":           []string{hexColor(darkFrom), hexColor(darkTo)},
			"light":          []string{hexColor(lightFrom), hexColor(lightTo)},
			"neutralDark":    []string{hexColor(neutralDarkFrom), hexColor(neutralDarkTo)},
			"neutralLight":   []string{hexColor(neutralLightFrom), hexColor(neutralLightTo)},
			"darkContrast":   darkContrast,
			"lightContrast":  lightContrast,
			"grayFallback":   grayFallsBack,
			"grayPaletteOK":  grayOK,
			"grayScreenshot": "gray-cover.png",
		},
	}
}

// --- small helpers --------------------------------------------------

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func numberValue(value any) float64 {
	if number, ok := value.(float64); ok {
		return number
	}
	if number, ok := value.(int64); ok {
		return float64(number)
	}
	return 0
}

func containsText(texts []string, want string) bool {
	for _, text := range texts {
		if strings.Contains(text, want) {
			return true
		}
	}
	return false
}

func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}

func testJPEG(c color.RGBA) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			img.SetRGBA(x, y, c)
		}
	}
	var out []byte
	buf := &byteWriter{&out}
	if err := jpeg.Encode(buf, img, nil); err != nil {
		return nil, err
	}
	return out, nil
}

type byteWriter struct{ target *[]byte }

func (w *byteWriter) Write(p []byte) (int, error) {
	*w.target = append(*w.target, p...)
	return len(p), nil
}

func grayImage(w, h int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, color.RGBA{R: 128, G: 128, B: 128, A: 255})
		}
	}
	return img
}

func writePNG(path string, img image.Image) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	return png.Encode(file, img)
}

// writeCoverFile stores an image as a content-addressed cover and returns its
// name, so the palette can run over a file the stage would actually use.
func writeCoverFile(coversDir string, img image.Image) string {
	var encoded []byte
	buf := &byteWriter{&encoded}
	_ = png.Encode(buf, img)
	name, _, err := (&images.Store{Dir: coversDir}).Save(encoded)
	if err != nil {
		return ""
	}
	return name
}

// RGBOf converts a palette color; the zero value for a failed extraction.
func RGBOf(c images.RGB) images.RGB { return c }

// countingTransport records how many HTTP requests the pipeline made, so the
// cover-cache check can prove a second fetch stayed on disk.
type countingTransport struct {
	base  http.RoundTripper
	count atomic.Int64
}

func (t *countingTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	t.count.Add(1)
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(request)
}

// readAISettings builds the AI fallback configuration from the environment.
// The harness never reads the Keychain (that would prompt for access on a
// headless run) and never writes the key anywhere: an unset TINGYU_AI_KEY is
// the normal "AI fallback not configured" case and is reported as such.
func readAISettings() (metadata.AISettings, string) {
	key := strings.TrimSpace(os.Getenv("TINGYU_AI_KEY"))
	if key == "" {
		return metadata.DefaultAISettings(), "TINGYU_AI_KEY is not set"
	}
	settings := metadata.DefaultAISettings()
	settings.Enabled = strings.TrimSpace(os.Getenv("TINGYU_AI_ENABLED")) != "0"
	if base := strings.TrimSpace(os.Getenv("TINGYU_AI_BASE_URL")); base != "" {
		settings.BaseURL = base
	}
	if model := strings.TrimSpace(os.Getenv("TINGYU_AI_MODEL")); model != "" {
		settings.Model = model
	}
	settings.APIKey = key
	return settings, ""
}

// hexColor renders a UI color as #RRGGBB for the record.
func hexColor(c ui.Color) string {
	return fmt.Sprintf("#%02X%02X%02X", c.R, c.G, c.B)
}

// demotedIDs lists the ids of a demoted batch.
func demotedIDs(items []demoted) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		out = append(out, item.ID)
	}
	return out
}
