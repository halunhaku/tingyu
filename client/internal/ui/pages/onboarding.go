package pages

import (
	"github.com/egoist/mygo/ui"

	"github.com/halunhaku/tingyu/client/internal/ui/components"
	"github.com/halunhaku/tingyu/client/internal/ui/model"
	"github.com/halunhaku/tingyu/client/internal/ui/tokens"
)

// Onboarding is the first-run page, shown once per process when the library
// has no sources and no tracks (the Flutter trigger). It offers the three
// source kinds; only the local folder is wired in this milestone, and the
// other two say so.
func Onboarding(c *ui.Context, d components.Design, s *model.State) {
	ui.Column(c).Fill().Gradient(d.P.Canvas, d.P.SurfaceSunken, 160).
		Justify(ui.Center).AlignItems(ui.Center).Padding(tokens.Space32).Children(func() {
		ui.Column(c).Width(760).Gap(tokens.Space20).AlignItems(ui.Center).Children(func() {
			d.Text(c, tokens.DisplayM, "听屿").TextColor(d.P.TextPrimary)
			d.Text(c, tokens.LabelS, "TINGYU · 声档").TextColor(d.P.Accent).LetterSpacing(2)
			ui.Text(c, "一个只属于本地与你自己来源的音乐库。先接入一个目录，扫描完成后曲库、专辑、艺术家与播放都会就绪。").
				FontSize(15).LineHeight(1.7).TextColor(d.P.TextSecondary).TextAlign(ui.Center).MaxWidth(560).Wrap()
			ui.Row(c).Gap(tokens.Space12).AlignItems(ui.Stretch).Children(func() {
				onboardingCard(c, d, components.IconFolder, "本地文件夹", "选择 macOS 上的音乐目录，扫描 9 种格式并入库。", "可用", true, func() {
					s.FinishOnboarding()
					if a := s.Actions(); a != nil {
						a.ChooseDirectory()
					}
				})
				onboardingCard(c, d, components.IconExternal, "WebDAV", "坚果云等 WebDAV 服务器，支持流式播放与鉴权头。", "M3", false, nil)
				onboardingCard(c, d, components.IconSearch, "夸克网盘", "扫码或网页登录后列举目录与直链播放。", "M3", false, nil)
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
			d.Text(c, tokens.LabelS, "提示：开发/验收构建在未设置 TINGYU_DATA_DIR 时只读，扫描与历史不会写生产库。").
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
			d.Text(c, tokens.BodyM, title).TextColor(d.P.TextPrimary)
			ui.Spacer(c)
			if tag != "" {
				d.Tag(c, tag)
			}
		})
		d.Text(c, tokens.BodyS, text).TextColor(d.P.TextSecondary).Wrap()
		if enabled && action != nil {
			if b := d.Button(c, "选择目录…"); b.Clicked() {
				action()
			}
		}
	})
}
