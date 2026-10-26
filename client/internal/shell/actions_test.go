package shell

// End-to-end wiring: the window's buttons drive real library writes.
//
// libraryActions is app.go's shell.Actions implementation reduced to the
// writes these tests exercise (the app's version additionally logs, publishes
// Now Playing and refreshes the window). Attaching it to the window means the
// clicks go through the same model → action → SQLite path the app uses, and the
// assertions read the database afterwards instead of trusting the UI.

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/scan"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

type libraryActions struct {
	lib    *library.Library
	covers string
	model  *Model
	t      *testing.T
}

func (a *libraryActions) write(what string, fn func(ctx context.Context) error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := fn(ctx); err != nil {
		a.t.Fatalf("%s: %v", what, err)
	}
	a.model.Invalidate()
	warmModel(a.model)
}

func (a *libraryActions) PlayTracks(tracks []library.Track, start int) error { return nil }
func (a *libraryActions) TogglePlayPause() error                             { return nil }
func (a *libraryActions) Next() error                                        { return nil }
func (a *libraryActions) Previous() error                                    { return nil }
func (a *libraryActions) Seek(time.Duration) error                           { return nil }
func (a *libraryActions) SetVolume(float64) error                            { return nil }
func (a *libraryActions) CycleRepeat() player.RepeatMode                     { return player.RepeatAll }
func (a *libraryActions) SetShuffle(on bool) bool                            { return on }
func (a *libraryActions) ChooseDirectory()                                   {}
func (a *libraryActions) SyncSource(library.Source)                          {}
func (a *libraryActions) SyncAllSources()                                    {}
func (a *libraryActions) RevealInFinder(library.Track)                       {}
func (a *libraryActions) Queue() []library.Track                             { return nil }

func (a *libraryActions) SetFavorite(track library.Track, favorite bool) {
	a.write("收藏写入", func(ctx context.Context) error {
		return a.lib.SetFavorite(ctx, track.ID, favorite)
	})
}

func (a *libraryActions) CreatePlaylist(name string) {
	a.write("新建歌单", func(ctx context.Context) error {
		_, err := a.lib.CreatePlaylist(ctx, name)
		return err
	})
}

func (a *libraryActions) RenamePlaylist(id, name string) {
	a.write("重命名歌单", func(ctx context.Context) error {
		return a.lib.RenamePlaylist(ctx, id, name)
	})
}

func (a *libraryActions) DeletePlaylist(id string) {
	a.write("删除歌单", func(ctx context.Context) error {
		_, err := a.lib.DeletePlaylist(ctx, id)
		return err
	})
}

func (a *libraryActions) AddToPlaylist(playlistID string, trackIDs []string) {
	a.write("加入歌单", func(ctx context.Context) error {
		_, err := a.lib.AddTracksToPlaylist(ctx, playlistID, trackIDs)
		return err
	})
}

func (a *libraryActions) RemoveFromPlaylist(playlistID string, index int) {
	a.write("移出歌单", func(ctx context.Context) error {
		return a.lib.RemovePlaylistItem(ctx, playlistID, index)
	})
}

func (a *libraryActions) MovePlaylistItem(playlistID string, from, to int) {
	a.write("调整歌单顺序", func(ctx context.Context) error {
		return a.lib.MovePlaylistItem(ctx, playlistID, from, to)
	})
}

func (a *libraryActions) DeleteSource(source library.Source) {
	a.write("删除来源", func(ctx context.Context) error {
		if _, err := a.lib.DeleteSource(ctx, source.ID); err != nil {
			return err
		}
		keep, err := a.lib.ReferencedCovers(ctx)
		if err != nil {
			return err
		}
		_, err = scan.CollectOrphanCovers(a.covers, keep)
		return err
	})
}

// newWiredWindow builds a library copy with covers and a window whose buttons
// write through the real library.
func newWiredWindow(t *testing.T, tracks []library.ScannedTrack) (*library.Library, *Model, *libraryActions) {
	t.Helper()
	lib, m := newLibrary(t, tracks)
	actions := &libraryActions{lib: lib, covers: library.CoversDir(filepath.Dir(lib.Path())), model: m, t: t}
	m.SetActions(actions)
	return lib, m, actions
}

