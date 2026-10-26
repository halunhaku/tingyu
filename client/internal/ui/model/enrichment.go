package model

// M5's view state: the metadata enrichment panel, the AI fallback settings and
// the manual-match dialog.
//
// These callbacks live in their own interface instead of being added to
// Actions: Actions is the playback/library contract every test fake already
// implements, while enrichment is an additive capability the app wires
// separately. A build without it (a headless test rendering the settings page)
// shows the panel as unavailable instead of panicking on a nil method.

import (
	"time"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
)

// MetadataActions is what the window asks the app to do about metadata.
type MetadataActions interface {
	// EnrichAll starts an automatic pass over the tracks that need it.
	EnrichAll()
	// CancelEnrichment stops a running pass after the current track.
	CancelEnrichment()
	// EnrichTrack runs the pipeline for one track (the row menu's action).
	EnrichTrack(track library.Track)
	// LoadMatchCandidates asks the sources for candidates to show in the
	// match dialog; the answer arrives through SetMatchCandidates.
	LoadMatchCandidates(track library.Track)
	// ApplyManualMatch writes the user's override and, when coverURL is set,
	// saves that cover. It reports through MatchApplied / MatchFailed.
	ApplyManualMatch(track library.Track, title, artist, album, coverURL string)
	// SaveAISettings persists the AI configuration (key into the Keychain).
	SaveAISettings(settings metadata.AISettings) error
	// PruneCovers removes cover files no track references.
	PruneCovers()
}

// SetMetadataActions installs the M5 callbacks.
func (s *State) SetMetadataActions(actions MetadataActions) { s.metadataActions = actions }

// metadata returns the installed callbacks (nil in tests that need none).
func (s *State) metadata() MetadataActions { return s.metadataActions }

// MetadataReady reports whether this build has the enrichment pipeline wired.
func (s *State) MetadataReady() bool { return s.metadataActions != nil }

// EnrichmentView is the metadata section's snapshot of the pipeline.
type EnrichmentView struct {
	Running bool
	Done    int
	Total   int
	Current string

	Changed int
	Offline int
	Skipped int
	Failed  int
	Covers  int
	Lyrics  int
	// Stopped is "quota" or "cancelled" when a pass did not visit every
	// target.
	Stopped string

	// Targets is how many tracks a full pass would look at right now.
	Targets int
	// Quota and Used are the automatic pass's session budget.
	Quota int
	Used  int

	// Cover cache counters: files saved, hits, orphans pruned, hit rate.
	CoverSaved   int64
	CoverReused  int64
	CoverPruned  int64
	HitRate      float64
	FetcherFails int64

	// Message is the last one-line outcome for the panel.
	Message string
	// UpdatedAt is when the snapshot was taken (the panel shows "刚刚").
	UpdatedAt time.Time
}

// Enrichment returns the panel's snapshot.
func (s *State) Enrichment() EnrichmentView { return s.enrichment }

// SetEnrichment replaces the snapshot (the app's worker calls it through
// Window.Update, so it stays on the UI thread).
func (s *State) SetEnrichment(view EnrichmentView) {
	if view.UpdatedAt.IsZero() {
		view.UpdatedAt = s.now
	}
	s.enrichment = view
}

// BeginEnrichment marks the panel as running before the app answers, so the
// button switches to 取消 on the same frame.
func (s *State) BeginEnrichment() {
	if s.metadata() == nil {
		s.SetNotice("本次构建未接入元数据补全")
		return
	}
	view := s.enrichment
	view.Running = true
	view.Done = 0
	view.Total = 0
	view.Current = ""
	view.Stopped = ""
	view.Message = ""
	s.enrichment = view
	s.metadata().EnrichAll()
}

// CancelEnrichment asks the running pass to stop.
func (s *State) CancelEnrichment() {
	if s.metadata() == nil {
		return
	}
	s.metadata().CancelEnrichment()
}

// EnrichOne runs the pipeline for one track.
func (s *State) EnrichOne(track library.Track) {
	if s.metadata() == nil {
		s.SetNotice("本次构建未接入元数据补全")
		return
	}
	s.metadata().EnrichTrack(track)
}

// PruneCovers runs the orphan sweep now.
func (s *State) PruneCovers() {
	if s.metadata() == nil {
		return
	}
	s.metadata().PruneCovers()
}

// AI returns the configured fallback settings.
func (s *State) AI() metadata.AISettings { return s.ai }

// AIError is the last load/save problem with the AI settings.
func (s *State) AIError() string { return s.aiError }

// SetAISettings replaces the settings and clears the error (the app calls it
// after reading the Keychain).
func (s *State) SetAISettings(settings metadata.AISettings, errMsg string) {
	s.ai = settings
	s.aiError = errMsg
}

