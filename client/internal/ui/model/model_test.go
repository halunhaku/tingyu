package model

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

func tracks(n int) []library.Track {
	out := make([]library.Track, 0, n)
	for i := 0; i < n; i++ {
		favorite := i%3 == 0
		out = append(out, library.Track{
			ID:         "id-" + itoa(uint64(i)),
			Title:      "曲目 " + itoa(uint64(i)),
			Artist:     "艺术家 " + itoa(uint64(i%7)),
			Album:      "专辑 " + itoa(uint64(i%5)),
			Duration:   time.Duration(180+i%120) * time.Second,
			SourceID:   "src",
			IsFavorite: favorite,
		})
	}
	return out
}

func TestPaginationIsOnePagePerTriggerAndGated(t *testing.T) {
	all := tracks(100)
	s := New(all, "/tmp/lib.sqlite", nil)
	s.SetTracks(all, 1, nil)
	s.Tick(time.Now())
	list := s.Library()
	if list.Total() != 100 || list.Loaded() != 40 || list.Done() {
		t.Fatalf("first page: total=%d loaded=%d done=%v", list.Total(), list.Loaded(), list.Done())
	}
	list.RequestMore()
	list.RequestMore()
	list.RequestMore()
	if list.Loaded() != 40 {
		t.Fatalf("a pending page built rows before its step: %d", list.Loaded())
	}
	s.Tick(time.Now())
	if list.Loaded() != 80 || list.Loading() {
		t.Fatalf("one trigger: loaded=%d loading=%v", list.Loaded(), list.Loading())
	}
	for !list.Done() {
		list.RequestMore()
		s.Tick(time.Now())
	}
	if list.Loaded() != 100 || list.Page() != 3 {
		t.Fatalf("end: loaded=%d pages=%d", list.Loaded(), list.Page())
	}
	before := list.Page()
	list.RequestMore()
	s.Tick(time.Now())
	if list.Page() != before {
		t.Fatalf("done list built another page: %d -> %d", before, list.Page())
	}
}

func TestRefreshKeepsPagesAndChangesRowKeys(t *testing.T) {
	all := tracks(100)
	s := New(all, "/tmp/lib.sqlite", nil)
	s.SetTracks(all, 1, nil)
	s.Tick(time.Now())
	s.Library().RequestMore()
	s.Tick(time.Now())
	if s.Library().Page() != 2 {
		t.Fatalf("pages = %d", s.Library().Page())
	}
	revs := map[string]uint64{}
	for _, track := range all {
		revs[track.ID] = 1
	}
	all[0].Title = "改写后的标题"
	all[0].IsFavorite = true
	revs[all[0].ID] = 2
	s.SetTracks(all, 2, revs)
	s.Tick(time.Now())
	if s.Library().Page() != 2 {
		t.Fatalf("refresh reset the pages to %d", s.Library().Page())
	}
	found := false
	for i, track := range s.Library().Items() {
		if track.ID == all[0].ID {
			key := s.Library().Table().Key(i).(RowKey)
			if key.Rev != 2 {
				t.Fatalf("row key %+v did not carry its revision", key)
			}
			found = true
		}
	}
	if !found {
		t.Fatal("the changed row is not in the loaded page")
	}
	if s.Library().Total() != 100 {
		t.Fatalf("total = %d", s.Library().Total())
	}
}

func TestSearchDebounceAndGroups(t *testing.T) {
	all := tracks(30)
	s := New(all, "/tmp/lib.sqlite", nil)
	s.SetTracks(all, 1, nil)
	now := time.Now()
	s.Tick(now)
	search := s.Search()
	search.Input = "曲目 1"
	search.OnInput(now)
	s.Tick(now.Add(100 * time.Millisecond))
	if search.Query != "" || search.NeedsResults() {
		t.Fatalf("debounce fired early: %q", search.Query)
	}
	s.Tick(now.Add(SearchDebounceTime + 10*time.Millisecond))
	if search.Query != "曲目 1" {
		t.Fatalf("query = %q", search.Query)
	}
	results := search.Results()
	if results.SongTotal == 0 || results.Query != "曲目 1" {
		t.Fatalf("results = %+v", results)
	}
	for _, track := range results.Songs {
		if !trackMatches(track, "曲目 1") {
			t.Fatalf("unexpected match %q", track.Title)
		}
	}
}

