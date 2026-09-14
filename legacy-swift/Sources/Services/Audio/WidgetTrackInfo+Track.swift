import Foundation

extension WidgetTrackInfo {
    init(track: Track?, isPlaying: Bool, currentTime: Double, duration: Double) {
        self.init(
            id: track?.id ?? "",
            title: track?.title ?? "听屿",
            artist: track?.artist ?? "暂未播放音乐",
            album: track?.album ?? "",
            isPlaying: isPlaying,
            duration: duration,
            currentTime: currentTime,
            coverData: track?.coverArtData
        )
    }
}

extension SharedPlaybackState {
    func save(track: Track?, isPlaying: Bool, currentTime: Double, duration: Double) {
        save(WidgetTrackInfo(track: track, isPlaying: isPlaying, currentTime: currentTime, duration: duration))
    }
}
