import Foundation

public struct QuarkItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let formatType: String

    public init(id: String, name: String, isFolder: Bool, size: Int64, formatType: String) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.formatType = formatType
    }
}

public struct QrCodeInfo: Sendable {
    public let token: String
    public let qrUrl: String
}

public enum QrStatus: Sendable {
    case waiting
    case scanned
    case confirmed(cookie: String)
    case expired
    case error(String)
}

public enum QuarkError: LocalizedError, Sendable {
    case unauthenticated
    case rateLimited
    case networkError(String)
    case parseError(String)
    case downloadUrlExpired

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "夸克网盘登录凭据已失效，请重新登录"
        case .rateLimited:
            return "夸克网盘请求过于频繁，请稍候再试"
        case .networkError(let msg):
            return "夸克网络连接异常: \(msg)"
        case .parseError(let msg):
            return "夸克数据解析失败: \(msg)"
        case .downloadUrlExpired:
            return "音频播放直链已失效，正在自动刷新"
        }
    }
}

public final class QuarkDriveClient: @unchecked Sendable {
    public static let shared = QuarkDriveClient()

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.23.0 Chrome/112.0.5615.165 Electron/23.3.13 Safari/537.36 Channel/pckk_other_ch"

    private let session: URLSession
    private let downloadCache = NSCache<NSString, CachedDownloadUrl>()
    private let cookieLock = NSLock()
    private var refreshedPuus: String?

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    public static func playbackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": userAgent,
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "Accept": "*/*"
        ]
    }

    private func applyAPIHeaders(_ request: inout URLRequest, cookie: String, jsonBody: Bool) {
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if jsonBody {
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
    }

    public func verifyCookie(_ cookie: String) async -> (isValid: Bool, nickname: String) {
        guard let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=0&_page=1&_size=1") else {
            return (false, "")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAPIHeaders(&request, cookie: cookie, jsonBody: false)

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, status == 200 else {
            return (false, "")
        }

        return (true, "夸克用户")
    }

    // MARK: - Directory & File Listing

    public func listFolder(fid: String = "0", cookie: String) async throws -> [QuarkItem] {
        let urlString = "https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&uc_param_str=&pdir_fid=\(fid)&_page=1&_size=100&_fetch_total=1&_sort=file_type:asc,file_name:asc"
        guard let url = URL(string: urlString) else {
            throw QuarkError.networkError("无效接口地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAPIHeaders(&request, cookie: cookie, jsonBody: false)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw QuarkError.networkError("读取夸克文件列表失败 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let list = dataDict["list"] as? [[String: Any]] else {
            return []
        }

        var items: [QuarkItem] = []
        for dict in list {
            guard let id = dict["fid"] as? String,
                  let name = dict["file_name"] as? String else { continue }
            let fileType = dict["file_type"] as? Int ?? 0 // 0 = folder, 1 = file
            let isFolder = (fileType == 0)
            let size = (dict["size"] as? Int64) ?? Int64((dict["size"] as? Int) ?? 0)
            let formatType = dict["format_type"] as? String ?? (isFolder ? "dir" : "file")

            items.append(QuarkItem(id: id, name: name, isFolder: isFolder, size: size, formatType: formatType))
        }

        return items
    }

    // MARK: - Scan Audio Files Recursively

    public func scan(
        folderFid: String,
        sourceId: String,
        cookie: String,
        maxDepth: Int = 5,
        maxFiles: Int = 5000,
        progressHandler: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> [Track] {
        var discoveredTracks: [Track] = []
        var queue: [(String, Int)] = [(folderFid, 0)]
        var visitedFids = Set<String>()

        while !queue.isEmpty && discoveredTracks.count < maxFiles {
            let (currentFid, depth) = queue.removeFirst()
            if depth > maxDepth { continue }
            if visitedFids.contains(currentFid) { continue }
            visitedFids.insert(currentFid)

            let items = try await listFolder(fid: currentFid, cookie: cookie)

            for item in items {
                if item.isFolder {
                    if depth + 1 <= maxDepth && !visitedFids.contains(item.id) {
                        queue.append((item.id, depth + 1))
                    }
                } else {
                    let ext = (item.name as NSString).pathExtension.lowercased()
                    if LocalLibraryScanner.supportedExtensions.contains(ext) {
                        let rawName = (item.name as NSString).deletingPathExtension
                        let parsed = SmartTitleParser.parse(filename: rawName)

                        progressHandler?(discoveredTracks.count + 1, parsed.title)

                        let track = Track(
                            sourceId: sourceId,
                            title: parsed.title,
                            artist: parsed.artist,
                            album: parsed.album == "未知专辑" ? "夸克曲库" : parsed.album,
                            duration: 0.0,
                            fileFormat: ext,
                            filePathOrUrl: "quark://\(item.id)",
                            fileSize: item.size
                        )
                        discoveredTracks.append(track)

                        if discoveredTracks.count >= maxFiles {
                            break
                        }
                    }
                }
            }

            // Gentle sleep between folders
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        return discoveredTracks
    }

    // MARK: - Dynamic Stream URL Resolution

    public func getDownloadUrl(fid: String, cookie: String) async throws -> URL {
        let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else {
            throw QuarkError.unauthenticated
        }

        let cacheKey = NSString(string: fid)

        let endpoints = [
            "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc",
            "https://drive.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc"
        ]

        var lastError: Error = QuarkError.parseError("获取下载直链失败")
        for endpoint in endpoints {
            do {
                let downloadUrl = try await requestDownloadUrl(endpoint: endpoint, fid: fid, cookie: trimmedCookie)
                let cached = CachedDownloadUrl(url: downloadUrl, expiryDate: Date().addingTimeInterval(5400))
                downloadCache.setObject(cached, forKey: cacheKey)
                return downloadUrl
            } catch {
                lastError = error
                if case QuarkError.unauthenticated = error {
                    throw error
                }
            }
        }
        throw lastError
    }

    public func downloadFile(fid: String, cookie: String, fileExtension: String) async throws -> URL {
        downloadCache.removeObject(forKey: NSString(string: fid))
        let downloadUrl = try await getDownloadUrl(fid: fid, cookie: cookie)
        let cdnCookie = cookieWithRefreshedPuus(original: cookie)

        var request = URLRequest(url: downloadUrl)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(cdnCookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let (tempURL, response) = try await session.download(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        if !(200...299).contains(statusCode) {
            throw QuarkError.networkError("下载音频失败 HTTP \(statusCode)")
        }
        if let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            throw QuarkError.unauthenticated
        }
        let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        if downloadedSize < 1024 {
            throw QuarkError.networkError("下载音频不完整 (\(downloadedSize) 字节)")
        }

        let ext = fileExtension.isEmpty ? "mp3" : fileExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tingyu-\(fid).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func requestDownloadUrl(endpoint: String, fid: String, cookie: String) async throws -> URL {
        guard let url = URL(string: endpoint) else {
            throw QuarkError.networkError("无效下载地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAPIHeaders(&request, cookie: cookie, jsonBody: true)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fid]])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            capturePuus(from: http)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let apiStatus = json["status"] as? Int
        let apiCode = json["code"] as? Int
        let apiMessage = (json["message"] as? String) ?? ""

        if statusCode == 401 || apiStatus == 401 || apiCode == 31001 || apiMessage.contains("login") {
            throw QuarkError.unauthenticated
        }
        if statusCode == 429 || apiStatus == 429 {
            throw QuarkError.rateLimited
        }
        if !(200...299).contains(statusCode) {
            let detail = apiMessage.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode) \(apiMessage)"
            throw QuarkError.networkError("直链失败 \(detail)")
        }
        if let apiStatus, apiStatus != 200 {
            throw QuarkError.networkError(apiMessage.isEmpty ? "接口 status \(apiStatus)" : apiMessage)
        }

        if let downloadUrl = extractDownloadURL(from: json) {
            return downloadUrl
        }

        let preview = String(data: data.prefix(180), encoding: .utf8) ?? ""
        throw QuarkError.parseError("响应中没有 download_url \(preview)")
    }

    private func extractDownloadURL(from json: [String: Any]) -> URL? {
        func url(from dict: [String: Any]) -> URL? {
            let keys = ["download_url", "download_url_https", "downloadUrl", "url"]
            for key in keys {
                if let string = dict[key] as? String, let url = URL(string: string), url.scheme != nil {
                    return url
                }
            }
            return nil
        }

        if let list = json["data"] as? [[String: Any]] {
            for item in list {
                if let found = url(from: item) { return found }
            }
        }
        if let dict = json["data"] as? [String: Any] {
            if let found = url(from: dict) { return found }
            if let list = dict["list"] as? [[String: Any]] {
                for item in list {
                    if let found = url(from: item) { return found }
                }
            }
        }
        return nil
    }

    private func capturePuus(from http: HTTPURLResponse) {
        guard let url = http.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if let puus = cookies.first(where: { $0.name == "__puus" })?.value, !puus.isEmpty {
            cookieLock.lock()
            refreshedPuus = puus
            cookieLock.unlock()
            return
        }

        if let raw = http.value(forHTTPHeaderField: "Set-Cookie") {
            for part in raw.split(separator: ",") {
                let item = part.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("__puus=") {
                    let value = item.split(separator: ";")[0].dropFirst("__puus=".count)
                    if !value.isEmpty {
                        cookieLock.lock()
                        refreshedPuus = String(value)
                        cookieLock.unlock()
                    }
                }
            }
        }
    }

    public func latestCookie(from original: String) -> String {
        cookieWithRefreshedPuus(original: original)
    }

    private func cookieWithRefreshedPuus(original: String) -> String {
        cookieLock.lock()
        let puus = refreshedPuus
        cookieLock.unlock()
        guard let puus, !puus.isEmpty else { return original }
        var parts = original.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.hasPrefix("__puus=") }
        parts.append("__puus=\(puus)")
        return parts.joined(separator: "; ")
    }
}

private final class CachedDownloadUrl: @unchecked Sendable {
    let url: URL
    let expiryDate: Date

    init(url: URL, expiryDate: Date) {
        self.url = url
        self.expiryDate = expiryDate
    }

    var isExpired: Bool {
        Date() >= expiryDate
    }
}
