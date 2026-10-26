// Package shell is the M4 window: sidebar, page dispatch, transport, command
// palette and the keyboard shortcuts. It holds no window, no database handle
// and no engine; the app package wires its actions to the playback kernel.
package shell

import (
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/metadata"
	"github.com/halunhaku/tingyu/client/internal/player"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/pages"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Window sizes. The assembly opens the window with these; the minimum is the
// acceptance floor (900×600).
const (
	DefaultWidth  = 1200
	DefaultHeight = 760
	MinimumWidth  = 900
	MinimumHeight = 600
)

// Actions are what the view can ask the app to do (the model's interface, kept
// here so the app keeps implementing shell.Actions as it did in M1).
type Actions = model.Actions

// ScanState is what the view shows about a scan.
type ScanState = model.ScanState

// Model is the state the window shows.
type Model struct {
	state *model.State
}

// New builds a model over the library's read side. loadErr means the library
// could not be opened at all; the window explains it instead of showing a
// blank table.
func New(backend model.Backend, live model.Live, dbPath string, loadErr error) *Model {
	return &Model{state: model.New(backend, live, dbPath, loadErr)}
}

// State exposes the view state for the assembly (menus, acceptance hooks).
func (m *Model) State() *model.State { return m.state }

// SetActions installs the callbacks.
func (m *Model) SetActions(actions Actions) { m.state.SetActions(actions) }

// Invalidate asks the next frame to re-read the library (the app calls it
// after a write it performed itself; writes made elsewhere are seen through
// the revision).
func (m *Model) Invalidate() { m.state.Invalidate() }

// SetSources replaces the source list.
func (m *Model) SetSources(sources []library.Source) { m.state.SetSources(sources) }

// SetPlayer applies a playback update and records the queue.
func (m *Model) SetPlayer(update player.Update) {
	m.state.SetPlayer(update)
	if update.Track != nil && len(m.state.Queue()) == 0 {
		// A queue the UI did not start (media keys) still shows something.
		m.state.SetQueue([]library.Track{*update.Track}, update.Index)
	}
}

// SetQueue records the queue the controller was given.
func (m *Model) SetQueue(queue []library.Track, index int) { m.state.SetQueue(queue, index) }

// --- M5 metadata state (see internal/ui/model/enrichment.go) ---------

// SetMetadataActions installs the enrichment callbacks.
func (m *Model) SetMetadataActions(actions model.MetadataActions) {
	m.state.SetMetadataActions(actions)
}

// SetEnrichment replaces the metadata panel's snapshot.
func (m *Model) SetEnrichment(view model.EnrichmentView) { m.state.SetEnrichment(view) }

// SetAISettings installs the AI fallback configuration.
func (m *Model) SetAISettings(settings metadata.AISettings, errMsg string) {
	m.state.SetAISettings(settings, errMsg)
}

// SetLogf installs the model's logger.
func (m *Model) SetLogf(logf func(format string, args ...any)) { m.state.SetLogf(logf) }

// SetMatchCandidates fills the manual-match dialog.
func (m *Model) SetMatchCandidates(candidates []model.MatchCandidate, errMsg string) {
	m.state.SetMatchCandidates(candidates, errMsg)
}

// MatchApplied closes the dialog after a successful write.
func (m *Model) MatchApplied(message string) { m.state.MatchApplied(message) }

// MatchFailed reports a write failure in the dialog.
func (m *Model) MatchFailed(message string) { m.state.MatchFailed(message) }

// --- M3 remote-source state (see internal/ui/model/sourceform.go) -----

// OpenSourceForm opens the add/re-login panel.
func (m *Model) OpenSourceForm(kind, editing string) { m.state.OpenSourceForm(kind, editing) }

// CloseSourceForm hides it.
func (m *Model) CloseSourceForm() { m.state.CloseSourceForm() }

// SetSourceFormBusy marks the form busy and shows a message.
func (m *Model) SetSourceFormBusy(busy bool, message string) {
	m.state.SetSourceFormBusy(busy, message)
}

// SetSourceFormMessage replaces the form's message line.
func (m *Model) SetSourceFormMessage(message string) { m.state.SetSourceFormMessage(message) }

// SetSourceQR shows the QR image and phase sentence.
func (m *Model) SetSourceQR(bitmap *ui.Bitmap, phase string) { m.state.SetSourceQR(bitmap, phase) }

// SourceForm exposes the form state.
func (m *Model) SourceForm() *model.SourceForm { return m.state.SourceForm() }

// SetSourceError records that a source needs a re-login.
func (m *Model) SetSourceError(sourceID, message string) {
	m.state.SetSourceError(sourceID, message)
}

// ClearSourceError drops a source's error.
func (m *Model) ClearSourceError(sourceID string) { m.state.ClearSourceError(sourceID) }

// SetScan updates the scan panel.
func (m *Model) SetScan(state ScanState) { m.state.SetScan(state) }

// SetStatus sets the line beside a page title.
func (m *Model) SetStatus(status string) { m.state.SetStatus(status) }

// SetError sets the error line.
func (m *Model) SetError(message string) { m.state.SetError(message) }

// SetCoversDir is where content-addressed cover files live.
func (m *Model) SetCoversDir(dir string) { m.state.SetCoversDir(dir) }

// ConfigureDataDir loads settings.json and records the read-only rule.
func (m *Model) ConfigureDataDir(dataDir string, writable bool) {
	m.state.ConfigureDataDir(dataDir, writable)
}

// Scan returns the scan state (the app uses it for logging).
func (m *Model) Scan() ScanState { return m.state.Scan() }

// Volume returns the volume the view shows.
func (m *Model) Volume() float64 { return m.state.Volume() }

// Revision returns the library revision the view last showed.
func (m *Model) Revision() uint64 { return m.state.Revision() }

// View builds the window.
func (m *Model) View(c *ui.Context) {
	s := m.state
	s.Tick(c.Now())
	dark := s.Settings().Dark(c.Theme().Dark)
	d := components.Resolve(c, dark, s.Settings().Compact())
	handleShortcuts(c, s)

	if s.ShouldOnboard() {
		pages.Onboarding(c, d, s)
		return
	}
	if s.Page() == model.PageStage {
		pages.Stage(c, d, s)
		components.Palette(c, d, s)
		components.MatchDialog(c, d, s)
		return
	}

	c.Root().Background(d.P.Canvas)
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		sidebar(c, d, s)
		ui.Column(c).Grow(1).FillHeight().Background(d.P.Canvas).Children(func() {
			page(c, d, s)
			components.Transport(c, d, s)
		})
	})
	components.Palette(c, d, s)
	components.MatchDialog(c, d, s)
}

