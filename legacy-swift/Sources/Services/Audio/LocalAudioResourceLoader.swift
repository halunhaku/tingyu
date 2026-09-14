import AVFoundation
import UniformTypeIdentifiers

/// Serves local file bytes to `AVPlayer` from this process.
/// Sandboxed apps cannot hand a security-scoped file URL to `mediaserverd`;
/// the resource loader keeps reads in-process after the folder bookmark is activated.
final class LocalAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let urlScheme = "tingyu-local"

    let queue = DispatchQueue(label: "com.halunhaku.tingyu.local-loader")
    let assetURL: URL

    private let fileLength: Int64
    private let contentType: String
    private let handle: FileHandle

    init?(fileURL: URL) {
        let path = fileURL.path
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size > 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }

        self.fileLength = size
        self.handle = handle
        self.contentType = Self.contentTypeIdentifier(for: fileURL.pathExtension)

        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "media"
        components.path = "/" + UUID().uuidString
        components.queryItems = [URLQueryItem(name: "ext", value: fileURL.pathExtension)]
        guard let url = components.url else { return nil }
        self.assetURL = url
        super.init()
    }

    deinit {
        try? handle.close()
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

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Serial queue already drops work after cancel; nothing extra to unwind.
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        if loadingRequest.isCancelled {
            return
        }

        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = fileLength
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let offset = max(dataRequest.requestedOffset, 0)
        if offset >= fileLength {
            loadingRequest.finishLoading()
            return
        }

        let remainingToEnd = Int(fileLength - offset)
        let length: Int
        if dataRequest.requestsAllDataToEndOfResource {
            length = remainingToEnd
        } else {
            length = min(dataRequest.requestedLength, remainingToEnd)
        }

        do {
            try handle.seek(toOffset: UInt64(offset))
            var left = length
            while left > 0 {
                if loadingRequest.isCancelled { return }
                let chunk = min(left, 64 * 1024)
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
                dataRequest.respond(with: data)
                left -= data.count
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private static func contentTypeIdentifier(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp3":
            return UTType.mp3.identifier
        case "m4a", "aac", "alac":
            return UTType.mpeg4Audio.identifier
        case "wav":
            return UTType.wav.identifier
        case "aiff", "aif":
            return UTType.aiff.identifier
        case "flac":
            return "org.xiph.flac"
        case "ogg":
            return "org.xiph.ogg"
        case "opus":
            return "org.xiph.opus"
        default:
            return UTType.audio.identifier
        }
    }
}
