// Command scrubprobe measures what dragging the progress bar costs a remote
// source, before and after the seek-on-release fix (research report §3.2).
//
// It plays one track from the local Range server the M2 acceptance harness
// uses, drags the progress slider the way a pointer does, and counts the HTTP
// Range requests the seek policy produces:
//
//	-policy=view    drives the production view (internal/shell + ui.Tester):
//	                the release is the only seek.
//	-policy=legacy  reproduces the two lines the fix removed (one Seek per
//	                slider Changed frame) against the same engine, source and
//	                drag trajectory.
//
// It is a development tool. Build and run it with scripts/run-scrub-probe.sh,
// which gives the binary the LC_RPATH libmpv's frameworks need.
package main

import (
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/rangesrv"
	"github.com/halunhaku/tingyu/client/internal/shell"
)

const (
	sourceUser = "tingyu"
	sourcePass = "m2-acceptance"
)

type result struct {
	Policy            string  `json:"policy"`
	Steps             int     `json:"steps"`
	DurationSeconds   float64 `json:"durationSeconds"`
	TargetSeconds     float64 `json:"targetSeconds"`
	PositionAfter     float64 `json:"positionAfterSeconds"`
	RangeRequests     int     `json:"rangeRequests"`
	DragRangeRequests int     `json:"dragRangeRequests"`
	BaselinePerSecond float64 `json:"baselineRangePerSecond"`
	SeekToSoundMs     int64   `json:"seekToSoundMs"`
	Seeks             int     `json:"seeks"`
}

// probeActions is the shell's Actions wired to the real controller.
type probeActions struct {
	control *player.Controller
	seeks   int
}

func (p *probeActions) PlayTracks(tracks []library.Track, start int) error {
	return p.control.PlayTracks(tracks, start)
}
func (p *probeActions) TogglePlayPause() error { return p.control.TogglePlayPause() }
func (p *probeActions) Next() error            { return p.control.Next() }
func (p *probeActions) Previous() error        { return p.control.Previous() }
func (p *probeActions) Seek(position time.Duration) error {
	p.seeks++
	return p.control.Seek(position)
}
func (p *probeActions) SetVolume(volume float64) error     { return p.control.SetVolume(volume) }
func (p *probeActions) CycleRepeat() player.RepeatMode     { return p.control.CycleRepeat() }
func (p *probeActions) ChooseDirectory()                   {}
func (p *probeActions) SyncSource(source library.Source)   {}
func (p *probeActions) SyncAllSources()                    {}
func (p *probeActions) RevealInFinder(track library.Track) {}
func (p *probeActions) Queue() []library.Track             { return p.control.Queue() }

