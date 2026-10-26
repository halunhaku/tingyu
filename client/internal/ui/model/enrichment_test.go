package model

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
)

// fakeMetadata records the M5 callbacks the window asks for.
type fakeMetadata struct {
	passes     int
	cancels    int
	single     []library.Track
	matchLoads []library.Track
	manuals    []manualCall
	ai         []metadata.AISettings
	prunes     int
	saveErr    error
}

type manualCall struct {
	track                library.Track
	title, artist, album string
	cover                string
}

func (f *fakeMetadata) EnrichAll()                      { f.passes++ }
func (f *fakeMetadata) CancelEnrichment()               { f.cancels++ }
func (f *fakeMetadata) EnrichTrack(track library.Track) { f.single = append(f.single, track) }
func (f *fakeMetadata) LoadMatchCandidates(track library.Track) {
	f.matchLoads = append(f.matchLoads, track)
}
func (f *fakeMetadata) ApplyManualMatch(track library.Track, title, artist, album, coverURL string) {
	f.manuals = append(f.manuals, manualCall{track: track, title: title, artist: artist, album: album, cover: coverURL})
}
func (f *fakeMetadata) SaveAISettings(settings metadata.AISettings) error {
	f.ai = append(f.ai, settings)
	return f.saveErr
}
func (f *fakeMetadata) PruneCovers() { f.prunes++ }

func newMetadataState(actions *fakeMetadata) *State {
	s := New(nil, nil, "", nil)
	s.SetMetadataActions(actions)
	return s
}

func TestEnrichmentPanelReflectsThePass(t *testing.T) {
	actions := &fakeMetadata{}
	s := newMetadataState(actions)
	if !s.MetadataReady() {
		t.Fatal("metadata actions installed but MetadataReady is false")
	}
	s.BeginEnrichment()
	if actions.passes != 1 || !s.Enrichment().Running {
		t.Fatalf("passes=%d view=%+v", actions.passes, s.Enrichment())
	}
	view := s.Enrichment()
	view.Done = 7
	view.Total = 20
	view.Changed = 5
	view.Covers = 4
	view.Lyrics = 3
	s.SetEnrichment(view)
	if got := s.Enrichment(); got.Done != 7 || got.Changed != 5 {
		t.Fatalf("view %+v", got)
	}
	s.CancelEnrichment()
	if actions.cancels != 1 {
		t.Fatalf("cancels=%d", actions.cancels)
	}
	s.PruneCovers()
	if actions.prunes != 1 {
		t.Fatalf("prunes=%d", actions.prunes)
	}
	track := library.Track{ID: "t1", Title: "晴天"}
	s.EnrichOne(track)
	if len(actions.single) != 1 || actions.single[0].ID != "t1" {
		t.Fatalf("single %+v", actions.single)
	}
}

func TestEnrichmentWithoutActionsSaysSo(t *testing.T) {
	s := New(nil, nil, "", nil)
	s.BeginEnrichment()
	if s.MetadataReady() {
		t.Fatal("no actions but the build claims the pipeline")
	}
	if !strings.Contains(s.Notice(), "未接入") {
		t.Fatalf("notice %q", s.Notice())
	}
}

func TestMatchDialogCollectsCandidatesAndWritesBack(t *testing.T) {
	actions := &fakeMetadata{}
	s := newMetadataState(actions)
	track := library.Track{ID: "t1", Title: "01. 花海-周杰伦-魔杰座", Artist: library.UnknownArtist, Album: library.UnknownAlbum}
	s.OpenMatch(track)
	if !s.Match().Open || !s.Match().Loading || len(actions.matchLoads) != 1 {
		t.Fatalf("match %+v loads=%d", s.Match(), len(actions.matchLoads))
	}
	if s.Match().Title != track.Title {
		t.Fatalf("the dialog must start at the track's values: %+v", s.Match())
	}
	s.SetMatchCandidates([]MatchCandidate{
		{Provider: "qqmusic", Title: "花海", Artist: "周杰伦", Album: "魔杰座", CoverURL: "https://example.invalid/c.jpg"},
		{Provider: "netease", Title: "花海 (Live)", Artist: "周杰伦", Album: "演唱会"},
	}, "")
	if s.Match().Loading || len(s.Match().Candidates) != 2 {
		t.Fatalf("match %+v", s.Match())
	}
	s.UseMatchCandidate(0)
	if s.Match().Title != "花海" || s.Match().Artist != "周杰伦" || s.Match().Selected != 0 {
		t.Fatalf("candidate not applied: %+v", s.Match())
	}
	// The user edits the album by hand after picking a candidate.
	s.Match().Album = "魔杰座 (2010 重制)"
	s.ApplyMatch()
	if len(actions.manuals) != 1 {
		t.Fatalf("manuals %+v", actions.manuals)
	}
	call := actions.manuals[0]
	if call.title != "花海" || call.artist != "周杰伦" || call.album != "魔杰座 (2010 重制)" {
		t.Fatalf("manual call %+v", call)
	}
	if call.cover != "https://example.invalid/c.jpg" {
		t.Fatalf("cover %q", call.cover)
	}
	if !s.Match().Busy {
		t.Fatal("the dialog must show the write in flight")
	}
	s.MatchApplied("已写回")
	if s.Match().Open || !strings.Contains(s.Notice(), "已写回") {
		t.Fatalf("after apply: %+v notice=%q", s.Match(), s.Notice())
	}
}

