//go:build darwin

// M5's wiring: the metadata pipeline, the cover fetcher and the two write
// paths (the automatic pass and the manual match) as application actions.
//
// The pipeline is built only when the library copy is writable. A read-only
// build — TINGYU_DATA_DIR unset — still shows what is in the library, but the
// panel says so instead of pretending a write landed (plan §8.1 rule 2).

package app

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/halunhaku/tingyu/client/internal/enrich"
	"github.com/halunhaku/tingyu/client/internal/images"
	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/sources"
	"github.com/halunhaku/tingyu/client/internal/titleparse"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// metadataHTTPTimeout is one metadata request's overall budget; the providers
// use 8–15 s per call, and a pass of 60 tracks is sequential on purpose (the
// upstreams are public rate-limited endpoints).
const metadataHTTPTimeout = 20 * time.Second

// enrichPassTimeout bounds one automatic pass. Sixty tracks with a 12 s
// upstream timeout each can legitimately take minutes; this is a safety net,
// not a schedule.
const enrichPassTimeout = 15 * time.Minute

// initMetadata builds the four sources, the AI fallback and the enrichment
// service, and hands the window its callbacks.
func (a *application) initMetadata() {
	if a.lib == nil || a.model == nil || a.covers == "" {
		return
	}
	a.metadataHTTP = sources.NewHTTPClient(metadataHTTPTimeout)
	http := &metadata.HTTP{Client: a.metadataHTTP, UA: metadata.DefaultUserAgent}
	enricher := &metadata.Enricher{
		Primary:        metadata.NewQQMusic(http),
		Fallback:       metadata.NewNetEase(http),
		Lyrics:         metadata.NewLRCLIB(http),
		FallbackLyrics: metadata.NewNetEase(http),
		Cover:          metadata.NewITunes(http),
		Log:            a.logf,
	}
	settings, aiErr := a.loadAISettings()
	if client := metadata.NewAIClient(settings, a.metadataHTTP); client != nil {
		enricher.SetAI(client)
	}
	store := &images.Store{Dir: a.covers}
	fetcher := &images.Fetcher{Store: store, Client: a.metadataHTTP, Log: a.logf}
	a.enricher = enricher
	a.enrich = &enrich.Service{
		Library:  a.lib,
		Enricher: enricher,
		Covers:   store,
		Fetcher:  fetcher,
		Log:      a.logf,
	}
	a.model.SetMetadataActions(a)
	a.model.SetAISettings(settings, aiErr)
	a.model.SetLogf(a.logf)
	a.logf("metadata: four sources ready (qqmusic / netease / itunes / lrclib); AI fallback ready=%v", settings.Ready())
	a.refreshEnrichmentView("")
}

// loadAISettings reads the AI configuration from the Keychain. A missing item
// is the normal "not configured" case; an unreadable one is reported but never
// fatal.
func (a *application) loadAISettings() (metadata.AISettings, string) {
	keychain := sources.Keychain{}
	raw, ok, err := keychain.Get(metadata.AIKeychainAccount)
	if err != nil {
		return metadata.DefaultAISettings(), "读取 AI 配置失败（钥匙串）：" + err.Error()
	}
	if !ok {
		return metadata.DefaultAISettings(), ""
	}
	settings, parseErr := metadata.ParseAISettings(string(raw))
	if parseErr != nil {
		return metadata.DefaultAISettings(), parseErr.Error()
	}
	return settings, ""
}

// refreshEnrichmentView pushes a fresh snapshot to the settings page. It runs
// on the UI thread (through updateWindow), so the model stays single-threaded.
func (a *application) refreshEnrichmentView(message string) {
	view := a.enrichmentView(message, false)
	a.updateWindow(func() { a.model.SetEnrichment(view) })
}

// enrichmentView builds the snapshot: service counters, cover-cache counters
// and the number of tracks still missing something.
func (a *application) enrichmentView(message string, running bool) model.EnrichmentView {
	view := model.EnrichmentView{Message: message, Running: running, UpdatedAt: time.Now()}
	if a.enrich != nil {
		stats := a.enrich.Stats()
		fetch := a.enrich.FetcherStats()
		view.Changed = stats.Changed
		view.Offline = stats.Offline
		view.Skipped = stats.Skipped
		view.Failed = stats.Failed
		view.Covers = stats.Covers
		view.Lyrics = stats.Lyrics
		view.Quota = stats.SessionQuota
		view.Used = stats.SessionUsed
		view.HitRate = fetch.HitRate()
		view.CoverReused = fetch.Reused
		view.FetcherFails = fetch.Failed
		if store := a.enrich.CoverStore(); store != nil {
			storeStats := store.Stats()
			view.CoverSaved = storeStats.Saved
			view.CoverReused = max(view.CoverReused, storeStats.Reused)
			view.CoverPruned = storeStats.Pruned
		}
	}
	if a.lib != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		if count, err := a.lib.CountEnrichmentTargets(ctx); err == nil {
			view.Targets = count
		}
		cancel()
	}
	return view
}

