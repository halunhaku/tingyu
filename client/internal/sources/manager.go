package sources

// Manager builds and caches one adapter per source, resolves a library track
// to a playable item, and forgets cached adapters when their credentials
// change. The Flutter client's SourceAdapterCache (app/source_adapters.dart)
// has the same two jobs, including the credentialEpoch in the fingerprint: a
// cached adapter holds the password and the Cookie, so a re-login must not keep
// using the old ones.

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// ManagerOptions configure the manager and its clients.
type ManagerOptions struct {
	Quark          *QuarkClient
	QR             *QuarkQRLogin
	HTTP           *http.Client
	WebDAVRetry    Retry
	WebDAVThrottle time.Duration
	Logf           func(string, ...any)
}

// Manager is the source layer's entry point for the app.
type Manager struct {
	lib   *library.Library
	creds *Credentials
	quark *QuarkClient
	qr    *QuarkQRLogin
	http  *http.Client
	logf  func(string, ...any)

	webdavRetry    Retry
	webdavThrottle time.Duration

	mu       sync.Mutex
	adapters map[string]adapterEntry
}

type adapterEntry struct {
	fingerprint string
	adapter     Adapter
}

// NewManager builds the manager. A nil Quark client is created with the
// production endpoints; tests and the acceptance harness pass their own.
func NewManager(lib *library.Library, creds *Credentials, options ManagerOptions) (*Manager, error) {
	if creds == nil {
		creds = NewCredentials(nil)
	}
	quark := options.Quark
	if quark == nil {
		built, err := NewQuarkClient(QuarkOptions{HTTP: options.HTTP, Logf: options.Logf})
		if err != nil {
			return nil, err
		}
		quark = built
	}
	qr := options.QR
	if qr == nil {
		qr = NewQuarkQRLogin(QuarkQROptions{HTTP: options.HTTP, Logf: options.Logf})
	}
	httpClient := options.HTTP
	if httpClient == nil {
		httpClient = newHTTPClient(webdavTimeout)
	}
	if options.WebDAVRetry == (Retry{}) {
		options.WebDAVRetry = DefaultRetry
	}
	return &Manager{
		lib:            lib,
		creds:          creds,
		quark:          quark,
		qr:             qr,
		http:           httpClient,
		logf:           options.Logf,
		webdavRetry:    options.WebDAVRetry,
		webdavThrottle: options.WebDAVThrottle,
		adapters:       map[string]adapterEntry{},
	}, nil
}

// Credentials returns the credential API (the UI stores WebDAV passwords and
// Quark cookies through it).
func (m *Manager) Credentials() *Credentials { return m.creds }

// QuarkClient returns the shared Quark API client.
func (m *Manager) QuarkClient() *QuarkClient { return m.quark }

// QRLogin returns the QR login flow.
func (m *Manager) QRLogin() *QuarkQRLogin { return m.qr }

// Adapter returns the adapter for source, building or reusing it.
func (m *Manager) Adapter(ctx context.Context, source library.Source) (Adapter, error) {
	switch source.Kind {
	case KindWebDAV, KindQuark:
	case KindLocal:
		return nil, newError(KindOther, "本地来源不属于远端来源层")
	default:
		return nil, newError(KindOther, "未知的来源类型：%s", source.Kind)
	}
	fingerprint := m.fingerprint(source)
	m.mu.Lock()
	if entry, ok := m.adapters[source.ID]; ok && entry.fingerprint == fingerprint {
		m.mu.Unlock()
		return entry.adapter, nil
	}
	m.mu.Unlock()

	adapter, err := m.build(source)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.adapters[source.ID] = adapterEntry{fingerprint: fingerprint, adapter: adapter}
	m.mu.Unlock()
	return adapter, nil
}

// AdapterFor is Adapter by source id, reading the row first.
func (m *Manager) AdapterFor(ctx context.Context, sourceID string) (Adapter, library.Source, error) {
	source, found, err := m.Source(ctx, sourceID)
	if err != nil {
		return nil, library.Source{}, err
	}
	if !found {
		return nil, library.Source{}, newError(KindOther, "来源不存在：%s", sourceID)
	}
	adapter, err := m.Adapter(ctx, source)
	return adapter, source, err
}

// Source returns one music_sources row.
func (m *Manager) Source(ctx context.Context, sourceID string) (library.Source, bool, error) {
	if m.lib == nil {
		return library.Source{}, false, newError(KindOther, "曲库不可用")
	}
	sources, err := m.lib.Sources(ctx)
	if err != nil {
		return library.Source{}, false, err
	}
	for _, source := range sources {
		if source.ID == sourceID {
			return source, true, nil
		}
	}
	return library.Source{}, false, nil
}

