// Package enrich turns metadata results into library writes and cover files.
//
// It is the layer app/data/enrichment_service.dart was: internal/metadata only
// fetches, internal/library only writes rows, and this package owns the
// decisions between them — which fields to apply, when to save a cover, how
// many tracks one session may enrich, and what "offline" means for the UI.
//
// The in-flight map is the Dart service's _inFlight: the automatic pass, the
// playback trigger and the manual trigger for the same track share one
// request, so a library open cannot multiply traffic to the upstreams.
package enrich

import (
	"context"
	"errors"
	"strings"
	"sync"

	"github.com/halunhaku/tingyu/client/internal/images"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
)

// DefaultSessionQuota is how many tracks one session enriches automatically
// (plan §2.4 #34: at most 60, so opening a large library cannot hammer the
// upstreams). A manual pass and the match dialog are not limited.
const DefaultSessionQuota = 60

// Library is the write side this service needs.
type Library interface {
	EnrichmentTargets(ctx context.Context, limit int) ([]library.EnrichmentTarget, error)
	ApplyEnrichment(ctx context.Context, id string, fields library.EnrichmentFields) (bool, error)
	ReferencedCovers(ctx context.Context) (map[string]bool, error)
}

// Result is one track's outcome.
type Result struct {
	TrackID string
	Title   string
	Changed bool
	Offline bool
	Skipped bool
	Sources []string
	// Fields is what was written (empty when nothing was).
	Fields library.EnrichmentFields
	Err    error
}

// Summary counts one pass.
type Summary struct {
	Attempted int
	Changed   int
	Offline   int
	Skipped   int
	Failed    int
	Covers    int
	Lyrics    int
}

// Stats are the service's lifetime counters, which the settings page and the
// acceptance record quote.
type Stats struct {
	Attempted int
	Changed   int
	Offline   int
	Skipped   int
	Failed    int
	Covers    int
	Lyrics    int
	// SessionUsed is how much of the automatic quota is gone.
	SessionUsed  int
	SessionQuota int
}

// Service performs enrichment.
type Service struct {
	Library  Library
	Enricher *metadata.Enricher
	Covers   *images.Store
	Fetcher  *images.Fetcher
	Log      func(format string, args ...any)
	// Quota bounds automatic enrichment; zero uses DefaultSessionQuota and a
	// negative value disables the automatic pass entirely.
	Quota int

	mu       sync.Mutex
	inflight map[string]*call
	stats    Stats
}

type call struct {
	done   chan struct{}
	result Result
}

// EnrichTrack enriches one track. Concurrent calls for the same id share one
// request. An upstream failure never becomes an error the UI must show: it
// lands in Result.Offline or Result.Err for the log only.
func (s *Service) EnrichTrack(ctx context.Context, track library.Track) Result {
	if s == nil || s.Library == nil || s.Enricher == nil {
		return Result{TrackID: track.ID, Title: track.Title, Err: errors.New("enrich: service is not configured")}
	}
	s.mu.Lock()
	if s.inflight == nil {
		s.inflight = map[string]*call{}
	}
	if running, ok := s.inflight[track.ID]; ok {
		s.mu.Unlock()
		select {
		case <-running.done:
			return running.result
		case <-ctx.Done():
			return Result{TrackID: track.ID, Title: track.Title, Err: ctx.Err()}
		}
	}
	running := &call{done: make(chan struct{})}
	s.inflight[track.ID] = running
	s.mu.Unlock()

	result := s.enrich(ctx, track)

	s.mu.Lock()
	delete(s.inflight, track.ID)
	s.stats.Attempted++
	switch {
	case result.Err != nil:
		s.stats.Failed++
	default:
		if result.Changed {
			s.stats.Changed++
			if result.Fields.CoverArtPath != "" {
				s.stats.Covers++
			}
			if result.Fields.Lyrics != "" {
				s.stats.Lyrics++
			}
		}
		if result.Offline {
			// Offline and Changed are independent: a file-name cleanup can
			// land while every request failed.
			s.stats.Offline++
		} else if !result.Changed {
			s.stats.Skipped++
		}
	}
	s.mu.Unlock()

	running.result = result
	close(running.done)
	return result
}

