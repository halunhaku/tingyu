package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/library"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// playlistsPage keeps the page's view-only state: which playlist a delete
// confirmation is about, and the name field's text (the model owns the field's
// mode, the widget has to survive frames).
type playlistsPage struct {
	confirmOpen bool
	deleting    library.Playlist
}

func playlistsView(s *model.State) *playlistsPage {
	if v, ok := s.Transient("playlists").(*playlistsPage); ok {
		return v
	}
	v := &playlistsPage{}
	s.SetTransient("playlists", v)
	return v
}

// playlistDeleteDialog is the two-step confirmation DESIGN.md §2.4 asks of a
// destructive action: the playlist is removed, its tracks are not.
func playlistDeleteDialog(c *ui.Context, s *model.State, v *playlistsPage) {
	if !v.confirmOpen {
		return
	}
	title := "删除歌单「" + v.deleting.Name + "」？"
	switch ui.AlertDialog(c, &v.confirmOpen, title, "歌单里的曲目本身不会被删除。", "取消", "确认删除") {
	case 1:
		s.DeletePlaylist(v.deleting)
	}
}

// Playlists is the playlist browser: real rows from SQL, create/rename/delete,
// and a row click that opens the playlist's items.
func Playlists(c *ui.Context, d components.Design, s *model.State) {
	playlists := s.Playlists()
	view := playlistsView(s)
	actions := func() {
		if b := d.Button(c, "新建歌单"); b.Clicked() {
			s.BeginCreatePlaylist()
		}
	}
	summary := ""
	if len(playlists) > 0 {
		summary = model.FormatCount(len(playlists), "个")
	}
	Page(c, d, s, "歌单", summary, nil, actions, func() {
		playlistDeleteDialog(c, s, view)
		// The inline field serves both 新建 and 重命名 here; the detail page
		// shows it for its own playlist.
		if _, ok := s.PlaylistEditID(); ok {
			playlistNameField(c, d, s, "保存")
		}
		if len(playlists) == 0 {
			components.Empty(c, d, components.IconQueue, "还没有歌单",
				"新建一个歌单，再从曲库、专辑或播放舞台把曲目加进来。", func() {
					d.Button(c, "新建歌单").OnClick(s.BeginCreatePlaylist)
				})
			return
		}
		ui.Scroll(c).Grow(1).Children(func() {
			ui.Column(c).Gap(tokens.Space4).Children(func() {
				for _, playlist := range playlists {
					playlist := playlist
					row := ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space12).
						Padding(tokens.Space10, tokens.Space8).Radius(tokens.RadiusSM).Focusable()
					if row.Hovered() {
						row.Background(d.P.Hover)
					}
					row.OnClick(func() { s.OpenPlaylist(playlist) })
					row.Children(func() {
						ui.Box(c).Size(44, 44).Radius(tokens.RadiusMD).Background(d.P.SurfaceSunken).Center().Children(func() {
							ui.Icon(c, components.IconQueue).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
						})
						ui.Column(c).Gap(2).Grow(1).Children(func() {
							d.Text(c, tokens.Body, playlist.Name).TextColor(d.P.TextPrimary).SingleLine()
							d.Textf(c, tokens.Small, "%d 首", playlist.TrackCount).TextColor(d.P.TextSecondary)
						})
						menu := ui.Button(c, "").Width(28).Height(28).Padding(2).Radius(tokens.RadiusXS).
							Label("歌单操作").Tooltip("歌单操作")
						menu.Children(func() {
							ui.Icon(c, components.IconMore).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
						})
						menu.Menu(func(m *ui.Menu) {
							if m.Item("打开").Chosen() {
								s.OpenPlaylist(playlist)
							}
							if m.Item("重命名…").Chosen() {
								s.BeginRenamePlaylist(playlist)
							}
							if m.Item("删除歌单…").Chosen() {
								view.deleting = playlist
								view.confirmOpen = true
							}
						})
					})
				}
			})
		})
	})
}

// playlistNameField is the inline name input for 新建 / 重命名.
func playlistNameField(c *ui.Context, d components.Design, s *model.State, confirm string) {
	value := s.PlaylistEditValue()
	if value == nil {
		return
	}
	ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Padding(tokens.Space12, tokens.Space10).
		Radius(tokens.RadiusMD).Background(d.P.SurfaceRaised).Border(1, d.P.Border).Children(func() {
		d.Text(c, tokens.Small, s.PlaylistEditTitle()).TextColor(d.P.TextSecondary)
		input := ui.TextInput(c, value).Placeholder("歌单名称").Label(s.PlaylistEditTitle()).Grow(1).AutoFocus()
		input.OnTextKey(func(k ui.TextKey) bool {
			switch {
			case k.Mods == 0 && k.Key == ui.KeyEnter:
				s.CommitPlaylistEdit()
				return true
			case k.Mods == 0 && k.Key == ui.KeyEscape:
				s.CancelPlaylistEdit()
				return true
			}
			return false
		})
		if input.Submitted() {
			s.CommitPlaylistEdit()
			return
		}
		if b := d.Button(c, confirm); b.Clicked() {
			s.CommitPlaylistEdit()
		}
		if b := d.Button(c, "取消"); b.Clicked() {
			s.CancelPlaylistEdit()
		}
	})
}

// PlaylistDetail is one playlist: its items in saved order, play/reorder tools
// and the rename/delete actions.
func PlaylistDetail(c *ui.Context, d components.Design, s *model.State) {
	detail := s.PlaylistDetail()
	back := s.Back
	if detail == nil {
		Page(c, d, s, "歌单", "", back, nil, func() {
			components.Empty(c, d, components.IconQueue, "没有可显示的歌单", "回到歌单列表重新选择。", nil)
		})
		return
	}
	playlist := detail.Playlist
	list := s.PlaylistTracks()
	view := playlistsView(s)
	actions := func() {
		if b := d.Button(c, "播放全部"); b.Clicked() {
			PlayAll(s, s.AllOf(list))
		}
		if b := d.Button(c, "随机播放"); b.Clicked() {
			PlayShuffled(s, list)
		}
		if b := d.Button(c, "重命名"); b.Clicked() {
			s.BeginRenamePlaylist(playlist)
		}
		if b := d.Button(c, "删除歌单"); b.Clicked() {
			view.deleting = playlist
			view.confirmOpen = true
		}
	}
	subtitle := model.FormatCount(playlist.TrackCount, "首")
	Page(c, d, s, playlist.Name, subtitle, back, actions, func() {
		playlistDeleteDialog(c, s, view)
		if id, ok := s.PlaylistEditID(); ok && id == playlist.ID {
			playlistNameField(c, d, s, "保存")
		}
		if list.Total() == 0 {
			components.Empty(c, d, components.IconQueue, "这个歌单还是空的",
				"到曲库、专辑或播放舞台，用「添加到播放列表」把曲目加进来。", func() {
					d.Button(c, "去曲库").OnClick(func() { s.OpenPage(model.PageLibrary) })
				})
			return
		}
		components.TrackTable(c, d, components.TableOptions{
			State:      s,
			List:       list,
			PlaylistID: playlist.ID,
		})
		components.Pager(c, d, list, "")
	})
}

// PlayShuffled starts a list with random order: shuffle is a controller state,
// so turning it on first is what makes the queue random (and turning it off
// again gives the list's own order back).
func PlayShuffled(s *model.State, list *model.TrackList) {
	if !s.Shuffle() {
		s.ToggleShuffle()
	}
	PlayAll(s, s.AllOf(list))
}
