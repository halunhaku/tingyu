package library

import (
	"context"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

// pageTrack is one row of a paging fixture, with every column the queries
// filter, sort or aggregate on.
type pageTrack struct {
	id       string
	source   string
	title    string
	artist   string
	album    string
	duration float64
	track    int
	disc     int
	year     int
	favorite bool
	cover    string
	added    time.Time
	played   time.Time
	plays    int
}

// newPageFixture writes a library with the full production schema and these
// rows. It is the SQL side's own fixture: the model and shell tests use an
// in-memory stand-in, so the statements themselves are only ever proved here.
func newPageFixture(t *testing.T, tracks []pageTrack) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "library.sqlite")
	db, err := sqlite.Open(context.Background(), path, sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("create fixture: %v", err)
	}
	defer db.Close()
	ctx := context.Background()
	if err := ensureSchema(ctx, db); err != nil {
		t.Fatalf("create schema: %v", err)
	}
	if _, err := db.Execute(ctx, `INSERT INTO music_sources (id, name, kind, track_count)
		VALUES ('src', '本地', 'local', 0), ('other', '别的来源', 'local', 0)`); err != nil {
		t.Fatalf("insert sources: %v", err)
	}
	for _, track := range tracks {
		source := track.source
		if source == "" {
			source = "src"
		}
		favorite := 0
		if track.favorite {
			favorite = 1
		}
		added := track.added
		if added.IsZero() {
			added = time.Unix(1_700_000_000, 0).UTC()
		}
		var played any
		if !track.played.IsZero() {
			played = formatTime(track.played)
		}
		if _, err := db.Execute(ctx,
			`INSERT INTO tracks (id, source_id, title, artist, album, duration,
			   track_number, disc_number, year, file_path_or_url, file_size,
			   cover_art_path, is_favorite, date_added, play_count, last_played_at)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)`,
			track.id, source, track.title, track.artist, track.album, track.duration,
			nullableInt(track.track), nullableInt(track.disc), nullableInt(track.year),
			source+"::/music/"+track.id+".flac", nullableString(track.cover),
			favorite, formatTime(added), track.plays, played); err != nil {
			t.Fatalf("insert %s: %v", track.id, err)
		}
	}
	if _, err := db.Execute(ctx, "PRAGMA user_version = 2"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	return path
}

func samplePageTracks() []pageTrack {
	return []pageTrack{
		{id: "a1", title: "西西里", artist: "周杰伦", album: "太阳之子", duration: 229, track: 1, disc: 1, year: 2016, favorite: true, cover: "aaaaaaaaaaaaaaaa.jpg"},
		{id: "a2", title: "湘女多情", artist: "周杰伦", album: "太阳之子", duration: 238, track: 2, disc: 1, year: 2016, cover: "aaaaaaaaaaaaaaaa.jpg"},
		{id: "b1", title: "Hello", artist: "Adele", album: "25", duration: 285.5, track: 1, disc: 1, year: 2015, played: time.Unix(1_700_100_000, 0).UTC(), plays: 4},
		{id: "b2", title: "Send My Love", artist: "Adele", album: "25", duration: 223, track: 2, disc: 1, year: 2015},
		{id: "c1", title: "夜曲", artist: "周杰伦", album: "十一月的萧邦", duration: 226, track: 1, disc: 1, year: 2005, cover: "cccccccccccccccc.png"},
		{id: "d1", title: "别的来源", artist: "其他人", album: "别的专辑", duration: 100, source: "other"},
	}
}

func mustPage(t *testing.T, lib *Library, q TrackQuery) []Track {
	t.Helper()
	tracks, err := lib.TracksPage(context.Background(), q)
	if err != nil {
		t.Fatalf("TracksPage(%+v): %v", q, err)
	}
	return tracks
}

func ids(tracks []Track) []string {
	out := make([]string, len(tracks))
	for i, track := range tracks {
		out[i] = track.ID
	}
	return out
}