// enrich is one track's pipeline run, without the dedupe bookkeeping.
func (s *Service) enrich(ctx context.Context, track library.Track) Result {
	result := Result{TrackID: track.ID, Title: track.Title}
	enriched, err := s.Enricher.Enrich(ctx, metadata.Input{
		Title:               track.Title,
		Artist:              track.Artist,
		Album:               track.Album,
		Lyrics:              track.Lyrics,
		HasCover:            track.CoverArtPath != "" || track.CoverArtURL != "",
		Duration:            track.Duration,
		FillMissingDuration: track.Duration <= 0,
	})
	if err != nil {
		result.Err = err
		return result
	}
	result.Offline = enriched.Offline
	result.Sources = enriched.Sources
	result.Skipped = enriched.Skipped
	if !enriched.Changed {
		return result
	}
	fields := library.EnrichmentFields{
		Title:    enriched.Title,
		Artist:   enriched.Artist,
		Album:    enriched.Album,
		Lyrics:   enriched.Lyrics,
		Duration: enriched.Duration,
	}
	if enriched.CoverURL != "" {
		name, _, err := s.Fetcher.Cover(ctx, enriched.CoverURL)
		if err != nil {
			// The cover is the one field that can fail alone; the rest still
			// lands, and the failure is logged rather than shown.
			s.logf("enrich: cover for %q: %v", track.Title, err)
		} else if name != "" {
			fields.CoverArtPath = name
			fields.CoverArtURL = enriched.CoverURL
		}
	}
	if fields.Empty() {
		return result
	}
	changed, err := s.Library.ApplyEnrichment(ctx, track.ID, fields)
	if err != nil {
		result.Err = err
		return result
	}
	result.Changed = changed
	result.Fields = fields
	if changed {
		s.logf("enrich: %s %q → title=%q artist=%q album=%q lyrics=%d cover=%q sources=%v",
			track.ID, track.Title, fields.Title, fields.Artist, fields.Album,
			len(fields.Lyrics), fields.CoverArtPath, result.Sources)
	}
	return result
}

// Pass is a progress snapshot of EnrichTargets.
type Pass struct {
	Done     int
	Total    int
	Current  string
	Summary  Summary
	Finished bool
	// Stopped is why the pass stopped early: "quota" or "cancelled".
	Stopped string
}

// EnrichTargets runs an automatic pass over the tracks that need it, up to the
// session quota. progress (optional) is called after every track and once at
// the end; cancel (optional) is polled before each track.
func (s *Service) EnrichTargets(ctx context.Context, limit int, progress func(Pass), cancel func() bool) Summary {
	summary := Summary{}
	if s == nil || s.Library == nil || s.Enricher == nil {
		return summary
	}
	quota := s.Quota
	if quota == 0 {
		quota = DefaultSessionQuota
	}
	if quota < 0 {
		return summary
	}
	targets, err := s.Library.EnrichmentTargets(ctx, limit)
	if err != nil {
		s.logf("enrich: read targets: %v", err)
		return summary
	}
	pass := Pass{Total: len(targets)}
	report := func() {
		if progress != nil {
			progress(pass)
		}
	}
	report()
	for _, target := range targets {
		if cancel != nil && cancel() {
			pass.Stopped = "cancelled"
			pass.Finished = true
			report()
			return summary
		}
		s.mu.Lock()
		used := s.stats.SessionUsed
		quotaReached := used >= quota
		s.mu.Unlock()
		if quotaReached {
			pass.Stopped = "quota"
			pass.Finished = true
			report()
			return summary
		}
		s.mu.Lock()
		s.stats.SessionUsed++
		s.mu.Unlock()

		result := s.EnrichTrack(ctx, target.Track)
		summary.Attempted++
		switch {
		case result.Err != nil:
			summary.Failed++
		default:
			if result.Changed {
				summary.Changed++
				if result.Fields.CoverArtPath != "" {
					summary.Covers++
				}
				if result.Fields.Lyrics != "" {
					summary.Lyrics++
				}
			}
			if result.Offline {
				summary.Offline++
			} else if !result.Changed {
				summary.Skipped++
			}
		}
		pass.Done++
		pass.Current = target.Track.Title
		pass.Summary = summary
		report()
	}
	pass.Finished = true
	report()
	return summary
}

