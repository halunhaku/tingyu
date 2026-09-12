// ExportLegacyLibrary.swift
// 一次性工具：把听屿 Swift 原生版的 SwiftData 曲库导出为 JSON，供 Flutter 版导入。
//
// 编译（必须指定 Xcode 的 DEVELOPER_DIR，因为 xcode-select 指向 CommandLineTools）：
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//   swiftc -parse-as-library -O \
//     -o /tmp/tingyu-legacy-export \
//     tools/legacy-export/ExportLegacyLibrary.swift \
//     Sources/Models/Track.swift \
//     Sources/Models/MusicSource.swift \
//     Sources/Models/Playlist.swift
//
// 运行（默认写到 ~/Desktop/tingyu-legacy-export.json，也可以传第一个参数指定路径）：
//
//   /tmp/tingyu-legacy-export [/tmp/tingyu-legacy-export.json]
//
// 安全策略：
//   * 绝不以可写方式打开真实存储。真实存储是
//     ~/Library/Application Support/default.store（含 -shm / -wal）。
//   * 先把 default.store 及其 -wal / -shm（存在才复制）复制到 NSTemporaryDirectory()
//     下的一个全新副本目录，副本保持同名 default.store，然后用
//     ModelConfiguration("library", schema:, url: <副本>, cloudKitDatabase: .none) 打开副本。
//   * WAL 说明：SQLite 只在 <db>-wal / <db>-shm 与主库同名同目录时才认它们，
//     所以副本目录里三者的 basename 必须都是 default.store。存在 -wal 时，
//     -wal 里的已提交数据只能靠 -wal（以及 -shm 索引）读到；如果 -shm 副本不一致
//     导致打不开副本库，工具会删掉 -shm 副本重试一次，让 SQLite 依据 -wal 重建索引，
//     从而保证 -wal 中的数据不丢。无论走哪条路径，实际读到的数量都会打印到 stdout。
//   * 另外复制 .default_SUPPORT（若存在）：coverArtData 用 @Attribute(.externalStorage)，
//     其大 blob 存放在与主库同名的 <父目录>/.default_SUPPORT/_EXTERNAL_DATA 下，
//     不复制的话封面数据读不出来（副本同名，所以目录名天然匹配）。
//   * 不导出任何密码 / Cookie（SwiftData 模型里本来就没有这类字段，已确认）。
//
// 边界处理：
//   * kindRaw 非法值 -> kind 按 "local" 输出并继续。
//   * coverArtData 为 nil 或空 -> coverArtBase64 写 null。
//   * 日期统一 ISO8601 UTC（带毫秒、Z 结尾）；空值写 null（键始终存在）。

import Foundation
import SwiftData

@main
struct ExportLegacyLibrary {

    // MARK: - JSON 契约

    private static let contractVersion = 1

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func date(_ value: Date?) -> Any {
        guard let value else { return NSNull() }
        return isoFormatter.string(from: value)
    }

    private static func text(_ value: String?) -> Any {
        guard let value, !value.isEmpty else { return NSNull() }
        return value
    }

    /// 空 / nil 的 Data 输出 null，其余输出 base64。
    private static func base64(_ value: Data?) -> Any {
        guard let value, !value.isEmpty else { return NSNull() }
        return value.base64EncodedString()
    }

    private static func nullOr<T>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    // MARK: - 入口

