package m5accept

// The UI side of the acceptance: the real shell rendered headlessly by
// ui.Tester, before and after the enrichment pass. The same shell.Model stays
// alive across the pass — no relaunch — which is what proves the "立即刷新"
// requirement rather than merely re-opening the database.

import (
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/shell"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

type uiProbe struct {
	model     *shell.Model
	state     *model.State
	tester    *ui.Tester
	coversDir string
}

func newUIProbe(lib *library.Library, libraryPath, coversDir string) (*uiProbe, error) {
	model := shell.New(lib.Queries(), lib, libraryPath, nil)
	model.SetCoversDir(coversDir)
	model.SetAISettings(metadata.DefaultAISettings(), "")
	// The settings panel draws its "pipeline available" state only when an app
	// half is installed; the harness's is inert because nothing clicks in these
	// screenshots.
	model.SetMetadataActions(stubMetadataActions{})
	probe := &uiProbe{
		model:     model,
		state:     model.State(),
		tester:    ui.NewTester(model.View, shell.DefaultWidth, shell.DefaultHeight),
		coversDir: coversDir,
	}
	probe.settle(10)
	return probe, nil
}

// settle renders frames until every paged list holds its rows, with a cap so a
// broken page fails the check instead of hanging.
func (p *uiProbe) settle(maxFrames int) {
	for i := 0; i < maxFrames; i++ {
		p.tester.Frame()
		if i > 2 && p.state.Settled() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// setQuery filters the library list, the way a search narrows it.
func (p *uiProbe) setQuery(query string) {
	clean := strings.NewReplacer("%", "", "_", "").Replace(query)
	p.state.Library().SetQuery(clean)
	p.state.Invalidate()
}

// setState mutates the view state on the UI thread (the tester is single
// threaded, exactly like a window callback).
func (p *uiProbe) setState(fn func(*model.State)) { fn(p.state) }

// advance moves the tester's clock and renders, so an element transition (the
// stage's cover, a page switch) finishes before a screenshot.
func (p *uiProbe) advance(d time.Duration) {
	p.tester.Advance(d)
	p.tester.Frame()
	p.tester.Frame()
}

func (p *uiProbe) texts() []string { return p.tester.Texts() }

// save writes the rendered frame as a PNG, the visual evidence.
func (p *uiProbe) save(path string) {
	img := p.tester.Image()
	if img == nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	file, err := os.Create(path)
	if err != nil {
		return
	}
	defer file.Close()
	_ = png.Encode(file, img)
}

// rowsSummary is a compact quote of what the table holds, for the report.
func (p *uiProbe) rowsSummary() []string {
	items := p.state.Library().Items()
	out := make([]string, 0, len(items))
	for _, track := range items {
		out = append(out, fmt.Sprintf("%s — %s", track.Title, track.Artist))
	}
	return out
}

// stubMetadataActions is the inert app half the screenshots need.
type stubMetadataActions struct{}

func (stubMetadataActions) EnrichAll()                        {}
func (stubMetadataActions) CancelEnrichment()                 {}
func (stubMetadataActions) EnrichTrack(library.Track)         {}
func (stubMetadataActions) LoadMatchCandidates(library.Track) {}
func (stubMetadataActions) ApplyManualMatch(library.Track, string, string, string, string) {
}
func (stubMetadataActions) SaveAISettings(metadata.AISettings) error { return nil }
func (stubMetadataActions) PruneCovers()                             {}
