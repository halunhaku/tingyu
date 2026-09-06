import Foundation
import SwiftData
import SQLite3

@MainActor
public final class LegacyCacheMigrator {
    public static func migrateIfNeeded(modelContext: ModelContext, sources: [MusicSource]) {
        // Only run if we have a WebDAV source
        guard let webdavSource = sources.first(where: { $0.kind == .webdav }) else { return }

        // Check if we already have tracks
        let sourceId = webdavSource.id
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.sourceId == sourceId })
        if let count = try? modelContext.fetchCount(descriptor), count > 0 {
            return
        }

        // Look for legacy SQLite cache files
        #if os(macOS)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let oldCacheDir = homeDir.appendingPathComponent("Library/Application Support/com.halunhaku.tingyu/source-caches")
        #else
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldCacheDir = appSupport.appendingPathComponent("com.halunhaku.tingyu/source-caches")
        #endif
        guard let files = try? FileManager.default.contentsOfDirectory(at: oldCacheDir, includingPropertiesForKeys: nil) else {
            return
        }

        let sqliteFiles = files.filter { $0.pathExtension == "sqlite3" }
        guard let primaryDb = sqliteFiles.first else { return }

        var db: OpaquePointer?
        guard sqlite3_open(primaryDb.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = "SELECT title, artist, album, duration, href, size, synced_lyrics, plain_lyrics FROM webdav_tracks;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var importedCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = String(cString: sqlite3_column_text(stmt, 0))
            let artist = String(cString: sqlite3_column_text(stmt, 1))
            let album = String(cString: sqlite3_column_text(stmt, 2))
            let duration = sqlite3_column_double(stmt, 3)
            let href = String(cString: sqlite3_column_text(stmt, 4))
            let size = sqlite3_column_int64(stmt, 5)

            var lyrics: String? = nil
            if let syncedText = sqlite3_column_text(stmt, 6) {
                lyrics = String(cString: syncedText)
            } else if let plainText = sqlite3_column_text(stmt, 7) {
                lyrics = String(cString: plainText)
            }

            let ext = (href as NSString).pathExtension.lowercased()

            let track = Track(
                sourceId: sourceId,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                fileFormat: ext.isEmpty ? "mp3" : ext,
                filePathOrUrl: href,
                fileSize: size,
                lyrics: lyrics
            )

            modelContext.insert(track)
            importedCount += 1

            // Trigger background cover enrichment
            Task {
                await MetadataEnricher.shared.enrichTrackIfNeeded(track)
            }
        }

        if importedCount > 0 {
            webdavSource.trackCount = importedCount
            webdavSource.syncStatus = "已同步 \(importedCount) 首 (本地缓存就绪)"
            try? modelContext.save()
            print("Successfully migrated \(importedCount) tracks from legacy cache into SwiftData!")
        }
    }
}