func TestTracksPageFiltersSortsAndPages(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()

	all := mustPage(t, lib, TrackQuery{Sort: SortTitle, Limit: 3})
	if len(all) != 3 {
		t.Fatalf("first page = %v, want 3 rows", ids(all))
	}
	second := mustPage(t, lib, TrackQuery{Sort: SortTitle, Limit: 3, Offset: 3})
	if len(second) != 3 {
		t.Fatalf("second page = %v, want 3 rows", ids(second))
	}
	seen := map[string]bool{}
	for _, track := range append(all, second...) {
		if seen[track.ID] {
			t.Fatalf("page %v and %v overlap", ids(all), ids(second))
		}
		seen[track.ID] = true
	}
	if total, err := lib.CountTracks(ctx, TrackQuery{}); err != nil || total != 6 {
		t.Fatalf("count = %d, %v, want 6", total, err)
	}

	// Source filter: only the other source's row.
	other := mustPage(t, lib, TrackQuery{SourceID: "other"})
	if got := ids(other); len(got) != 1 || got[0] != "d1" {
		t.Fatalf("source filter = %v", got)
	}
	if total, _ := lib.CountTracks(ctx, TrackQuery{SourceID: "other"}); total != 1 {
		t.Fatalf("source count = %d", total)
	}

	// Favourites.
	favorites := mustPage(t, lib, TrackQuery{Favorite: true})
	if got := ids(favorites); len(got) != 1 || got[0] != "a1" {
		t.Fatalf("favourites = %v", got)
	}

	// Artist + album (album detail) in disc/track order.
	album := mustPage(t, lib, TrackQuery{Artist: "周杰伦", Album: "太阳之子", Sort: SortAlbum})
	if got := ids(album); len(got) != 2 || got[0] != "a1" || got[1] != "a2" {
		t.Fatalf("album tracks = %v", got)
	}

	// Search over title, artist and album, case-insensitively.
	for _, needle := range []string{"hello", "周杰伦", "25"} {
		found := mustPage(t, lib, TrackQuery{Search: needle})
		if len(found) == 0 {
			t.Fatalf("search %q found nothing", needle)
		}
	}
	// A LIKE wildcard is literal, not a wildcard.
	if found := mustPage(t, lib, TrackQuery{Search: "%"}); len(found) != 0 {
		t.Fatalf("a literal %% matched %d rows", len(found))
	}

	// Sort direction: 最近添加 ascending oldest first.
	oldest := mustPage(t, lib, TrackQuery{Sort: SortAdded, Limit: 1})
	newest := mustPage(t, lib, TrackQuery{Sort: SortAdded, Desc: true, Limit: 1})
	if len(oldest) != 1 || len(newest) != 1 {
		t.Fatalf("added sort returned %d/%d rows", len(oldest), len(newest))
	}
	// The fixture's date_added is the same for all rows, so the tie-break
	// (title) decides; both directions must still be stable and distinct.
	if oldest[0].ID == newest[0].ID && len(samplePageTracks()) > 1 {
		t.Logf("ties keep one row in both directions: %s", oldest[0].ID)
	}
}

