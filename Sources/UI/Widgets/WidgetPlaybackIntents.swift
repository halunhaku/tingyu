import AppIntents
import Foundation

struct WidgetPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "播放 / 暂停"
    static let description = IntentDescription("在听屿中切换播放或暂停")
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            SharedPlaybackState.playbackCommandNotification,
            object: PlaybackWidgetCommand.playPause.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

struct WidgetNextIntent: AppIntent {
    static let title: LocalizedStringResource = "下一首"
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            SharedPlaybackState.playbackCommandNotification,
            object: PlaybackWidgetCommand.next.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}

struct WidgetPreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "上一首"
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            SharedPlaybackState.playbackCommandNotification,
            object: PlaybackWidgetCommand.previous.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}
