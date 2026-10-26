package sourceaccept

// The playback halves of the M3 acceptance: a remote track through the real
// kernel (Range + per-track headers), and a Quark direct link that expires
// mid-playback and is refreshed by the same Recoverer the app installs.

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/mpv"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/sourcemock"
	"github.com/halunhaku/tingyu/client/internal/sources"
)

// webdavRequestSample is one request line in the evidence.
func webdavRequestSample(records []sourcemock.Request, limit int) []map[string]any {
	out := make([]map[string]any, 0, limit)
	for i := len(records) - 1; i >= 0 && len(out) < limit; i-- {
		record := records[i]
		if record.Method != "GET" && record.Method != "HEAD" {
			continue
		}
		out = append(out, map[string]any{
			"method": record.Method, "path": record.Path, "range": record.Range,
			"auth": record.Authorization != "", "status": record.Status, "bytes": record.Bytes,
		})
	}
	return out
}

// reportWebDAVPlayback plays a scanned remote track, seeks inside it, and
// returns the evidence that libmpv — not Go — fetched it with Range and the
// per-track Basic header.
func reportWebDAVPlayback(lib *mpv.Lib, manager *sources.Manager, db *library.Library, source library.Source, mock *sourcemock.WebDAV, log func(string, ...any)) []Check {
	tracks := remoteTracks(db, source.ID)
	if len(tracks) == 0 {
		return []Check{{Name: "webdav-play", Goal: "远端曲目可播可 seek", OK: false, Detail: "来源没有曲目"}}
	}
	mock.ResetRecords()
	started := time.Now()
	var mu sync.Mutex
	var soundAt time.Time
	var lastPosition time.Duration
	playErr := error(nil)
	sess, err := newSession(lib, manager, log, func(update player.Update) {
		if update.Track == nil || !update.Snapshot.Playing {
			return
		}
		mu.Lock()
		lastPosition = update.Snapshot.Position
		if soundAt.IsZero() && update.Snapshot.Position > 0 {
			soundAt = time.Now()
		}
		mu.Unlock()
	})
	if err != nil {
		return []Check{{Name: "webdav-play", Goal: "远端曲目可播可 seek", OK: false, Detail: err.Error()}}
	}
	defer sess.close()

	track := tracks[0]
	if err := sess.control.PlayTracks(tracks, 0); err != nil {
		return []Check{{Name: "webdav-play", Goal: "远端曲目可播可 seek", OK: false, Detail: "起播失败：" + err.Error()}}
	}
	played, playingOK := sess.waitFor(25*time.Second, func(update player.Update) bool {
		return update.Snapshot.Playing && update.Snapshot.Position > 500*time.Millisecond
	})
	seekTarget := 10 * time.Second
	if playingOK {
		playErr = sess.control.Seek(seekTarget)
	}
	seeked, seekOK := sess.waitFor(20*time.Second, func(update player.Update) bool {
		return update.Snapshot.Position >= seekTarget && update.Snapshot.Position < seekTarget+6*time.Second
	})
	time.Sleep(700 * time.Millisecond)
	advanced := sess.control.Snapshot()
	mu.Lock()
	soundDelay := time.Duration(0)
	if !soundAt.IsZero() {
		soundDelay = soundAt.Sub(started)
	}
	finalPosition := lastPosition
	mu.Unlock()

	records := mock.Records()
	gets, withAuth, withRange, partial := 0, 0, 0, 0
	for _, record := range records {
		if record.Method != "GET" {
			continue
		}
		gets++
		if strings.HasPrefix(record.Authorization, "Basic ") {
			withAuth++
		}
		if record.Range != "" {
			withRange++
		}
		if record.Status == 206 {
			partial++
		}
	}
	ok := playErr == nil && playingOK && seekOK && gets > 0 && withAuth == gets && withRange == gets && partial > 0 &&
		advanced.Snapshot.Position > seekTarget
	detail := fmt.Sprintf("%q：起播 %.2fs，seek 到 %.0fs 落点 %.2fs，之后推进到 %.2fs；服务端 GET %d 次（带 Range %d、带 Basic %d、206 %d）",
		track.Title, played.Snapshot.Position.Seconds(), seekTarget.Seconds(), seeked.Snapshot.Position.Seconds(),
		advanced.Snapshot.Position.Seconds(), gets, withRange, withAuth, partial)
	return []Check{{
		Name: "webdav-play", Goal: "远端曲目可播可 seek，服务端可见 Range + 按曲目鉴权头", OK: ok, Detail: detail,
		Evidence: map[string]any{
			"track": track.Title, "uri_host": hostOf(track.FilePath),
			"played_position":     played.Snapshot.Position.Seconds(),
			"seek_target":         seekTarget.Seconds(),
			"position_after_seek": seeked.Snapshot.Position.Seconds(),
			"position_advanced":   advanced.Snapshot.Position.Seconds(),
			"final_position":      finalPosition.Seconds(),
			"sound_after_ms":      soundDelay.Milliseconds(),
			"gets":                gets, "gets_with_range": withRange, "gets_with_basic": withAuth, "partial_206": partial,
			"requests":   webdavRequestSample(records, 6),
			"elapsed_ms": time.Since(started).Milliseconds(),
		},
	}}
}

