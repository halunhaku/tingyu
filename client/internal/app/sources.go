//go:build darwin

package app

// M3 source assembly: add/relogin a remote source, sync it with visible
// progress and cancellation, log in to Quark (QR or pasted Cookie), resolve a
// remote track for playback, and refresh an expired direct link once.
//
// The playback kernel is untouched: a remote track is still one URI plus
// per-track headers, and a refreshed link re-enters the public PlayTracks path
// so the engine gets a *different* URL (mpv may reuse the demuxer of a URI it
// loaded before — M2 §4.5 — so same-URI token rotation must not be relied on).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"net/url"
	"strings"
	"time"

	"github.com/skip2/go-qrcode"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// initSources builds the source manager and syncer once the library is open.
func (a *application) initSources() {
	if a.lib == nil {
		return
	}
	a.creds = sources.NewCredentials(sources.Keychain{})
	manager, err := sources.NewManager(a.lib, a.creds, sources.ManagerOptions{Logf: a.logf})
	if err != nil {
		a.logf("sources: manager unavailable: %v", err)
		return
	}
	a.sourceMgr = manager
	a.syncer = &sources.Syncer{Lib: a.lib, Manager: manager, Logf: a.logf}
}

// resolveTrack is the playback resolver: local paths pass through, remote ones
// get their URI and headers from the source layer.
func (a *application) resolveTrack(track library.Track) (player.Item, error) {
	item := player.Item{
		ID:       track.ID,
		TrackID:  track.ID,
		Title:    track.Title,
		Artist:   track.Artist,
		Album:    track.Album,
		Duration: track.Duration,
	}
	if track.FilePath == "" {
		return item, errors.New("曲目没有文件路径")
	}
	if a.sourceMgr == nil || !sources.IsRemotePath(track.FilePath) {
		item.URI = track.FilePath
		return item, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	playable, err := a.sourceMgr.Resolve(ctx, track)
	if err != nil {
		// A credential failure surfaces as a source error, so the card offers
		// "重新登录" even when the first symptom was a failed play.
		if sources.IsAuth(err) {
			message := err.Error()
			a.updateWindow(func() { a.model.SetSourceError(track.SourceID, message) })
		}
		return item, err
	}
	item.URI = playable.URI
	item.Headers = playable.Headers
	a.logf("sources: resolve %q via %s (%d headers)", track.Title, redactedHost(playable.URI), len(playable.Headers))
	return item, nil
}

// redactedHost keeps only the scheme and host of a URL: direct links carry
// their signature in the query string and must not reach the log.
func redactedHost(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return raw
	}
	return parsed.Scheme + "://" + parsed.Host + "/…"
}

// --- source actions (model.SourceActions) ---------------------------

// AddWebDAVSource validates, stores the password and creates or updates the row.
func (a *application) AddWebDAVSource(values model.SourceFormValues) {
	go a.addWebDAVSource(values)
}

func (a *application) addWebDAVSource(values model.SourceFormValues) {
	if a.lib == nil || !a.lib.Writable() || a.sourceMgr == nil {
		a.setFormMessage("只读模式：本次以 TINGYU_READ_ONLY=1 打开，不能添加来源；去掉该变量后重试")
		return
	}
	root := strings.TrimSpace(values.URL)
	if root == "" {
		a.setFormMessage("请填写 WebDAV 地址")
		return
	}
	name := strings.TrimSpace(values.Name)
	if name == "" {
		if parsed, err := url.Parse(root); err == nil && parsed.Host != "" {
			name = parsed.Host
		} else {
			name = "WebDAV"
		}
	}
	adapter, err := sources.NewWebDAV(sourceID(values.Editing), sources.WebDAVOptions{
		RootURL:  root,
		Username: strings.TrimSpace(values.Username),
		Password: values.Password,
	})
	if err != nil {
		a.setFormMessage(err.Error())
		return
	}
	started := time.Now()
	if err := adapter.TestConnection(context.Background()); err != nil {
		a.logf("sources: webdav test failed: %v", err)
		a.setFormMessage(err.Error())
		return
	}
	a.logf("sources: webdav connection ok in %s", time.Since(started).Round(time.Millisecond))

	id := strings.TrimSpace(values.Editing)
	if id == "" {
		id = newSourceID()
	}
	source := library.Source{
		ID:             id,
		Name:           name,
		Kind:           sources.KindWebDAV,
		WebDAVURL:      root,
		WebDAVUsername: strings.TrimSpace(values.Username),
		SyncStatus:     "未同步",
	}
	if err := a.creds.SetWebDAVPassword(id, values.Password); err != nil {
		a.setFormMessage("保存密码到钥匙串失败：" + err.Error())
		return
	}
	if err := a.lib.UpsertSource(context.Background(), source); err != nil {
		a.setFormMessage("保存来源失败：" + err.Error())
		return
	}
	a.sourceMgr.Invalidate(id)
	a.logf("sources: saved webdav source %s (%s)", name, root)
	a.reloadSources()
	a.closeForm()
	a.syncRemote(source)
}

