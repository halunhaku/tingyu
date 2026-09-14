import Foundation

public struct NetEaseSearchResult: Sendable {
    public let songId: Int
    public let title: String
    public let artist: String
    public let album: String
    public let picUrl: String?
}

public final class NetEaseScraper: Sendable {
    public static let shared = NetEaseScraper()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    public func search(title: String, artist: String = "") async -> NetEaseSearchResult? {
        var query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty && artist != "未知艺术家" {
            query += " " + artist
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.163.com/api/search/get/web?csrf_token=&s=\(encodedQuery)&type=1&offset=0&total=true&limit=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              let first = songs.first else {
            return nil
        }

        guard let songId = first["id"] as? Int,
              let songTitle = first["name"] as? String else {
            return nil
        }

        var artistName = ""
        if let artists = first["artists"] as? [[String: Any]], let firstArtist = artists.first {
            artistName = firstArtist["name"] as? String ?? ""
        }

        var albumName = ""
        var picUrl: String? = nil
        if let album = first["album"] as? [String: Any] {
            albumName = album["name"] as? String ?? ""
            picUrl = album["picUrl"] as? String
        }

        return NetEaseSearchResult(
            songId: songId,
            title: songTitle,
            artist: artistName,
            album: albumName,
            picUrl: picUrl
        )
    }

    public func fetchLyrics(songId: Int) async -> String? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?os=pc&id=\(songId)&lv=-1&kv=-1&tv=-1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lrcDict = json["lrc"] as? [String: Any],
              let lyricText = lrcDict["lyric"] as? String,
              !lyricText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return ChineseConverter.toSimplified(lyricText)
    }

    public func fetchCoverArt(picUrl: String) async -> Data? {
        var highResUrlString = picUrl
        if highResUrlString.contains("?") {
            highResUrlString += "&param=800y800"
        } else {
            highResUrlString += "?param=800y800"
        }

        guard let url = URL(string: highResUrlString) else { return nil }

        guard let (data, response) = try? await session.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              !data.isEmpty else {
            return nil
        }

        return data
    }
}
