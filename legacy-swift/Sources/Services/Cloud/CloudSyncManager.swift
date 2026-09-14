import Foundation
import SwiftData
import CloudKit

@MainActor
@Observable
public final class CloudSyncManager {
    public static let shared = CloudSyncManager()
    public static let containerIdentifier = "iCloud.com.halunhaku.tingyu"

    public var isCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCloudSyncEnabled, forKey: "tingyu_icloud_sync_enabled")
        }
    }

    public var accountStatus: CKAccountStatus = .couldNotDetermine
    public var statusMessage: String = "正在检测 iCloud 状态..."

    public init() {
        self.isCloudSyncEnabled = UserDefaults.standard.object(forKey: "tingyu_icloud_sync_enabled") as? Bool ?? false
        let hasProvisioningProfile = Bundle.main.path(forResource: "embedded", ofType: "provisionprofile") != nil
        if hasProvisioningProfile {
            Task {
                await checkAccountStatus()
            }
        } else {
            self.statusMessage = "本地独立存储模式"
        }
    }

    public func checkAccountStatus() async {
        let hasProvisioningProfile = Bundle.main.path(forResource: "embedded", ofType: "provisionprofile") != nil
        guard hasProvisioningProfile else {
            self.statusMessage = "本地独立存储模式"
            return
        }

        do {
            let container = CKContainer(identifier: Self.containerIdentifier)
            let status = try await container.accountStatus()
            self.accountStatus = status
            switch status {
            case .available:
                self.statusMessage = isCloudSyncEnabled ? "iCloud 云同步已正常启用" : "iCloud 已连接（已暂停同步）"
            case .noAccount:
                self.statusMessage = "未登录 Apple ID（仅本地存储）"
            case .restricted:
                self.statusMessage = "iCloud 访问受家长控制或策略限制"
            case .couldNotDetermine:
                self.statusMessage = "无法连接至 iCloud 服务"
            case .temporarilyUnavailable:
                self.statusMessage = "iCloud 服务暂不可用"
            @unknown default:
                self.statusMessage = "iCloud 状态未知"
            }
        } catch {
            self.statusMessage = "本地独立存储模式"
        }
    }

    public static func createModelContainer() -> ModelContainer {
        let schema = Schema([
            Track.self,
            MusicSource.self,
            Playlist.self
        ])

        // Check if app has embedded provisioning profile for CloudKit
        let hasProvisioningProfile = Bundle.main.path(forResource: "embedded", ofType: "provisionprofile") != nil
        let userEnabled = UserDefaults.standard.bool(forKey: "tingyu_icloud_sync_enabled")

        if hasProvisioningProfile && userEnabled {
            do {
                let cloudConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .private(containerIdentifier)
                )
                return try ModelContainer(for: schema, configurations: [cloudConfig])
            } catch {
                print("CloudKit container initialization failed: \(error). Falling back to local storage.")
            }
        }

        // Pin the store to the app container. With an App Group entitlement, SwiftData's
        // default URL moves into the group container, which is unwritable without a Team ID.
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let storeURL = supportDir.appendingPathComponent("default.store")
        let localConfig = ModelConfiguration(
            "library",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        Self.writeStoreDebug("opening \(localConfig.url.path)")

        do {
            let container = try ModelContainer(for: schema, configurations: [localConfig])
            Self.writeStoreDebug("opened \(localConfig.url.path)")
            return container
        } catch {
            Self.writeStoreDebug("Failed to initialize local ModelContainer: \(error)\nurl=\(localConfig.url.path)")
            print("Failed to initialize local ModelContainer: \(error)")
            // Never delete the user's library. Retry once, then empty in-memory so the app still launches.
            if let retry = try? ModelContainer(for: schema, configurations: [localConfig]) {
                return retry
            }
            print("Falling back to in-memory SwiftData store.")
            let memoryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: schema, configurations: [memoryConfig])
        }
    }

    private static func writeStoreDebug(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("tingyu").appendingPathComponent("store-debug.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
