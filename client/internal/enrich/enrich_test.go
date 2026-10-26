package enrich

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/images"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
)

// fakeLibrary is the write side in memory.
type fakeLibrary struct {
	mu         sync.Mutex
	tracks     map[string]library.Track
	applied    map[string]library.EnrichmentFields
	referenced map[string]bool
}

func newFakeLibrary(tracks ...library.Track) *fakeLibrary {
	lib := &fakeLibrary{tracks: map[string]library.Track{}, applied: map[string]library.EnrichmentFields{}}
	for _, track := range tracks {
		lib.tracks[track.ID] = track
	}
	return lib
}

func (f *fakeLibrary) EnrichmentTargets(_ context.Context, limit int) ([]library.EnrichmentTarget, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]library.EnrichmentTarget, 0, len(f.tracks))
	for _, track := range f.tracks {
		out = append(out, library.EnrichmentTarget{Track: track, NeedsCover: true, NeedsLyrics: true, NeedsTags: true})
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeLibrary) ApplyEnrichment(_ context.Context, id string, fields library.EnrichmentFields) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	track, ok := f.tracks[id]
	if !ok {
		return false, errors.New("unknown track")
	}
	track.Title = firstNonEmpty(fields.Title, track.Title)
	track.Artist = firstNonEmpty(fields.Artist, track.Artist)
	track.Album = firstNonEmpty(fields.Album, track.Album)
	track.Lyrics = firstNonEmpty(fields.Lyrics, track.Lyrics)
	track.CoverArtPath = firstNonEmpty(fields.CoverArtPath, track.CoverArtPath)
	track.CoverArtURL = firstNonEmpty(fields.CoverArtURL, track.CoverArtURL)
	if fields.Duration > 0 && track.Duration == 0 {
		track.Duration = fields.Duration
	}
	f.tracks[id] = track
	f.applied[id] = fields
	return !fields.Empty(), nil
}

func (f *fakeLibrary) ReferencedCovers(context.Context) (map[string]bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string]bool{}
	for name := range f.referenced {
		out[name] = true
	}
	return out, nil
}

func firstNonEmpty(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

// fakeSearcher counts searches and answers one candidate.
type fakeSearcher struct {
	calls atomic.Int64
	hit   metadata.Candidate
	delay time.Duration
}

func (f *fakeSearcher) Name() string { return "fake" }

func (f *fakeSearcher) Search(context.Context, metadata.SearchQuery, int) ([]metadata.Candidate, error) {
	f.calls.Add(1)
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	if f.hit.Title == "" {
		return nil, nil
	}
	return []metadata.Candidate{f.hit}, nil
}

type fakeLyrics struct{ text string }

func (f *fakeLyrics) Name() string { return "fake-lyrics" }

func (f *fakeLyrics) Lyrics(context.Context, metadata.LyricsQuery, *metadata.Candidate) (string, error) {
	return f.text, nil
}

func coverServer(t *testing.T, broken bool) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if broken {
			http.Error(w, "no", http.StatusBadGateway)
			return
		}
		img := image.NewRGBA(image.Rect(0, 0, 16, 16))
		for y := 0; y < 16; y++ {
			for x := 0; x < 16; x++ {
				img.SetRGBA(x, y, color.RGBA{R: 200, G: 40, B: 40, A: 255})
			}
		}
		var buf bytes.Buffer
		_ = jpeg.Encode(&buf, img, nil)
		_, _ = w.Write(buf.Bytes())
	}))
	t.Cleanup(server.Close)
	return server
}

func newService(t *testing.T, lib Library, enricher *metadata.Enricher, quota int) *Service {
	t.Helper()
	dir := t.TempDir()
	store := &images.Store{Dir: dir}
	return &Service{
		Library:  lib,
		Enricher: enricher,
		Covers:   store,
		Fetcher:  &images.Fetcher{Store: store, Client: &http.Client{Timeout: 5 * time.Second}},
		Quota:    quota,
		Log:      func(format string, args ...any) { t.Logf(format, args...) },
	}
}

