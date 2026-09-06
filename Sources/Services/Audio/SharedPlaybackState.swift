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

public final class SharedPlaybackState: Sendable {
    public static let shared = SharedPlaybackState()
    private let key = "tingyu_widget_track_info"

    public func save(track: Track?, isPlaying: Bool, currentTime: Double, duration: Double) {
        let info = WidgetTrackInfo(
            id: track?.id ?? "",
            title: track?.title ?? "听屿",
            artist: track?.artist ?? "暂未播放音乐",
            album: track?.album ?? "",
            isPlaying: isPlaying,
            duration: duration,
            currentTime: currentTime,
            coverData: track?.coverArtData
        )

        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: key)
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    public func load() -> WidgetTrackInfo {
        guard let data = UserDefaults.standard.data(forKey: key),
              let info = try? JSONDecoder().decode(WidgetTrackInfo.self, from: data) else {
            return WidgetTrackInfo()
        }
        return info
    }
}