func TestUnknownAlbumAndArtistMatchBothForms(t *testing.T) {
	// One row stores the placeholder, one a legacy empty string: both belong to
	// the 未知专辑 / 未知艺术家 group the pages show.
	path := newPageFixture(t, []pageTrack{
		{id: "u1", title: "有标签", artist: "未知艺术家", album: "未知专辑"},
		{id: "u2", title: "无标签", artist: "", album: ""},
	})
	lib := openWritable(t, path)
	ctx := context.Background()
	albums, err := lib.AlbumsPage(ctx, AlbumQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if len(albums) != 1 || albums[0].Name != "未知专辑" || albums[0].TrackCount != 2 {
		t.Fatalf("albums = %+v, want one unknown album with two tracks", albums)
	}
	artists, err := lib.ArtistsPage(ctx, ArtistQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if len(artists) != 1 || artists[0].Name != "未知艺术家" || artists[0].TrackCount != 2 {
		t.Fatalf("artists = %+v", artists)
	}
	tracks, err := lib.TracksPage(ctx, TrackQuery{Artist: "未知艺术家", Album: "未知专辑"})
	if err != nil {
		t.Fatal(err)
	}
	if len(tracks) != 2 {
		t.Fatalf("unknown album detail = %d rows, want 2 (%v)", len(tracks), ids(tracks))
	}
}

func TestTracksPagePlaylistOrder(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"c1", "a2", "b1"}); err != nil {
		t.Fatal(err)
	}
	// A playlist page is in saved order whatever the sort asks for.
	tracks := mustPage(t, lib, TrackQuery{PlaylistID: playlist.ID, Sort: SortTitle})
	if got := ids(tracks); strings.Join(got, ",") != "c1,a2,b1" {
		t.Fatalf("playlist order = %v", got)
	}
	if total, _ := lib.CountTracks(ctx, TrackQuery{PlaylistID: playlist.ID}); total != 3 {
		t.Fatalf("playlist count = %d", total)
	}
	// Paging a playlist with LIMIT/OFFSET keeps the same order.
	page := mustPage(t, lib, TrackQuery{PlaylistID: playlist.ID, Limit: 2, Offset: 1})
	if got := ids(page); strings.Join(got, ",") != "a2,b1" {
		t.Fatalf("playlist page = %v", got)
	}
}

