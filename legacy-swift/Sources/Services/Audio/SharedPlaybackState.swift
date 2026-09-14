import Foundation
import WidgetKit

public struct WidgetTrackInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let isPlaying: Bool
    public let duration: Double
    public let currentTime: Double
    public let coverData: Data?

    public init(
        id: String = "",
        title: String = "听屿",
        artist: String = "暂未播放",
        album: String = "",
        isPlaying: Bool = false,
        duration: Double = 0.0,
        currentTime: Double = 0.0,
        coverData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.currentTime = currentTime
        self.coverData = coverData
    }
}

public enum PlaybackWidgetCommand: String, Sendable {
    case playPause
    case next
    case previous
}

public final class SharedPlaybackState: @unchecked Sendable {
    public static let shared = SharedPlaybackState()
    public static let appGroupId = "group.com.halunhaku.tingyu"
    public static let playbackCommandNotification = Notification.Name("com.halunhaku.tingyu.playbackCommand")

    private let key = "tingyu_widget_track_info"
    private let defaults: UserDefaults

    public init() {
        defaults = UserDefaults(suiteName: Self.appGroupId) ?? .standard
    }

    public func save(_ info: WidgetTrackInfo) {
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: key)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    public func load() -> WidgetTrackInfo {
        guard let data = defaults.data(forKey: key),
              let info = try? JSONDecoder().decode(WidgetTrackInfo.self, from: data) else {
            return WidgetTrackInfo()
        }
        return info
    }
}