func TestAlbumsAndArtistsGroup(t *testing.T) {
	all := tracks(35)
	s := New(all, "/tmp/lib.sqlite", nil)
	s.SetTracks(all, 1, nil)
	s.Tick(time.Now())
	if got, want := len(s.Albums()), 35; got != want {
		t.Fatalf("albums = %d, want %d", got, want)
	}
	if got, want := len(s.Artists()), 7; got != want {
		t.Fatalf("artists = %d, want %d", got, want)
	}
	favorites := s.FavoriteAlbums()
	if len(favorites) == 0 || len(favorites) >= len(s.Albums()) {
		t.Fatalf("favourite albums = %d of %d", len(favorites), len(s.Albums()))
	}
	var total int
	for _, album := range s.Albums() {
		total += len(album.Tracks)
	}
	if total != len(all) {
		t.Fatalf("album tracks = %d, want %d", total, len(all))
	}
}

func TestParseLRC(t *testing.T) {
	lyrics := ParseLRC("[ar:艺术家]\n[00:01.00]第一句\n[00:05.50][00:12.250]重复第二句\n[01:02]最后一句")
	if !lyrics.Synced {
		t.Fatal("timed lyrics reported as plain text")
	}
	if len(lyrics.Lines) != 4 {
		t.Fatalf("lines = %d: %+v", len(lyrics.Lines), lyrics.Lines)
	}
	if lyrics.Lines[1].Time != 5500*time.Millisecond || lyrics.Lines[2].Time != 12250*time.Millisecond {
		t.Fatalf("fractions parsed wrong: %+v", lyrics.Lines)
	}
	for _, test := range []struct {
		pos  time.Duration
		want int
	}{
		{0, 0},
		{time.Second, 0},
		{6 * time.Second, 1},
		{13 * time.Second, 2},
		{2 * time.Minute, 3},
	} {
		if got := lyrics.Current(test.pos); got != test.want {
			t.Errorf("Current(%v) = %d, want %d", test.pos, got, test.want)
		}
	}
}

func TestParseLRCPlainText(t *testing.T) {
	lyrics := ParseLRC("第一行\n第二行")
	if lyrics.Synced || lyrics.Plain != "第一行\n第二行" {
		t.Fatalf("plain lyrics = %+v", lyrics)
	}
	if got := lyrics.Current(time.Minute); got != -1 {
		t.Fatalf("plain lyrics current = %d", got)
	}
}

func TestSettingsTolerantReadAndAtomicWrite(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"themeMode":"sepia","density":"compact","coverTint":"yes","unknown":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	settings, corrupt, err := LoadSettings(dir)
	if err != nil || corrupt {
		t.Fatalf("load: %v corrupt=%v", err, corrupt)
	}
	if settings.ThemeMode != "system" || settings.Density != "compact" || !settings.CoverTint {
		t.Fatalf("tolerant parse = %+v", settings)
	}
	settings.ThemeMode = "dark"
	if err := SaveSettings(dir, settings); err != nil {
		t.Fatal(err)
	}
	again, corrupt, err := LoadSettings(dir)
	if err != nil || corrupt || again.ThemeMode != "dark" {
		t.Fatalf("saved = %+v corrupt=%v err=%v", again, corrupt, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, corrupt, _ := LoadSettings(dir); !corrupt {
		t.Fatal("a corrupt file was not reported")
	}
	data, _ := os.ReadFile(filepath.Join(dir, "settings.json"))
	if string(data) != "{" {
		t.Fatalf("corrupt file was overwritten: %q", data)
	}
}

func TestPaletteBuildsGroupsAndCommands(t *testing.T) {
	all := tracks(12)
	s := New(all, "/tmp/lib.sqlite", nil)
	s.SetTracks(all, 1, nil)
	s.Tick(time.Now())
	s.OpenPalette()
	if len(s.Palette().Items) == 0 {
		t.Fatal("empty palette")
	}
	s.Palette().Input = "曲目 3"
	s.Palette().OnInput(s.Now())
	s.Tick(s.Now().Add(SearchDebounceTime + time.Millisecond))
	found := false
	for _, item := range s.Palette().Items {
		if item.Kind == PaletteSong && item.Label == "曲目 3" {
			found = true
		}
	}
	if !found {
		t.Fatalf("palette items = %+v", s.Palette().Items)
	}
	s.Palette().Selected = 0
	s.ActivatePalette()
	if s.Palette().Open {
		t.Fatal("palette stayed open after activation")
	}
}
