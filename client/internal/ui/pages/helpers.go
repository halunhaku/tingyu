package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Page is the common frame of every page: page padding, header and notice.
func Page(c *ui.Context, d components.Design, s *model.State, title, subtitle string, back func(), actions func(), body func()) {
	width, _ := c.Size()
	ui.Column(c).Width(width-d.SidebarWidth()).FillHeight().
		Padding(tokens.Space16, d.PagePadding()).
		Gap(tokens.Space10).Background(d.P.Canvas).Children(func() {
		components.Header(c, d, title, subtitle, back, actions)
		components.Notice(c, d, s.Notice(), s.DismissNotice)
		if s.Error() != "" {
			ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space6).Children(func() {
				ui.Icon(c, components.IconInfo).FontSize(tokens.IconCompact).TextColor(d.P.Danger)
				d.Text(c, tokens.Small, s.Error()).TextColor(d.P.Danger).Wrap()
			})
		}
		body()
	})
}

// ScanPanel shows the running scan or its last outcome.
func ScanPanel(c *ui.Context, d components.Design, scan model.ScanState) {
	if !scan.Running && scan.Status == "" && scan.Error == "" {
		return
	}
	ui.Column(c).Gap(tokens.Space6).Padding(tokens.Space12, tokens.Space10).
		Radius(tokens.RadiusMD).Background(d.P.SurfaceRaised).Border(1, d.P.Border).Children(func() {
		if scan.Running {
			ui.Row(c).Gap(tokens.Space8).AlignItems(ui.Center).Children(func() {
				ui.Spinner(c)
				if scan.SourceName != "" {
					d.Textf(c, tokens.Small, "正在同步「%s」· 已发现 %d 首", scan.SourceName, scan.Done).
						TextColor(d.P.TextPrimary)
				} else if scan.Total > 0 {
					d.Textf(c, tokens.Small, "正在扫描 %d/%d", scan.Done, scan.Total).TextColor(d.P.TextPrimary)
				} else {
					d.Text(c, tokens.Small, "正在扫描…").TextColor(d.P.TextPrimary)
				}
				d.Text(c, tokens.Small, scan.Path).TextColor(d.P.TextTertiary).SingleLine().Grow(1)
			})
			if scan.Total > 0 {
				components.ProgressBar(c, d, float64(scan.Done)/float64(scan.Total))
			}
			return
		}
		text, color := scan.Status, d.P.TextSecondary
		if scan.Error != "" {
			text, color = scan.Error, d.P.Danger
		}
		if text != "" {
			d.Text(c, tokens.Small, text).TextColor(color).Wrap()
		}
	})
}

// SortMenu is the library's sort control: five fields and both directions.
func SortMenu(c *ui.Context, d components.Design, list *model.TrackList) {
	label := "排序：" + list.Sort().String()
	if !list.Asc() {
		label += " ↓"
	}
	ui.MenuButton(c, label, func(m *ui.Menu) {
		for field := model.SortTitle; field <= model.SortAdded; field++ {
			if m.Item(field.String()).Checked(list.Sort() == field).Chosen() {
				list.SetSort(field, list.Asc())
			}
		}
		m.Separator()
		if m.Item("升序").Checked(list.Asc()).Chosen() {
			list.SetSort(list.Sort(), true)
		}
		if m.Item("降序").Checked(!list.Asc()).Chosen() {
			list.SetSort(list.Sort(), false)
		}
	}).Radius(tokens.RadiusSM).FontSize(13)
}

// SourceMenu filters a list by source.
func SourceMenu(c *ui.Context, d components.Design, s *model.State, list *model.TrackList) {
	label := "全部来源"
	for _, source := range s.Sources() {
		if source.ID == s.SourceFilter() {
			label = source.Name
		}
	}
	ui.MenuButton(c, label, func(m *ui.Menu) {
		if m.Item("全部来源").Checked(s.SourceFilter() == "").Chosen() {
			list.SetSource("")
		}
		for _, source := range s.Sources() {
			if m.Item(source.Name).Checked(s.SourceFilter() == source.ID).Chosen() {
				list.SetSource(source.ID)
			}
		}
	}).Radius(tokens.RadiusSM).FontSize(13)
}

// PlayAll starts a list from its first row.
func PlayAll(s *model.State, tracks []library.Track) {
	if len(tracks) == 0 {
		return
	}
	if actions := s.Actions(); actions != nil {
		_ = actions.PlayTracks(tracks, 0)
		s.SetQueue(tracks, 0)
	}
}

// PlayFrom starts a list at a row, with the queue rotated so that row is first
// (the controller does the same rotation for PlayTracks).
func PlayFrom(s *model.State, tracks []library.Track, row int) {
	if len(tracks) == 0 {
		return
	}
	if row < 0 || row >= len(tracks) {
		row = 0
	}
	rotated := append(append([]library.Track{}, tracks[row:]...), tracks[:row]...)
	if actions := s.Actions(); actions != nil {
		_ = actions.PlayTracks(tracks, row)
		s.SetQueue(rotated, 0)
	}
}

// AddDirectoryButton is the shared "添加目录…" action.
func AddDirectoryButton(c *ui.Context, d components.Design, s *model.State) ui.Element {
	button := d.Button(c, "添加目录…")
	if button.Clicked() {
		if actions := s.Actions(); actions != nil {
			actions.ChooseDirectory()
		}
	}
	return button
}