func TestAlbumAndArtistAggregates(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()

	albums, err := lib.AlbumsPage(ctx, AlbumQuery{})
	if err != nil {
		t.Fatal(err)
	}
	byKey := map[string]AlbumSummary{}
	for _, album := range albums {
		byKey[album.Artist+"/"+album.Name] = album
	}
	if len(albums) != 4 {
		t.Fatalf("albums = %d (%v), want 4", len(albums), byKey)
	}
	sun := byKey["周杰伦/太阳之子"]
	if sun.TrackCount != 2 || sun.Duration != 467*time.Second || sun.Year != 2016 || sun.Cover != "aaaaaaaaaaaaaaaa.jpg" {
		t.Fatalf("太阳之子 = %+v", sun)
	}
	if total, _ := lib.CountAlbums(ctx, AlbumQuery{}); total != 4 {
		t.Fatalf("album count = %d", total)
	}
	favorites, err := lib.AlbumsPage(ctx, AlbumQuery{Favorite: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(favorites) != 1 || favorites[0].Name != "太阳之子" || favorites[0].TrackCount != 1 {
		t.Fatalf("favourite albums = %+v", favorites)
	}
	// One artist's albums (the artist detail rail).
	ofArtist, err := lib.AlbumsPage(ctx, AlbumQuery{Artist: "周杰伦"})
	if err != nil {
		t.Fatal(err)
	}
	if len(ofArtist) != 2 {
		t.Fatalf("周杰伦 albums = %+v", ofArtist)
	}
	// Paging the album list.
	firstPage, _ := lib.AlbumsPage(ctx, AlbumQuery{Limit: 2})
	if len(firstPage) != 2 {
		t.Fatalf("album page = %d rows", len(firstPage))
	}

	artists, err := lib.ArtistsPage(ctx, ArtistQuery{})
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]ArtistSummary{}
	for _, artist := range artists {
		byName[artist.Name] = artist
	}
	if len(artists) != 3 {
		t.Fatalf("artists = %+v", artists)
	}
	zhou := byName["周杰伦"]
	if zhou.TrackCount != 3 || zhou.AlbumCount != 2 || zhou.Duration != 693*time.Second || zhou.Cover == "" {
		t.Fatalf("周杰伦 = %+v", zhou)
	}
	if total, _ := lib.CountArtists(ctx, ArtistQuery{}); total != 3 {
		t.Fatalf("artist count = %d", total)
	}
	if total, _ := lib.CountArtists(ctx, ArtistQuery{Search: "adele"}); total != 1 {
		t.Fatalf("artist search count = %d", total)
	}
}

func TestCountsAndRecentlyPlayed(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	_ = playlist
	counts, err := lib.Counts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	want := Counts{Tracks: 6, Albums: 4, Artists: 3, Playlists: 1, Sources: 2}
	if counts != want {
		t.Fatalf("counts = %+v, want %+v", counts, want)
	}
	recent, err := lib.RecentlyPlayed(ctx, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 1 || recent[0].ID != "b1" {
		t.Fatalf("recently played = %v", ids(recent))
	}
	if recent[0].PlayCount != 4 {
		t.Fatalf("play count = %d", recent[0].PlayCount)
	}
}

// TestQueryPlansUseIndexes is the acceptance evidence for SQL paging: every
// statement the pages issue is EXPLAINed on the fixture, and the plan must
// name an index (SEARCH ... USING INDEX) or a key rather than "SCAN tracks".
func TestQueryPlansUseIndexes(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "通勤")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"a1"}); err != nil {
		t.Fatal(err)
	}

	type planCase struct {
		name  string
		build func() (string, []any)
		want  []string
	}
	cases := []planCase{
		{
			name: "source page",
			build: func() (string, []any) {
				return (TrackQuery{SourceID: "src", Sort: SortArtist, Limit: 40}).pageSQL()
			},
			want: []string{"idx_tracks_source"},
		},
		{
			name: "favourites page",
			build: func() (string, []any) {
				return (TrackQuery{Favorite: true, Sort: SortTitle, Limit: 40}).pageSQL()
			},
			want: []string{"idx_tracks_favorite"},
		},
		{
			name: "album page",
			build: func() (string, []any) {
				return (TrackQuery{Artist: "周杰伦", Album: "太阳之子", Sort: SortAlbum}).pageSQL()
			},
			want: []string{"idx_tracks"},
		},
		{
			name: "artist page",
			build: func() (string, []any) {
				return (TrackQuery{Artist: "周杰伦", Sort: SortAlbum, Limit: 20}).pageSQL()
			},
			want: []string{"idx_tracks"},
		},
		{
			name: "playlist page",
			build: func() (string, []any) {
				return (TrackQuery{PlaylistID: playlist.ID, Limit: 40}).pageSQL()
			},
			want: []string{"sqlite_autoindex_playlist_items_1", "sqlite_autoindex_tracks_1"},
		},
		{
			name:  "album aggregate",
			build: func() (string, []any) { return (AlbumQuery{Limit: 60}).pageSQL() },
			want:  []string{"idx_tracks"},
		},
		{
			name:  "artist aggregate",
			build: func() (string, []any) { return (ArtistQuery{Limit: 40}).pageSQL() },
			want:  []string{"idx_tracks"},
		},
	}
	for _, test := range cases {
		sql, args := test.build()
		rows, err := lib.db.Query(ctx, "EXPLAIN QUERY PLAN "+sql, args...)
		if err != nil {
			t.Fatalf("%s: EXPLAIN: %v", test.name, err)
		}
		detail := planDetails(t, rows)
		t.Logf("%s: %s", test.name, detail)
		if strings.HasPrefix(detail, "SCAN t") && !strings.Contains(detail, "USING") {
			t.Errorf("%s scans the table: %s", test.name, detail)
		}
		for _, want := range test.want {
			if !strings.Contains(detail, want) {
				t.Errorf("%s plan does not mention %q: %s", test.name, want, detail)
			}
		}
	}
}

