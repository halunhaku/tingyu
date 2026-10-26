package sources

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/sourcemock"
)

// quarkFixture is one running mock drive plus the production client wired to
// it and a source adapter with a stored Cookie.
type quarkFixture struct {
	mock    *sourcemock.Quark
	server  *httptest.Server
	client  *QuarkClient
	creds   *Credentials
	source  *QuarkSource
	lib     *library.Library
	manager *Manager
}

func newQuarkFixture(t *testing.T, entries map[string][]sourcemock.QuarkEntry, media map[string][]byte) *quarkFixture {
	t.Helper()
	mock := sourcemock.NewQuark(sourcemock.QuarkOptions{Entries: entries, Media: media, Session: "mock-session"})
	server := httptest.NewServer(mock)
	t.Cleanup(server.Close)
	mock.SetBaseURL(server.URL)
	client, err := NewQuarkClient(QuarkOptions{
		HTTP:        server.Client(),
		PCBaseURL:   server.URL + "/api",
		CDNBaseURL:  server.URL + "/cdn",
		FolderDelay: time.Millisecond,
		Retry:       NoRetry,
	})
	if err != nil {
		t.Fatalf("NewQuarkClient: %v", err)
	}
	creds := NewCredentials(NewMemoryStore())
	if err := creds.SetQuarkCookie("src-quark", "__pus=mock-session; __puus=rotated"); err != nil {
		t.Fatalf("store cookie: %v", err)
	}
	source := NewQuarkSource(creds, client, QuarkSourceOptions{SourceID: "src-quark"})
	lib := newLibraryFixture(t)
	seedSource(t, lib, library.Source{ID: "src-quark", Name: "夸克", Kind: KindQuark, QuarkFolderFID: "0"})
	manager, err := NewManager(lib, creds, ManagerOptions{Quark: client, HTTP: server.Client()})
	if err != nil {
		t.Fatalf("manager: %v", err)
	}
	return &quarkFixture{mock: mock, server: server, client: client, creds: creds, source: source, lib: lib, manager: manager}
}

func sampleQuarkTree() (map[string][]sourcemock.QuarkEntry, map[string][]byte) {
	audio := sourcemock.WAV(2, 8000)
	entries := map[string][]sourcemock.QuarkEntry{
		"0": {
			{FID: "folder-1", Name: "周杰伦 - 叶惠美", Folder: true},
			{FID: "folder-2", Name: "其他", Folder: true},
			{FID: "file-0", Name: "01 晴天 - 周杰伦.mp3", Size: int64(len(audio)), Format: "mp3"},
			{FID: "note", Name: "readme.txt", Size: 10, Format: "txt"},
		},
		"folder-1": {
			{FID: "file-1", Name: "02 以父之名 - 周杰伦.flac", Size: int64(len(audio)), Format: "flac"},
		},
		"folder-2": {
			{FID: "nested", Name: "更深", Folder: true},
		},
		"nested": {
			{FID: "file-2", Name: "03 她的睫毛.wav", Size: int64(len(audio)), Format: "wav"},
		},
	}
	media := map[string][]byte{
		"file-0": audio,
		"file-1": audio,
		"file-2": audio,
	}
	return entries, media
}

func TestQuarkScanWalksFoldersAndSkipsNonAudio(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	result, err := fixture.source.Scan(context.Background(), nil)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(result.Tracks) != 3 {
		t.Fatalf("tracks = %d, want 3: %+v", len(result.Tracks), result.Tracks)
	}
	if !result.Authoritative() {
		t.Fatalf("scan not authoritative: %+v", result)
	}
	paths := map[string]bool{}
	for _, track := range result.Tracks {
		paths[track.FilePathOrURL] = true
		if track.Album != QuarkAlbum {
			t.Errorf("album = %q, want %q", track.Album, QuarkAlbum)
		}
	}
	for _, want := range []string{"quark://file-0", "quark://file-1", "quark://file-2"} {
		if !paths[want] {
			t.Errorf("missing %s in %v", want, paths)
		}
	}
	titles := map[string]string{}
	for _, track := range result.Tracks {
		titles[track.FilePathOrURL] = track.Title + "|" + track.Artist
	}
	if titles["quark://file-0"] != "晴天|周杰伦" {
		t.Errorf("file-0 parsed as %q", titles["quark://file-0"])
	}
}