// publishPass mirrors one progress callback from the service.
func (a *application) publishPass(pass enrich.Pass) {
	view := a.enrichmentView("", !pass.Finished)
	view.Done = pass.Done
	view.Total = pass.Total
	view.Current = pass.Current
	view.Stopped = pass.Stopped
	view.Running = !pass.Finished
	view.Changed = pass.Summary.Changed
	view.Offline = pass.Summary.Offline
	view.Skipped = pass.Summary.Skipped
	view.Failed = pass.Summary.Failed
	view.Covers = pass.Summary.Covers
	view.Lyrics = pass.Summary.Lyrics
	a.updateWindow(func() { a.model.SetEnrichment(view) })
}

// EnrichAll starts an automatic pass (the settings page's 补全全部). One pass
// at a time: a second click while one runs is ignored rather than queued.
func (a *application) EnrichAll() {
	if a.enrich == nil || a.lib == nil {
		return
	}
	if !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能补全（生产库绝不被写）")
		return
	}
	if !a.enrichActive.CompareAndSwap(false, true) {
		a.logf("metadata: a pass is already running")
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), enrichPassTimeout)
	a.enrichMu.Lock()
	a.enrichCancel = cancel
	a.enrichMu.Unlock()

	go func() {
		defer func() {
			a.enrichActive.Store(false)
			cancel()
			a.enrichMu.Lock()
			a.enrichCancel = nil
			a.enrichMu.Unlock()
		}()
		a.logf("metadata: pass start")
		summary := a.enrich.EnrichTargets(ctx, 0, a.publishPass, func() bool { return ctx.Err() != nil })
		a.logf("metadata: pass done attempted=%d changed=%d offline=%d skipped=%d failed=%d covers=%d lyrics=%d",
			summary.Attempted, summary.Changed, summary.Offline, summary.Skipped, summary.Failed, summary.Covers, summary.Lyrics)
		message := fmt.Sprintf("补全完成：处理 %d 首，变更 %d 首，离线跳过 %d 首，封面 %d、歌词 %d",
			summary.Attempted, summary.Changed, summary.Offline, summary.Covers, summary.Lyrics)
		view := a.enrichmentView(message, false)
		view.Done = summary.Attempted
		view.Total = summary.Attempted
		view.Changed = summary.Changed
		view.Offline = summary.Offline
		view.Skipped = summary.Skipped
		view.Failed = summary.Failed
		a.updateWindow(func() {
			// The writes bumped the revision; the Invalidate makes the frame
			// after this one re-read the lists and the stage (plan §2.5).
			a.model.Invalidate()
			a.model.SetEnrichment(view)
			a.model.SetStatus(message)
		})
	}()
}

// CancelEnrichment stops the running pass after the current track.
func (a *application) CancelEnrichment() {
	a.enrichMu.Lock()
	cancel := a.enrichCancel
	a.enrichMu.Unlock()
	if cancel == nil {
		return
	}
	a.logf("metadata: pass cancel requested")
	cancel()
}

// maybeAutoEnrich is the startup/sync trigger: the same pass, bounded by the
// service's 60-track session quota. It never runs on a read-only build.
func (a *application) maybeAutoEnrich(reason string) {
	if a.enrich == nil || a.lib == nil || !a.lib.Writable() {
		return
	}
	if strings.TrimSpace(strings.ToLower(getenvDefault("TINGYU_ENRICH_AUTO", "1"))) == "0" {
		a.logf("metadata: automatic pass disabled by TINGYU_ENRICH_AUTO=0")
		return
	}
	a.logf("metadata: automatic pass after %s", reason)
	a.EnrichAll()
}

// EnrichTrack runs the pipeline for one track (the row menu and the stage).
func (a *application) EnrichTrack(track library.Track) {
	if a.enrich == nil {
		return
	}
	if a.lib != nil && !a.lib.Writable() {
		a.setStatus("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能补全（生产库绝不被写）")
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		result := a.enrich.EnrichTrack(ctx, track)
		view := a.enrichmentView("", false)
		a.updateWindow(func() {
			switch {
			case result.Err != nil:
				a.logf("metadata: %q failed: %v", track.Title, result.Err)
				a.model.SetError("补全失败：" + result.Err.Error())
			case result.Offline && result.Changed:
				a.model.Invalidate()
				a.model.SetStatus("离线：只落下文件名清理（" + describeFields(result.Fields) + "），封面/歌词未联网补全")
			case result.Offline:
				a.model.SetStatus("离线：已跳过「" + track.Title + "」，没有写库（不弹错）")
			case result.Changed:
				a.model.Invalidate()
				a.model.SetStatus(fmt.Sprintf("已补全「%s」：%s", track.Title, describeFields(result.Fields)))
			default:
				a.model.SetStatus("没有可写入的新元数据：" + track.Title)
			}
			a.model.SetEnrichment(view)
		})
	}()
}

