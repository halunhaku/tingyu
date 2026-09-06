import Foundation

struct AlbumSummary: Identifiable, Hashable {
    var id: String { "\(artist)|\(album)" }
    let album: String
    let artist: String
    let coverArtData: Data?
    let year: Int?
    let tracks: [Track]
}

enum LibraryGrouping {
    static func artistNames(from tracks: [Track]) -> [String] {
        let names = Set(tracks.map(\.artist))
        return names.sorted { a, b in
            if a == "未知艺术家" { return false }
            if b == "未知艺术家" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func tracks(forArtist artist: String, in tracks: [Track]) -> [Track] {
        sortForAlbum(tracks.filter { $0.artist == artist })
    }

    static func albums(from tracks: [Track]) -> [AlbumSummary] {
        var grouped: [String: [Track]] = [:]
        for track in tracks {
            grouped[albumKey(album: track.album, artist: track.artist), default: []].append(track)
        }
        return grouped.values.map { albumTracks in
            let sorted = sortForAlbum(albumTracks)
            let first = sorted.first
            return AlbumSummary(
                album: first?.album ?? "未知专辑",
                artist: first?.artist ?? "未知艺术家",
                coverArtData: sorted.first(where: { $0.coverArtData != nil })?.coverArtData,
                year: sorted.compactMap(\.year).max(),
                tracks: sorted
            )
        }
        .sorted { a, b in
            if a.album == "未知专辑" { return false }
            if b.album == "未知专辑" { return true }
            return a.album.localizedStandardCompare(b.album) == .orderedAscending
        }
    }

    static func sortForAlbum(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            let discL = lhs.discNumber ?? 1
            let discR = rhs.discNumber ?? 1
            if discL != discR { return discL < discR }
            let numL = lhs.trackNumber ?? Int.max
            let numR = rhs.trackNumber ?? Int.max
            if numL != numR { return numL < numR }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func albumKey(album: String, artist: String) -> String {
        "\(artist)|\(album)"
    }
}