func TestEnrichTrackWritesEveryFieldAndSavesTheCover(t *testing.T) {
	server := coverServer(t, false)
	searcher := &fakeSearcher{hit: metadata.Candidate{
		Provider: "fake", Title: "花海", Artist: "周杰伦", Album: "魔杰座",
		CoverURL: server.URL + "/cover.jpg", Duration: 250 * time.Second,
	}}
	enricher := &metadata.Enricher{Primary: searcher, Lyrics: &fakeLyrics{text: "[00:01.00]花海"}}
	lib := newFakeLibrary(library.Track{ID: "t1", Title: "01. 花海-周杰伦-魔杰座", Artist: "未知艺术家", Album: "未知专辑"})
	service := newService(t, lib, enricher, 10)

	result := service.EnrichTrack(context.Background(), lib.tracks["t1"])
	if result.Err != nil || !result.Changed {
		t.Fatalf("result %+v", result)
	}
	applied := lib.applied["t1"]
	if applied.Artist != "周杰伦" || applied.Album != "魔杰座" || applied.Title != "花海" {
		t.Fatalf("applied %+v", applied)
	}
	if applied.Lyrics != "[00:01.00]花海" {
		t.Fatalf("lyrics %q", applied.Lyrics)
	}
	if applied.CoverArtPath == "" {
		t.Fatal("no cover file name written")
	}
	if _, ok := service.Covers.Path(applied.CoverArtPath); !ok {
		t.Fatalf("cover %q is not in the store", applied.CoverArtPath)
	}
	if applied.Duration != 250*time.Second {
		t.Fatalf("duration %v", applied.Duration)
	}
	stats := service.Stats()
	if stats.Changed != 1 || stats.Covers != 1 || stats.Lyrics != 1 {
		t.Fatalf("stats %+v", stats)
	}
	if fetch := service.FetcherStats(); fetch.Downloaded != 1 {
		t.Fatalf("fetch stats %+v", fetch)
	}
}

func TestEnrichTrackSharesOneRequest(t *testing.T) {
	searcher := &fakeSearcher{delay: 50 * time.Millisecond, hit: metadata.Candidate{Title: "晴天", Artist: "周杰伦"}}
	enricher := &metadata.Enricher{Primary: searcher}
	lib := newFakeLibrary(library.Track{ID: "t1", Title: "晴天", Artist: "未知艺术家", Album: "未知专辑"})
	service := newService(t, lib, enricher, 10)

	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			service.EnrichTrack(context.Background(), lib.tracks["t1"])
		}()
	}
	wg.Wait()
	if calls := searcher.calls.Load(); calls != 1 {
		t.Fatalf("%d upstream searches for one track, want 1", calls)
	}
	if stats := service.Stats(); stats.Attempted != 1 {
		t.Fatalf("attempted=%d, want the shared request counted once", stats.Attempted)
	}
}

func TestEnrichTargetsStopsAtTheSessionQuota(t *testing.T) {
	searcher := &fakeSearcher{hit: metadata.Candidate{Title: "歌", Artist: "歌手", Album: "专辑"}}
	enricher := &metadata.Enricher{Primary: searcher}
	lib := newFakeLibrary(
		library.Track{ID: "a", Title: "歌 1", Artist: "未知艺术家[1]", Album: "未知专辑"},
		library.Track{ID: "b", Title: "歌 2", Artist: "未知艺术家", Album: "未知专辑"},
		library.Track{ID: "c", Title: "歌 3", Artist: "未知艺术家", Album: "未知专辑"},
	)
	service := newService(t, lib, enricher, 2)
	var last Pass
	summary := service.EnrichTargets(context.Background(), 0, func(pass Pass) { last = pass }, nil)
	if summary.Attempted != 2 {
		t.Fatalf("attempted=%d, want the quota of 2", summary.Attempted)
	}
	if !last.Finished || last.Stopped != "quota" {
		t.Fatalf("final pass %+v", last)
	}
}