func main() {
	mediaDir := flag.String("media", filepath.Join("build", "scrub-media"), "media root served over Range")
	trackPath := flag.String("track", filepath.Join("remote", "long.flac"), "track inside -media to drag through")
	policy := flag.String("policy", "view", "view (production slider) or legacy (one seek per changed frame)")
	steps := flag.Int("steps", 30, "drag frames")
	gap := flag.Duration("gap", 40*time.Millisecond, "time between drag frames, as frames of a real drag run")
	mpvPath := flag.String("mpv", "", "libmpv path (default: MPV_LIB, app bundle, then the pub cache)")
	out := flag.String("out", "", "write the JSON result here instead of stdout")
	flag.Parse()

	if *policy != "view" && *policy != "legacy" {
		fail("-policy must be view or legacy")
	}
	libraryPath := *mpvPath
	if libraryPath == "" {
		libraryPath = mpv.LibraryPath()
	}
	if libraryPath == "" {
		fail("no libmpv found; set MPV_LIB or build the app bundle first")
	}
	if _, err := os.Stat(filepath.Join(*mediaDir, *trackPath)); err != nil {
		fail("missing test media %s (run scripts/run-scrub-probe.sh, which generates it)", filepath.Join(*mediaDir, *trackPath))
	}

	server, err := rangesrv.New(rangesrv.Options{
		Root:         *mediaDir,
		User:         sourceUser,
		Password:     sourcePass,
		RequireRange: true,
	})
	if err != nil {
		fail("range server: %v", err)
	}
	if _, err := server.Start(); err != nil {
		fail("range server: %v", err)
	}
	defer server.Close()

	uri := server.URL(*trackPath)
	authorization := "Basic " + base64.StdEncoding.EncodeToString([]byte(sourceUser+":"+sourcePass))
	lib, err := mpv.Load(libraryPath)
	if err != nil {
		fail("libmpv: %v", err)
	}
	// A small demuxer cache makes each seek cross an uncached region, so the
	// source really sees the Range requests a remote link would.
	engine, err := mpv.NewPlayer(lib, mpv.Config{
		AudioClientName: "听屿ScrubProbe",
		Options: map[string]string{
			"cache":                  "yes",
			"demuxer-max-bytes":      "1048576",
			"demuxer-readahead-secs": "1",
		},
	})
	if err != nil {
		fail("engine: %v", err)
	}
	control := player.New(engine, func(track library.Track) (player.Item, error) {
		return player.Item{
			ID: track.ID, TrackID: track.ID, URI: track.FilePath,
			Headers: map[string]string{"Authorization": authorization},
			Title:   track.Title, Artist: track.Artist, Album: track.Album,
			Duration: track.Duration,
		}, nil
	}, nil)
	defer func() { _ = control.Close() }()

	var (
		mu     sync.Mutex
		latest = player.Update{}
	)
	control.SetListener(func(update player.Update) {
		mu.Lock()
		latest = update
		mu.Unlock()
	})
	snapshot := func() player.Update {
		mu.Lock()
		defer mu.Unlock()
		return latest
	}

	track := library.Track{ID: "probe", Title: "探针 测试曲", FilePath: uri, Artist: "测试歌手", Album: "测试专辑"}
	actions := &probeActions{control: control}
	model := shell.New([]library.Track{track}, "", nil)
	model.SetActions(actions)
	model.State().FinishOnboarding()
	apply := func() {
		update := snapshot()
		if update.Track != nil {
			model.SetPlayer(update)
			if len(model.State().Queue()) == 0 {
				model.SetQueue([]library.Track{*update.Track}, update.Index)
			}
		}
	}
	tester := ui.NewTester(model.View, shell.DefaultWidth, shell.DefaultHeight)

	// Start playback and wait for audio.
	if err := control.PlayTracks([]library.Track{track}, 0); err != nil {
		fail("play: %v", err)
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		apply()
		tester.Frame()
		update := snapshot()
		if update.Snapshot.Playing && update.Snapshot.Position >= 2*time.Second {
			break
		}
		if time.Now().After(deadline) {
			fail("no audio after 20s (position %v, playing %v, failure %+v)",
				update.Snapshot.Position, update.Snapshot.Playing, update.Failure)
		}
		time.Sleep(10 * time.Millisecond)
	}
	duration := snapshot().Snapshot.Duration
	if duration <= 0 {
		fail("the engine reported no duration")
	}
	// Let the initial streaming settle, then take the baseline the drag is
	// measured against.
	time.Sleep(time.Second)
	before := rangeRequests(server)
	baselineStart := time.Now()
	time.Sleep(time.Second)
	baseline := float64(rangeRequests(server)-before) / time.Since(baselineStart).Seconds()

	target := time.Duration(float64(duration) * 0.7)
	var seen []int
	if *policy == "view" {
		apply()
		tester.Frame()
		rect, ok := tester.Find("播放进度")
		if !ok {
			fail("progress slider not found; texts are %q", tester.Texts())
		}
		y := rect.Y + rect.H/2
		startX := rect.X + rect.W*0.1
		endX := rect.X + rect.W*0.7
		tester.Press(startX, y)
		for step := 1; step <= *steps; step++ {
			x := startX + (endX-startX)*float32(step)/float32(*steps)
			tester.Move(x, y)
			apply()
			tester.Frame()
			// A human drag runs at frame rate; pace the steps so mpv's
			// asynchronous seeks are not collapsed into one.
			time.Sleep(*gap)
			seen = append(seen, actions.seeks)
		}
		if actions.seeks != 0 {
			fail("the drag seeked before release (%d seeks)", actions.seeks)
		}
		tester.Release(endX, y)
		apply()
		tester.Frame()
		if actions.seeks != 1 {
			fail("release produced %d seeks, want 1", actions.seeks)
		}
	} else {
		// The removed lines: every changed frame seeked.
		for step := 1; step <= *steps; step++ {
			value := 0.1 + 0.6*float64(step)/float64(*steps)
			_ = actions.Seek(time.Duration(value * float64(duration)))
			seen = append(seen, actions.seeks)
			apply()
			time.Sleep(*gap)
		}
	}
	duringDrag := rangeRequests(server) - before

	// Release to audio: wait until the reported position reaches the target
	// (within half a second), as the M2 acceptance harness does.
	start := time.Now()
	reached := false
	for time.Now().Sub(start) < 10*time.Second {
		apply()
		update := snapshot()
		if update.Snapshot.Playing && update.Snapshot.Position >= target-500*time.Millisecond {
			reached = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	elapsed := time.Since(start)
	time.Sleep(300 * time.Millisecond)
	total := rangeRequests(server) - before
	position := snapshot().Snapshot.Position

	report := result{
		Policy:            *policy,
		Steps:             *steps,
		DurationSeconds:   duration.Seconds(),
		TargetSeconds:     target.Seconds(),
		PositionAfter:     position.Seconds(),
		RangeRequests:     total,
		DragRangeRequests: duringDrag,
		BaselinePerSecond: baseline,
		SeekToSoundMs:     elapsed.Milliseconds(),
		Seeks:             actions.seeks,
	}
	if !reached {
		fmt.Fprintf(os.Stderr, "scrubprobe: position did not reach %v within 10s (now %v)\n", target, position)
	}
	encoded, _ := json.MarshalIndent(report, "", "  ")
	encoded = append(encoded, '\n')
	if *out != "" {
		if err := os.WriteFile(*out, encoded, 0o644); err != nil {
			fail("write %s: %v", *out, err)
		}
	}
	if os.Getenv("SCRUBPROBE_DUMP") != "" {
		for _, record := range server.Records() {
			fmt.Fprintf(os.Stderr, "REQ %s %s range=%q status=%d at=%s\n", record.Method, record.Path, record.Range, record.Status, record.At.Format("15:04:05.000"))
		}
	}
	fmt.Printf("policy=%s steps=%d dragRange=%d totalRange=%d baselineRangePerSecond=%.1f seekToSoundMs=%d seeks=%d target=%.2fs position=%.2fs\n",
		report.Policy, report.Steps, duringDrag, report.RangeRequests, report.BaselinePerSecond,
		report.SeekToSoundMs, report.Seeks, report.TargetSeconds, report.PositionAfter)
	if duringDrag > 0 {
		fmt.Printf("dragRangePerStep=%.2f\n", float64(duringDrag)/float64(report.Steps))
	}
	if *out != "" {
		fmt.Println("result:", *out)
	} else {
		fmt.Print(string(encoded))
	}
}

func rangeRequests(server *rangesrv.Server) int {
	count := 0
	for _, record := range server.Records() {
		if record.Range != "" {
			count++
		}
	}
	return count
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "scrubprobe: "+format+"\n", args...)
	os.Exit(2)
}
