package sources

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/sourcemock"
)

// syncFixture is a WebDAV source wired through the production manager and
// syncer against the mock server.
type syncFixture struct {
	lib     *library.Library
	creds   *Credentials
	manager *Manager
	syncer  *Syncer
	source  library.Source
	mock    *sourcemock.WebDAV
}

func newSyncFixture(t *testing.T, server *sourcemock.WebDAV, httpServer *httptest.Server) *syncFixture {
	t.Helper()
	lib := newLibraryFixture(t)
	creds := NewCredentials(NewMemoryStore())
	source := library.Source{
		ID:             "src-webdav",
		Name:           "测试 WebDAV",
		Kind:           KindWebDAV,
		WebDAVURL:      httpServer.URL + "/dav/",
		WebDAVUsername: "user",
		SyncStatus:     "未同步",
	}
	seedSource(t, lib, source)
	if err := creds.SetWebDAVPassword(source.ID, "app-password"); err != nil {
		t.Fatalf("store password: %v", err)
	}
	manager, err := NewManager(lib, creds, ManagerOptions{
		HTTP:           httpServer.Client(),
		WebDAVRetry:    NoRetry,
		WebDAVThrottle: time.Millisecond,
	})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}
	return &syncFixture{
		lib:     lib,
		creds:   creds,
		manager: manager,
		syncer:  &Syncer{Lib: lib, Manager: manager},
		source:  source,
		mock:    server,
	}
}

func sourceCount(t *testing.T, lib *library.Library, sourceID string) int64 {
	t.Helper()
	count, err := lib.CountSourceTracks(context.Background(), sourceID)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	return count
}

func TestSyncCancelKeepsEveryTrack(t *testing.T) {
	mock, httpServer := newWebDAVMock(t, 120)
	fixture := newSyncFixture(t, mock, httpServer)

	first, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if first.Count != 120 || first.Merge.Added != 120 {
		t.Fatalf("first sync = %+v", first)
	}
	before := sourceCount(t, fixture.lib, fixture.source.ID)

	// Second sync, cancelled after five entries have been discovered.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	outcome, err := fixture.syncer.Sync(ctx, fixture.source, func(done int, _ string) {
		if done == 5 {
			cancel()
		}
	})
	if err != nil {
		t.Fatalf("cancelled sync returned an error: %v", err)
	}
	if !outcome.Scan.Cancelled {
		t.Fatal("outcome is not marked cancelled")
	}
	if outcome.Merge.Removed != 0 {
		t.Fatalf("cancelled sync removed %d tracks", outcome.Merge.Removed)
	}
	if !strings.HasPrefix(outcome.Status, "已取消（保留未扫描曲目") {
		t.Fatalf("status = %q", outcome.Status)
	}
	after := sourceCount(t, fixture.lib, fixture.source.ID)
	if after != before {
		t.Fatalf("track count changed on cancel: %d → %d", before, after)
	}
	// The database is the evidence, not the in-memory outcome.
	tracks, err := fixture.lib.Tracks(context.Background())
	if err != nil {
		t.Fatalf("tracks: %v", err)
	}
	if len(tracks) != 120 {
		t.Fatalf("library rows = %d, want 120", len(tracks))
	}
	row := storedSource(t, fixture.lib, fixture.source.ID)
	if row.SyncStatus != outcome.Status || row.TrackCount != 120 {
		t.Fatalf("source row = status %q count %d", row.SyncStatus, row.TrackCount)
	}
}

func TestSyncAuthoritativeSnapshotDeletesVanishedTracks(t *testing.T) {
	mock, httpServer := newWebDAVMock(t, 10)
	fixture := newSyncFixture(t, mock, httpServer)
	if _, err := fixture.syncer.Sync(context.Background(), fixture.source, nil); err != nil {
		t.Fatalf("first sync: %v", err)
	}

	removedPath := "/dav/专辑04/004 歌名004.wav"
	mock.Remove(removedPath)
	outcome, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if outcome.Merge.Removed != 1 {
		t.Fatalf("removed = %d, want 1", outcome.Merge.Removed)
	}
	if outcome.Count != 9 {
		t.Fatalf("count = %d, want 9", outcome.Count)
	}
	if outcome.Status != "已同步（新增 0 / 更新 0 / 移除 1）" {
		t.Fatalf("status = %q", outcome.Status)
	}
}