func page(c *ui.Context, d components.Design, s *model.State) {
	switch s.Page() {
	case model.PageLibrary:
		pages.Library(c, d, s)
	case model.PageFavorites:
		pages.Favorites(c, d, s)
	case model.PageAlbums:
		pages.Albums(c, d, s)
	case model.PageArtists:
		pages.Artists(c, d, s)
	case model.PagePlaylists:
		pages.Playlists(c, d, s)
	case model.PagePlaylistDetail:
		pages.PlaylistDetail(c, d, s)
	case model.PageSearch:
		pages.Search(c, d, s)
	case model.PageSettings:
		pages.Settings(c, d, s)
	case model.PageSources:
		pages.Sources(c, d, s)
	case model.PageQueue:
		pages.Queue(c, d, s)
	case model.PageLyrics:
		pages.Lyrics(c, d, s)
	case model.PageAlbumDetail:
		pages.AlbumDetail(c, d, s)
	case model.PageArtistDetail:
		pages.ArtistDetail(c, d, s)
	default:
		pages.Library(c, d, s)
	}
}

func sidebar(c *ui.Context, d components.Design, s *model.State) {
	ui.Column(c).Width(d.SidebarWidth()).FillHeight().Padding(tokens.Space16, tokens.Space12).
		Gap(tokens.Space8).Background(d.P.Surface).BorderWidth(0, 1, 0, 0).
		BorderColor(d.P.Border).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			ui.Box(c).Size(26, 26).Radius(tokens.RadiusSM).Background(d.P.Accent).Center().Children(func() {
				ui.Icon(c, components.IconMusic).FontSize(15).TextColor(d.P.OnAccent)
			})
			ui.Column(c).Gap(1).Children(func() {
				d.Text(c, tokens.TitleM, "听屿").TextColor(d.P.TextPrimary)
				d.Text(c, tokens.LabelS, "声档").TextColor(d.P.TextTertiary)
			})
		})
		query := s.SidebarQuery()
		focus := s.TakeSearchFocus()
		d.SearchBox(c, &query, "侧栏搜索", "搜索歌曲、专辑、艺术家", focus,
			func() { s.SetSidebarQuery(query) }, nil, nil).
			Tooltip("搜索（⌘K 命令面板，⌘F 聚焦）")
		ui.Scroll(c).Grow(1).Children(func() {
			ui.Column(c).Gap(2).Children(func() {
				navItem(c, d, s, "曲库", model.PageLibrary)
				navItem(c, d, s, "收藏", model.PageFavorites)
				navItem(c, d, s, "专辑", model.PageAlbums)
				navItem(c, d, s, "艺术家", model.PageArtists)
				navItem(c, d, s, "歌单", model.PagePlaylists)
				navItem(c, d, s, "搜索", model.PageSearch)
				ui.Box(c).Height(tokens.Space8)
				ui.Row(c).AlignItems(ui.Center).Children(func() {
					d.Text(c, tokens.LabelS, "来源").TextColor(d.P.TextTertiary)
					ui.Spacer(c)
					if b := d.Button(c, "管理").FontSize(11); b.Clicked() {
						s.OpenPage(model.PageSources)
					}
				})
				if len(s.Sources()) == 0 {
					ui.Row(c).Padding(tokens.Space8, tokens.Space4).Children(func() {
						d.Text(c, tokens.BodyS, "尚未添加来源").TextColor(d.P.TextTertiary)
					})
				}
				for _, source := range s.Sources() {
					source := source
					row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space6).
						Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
					if row.Hovered() {
						row.Background(d.P.Hover)
					}
					row.OnClick(func() {
						s.Library().SetSource(source.ID)
						s.OpenPage(model.PageLibrary)
					})
					row.Children(func() {
						ui.Icon(c, components.IconFolder).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
						d.Text(c, tokens.BodyS, source.Name).TextColor(d.P.TextSecondary).Grow(1).SingleLine()
						d.Textf(c, tokens.LabelS, "%d", source.TrackCount).TextColor(d.P.TextTertiary)
					})
				}
				ui.Box(c).Height(tokens.Space8)
				ui.Row(c).AlignItems(ui.Center).Children(func() {
					d.Text(c, tokens.LabelS, "播放列表").TextColor(d.P.TextTertiary)
					ui.Spacer(c)
					newPlaylist := d.Button(c, "").Padding(2).Radius(tokens.RadiusXS).Label("新建播放列表")
					newPlaylist.Children(func() {
						ui.Icon(c, components.IconPlus).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
					})
					if newPlaylist.Clicked() {
						s.BeginCreatePlaylist()
						s.OpenPage(model.PagePlaylists)
					}
				})
				if len(s.Playlists()) == 0 {
					ui.Row(c).Padding(tokens.Space8, tokens.Space4).Children(func() {
						d.Text(c, tokens.BodyS, "尚未创建播放列表").TextColor(d.P.TextTertiary)
					})
				}
				for _, playlist := range s.Playlists() {
					playlist := playlist
					row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space6).
						Padding(tokens.Space8, tokens.Space6).Radius(tokens.RadiusSM)
					if row.Hovered() {
						row.Background(d.P.Hover)
					}
					row.OnClick(func() { s.OpenPlaylist(playlist) })
					row.Children(func() {
						ui.Icon(c, components.IconQueue).FontSize(tokens.IconCompact).TextColor(d.P.TextTertiary)
						d.Text(c, tokens.BodyS, playlist.Name).TextColor(d.P.TextSecondary).Grow(1).SingleLine()
						d.Textf(c, tokens.LabelS, "%d", playlist.TrackCount).TextColor(d.P.TextTertiary)
					})
				}
			})
		})
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			navItem(c, d, s, "设置", model.PageSettings)
		})
		d.Text(c, tokens.LabelS, model.Version).TextColor(d.P.TextTertiary)
	})
}