// ManualMatch writes a user's override: the fields they chose, the cover of the
// candidate they picked, and — when the track still has no lyrics — a lyric
// lookup against the chosen metadata. It never touches the session quota:
// a human action is not the automatic pass.
func (s *Service) ManualMatch(ctx context.Context, track library.Track, title, artist, album, coverURL string) Result {
	result := Result{TrackID: track.ID, Title: track.Title}
	if s == nil || s.Library == nil || s.Enricher == nil {
		result.Err = errors.New("enrich: service is not configured")
		return result
	}
	fields := library.EnrichmentFields{
		Title:  strings.TrimSpace(title),
		Artist: strings.TrimSpace(artist),
		Album:  strings.TrimSpace(album),
	}
	if coverURL != "" {
		if s.Fetcher == nil {
			result.Err = errors.New("enrich: no cover fetcher")
			return result
		}
		name, _, err := s.Fetcher.Cover(ctx, coverURL)
		if err != nil {
			s.logf("enrich: manual cover %q: %v", coverURL, err)
		} else if name != "" {
			fields.CoverArtPath = name
			fields.CoverArtURL = coverURL
		}
	}
	if strings.TrimSpace(track.Lyrics) == "" {
		query := metadata.LyricsQuery{Title: fields.Title, Artist: fields.Artist, Album: fields.Album, Duration: track.Duration}
		if query.Title == "" {
			query.Title = track.Title
		}
		text, err := s.Enricher.FetchLyrics(ctx, query)
		if err != nil {
			s.logf("enrich: manual lyrics for %q: %v", track.Title, err)
		}
		fields.Lyrics = text
		result.Sources = []string{"manual"}
	}
	changed, err := s.Library.ApplyEnrichment(ctx, track.ID, fields)
	if err != nil {
		result.Err = err
		return result
	}
	result.Changed = changed
	result.Fields = fields
	result.Skipped = !changed
	if changed {
		s.logf("enrich: manual match %q → title=%q artist=%q album=%q cover=%q lyrics=%d",
			track.Title, fields.Title, fields.Artist, fields.Album, fields.CoverArtPath, len(fields.Lyrics))
	}
	return result
}

// PruneCovers removes cover files no track references any more and returns how
// many went. The library deletion path calls this too; enrichment adds new
// files, so a pass over an edited library can drop the ones it replaced.
func (s *Service) PruneCovers(ctx context.Context) (int, error) {
	if s == nil || s.Library == nil || s.Covers == nil {
		return 0, nil
	}
	keep, err := s.Library.ReferencedCovers(ctx)
	if err != nil {
		return 0, err
	}
	return s.Covers.Prune(keep)
}

// Stats returns the counters.
func (s *Service) Stats() Stats {
	if s == nil {
		return Stats{}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	stats := s.stats
	stats.SessionQuota = s.Quota
	if stats.SessionQuota == 0 {
		stats.SessionQuota = DefaultSessionQuota
	}
	return stats
}

// CoverStore returns the store (nil-safe) so the UI can show its counters.
func (s *Service) CoverStore() *images.Store {
	if s == nil {
		return nil
	}
	return s.Covers
}

// FetcherStats returns the download counters.
func (s *Service) FetcherStats() images.FetchStats {
	if s == nil || s.Fetcher == nil {
		return images.FetchStats{}
	}
	return s.Fetcher.Stats()
}

func (s *Service) logf(format string, args ...any) {
	if s != nil && s.Log != nil {
		s.Log(format, args...)
	}
}
