//go:build darwin

package app

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/sourcemock"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

func folderFixture(t *testing.T) (*library.Library, *sources.Credentials, *sources.QuarkClient, *sourcemock.Quark) {
	t.Helper()
	ctx := context.Background()
	p := filepath.Join(t.TempDir(), "library.sqlite")
	db, err := sqlite.Open(ctx, p, sqlite.OpenOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Execute(ctx, "PRAGMA user_version = 2"); err != nil {
		t.Fatal(err)
	}
	db.Close()
	lib, err := library.OpenWritable(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lib.Close() })
	mock := sourcemock.NewQuark(sourcemock.QuarkOptions{Session: "mock-session", Entries: map[string][]sourcemock.QuarkEntry{
		"0":     {{FID: "music", Name: "音乐", Folder: true}, {FID: "other", Name: "其他", Folder: true}, {FID: "not-folder", Name: "其他.mp3"}},
		"music": {{FID: "song", Name: "周杰伦 - Mine Mine.mp3", Size: 100}},
		"other": {{FID: "outside", Name: "不应入库.mp3", Size: 100}},
		"empty": {},
	}})
	server := httptest.NewServer(mock)
	t.Cleanup(server.Close)
	mock.SetBaseURL(server.URL)
	client, err := sources.NewQuarkClient(sources.QuarkOptions{HTTP: server.Client(), PCBaseURL: server.URL + "/api", CDNBaseURL: server.URL + "/cdn", Retry: sources.NoRetry, FolderDelay: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	return lib, sources.NewCredentials(sources.NewMemoryStore()), client, mock
}

func TestQuarkBrowsingDoesNotSaveUntilFolderConfirmation(t *testing.T) {
	lib, creds, client, _ := folderFixture(t)
	ctx := context.Background()
	v := model.SourceFormValues{Name: "我的音乐", Cookie: "__pus=mock-session; __puus=test", FolderFID: "0", FolderPath: "/"}
	folders, cookie, err := readQuarkFolders(ctx, client, creds, v)
	if err != nil {
		t.Fatal(err)
	}
	if len(folders) != 2 {
		t.Fatalf("picker should list folders only: %+v", folders)
	}
	all, err := lib.Sources(ctx)
	if err != nil || len(all) != 0 {
		t.Fatalf("browsing saved a source: %+v %v", all, err)
	}
	v.Cookie = cookie
	v.FolderFID = "music"
	v.FolderPath = "/音乐"
	source, err := saveQuarkFolder(ctx, lib, creds, client, v)
	if err != nil {
		t.Fatal(err)
	}
	all, err = lib.Sources(ctx)
	if err != nil || len(all) != 1 || all[0].QuarkFolderFID != "music" || all[0].QuarkFolderPath != "/音乐" {
		t.Fatalf("selected folder not persisted: %+v %v", all, err)
	}
	mgr, err := sources.NewManager(lib, creds, sources.ManagerOptions{Quark: client})
	if err != nil {
		t.Fatal(err)
	}
	syncer := sources.Syncer{Lib: lib, Manager: mgr}
	if _, err = syncer.Sync(ctx, source, nil); err != nil {
		t.Fatal(err)
	}
	tracks, err := lib.Tracks(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(tracks) != 1 || tracks[0].FilePath != "quark://song" {
		t.Fatalf("sync escaped selected folder: %+v", tracks)
	}
	// Changing an existing source keeps its identity and explicitly uses the new folder.
	v.Editing = source.ID
	v.Cookie = ""
	v.FolderFID = "empty"
	v.FolderPath = "/空文件夹"
	changed, err := saveQuarkFolder(ctx, lib, creds, client, v)
	if err != nil {
		t.Fatal(err)
	}
	if changed.ID != source.ID || changed.QuarkFolderFID != "empty" || changed.TrackCount != 1 {
		t.Fatalf("changing folder damaged source state: %+v", changed)
	}
	if _, err = syncer.Sync(ctx, changed, nil); err != nil {
		t.Fatal(err)
	}
	tracks, err = lib.Tracks(ctx)
	if err != nil || len(tracks) != 0 {
		t.Fatalf("empty-folder confirmation did not update library: %+v %v", tracks, err)
	}
}

func TestQuarkIncompleteAndExpiredListingsCannotCommit(t *testing.T) {
	lib, creds, client, mock := folderFixture(t)
	ctx := context.Background()
	v := model.SourceFormValues{Name: "音乐", Cookie: "__pus=mock-session; __puus=test", FolderFID: "music", FolderPath: "/音乐"}
	cancelled, stop := context.WithCancel(ctx)
	stop()
	if _, err := saveQuarkFolder(cancelled, lib, creds, client, v); err == nil {
		t.Fatal("cancelled confirmation saved a source")
	}
	mock.SetMalformedSort(true)
	if _, err := saveQuarkFolder(ctx, lib, creds, client, v); err == nil {
		t.Fatal("malformed folder was saved")
	}
	mock.SetMalformedSort(false)
	v.Cookie = "__pus=expired; __puus=test"
	if _, err := saveQuarkFolder(ctx, lib, creds, client, v); err == nil {
		t.Fatal("expired session saved a source")
	}
	all, err := lib.Sources(ctx)
	if err != nil || len(all) != 0 {
		t.Fatalf("failed confirmation changed library: %+v %v", all, err)
	}
}