// AddQuarkSource authenticates without persisting or synchronizing yet.
func (a *application) AddQuarkSource(values model.SourceFormValues) {
	a.cancelSourceLogin()
	a.quarkFormUpdate(values, func(f *model.SourceForm) {
		f.Busy = true
		f.Message = ""
		go a.prepareQuarkSelection(values, values.Cookie)
	})
}

func (a *application) prepareQuarkSelection(values model.SourceFormValues, cookie string) {
	if a.lib == nil || !a.lib.Writable() || a.sourceMgr == nil {
		a.quarkMessage(values, "当前不能添加来源，请使用可写曲库重试")
		return
	}
	session := sources.NewQuarkSession(sources.ParseQuarkCookie(cookie))
	if session.IsEmpty() {
		a.quarkMessage(values, sources.QuarkCookieFormatError)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	check := a.sourceMgr.QuarkClient().ValidateSession(ctx, session)
	if check.State != sources.QuarkSessionValid {
		message := sources.QuarkAuthUnavailableMessage
		if check.State == sources.QuarkSessionExpired {
			message = sources.QuarkSessionExpiredMessage
		}
		a.quarkMessage(values, message)
		return
	}
	a.quarkFormUpdate(values, func(f *model.SourceForm) {
		f.Cookie = session.Header()
		f.AccountName = check.Nickname
		f.Choosing = true
		f.QR = nil
		go a.loadQuarkFolders(f.RequestFolders())
	})
}

// LoginQuark starts the QR flow: fetch a code, render it, poll until the phone
// confirms, then open the same folder picker as a pasted Cookie.
func (a *application) LoginQuark(values model.SourceFormValues) {
	a.quarkFormUpdate(values, func(f *model.SourceForm) {
		if a.lib == nil || !a.lib.Writable() || a.sourceMgr == nil {
			f.Message = "只读模式：不能登录来源"
			return
		}
		a.cancelSourceLogin()
		ctx, cancel := context.WithCancel(context.Background())
		a.sourceLoginMu.Lock()
		seq := a.sourceLoginSeq.Add(1)
		a.sourceLoginCancel = cancel
		a.sourceLoginActive = seq
		a.sourceLoginMu.Unlock()
		f.Busy = true
		f.Message = ""
		go a.loginQuark(ctx, cancel, seq, values)
	})
}

func (a *application) loginQuark(ctx context.Context, cancel context.CancelFunc, seq uint64, values model.SourceFormValues) {
	defer func() {
		a.sourceLoginMu.Lock()
		if a.sourceLoginActive == seq {
			a.sourceLoginCancel = nil
			a.sourceLoginActive = 0
		}
		a.sourceLoginMu.Unlock()
		cancel()
	}()

	a.quarkFormUpdate(values, func(f *model.SourceForm) { f.Busy = true; f.Message = "正在申请二维码…" })
	session, err := a.sourceMgr.QRLogin().Start(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		a.quarkMessage(values, "申请二维码失败："+err.Error())
		return
	}
	if !a.showQR(values, session.QRContent) {
		a.quarkMessage(values, "无法绘制二维码")
		return
	}
	a.logf("sources: quark QR requested")
	deadline := time.Now().Add(3 * time.Minute)
	for {
		if ctx.Err() != nil {
			return
		}
		if time.Now().After(deadline) {
			a.quarkMessage(values, "二维码已过期，请刷新")
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
		poll, pollErr := a.sourceMgr.QRLogin().Poll(ctx, session)
		if pollErr != nil {
			if ctx.Err() != nil {
				return
			}
			a.quarkMessage(values, "查询扫码状态失败："+pollErr.Error())
			return
		}
		if ctx.Err() != nil {
			return
		}
		switch poll.Phase {
		case sources.QuarkQRWaiting:
			a.updateQRPhase(values, poll.Message)
		case sources.QuarkQRExpired:
			a.quarkMessage(values, poll.Message)
			return
		case sources.QuarkQRFailed:
			a.quarkMessage(values, poll.Message)
			return
		case sources.QuarkQRScanned:
			a.logf("sources: quark QR confirmed, exchanging login for a cookie")
			go a.prepareQuarkSelection(values, poll.Cookie)
			return
		}
	}
}

// CancelSourceLogin stops a QR flow in progress.
func (a *application) CancelSourceLogin() {
	values := a.model.SourceForm().Values()
	a.cancelSourceLogin()
	a.quarkFormUpdate(values, func(f *model.SourceForm) {
		if !f.Choosing {
			a.model.State().InvalidateSourceFormRequest()
			f.Busy = false
			f.Message = "已停止扫码登录"
		}
	})
}

func (a *application) cancelSourceLogin() {
	a.sourceLoginMu.Lock()
	cancel := a.sourceLoginCancel
	a.sourceLoginCancel = nil
	a.sourceLoginMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// CancelSourceSync cancels a running remote sync; the merge keeps what was
// already found and never deletes (the non-authoritative rule).
func (a *application) CancelSourceSync() {
	a.sourceSyncMu.Lock()
	cancel := a.sourceSyncCancel
	a.sourceSyncMu.Unlock()
	if cancel != nil {
		cancel()
		a.setStatus("已请求取消同步")
	}
}

// --- sync -----------------------------------------------------------

func (a *application) syncRemote(source library.Source) {
	if a.syncer == nil || a.sourceMgr == nil {
		a.setStatus("来源层不可用")
		return
	}
	if a.scanning.Swap(true) {
		a.setStatus("已有同步在进行，请稍候")
		return
	}
	defer a.scanning.Store(false)
	a.runRemoteSync(source)
}

func (a *application) runRemoteSync(source library.Source) {
	ctx, cancel := context.WithCancel(context.Background())
	seq := a.sourceSyncSeq.Add(1)
	a.sourceSyncMu.Lock()
	a.sourceSyncCancel = cancel
	a.sourceSyncID = source.ID
	a.sourceSyncActive = seq
	a.sourceSyncMu.Unlock()
	defer func() {
		a.sourceSyncMu.Lock()
		if a.sourceSyncActive == seq {
			a.sourceSyncCancel = nil
			a.sourceSyncID = ""
			a.sourceSyncActive = 0
		}
		a.sourceSyncMu.Unlock()
		cancel()
	}()

	name := source.Name
	if name == "" {
		name = source.ID
	}
	a.logf("sources: sync start %q (%s)", name, source.Kind)
	a.updateWindow(func() {
		a.model.SetScan(model.ScanState{Running: true, SourceID: source.ID, SourceName: name, Path: name})
	})
	last := time.Time{}
	outcome, err := a.syncer.Sync(ctx, source, func(done int, title string) {
		if time.Since(last) < 40*time.Millisecond {
			return
		}
		last = time.Now()
		a.updateWindow(func() {
			a.model.SetScan(model.ScanState{
				Running: true, Done: done, SourceID: source.ID, SourceName: name,
				Path: fmt.Sprintf("%s · %s", name, title),
			})
		})
	})
	if err != nil {
		a.logf("sources: sync %q failed: %v", name, err)
		a.updateWindow(func() {
			a.model.SetScan(model.ScanState{Error: err.Error(), SourceID: source.ID, SourceName: name})
			a.model.SetError(err.Error())
			if outcome.NeedLogin {
				a.model.SetSourceError(source.ID, err.Error())
			}
		})
		return
	}
	a.updateWindow(func() {
		a.model.SetScan(model.ScanState{Status: outcome.Status, SourceID: source.ID, SourceName: name})
		a.model.ClearSourceError(source.ID)
		a.model.SetError("")
	})
	a.logf("sources: sync %q done: %s", name, outcome.Status)
	// The scan wrote through the library, which bumped its revision: the SQL
	// lists refresh off that counter, so the window needs an invalidation
	// rather than a copy of the whole tracks table.
	a.refresh()
}

func (a *application) setFormMessage(message string) {
	a.updateWindow(func() {
		a.model.SetSourceFormBusy(false, "")
		a.model.SetSourceFormMessage(message)
	})
}

func (a *application) setFormBusy(busy bool, message string) {
	a.updateWindow(func() {
		a.model.SetSourceFormBusy(busy, message)
	})
}

func (a *application) closeForm() {
	a.updateWindow(func() { a.model.CloseSourceForm() })
}

// showQR renders the QR content into the form.
func (a *application) showQR(values model.SourceFormValues, content string) bool {
	png, err := qrcode.Encode(content, qrcode.Medium, 512)
	if err != nil {
		a.logf("sources: qr encode: %v", err)
		return false
	}
	decoded, _, err := image.Decode(bytes.NewReader(png))
	if err != nil {
		a.logf("sources: qr decode: %v", err)
		return false
	}
	bitmap := ui.NewBitmap(decoded)
	a.quarkFormUpdate(values, func(f *model.SourceForm) { f.QR = bitmap; f.QRPhase = "请用手机夸克 App 扫码" })
	return true
}

func (a *application) updateQRPhase(values model.SourceFormValues, phase string) {
	a.quarkFormUpdate(values, func(f *model.SourceForm) { f.QRPhase = phase })
}

func sourceID(editing string) string {
	if strings.TrimSpace(editing) != "" {
		return editing
	}
	return newSourceID()
}

func newSourceID() string {
	return fmt.Sprintf("src-%d", time.Now().UnixMicro())
}
