// Package shell is the M1 UI: sidebar, library table, scan progress and the
// transport. It holds no window, no database handle and no engine; the app
// package wires its buttons to the controller.
package shell

import (
	"fmt"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/player"
)

// navItem is one sidebar entry. Only the library exists in M1; the others are
// placeholders for M4 and say so instead of pretending to work.
type navItem struct {
	label  string
	active bool
}

var navItems = []navItem{
	{label: "曲库", active: true},
	{label: "收藏"},
	{label: "专辑"},
	{label: "艺术家"},
	{label: "歌单"},
	{label: "搜索"},
	{label: "设置"},
}

// Window sizes. The assembly opens the window with these; the minimum is the
// acceptance floor (900×600).
const (
	DefaultWidth  = 1200
	DefaultHeight = 760
	MinimumWidth  = 900
	MinimumHeight = 600
)

// Actions are what the view can ask the app to do. The app implements them;
// tests pass a recorder.
type Actions interface {
	PlayTracks(tracks []library.Track, start int) error
	TogglePlayPause() error
	Next() error
	Previous() error
	Seek(position time.Duration) error
	SetVolume(volume float64) error
	CycleRepeat() player.RepeatMode
	ChooseDirectory()
}

// ScanState is what the view shows about a scan.
type ScanState struct {
	Running bool
	Done    int
	Total   int
	Path    string
	Status  string
	Error   string
}

// rowKey is the table's row identity: the track id plus its row revision, so
// a metadata-only change rebuilds that row (and only that row). This is the
// audit's "刷新指纹遗漏元数据" fix in the immediate-mode world.
type rowKey struct {
	ID  string
	Rev uint64
}

// Model is the state the window shows.
type Model struct {
	actions Actions
	tracks  []library.Track
	rowRevs map[string]uint64
	rev     uint64
	dbPath  string
	loadErr error

	table    ui.ListState
	selected int

	playing  player.Update
	hasQueue bool
	volume   float64
	repeat   player.RepeatMode

	seekValue   float64
	seekPressed bool

	scan    ScanState
	status  string
	failure string
}

// New builds a model. loadErr means the library could not be opened at all;
// the window explains it instead of showing a blank table.
func New(tracks []library.Track, dbPath string, loadErr error) *Model {
	m := &Model{
		tracks:  tracks,
		dbPath:  dbPath,
		loadErr: loadErr,
		volume:  1,
		repeat:  player.RepeatAll,
	}
	m.table.Key = func(row int) any {
		if row < 0 || row >= len(m.tracks) {
			return row
		}
		return rowKey{ID: m.tracks[row].ID, Rev: m.rowRevs[m.tracks[row].ID]}
	}
	m.table.Label = func(row int) string {
		if row < 0 || row >= len(m.tracks) {
			return ""
		}
		return m.tracks[row].Title
	}
	return m
}

// SetActions installs the callbacks.
func (m *Model) SetActions(actions Actions) { m.actions = actions }

// SetTracks replaces the visible library. revision is the library's write
// counter and rowRevs the per-row counters; both are kept so the view can
// rebuild when metadata (not just the row count) changed.
func (m *Model) SetTracks(tracks []library.Track, revision uint64, rowRevs map[string]uint64) {
	previousID := ""
	if m.selected >= 0 && m.selected < len(m.tracks) {
		previousID = m.tracks[m.selected].ID
	}
	m.tracks = tracks
	m.rev = revision
	m.rowRevs = rowRevs
	m.selected = -1
	for i, track := range tracks {
		if track.ID == previousID {
			m.selected = i
			break
		}
	}
}

// Revision returns the library revision the view last showed.
func (m *Model) Revision() uint64 { return m.rev }

// SetPlayer applies a playback update.
func (m *Model) SetPlayer(update player.Update) {
	m.playing = update
	m.hasQueue = update.Track != nil
	if update.Track != nil && update.PlayCount > 0 {
		for i := range m.tracks {
			if m.tracks[i].ID == update.Track.ID {
				m.tracks[i].PlayCount = update.PlayCount
				break
			}
		}
	}
	if update.Failure != nil {
		m.failure = update.Failure.Message
	} else if update.Snapshot.Playing {
		m.failure = ""
	}
	if update.Repeat != m.repeat {
		m.repeat = update.Repeat
	}
	if update.Snapshot.Volume > 0 {
		m.volume = update.Snapshot.Volume
	}
}

// Volume returns the volume the view shows.
func (m *Model) Volume() float64 { return m.volume }

// SetScan updates the scan panel.
func (m *Model) SetScan(state ScanState) { m.scan = state }

// SetStatus sets the line under the header.
func (m *Model) SetStatus(status string) { m.status = status }

// SetError sets an error line shown next to the status.
func (m *Model) SetError(message string) { m.failure = message }

