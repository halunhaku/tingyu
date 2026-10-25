# P1视觉稿源文件说明

- `a/`、`b/`、`c/` 各4张最终方向稿，都是未批准的扁平PNG。
- `index.html`：可编辑的本地评审目录，切换四种场景，点击原图查看。它不实现播放器业务，不是Flutter替代应用。
- `generation-prompts.json`：内置ImageGen的实际提示、定向返工提示及原始生成文件名。每张独立生成；没有通过脚本绘制或拉伸位图。
- `fixture.json`：虚构元数据；后续确定性渲染的依据。生成图片仍有非当前曲元数据偏差，详见审查记录，不能用于数据库导入。
- `palette-candidates.json`：双主题色彩候选及计算对比度，没有写入Flutter主题。
- `asset-manifest.json`：最终12图的实际尺寸/哈希，用于确认用户批准的是哪个版本。

参考角色：P0的 `../evidence/desktop-light/library-songs.png` 与 `stage.png`、`../evidence/desktop-dark/stage.png`、`../evidence/mobile-light/library-songs.png` 与 `stage.png` 用于能力与页面类型参考；同方向已生成图用于色彩/封面意象参考。没有把竞品截图、商标或正版专辑封面作为目标资产复制。

本轮没有Figma或Sketch逐层设计源。JSON提示可以编辑并重新生成，但不保证相同像素；PNG不能用于Golden基准。选择后需先建立统一资产、可编辑精确稿和令牌规格，确认后再实现Flutter。

本地查看（仓库根目录）：

```powershell
python -m http.server 8765 --bind 127.0.0.1 --directory docs/ui-redesign
# 浏览器打开 http://127.0.0.1:8765/directions/index.html
python docs/ui-redesign/p1-evidence/verify_artifacts.py
```

若系统python别名不可用，请使用已安装的Python可执行文件；本轮使用Codex工作区自带Python。服务只绑定本机，不发布到外部。
