import Foundation

public struct LRCLIBResponse: Codable, Sendable {
    public let id: Int?
    public let trackName: String?
    public let artistName: String?
    public let albumName: String?
    public let duration: Double?
    public let instrumental: Bool?
    public let plainLyrics: String?
    public let syncedLyrics: String?
}

public final class LRCLIBScraper: Sendable {
    public static let shared = LRCLIBScraper()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    public func fetchLyrics(
        trackTitle: String,
        artist: String,
        album: String,
        duration: Double
    ) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var queryItems = [
            URLQueryItem(name: "track_name", value: trackTitle),
            URLQueryItem(name: "artist_name", value: artist.isEmpty ? nil : artist),
            URLQueryItem(name: "album_name", value: album.isEmpty ? nil : album)
        ]
        if duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components?.queryItems = queryItems.filter { $0.value != nil }

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Tingyu/1.0 (https://github.com/halunhaku/tingyu)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(LRCLIBResponse.self, from: data)

            if let synced = result.syncedLyrics, !synced.isEmpty {
                return ChineseConverter.toSimplified(synced)
            } else if let plain = result.plainLyrics, !plain.isEmpty {
                return ChineseConverter.toSimplified(plain)
            }
        } catch {
            // Silently ignore network / parsing failure
        }
        return nil
    }
}
