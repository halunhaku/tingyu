import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 旧版 MacOSContentView 的最小尺寸是 900×600；这里给一个更适合曲库浏览的默认尺寸，
    // 避免 Flutter 模板默认的 800×600 把侧栏 + 列表挤到溢出。
    let defaultSize = NSSize(width: 1180, height: 760)
    self.minSize = NSSize(width: 900, height: 600)
    if let screen = self.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let origin = NSPoint(
        x: visible.midX - defaultSize.width / 2,
        y: visible.midY - defaultSize.height / 2
      )
      self.setFrame(NSRect(origin: origin, size: defaultSize), display: true)
    } else {
      self.setFrame(NSRect(origin: self.frame.origin, size: defaultSize), display: true)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
