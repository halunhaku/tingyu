// Package shell is the M0 UI shell: the sidebar and the ui.Table of
// tracks. It holds no window, no database handle and no write path; the
// app package assembles it into a window.
package shell

import (
	"fmt"
	"time"

	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
)

// navItem is one sidebar entry. M0 only has the library; the others are
// placeholders for M4, and say so instead of pretending to work.
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

// Window sizes. The assembly opens the window with these; the minimum is
// the M0 acceptance floor (900×600).
const (
	DefaultWidth  = 1200
	DefaultHeight = 760
	MinimumWidth  = 900
	MinimumHeight = 600
)

// Model is the state the window shows: the tracks read once at startup,
// the table's own state, and what went wrong when the library could not be
// read. It has no write path: the M0 client only ever reads.
type Model struct {
	tracks  []library.Track
	dbPath  string
	loadErr error
	table   ui.ListState
}

func New(tracks []library.Track, dbPath string, loadErr error) *Model {
	a := &Model{tracks: tracks, dbPath: dbPath, loadErr: loadErr}
	a.table.Key = func(row int) any { return a.tracks[row].ID }
	a.table.Label = func(row int) string { return a.tracks[row].Title }
	return a
}

func (a *Model) View(c *ui.Context) {
	c.Root().Background(c.Theme().Background)
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		a.sidebar(c)
		a.content(c)
	})
}

func (a *Model) sidebar(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Width(216).Padding(16, 14).Gap(4).Background(t.Surface).Children(func() {
		ui.Text(c, "听屿").FontSize(20).Bold()
		ui.Text(c, "M0 骨架").FontSize(11).TextColor(t.TextMuted)
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
		ui.Text(c, "只读曲库").FontSize(11).TextColor(t.TextMuted)
	})
}

func (a *Model) content(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Grow(1).Padding(20, 18).Gap(12).Background(t.Background).Children(func() {
		ui.Row(c).AlignItems(ui.End).Gap(10).Children(func() {
			ui.Text(c, "曲库").FontSize(22).Bold()
			ui.Textf(c, "%d 首", len(a.tracks)).FontSize(12).TextColor(t.TextMuted)
			ui.Spacer(c)
			ui.Text(c, "只读演示").FontSize(11).TextColor(t.TextMuted)
		})
		if a.loadErr != nil {
			a.errorPanel(c)
			return
		}
		if len(a.tracks) == 0 {
			ui.Column(c).Grow(1).Center().Children(func() {
				ui.Text(c, "曲库为空").FontSize(14).TextColor(t.TextMuted)
			})
		} else {
			a.trackTable(c)
		}
		ui.Row(c).Gap(8).Children(func() {
			ui.Text(c, a.dbPath).FontSize(10).TextColor(t.TextMuted).SingleLine()
			ui.Text(c, "· 以 mode=ro 打开 · 写入未实现").FontSize(10).TextColor(t.TextMuted)
		})
	})
}

func (a *Model) trackTable(c *ui.Context) {
	// Sorting is M4: the rows arrive pre-sorted from the library query.
	columns := []ui.TableColumn{
		{Title: "曲名"},
		{Title: "艺术家", Width: 190},
		{Title: "专辑", Width: 230},
		{Title: "时长", Width: 72, Align: ui.End},
	}
	ui.Table(c, &a.table, columns, len(a.tracks), func(row, col int) {
		track := a.tracks[row]
		switch col {
		case 0:
			ui.Text(c, track.Title).SingleLine()
		case 1:
			ui.Text(c, track.Artist).SingleLine()
		case 2:
			ui.Text(c, track.Album).SingleLine()
		case 3:
			ui.Text(c, formatDuration(track.Duration)).SingleLine()
		}
	}).Grow(1)
}

func (a *Model) errorPanel(c *ui.Context) {
	t := c.Theme()
	ui.Column(c).Grow(1).Center().Gap(10).Children(func() {
		ui.Text(c, "无法打开曲库").FontSize(18).Bold()
		ui.Text(c, a.loadErr.Error()).FontSize(12).TextColor(t.Danger)
		ui.Text(c, a.dbPath).FontSize(11).TextColor(t.TextMuted).SingleLine()
		ui.Text(c, "M0 只读：不创建、不迁移、不修复数据库").FontSize(11).TextColor(t.TextMuted)
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