// reportQuarkPlayback plays a Quark track, then makes the direct link of the
// next track expire before it loads: the load is rejected with 403, the
// Recoverer mints a new link and replays, and audio starts. This is the
// reproducible form of "直链过期后自动刷新并继续播放": the failure happens at
// load, where the kernel reports it. (A 403 while the current track is already
// streaming does not surface as a Failure at all — mpv only logs a failed seek
// and keeps playing from its cache; see the M3 record.)
func reportQuarkPlayback(lib *mpv.Lib, manager *sources.Manager, db *library.Library, source library.Source, mock *sourcemock.Quark, log func(string, ...any)) []Check {
	tracks := remoteTracks(db, source.ID)
	if len(tracks) < 2 {
		return []Check{{Name: "quark-play-refresh", Goal: "夸克直链播放与过期刷新", OK: false, Detail: "来源曲目不足两首"}}
	}
	mock.ResetRecords()
	started := time.Now()
	var mu sync.Mutex
	failureMessage := ""
	failureStatus := 0
	refreshStarted := false
	var recoverer *sources.Recoverer
	sess, err := newSession(lib, manager, log, func(update player.Update) {
		mu.Lock()
		if update.Failure != nil {
			failureMessage = update.Failure.Message
			failureStatus = update.Failure.Status
		}
		mu.Unlock()
		if recoverer != nil && recoverer.Handle(update) {
			mu.Lock()
			refreshStarted = true
			mu.Unlock()
		}
	})
	if err != nil {
		return []Check{{Name: "quark-play-refresh", Goal: "夸克直链播放与过期刷新", OK: false, Detail: err.Error()}}
	}
	defer sess.close()
	recoverer = sources.NewRecoverer(manager, sess.control, log)

	// 1. A normal track plays through its direct link.
	if err := sess.control.PlayTracks(tracks, 0); err != nil {
		return []Check{{Name: "quark-play-refresh", Goal: "夸克直链播放与过期刷新", OK: false, Detail: "起播失败：" + err.Error()}}
	}
	played, playingOK := sess.waitFor(25*time.Second, func(update player.Update) bool {
		return update.Snapshot.Playing && update.Snapshot.Position > 500*time.Millisecond
	})

	// 2. The next track's link was already minted by the prefetch; expire every
	// link, then switch to it. Its load now hits a stale signature.
	next := tracks[1]
	mock.ExpireLink()
	issuesBefore := mock.LinkIssues()
	if playingOK {
		_ = sess.control.PlayTracks(tracks, 1)
	}
	_, recovered := sess.waitFor(30*time.Second, func(update player.Update) bool {
		mu.Lock()
		startedRefresh := refreshStarted
		mu.Unlock()
		return startedRefresh && update.Track != nil && update.Track.ID == next.ID &&
			update.Snapshot.Playing && update.Snapshot.Position > 300*time.Millisecond &&
			mock.LinkIssues() > issuesBefore
	})
	time.Sleep(500 * time.Millisecond)
	final := sess.control.Snapshot()

	records := mock.Records()
	rejected := 0
	staleToken := ""
	for _, record := range records {
		if strings.Contains(record.Path, "/cdn/download/") && record.Status == 403 {
			rejected++
			if staleToken == "" {
				staleToken = queryValue(record.Query, "token")
			}
		}
	}
	secondToken := ""
	for _, record := range records {
		if !strings.Contains(record.Path, "/cdn/download/") || record.Status != 206 {
			continue
		}
		if token := queryValue(record.Query, "token"); token != "" && token != staleToken {
			secondToken = token
		}
	}
	mu.Lock()
	message, status, refresh := failureMessage, failureStatus, refreshStarted
	mu.Unlock()

	ok := playingOK && recovered && rejected > 0 && secondToken != "" && refresh &&
		final.Snapshot.Playing && final.Snapshot.Position > 300*time.Millisecond
	detail := fmt.Sprintf("首播 %q %.2fs；过期后切到 %q 首次加载被拒 %d 次（HTTP %d：%s），自动刷新=%v，新直链 %s 返回 206，出声位置 %.2fs",
		tracks[0].Title, played.Snapshot.Position.Seconds(), next.Title, rejected, status, message,
		refresh, shortToken(secondToken), final.Snapshot.Position.Seconds())
	return []Check{{
		Name: "quark-play-refresh", Goal: "夸克直链可播；直链过期后自动刷新并继续播放（日志为证）", OK: ok, Detail: detail,
		Evidence: map[string]any{
			"first_track": tracks[0].Title, "first_played_position": played.Snapshot.Position.Seconds(),
			"next_track": next.Title, "final_position": final.Snapshot.Position.Seconds(),
			"playing_after_recovery": final.Snapshot.Playing,
			"failure_message":        message, "failure_status": status,
			"refresh_started": refresh, "http_403": rejected,
			"stale_link_token":      shortToken(staleToken),
			"fresh_link_token":      shortToken(secondToken),
			"link_issuances_before": issuesBefore, "link_issuances_after": mock.LinkIssues(),
			"requests":   mediaRequestSample(records, 8),
			"elapsed_ms": time.Since(started).Milliseconds(),
		},
	}}
}