func TestSyncTruncatedSnapshotKeepsUnscannedTracks(t *testing.T) {
	// One shallow file plus a tree deeper than the 8-level default.
	files := map[string][]byte{
		"/dav/shallow.wav": sourcemock.WAV(1, 8000),
	}
	deep := "/dav"
	for level := 1; level <= 9; level++ {
		deep += fmt.Sprintf("/l%d", level)
	}
	files[deep+"/deep.wav"] = sourcemock.WAV(1, 8000)
	mock := sourcemock.NewWebDAV(files, "user", "app-password")
	httpServer := httptest.NewServer(mock)
	t.Cleanup(httpServer.Close)

	fixture := newSyncFixture(t, mock, httpServer)
	first, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if first.Count != 1 || !first.Scan.Truncated {
		t.Fatalf("first sync = count %d truncated %v reason %q", first.Count, first.Scan.Truncated, first.Scan.TruncationReason)
	}
	if first.Scan.TruncationReason != "目录层级超过 8 层" {
		t.Fatalf("reason = %q", first.Scan.TruncationReason)
	}
	if !strings.HasPrefix(first.Status, "部分同步（目录层级超过 8 层") {
		t.Fatalf("status = %q", first.Status)
	}

	// The only scanned file disappears: a truncated snapshot must not delete it.
	mock.Remove("/dav/shallow.wav")
	second, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if second.Merge.Removed != 0 || second.Count != 1 {
		t.Fatalf("truncated snapshot deleted tracks: %+v", second.Merge)
	}
}

func TestSyncCredentialFailureNeedsLoginAndRecovers(t *testing.T) {
	mock, httpServer := newWebDAVMock(t, 3)
	fixture := newSyncFixture(t, mock, httpServer)

	mock.SetMode(sourcemock.ModeUnauthorized)
	outcome, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err == nil {
		t.Fatal("rejected credential synced successfully")
	}
	if !outcome.NeedLogin {
		t.Fatalf("outcome does not ask for a re-login: %+v", outcome)
	}
	if outcome.Message != WebDAVUnauthorized {
		t.Fatalf("message = %q", outcome.Message)
	}
	if count := sourceCount(t, fixture.lib, fixture.source.ID); count != 0 {
		t.Fatalf("failed sync stored %d tracks", count)
	}
	row := storedSource(t, fixture.lib, fixture.source.ID)
	if row.SyncStatus != WebDAVUnauthorized {
		t.Fatalf("source status = %q", row.SyncStatus)
	}

	// Re-login: credentials are re-written (a new epoch), the mock accepts
	// again, and the same source id syncs without restarting anything.
	mock.SetMode(sourcemock.ModeAllow)
	if err := fixture.creds.SetWebDAVPassword(fixture.source.ID, "app-password"); err != nil {
		t.Fatalf("rewrite password: %v", err)
	}
	recovered, err := fixture.syncer.Sync(context.Background(), fixture.source, nil)
	if err != nil {
		t.Fatalf("sync after re-login: %v", err)
	}
	if recovered.NeedLogin || recovered.Count != 3 {
		t.Fatalf("recovered sync = %+v", recovered)
	}
	if row := storedSource(t, fixture.lib, fixture.source.ID); row.SyncStatus != recovered.Status {
		t.Fatalf("source status after recovery = %q", row.SyncStatus)
	}
}

func TestSyncMissingPasswordAsksForCredentials(t *testing.T) {
	_, httpServer := newWebDAVMock(t, 1)
	lib := newLibraryFixture(t)
	source := library.Source{
		ID:             "src-webdav",
		Name:           "没有密码",
		Kind:           KindWebDAV,
		WebDAVURL:      httpServer.URL + "/dav/",
		WebDAVUsername: "user",
	}
	seedSource(t, lib, source)
	manager, err := NewManager(lib, NewCredentials(NewMemoryStore()), ManagerOptions{HTTP: httpServer.Client(), WebDAVRetry: NoRetry})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}
	syncer := &Syncer{Lib: lib, Manager: manager}
	outcome, err := syncer.Sync(context.Background(), source, nil)
	if err == nil || !outcome.NeedLogin {
		t.Fatalf("missing password = outcome %+v err %v", outcome, err)
	}
	if outcome.Message != "WebDAV 密码未保存，请重新填写" {
		t.Fatalf("message = %q", outcome.Message)
	}
}

func TestSyncQuarkExpiredCookieMarksTheSource(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	lib := newLibraryFixture(t)
	source := library.Source{ID: "src-quark", Name: "夸克", Kind: KindQuark, QuarkFolderFID: "0"}
	seedSource(t, lib, source)
	manager, err := NewManager(lib, fixture.creds, ManagerOptions{
		Quark: fixture.client,
		HTTP:  fixture.server.Client(),
	})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}
	syncer := &Syncer{Lib: lib, Manager: manager}
	outcome, err := syncer.Sync(context.Background(), source, nil)
	if err != nil || outcome.Count != 3 {
		t.Fatalf("quark sync = %+v err %v", outcome, err)
	}

	fixture.mock.ExpireSession()
	outcome, err = syncer.Sync(context.Background(), source, nil)
	if err == nil || !outcome.NeedLogin {
		t.Fatalf("expired cookie = outcome %+v err %v", outcome, err)
	}
	if count := sourceCount(t, lib, source.ID); count != 3 {
		t.Fatalf("expired cookie deleted tracks: %d", count)
	}
	if row := storedSource(t, lib, source.ID); row.SyncStatus != QuarkUnauthenticatedMessage {
		t.Fatalf("source status = %q", row.SyncStatus)
	}
}
