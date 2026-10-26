package model

import (
	"os"
	"path/filepath"
	"strings"
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

// newTestState builds the model over the in-memory backend.
func newTestState(t *testing.T, list []library.Track) (*State, *fakeBackend) {
	t.Helper()
	backend := newFakeBackend(list)
	backend.sources = []library.Source{{ID: "src", Name: "本地", Kind: "local", TrackCount: int64(len(list))}}
	s := New(backend, backend, "/tmp/lib.sqlite", nil)
	s.FinishOnboarding()
	s.Tick(time.Now())
	return s, backend
}

func TestPaginationIsOnePagePerTriggerAndGated(t *testing.T) {
	s, backend := newTestState(t, tracks(100))
	list := s.Library()
	if list.Total() != 100 || list.Loaded() != 40 || list.Done() {
		t.Fatalf("first page: total=%d loaded=%d done=%v", list.Total(), list.Loaded(), list.Done())
	}
	_ = backend
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
	s, backend := newTestState(t, tracks(100))
	s.Library().RequestMore()
	s.Tick(time.Now())
	if s.Library().Page() != 2 {
		t.Fatalf("pages = %d", s.Library().Page())
	}
	// A metadata-only write: one title changes, the row revision moves.
	backend.tracks[0].Title = "改写后的标题"
	backend.tracks[0].IsFavorite = true
	backend.bump(backend.tracks[0].ID)
	s.Tick(time.Now())
	s.Tick(time.Now())
	if s.Library().Page() != 2 {
		t.Fatalf("refresh reset the pages to %d", s.Library().Page())
	}
	found := false
	for i, track := range s.Library().Items() {
		if track.ID == backend.tracks[0].ID {
			key := s.Library().Table().Key(i).(RowKey)
			if key.Rev != 1 {
				t.Fatalf("row key %+v did not carry its revision", key)
			}
			if track.Title != "改写后的标题" {
				t.Fatalf("refreshed row still says %q", track.Title)
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

func TestLoadingPageKeepsTheRowsItHas(t *testing.T) {
	s, backend := newTestState(t, tracks(100))
	backend.hang = map[uint64]bool{backend.revision: true}
	s.Library().RequestMore()
	s.Tick(time.Now())
	s.Tick(time.Now())
	if s.Library().Loaded() != 40 {
		t.Fatalf("loaded = %d while the next page is in flight", s.Library().Loaded())
	}
	if !s.Library().Loading() {
		t.Fatal("the list does not report the page as loading")
	}
	backend.hang = nil
	backend.bump()
	s.Tick(time.Now())
	s.Tick(time.Now())
	if s.Library().Loaded() != 80 {
		t.Fatalf("the page never arrived: loaded=%d", s.Library().Loaded())
	}
}

func TestSearchDebounceAndGroups(t *testing.T) {
	s, _ := newTestState(t, tracks(30))
	now := time.Now()
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
	if len(results.Songs) > PreviewSize || len(results.Albums) > PreviewSize || len(results.Artists) > PreviewSize {
		t.Fatalf("previews are not limited: %+v", results)
	}
}

func TestAlbumsAndArtistsComeFromTheAggregate(t *testing.T) {
	s, _ := newTestState(t, tracks(35))
	s.Tick(time.Now())
	s.Tick(time.Now())
	albums := s.Albums()
	// The fixture's 35 tracks span 7 artists × 5 albums; a group is one
	// (artist, album) pair, so all 35 are distinct albums.
	if albums.Total() != 35 {
		t.Fatalf("albums = %d, want 35", albums.Total())
	}
	if len(albums.Items()) != 35 {
		t.Fatalf("album items = %d", len(albums.Items()))
	}
	artists := s.Artists()
	if artists.Total() != 7 {
		t.Fatalf("artists = %d, want 7", artists.Total())
	}
	favorites := s.FavoriteAlbums()
	s.Tick(time.Now())
	if favorites.Total() == 0 || favorites.Total() >= albums.Total() {
		t.Fatalf("favourite albums = %d of %d", favorites.Total(), albums.Total())
	}
	// The album's tracks are one more query, not a field.
	album := albums.Items()[0]
	if got := len(s.AlbumTracks(album)); got != album.Count {
		t.Fatalf("album tracks = %d, want %d", got, album.Count)
	}
	// The aggregate carries counts, so a page does not have to load tracks to
	// print them.
	sum := 0
	for _, album := range albums.Items() {
		sum += album.Count
	}
	if sum != 35 {
		t.Fatalf("album track counts sum to %d", sum)
	}
}

func TestFavoritesListIsAFilteredQuery(t *testing.T) {
	s, _ := newTestState(t, tracks(30))
	favorites := s.Favorites()
	if total, want := favorites.Total(), 10; total != want {
		t.Fatalf("favourites = %d, want %d", total, want)
	}
	for _, track := range favorites.Items() {
		if !track.IsFavorite {
			t.Fatalf("%q is not a favourite", track.Title)
		}
	}
}

func TestPlaylistListIsInSavedOrder(t *testing.T) {
	s, backend := newTestState(t, tracks(6))
	backend.playlists = []library.Playlist{{ID: "pl-1", Name: "通勤"}}
	backend.items["pl-1"] = []string{"id-4", "id-1", "id-2"}
	backend.bump()
	s.Invalidate()
	s.Tick(time.Now())
	s.Tick(time.Now())
	if len(s.Playlists()) != 1 || s.Playlists()[0].TrackCount != 3 {
		t.Fatalf("playlists = %+v", s.Playlists())
	}
	s.OpenPlaylist(s.Playlists()[0])
	s.Tick(time.Now())
	list := s.PlaylistTracks()
	if got := list.Items(); len(got) != 3 {
		t.Fatalf("playlist rows = %d", len(got))
	}
	order := []string{}
	for _, track := range s.PlaylistTracks().Items() {
		order = append(order, track.ID)
	}
	if strings.Join(order, ",") != "id-4,id-1,id-2" {
		t.Fatalf("playlist order = %v", order)
	}
	if s.Page() != PagePlaylistDetail {
		t.Fatalf("page = %s", s.Page())
	}
}

func TestPlaylistActionsReachTheApp(t *testing.T) {
	s, backend := newTestState(t, tracks(6))
	actions := &fakeActions{}
	s.SetActions(actions)
	backend.playlists = []library.Playlist{{ID: "pl-1", Name: "通勤"}}
	backend.items["pl-1"] = []string{"id-1", "id-2"}
	backend.bump()
	s.Invalidate()
	s.Tick(time.Now())
	s.Tick(time.Now())

	s.BeginCreatePlaylist()
	*s.PlaylistEditValue() = "  夜跑 "
	s.CommitPlaylistEdit()
	if len(actions.playlists) != 1 || actions.playlists[0] != "create:夜跑" {
		t.Fatalf("create = %v", actions.playlists)
	}

	playlist := s.Playlists()[0]
	s.BeginRenamePlaylist(playlist)
	*s.PlaylistEditValue() = "通勤 2"
	s.CommitPlaylistEdit()
	if got := actions.playlists[1]; got != "rename:pl-1:通勤 2" {
		t.Fatalf("rename = %q", got)
	}

	// An empty name writes nothing (the kernel refuses it too).
	s.BeginCreatePlaylist()
	*s.PlaylistEditValue() = "  "
	s.CommitPlaylistEdit()
	if len(actions.playlists) != 2 {
		t.Fatalf("an empty name reached the app: %v", actions.playlists)
	}

	s.OpenPlaylist(playlist)
	s.Tick(time.Now())
	s.Tick(time.Now())
	s.MovePlaylistItem(1, 0)
	s.RemoveFromPlaylist(0)
	s.AddToPlaylist("pl-1", []library.Track{{ID: "id-5"}})
	if len(actions.moved) != 1 || actions.moved[0] != [2]int{1, 0} {
		t.Fatalf("move = %v", actions.moved)
	}
	if len(actions.removed) != 1 || actions.removed[0] != 0 {
		t.Fatalf("remove = %v", actions.removed)
	}
	if len(actions.added) != 1 || actions.added[0] != "pl-1=id-5" {
		t.Fatalf("add = %v", actions.added)
	}

	s.DeletePlaylist(playlist)
	if got := actions.playlists[len(actions.playlists)-1]; got != "delete:pl-1" {
		t.Fatalf("delete = %q", got)
	}
	if s.PlaylistDetail() != nil {
		t.Fatal("the deleted playlist stayed open")
	}
}

func TestFavoriteToggleReachesTheApp(t *testing.T) {
	s, _ := newTestState(t, tracks(6))
	actions := &fakeActions{}
	s.SetActions(actions)
	track := library.Track{ID: "id-1", Title: "曲目 1"}
	s.ToggleFavorite(track)
	if len(actions.favorites) != 1 || actions.favorites[0] != "+"+track.ID {
		t.Fatalf("favorite = %v", actions.favorites)
	}
	track.IsFavorite = true
	s.ToggleFavorite(track)
	if got := actions.favorites[1]; got != "-"+track.ID {
		t.Fatalf("unfavorite = %q", got)
	}
}

func TestShuffleTogglesThroughTheApp(t *testing.T) {
	s, _ := newTestState(t, tracks(4))
	actions := &fakeActions{}
	s.SetActions(actions)
	s.ToggleShuffle()
	if !s.Shuffle() || !actions.shuffle {
		t.Fatalf("shuffle = %v / %v", s.Shuffle(), actions.shuffle)
	}
	s.ToggleShuffle()
	if s.Shuffle() || actions.shuffle {
		t.Fatalf("shuffle off = %v / %v", s.Shuffle(), actions.shuffle)
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
	s, _ := newTestState(t, tracks(12))
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

func TestCountsAndOnboarding(t *testing.T) {
	s, backend := newTestState(t, tracks(9))
	if s.Counts().Tracks != 9 {
		t.Fatalf("counts = %+v", s.Counts())
	}
	if s.ShouldOnboard() {
		t.Fatal("onboarding showed with tracks in the library")
	}
	emptyBackend := newFakeBackend(nil)
	empty := New(emptyBackend, emptyBackend, "/tmp/lib.sqlite", nil)
	empty.Tick(time.Now())
	if !empty.ShouldOnboard() {
		t.Fatalf("onboarding did not show for an empty library: counts=%+v sources=%d",
			empty.Counts(), len(empty.Sources()))
	}
	_ = backend
}
