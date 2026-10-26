// Package sourceaccept is the M3 acceptance harness: it drives the production
// source layer (internal/sources) against local mock servers that speak the
// WebDAV and Quark protocols, merges into a throwaway library, and plays
// through the production kernel (internal/mpv + internal/player) including the
// expired-direct-link recovery the app installs.
//
// It is a development tool. Nothing in the app imports it; it never opens the
// production library and never talks to the real WebDAV or Quark services.
package sourceaccept

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/sourcemock"
	"github.com/halunhaku/tingyu/client/internal/sources"
)

// Options configure a run.
type Options struct {
	// OutDir receives the report and request logs.
	OutDir string
	// Lib is the loaded libmpv.
	Lib *mpv.Lib
	// KeychainService overrides the Keychain service (default:
	// com.halunhaku.tingyu.sources.acceptance).
	KeychainService string
	// Logf receives progress lines.
	Logf func(string, ...any)
}

// Check is one acceptance item.
type Check struct {
	Name     string         `json:"name"`
	Goal     string         `json:"goal"`
	OK       bool           `json:"ok"`
	Detail   string         `json:"detail"`
	Evidence map[string]any `json:"evidence,omitempty"`
}

// Report is the whole run.
type Report struct {
	StartedAt   time.Time `json:"started_at"`
	FinishedAt  time.Time `json:"finished_at"`
	Host        Host      `json:"host"`
	Checks      []Check   `json:"checks"`
	LibraryPath string    `json:"library_path"`
	// ProductionSHA256Before/After prove the production library was not
	// written (equal, or empty when the machine has none).
	ProductionSHA256Before string `json:"production_sha256_before"`
	ProductionSHA256After  string `json:"production_sha256_after"`
	ProductionPath         string `json:"production_path"`
	KeychainService        string `json:"keychain_service"`
}

// Host records what ran the checks.
type Host struct {
	Go        string `json:"go"`
	OS        string `json:"os"`
	LibMPV    string `json:"libmpv_path"`
	MPVClient string `json:"mpv_client_api"`
}

// Add appends a check.
func (r *Report) Add(name, goal string, ok bool, detail string, evidence map[string]any) {
	r.Checks = append(r.Checks, Check{Name: name, Goal: goal, OK: ok, Detail: detail, Evidence: evidence})
}

// Failed returns the failing checks.
func (r *Report) Failed() []Check {
	var failed []Check
	for _, check := range r.Checks {
		if !check.OK {
			failed = append(failed, check)
		}
	}
	return failed
}

// Summary is the last lines of an acceptance run.
func (r *Report) Summary() string {
	passed := len(r.Checks) - len(r.Failed())
	var builder strings.Builder
	fmt.Fprintf(&builder, "M3 来源验收：%d/%d 通过，用时 %s\n", passed, len(r.Checks),
		r.FinishedAt.Sub(r.StartedAt).Round(time.Millisecond))
	for _, check := range r.Checks {
		status := "通过"
		if !check.OK {
			status = "失败"
		}
		fmt.Fprintf(&builder, "  [%s] %s — %s\n", status, check.Name, check.Detail)
	}
	return builder.String()
}