func TestQuarkScanPaginatesLargeFolders(t *testing.T) {
	audio := sourcemock.WAV(1, 8000)
	children := make([]sourcemock.QuarkEntry, 0, 250)
	media := map[string][]byte{}
	for i := 0; i < 250; i++ {
		fid := fmt.Sprintf("bulk-%03d", i)
		children = append(children, sourcemock.QuarkEntry{
			FID: fid, Name: fmt.Sprintf("%03d 歌名%03d.wav", i, i),
			Size: int64(len(audio)), Format: "wav",
		})
		media[fid] = audio
	}
	fixture := newQuarkFixture(t, map[string][]sourcemock.QuarkEntry{"0": children}, media)
	result, err := fixture.source.Scan(context.Background(), nil)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(result.Tracks) != 250 {
		t.Fatalf("tracks = %d, want 250 (pagination)", len(result.Tracks))
	}
	if !result.Authoritative() {
		t.Fatalf("paged scan not authoritative: %+v", result)
	}
}

func TestQuarkIncompleteListingIsNotAuthoritative(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)

	fixture.mock.SetTotalLie(true)
	result, err := fixture.source.Scan(context.Background(), nil)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if !result.Truncated || result.Authoritative() {
		t.Fatalf("a folder whose total does not match must be truncated: %+v", result)
	}
	if !strings.Contains(result.TruncationReason, "目录未取全") {
		t.Fatalf("reason = %q", result.TruncationReason)
	}

	fixture.mock.SetTotalLie(false)
	fixture.mock.SetMalformedSort(true)
	result, err = fixture.source.Scan(context.Background(), nil)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if !result.Truncated || len(result.Tracks) != 0 {
		t.Fatalf("a malformed listing must be truncated, not empty: %+v", result)
	}
	if result.TruncationReason != "服务端返回了无法解析的目录内容" {
		t.Fatalf("reason = %q", result.TruncationReason)
	}
}

func TestQuarkExpiredCookieIsAReLogin(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	fixture.mock.ExpireSession()

	if _, err := fixture.source.Scan(context.Background(), nil); !IsAuth(err) || err.Error() != QuarkUnauthenticatedMessage {
		t.Fatalf("scan error = %v, want the re-login sentence", err)
	}
	check, err := fixture.source.CheckSession(context.Background())
	if err != nil {
		t.Fatalf("CheckSession: %v", err)
	}
	if check.State != QuarkSessionExpired {
		t.Fatalf("state = %v, want expired", check.State)
	}

	// A missing Cookie is the same kind of failure, without any request.
	empty := NewQuarkSource(NewCredentials(NewMemoryStore()), fixture.client, QuarkSourceOptions{SourceID: "src-quark"})
	if _, err := empty.Scan(context.Background(), nil); !IsAuth(err) {
		t.Fatalf("missing cookie error = %v", err)
	}
}