// evidence opens a second connection to the same file: the assertions read
// the database itself, not the window's idea of it.
func evidence(t *testing.T, lib *library.Library) *sqlite.DB {
	t.Helper()
	db, err := sqlite.Open(context.Background(), lib.Path(), sqlite.OpenOptions{})
	if err != nil {
		t.Fatalf("evidence connection: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func count(t *testing.T, db *sqlite.DB, sql string, args ...any) int {
	t.Helper()
	rows, err := db.Query(context.Background(), sql, args...)
	if err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		t.Fatalf("%s returned %+v", sql, rows.Values)
	}
	n, _ := rows.Values[0][0].(int64)
	return int(n)
}

// openRowMenu opens a row's context menu the way the A table offers it: the
// ••• column is gone (the fixed 22/44/330/170/210/弹性/56/30 rhythm of §10-4 has
// no room for it), so the menu is the right-click one the row always had.
func openRowMenu(t *testing.T, tt *ui.Tester, title string) {
	t.Helper()
	if err := tt.RightClick(title); err != nil {
		t.Fatalf("row menu on %q: %v (menu %v)", title, err, tt.Menu())
	}
}

func exec(t *testing.T, db *sqlite.DB, sql string, args ...any) {
	t.Helper()
	if _, err := db.Execute(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func TestFavoriteButtonsWriteAndUndo(t *testing.T) {
	lib, m, _ := newWiredWindow(t, sampleTracks())
	db := evidence(t, lib)
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	title := m.State().Library().Items()[0].Title
	if got := count(t, db, `SELECT COUNT(*) FROM tracks WHERE is_favorite = 1`); got != 0 {
		t.Fatalf("fixture starts with %d favourites", got)
	}
	if err := tt.Click("收藏此曲"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if got := count(t, db, `SELECT COUNT(*) FROM tracks WHERE is_favorite = 1 AND title = ?`, title); got != 1 {
		t.Fatalf("after the click, tracks.is_favorite = 1 for %d rows, want 1", got)
	}
	if !tt.HasText("取消收藏此曲") {
		t.Fatalf("the row still shows the old state; texts %q", tt.Texts())
	}
	// The favourites page queries the same flag.
	if err := tt.Click("收藏"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if !tt.HasText("已全部加载 · 共 1 首") {
		t.Fatalf("the favourites page does not show the favourite; texts %q", tt.Texts())
	}
	// And the same button takes it back.
	if err := tt.Click("取消收藏此曲"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	if got := count(t, db, `SELECT COUNT(*) FROM tracks WHERE is_favorite = 1`); got != 0 {
		t.Fatalf("after unfavouriting, %d rows are still favourites", got)
	}
	if !tt.HasText("还没有收藏的歌曲") {
		t.Fatalf("the favourites page did not empty; texts %q", tt.Texts())
	}
}

func TestFavoriteSurvivesReopeningTheLibrary(t *testing.T) {
	lib, m, _ := newWiredWindow(t, sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("收藏此曲"); err != nil {
		t.Fatal(err)
	}
	frame(tt)
	path := lib.Path()
	trackID := m.State().Library().Items()[0].ID
	lib.Close()

	// "Restart": a fresh connection sees the same row.
	reopened, err := library.OpenWritable(context.Background(), path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	track, found, err := reopened.Track(context.Background(), trackID)
	if err != nil || !found {
		t.Fatalf("track %s: found=%v err=%v", trackID, found, err)
	}
	if !track.IsFavorite {
		t.Fatal("the favourite did not survive reopening the library")
	}
}

func TestPlaylistButtonsDriveTheWholeLifecycle(t *testing.T) {
	lib, m, _ := newWiredWindow(t, sampleTracks())
	db := evidence(t, lib)
	ctx := context.Background()
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()

	// 新建 via the window's button and inline field.
	m.State().OpenPage(model.PagePlaylists)
	frame(tt)
	if err := tt.Click("新建歌单"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	// The field takes the focus itself (AutoFocus), so typing lands in it.
	tt.Type("通勤")
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	playlists, err := lib.Playlists(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(playlists) != 1 || playlists[0].Name != "通勤" {
		t.Fatalf("playlists = %+v", playlists)
	}
	playlist := playlists[0]

	// 加曲: the library rows' 「添加到播放列表」 submenu appends them.
	m.State().OpenPage(model.PageLibrary)
	frame(tt)
	for i := 0; i < 2; i++ {
		openRowMenu(t, tt, m.State().Library().Items()[i].Title)
		if err := tt.ChooseMenuItem("添加到播放列表", "通勤"); err != nil {
			t.Fatalf("add row %d: %v (menu %v)", i, err, tt.Menu())
		}
		frame(tt)
	}
	// The album header's 「加入歌单」 appends the whole album.
	m.State().OpenAlbum(model.Album{Key: "album", Name: "太阳之子", Artist: "周杰伦", Count: 2})
	frame(tt)
	if err := tt.Click("加入歌单"); err != nil {
		t.Fatalf("album 加入歌单: %v", err)
	}
	if err := tt.ChooseMenuItem("通勤"); err != nil {
		t.Fatalf("album add: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if got := count(t, db, `SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?`, playlist.ID); got != 4 {
		t.Fatalf("playlist_items = %d, want 4 (2 from rows, 2 from the album)", got)
	}

	// The playlist page lists them in saved order.
	m.State().OpenPlaylist(playlist)
	frame(tt)
	if !tt.HasText("4 首") {
		t.Fatalf("playlist page count missing; texts %q", tt.Texts())
	}

	// 排序: move the first item down one place through the row menu.
	first := m.State().PlaylistTracks().Items()[0].ID
	second := m.State().PlaylistTracks().Items()[1].ID
	openRowMenu(t, tt, m.State().PlaylistTracks().Items()[0].Title)
	if err := tt.ChooseMenuItem("下移"); err != nil {
		t.Fatalf("下移: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	rows, err := lib.TracksPage(ctx, library.TrackQuery{PlaylistID: playlist.ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 4 || rows[0].ID != second || rows[1].ID != first {
		t.Fatalf("order after the move = %v", trackIDs(rows))
	}
	if got := count(t, db, `SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ? AND position >= 0 AND position < 4`, playlist.ID); got != 4 {
		t.Fatalf("positions are not dense after the move: %d rows below 4", got)
	}

	// 改名 through the detail header.
	if err := tt.Click("重命名"); err != nil {
		t.Fatalf("重命名: %v", err)
	}
	tt.Frame()
	// The field opens with the current name; typing appends to it.
	tt.Type("·夜跑")
	tt.Key(0, ui.KeyEnter)
	frame(tt)
	renamed, found, err := lib.Playlist(ctx, playlist.ID)
	if err != nil || !found {
		t.Fatalf("playlist: %v found=%v", err, found)
	}
	if renamed.Name != "通勤·夜跑" {
		t.Fatalf("name = %q", renamed.Name)
	}

	// 删除曲目 through the row menu.
	before := count(t, db, `SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?`, playlist.ID)
	openRowMenu(t, tt, m.State().PlaylistTracks().Items()[0].Title)
	if err := tt.ChooseMenuItem("移出歌单"); err != nil {
		t.Fatalf("移出歌单: %v (menu %v)", err, tt.Menu())
	}
	frame(tt)
	if after := count(t, db, `SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?`, playlist.ID); after != before-1 {
		t.Fatalf("items %d -> %d, want one fewer", before, after)
	}

	// 删除歌单: the confirmation removes the row and cascades its items, while
	// the tracks stay.
	if err := tt.Click("删除歌单"); err != nil {
		t.Fatalf("删除歌单: %v", err)
	}
	tt.Frame()
	if err := tt.Click("确认删除"); err != nil {
		t.Fatalf("确认删除: %v", err)
	}
	frame(tt)
	if got := count(t, db, `SELECT COUNT(*) FROM playlists`); got != 0 {
		t.Fatalf("playlists left: %d", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM playlist_items`); got != 0 {
		t.Fatalf("playlist_items left after the cascade: %d", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM tracks`); got != 2 {
		t.Fatalf("the tracks went with the playlist: %d left", got)
	}
	if m.State().Page() != model.PagePlaylists {
		t.Fatalf("page after deleting the open playlist = %s", m.State().Page())
	}
}

func TestSourceDeleteRemovesTracksAndOrphanCovers(t *testing.T) {
	lib, m, actions := newWiredWindow(t, sampleTracks())
	db := evidence(t, lib)
	ctx := context.Background()
	// Two covers: one the surviving source uses, one only the deleted
	// source's track uses, plus a file that is not a cover at all.
	covers := actions.covers
	if err := os.MkdirAll(covers, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name string) {
		if err := os.WriteFile(filepath.Join(covers, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("aaaaaaaaaaaaaaaa.jpg") // the surviving source's cover
	write("bbbbbbbbbbbbbbbb.jpg") // the deleted source's cover
	write("notes.txt")            // not a cover name: must survive

	// A second source with one track, so the delete has to leave the first
	// source alone. Its name sorts first ("A" before any CJK byte), so the
	// first 删除来源 button on the page is its own.
	if err := lib.UpsertLocalSource(ctx, library.Source{ID: "src-other", Name: "A 别的来源", Kind: "local", LocalFolderPath: "/other"}); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.MergeScan(ctx, "src-other", []library.ScannedTrack{{
		FilePathOrURL: "/other/b.flac", Title: "别的", Artist: "别人", Album: "别的专辑",
		FileFormat: "flac", CoverArtPath: "bbbbbbbbbbbbbbbb.jpg",
	}}, true); err != nil {
		t.Fatal(err)
	}
	exec(t, db, `UPDATE tracks SET cover_art_path = 'aaaaaaaaaaaaaaaa.jpg' WHERE source_id = 'src-local'`)
	m.Invalidate()
	warmModel(m)

	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	m.State().OpenPage(model.PageSources)
	frame(tt)
	if !tt.HasText("A 别的来源") {
		t.Fatalf("sources page missing the second source; texts %q", tt.Texts())
	}
	// The delete lives in the card's ••• menu (§4.3's action row), so the
	// entry is opened first; the confirmation is still the only thing that
	// writes.
	if err := tt.Click("来源操作"); err != nil {
		t.Fatalf("来源操作: %v", err)
	}
	if err := tt.ChooseMenuItem("删除来源…"); err != nil {
		t.Fatalf("删除来源…: %v (menu %v)", err, tt.Menu())
	}
	tt.Frame()
	if err := tt.Click("确认删除"); err != nil {
		t.Fatalf("确认删除: %v", err)
	}
	frame(tt)

	if got := count(t, db, `SELECT COUNT(*) FROM tracks WHERE source_id = 'src-other'`); got != 0 {
		t.Fatalf("deleted source still has %d tracks", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM tracks WHERE source_id = 'src-local'`); got != 2 {
		t.Fatalf("the other source lost tracks: %d left", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM music_sources`); got != 1 {
		t.Fatalf("sources left: %d", got)
	}
	if got := count(t, db, `SELECT COUNT(*) FROM music_sources WHERE id = 'src-local'`); got != 1 {
		t.Fatal("the wrong source was deleted")
	}
	if _, err := os.Stat(filepath.Join(covers, "bbbbbbbbbbbbbbbb.jpg")); !os.IsNotExist(err) {
		t.Fatalf("the orphan cover was not collected: %v", err)
	}
	for _, keep := range []string{"aaaaaaaaaaaaaaaa.jpg", "notes.txt"} {
		if _, err := os.Stat(filepath.Join(covers, keep)); err != nil {
			t.Fatalf("%s was removed: %v", keep, err)
		}
	}
}

func trackIDs(tracks []library.Track) []string {
	out := make([]string, len(tracks))
	for i, track := range tracks {
		out[i] = track.Title
	}
	return out
}

func TestShuffleButtonReportsTheControllerState(t *testing.T) {
	_, m, actions := newWiredWindow(t, sampleTracks())
	tt := ui.NewTester(m.View, DefaultWidth, DefaultHeight)
	tt.Frame()
	if err := tt.Click("随机播放：关"); err != nil {
		t.Fatalf("shuffle button: %v (texts %q)", err, tt.Texts())
	}
	tt.Frame()
	if !m.State().Shuffle() || !tt.HasText("随机播放：开") {
		t.Fatalf("shuffle did not turn on: %v texts %q", m.State().Shuffle(), tt.Texts())
	}
	// The playlist page's 「随机播放」 turns it on for its own queue.
	if err := tt.Click("随机播放：开"); err != nil {
		t.Fatal(err)
	}
	tt.Frame()
	if m.State().Shuffle() {
		t.Fatal("shuffle did not turn off")
	}
	_ = actions
}
