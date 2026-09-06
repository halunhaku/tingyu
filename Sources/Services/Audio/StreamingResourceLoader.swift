import AVFoundation
import UniformTypeIdentifiers

/// Feeds a remote audio URL to `AVPlayer` while attaching required HTTP headers.
/// Quark CDN rejects AppleCoreMedia's default User-Agent unless Cookie + UA match the download request.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let urlScheme = "tingyu-stream"

    let queue = DispatchQueue(label: "com.halunhaku.tingyu.stream-loader")
    let assetURL: URL

    private let realURL: URL
    private let headers: [String: String]
    private let fileExtension: String
    private let session: URLSession
    private var knownLength: Int64 = 0
    private var knownType: String?

    init?(url: URL, headers: [String: String], fileExtension: String = "") {
        self.realURL = url
        self.headers = headers
        self.fileExtension = fileExtension

        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "media"
        components.path = "/" + UUID().uuidString + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        guard let assetURL = components.url else { return nil }
        self.assetURL = assetURL

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async { [weak self] in
            self?.fulfill(loadingRequest)
        }
        return true
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        if loadingRequest.isCancelled { return }

        if loadingRequest.contentInformationRequest != nil, knownLength <= 0 {
            if let error = probeContentInfo() {
                loadingRequest.finishLoading(with: error)
                return
            }
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = knownType ?? Self.contentTypeIdentifier(mime: nil, ext: fileExtension)
            info.isByteRangeAccessSupported = true
            info.contentLength = knownLength
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let offset = max(dataRequest.requestedOffset, 0)
        let chunk: Int64 = 512 * 1024
        let requested = Int64(dataRequest.requestedLength)
        let unlimited = dataRequest.requestsAllDataToEndOfResource
            || requested >= chunk
            || requested == Int.max
        let end: Int64
        if unlimited {
            if knownLength > offset {
                end = min(offset + chunk, knownLength) - 1
            } else {
                end = offset + chunk - 1
            }
        } else {
            end = offset + max(requested, 1) - 1
        }

        var request = URLRequest(url: realURL)
        request.httpMethod = "GET"
        applyHeaders(&request)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

        let result = perform(request)
        if loadingRequest.isCancelled { return }

        if let error = result.error {
            loadingRequest.finishLoading(with: error)
            return
        }

        guard let http = result.response else {
            loadingRequest.finishLoading(with: Self.makeError("无响应"))
            return
        }

        if !(200...299).contains(http.statusCode) {
            loadingRequest.finishLoading(with: Self.makeError("CDN HTTP \(http.statusCode)"))
            return
        }

        if knownLength <= 0, let total = Self.totalLength(from: http) {
            knownLength = total
        }

        var body = result.data
        if http.statusCode == 200, offset > 0, offset < Int64(body.count) {
            body = body.subdata(in: Int(offset)..<body.count)
        }
        if !body.isEmpty {
            dataRequest.respond(with: body)
        }
        loadingRequest.finishLoading()
    }

    private func probeContentInfo() -> Error? {
        var request = URLRequest(url: realURL)
        request.httpMethod = "GET"
        applyHeaders(&request)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let result = perform(request)
        if let error = result.error { return error }
        guard let http = result.response else {
            return Self.makeError("无法读取音频信息")
        }
        if !(200...299).contains(http.statusCode) {
            return Self.makeError("CDN HTTP \(http.statusCode)")
        }

        knownType = Self.contentTypeIdentifier(
            mime: http.value(forHTTPHeaderField: "Content-Type"),
            ext: fileExtension
        )
        if let total = Self.totalLength(from: http), total > 2 {
            knownLength = total
        } else if http.statusCode == 200, http.expectedContentLength > 2 {
            knownLength = http.expectedContentLength
        } else if result.data.count > 2 {
            knownLength = Int64(result.data.count)
        }
        return nil
    }

    private func applyHeaders(_ request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    }

    private func perform(_ request: URLRequest) -> (data: Data, response: HTTPURLResponse?, error: Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var data = Data()
        var response: HTTPURLResponse?
        var error: Error?
        session.dataTask(with: request) { body, urlResponse, taskError in
            data = body ?? Data()
            response = urlResponse as? HTTPURLResponse
            error = taskError
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (data, response, error)
    }

    private static func totalLength(from http: HTTPURLResponse) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range") {
            if let total = range.split(separator: "/").last, total != "*", let value = Int64(total), value > 0 {
                return value
            }
        }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
    }

    private static func contentTypeIdentifier(mime: String?, ext: String) -> String {
        let lowered = (mime ?? "").lowercased()
        if lowered.contains("mpeg") || lowered.contains("mp3") { return UTType.mp3.identifier }
        if lowered.contains("mp4") || lowered.contains("aac") || lowered.contains("m4a") {
            return UTType.mpeg4Audio.identifier
        }
        if lowered.contains("flac") { return "org.xiph.flac" }
        if lowered.contains("wav") { return UTType.wav.identifier }
        switch ext.lowercased() {
        case "mp3": return UTType.mp3.identifier
        case "m4a", "aac", "alac": return UTType.mpeg4Audio.identifier
        case "wav": return UTType.wav.identifier
        case "aiff", "aif": return UTType.aiff.identifier
        case "flac": return "org.xiph.flac"
        case "ogg": return "org.xiph.ogg"
        case "opus": return "org.xiph.opus"
        default: return UTType.mp3.identifier
        }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "tingyu.stream",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