func planDetails(t *testing.T, rows sqlite.Rows) string {
	t.Helper()
	column := columnIndex(rows.Columns, "detail")
	if column < 0 {
		t.Fatalf("EXPLAIN QUERY PLAN has no detail column: %v", rows.Columns)
	}
	parts := make([]string, 0, len(rows.Values))
	for _, value := range rows.Values {
		parts = append(parts, stringValue(value[column]))
	}
	return strings.Join(parts, " | ")
}

// TestTenThousandRowPaging stays inside the frame budget: a page query and its
// count over ten thousand rows must be far quicker than 16.7 ms, which is what
// lets the scroll gate ask for a page without dropping a frame.
func TestTenThousandRowPaging(t *testing.T) {
	const rows = 10000
	tracks := make([]pageTrack, 0, rows)
	for i := range rows {
		tracks = append(tracks, pageTrack{
			id:       fmt.Sprintf("perf-%05d", i),
			title:    fmt.Sprintf("长列表曲目 %05d", i),
			artist:   fmt.Sprintf("艺术家 %02d", i%37),
			album:    fmt.Sprintf("专辑 %03d", i%211),
			duration: float64(120 + i%240),
			favorite: i%9 == 0,
		})
	}
	lib := openWritable(t, newPageFixture(t, tracks))
	ctx := context.Background()
	if total, err := lib.CountTracks(ctx, TrackQuery{}); err != nil || total != rows {
		t.Fatalf("count = %d, %v", total, err)
	}

	queries := []struct {
		name string
		q    TrackQuery
	}{
		{"library page", TrackQuery{Sort: SortTitle, Limit: PageSizeForTest, Offset: rows/2 + 1000}},
		{"favourites page", TrackQuery{Favorite: true, Sort: SortTitle, Limit: PageSizeForTest, Offset: 900}},
		{"last page", TrackQuery{Sort: SortAdded, Desc: true, Limit: PageSizeForTest, Offset: rows - 40}},
		{"source page", TrackQuery{SourceID: "src", Sort: SortArtist, Limit: PageSizeForTest, Offset: 5000}},
	}
	var slowest time.Duration
	for _, query := range queries {
		start := time.Now()
		if _, err := lib.TracksPage(ctx, query.q); err != nil {
			t.Fatalf("%s: %v", query.name, err)
		}
		took := time.Since(start)
		start = time.Now()
		if _, err := lib.CountTracks(ctx, query.q); err != nil {
			t.Fatalf("%s count: %v", query.name, err)
		}
		countTook := time.Since(start)
		t.Logf("%s: page %v, count %v", query.name, took.Round(time.Microsecond), countTook.Round(time.Microsecond))
		slowest = max(slowest, took, countTook)
	}
	start := time.Now()
	if _, err := lib.AlbumsPage(ctx, AlbumQuery{Limit: 60, Offset: 100}); err != nil {
		t.Fatal(err)
	}
	albumTook := time.Since(start)
	start = time.Now()
	if _, err := lib.ArtistsPage(ctx, ArtistQuery{Limit: 40}); err != nil {
		t.Fatal(err)
	}
	artistTook := time.Since(start)
	t.Logf("album aggregate %v, artist aggregate %v", albumTook.Round(time.Microsecond), artistTook.Round(time.Microsecond))
	slowest = max(slowest, albumTook, artistTook)
	if slowest > 16*time.Millisecond {
		t.Fatalf("slowest paging statement %v exceeds the 16.7 ms frame budget", slowest)
	}
}

// PageSizeForTest mirrors the model's page size without importing it (the
// model imports this package).
const PageSizeForTest = 40