func TestQuarkDirectLinkRefreshAndPlaybackHeaders(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	playable, err := fixture.source.Open(context.Background(), "quark://file-0")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	for _, header := range []string{"Cookie", "User-Agent", "Referer", "Origin", "Accept"} {
		if playable.Headers[header] == "" {
			t.Errorf("playback header %s missing in %+v", header, playable.Headers)
		}
	}
	if !strings.Contains(playable.Headers["Cookie"], "__pus=mock-session") {
		t.Fatalf("Cookie header = %q", playable.Headers["Cookie"])
	}

	first := playable.URI
	if status := fetchWith(t, fixture.server.Client(), first, playable.Headers, "bytes=0-1023"); status != http.StatusPartialContent {
		t.Fatalf("first link status = %d, want 206", status)
	}

	// The link rotates (what an expired signature looks like): the old URL is
	// rejected, and refreshing the track mints a different one.
	fixture.mock.ExpireLink()
	if status := fetchWith(t, fixture.server.Client(), first, playable.Headers, "bytes=0-1023"); status != http.StatusForbidden {
		t.Fatalf("expired link status = %d, want 403", status)
	}
	fixture.source.Refresh("quark://file-0")
	refreshed, err := fixture.source.Open(context.Background(), "quark://file-0")
	if err != nil {
		t.Fatalf("Open after refresh: %v", err)
	}
	if refreshed.URI == first {
		t.Fatalf("refreshed link is identical: %q", refreshed.URI)
	}
	if status := fetchWith(t, fixture.server.Client(), refreshed.URI, refreshed.Headers, "bytes=0-1023"); status != http.StatusPartialContent {
		t.Fatalf("refreshed link status = %d, want 206", status)
	}
	if issues := fixture.mock.LinkIssues(); issues != 2 {
		t.Fatalf("link issuances = %d, want 2 (one per Open after invalidation)", issues)
	}
}

func TestQuarkCachesTheDirectLinkUntilInvalidated(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	first, err := fixture.source.Open(context.Background(), "quark://file-1")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	second, err := fixture.source.Open(context.Background(), "quark://file-1")
	if err != nil {
		t.Fatalf("Open again: %v", err)
	}
	if first.URI != second.URI {
		t.Fatalf("cached link changed: %q vs %q", first.URI, second.URI)
	}
	if issues := fixture.mock.LinkIssues(); issues != 1 {
		t.Fatalf("link issuances = %d, want 1 while cached", issues)
	}
	if _, err := fixture.source.Open(context.Background(), "quark://not-a-fid-format"); err == nil {
		t.Fatal("Open accepted a path without the quark scheme")
	}
}

func TestQuarkQRLoginFlow(t *testing.T) {
	mock := sourcemock.NewQuark(sourcemock.QuarkOptions{Session: "qr-session"})
	server := httptest.NewServer(mock)
	t.Cleanup(server.Close)
	mock.SetBaseURL(server.URL)
	login := NewQuarkQRLogin(QuarkQROptions{
		HTTP:      server.Client(),
		UOPBase:   server.URL + "/cas/ajax",
		PanBase:   server.URL + "/pan",
		DriveBase: server.URL + "/api",
	})
	ctx := context.Background()
	session, err := login.Start(ctx)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !strings.Contains(session.QRContent, "token=") || !strings.Contains(session.QRContent, "uc_param_str=") {
		t.Fatalf("QR content = %q", session.QRContent)
	}
	poll, err := login.Poll(ctx, session)
	if err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if poll.Phase != QuarkQRWaiting {
		t.Fatalf("phase before scan = %v (%s)", poll.Phase, poll.Message)
	}

	mock.ConfirmScan()
	poll, err = login.Poll(ctx, session)
	if err != nil {
		t.Fatalf("Poll after scan: %v", err)
	}
	if poll.Phase != QuarkQRScanned {
		t.Fatalf("phase after scan = %v (%s)", poll.Phase, poll.Message)
	}
	if !strings.Contains(poll.Cookie, "__pus=") {
		t.Fatalf("login cookie = %q", poll.Cookie)
	}
	if strings.Contains(poll.Cookie, "push_vurl") {
		t.Fatalf("housekeeping cookie kept: %q", poll.Cookie)
	}

	client, err := NewQuarkClient(QuarkOptions{HTTP: server.Client(), PCBaseURL: server.URL + "/api", CDNBaseURL: server.URL + "/cdn", Retry: NoRetry})
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	valid := NewQuarkSession(ParseQuarkCookie(poll.Cookie))
	if check := client.ValidateSession(ctx, valid); check.State != QuarkSessionValid {
		t.Fatalf("exchanged cookie not valid: %+v", check)
	}
}

