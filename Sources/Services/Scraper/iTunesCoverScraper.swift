import Foundation

public struct iTunesSearchResult: Codable, Sendable {
    public let resultCount: Int
    public let results: [iTunesAlbum]
}

public struct iTunesAlbum: Codable, Sendable {
    public let artistName: String?
    public let collectionName: String?
    public let artworkUrl100: String?
}

public final class iTunesCoverScraper: Sendable {
    public static let shared = iTunesCoverScraper()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    public func fetchCoverArtData(album: String, artist: String) async -> Data? {
        guard !album.isEmpty && album != "未知专辑" else { return nil }

        var term = album
        if !artist.isEmpty && artist != "未知艺术家" {
            term += " " + artist
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let searchResult = try JSONDecoder().decode(iTunesSearchResult.self, from: data)
            guard let artworkUrl100 = searchResult.results.first?.artworkUrl100 else {
                return nil
            }

            // Upgrade to high-res 600x600 artwork
            let highResUrlString = artworkUrl100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let highResUrl = URL(string: highResUrlString) else { return nil }

            let (imageData, imageResponse) = try await session.data(from: highResUrl)
            if let imgHttpResponse = imageResponse as? HTTPURLResponse, imgHttpResponse.statusCode == 200 {
                return imageData
            }
        } catch {
            // Silently ignore
        }
        return nil
    }
}
