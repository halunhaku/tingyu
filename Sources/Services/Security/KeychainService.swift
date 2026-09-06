import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "钥匙串中已存在相同条目"
        case .itemNotFound:
            return "钥匙串中未找到指定凭据"
        case .unexpectedStatus(let status):
            return "钥匙串操作失败，错误码：\(status)"
        case .invalidData:
            return "凭据数据格式错误"
        }
    }
}

public final class KeychainService: Sendable {
    public static let shared = KeychainService()
    public static let defaultService = "com.halunhaku.tingyu.webdav"

    public init() {}

    public func save(password: String, for account: String, service: String = defaultService) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query = baseQuery(account: account, service: service)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        } else {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        }
    }

    public func get(for account: String, service: String = defaultService) -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    public func delete(for account: String, service: String = defaultService) throws {
        let query = baseQuery(account: account, service: service)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String, service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }
}