func (m *Manager) build(source library.Source) (Adapter, error) {
	switch source.Kind {
	case KindWebDAV:
		password, found, err := m.creds.WebDAVPassword(source.ID)
		if err != nil {
			return nil, wrapError(KindOther, err, "读取 WebDAV 密码失败")
		}
		if !found || password == "" {
			// Missing credential = re-enter it, which is a login action.
			return nil, newError(KindAuth, "WebDAV 密码未保存，请重新填写")
		}
		adapter, err := NewWebDAV(source.ID, WebDAVOptions{
			RootURL:  source.WebDAVURL,
			Username: source.WebDAVUsername,
			Password: password,
			HTTP:     m.http,
			Retry:    m.webdavRetry,
			Throttle: m.webdavThrottle,
			Logf:     m.logf,
		})
		if err != nil {
			return nil, err
		}
		return adapter, nil
	case KindQuark:
		return NewQuarkSource(m.creds, m.quark, QuarkSourceOptions{
			SourceID:  source.ID,
			FolderFID: source.QuarkFolderFID,
			Logf:      m.logf,
		}), nil
	}
	return nil, newError(KindOther, "未知的来源类型：%s", source.Kind)
}

// fingerprint changes when the source row or the credentials change.
func (m *Manager) fingerprint(source library.Source) string {
	epoch := uint64(0)
	if m.creds != nil {
		epoch = m.creds.Epoch()
	}
	return strings.Join([]string{
		source.Kind,
		source.WebDAVURL,
		source.WebDAVUsername,
		source.WebDAVRootPath,
		source.QuarkFolderFID,
		strconv.FormatUint(epoch, 10),
	}, "\x00")
}

// Invalidate drops the cached adapter of one source.
func (m *Manager) Invalidate(sourceID string) {
	m.mu.Lock()
	delete(m.adapters, sourceID)
	m.mu.Unlock()
}

// Resolve turns a library track into a playable item. Local paths pass through
// untouched; a WebDAV path gets the Basic header; a `quark://<fid>` path gets a
// direct link plus the CDN headers.
func (m *Manager) Resolve(ctx context.Context, track library.Track) (Playable, error) {
	path := strings.TrimSpace(track.FilePath)
	if path == "" {
		return Playable{}, newError(KindOther, "曲目没有文件地址")
	}
	if !strings.Contains(path, "://") {
		return Playable{URI: path}, nil
	}
	scheme := strings.ToLower(path[:strings.Index(path, "://")])
	switch scheme {
	case "quark":
		adapter, _, err := m.AdapterFor(ctx, track.SourceID)
		if err != nil {
			return Playable{}, err
		}
		return adapter.Open(ctx, path)
	case "http", "https":
		source, found, err := m.Source(ctx, track.SourceID)
		if err == nil && found && source.Kind == KindWebDAV {
			adapter, adapterErr := m.Adapter(ctx, source)
			if adapterErr != nil {
				// A missing or unreadable credential is actionable ("重新登录"),
				// not something to hide behind an unauthenticated 401.
				return Playable{}, adapterErr
			}
			return adapter.Open(ctx, path)
		}
		// Unknown or local source with an http(s) path: hand it to the engine
		// without headers. A source row that vanished must not make an
		// otherwise playable track fail.
		return Playable{URI: path}, nil
	}
	return Playable{}, newError(KindOther, "不支持的曲目地址：%s", scheme)
}

// RefreshTrack invalidates whatever made a track's URI expire, so resolving it
// again mints a new one. Only Quark direct links expire; a WebDAV URL does not.
func (m *Manager) RefreshTrack(track library.Track) {
	if !strings.HasPrefix(track.FilePath, QuarkURIScheme) {
		return
	}
	fid, err := FIDOf(track.FilePath)
	if err != nil {
		return
	}
	m.quark.Invalidate(fid)
	if m.logf != nil {
		m.logf("sources: quark: invalidated direct link for %s", fid)
	}
}

// IsRemotePath reports whether a library path needs the source layer.
func IsRemotePath(path string) bool {
	return strings.Contains(path, "://") && !strings.HasPrefix(path, "file://")
}

// DescribeAdapter is a small debug string used in logs.
func DescribeAdapter(adapter Adapter) string {
	return fmt.Sprintf("%s:%s", adapter.Kind(), adapter.SourceID())
}
