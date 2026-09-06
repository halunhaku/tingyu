import Foundation
import AppIntents

public struct PlayPauseIntent: AppIntent {
    public static let title: LocalizedStringResource = "播放 / 暂停"
    public static let description: LocalizedStringResource = "在听屿中切换播放或暂停"
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayerService.shared.togglePlayPause()
        let isPlaying = AudioPlayerService.shared.isPlaying
        let title = AudioPlayerService.shared.currentTrack?.title ?? "听屿"
        let msg = isPlaying ? "正在播放 \(title)" : "已暂停播放"
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

public struct NextTrackIntent: AppIntent {
    public static let title: LocalizedStringResource = "下一首"
    public static let description: LocalizedStringResource = "在听屿中切换到下一首歌曲"
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayerService.shared.next()
        let title = AudioPlayerService.shared.currentTrack?.title ?? ""
        let dialog = title.isEmpty ? "已切换至下一首" : "正在播放下一首：\(title)"
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

public struct PreviousTrackIntent: AppIntent {
    public static let title: LocalizedStringResource = "上一首"
    public static let description: LocalizedStringResource = "在听屿中切换到上一首歌曲"
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayerService.shared.previous()
        let title = AudioPlayerService.shared.currentTrack?.title ?? ""
        let dialog = title.isEmpty ? "已返回上一首" : "正在播放上一首：\(title)"
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

public struct TingyuShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "在 \(.applicationName) 中播放",
                "在 \(.applicationName) 中暂停",
                "\(.applicationName) 播放或暂停"
            ],
            shortTitle: "播放 / 暂停",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "\(.applicationName) 下一首",
                "\(.applicationName) 切歌",
                "在 \(.applicationName) 中播放下一首"
            ],
            shortTitle: "下一首",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: [
                "\(.applicationName) 上一首",
                "在 \(.applicationName) 中播放上一首"
            ],
            shortTitle: "上一首",
            systemImageName: "backward.fill"
        )
    }
}