// Scan returns the scan state (the app uses it for logging).
func (m *Model) Scan() ScanState { return m.scan }

// Tracks returns the tracks the view shows.
func (m *Model) Tracks() []library.Track { return m.tracks }

func (m *Model) View(c *ui.Context) {
	c.Root().Background(c.Theme().Background)
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		m.sidebar(c)
		m.content(c)
	})
}

func (m *Model) sidebar(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Width(216).Padding(16, 14).Gap(4).Background(t.Surface).Children(func() {
		ui.Text(c, "听屿").FontSize(20).Bold()
		ui.Text(c, "M1 主线").FontSize(11).TextColor(t.TextMuted)
		ui.Box(c).Height(10)
		for _, item := range navItems {
			if item.active {
				ui.Row(c).Padding(7, 10).Radius(6).Background(t.Accent).Children(func() {
					ui.Text(c, item.label).FontSize(13).TextColor(t.AccentText)
				})
				continue
			}
			ui.Row(c).Padding(7, 10).Gap(8).Children(func() {
				ui.Text(c, item.label).FontSize(13).TextColor(t.TextMuted)
				ui.Spacer(c)
				ui.Text(c, "M4").FontSize(10).TextColor(t.TextMuted)
			})
		}
		ui.Spacer(c)
		ui.Text(c, m.sidebarStatus()).FontSize(11).TextColor(t.TextMuted)
	})
}

func (m *Model) sidebarStatus() string {
	if m.playing.Snapshot.Playing {
		return "正在播放"
	}
	if m.hasQueue {
		return "已暂停"
	}
	return "本地曲库"
}

func (m *Model) content(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Grow(1).Padding(20, 18).Gap(10).Background(t.Background).Children(func() {
		m.header(c)
		if m.failure != "" && m.loadErr == nil {
			ui.Textf(c, "⚠ %s", m.failure).FontSize(11).TextColor(t.Danger).SingleLine()
		}
		if m.scan.Running || m.scan.Status != "" || m.scan.Error != "" {
			m.scanPanel(c)
		}
		if m.loadErr != nil {
			m.errorPanel(c)
			return
		}
		if len(m.tracks) == 0 {
			ui.Column(c).Grow(1).Center().Gap(8).Children(func() {
				ui.Text(c, "曲库为空").FontSize(14).TextColor(t.TextMuted)
				ui.Text(c, "点「添加目录…」选一个音乐文件夹，扫描后会出现在这里").FontSize(12).TextColor(t.TextMuted)
			})
		} else {
			m.trackTable(c)
		}
		m.transport(c)
		ui.Row(c).Gap(8).Children(func() {
			ui.Text(c, m.dbPath).FontSize(10).TextColor(t.TextMuted).SingleLine()
			ui.Text(c, "· 写入仅限扫描入库与播放历史").FontSize(10).TextColor(t.TextMuted)
		})
	})
}

func (m *Model) header(c *ui.Context) {
	t := c.Theme()
	ui.Row(c).AlignItems(ui.Center).Gap(10).Children(func() {
		ui.Text(c, "曲库").FontSize(22).Bold()
		ui.Textf(c, "%d 首", len(m.tracks)).FontSize(12).TextColor(t.TextMuted)
		ui.Spacer(c)
		if m.status != "" {
			ui.Text(c, m.status).FontSize(11).TextColor(t.TextMuted).SingleLine()
		}
		ui.Button(c, "添加目录…").OnClick(func() {
			if m.actions != nil {
				m.actions.ChooseDirectory()
			}
		})
	})
}

func (m *Model) scanPanel(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Gap(4).Padding(10, 8).Radius(6).Background(t.Surface).Children(func() {
		if m.scan.Running {
			ui.Row(c).Gap(8).Children(func() {
				ui.Spinner(c)
				if m.scan.Total > 0 {
					ui.Textf(c, "正在扫描 %d/%d", m.scan.Done, m.scan.Total).FontSize(12)
				} else {
					ui.Text(c, "正在扫描…").FontSize(12)
				}
				ui.Text(c, m.scan.Path).FontSize(10).TextColor(t.TextMuted).SingleLine()
			})
			if m.scan.Total > 0 {
				ui.Progress(c, float64(m.scan.Done)/float64(m.scan.Total))
			}
			return
		}
		color := t.TextMuted
		text := m.scan.Status
		if m.scan.Error != "" {
			color = t.Danger
			text = m.scan.Error
		}
		if text != "" {
			ui.Text(c, text).FontSize(12).TextColor(color)
		}
	})
}