// Run performs the M3 acceptance.
func Run(options Options) (*Report, error) {
	log := options.Logf
	if log == nil {
		log = func(string, ...any) {}
	}
	if options.Lib == nil {
		return nil, fmt.Errorf("sourceaccept: no libmpv loaded")
	}
	if err := os.MkdirAll(options.OutDir, 0o755); err != nil {
		return nil, err
	}
	service := options.KeychainService
	if service == "" {
		service = "com.halunhaku.tingyu.sources.acceptance"
	}
	report := &Report{
		StartedAt:       time.Now(),
		KeychainService: service,
		Host: Host{
			Go:     runtime.Version() + " " + runtime.GOOS + "/" + runtime.GOARCH,
			OS:     hostOS(),
			LibMPV: mpv.LibraryPath(),
		},
	}
	apiVersion := options.Lib.ClientAPIVersion()
	report.Host.MPVClient = fmt.Sprintf("%d.%d", int(apiVersion>>16), int(apiVersion&0xffff))

	// The production library is fingerprinted before anything opens a database.
	productionPath := ""
	if dataDir, err := library.DataDir(); err == nil {
		productionPath = library.Path(dataDir)
		report.ProductionPath = productionPath
		report.ProductionSHA256Before = sha256File(productionPath)
	}

	lib, err := createLibrary(filepath.Join(options.OutDir, "data"))
	if err != nil {
		return nil, err
	}
	defer lib.Close()
	report.LibraryPath = lib.Path()

	creds := sources.NewCredentials(sources.Keychain{Service: service})
	defer func() {
		_ = creds.DeleteWebDAVPassword("src-webdav")
		_ = creds.DeleteQuarkCookie("src-quark")
	}()

	// --- WebDAV ---------------------------------------------------
	webdavAudio := sourcemock.WAV(30, 48000)
	webdavFiles := map[string][]byte{}
	for i := 0; i < 120; i++ {
		webdavFiles[fmt.Sprintf("/dav/专辑%02d/%03d 歌名%03d.wav", i%6, i, i)] = webdavAudio
	}
	var webdavMock *sourcemock.WebDAV
	var quarkMock *sourcemock.Quark
	defer func() { writeEvidence(options.OutDir, webdavMock, quarkMock) }()
	webdavMock = sourcemock.NewWebDAV(webdavFiles, "tingyu", webdavPassword)
	webdavServer := httptest.NewServer(webdavMock)
	defer webdavServer.Close()

	manager, err := sources.NewManager(lib, creds, sources.ManagerOptions{
		HTTP:           webdavServer.Client(),
		WebDAVRetry:    sources.NoRetry,
		WebDAVThrottle: time.Millisecond,
		Logf:           log,
	})
	if err != nil {
		return nil, err
	}
	syncer := &sources.Syncer{Lib: lib, Manager: manager, Logf: log}

	webdavSource := library.Source{
		ID:             "src-webdav",
		Name:           "M3 验收 WebDAV",
		Kind:           sources.KindWebDAV,
		WebDAVURL:      webdavServer.URL + "/dav/",
		WebDAVUsername: "tingyu",
		SyncStatus:     "未同步",
	}
	started := time.Now()
	if err := creds.SetWebDAVPassword(webdavSource.ID, webdavPassword); err != nil {
		return nil, fmt.Errorf("keychain: store WebDAV password: %w", err)
	}
	if err := lib.UpsertSource(context.Background(), webdavSource); err != nil {
		return nil, err
	}
	// What the form does first: a Depth:0 PROPFIND with the credential.
	probe, err := sources.NewWebDAV(webdavSource.ID, sources.WebDAVOptions{
		RootURL: webdavSource.WebDAVURL, Username: webdavSource.WebDAVUsername,
		Password: webdavPassword, HTTP: webdavServer.Client(), Retry: sources.NoRetry,
	})
	if err != nil {
		return nil, err
	}
	if err := probe.TestConnection(context.Background()); err != nil {
		report.Add("webdav-add", "添加 WebDAV 来源", false, err.Error(), nil)
		return report, nil
	}
	report.Add("webdav-add", "添加 WebDAV 来源（地址/账号/密码 → Depth:0 探测通过）", true,
		fmt.Sprintf("连接探测通过，用时 %s；密码写入 Keychain 服务 %s", time.Since(started).Round(time.Millisecond), service),
		map[string]any{"root": webdavSource.WebDAVURL, "probe_ms": time.Since(started).Milliseconds()})

	// --- WebDAV scan: 120 tracks ---------------------------------
	syncStart := time.Now()
	outcome, err := syncer.Sync(context.Background(), webdavSource, nil)
	countWebDAV := sourceCount(lib, webdavSource.ID)
	report.Add("webdav-scan", "加 WebDAV 来源 → 120 首入库", err == nil && countWebDAV == 120,
		describeSync(outcome, err, countWebDAV, syncStart),
		map[string]any{
			"tracks_found": len(outcome.Scan.Tracks), "stored": countWebDAV,
			"merge":  mergeEvidence(outcome.Merge),
			"status": outcome.Status, "elapsed_ms": time.Since(syncStart).Milliseconds(),
		})
	if err != nil {
		return finish(report, productionPath, log)
	}

	// --- WebDAV playback + seek ----------------------------------
	playReport := reportWebDAVPlayback(options.Lib, manager, lib, webdavSource, webdavMock, log)
	report.Checks = append(report.Checks, playReport...)

	// --- WebDAV re-login -----------------------------------------
	webdavMock.SetMode(sourcemock.ModeUnauthorized)
	failed, failErr := syncer.Sync(context.Background(), webdavSource, nil)
	reloginOK := failErr != nil && failed.NeedLogin && failed.Message == sources.WebDAVUnauthorized
	row := storedSource(lib, webdavSource.ID)
	webdavMock.SetMode(sourcemock.ModeAllow)
	_ = creds.SetWebDAVPassword(webdavSource.ID, webdavPassword)
	recovered, recoverErr := syncer.Sync(context.Background(), webdavSource, nil)
	reloginOK = reloginOK && recoverErr == nil && recovered.Status != "" && sourceCount(lib, webdavSource.ID) == 120
	report.Add("webdav-relogin", "凭据失效 → 出现重新登录入口；重填后恢复", reloginOK,
		fmt.Sprintf("失效时 needLogin=%v 文案=%q 来源状态=%q；重填后 %s",
			failed.NeedLogin, failed.Message, row.SyncStatus, recovered.Status),
		map[string]any{"need_login": failed.NeedLogin, "message": failed.Message,
			"stored_status": row.SyncStatus, "recovered_status": recovered.Status,
			"recovered_err": errorText(recoverErr)})

	// --- Cancel keeps the count ----------------------------------
	before := sourceCount(lib, webdavSource.ID)
	ctx, cancel := context.WithCancel(context.Background())
	cancelled, cancelErr := syncer.Sync(ctx, webdavSource, func(done int, _ string) {
		if done == 5 {
			cancel()
		}
	})
	cancel()
	after := sourceCount(lib, webdavSource.ID)
	rows := totalRows(lib)
	cancelOK := cancelErr == nil && cancelled.Scan.Cancelled && cancelled.Merge.Removed == 0 &&
		before == after && rows == 120
	report.Add("sync-cancel", "取消同步后曲目数不变（含数据库计数）", cancelOK,
		fmt.Sprintf("取消前 %d 首 → 取消后 %d 首；merge.removed=%d；库内总行数 %d；状态 %q",
			before, after, cancelled.Merge.Removed, rows, cancelled.Status),
		map[string]any{"before": before, "after": after, "removed": cancelled.Merge.Removed,
			"library_rows": rows, "status": cancelled.Status, "cancelled": cancelled.Scan.Cancelled,
			"query": "SELECT COUNT(*) FROM tracks", "error": errorText(cancelErr)})

	// --- Quark ---------------------------------------------------
	quarkAudio := sourcemock.WAV(120, 48000)
	quarkEntries, quarkMedia := quarkTree(quarkAudio)
	quarkMock = sourcemock.NewQuark(sourcemock.QuarkOptions{
		Entries: quarkEntries, Media: quarkMedia, Session: "m3-session",
	})
	quarkServer := httptest.NewServer(quarkMock)
	defer quarkServer.Close()
	quarkMock.SetBaseURL(quarkServer.URL)

	quarkClient, err := sources.NewQuarkClient(sources.QuarkOptions{
		HTTP:        quarkServer.Client(),
		PCBaseURL:   quarkServer.URL + "/api",
		CDNBaseURL:  quarkServer.URL + "/cdn",
		FolderDelay: time.Millisecond,
		Retry:       sources.NoRetry,
		Logf:        log,
	})
	if err != nil {
		return nil, err
	}
	quarkManager, err := sources.NewManager(lib, creds, sources.ManagerOptions{
		Quark: quarkClient,
		QR: sources.NewQuarkQRLogin(sources.QuarkQROptions{
			HTTP:      quarkServer.Client(),
			UOPBase:   quarkServer.URL + "/cas/ajax",
			PanBase:   quarkServer.URL + "/pan",
			DriveBase: quarkServer.URL + "/api",
			Logf:      log,
		}),
		HTTP: quarkServer.Client(),
		Logf: log,
	})
	if err != nil {
		return nil, err
	}
	quarkSyncer := &sources.Syncer{Lib: lib, Manager: quarkManager, Logf: log}

	// QR login: request → waiting → confirm → cookie.
	qrStart := time.Now()
	qrSession, qrErr := quarkManager.QRLogin().Start(context.Background())
	if qrErr != nil {
		report.Add("quark-qr-login", "夸克扫码登录 → 拿 Cookie", false, qrErr.Error(), nil)
	} else {
		first, _ := quarkManager.QRLogin().Poll(context.Background(), qrSession)
		quarkMock.ConfirmScan()
		confirmed, pollErr := quarkManager.QRLogin().Poll(context.Background(), qrSession)
		loginOK := pollErr == nil && confirmed.Phase == sources.QuarkQRScanned && strings.Contains(confirmed.Cookie, "__pus=") && first.Phase == sources.QuarkQRWaiting
		cookieStored := false
		if loginOK {
			cookieStored = creds.SetQuarkCookie("src-quark", confirmed.Cookie) == nil
		}
		quarkSource := library.Source{
			ID: "src-quark", Name: "M3 验收夸克", Kind: sources.KindQuark,
			QuarkFolderFID: "0", QuarkAccountName: "夸克用户", SyncStatus: "未同步",
		}
		upsertErr := lib.UpsertSource(context.Background(), quarkSource)
		report.Add("quark-qr-login", "夸克扫码登录 → 拿到 Cookie 并写入 Keychain", loginOK && cookieStored && upsertErr == nil,
			fmt.Sprintf("扫码前 %v，确认后 %v；Cookie %d 字节 / %d 项；cookie 写入=%v",
				first.Phase, confirmed.Phase, len(confirmed.Cookie), len(sources.ParseQuarkCookie(confirmed.Cookie).Names()), cookieStored),
			map[string]any{
				"first_phase": first.Phase.String(), "phase": confirmed.Phase.String(),
				"cookie_bytes":   len(confirmed.Cookie),
				"cookie_names":   sources.ParseQuarkCookie(confirmed.Cookie).Names(),
				"qr_content_len": len(qrSession.QRContent),
				"qr_content_has": strings.Contains(qrSession.QRContent, "token=") && strings.Contains(qrSession.QRContent, "uc_param_str="),
				"elapsed_ms":     time.Since(qrStart).Milliseconds(),
				"error":          errorText(qrErr),
			})
		if loginOK && upsertErr == nil {
			quarkSyncStart := time.Now()
			quarkOutcome, quarkErr := quarkSyncer.Sync(context.Background(), quarkSource, nil)
			quarkCount := sourceCount(lib, quarkSource.ID)
			wantQuark := len(quarkMedia)
			report.Add("quark-scan", "夸克列目录 → 入库", quarkErr == nil && quarkCount == int64(wantQuark),
				describeSync(quarkOutcome, quarkErr, quarkCount, quarkSyncStart),
				map[string]any{"tracks_found": len(quarkOutcome.Scan.Tracks), "stored": quarkCount,
					"want": wantQuark, "status": quarkOutcome.Status,
					"merge": mergeEvidence(quarkOutcome.Merge), "elapsed_ms": time.Since(quarkSyncStart).Milliseconds()})
			if quarkErr == nil {
				report.Checks = append(report.Checks, reportQuarkPlayback(options.Lib, quarkManager, lib, quarkSource, quarkMock, log)...)
				report.Checks = append(report.Checks, reportQuarkRelogin(quarkSyncer, quarkManager, lib, quarkSource, quarkMock, creds, log)...)
			}
		}
	}

	// --- Credentials ---------------------------------------------
	report.Checks = append(report.Checks, reportCredentials(creds, lib, service, log)...)

	return finish(report, productionPath, log)
}

