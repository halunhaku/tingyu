import Foundation
import SwiftData

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local
    case webdav
    case quark
}

@Model
public final class MusicSource {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var kindRaw: String = SourceKind.local.rawValue
    public var localBookmarkData: Data? = nil
    public var localFolderPath: String? = nil
    public var webdavUrl: String? = nil
    public var webdavUsername: String? = nil
    public var webdavRootPath: String? = nil
    public var syncStatus: String = "未同步"
    public var lastSyncedAt: Date? = nil
    public var trackCount: Int = 0
    public var quarkFolderFid: String? = nil
    public var quarkAccountName: String? = nil
    public var kind: SourceKind {
        get { SourceKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: SourceKind = .local,
        localBookmarkData: Data? = nil,
        localFolderPath: String? = nil,
        webdavUrl: String? = nil,
        webdavUsername: String? = nil,
        webdavRootPath: String? = nil,
        quarkFolderFid: String? = nil,
        quarkAccountName: String? = nil,
        syncStatus: String = "未同步",
        lastSyncedAt: Date? = nil,
        trackCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.localBookmarkData = localBookmarkData
        self.localFolderPath = localFolderPath
        self.webdavUrl = webdavUrl
        self.webdavUsername = webdavUsername
        self.webdavRootPath = webdavRootPath
        self.quarkFolderFid = quarkFolderFid
        self.quarkAccountName = quarkAccountName
        self.syncStatus = syncStatus
        self.lastSyncedAt = lastSyncedAt
        self.trackCount = trackCount
    }
}