func (m *Model) trackTable(c *ui.Context) {
	columns := []ui.TableColumn{
		{Title: "曲名"},
		{Title: "艺术家", Width: 170},
		{Title: "专辑", Width: 210},
		{Title: "时长", Width: 70, Align: ui.End},
		{Title: "播放", Width: 56, Align: ui.End},
	}
	m.table.Selected = &m.selected
	if ui.Table(c, &m.table, columns, len(m.tracks), func(row, col int) {
		track := m.tracks[row]
		current := m.playing.Track != nil && m.playing.Track.ID == track.ID
		switch col {
		case 0:
			title := track.Title
			if current {
				title = "▶ " + title
			}
			ui.Text(c, title).SingleLine()
		case 1:
			ui.Text(c, track.Artist).SingleLine()
		case 2:
			ui.Text(c, track.Album).SingleLine()
		case 3:
			ui.Text(c, formatDuration(track.Duration)).SingleLine()
		case 4:
			ui.Textf(c, "%d", track.PlayCount).SingleLine()
		}
	}).Grow(1).Submitted() {
		m.playSelected()
	}
}

func (m *Model) playSelected() {
	if m.actions == nil || m.selected < 0 || m.selected >= len(m.tracks) {
		return
	}
	_ = m.actions.PlayTracks(m.tracks, m.selected)
}

func (m *Model) transport(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Gap(6).Padding(12, 10).Radius(8).Background(t.Surface).Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(10).Children(func() {
			title := "未在播放"
			subtitle := ""
			if m.playing.Track != nil {
				title = m.playing.Track.Title
				subtitle = m.playing.Track.Artist + " · " + m.playing.Track.Album
			}
			ui.Column(c).Gap(2).Children(func() {
				ui.Text(c, title).FontSize(13).Bold().SingleLine()
				if subtitle != "" {
					ui.Text(c, subtitle).FontSize(10).TextColor(t.TextMuted).SingleLine()
				}
			})
			ui.Spacer(c)
			ui.Button(c, "上一首").OnClick(func() {
				if m.actions != nil {
					_ = m.actions.Previous()
				}
			})
			label := "播放"
			if m.playing.Snapshot.Playing {
				label = "暂停"
			}
			ui.Button(c, label).OnClick(func() {
				if m.actions != nil {
					_ = m.actions.TogglePlayPause()
				}
			})
			ui.Button(c, "下一首").OnClick(func() {
				if m.actions != nil {
					_ = m.actions.Next()
				}
			})
			ui.Button(c, "循环："+m.repeat.String()).OnClick(func() {
				if m.actions != nil {
					m.repeat = m.actions.CycleRepeat()
				}
			})
		})
		ui.Row(c).AlignItems(ui.Center).Gap(10).Children(func() {
			position := m.playing.Snapshot.Position
			duration := m.playing.Snapshot.Duration
			if duration <= 0 && m.playing.Track != nil {
				duration = m.playing.Track.Duration
			}
			end := duration.Seconds()
			if end <= 0 {
				end = 1
			}
			if !m.seekPressed {
				m.seekValue = position.Seconds()
			}
			ui.Text(c, formatDuration(position)).FontSize(10).TextColor(t.TextMuted)
			slider := ui.Slider(c, &m.seekValue, 0, end).Grow(1)
			if slider.Pressed() {
				m.seekPressed = true
			}
			if slider.Changed() {
				if m.actions != nil {
					_ = m.actions.Seek(time.Duration(m.seekValue * float64(time.Second)))
				}
			}
			if m.seekPressed && !slider.Pressed() {
				m.seekPressed = false
			}
			ui.Text(c, formatDuration(duration)).FontSize(10).TextColor(t.TextMuted)
			ui.Text(c, "音量").FontSize(10).TextColor(t.TextMuted)
			volume := m.volume
			volumeSlider := ui.Slider(c, &volume, 0, 1).Width(110)
			if volumeSlider.Changed() {
				m.volume = volume
				if m.actions != nil {
					_ = m.actions.SetVolume(volume)
				}
			}
		})
	})
}

func (m *Model) errorPanel(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Grow(1).Center().Gap(10).Children(func() {
		ui.Text(c, "无法打开曲库").FontSize(18).Bold()
		ui.Text(c, m.loadErr.Error()).FontSize(12).TextColor(t.Danger)
		ui.Text(c, m.dbPath).FontSize(11).TextColor(t.TextMuted).SingleLine()
		ui.Text(c, "不创建、不迁移、不修复数据库；请检查 TINGYU_DATA_DIR 指向的副本").FontSize(11).TextColor(t.TextMuted)
	})
}

// formatDuration shows a track's length as 3:49, or 1:02:03 past an hour.
func formatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	seconds := int64(d / time.Second)
	if seconds >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", seconds/3600, seconds%3600/60, seconds%60)
	}
	return fmt.Sprintf("%d:%02d", seconds/60, seconds%60)
}