func TestOfflineEnrichIsSilent(t *testing.T) {
	offline := &metadata.HTTP{Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("network is unreachable")
	})}}
	enricher := &metadata.Enricher{
		Primary: &metadata.QQMusic{HTTP: offline, Endpoint: "https://example.invalid/x"},
		Cover:   &metadata.ITunes{HTTP: offline, Endpoint: "https://example.invalid/y"},
	}
	lib := newFakeLibrary(library.Track{ID: "t1", Title: "晴天", Artist: "未知艺术家", Album: "未知专辑"})
	service := newService(t, lib, enricher, 10)
	result := service.EnrichTrack(context.Background(), lib.tracks["t1"])
	if result.Err != nil {
		t.Fatalf("offline must not be an error: %v", result.Err)
	}
	if !result.Offline || result.Changed {
		t.Fatalf("result %+v", result)
	}
	if stats := service.Stats(); stats.Offline != 1 || stats.Failed != 0 {
		t.Fatalf("stats %+v", stats)
	}
}

func TestCoverFailureKeepsTheMetadata(t *testing.T) {
	server := coverServer(t, true)
	searcher := &fakeSearcher{hit: metadata.Candidate{
		Provider: "fake", Title: "花海", Artist: "周杰伦", Album: "魔杰座", CoverURL: server.URL + "/cover.jpg",
	}}
	enricher := &metadata.Enricher{Primary: searcher}
	lib := newFakeLibrary(library.Track{ID: "t1", Title: "01. 花海-周杰伦-魔杰座", Artist: "未知艺术家", Album: "未知专辑"})
	service := newService(t, lib, enricher, 10)
	result := service.EnrichTrack(context.Background(), lib.tracks["t1"])
	if result.Err != nil || !result.Changed {
		t.Fatalf("result %+v", result)
	}
	if lib.applied["t1"].CoverArtPath != "" {
		t.Fatal("a failed cover was written")
	}
	if lib.applied["t1"].Artist != "周杰伦" {
		t.Fatalf("metadata lost with the cover: %+v", lib.applied["t1"])
	}
}

func TestPruneCoversRemovesOnlyUnreferencedFiles(t *testing.T) {
	lib := newFakeLibrary()
	service := newService(t, lib, &metadata.Enricher{}, 10)
	dir := t.TempDir()
	service.Covers.Dir = dir
	keepName, _, err := service.Covers.Save([]byte("\xff\xd8keep"))
	if err != nil {
		t.Fatal(err)
	}
	orphanName, _, err := service.Covers.Save([]byte("\xff\xd8orphan"))
	if err != nil {
		t.Fatal(err)
	}
	lib.referenced = map[string]bool{keepName: true}
	removed, err := service.PruneCovers(context.Background())
	if err != nil || removed != 1 {
		t.Fatalf("removed=%d err=%v", removed, err)
	}
	if _, ok := service.Covers.Path(keepName); !ok {
		t.Fatal("the shared cover was removed")
	}
	if _, ok := service.Covers.Path(orphanName); ok {
		t.Fatal("the orphan survived")
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal(err)
	}
}

func TestEnrichTargetsReportsProgress(t *testing.T) {
	searcher := &fakeSearcher{}
	enricher := &metadata.Enricher{Primary: searcher}
	lib := newFakeLibrary(
		library.Track{ID: "a", Title: "歌 1", Artist: "未知艺术家", Album: "未知专辑"},
		library.Track{ID: "b", Title: "歌 2", Artist: "未知艺术家", Album: "未知专辑"},
	)
	service := newService(t, lib, enricher, 10)
	var passes []Pass
	service.EnrichTargets(context.Background(), 0, func(pass Pass) { passes = append(passes, pass) }, nil)
	if len(passes) < 3 {
		t.Fatalf("%d progress reports, want at least total+final", len(passes))
	}
	if passes[0].Total != 2 || !passes[len(passes)-1].Finished {
		t.Fatalf("passes %+v", passes)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