func TestMatchFailureStaysInTheDialog(t *testing.T) {
	s := newMetadataState(&fakeMetadata{})
	s.OpenMatch(library.Track{ID: "t1", Title: "晴天"})
	s.SetMatchCandidates(nil, "搜索失败：网络不可用")
	if s.Match().Error == "" {
		t.Fatal("the search error must be visible")
	}
	s.ApplyMatch()
	s.MatchFailed("写回失败：只读模式")
	if s.Match().Open != true || !strings.Contains(s.Match().Error, "只读") {
		t.Fatalf("match %+v", s.Match())
	}
	if s.Match().Busy {
		t.Fatal("a failed write must leave the dialog usable")
	}
}

func TestSaveAISettingsReportsTheAppAnswer(t *testing.T) {
	actions := &fakeMetadata{}
	s := newMetadataState(actions)
	next := metadata.AISettings{Enabled: true, Preset: "kimi", BaseURL: "https://api.moonshot.cn/v1", Model: "moonshot-v1-8k", APIKey: "test-key"}
	s.SaveAISettings(next)
	if len(actions.ai) != 1 || !s.AI().Enabled {
		t.Fatalf("ai %+v", actions.ai)
	}
	actions.saveErr = context.DeadlineExceeded
	s.SaveAISettings(next)
	if !strings.Contains(s.AIError(), "保存 AI 配置失败") {
		t.Fatalf("ai error %q", s.AIError())
	}
}

func TestAIPresetCycle(t *testing.T) {
	first := metadata.AIPresets[0]
	if got := AIPreset("nope"); got.Name != first.Name {
		t.Fatalf("unknown preset returned %+v", got)
	}
	if got := NextAIPreset(first.Name); got.Name == first.Name {
		t.Fatalf("cycle stayed on %s", first.Name)
	}
	if got := NextAIPreset(metadata.AIPresets[len(metadata.AIPresets)-1].Name); got.Name != first.Name {
		t.Fatalf("the cycle does not wrap: %+v", got)
	}
}

