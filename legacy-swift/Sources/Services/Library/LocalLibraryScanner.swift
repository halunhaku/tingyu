import Foundation
import AVFoundation

public struct ScannedMetadata: Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let genre: String?
    public let coverArtData: Data?
    public let bitrate: Int?
    public let sampleRate: Int?
}

public final class LocalLibraryScanner: Sendable {
    public static let shared = LocalLibraryScanner()
    public static let supportedExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "ogg", "opus", "aiff", "alac"
    ]

    public init() {}

    // MARK: - Security-Scoped Bookmarks

    public func createBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolveBookmark(data: Data) throws -> URL {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
        return url
    }

    // MARK: - Scanning

    public func scanFolder(
        at folderUrl: URL,
        sourceId: String,
        maxDepth: Int = 8,
        maxFiles: Int = 5000,
        progressHandler: (@Sendable (Int, String) -> Void)? = nil
    ) async -> [Track] {
        let isAccessing = folderUrl.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                folderUrl.stopAccessingSecurityScopedResource()
            }
        }

        let audioUrls = collectAudioUrls(in: folderUrl, maxFiles: maxFiles)

        let fileManager = FileManager.default
        var tracks: [Track] = []
        for (index, fileUrl) in audioUrls.enumerated() {
            let relativePath = fileUrl.lastPathComponent
            progressHandler?(index + 1, relativePath)

            let attributes = try? fileManager.attributesOfItem(atPath: fileUrl.path)
            let fileSize = (attributes?[.size] as? Int64) ?? 0
            let lastModified = attributes?[.modificationDate] as? Date

            let metadata = await extractMetadata(from: fileUrl)
            let track = Track(
                sourceId: sourceId,
                title: metadata.title.isEmpty ? fileUrl.deletingPathExtension().lastPathComponent : metadata.title,
                artist: metadata.artist.isEmpty ? "未知艺术家" : metadata.artist,
                album: metadata.album.isEmpty ? "未知专辑" : metadata.album,
                duration: metadata.duration,
                trackNumber: metadata.trackNumber,
                discNumber: metadata.discNumber,
                year: metadata.year,
                genre: metadata.genre,
                bitrate: metadata.bitrate,
                sampleRate: metadata.sampleRate,
                fileFormat: fileUrl.pathExtension.lowercased(),
                filePathOrUrl: fileUrl.path,
                fileSize: fileSize,
                lastModified: lastModified,
                coverArtData: metadata.coverArtData
            )
            tracks.append(track)
        }

        return tracks
    }

    private func collectAudioUrls(in folderUrl: URL, maxFiles: Int) -> [URL] {
        var audioUrls: [URL] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderUrl,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        while let fileUrl = enumerator.nextObject() as? URL {
            if audioUrls.count >= maxFiles { break }
            let ext = fileUrl.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                audioUrls.append(fileUrl)
            }
        }
        return audioUrls
    }

    // MARK: - Metadata Extraction

    public func extractMetadata(from url: URL) async -> ScannedMetadata {
        let asset = AVURLAsset(url: url)
        var title = ""
        var artist = ""
        var album = ""
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var coverArtData: Data?
        var duration: Double = 0.0

        if let assetDuration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(assetDuration)
            if !seconds.isNaN && !seconds.isInfinite && seconds > 0 {
                duration = seconds
            }
        }

        if let metadataItems = try? await asset.load(.commonMetadata) {
            for item in metadataItems {
                guard let commonKey = item.commonKey else { continue }
                switch commonKey {
                case .commonKeyTitle:
                    title = (try? await item.load(.stringValue)) ?? ""
                case .commonKeyArtist:
                    artist = (try? await item.load(.stringValue)) ?? ""
                case .commonKeyAlbumName:
                    album = (try? await item.load(.stringValue)) ?? ""
                case .commonKeyArtwork:
                    coverArtData = try? await item.load(.dataValue)
                case .commonKeyCreationDate:
                    if let dateStr = try? await item.load(.stringValue) {
                        year = Int(dateStr.prefix(4))
                    }
                case .commonKeyType:
                    genre = try? await item.load(.stringValue)
                default:
                    break
                }
            }
        }

        // Secondary metadata lookup
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) {
                    for item in items {
                        if let key = item.keyString {
                            if key.contains("track") || key.contains("TRCK") {
                                if let val = try? await item.load(.stringValue) {
                                    trackNumber = Int(val.components(separatedBy: "/").first ?? "")
                                }
                            } else if key.contains("disc") || key.contains("TPOS") {
                                if let val = try? await item.load(.stringValue) {
                                    discNumber = Int(val.components(separatedBy: "/").first ?? "")
                                }
                            }
                        }
                    }
                }
            }
        }

        return ScannedMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            genre: genre,
            coverArtData: coverArtData,
            bitrate: nil,
            sampleRate: nil
        )
    }
}

private extension AVMetadataItem {
    var keyString: String? {
        if let key = key as? String {
            return key
        } else if let number = key as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
