import Foundation

public actor ArtistAvatarStore {
    public static let shared = ArtistAvatarStore()

    private var memoryCache: [String: Data] = [:]

    private init() {}

    public func avatar(for artist: String) async -> Data? {
        let cleanName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty && cleanName != "未知艺术家" else { return nil }

        // 1. Check memory cache
        if let cached = memoryCache[cleanName] {
            return cached
        }

        // 2. Check local disk cache
        if let diskData = readDiskCache(for: cleanName) {
            memoryCache[cleanName] = diskData
            return diskData
        }

        // 3. Fetch from remote NetEase artist API
        guard let fetchedData = await fetchRemoteAvatar(artist: cleanName) else {
            return nil
        }

        // 4. Save to memory & disk
        memoryCache[cleanName] = fetchedData
        writeDiskCache(data: fetchedData, for: cleanName)
        return fetchedData
    }

    private func fetchRemoteAvatar(artist: String) async -> Data? {
        guard let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://music.163.com/api/search/get/web?s=\(encoded)&type=100&offset=0&total=true&limit=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let artists = result["artists"] as? [[String: Any]],
              let first = artists.first,
              let imgUrlString = first["img1v1Url"] as? String ?? first["picUrl"] as? String,
              !imgUrlString.isEmpty else {
            return nil
        }

        let highResUrl = imgUrlString.contains("?") ? "\(imgUrlString)&param=500y500" : "\(imgUrlString)?param=500y500"
        guard let imgUrl = URL(string: highResUrl) else { return nil }

        var imgRequest = URLRequest(url: imgUrl)
        imgRequest.timeoutInterval = 10
        guard let (imgData, _) = try? await URLSession.shared.data(for: imgRequest) else {
            return nil
        }

        return imgData
    }

    private func diskCacheURL(for artist: String) -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let avatarDir = baseDir.appendingPathComponent("tingyu").appendingPathComponent("avatars")
        try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        let filename = sanitizeFilename(artist) + ".jpg"
        return avatarDir.appendingPathComponent(filename)
    }

    private func readDiskCache(for artist: String) -> Data? {
        let url = diskCacheURL(for: artist)
        return try? Data(contentsOf: url)
    }

    private func writeDiskCache(data: Data, for artist: String) {
        let url = diskCacheURL(for: artist)
        try? data.write(to: url, options: .atomic)
    }

    private func sanitizeFilename(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? string
    }
}