func navItem(c *ui.Context, d components.Design, s *model.State, label, page string) {
	active := s.Page() == page
	row := ui.Row(c).FillWidth().Padding(tokens.Space10, tokens.Space6).Radius(tokens.RadiusMD).
		AlignItems(ui.Center)
	if active {
		row.Background(d.P.Selected)
	} else if row.Hovered() {
		row.Background(d.P.Hover)
	}
	row.OnClick(func() { s.OpenPage(page) })
	row.Children(func() {
		color := d.P.TextSecondary
		if active {
			color = d.P.Accent
		}
		d.Text(c, tokens.BodyM, label).TextColor(color)
	})
}

func handleShortcuts(c *ui.Context, s *model.State) {
	c.OnShortcut(ui.Cmd, ui.KeyK, func() {
		if s.Palette().Open {
			s.ClosePalette()
			return
		}
		s.OpenPalette()
	})
	c.OnShortcut(ui.Cmd, ui.KeyF, func() {
		if s.Page() != model.PageSearch {
			s.OpenPage(model.PageSearch)
		}
		s.RequestSearchFocus()
	})
	c.OnShortcut(ui.Cmd, ui.KeyComma, func() { s.OpenPage(model.PageSettings) })
	c.OnShortcut(ui.Cmd, ui.Key1, func() { s.OpenPage(model.PageLibrary) })
	c.OnShortcut(ui.Cmd, ui.Key2, func() { s.OpenPage(model.PageSearch) })
	c.OnShortcut(ui.Cmd, ui.Key3, func() { s.OpenPage(model.PageFavorites) })
	c.OnShortcut(ui.Cmd, ui.Key4, func() { s.OpenPage(model.PageSources) })
	c.OnShortcut(ui.Cmd|ui.Shift, ui.KeyP, func() { s.OpenStage() })
	c.OnShortcut(ui.Cmd, ui.KeyL, func() { s.OpenPage(model.PageLyrics) })
	c.OnShortcut(ui.Cmd, ui.KeyU, func() { s.OpenPage(model.PageQueue) })
	c.OnShortcut(0, ui.KeyEscape, func() {
		switch {
		case s.Palette().Open:
			s.ClosePalette()
		case s.Page() == model.PageStage:
			s.CloseStage()
		}
	})
	c.OnShortcut(0, ui.KeySpace, func() {
		if a := s.Actions(); a != nil {
			_ = a.TogglePlayPause()
		}
	})
	c.OnShortcut(ui.Cmd, ui.KeyLeft, func() {
		if a := s.Actions(); a != nil {
			_ = a.Previous()
		}
	})
	c.OnShortcut(ui.Cmd, ui.KeyRight, func() {
		if a := s.Actions(); a != nil {
			_ = a.Next()
		}
	})
	c.OnShortcut(ui.Cmd|ui.Shift, ui.KeyLeft, func() { seekBy(s, -10*time.Second) })
	c.OnShortcut(ui.Cmd|ui.Shift, ui.KeyRight, func() { seekBy(s, 10*time.Second) })
	c.OnShortcut(ui.Cmd, ui.KeyUp, func() { volumeBy(s, 0.05) })
	c.OnShortcut(ui.Cmd, ui.KeyDown, func() { volumeBy(s, -0.05) })
}

func seekBy(s *model.State, delta time.Duration) {
	update := s.Player()
	if update.Track == nil {
		return
	}
	target := update.Snapshot.Position + delta
	if target < 0 {
		target = 0
	}
	if update.Snapshot.Duration > 0 && target > update.Snapshot.Duration {
		target = update.Snapshot.Duration
	}
	if a := s.Actions(); a != nil {
		_ = a.Seek(target)
	}
}

func volumeBy(s *model.State, delta float64) {
	volume := s.Volume() + delta
	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}
	s.SetVolume(volume)
	if a := s.Actions(); a != nil {
		_ = a.SetVolume(volume)
	}
}

// Formatting helpers kept for the M1 tests that call them.
func formatDuration(d time.Duration) string { return model.FormatDuration(d) }
