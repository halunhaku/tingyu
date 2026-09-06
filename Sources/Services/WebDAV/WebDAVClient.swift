import Foundation

public enum WebDAVError: LocalizedError, Sendable {
    case unauthorized
    case forbidden
    case rateLimited(String)
    case serverError(Int, String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "WebDAV 认证失败，请检查账号和应用专用密码"
        case .forbidden:
            return "WebDAV 拒绝访问该目录 (403 Forbidden)"
        case .rateLimited(let msg):
            return msg
        case .serverError(let code, let msg):
            return "WebDAV 服务器返回错误 (\(code)): \(msg)"
        case .networkError(let msg):
            return "网络连接失败: \(msg)"
        }
    }
}

public final class WebDAVClient: Sendable {
    public static let shared = WebDAVClient()

    private let session: URLSession

    private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname />
        <d:resourcetype />
        <d:getcontentlength />
        <d:getcontenttype />
        <d:getlastmodified />
        <d:getetag />
      </d:prop>
    </d:propfind>
    """

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Connection Test & Scan

    public func testConnection(url: URL, username: String, password: String) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = Self.propfindBody.data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            return (200...299).contains(httpResponse.statusCode)
        }
        return false
    }

    public func scan(
        rootUrl: URL,
        sourceId: String,
        username: String,
        password: String,
        maxDepth: Int = 8,
        maxFiles: Int = 5000,
        progressHandler: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> [Track] {
        var discoveredTracks: [Track] = []
        var queue: [(URL, Int)] = [(rootUrl, 0)]
        var visitedPaths = Set<String>()

        let normalizedRootPath = normalizePath(rootUrl.path)
        visitedPaths.insert(normalizedRootPath)

        let authHeader = basicAuthHeader(username: username, password: password)
        let parser = WebDAVXMLParser()
        let bodyData = Self.propfindBody.data(using: .utf8)

        while !queue.isEmpty && discoveredTracks.count < maxFiles {
            let (currentDirUrl, depth) = queue.removeFirst()
            if depth > maxDepth { continue }

            var request = URLRequest(url: currentDirUrl)
            request.httpMethod = "PROPFIND"
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if depth == 0 {
                    throw WebDAVError.networkError(error.localizedDescription)
                }
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                continue
            }

            if httpResponse.statusCode == 401 {
                throw WebDAVError.unauthorized
            } else if httpResponse.statusCode == 403 {
                throw WebDAVError.forbidden
            } else if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                var msg = "坚果云提示请求过于频繁 (503 临时流控)，请等待 5-10 分钟自动解封"
                if let xmlStr = String(data: data, encoding: .utf8), xmlStr.contains("BlockedTemporarily") {
                    msg = "坚果云提示请求过于频繁（临时封禁中），请稍候 5-10 分钟自动解封"
                }
                throw WebDAVError.rateLimited(msg)
            } else if !(200...299).contains(httpResponse.statusCode) {
                if depth == 0 {
                    throw WebDAVError.serverError(httpResponse.statusCode, "HTTP \(httpResponse.statusCode)")
                }
                continue
            }

            // Gentle throttle between folders
            try? await Task.sleep(nanoseconds: 120_000_000)

            let items = parser.parse(data: data)
            let currentDirPath = normalizePath(currentDirUrl.path)

            for item in items {
                guard let itemUrl = resolveItemUrl(href: item.href, baseUrl: rootUrl, currentDirUrl: currentDirUrl) else {
                    continue
                }

                let itemPath = normalizePath(itemUrl.path)

                // 1. Skip self
                if itemPath == currentDirPath {
                    continue
                }

                // 2. Strict boundary check: item MUST be within rootUrl directory (reject parent dirs)
                if !itemPath.hasPrefix(normalizedRootPath) {
                    continue
                }

                // 3. Skip junk / hidden directories (e.g. Synology @eaDir, #recycle, .Trash)
                let lastSegment = itemUrl.lastPathComponent
                if lastSegment.hasPrefix(".") || lastSegment.hasPrefix("@") || lastSegment.hasPrefix("#") {
                    continue
                }

                if item.isDirectory {
                    if !visitedPaths.contains(itemPath) && depth + 1 <= maxDepth {
                        visitedPaths.insert(itemPath)
                        queue.append((itemUrl, depth + 1))
                    }
                } else {
                    let ext = itemUrl.pathExtension.lowercased()
                    if LocalLibraryScanner.supportedExtensions.contains(ext) {
                        let rawName: String
                        if let display = item.displayName, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            rawName = display.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            let fileName = itemUrl.deletingPathExtension().lastPathComponent
                            rawName = fileName.removingPercentEncoding ?? fileName
                        }

                        let parsed = SmartTitleParser.parse(filename: rawName)
                        progressHandler?(discoveredTracks.count + 1, parsed.title)

                        let track = Track(
                            sourceId: sourceId,
                            title: parsed.title,
                            artist: parsed.artist,
                            album: parsed.album == "未知专辑" ? "WebDAV 曲库" : parsed.album,
                            duration: 0.0,
                            fileFormat: ext,
                            filePathOrUrl: itemUrl.absoluteString,
                            fileSize: item.contentLength,
                            etag: item.etag
                        )
                        discoveredTracks.append(track)

                        if discoveredTracks.count >= maxFiles {
                            break
                        }
                    }
                }
            }
        }

        return discoveredTracks
    }

    private func normalizePath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + trimmed + "/"
    }

    private func resolveItemUrl(href: String, baseUrl: URL, currentDirUrl: URL) -> URL? {
        let clean = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // If it's already a full absolute URL
        if let directUrl = URL(string: clean), directUrl.scheme != nil {
            return directUrl
        }

        let percentEncoded: String
        if clean.contains("%") {
            percentEncoded = clean.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlFragmentAllowed.union(.urlPathAllowed).union(.urlQueryAllowed).union(CharacterSet(charactersIn: "%"))) ?? clean
        } else {
            percentEncoded = clean.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlFragmentAllowed.union(.urlPathAllowed).union(.urlQueryAllowed)) ?? clean
        }

        if percentEncoded.hasPrefix("/") {
            let baseSchemeAndHost = "\(baseUrl.scheme ?? "http")://\(baseUrl.host ?? "")\(baseUrl.port != nil ? ":\(baseUrl.port!)" : "")"
            return URL(string: baseSchemeAndHost + percentEncoded)
        } else {
            return URL(string: percentEncoded, relativeTo: currentDirUrl)?.absoluteURL
        }
    }

    private func basicAuthHeader(username: String, password: String) -> String {
        let cred = "\(username):\(password)"
        guard let data = cred.data(using: .utf8) else { return "" }
        return "Basic \(data.base64EncodedString())"
    }
}
