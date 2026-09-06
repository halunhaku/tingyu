import Foundation
import SwiftData

enum PlaylistActions {
    static func tracks(in playlist: Playlist, from allTracks: [Track]) -> [Track] {
        let byId = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        return playlist.trackIds.compactMap { byId[$0] }
    }

    static func add(track: Track, to playlist: Playlist, context: ModelContext) {
        guard !playlist.trackIds.contains(track.id) else { return }
        playlist.trackIds.append(track.id)
        try? context.save()
    }

    static func remove(track: Track, from playlist: Playlist, context: ModelContext) {
        playlist.trackIds.removeAll { $0 == track.id }
        try? context.save()
    }

    @discardableResult
    static func create(name: String, context: ModelContext, firstTrack: Track? = nil) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "未命名播放列表" : trimmed)
        if let firstTrack {
            playlist.trackIds = [firstTrack.id]
        }
        context.insert(playlist)
        try? context.save()
        return playlist
    }

    static func rename(_ playlist: Playlist, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.name = trimmed.isEmpty ? "未命名播放列表" : trimmed
        try? context.save()
    }

    static func delete(_ playlist: Playlist, context: ModelContext) {
        context.delete(playlist)
        try? context.save()
    }
}
