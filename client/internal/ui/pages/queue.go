package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
)

// Queue is the playback queue: the current track and what plays next. A row
// click jumps to that track (the kernel rebuilds the queue from it; insert,
// remove and reorder stay unimplemented in the controller, as in Flutter).
func Queue(c *ui.Context, d components.Design, s *model.State) {
	queue := s.Queue()
	index := s.QueueIndex()
	actions := func() {
		if b := d.Button(c, "播放舞台"); b.Clicked() {
			s.OpenStage()
		}
	}
	Page(c, d, s, "播放队列", model.FormatCount(len(queue), "首"), s.Back, actions, func() {
		if len(queue) == 0 {
			components.Empty(c, d, components.IconQueue, "暂无待播歌曲",
				"从曲库中播放一首歌后，队列会显示在这里。", func() {
					d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
				})
			return
		}
		if index >= 0 && index < len(queue) {
			components.SectionTitle(c, d, "当前播放", "")
			components.TrackRow(c, d, s, queue[index], true, func() {
				PlayFrom(s, queue, index)
			}).Focusable()
		}
		next := index + 1
		if next < len(queue) {
			components.SectionTitle(c, d, "接下来 "+model.FormatCount(len(queue)-next, "首"), "")
		}
		list := s.QueueList()
		table := ui.List(c, list, max(0, len(queue)-next), func(row int) {
			i := next + row
			if i < 0 || i >= len(queue) {
				return
			}
			track := queue[i]
			components.TrackRow(c, d, s, track, false, func() {
				PlayFrom(s, queue, i)
			})
		}).Grow(1)
		if table.Submitted() {
			if i := next + *list.Selected; *list.Selected >= 0 && i < len(queue) {
				PlayFrom(s, queue, i)
			}
		}
	})
}