// finish fingerprints the production library again and stamps the report.
func finish(report *Report, productionPath string, log func(string, ...any)) (*Report, error) {
	report.ProductionSHA256After = sha256File(productionPath)
	report.FinishedAt = time.Now()
	log("sources: acceptance finished: %d checks, %d failed", len(report.Checks), len(report.Failed()))
	return report, nil
}

// webdavPassword is the throwaway credential the mock accepts.
const webdavPassword = "m3-app-password"

// --- helpers --------------------------------------------------------

func createLibrary(dir string) (*library.Library, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "library.sqlite")
	ctx := context.Background()
	db, err := sqlite.Open(ctx, path, sqlite.OpenOptions{})
	if err != nil {
		return nil, fmt.Errorf("create fixture library: %w", err)
	}
	if _, err := db.Execute(ctx, "PRAGMA user_version = 2"); err != nil {
		db.Close()
		return nil, fmt.Errorf("set user_version: %w", err)
	}
	db.Close()
	return library.OpenWritable(ctx, path)
}

func quarkTree(audio []byte) (map[string][]sourcemock.QuarkEntry, map[string][]byte) {
	entries := map[string][]sourcemock.QuarkEntry{
		"0": {
			{FID: "folder-1", Name: "周杰伦 - 叶惠美", Folder: true},
			{FID: "folder-2", Name: "其他", Folder: true},
			{FID: "file-0", Name: "01 晴天 - 周杰伦.mp3", Size: int64(len(audio)), Format: "mp3"},
			{FID: "note", Name: "readme.txt", Size: 10, Format: "txt"},
		},
		"folder-1": {
			{FID: "file-1", Name: "02 以父之名 - 周杰伦.flac", Size: int64(len(audio)), Format: "flac"},
			{FID: "file-2", Name: "03 她的睫毛 - 周杰伦.wav", Size: int64(len(audio)), Format: "wav"},
		},
		"folder-2": {
			{FID: "file-3", Name: "04 园游会 - 周杰伦.mp3", Size: int64(len(audio)), Format: "mp3"},
		},
	}
	media := map[string][]byte{
		"file-0": audio, "file-1": audio, "file-2": audio, "file-3": audio,
	}
	return entries, media
}