// reportQuarkRelogin expires the session, checks the re-login state, logs in
// again through the QR flow and syncs.
func reportQuarkRelogin(syncer *sources.Syncer, manager *sources.Manager, db *library.Library, source library.Source, mock *sourcemock.Quark, creds *sources.Credentials, log func(string, ...any)) []Check {
	before := sourceCount(db, source.ID)
	mock.ExpireSession()
	failed, failErr := syncer.Sync(context.Background(), source, nil)
	row := storedSource(db, source.ID)
	afterFail := sourceCount(db, source.ID)

	loginErr := error(nil)
	reloginOK := false
	cookieBytes := 0
	if session, err := manager.QRLogin().Start(context.Background()); err == nil {
		mock.ConfirmScan()
		// The first poll may still be waiting; poll until it settles.
		for attempt := 0; attempt < 5; attempt++ {
			poll, pollErr := manager.QRLogin().Poll(context.Background(), session)
			if pollErr != nil {
				loginErr = pollErr
				break
			}
			if poll.Phase == sources.QuarkQRScanned {
				cookieBytes = len(poll.Cookie)
				if err := creds.SetQuarkCookie(source.ID, poll.Cookie); err != nil {
					loginErr = err
					break
				}
				manager.Invalidate(source.ID)
				reloginOK = true
				break
			}
		}
	} else {
		loginErr = err
	}
	recovered, recoverErr := syncer.Sync(context.Background(), source, nil)
	after := sourceCount(db, source.ID)

	ok := failErr != nil && failed.NeedLogin && failed.Message == sources.QuarkUnauthenticatedMessage &&
		afterFail == before && row.SyncStatus == sources.QuarkUnauthenticatedMessage &&
		reloginOK && recoverErr == nil && after == before
	detail := fmt.Sprintf("失效：needLogin=%v 文案=%q 来源状态=%q，曲目 %d→%d；重新扫码（Cookie %d 字节）后 %s，曲目 %d",
		failed.NeedLogin, failed.Message, row.SyncStatus, before, afterFail, cookieBytes, recovered.Status, after)
	return []Check{{
		Name: "quark-relogin", Goal: "Cookie 失效 → 出现重新登录入口，登录后恢复", OK: ok, Detail: detail,
		Evidence: map[string]any{
			"need_login": failed.NeedLogin, "message": failed.Message,
			"source_status": row.SyncStatus, "tracks_before": before, "tracks_after_failure": afterFail,
			"recovered_status": recovered.Status, "tracks_after": after,
			"cookie_bytes": cookieBytes,
			"errors":       []string{errorString(failErr), errorString(loginErr), errorString(recoverErr)},
		},
	}}
}

// --- small helpers --------------------------------------------------

func lastMediaToken(records []sourcemock.QuarkRequest) string {
	token := ""
	for _, record := range records {
		if strings.Contains(record.Path, "/cdn/download/") {
			if value := queryValue(record.Query, "token"); value != "" {
				token = value
			}
		}
	}
	return token
}

func queryValue(query, key string) string {
	for _, part := range strings.Split(query, "&") {
		name, value, found := strings.Cut(part, "=")
		if found && name == key {
			return value
		}
	}
	return ""
}

func shortToken(token string) string {
	if len(token) <= 6 {
		return token
	}
	return token[:6] + "…"
}

func mediaRequestSample(records []sourcemock.QuarkRequest, limit int) []map[string]any {
	out := make([]map[string]any, 0, limit)
	for i := len(records) - 1; i >= 0 && len(out) < limit; i-- {
		record := records[i]
		if !strings.Contains(record.Path, "/cdn/download/") && record.Status == 200 {
			continue
		}
		out = append(out, map[string]any{
			"path": record.Path, "range": record.Range, "status": record.Status,
			"bytes": record.Bytes, "cookie": record.Cookie,
			"user_agent": shortUserAgent(record.UserAgent), "token": shortToken(queryValue(record.Query, "token")),
		})
	}
	return out
}

func shortUserAgent(agent string) string {
	if len(agent) <= 40 {
		return agent
	}
	return agent[:40] + "…"
}

func hostOf(raw string) string {
	for _, part := range strings.SplitN(raw, "/", 4) {
		if strings.Contains(part, ".") || strings.Contains(part, "localhost") {
			return part
		}
	}
	return raw
}

// fidOf extracts the fid from a quark:// path.
func fidOf(path string) string {
	if index := strings.LastIndex(path, "/"); index >= 0 {
		return path[index+1:]
	}
	return strings.TrimPrefix(path, "quark://")
}

// tokenForFID finds the token of the last direct link issued for fid.
func tokenForFID(records []sourcemock.QuarkRequest, fid string) string {
	token := ""
	for _, record := range records {
		if !strings.HasSuffix(record.Path, "/"+fid) {
			continue
		}
		if value := queryValue(record.Query, "token"); value != "" {
			token = value
		}
	}
	return token
}
