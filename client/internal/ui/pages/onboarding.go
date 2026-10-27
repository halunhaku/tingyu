package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Onboarding introduces the three supported music sources.
func Onboarding(c *ui.Context, d components.Design, s *model.State) {
	ui.Column(c).Fill().Gradient(d.P.Canvas, d.P.SurfaceSunken, 160).
		Justify(ui.Center).AlignItems(ui.Center).Padding(tokens.Space32).Children(func() {
		ui.Column(c).Width(760).Gap(tokens.Space20).AlignItems(ui.Center).Children(func() {
			d.Text(c, tokens.H1, "听屿").TextColor(d.P.TextPrimary)
			d.Text(c, tokens.Overline, "TINGYU").TextColor(d.P.Accent).LetterSpacing(2)
			ui.Text(c, "连接本地文件夹或私人云盘，把喜欢的音乐收进听屿。").
				FontSize(15).LineHeight(1.7).TextColor(d.P.TextSecondary).TextAlign(ui.Center).MaxWidth(560).Wrap()
			ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Stretch).Children(func() {
				onboardingCard(c, d, components.IconFolder, "本地文件夹", "选择电脑上的音乐文件夹，自动扫描并整理曲库。", "可用", true, func() {
					s.FinishOnboarding()
					if a := s.Actions(); a != nil {
						a.ChooseDirectory()
					}
				})
				onboardingCard(c, d, components.IconWebDAV, "WebDAV", "连接坚果云等私人存储，直接播放云端音乐。", "可用", true, func() {
					s.FinishOnboarding()
					s.OpenPage(model.PageSources)
					s.OpenSourceForm(model.SourceKindWebDAV, "")
				})
				onboardingCard(c, d, components.IconCloud, "夸克网盘", "登录你的账号，选择需要同步的音乐文件夹。", "可用", true, func() {
					s.FinishOnboarding()
					s.OpenPage(model.PageSources)
					s.OpenSourceForm(model.SourceKindQuark, "")
				})
			})
			ui.Row(c).Gap(tokens.Space10).PaddingY(tokens.Space8).Children(func() {
				if b := d.PrimaryButton(c, "添加音乐来源"); b.Clicked() {
					s.FinishOnboarding()
					s.OpenPage(model.PageSources)
				}
				if b := d.Button(c, "先去设置看看"); b.Clicked() {
					s.FinishOnboarding()
					s.OpenPage(model.PageSettings)
				}
				if b := d.Button(c, "跳过"); b.Clicked() {
					s.FinishOnboarding()
					s.OpenPage(model.PageLibrary)
				}
			})
			d.Text(c, tokens.Overline, "稍后也可以在「来源」中添加或管理音乐文件夹。").
				TextColor(d.P.TextTertiary)
		})
	})
}

func onboardingCard(c *ui.Context, d components.Design, icon *ui.SVG, title, text, tag string, enabled bool, action func()) {
	card := ui.Column(c).Width(232).Gap(tokens.Space8).Padding(tokens.Space16).
		Radius(tokens.RadiusLG).Background(d.P.SurfaceRaised).Border(1, d.P.Border)
	card.Children(func() {
		ui.Row(c).AlignItems(ui.Center).Gap(tokens.Space8).Children(func() {
			ui.Box(c).Size(32, 32).Radius(tokens.RadiusSM).Background(d.P.SurfaceSunken).Center().Children(func() {
				ui.Icon(c, icon).FontSize(tokens.IconCompact).TextColor(d.P.TextSecondary)
			})
			d.Text(c, tokens.Body, title).TextColor(d.P.TextPrimary)
			ui.Spacer(c)
			if tag != "" {
				d.Tag(c, tag)
			}
		})
		d.Text(c, tokens.Small, text).TextColor(d.P.TextSecondary).Wrap()
		if enabled && action != nil {
			label := "添加来源…"
			if title == "本地文件夹" {
				label = "选择目录…"
			}
			if b := d.Button(c, label); b.Clicked() {
				action()
			}
		}
	})
}