func sourceCount(lib *library.Library, sourceID string) int64 {
	count, err := lib.CountSourceTracks(context.Background(), sourceID)
	if err != nil {
		return -1
	}
	return count
}

func totalRows(lib *library.Library) int {
	tracks, err := lib.Tracks(context.Background())
	if err != nil {
		return -1
	}
	return len(tracks)
}

func storedSource(lib *library.Library, sourceID string) library.Source {
	sourcses, err := lib.Sources(context.Background())
	if err != nil {
		return library.Source{}
	}
	for _, source := range sourcses {
		if source.ID == sourceID {
			return source
		}
	}
	return library.Source{}
}

func describeSync(outcome sources.SyncOutcome, err error, count int64, started time.Time) string {
	if err != nil {
		return fmt.Sprintf("同步失败：%v（入库 %d）", err, count)
	}
	return fmt.Sprintf("%s；入库 %d 首，用时 %s", outcome.Status, count, time.Since(started).Round(time.Millisecond))
}

func mergeEvidence(merge library.MergeResult) map[string]any {
	return map[string]any{"added": merge.Added, "updated": merge.Updated, "removed": merge.Removed}
}

func errorText(err error) any {
	if err == nil {
		return ""
	}
	return err.Error()
}

func sha256File(path string) string {
	if path == "" {
		return ""
	}
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return ""
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func hostOS() string {
	output, err := exec.Command("sw_vers", "-productVersion").Output()
	if err != nil {
		return runtime.GOOS
	}
	return "macOS " + strings.TrimSpace(string(output))
}

// keychainLookup asks the login Keychain for an item's attributes. It prints
// attributes only, never the secret (a `-w` flag would print the password).
func keychainLookup(service, account string) (string, bool) {
	output, err := exec.Command("security", "find-generic-password", "-s", service, "-a", account).CombinedOutput()
	text := strings.TrimSpace(string(output))
	if err != nil {
		return text, false
	}
	return text, true
}

// reportCredentials proves the secrets are in the Keychain and nowhere in the
// data directory.
func reportCredentials(creds *sources.Credentials, lib *library.Library, service string, log func(string, ...any)) []Check {
	password, passwordFound, passwordErr := creds.WebDAVPassword("src-webdav")
	cookie, cookieFound, cookieErr := creds.QuarkCookie("src-quark")
	_, passwordInKeychain := keychainLookup(service, "webdav_password_src-webdav")
	_, cookieInKeychain := keychainLookup(service, "quark_cookie_src-quark")

	// No file under the data directory may contain either secret.
	dataDir := filepath.Dir(lib.Path())
	leaked := 0
	_ = filepath.WalkDir(dataDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		info, statErr := entry.Info()
		if statErr != nil || info.Size() > 8<<20 {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		if strings.Contains(string(data), password) || strings.Contains(string(data), cookie) {
			leaked++
			log("sources: SECRET FOUND IN FILE %s", path)
		}
		return nil
	})

	ok := passwordFound && cookieFound && passwordInKeychain && cookieInKeychain &&
		passwordErr == nil && cookieErr == nil && leaked == 0 && password != "" && cookie != ""
	detail := fmt.Sprintf("Keychain：WebDAV 密码与夸克 Cookie 均可读回（密码 %d 字节，Cookie %d 字节）；security 查询命中=%v/%v；数据目录明文命中 %d 个文件",
		len(password), len(cookie), passwordInKeychain, cookieInKeychain, leaked)
	return []Check{{
		Name: "credentials-keychain", Goal: "凭据只存系统钥匙串、不落明文", OK: ok, Detail: detail,
		Evidence: map[string]any{
			"service":        service,
			"accounts":       []string{"webdav_password_src-webdav", "quark_cookie_src-quark"},
			"password_bytes": len(password), "cookie_bytes": len(cookie),
			"security_found":  map[string]bool{"webdav_password_src-webdav": passwordInKeychain, "quark_cookie_src-quark": cookieInKeychain},
			"plaintext_files": leaked,
			"data_dir":        dataDir,
			"errors":          []string{errorString(passwordErr), errorString(cookieErr)},
		},
	}}
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// writeJSONL writes one JSON object per line.
func writeRequests(path string, values any) error {
	encoded, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, encoded, 0o644)
}

// Write stores the report as report.json.
func (r *Report) Write(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "report.json")
	encoded, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		return "", err
	}
	return path, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// session drives one real engine and controller, exactly as the app does.
