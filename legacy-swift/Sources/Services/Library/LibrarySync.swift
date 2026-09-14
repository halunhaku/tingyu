import Foundation
import SwiftData

enum LibrarySync {
    /// Merge a fresh scan into SwiftData: keep ids, covers, lyrics, favorites, and playlists.
    static func merge(
        scanned: [Track],
        sourceId: String,
        context: ModelContext
    ) {
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.sourceId == sourceId })
        let existing = (try? context.fetch(descriptor)) ?? []
        var byPath: [String: Track] = [:]
        for track in existing {
            byPath[track.filePathOrUrl] = track
        }

        var seen = Set<String>()
        for incoming in scanned {
            let path = incoming.filePathOrUrl
            guard !path.isEmpty else { continue }
            seen.insert(path)

            if let old = byPath[path] {
                applyFileFacts(from: incoming, onto: old)
            } else {
                context.insert(incoming)
            }
        }

        var removedIds = Set<String>()
        for old in existing where !seen.contains(old.filePathOrUrl) {
            removedIds.insert(old.id)
            context.delete(old)
        }

        if !removedIds.isEmpty {
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            for playlist in playlists {
                playlist.trackIds.removeAll { removedIds.contains($0) }
            }
        }
    }

    private static func applyFileFacts(from incoming: Track, onto old: Track) {
        old.fileSize = incoming.fileSize
        old.etag = incoming.etag
        old.lastModified = incoming.lastModified
        old.fileFormat = incoming.fileFormat
        if incoming.duration > 0 {
            old.duration = incoming.duration
        }
        if old.coverArtData == nil {
            old.coverArtData = incoming.coverArtData
        }
        if old.coverArtUrl == nil {
            old.coverArtUrl = incoming.coverArtUrl
        }
        if isPlaceholder(old.title), !isPlaceholder(incoming.title) {
            old.title = incoming.title
        }
        if isPlaceholderArtist(old.artist), !isPlaceholderArtist(incoming.artist) {
            old.artist = incoming.artist
        }
        if isPlaceholderAlbum(old.album), !isPlaceholderAlbum(incoming.album) {
            old.album = incoming.album
        }
    }

    private static func isPlaceholder(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isPlaceholderArtist(_ artist: String) -> Bool {
        artist.isEmpty || artist == "未知艺术家"
    }

    private static func isPlaceholderAlbum(_ album: String) -> Bool {
        album.isEmpty || album == "未知专辑" || album == "夸克曲库" || album == "WebDAV 曲库"
    }
}
