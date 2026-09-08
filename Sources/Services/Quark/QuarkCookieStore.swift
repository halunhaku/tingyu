import Foundation

enum QuarkCookieStore {
    static func account(for sourceId: String) -> String {
        "quark_cookie_\(sourceId)"
    }

    static func save(cookie: String, sourceId: String) throws {
        try? writeFallback(cookie: cookie, sourceId: sourceId)
        try? KeychainService.shared.save(password: cookie, for: account(for: sourceId))
    }

    static func load(sourceId: String) -> String? {
        if let cookie = readFallback(sourceId: sourceId), !cookie.isEmpty {
            return cookie
        }
        if let cookie = KeychainService.shared.get(for: account(for: sourceId)), !cookie.isEmpty {
            return cookie
        }
        return nil
    }
    static func delete(sourceId: String) {
        try? KeychainService.shared.delete(for: account(for: sourceId))
        try? FileManager.default.removeItem(at: fallbackURL(sourceId: sourceId))
    }

    private static func fallbackURL(sourceId: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("tingyu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quark_\(sourceId).cookie")
    }

    private static func writeFallback(cookie: String, sourceId: String) throws {
        try cookie.write(to: fallbackURL(sourceId: sourceId), atomically: true, encoding: .utf8)
    }

    private static func readFallback(sourceId: String) -> String? {
        guard let cookie = try? String(contentsOf: fallbackURL(sourceId: sourceId), encoding: .utf8) else {
            return nil
        }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
