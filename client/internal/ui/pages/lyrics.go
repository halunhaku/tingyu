package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// Lyrics is the standalone lyrics page (the stage also shows this view in its
// side panel).
func Lyrics(c *ui.Context, d components.Design, s *model.State) {
	title := "歌词"
	subtitle := ""
	if track, lyrics, ok := s.CurrentLyrics(); ok {
		title = track.Title
		if lyrics.Synced {
			subtitle = "随播放高亮 · 点击一行跳到该处"
		} else {
			subtitle = "未同步歌词"
		}
	}
	Page(c, d, s, title, subtitle, s.Back, func() {
		if b := d.Button(c, "播放舞台"); b.Clicked() {
			s.OpenStage()
		}
	}, func() {
		components.LyricsView(c, d, s)
	})
}
