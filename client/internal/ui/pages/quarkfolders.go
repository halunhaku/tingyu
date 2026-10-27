package pages

import (
	"github.com/egoist/mygo/ui"
	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
	"strings"
)

func requestQuarkFolders(s *model.State) {
	v := s.SourceForm().RequestFolders()
	if a := s.QuarkFolderActionsOf(); a != nil {
		a.BrowseQuarkFolders(v)
	}
}

func quarkFolderPicker(c *ui.Context, d components.Design, s *model.State) {
	f := s.SourceForm()
	width, height := c.Size()
	d.Overlay(c, &f.Open, func() {
		ui.Column(c).Width(min(620, width-48)).Height(min(600, height-48)).Padding(tokens.Space20).Gap(tokens.Space12).
			Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border).Children(func() {
			d.Text(c, tokens.H2, "选择音乐文件夹").TextColor(d.P.TextPrimary).Shrink(0)
			ui.Column(c).Shrink(0).Children(func() { sourceField(c, d, "来源名称", "例如「夸克音乐」", &f.Name) })
			d.Text(c, tokens.Small, "当前位置："+f.FolderPath()).TextColor(d.P.TextSecondary).SingleLine().Shrink(0)
			ui.Row(c).Shrink(0).Gap(tokens.Space8).Children(func() {
				if b := d.Button(c, "全部文件").Disabled(f.Busy || f.CurrentFolder().FID == "0"); b.Clicked() {
					f.FolderTrail = []model.QuarkFolder{{FID: "0", Name: "全部文件"}}
					requestQuarkFolders(s)
				}
				backLabel := "上一级"
				if len(f.FolderTrail) == 2 && strings.Contains(f.FolderTrail[1].Name, "/") {
					backLabel = "返回全部文件"
				}
				if b := d.Button(c, backLabel).Disabled(f.Busy || len(f.FolderTrail) <= 1); b.Clicked() {
					f.FolderTrail = f.FolderTrail[:len(f.FolderTrail)-1]
					requestQuarkFolders(s)
				}
				if b := d.Button(c, "刷新目录").Disabled(f.Busy); b.Clicked() {
					requestQuarkFolders(s)
				}
			})
			ui.Scroll(c).Grow(1).MinHeight(80).FillWidth().Border(1, d.P.Border).Radius(tokens.RadiusSM).Children(func() {
				ui.Column(c).FillWidth().Padding(tokens.Space8).Gap(tokens.Space4).Children(func() {
					if f.Busy {
						d.Text(c, tokens.Small, "正在加载…").TextColor(d.P.TextSecondary)
						return
					}
					if f.Message != "" {
						d.Text(c, tokens.Small, f.Message).TextColor(d.P.Danger).Wrap()
						return
					}
					if len(f.Folders) == 0 {
						d.Text(c, tokens.Small, "没有子文件夹，可直接选择当前目录。").TextColor(d.P.TextSecondary)
						return
					}
					for _, folder := range f.Folders {
						folder := folder
						b := ui.Button(c, "").FillWidth().Height(36).Label("打开文件夹：" + folder.Name).Radius(tokens.RadiusSM)
						b.Children(func() {
							ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
								ui.Icon(c, components.IconFolder).FontSize(16).TextColor(d.P.Accent)
								d.Text(c, tokens.Body, folder.Name).Grow(1).SingleLine().TextColor(d.P.TextPrimary)
								ui.Icon(c, components.IconForward).FontSize(12).TextColor(d.P.TextTertiary)
							})
						})
						if b.Clicked() {
							f.FolderTrail = append(f.FolderTrail, folder)
							requestQuarkFolders(s)
						}
					}
				})
			})
			message := "同步此目录及其子目录中的音乐，网盘文件不会被修改。"
			if f.Editing != "" {
				message = "更换目录后，同步会更新该来源的曲库曲目；网盘文件不会被修改。"
			}
			d.Text(c, tokens.Small, message).TextColor(d.P.TextSecondary).Wrap().Shrink(0)
			ui.Row(c).FillWidth().Height(32).Shrink(0).Gap(tokens.Space8).Children(func() {
				if b := d.Button(c, "取消选择").Label("取消夸克文件夹"); b.Clicked() {
					if a := s.SourceActionsOf(); a != nil {
						a.CancelSourceLogin()
					}
					s.CloseSourceForm()
				}
				if f.Message != "" {
					if b := d.Button(c, "重新登录"); b.Clicked() {
						id := f.Editing
						s.OpenSourceForm(model.SourceKindQuark, id)
					}
				}
				ui.Spacer(c)
				if b := d.PrimaryButton(c, "使用此文件夹并同步").Label("确认夸克文件夹").Disabled(f.Busy || !f.FolderReady); b.Clicked() {
					if a := s.QuarkFolderActionsOf(); a != nil {
						a.ConfirmQuarkFolder(f.Values())
					}
				}
			})
		})
	})
}