// SaveAISettings asks the app to persist the settings. The panel shows the
// result; a Keychain failure never discards what the user typed.
func (s *State) SaveAISettings(next metadata.AISettings) {
	s.ai = next
	if s.metadata() == nil {
		s.aiError = "本次构建未接入元数据补全"
		return
	}
	if err := s.metadata().SaveAISettings(next); err != nil {
		s.aiError = "保存 AI 配置失败：" + err.Error()
		return
	}
	s.aiError = ""
	s.SetNotice("AI 兜底配置已保存（密钥在系统钥匙串）")
}

// NextAIPreset returns the preset after name (the panel's 下一个 preset button).
func NextAIPreset(name string) metadata.AIPreset {
	for i, preset := range metadata.AIPresets {
		if preset.Name == name {
			return metadata.AIPresets[(i+1)%len(metadata.AIPresets)]
		}
	}
	return metadata.AIPresets[0]
}

// AIPreset returns the preset with this name, or the first one.
func AIPreset(name string) metadata.AIPreset {
	for _, preset := range metadata.AIPresets {
		if preset.Name == name {
			return preset
		}
	}
	return metadata.AIPresets[0]
}

// MatchCandidate is one row of the manual-match dialog.
type MatchCandidate struct {
	Provider string
	Title    string
	Artist   string
	Album    string
	CoverURL string
	Duration time.Duration
}

// MatchState is the manual-match dialog: search candidates from the sources,
// editable fields, and the write-back the user confirms.
type MatchState struct {
	Open       bool
	Track      library.Track
	Loading    bool
	Error      string
	Candidates []MatchCandidate
	Selected   int

	// The fields the apply writes. They start at the track's current values
	// and are replaced by a chosen candidate, then editable again.
	Title  string
	Artist string
	Album  string

	Busy    bool
	Message string
}

// Match returns the dialog state.
func (s *State) Match() *MatchState { return &s.match }

// OpenMatch opens the dialog for a track and asks for candidates.
func (s *State) OpenMatch(track library.Track) {
	s.match = MatchState{
		Open: true, Track: track, Loading: true,
		Title: track.Title, Artist: track.Artist, Album: track.Album,
	}
	if s.metadata() == nil {
		s.match.Loading = false
		s.match.Error = "本次构建未接入元数据补全"
		return
	}
	s.metadata().LoadMatchCandidates(track)
}

// CloseMatch hides the dialog.
func (s *State) CloseMatch() { s.match.Open = false }

// SetMatchCandidates fills the candidate list (an empty list with an error is
// shown, an empty list without one says "没有候选").
func (s *State) SetMatchCandidates(candidates []MatchCandidate, errMsg string) {
	if !s.match.Open {
		return
	}
	s.match.Loading = false
	s.match.Error = errMsg
	s.match.Candidates = candidates
	s.match.Selected = 0
	if len(candidates) == 0 && errMsg == "" {
		s.match.Message = "没有找到候选：可以手动填写标题 / 艺术家 / 专辑后应用"
	} else {
		s.match.Message = ""
	}
}

// UseMatchCandidate copies a candidate into the editable fields.
func (s *State) UseMatchCandidate(index int) {
	if index < 0 || index >= len(s.match.Candidates) {
		return
	}
	candidate := s.match.Candidates[index]
	s.match.Selected = index
	s.match.Title = candidate.Title
	s.match.Artist = candidate.Artist
	s.match.Album = candidate.Album
}

// ApplyMatch writes the editable fields back through the app.
func (s *State) ApplyMatch() {
	if !s.match.Open || s.match.Busy {
		return
	}
	if s.metadata() == nil {
		s.match.Error = "本次构建未接入元数据补全"
		return
	}
	coverURL := ""
	if s.match.Selected >= 0 && s.match.Selected < len(s.match.Candidates) {
		coverURL = s.match.Candidates[s.match.Selected].CoverURL
	}
	s.match.Busy = true
	s.match.Message = "正在写入…"
	s.metadata().ApplyManualMatch(s.match.Track, s.match.Title, s.match.Artist, s.match.Album, coverURL)
}

// MatchApplied closes the dialog after a successful write.
func (s *State) MatchApplied(message string) {
	s.match.Busy = false
	s.match.Open = false
	s.match.Message = ""
	if message == "" {
		message = "已写入人工匹配的元数据"
	}
	s.SetNotice(message)
}

// MatchFailed shows a write failure in the dialog.
func (s *State) MatchFailed(message string) {
	s.match.Busy = false
	s.match.Message = ""
	s.match.Error = message
}