// writeCover writes a JPEG cover into dir and returns its name.
func writeCover(t *testing.T, dir string, paint func(x, y int) color.RGBA) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 48, 48))
	for y := 0; y < 48; y++ {
		for x := 0; x < 48; x++ {
			img.SetRGBA(x, y, paint(x, y))
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatal(err)
	}
	// The name only has to be a file in the covers directory; the palette
	// cache keys on the name and stat.
	name := "test-cover.jpg"
	if err := os.WriteFile(filepath.Join(dir, name), buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return name
}

func TestStageColorsComeFromTheCoverPerTheme(t *testing.T) {
	dir := t.TempDir()
	name := writeCover(t, dir, func(x, _ int) color.RGBA {
		if x < 24 {
			return color.RGBA{R: 30, G: 120, B: 70, A: 255}
		}
		return color.RGBA{R: 210, G: 160, B: 40, A: 255}
	})
	s := New(nil, nil, "", nil)
	s.SetCoversDir(dir)

	darkFrom, darkTo := s.StageColors(name, true)
	lightFrom, lightTo := s.StageColors(name, false)
	neutralFrom, neutralTo := NeutralStageColors(true)
	if darkFrom == neutralFrom && darkTo == neutralTo {
		t.Fatalf("dark stage used the neutral gradient %v→%v", darkFrom, darkTo)
	}
	if darkFrom == lightFrom && darkTo == lightTo {
		t.Fatalf("both themes produced %v→%v: the per-theme clamps did not apply", darkFrom, darkTo)
	}
	t.Logf("stage colors dark=%v→%v light=%v→%v", darkFrom, darkTo, lightFrom, lightTo)

	// The cache answers the same colours on the second call.
	if again, _ := s.StageColors(name, true); again != darkFrom {
		t.Fatalf("cache changed the colour: %v then %v", darkFrom, again)
	}
}

func TestStageColorsFallBackForAGrayCoverAndNoCover(t *testing.T) {
	dir := t.TempDir()
	gray := writeCover(t, dir, func(int, int) color.RGBA { return color.RGBA{R: 128, G: 128, B: 128, A: 255} })
	s := New(nil, nil, "", nil)
	s.SetCoversDir(dir)
	var logged []string
	s.SetLogf(func(format string, args ...any) { logged = append(logged, format) })

	from, to := s.StageColors(gray, true)
	neutralFrom, neutralTo := NeutralStageColors(true)
	if from != neutralFrom || to != neutralTo {
		t.Fatalf("gray cover gave %v→%v, want the neutral %v→%v", from, to, neutralFrom, neutralTo)
	}
	if len(logged) == 0 {
		t.Fatal("the fallback was not logged")
	}
	for _, name := range []string{"", "missing.jpg"} {
		from, to := s.StageColors(name, true)
		if from != neutralFrom || to != neutralTo {
			t.Fatalf("cover %q gave %v→%v, want the neutral gradient", name, from, to)
		}
	}
}

func TestCoverTintOffUsesTheNeutralGradient(t *testing.T) {
	dir := t.TempDir()
	name := writeCover(t, dir, func(x, _ int) color.RGBA {
		return color.RGBA{R: uint8(20 + x), G: 20, B: 200, A: 255}
	})
	s := New(nil, nil, "", nil)
	s.SetCoversDir(dir)
	settings := s.Settings()
	settings.CoverTint = false
	s.settings = settings
	from, to := s.StageColors(name, true)
	neutralFrom, neutralTo := NeutralStageColors(true)
	if from != neutralFrom || to != neutralTo {
		t.Fatalf("tint off still used the cover: %v→%v", from, to)
	}
}

func TestLyricsModeAndWordProgress(t *testing.T) {
	s := New(nil, nil, "", nil)
	if s.LyricsMode() != LyricsLines {
		t.Fatal("the default renderer must be 逐行")
	}
	s.SetLyricsMode(LyricsWords)
	if s.LyricsMode() != LyricsWords {
		t.Fatal("逐字 was not selected")
	}
	s.SetLyricsMode(7)
	if s.LyricsMode() != LyricsLines {
		t.Fatal("an out-of-range mode must fall back to 逐行")
	}
}

func TestSpreadWordsIsMonotonicAndKeepsTheText(t *testing.T) {
	lyrics := ParseLRC("[00:10.00]晴天 有雨\n[00:14.00]花海 无风\n")
	if len(lyrics.Lines) != 2 {
		t.Fatalf("lines %+v", lyrics.Lines)
	}
	var joined strings.Builder
	for _, word := range lyrics.Lines[0].Words {
		joined.WriteString(word.Text)
	}
	if joined.String() != "晴天 有雨" {
		t.Fatalf("words joined to %q", joined.String())
	}
	previous := lyrics.Lines[0].Words[0]
	if previous.Start != 10*time.Second {
		t.Fatalf("first word starts at %v", previous.Start)
	}
	for _, word := range lyrics.Lines[0].Words {
		if word.End < word.Start {
			t.Fatalf("word %+v ends before it starts", word)
		}
		if word.Start < previous.Start {
			t.Fatalf("words are out of order: %+v then %+v", previous, word)
		}
		previous = word
	}
	last := lyrics.Lines[0].Words[len(lyrics.Lines[0].Words)-1]
	if last.End != 14*time.Second {
		t.Fatalf("last word ends at %v, want the next line's start 14s", last.End)
	}
	if got := WordProgress(lyrics.Lines[0].Words[0], 10*time.Second); got != 0 {
		t.Fatalf("progress at the start = %v", got)
	}
	if got := WordProgress(last, 20*time.Second); got != 1 {
		t.Fatalf("progress after the end = %v", got)
	}
	mid := WordProgress(lyrics.Lines[0].Words[1], 12*time.Second)
	if mid <= 0 || mid >= 1 {
		t.Fatalf("progress mid-word = %v, want between 0 and 1", mid)
	}
}

func TestLastLineGetsAWindow(t *testing.T) {
	lyrics := ParseLRC("[00:10.00]晴天\n")
	words := lyrics.Lines[0].Words
	if len(words) == 0 {
		t.Fatal("the last line has no words")
	}
	if words[len(words)-1].End != 14*time.Second {
		t.Fatalf("last line window ends at %v, want 10s + 4s", words[len(words)-1].End)
	}
	if SpreadWords("", 0, time.Second) != nil {
		t.Fatal("an empty line has no words")
	}
	if SpreadWords("x", time.Second, time.Second) != nil {
		t.Fatal("a zero-length line has no words")
	}
}
