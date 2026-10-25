package shell

import (
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// perfTracks builds a ten-thousand-row library with covers missing (a CPU-bound
// scroll should not wait on IO; the cover cache is exercised by the visual
// tests).
func perfTracks(n int) []library.Track {
	out := make([]library.Track, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, library.Track{
			ID:         fmt.Sprintf("perf-%05d", i),
			Title:      fmt.Sprintf("长列表曲目 %05d", i),
			Artist:     fmt.Sprintf("艺术家 %02d", i%37),
			Album:      fmt.Sprintf("专辑 %03d", i%211),
			Duration:   time.Duration(120+i%240) * time.Second,
			SourceID:   "src-local",
			IsFavorite: i%9 == 0,
		})
	}
	return out
}

// TestLibraryScrollP95At10000Rows is the plan §6 M4 performance gate: scrolling
// ten thousand rows keeps p95 frame time at or below 16.7 ms. It measures
// ui.Tester frames (build + layout + paint, CPU, no GPU) and logs every sample
// so the acceptance record can quote raw numbers.
func TestLibraryScrollP95At10000Rows(t *testing.T) {
	if raceEnabled {
		t.Skip("frame-time gate measured without -race: race instrumentation dominates each frame")
	}
	const rows = 10000
	m := newModel(perfTracks(rows))
	s := m.State()
	s.Tick(time.Now())
	for !s.Library().Done() {
		s.Library().RequestMore()
		s.Tick(time.Now())
	}
	if s.Library().Loaded() != rows {
		t.Fatalf("loaded %d of %d rows", s.Library().Loaded(), rows)
	}
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if first, last := s.Library().Table().Visible(); first < 0 || last < 0 {
		t.Fatalf("table shows no rows: %d..%d", first, last)
	}
	// Warm up layout caches (text shaping, column widths).
	for range 10 {
		tt.Scroll(700, 340, 0, 1200)
	}
	// 400 steps × 1200 DIPs cover the whole 10,000-row list (rows are 44
	// DIPs high); the samples therefore include the far end of the list, not
	// only its first screenfuls.
	samples := make([]time.Duration, 0, 400)
	for range 400 {
		start := time.Now()
		tt.Scroll(700, 340, 0, 1200)
		samples = append(samples, time.Since(start))
	}
	if len(samples) == 0 {
		t.Fatal("no scroll samples")
	}
	if first, _ := s.Library().Table().Visible(); first < rows-100 {
		t.Fatalf("the scroll stopped early: first visible row %d of %d", first, rows)
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	percentile := func(p float64) time.Duration {
		index := int(float64(len(samples)-1) * p)
		return samples[index]
	}
	p50, p95, p99, max := percentile(0.50), percentile(0.95), percentile(0.99), samples[len(samples)-1]
	t.Logf("scroll_p95 rows=%d samples=%d p50=%v p95=%v p99=%v max=%v", rows, len(samples), p50, p95, p99, max)
	t.Logf("samples_ms=%v", millis(samples))
	if p95 > 16700*time.Microsecond {
		t.Fatalf("p95 %v exceeds 16.7 ms", p95)
	}
}

func millis(samples []time.Duration) []float64 {
	out := make([]float64, 0, len(samples))
	for _, sample := range samples {
		out = append(out, float64(sample.Microseconds())/1000)
	}
	return out
}