// LoadMatchCandidates searches the sources for the match dialog. The query is
// the file-name parse of the title, so a dirty row still finds its song.
func (a *application) LoadMatchCandidates(track library.Track) {
	if a.enricher == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		parsed := titleparse.ParseFilename(track.Title)
		query := metadata.SearchQuery{Title: parsed.Title, Artist: track.Artist, Album: track.Album}
		if metadata.IsPlaceholderArtist(query.Artist) {
			query.Artist = parsed.Artist
		}
		if metadata.IsPlaceholderAlbum(query.Album) {
			query.Album = parsed.Album
		}
		hits, err := a.enricher.Candidates(ctx, query, 12)
		candidates := make([]model.MatchCandidate, 0, len(hits))
		for _, hit := range hits {
			candidates = append(candidates, model.MatchCandidate{
				Provider: hit.Provider,
				Title:    hit.Title,
				Artist:   hit.Artist,
				Album:    hit.Album,
				CoverURL: hit.CoverURL,
				Duration: hit.Duration,
			})
		}
		message := ""
		if err != nil {
			// Offline is shown inside the dialog as "no candidates", which is
			// the same place a user sees an empty search; it is a hint, not a
			// blocking error.
			message = "搜索失败：" + friendlyUpstreamError(err)
			a.logf("metadata: match search for %q: %v", track.Title, err)
		}
		a.updateWindow(func() { a.model.SetMatchCandidates(candidates, message) })
	}()
}

// ApplyManualMatch writes the user's override, then reports through the model.
func (a *application) ApplyManualMatch(track library.Track, title, artist, album, coverURL string) {
	if a.enrich == nil {
		a.updateWindow(func() { a.model.MatchFailed("本次构建未接入元数据补全") })
		return
	}
	if a.lib != nil && !a.lib.Writable() {
		a.updateWindow(func() {
			a.model.MatchFailed("只读模式：设置 TINGYU_DATA_DIR 指向曲库副本后才能写回（生产库绝不被写）")
		})
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		result := a.enrich.ManualMatch(ctx, track, title, artist, album, coverURL)
		view := a.enrichmentView("", false)
		a.updateWindow(func() {
			if result.Err != nil {
				a.logf("metadata: manual match %q failed: %v", track.Title, result.Err)
				a.model.MatchFailed("写回失败：" + result.Err.Error())
				return
			}
			a.model.Invalidate()
			message := fmt.Sprintf("已写回「%s」：%s", title, describeFields(result.Fields))
			if !result.Changed {
				message = "没有变化：「" + title + "」与库中一致"
			}
			a.model.MatchApplied(message)
			a.model.SetEnrichment(view)
		})
	}()
}

// SaveAISettings persists the AI configuration. The key goes to the Keychain
// and nowhere else: not settings.json, not the log (MaskKey only).
func (a *application) SaveAISettings(settings metadata.AISettings) error {
	blob, err := settings.Encode()
	if err != nil {
		return err
	}
	keychain := sources.Keychain{}
	if err := keychain.Set(metadata.AIKeychainAccount, []byte(blob)); err != nil {
		return err
	}
	var client *metadata.AIClient
	if settings.Ready() {
		client = metadata.NewAIClient(settings, a.metadataHTTP)
	}
	if a.enricher != nil {
		a.enricher.SetAI(client)
	}
	a.logf("metadata: AI settings saved enabled=%v preset=%s model=%s key=%s",
		settings.Enabled, settings.Preset, settings.Model, settings.MaskKey())
	return nil
}

// PruneCovers deletes cover files no track references. It refuses on a
// read-only build for the same reason the writes do: the covers directory is
// the production one then.
func (a *application) PruneCovers() {
	if a.enrich == nil || a.lib == nil {
		return
	}
	if !a.lib.Writable() {
		a.setStatus("只读模式：清理封面只对 TINGYU_DATA_DIR 指向的副本生效")
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		removed, err := a.enrich.PruneCovers(ctx)
		view := a.enrichmentView("", false)
		a.updateWindow(func() {
			if err != nil {
				a.model.SetError("清理封面失败：" + err.Error())
			} else {
				a.model.SetStatus(fmt.Sprintf("已清理 %d 个无引用封面，仍被引用的封面保留", removed))
			}
			a.model.SetEnrichment(view)
		})
	}()
}

// describeFields is the one-line summary of a write used in the status bar.
func describeFields(fields library.EnrichmentFields) string {
	parts := make([]string, 0, 4)
	if fields.Title != "" {
		parts = append(parts, "标题「"+fields.Title+"」")
	}
	if fields.Artist != "" {
		parts = append(parts, "艺术家「"+fields.Artist+"」")
	}
	if fields.Album != "" {
		parts = append(parts, "专辑「"+fields.Album+"」")
	}
	if fields.Lyrics != "" {
		parts = append(parts, "歌词")
	}
	if fields.CoverArtPath != "" {
		parts = append(parts, "封面")
	}
	if title := strings.TrimSpace(fields.Title); title == "" && len(parts) == 0 {
		return "无字段变更"
	}
	if len(parts) == 0 {
		return "只补齐了时长"
	}
	return strings.Join(parts, "、")
}

// friendlyUpstreamError keeps the dialog's sentence short; the full error is in
// the log.
func friendlyUpstreamError(err error) string {
	if metadata.IsNetwork(err) {
		return "网络不可用"
	}
	return "上游没有应答"
}

// getenvDefault reads an environment variable with a fallback.
func getenvDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}
