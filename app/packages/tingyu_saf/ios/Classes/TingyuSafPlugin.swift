import Flutter
import UIKit
import UniformTypeIdentifiers

/// iOS 的「本地音乐目录」桥，与 Android 侧的 SAF 一一对应。
///
/// iOS 沙盒拿不到用户任意目录的长期访问权，必须由用户在系统文档选择器里显式授权：
/// - `pickFolderBookmark` 拉起 `UIDocumentPickerViewController` 选一个目录，把它存成
///   **安全作用域书签**（base64，由 Dart 侧落到 `music_sources.local_bookmark`）；
/// - `resolveBookmark` 解析书签、开启安全作用域访问，返回目录的绝对路径；
/// - `releaseBookmark` 关闭安全作用域（删除来源时调用）。
///
/// 与 Android 侧的差别：iOS 授权到的目录就是一个真实路径，`dart:io` 可以直接遍历与播放，
/// 所以这里没有枚举桥，唯一的责任是"拿到授权并把授权保持有效"。
///
/// 安全作用域在进程内一直保持开启（`scopedURLs`）：扫描与点播之间可能隔很久，
/// 一旦 stop，AVPlayer 读取该目录下的文件就会失败。
public class TingyuSafPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private static let channelName = "tingyu/saf"

    /// 书签 → 已开启安全作用域的 URL。
    private var scopedURLs: [String: URL] = [:]

    /// 目录选择器是异步的：结果先存这里，等 delegate 回调再交给 Dart。
    private var pendingPick: FlutterResult?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = TingyuSafPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "pickFolderBookmark":
            pickFolderBookmark(result: result)
        case "resolveBookmark":
            resolveBookmark(bookmark: Self.argument(call, "bookmark"), result: result)
        case "releaseBookmark":
            releaseBookmark(bookmark: Self.argument(call, "bookmark"))
            result(nil)
        default:
            // 其余方法（SAF 枚举、夸克跳转、拉回前台）只存在于 Android 侧，Dart 侧按平台分流。
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 目录选择

    private func pickFolderBookmark(result: @escaping FlutterResult) {
        guard pendingPick == nil else {
            result(FlutterError(code: "picker_busy", message: "上一次目录选择还没有结束", details: nil))
            return
        }
        guard let presenter = Self.topViewController() else {
            result(FlutterError(code: "no_presenter", message: "找不到可以展示目录选择器的界面", details: nil))
            return
        }
        pendingPick = result
        // asCopy: false —— 要的是"原地访问权 + 可持久化书签"，不是把整个目录拷进沙盒。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pendingPick else {
            return
        }
        pendingPick = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        // 书签必须在访问权限还开着的时候创建；建完就还回去，
        // 长期的访问权交给 resolveBookmark 按需开启。
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            result(["bookmark": data.base64EncodedString(), "path": url.path])
        } catch {
            result(FlutterError(code: "bookmark_failed", message: error.localizedDescription, details: nil))
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let result = pendingPick else {
            return
        }
        pendingPick = nil
        result(nil)
    }

    // MARK: - 书签

    private func resolveBookmark(bookmark: String?, result: @escaping FlutterResult) {
        guard let bookmark = bookmark, !bookmark.isEmpty else {
            result(nil)
            return
        }
        if let opened = scopedURLs[bookmark] {
            result(opened.path)
            return
        }
        guard let data = Data(base64Encoded: bookmark) else {
            result(nil)
            return
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            // 沙盒内自己的目录 startAccessing 会返回 false 但依然可读，所以不能只看返回值。
            let scoped = url.startAccessingSecurityScopedResource()
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue,
                  scoped || FileManager.default.isReadableFile(atPath: url.path) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                result(nil)
                return
            }
            if scoped { scopedURLs[bookmark] = url }
            result(url.path)
        } catch {
            result(nil)
        }
    }

    private func releaseBookmark(bookmark: String?) {
        guard let bookmark = bookmark, let url = scopedURLs.removeValue(forKey: bookmark) else {
            return
        }
        url.stopAccessingSecurityScopedResource()
    }

    private static func argument(_ call: FlutterMethodCall, _ key: String) -> String? {
        (call.arguments as? [String: Any])?[key] as? String
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
