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

        // Standard high-performance local SwiftData storage
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            print("Failed to initialize ModelContainer: \(error). Cleaning up incompatible store...")
            let storeUrl = localConfig.url
            try? FileManager.default.removeItem(at: storeUrl)
            try? FileManager.default.removeItem(at: storeUrl.appendingPathExtension("shm"))
            try? FileManager.default.removeItem(at: storeUrl.appendingPathExtension("wal"))

            if let fallbackContainer = try? ModelContainer(for: schema, configurations: [localConfig]) {
                return fallbackContainer
            }

            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }
}
