import Foundation

public struct QQMusicSearchResult: Identifiable, Hashable, Sendable {
    public var id: String { songMid }
    public let songMid: String
    public let songName: String
    public let singerName: String
    public let albumName: String
    public let albumMid: String
    public let duration: Double

    public init(songMid: String, songName: String, singerName: String, albumName: String, albumMid: String, duration: Double = 0.0) {
        self.songMid = songMid
        self.songName = songName
        self.singerName = singerName
        self.albumName = albumName
        self.albumMid = albumMid
        self.duration = duration
    }

    public var coverUrl: String {
        "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
    }

    public var formattedDuration: String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public final class QQMusicScraper: Sendable {
    public static let shared = QQMusicScraper()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: config)
    }

    public func search(title: String, artist: String = "") async -> QQMusicSearchResult? {
        let list = await searchCandidates(title: title, artist: artist, limit: 1)
        return list.first
    }

    public func searchCandidates(title: String, artist: String = "", limit: Int = 10) async -> [QQMusicSearchResult] {
        var query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty && artist != "未知艺术家" {
            query += " " + artist
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=\(limit)&w=\(encoded)&format=json") else {
            return []
        }

        guard let (data, response) = try? await session.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let songDict = dataDict["song"] as? [String: Any],
              let list = songDict["list"] as? [[String: Any]] else {
            return []
        }

        var results: [QQMusicSearchResult] = []
        for item in list {
            guard let songMid = item["songmid"] as? String,
                  let songName = item["songname"] as? String,
                  let albumMid = item["albummid"] as? String,
                  let albumName = item["albumname"] as? String else {
                continue
            }

            let interval = (item["interval"] as? Double) ?? Double((item["interval"] as? Int) ?? 0)

            var singerName = ""
            if let singers = item["singer"] as? [[String: Any]], let firstSinger = singers.first {
                singerName = firstSinger["name"] as? String ?? ""
            }

            results.append(QQMusicSearchResult(
                songMid: songMid,
                songName: songName,
                singerName: singerName,
                albumName: albumName,
                albumMid: albumMid,
                duration: interval
            ))
        }

        return results
    }

    public func fetchCoverArt(albumMid: String) async -> Data? {
        let urlString = "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
        guard let url = URL(string: urlString) else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              !data.isEmpty else {
            return nil
        }

        return data
    }
}
