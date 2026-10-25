package components

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// CoverMatch is the shared identity of the transport's cover and the stage's
// large cover: a Hero approximation through MyGo's matched transitions.
type CoverMatch struct{ ID string }

// Cover draws a track's cover art, or the music-note placeholder the design
// uses for a missing one. The bitmap comes from the bounded cover cache, so a
// table that scrolls reuses decoded covers rather than reading files per row.
func Cover(c *ui.Context, d Design, s *model.State, name string, size, radius float32) ui.Element {
	if s != nil {
		if bitmap := s.CoverBitmap(name); bitmap != nil {
			return ui.Image(c, bitmap).Size(size, size).Fit(ui.Cover).Radius(radius)
		}
	}
	box := ui.Box(c).Size(size, size).Radius(radius).Background(d.P.CoverPlaceholder).Center()
	box.Children(func() {
		ui.Icon(c, IconMusic).FontSize(size * 0.34).TextColor(d.P.TextTertiary)
	})
	return box
}

// CoverFill draws a cover that takes its parent's width and keeps a square
// aspect, for the album grid's cards.
func CoverFill(c *ui.Context, d Design, s *model.State, name string, radius float32) ui.Element {
	if s != nil {
		if bitmap := s.CoverBitmap(name); bitmap != nil {
			return ui.Image(c, bitmap).FillWidth().AspectRatio(1).Fit(ui.Cover).Radius(radius)
		}
	}
	box := ui.Box(c).FillWidth().AspectRatio(1).Radius(radius).Background(d.P.CoverPlaceholder).Center()
	box.Children(func() {
		ui.Icon(c, IconMusic).FontSize(34).TextColor(d.P.TextTertiary)
	})
	return box
}

// CoverFor is Cover for a track.
func CoverFor(c *ui.Context, d Design, s *model.State, name string, size float32) ui.Element {
	return Cover(c, d, s, name, size, tokens.RadiusSM)
}

// NowPlayingBars is the small accent equalizer drawn beside the current row.
func NowPlayingBars(c *ui.Context, d Design, playing bool) {
	height := tokens.IconCompact
	color := d.P.Accent
	ui.Row(c).AlignItems(ui.End).Gap(2).Height(height).Children(func() {
		heights := []float32{6, 12, 9}
		if !playing {
			heights = []float32{4, 4, 4}
			color = d.P.TextDisabled
		}
		for _, h := range heights {
			ui.Box(c).Width(2).Height(h).Radius(1).Background(color)
		}
	})
}