type session struct {
	engine  *mpv.Player
	control *player.Controller
	log     func(string, ...any)
}

func newSession(lib *mpv.Lib, manager *sources.Manager, log func(string, ...any), onUpdate func(player.Update)) (*session, error) {
	engine, err := mpv.NewPlayer(lib, mpv.Config{AudioClientName: "听屿M3", Debug: log})
	if err != nil {
		return nil, err
	}
	resolver := func(track library.Track) (player.Item, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		playable, resolveErr := manager.Resolve(ctx, track)
		if resolveErr != nil {
			return player.Item{}, resolveErr
		}
		return player.Item{
			ID: track.ID, TrackID: track.ID, URI: playable.URI, Headers: playable.Headers,
			Title: track.Title, Artist: track.Artist, Album: track.Album, Duration: track.Duration,
		}, nil
	}
	control := player.New(engine, resolver, nil)
	control.SetListener(onUpdate)
	return &session{engine: engine, control: control, log: log}, nil
}

func (s *session) close() {
	if s.control != nil {
		_ = s.control.Close()
		return
	}
	if s.engine != nil {
		_ = s.engine.Close()
	}
}

// waitFor polls the controller until cond holds or the timeout expires.
func (s *session) waitFor(timeout time.Duration, cond func(player.Update) bool) (player.Update, bool) {
	deadline := time.Now().Add(timeout)
	for {
		update := s.control.Snapshot()
		if cond(update) {
			return update, true
		}
		if time.Now().After(deadline) {
			return update, false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// waitIdle waits until no load is pending (used between playbacks).
func (s *session) waitIdle(timeout time.Duration) {
	_, _ = s.waitFor(timeout, func(update player.Update) bool {
		return update.Snapshot.Processing != mpv.Loading
	})
}

func remoteTracks(lib *library.Library, sourceID string) []library.Track {
	tracks, err := lib.Tracks(context.Background())
	if err != nil {
		return nil
	}
	out := make([]library.Track, 0, len(tracks))
	for _, track := range tracks {
		if track.SourceID == sourceID {
			out = append(out, track)
		}
	}
	return out
}

// writeEvidence dumps the request logs next to the report.
func writeEvidence(dir string, webdavMock *sourcemock.WebDAV, quarkMock *sourcemock.Quark) {
	if webdavMock != nil {
		_ = writeRequests(filepath.Join(dir, "webdav-requests.json"), webdavMock.Records())
	}
	if quarkMock != nil {
		_ = writeRequests(filepath.Join(dir, "quark-requests.json"), quarkMock.Records())
	}
}