func TestQuarkQRLoginCancel(t *testing.T) {
	mock := sourcemock.NewQuark(sourcemock.QuarkOptions{})
	server := httptest.NewServer(mock)
	t.Cleanup(server.Close)
	mock.SetBaseURL(server.URL)
	login := NewQuarkQRLogin(QuarkQROptions{HTTP: server.Client(), UOPBase: server.URL + "/cas/ajax", PanBase: server.URL + "/pan", DriveBase: server.URL + "/api"})
	session, err := login.Start(context.Background())
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	mock.CancelLogin()
	poll, err := login.Poll(context.Background(), session)
	if err != nil {
		t.Fatalf("Poll: %v", err)
	}
	if poll.Phase != QuarkQRFailed || poll.Message != "已在夸克 App 中取消登录" {
		t.Fatalf("cancel poll = %+v", poll)
	}
}

// fetchWith makes one ranged GET with the playback headers.
func fetchWith(t *testing.T, client *http.Client, uri string, headers map[string]string, byteRange string) int {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, uri, nil)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	if byteRange != "" {
		request.Header.Set("Range", byteRange)
	}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("GET %s: %v", uri, err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

// fakeRecoveryControl records what a replay would do, without an engine.
type fakeRecoveryControl struct {
	mu      sync.Mutex
	queue   []library.Track
	replays int
	start   int
	seek    time.Duration
	ready   bool
}

func (f *fakeRecoveryControl) Queue() []library.Track { return f.queue }
func (f *fakeRecoveryControl) PlayTracks(tracks []library.Track, start int) error {
	f.mu.Lock()
	f.replays++
	f.start = start
	f.mu.Unlock()
	return nil
}
func (f *fakeRecoveryControl) Seek(position time.Duration) error {
	f.mu.Lock()
	f.seek = position
	f.mu.Unlock()
	return nil
}
func (f *fakeRecoveryControl) Snapshot() player.Update {
	return player.Update{Snapshot: mpv.Snapshot{Processing: mpv.Ready}}
}

func TestRecovererRefreshesAnExpiredDirectLinkOnce(t *testing.T) {
	entries, media := sampleQuarkTree()
	fixture := newQuarkFixture(t, entries, media)
	control := &fakeRecoveryControl{queue: []library.Track{{
		ID: "t1", SourceID: "src-quark", FilePath: "quark://file-0", Title: "晴天",
	}}}
	recoverer := NewRecoverer(fixture.manager, control, nil)
	if !recoverer.Handle(player.Update{
		Track:    &control.queue[0],
		Failure:  &mpv.Failure{Kind: mpv.FailureUnauthorized, Status: 403, Message: "expired"},
		Snapshot: mpv.Snapshot{Position: 12 * time.Second},
	}) {
		t.Fatal("a 403 on a quark track did not start a refresh")
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		control.mu.Lock()
		seek := control.seek
		replays := control.replays
		control.mu.Unlock()
		if seek == 12*time.Second && replays == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no replay at 12s (replays=%d seek=%v)", replays, seek)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if issues := fixture.mock.LinkIssues(); issues != 0 {
		// No link was opened before the failure in this fake, so one issuance
		// only appears if the refresh minted one for a real Open.
		t.Logf("link issuances = %d", issues)
	}
	// The cooldown keeps a revoked login from becoming a retry loop.
	if recoverer.Handle(player.Update{
		Track:   &control.queue[0],
		Failure: &mpv.Failure{Kind: mpv.FailureUnauthorized, Status: 403},
	}) {
		t.Fatal("a second refresh started inside the cooldown")
	}
	// A non-Quark track, a network failure and a missing failure are ignored.
	if recoverer.Handle(player.Update{
		Track:   &library.Track{ID: "x", FilePath: "/tmp/a.flac"},
		Failure: &mpv.Failure{Kind: mpv.FailureUnauthorized},
	}) {
		t.Fatal("a local track started a direct-link refresh")
	}
	if recoverer.Handle(player.Update{
		Track:   &control.queue[0],
		Failure: &mpv.Failure{Kind: mpv.FailureNetwork},
	}) {
		t.Fatal("a network failure started a direct-link refresh")
	}
}
