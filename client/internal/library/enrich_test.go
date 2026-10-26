package library

import (
	"context"
	"strings"
	"testing"
	"time"
)

// tagsFixture is three tracks: one fully tagged, one untagged (a remote
// source's row), one with tags but no assets.
func tagsFixture(t *testing.T) string {
	t.Helper()
	return newFixture(t, SchemaVersion, []fixtureTrack{
		{id: "a", title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269},
		{id: "b", title: "01. 花海-周杰伦-魔杰座", artist: UnknownArtist, album: UnknownAlbum},
		{id: "c", title: "守月", artist: "张碧晨", album: "守月", duration: 200},
	})
}

func TestEnrichmentTargetsListOnlyIncompleteRows(t *testing.T) {
	lib := openWritable(t, tagsFixture(t))
	// "a" is complete once it has a cover and lyrics.
	if ok, err := lib.ApplyEnrichment(context.Background(), "a", EnrichmentFields{
		CoverArtPath: "cover.jpg", Lyrics: "[00:01.00]晴天",
	}); err != nil || !ok {
		t.Fatalf("complete a: ok=%v err=%v", ok, err)
	}
	targets, err := lib.EnrichmentTargets(context.Background(), 0)
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, 0, len(targets))
	for _, target := range targets {
		ids = append(ids, target.Track.ID)
	}
	if len(ids) != 2 || ids[0] != "b" || ids[1] != "c" {
		t.Fatalf("targets %v, want [b c]", ids)
	}
	for _, target := range targets {
		if target.Track.ID == "b" && (!target.NeedsTags || !target.NeedsCover || !target.NeedsLyrics) {
			t.Fatalf("b flags %+v", target)
		}
	}
	if count, err := lib.CountEnrichmentTargets(context.Background()); err != nil || count != 2 {
		t.Fatalf("count=%d err=%v, want 2", count, err)
	}
	limited, err := lib.EnrichmentTargets(context.Background(), 1)
	if err != nil || len(limited) != 1 || limited[0].Track.ID != "b" {
		t.Fatalf("limited %+v err=%v", limited, err)
	}
}

func TestApplyEnrichmentWritesOnlyWhatItWasGivenAndBumpsRevisions(t *testing.T) {
	lib := openWritable(t, tagsFixture(t))
	beforeRevision := lib.Revision()
	beforeRow := lib.RowRevision("b")
	ok, err := lib.ApplyEnrichment(context.Background(), "b", EnrichmentFields{
		Title: "花海", Artist: "周杰伦", Album: "魔杰座",
	})
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	track, found, err := lib.Track(context.Background(), "b")
	if err != nil || !found {
		t.Fatalf("read b: %v", err)
	}
	if track.Title != "花海" || track.Artist != "周杰伦" || track.Album != "魔杰座" {
		t.Fatalf("track %+v", track)
	}
	if track.CoverArtPath != "" || track.Lyrics != "" {
		t.Fatalf("untouched fields were written: cover=%q lyrics=%q", track.CoverArtPath, track.Lyrics)
	}
	if lib.Revision() <= beforeRevision || lib.RowRevision("b") <= beforeRow {
		t.Fatalf("revision %d (was %d), row %d (was %d): the write must invalidate the list",
			lib.Revision(), beforeRevision, lib.RowRevision("b"), beforeRow)
	}
	// A no-op write reports false and does not bump anything.
	beforeRevision = lib.Revision()
	if ok, err := lib.ApplyEnrichment(context.Background(), "b", EnrichmentFields{}); err != nil || ok {
		t.Fatalf("empty write: ok=%v err=%v", ok, err)
	}
	if lib.Revision() != beforeRevision {
		t.Fatal("an empty write bumped the revision")
	}
}

func TestApplyEnrichmentKeepsAKnownDuration(t *testing.T) {
	lib := openWritable(t, tagsFixture(t))
	// "c" has a 200 s duration; a search hit claiming 210 s must not replace it.
	if _, err := lib.ApplyEnrichment(context.Background(), "c", EnrichmentFields{
		Lyrics: "[00:01.00]守月", Duration: 210 * time.Second,
	}); err != nil {
		t.Fatal(err)
	}
	// "b" has none; the hit fills it.
	if _, err := lib.ApplyEnrichment(context.Background(), "b", EnrichmentFields{
		Duration: 240 * time.Second,
	}); err != nil {
		t.Fatal(err)
	}
	c, _, _ := lib.Track(context.Background(), "c")
	b, _, _ := lib.Track(context.Background(), "b")
	if c.Duration != 200*time.Second {
		t.Fatalf("c duration %v, want its own 200s", c.Duration)
	}
	if b.Duration != 240*time.Second {
		t.Fatalf("b duration %v, want the backfilled 240s", b.Duration)
	}
}

func TestManualMatchPersistsAndStaysMinimal(t *testing.T) {
	path := tagsFixture(t)
	lib := openWritable(t, path)
	// The user fixes only the artist after picking a candidate.
	if ok, err := lib.ManualMatch(context.Background(), "c", EnrichmentFields{Artist: "张碧晨"}); err != nil || ok {
		t.Fatalf("unchanged override: ok=%v err=%v", ok, err)
	}
	if ok, err := lib.ManualMatch(context.Background(), "b", EnrichmentFields{
		Title: "花海", Artist: "周杰伦", Album: "魔杰座", CoverArtPath: "abc.jpg",
	}); err != nil || !ok {
		t.Fatalf("manual match: ok=%v err=%v", ok, err)
	}
	lib.Close()
	// Reopen: the override is in the file, not in a cache.
	reopened := openWritable(t, path)
	track, _, err := reopened.Track(context.Background(), "b")
	if err != nil {
		t.Fatal(err)
	}
	if track.Title != "花海" || track.CoverArtPath != "abc.jpg" {
		t.Fatalf("reopened track %+v", track)
	}
	if !strings.HasPrefix(track.Album, "魔杰座") {
		t.Fatalf("album %q", track.Album)
	}
}

func TestEnrichmentRequiresWritableAndID(t *testing.T) {
	lib := openWritable(t, tagsFixture(t))
	if _, err := lib.ApplyEnrichment(context.Background(), "", EnrichmentFields{Title: "x"}); err == nil {
		t.Fatal("an empty id must be refused")
	}
	readOnly, err := Open(context.Background(), lib.Path())
	if err != nil {
		t.Fatal(err)
	}
	defer readOnly.Close()
	if _, err := readOnly.ApplyEnrichment(context.Background(), "b", EnrichmentFields{Title: "x"}); err == nil {
		t.Fatal("a read-only connection must refuse the write")
	}
}