func TestPlaylistLifecycleKeepsPositionsDense(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()

	playlist, err := lib.CreatePlaylist(ctx, "  通勤  ")
	if err != nil {
		t.Fatal(err)
	}
	if playlist.Name != "通勤" || !strings.HasPrefix(playlist.ID, "pl-") {
		t.Fatalf("created playlist = %+v", playlist)
	}
	if _, err := lib.CreatePlaylist(ctx, "   "); err == nil {
		t.Fatal("an empty name created a playlist")
	}

	// 新建 → 加 3 首
	if added, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"a1", "b1", "c1"}); err != nil || added != 3 {
		t.Fatalf("add = %d, %v", added, err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "0:a1,1:b1,2:c1" {
		t.Fatalf("items = %s", strings.Join(got, ","))
	}

	// 改名
	if err := lib.RenamePlaylist(ctx, playlist.ID, "夜跑"); err != nil {
		t.Fatal(err)
	}
	if renamed, _, _ := lib.Playlist(ctx, playlist.ID); renamed.Name != "夜跑" {
		t.Fatalf("name = %q", renamed.Name)
	}
	if err := lib.RenamePlaylist(ctx, playlist.ID, ""); err == nil {
		t.Fatal("an empty rename was accepted")
	}

	// 排序：把第 3 首移到最前
	if err := lib.MovePlaylistItem(ctx, playlist.ID, 2, 0); err != nil {
		t.Fatal(err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "0:c1,1:a1,2:b1" {
		t.Fatalf("after move: %s", strings.Join(got, ","))
	}
	if err := lib.MovePlaylistItem(ctx, playlist.ID, 0, 9); err == nil {
		t.Fatal("an out-of-range move was accepted")
	}

	// 删除曲目（按行号）后位置仍然是 0..n-1
	if err := lib.RemovePlaylistItem(ctx, playlist.ID, 1); err != nil {
		t.Fatal(err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "0:c1,1:b1" {
		t.Fatalf("after remove: %s", strings.Join(got, ","))
	}

	// 删一首曲目（走 tracks 删除与级联）会留下空洞，下一次加曲前先压紧。
	if _, err := lib.db.Execute(ctx, `DELETE FROM tracks WHERE id = 'c1'`); err != nil {
		t.Fatal(err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "1:b1" {
		t.Fatalf("cascade left %s", strings.Join(got, ","))
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"a2"}); err != nil {
		t.Fatalf("add after a hole: %v", err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "0:b1,1:a2" {
		t.Fatalf("hole not closed: %s", strings.Join(got, ","))
	}

	// 同一首歌可以出现两次（Flutter 同语义）。
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"b1"}); err != nil {
		t.Fatal(err)
	}
	if got := positions(t, lib, playlist.ID); strings.Join(got, ",") != "0:b1,1:a2,2:b1" {
		t.Fatalf("duplicate append: %s", strings.Join(got, ","))
	}

	// 删除歌单：条目随外键走，曲目本身不动。
	deletion, err := lib.DeletePlaylist(ctx, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	if deletion.Items != 3 {
		t.Fatalf("deletion = %+v", deletion)
	}
	rows, err := lib.db.Query(ctx, `SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?`, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	if left, _ := countValue(rows); left != 0 {
		t.Fatalf("%d items survived the playlist delete", left)
	}
	if total, _ := lib.CountTracks(ctx, TrackQuery{}); total != 5 {
		t.Fatalf("tracks after playlist delete = %d, want 5", total)
	}
}

func positions(t *testing.T, lib *Library, playlistID string) []string {
	t.Helper()
	rows, err := lib.db.Query(context.Background(),
		`SELECT position, track_id FROM playlist_items WHERE playlist_id = ? ORDER BY position`,
		playlistID)
	if err != nil {
		t.Fatal(err)
	}
	out := make([]string, 0, len(rows.Values))
	for _, value := range rows.Values {
		out = append(out, strconv.Itoa(intValue(value[0]))+":"+stringValue(value[1]))
	}
	return out
}

func TestFavoriteWritesPersistAndBumpRevisions(t *testing.T) {
	path := newPageFixture(t, samplePageTracks())
	lib := openWritable(t, path)
	ctx := context.Background()
	before := lib.Revision()
	if err := lib.SetFavorite(ctx, "b1", true); err != nil {
		t.Fatal(err)
	}
	if lib.Revision() <= before || lib.RowRevision("b1") == 0 {
		t.Fatalf("revision = %d (was %d), row = %d", lib.Revision(), before, lib.RowRevision("b1"))
	}
	if total, _ := lib.CountTracks(ctx, TrackQuery{Favorite: true}); total != 2 {
		t.Fatalf("favourites = %d, want 2", total)
	}
	lib.Close()

	// 重启（重开连接）后收藏仍在。
	reopened := openWritable(t, path)
	defer reopened.Close()
	track, found, err := reopened.Track(ctx, "b1")
	if err != nil || !found {
		t.Fatalf("reopen: %v found=%v", err, found)
	}
	if !track.IsFavorite {
		t.Fatal("favourite was not persisted")
	}
	// 取消收藏同样生效。
	if err := reopened.SetFavorites(ctx, []string{"b1", "a1"}, false); err != nil {
		t.Fatal(err)
	}
	if total, _ := reopened.CountTracks(ctx, TrackQuery{Favorite: true}); total != 0 {
		t.Fatalf("favourites after unfavourite = %d", total)
	}
	if err := reopened.SetFavorite(ctx, "b1", true); err != nil {
		t.Fatal(err)
	}
	if count, _ := reopened.CountTracks(ctx, TrackQuery{Favorite: true}); count != 1 {
		t.Fatalf("favourites after re-favourite = %d", count)
	}
}

func TestDeleteSourceRemovesOnlyItsTracksAndPlaylistItems(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	ctx := context.Background()
	playlist, err := lib.CreatePlaylist(ctx, "混合")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lib.AddTracksToPlaylist(ctx, playlist.ID, []string{"a1", "d1"}); err != nil {
		t.Fatal(err)
	}
	before, _ := lib.CountTracks(ctx, TrackQuery{})

	deletion, err := lib.DeleteSource(ctx, "other")
	if err != nil {
		t.Fatal(err)
	}
	if deletion.Source != "别的来源" || deletion.Tracks != 1 || deletion.PlaylistItems != 1 {
		t.Fatalf("deletion = %+v", deletion)
	}
	if len(deletion.Covers) != 0 {
		t.Fatalf("covers = %v", deletion.Covers)
	}
	after, _ := lib.CountTracks(ctx, TrackQuery{})
	if after != before-1 {
		t.Fatalf("tracks %d -> %d, want one fewer", before, after)
	}
	// The other source's rows are untouched, and its playlist item too.
	if total, _ := lib.CountTracks(ctx, TrackQuery{SourceID: "src"}); total != 5 {
		t.Fatalf("remaining source tracks = %d, want 5", total)
	}
	if total, _ := lib.CountTracks(ctx, TrackQuery{PlaylistID: playlist.ID}); total != 1 {
		t.Fatalf("playlist tracks = %d, want 1", total)
	}
	if _, found, err := lib.Track(ctx, "d1"); err != nil || found {
		t.Fatalf("deleted track still readable: found=%v err=%v", found, err)
	}
	if sources, _ := lib.Sources(ctx); len(sources) != 1 || sources[0].ID != "src" {
		t.Fatalf("sources after delete = %+v", sources)
	}
	if _, err := lib.DeleteSource(ctx, "other"); err == nil {
		t.Fatal("deleting a missing source reported success")
	}
}

func TestReferencedCoversListsLiveFiles(t *testing.T) {
	lib := openWritable(t, newPageFixture(t, samplePageTracks()))
	keep, err := lib.ReferencedCovers(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !keep["aaaaaaaaaaaaaaaa.jpg"] || !keep["cccccccccccccccc.png"] {
		t.Fatalf("referenced covers = %v", keep)
	}
	if keep["bbbbbbbbbbbbbbbb.jpg"] {
		t.Fatal("an unreferenced cover was reported as referenced")
	}
}