    static func main() throws {
        let arguments = CommandLine.arguments
        let outputURL: URL = {
            if arguments.count > 1, !arguments[1].isEmpty {
                return URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/tingyu-legacy-export.json")
        }()

        let sourceDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let originalStore = sourceDirectory.appendingPathComponent("default.store")

        guard FileManager.default.fileExists(atPath: originalStore.path) else {
            FileHandle.standardError.write(Data("找不到 SwiftData 存储: \(originalStore.path)\n".utf8))
            exit(2)
        }

        let (copyDirectory, copyStore, skippedBackups) = try makeSnapshot(of: originalStore)
        print("原库（只读复制源）: \(originalStore.path)")
        print("副本目录: \(copyDirectory.path)")
        if !skippedBackups.isEmpty {
            print("未复制的伴随文件（不存在）: \(skippedBackups.joined(separator: ", "))")
        }

        let schema = Schema([Track.self, MusicSource.self, Playlist.self])
        let configuration = ModelConfiguration(
            "library",
            schema: schema,
            url: copyStore,
            cloudKitDatabase: .none
        )

        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // -shm 与 -wal 不自洽时删掉 -shm 副本重试，让 SQLite 从 -wal 重建索引。
            print("首次打开副本失败（\(error)），删除 -shm 副本后重试以保留 -wal 数据。")
            try? FileManager.default.removeItem(at: copyDirectory.appendingPathComponent("default.store-shm"))
            container = try ModelContainer(for: schema, configurations: [configuration])
        }

        let context = ModelContext(container)
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let sources = try context.fetch(FetchDescriptor<MusicSource>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())

        let root: [String: Any] = [
            "version": contractVersion,
            "exportedAt": date(Date()),
            "sources": sources.map(sourceDictionary),
            "tracks": tracks.map(trackDictionary),
            "playlists": playlists.map(playlistDictionary)
        ]

        let payload = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .prettyPrinted]
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: outputURL, options: .atomic)

        print("导出完成: \(outputURL.path)")
        print("sources: \(sources.count)")
        print("tracks: \(tracks.count)")
        print("playlists: \(playlists.count)")
    }

    // MARK: - 快照

    /// 把真实存储复制到 NSTemporaryDirectory() 下的独立副本目录。
    /// 返回 (副本目录, 副本 default.store 路径, 不存在的伴随文件 basename)。
    private static func makeSnapshot(of originalStore: URL) throws -> (URL, URL, [String]) {
        let fileManager = FileManager.default
        let copyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tingyu-legacy-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)

        // 主库必须叫 default.store，这样 -wal / -shm / .default_SUPPORT 的命名才能对上。
        let copyStore = copyDirectory.appendingPathComponent("default.store")
        try fileManager.copyItem(at: originalStore, to: copyStore)

        var skipped: [String] = []
        for suffix in ["-wal", "-shm"] {
            let originalSidecar = sidecar(of: originalStore, suffix: suffix)
            guard fileManager.fileExists(atPath: originalSidecar.path) else {
                skipped.append(originalSidecar.lastPathComponent)
                continue
            }
            try fileManager.copyItem(at: originalSidecar, to: sidecar(of: copyStore, suffix: suffix))
        }

        // @Attribute(.externalStorage) 的 blob 存放目录，目录名与主库同名（去扩展名）。
        let originalSupport = originalStore.deletingLastPathComponent()
            .appendingPathComponent(".default_SUPPORT", isDirectory: true)
        if fileManager.fileExists(atPath: originalSupport.path) {
            try? fileManager.copyItem(
                at: originalSupport,
                to: copyDirectory.appendingPathComponent(".default_SUPPORT", isDirectory: true)
            )
        }

        return (copyDirectory, copyStore, skipped)
    }

    private static func sidecar(of store: URL, suffix: String) -> URL {
        URL(fileURLWithPath: store.path + suffix)
    }

    // MARK: - 记录映射

    private static func sourceDictionary(_ source: MusicSource) -> [String: Any] {
        // kindRaw 非法值按 local 处理并继续。
        let kind = SourceKind(rawValue: source.kindRaw) ?? .local
        return [
            "id": source.id,
            "name": source.name,
            "kind": kind.rawValue,
            "localFolderPath": text(source.localFolderPath),
            "localBookmarkBase64": base64(source.localBookmarkData),
            "webdavUrl": text(source.webdavUrl),
            "webdavUsername": text(source.webdavUsername),
            "webdavRootPath": text(source.webdavRootPath),
            "quarkFolderFid": text(source.quarkFolderFid),
            "quarkAccountName": text(source.quarkAccountName),
            "syncStatus": source.syncStatus,
            "lastSyncedAt": date(source.lastSyncedAt),
            "trackCount": source.trackCount
        ]
    }

    private static func trackDictionary(_ track: Track) -> [String: Any] {
        [
            "id": track.id,
            "sourceId": track.sourceId,
            "title": track.title,
            "artist": track.artist,
            "album": track.album,
            "duration": track.duration,
            "trackNumber": nullOr(track.trackNumber),
            "discNumber": nullOr(track.discNumber),
            "year": nullOr(track.year),
            "genre": text(track.genre),
            "bitrate": nullOr(track.bitrate),
            "sampleRate": nullOr(track.sampleRate),
            "fileFormat": track.fileFormat,
            "filePathOrUrl": track.filePathOrUrl,
            "fileSize": track.fileSize,
            "etag": text(track.etag),
            "lastModified": date(track.lastModified),
            "coverArtBase64": base64(track.coverArtData),
            "coverArtUrl": text(track.coverArtUrl),
            "lyrics": text(track.lyrics),
            "isFavorite": track.isFavorite,
            "dateAdded": date(track.dateAdded),
            "playCount": track.playCount,
            "lastPlayedAt": date(track.lastPlayedAt)
        ]
    }

    private static func playlistDictionary(_ playlist: Playlist) -> [String: Any] {
        [
            "id": playlist.id,
            "name": playlist.name,
            "createdAt": date(playlist.createdAt),
            "trackIds": playlist.trackIds
        ]
    }
}
