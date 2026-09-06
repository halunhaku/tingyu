import Foundation

public struct AIInputItem: Codable, Sendable {
    public let id: String
    public let filename: String

    public init(id: String, filename: String) {
        self.id = id
        self.filename = filename
    }
}

public struct AIOutputItem: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String?
}

public enum AIMetadataParser {
    private static let systemPrompt = """
    你是一位资深的华语与国际音乐元数据专家。用户会提供一组包含噪声、乱码或特殊格式的音频文件名。
    请凭借你庞大的音乐常识，识别出每首歌曲的真实信息：
    1. title: 标准中文或官方歌曲名（不要带Live、伴奏、前导序号、点号等噪声）
    2. artist: 标准主要歌手或音乐人（华语歌曲优先使用常见标准简体中文，如 周杰伦、陈奕迅）
    3. album: 该歌曲所属的正式录音室专辑或官方原声带名称（若无法确定可填已知专辑）

    必须严格只输出合法的 JSON 数组，严禁包含任何 Markdown 标记外的多余解释。格式示例：
    [
      {"id": "1", "title": "园游会", "artist": "周杰伦", "album": "七里香"},
      {"id": "2", "title": "早操", "artist": "周杰伦", "album": "不能说的秘密 电影原声带"}
    ]
    """

    public static func parseBatch(items: [AIInputItem]) async throws -> [String: ParsedSongInfo] {
        guard !items.isEmpty else { return [:] }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let inputData = try encoder.encode(items)
        let inputJsonString = String(data: inputData, encoding: .utf8) ?? ""

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: "请清洗并识别以下歌曲文件名：\n\(inputJsonString)")
        ]

        let responseText = try await AIService.shared.complete(messages: messages, temperature: 0.1)

        // Clean markdown code blocks if wrapped with ```json ... ```
        var cleanJson = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanJson.hasPrefix("```") {
            let lines = cleanJson.components(separatedBy: .newlines)
            if lines.count >= 3 {
                cleanJson = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }

        guard let jsonData = cleanJson.data(using: .utf8),
              let results = try? JSONDecoder().decode([AIOutputItem].self, from: jsonData) else {
            throw NSError(domain: "AIMetadataParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "AI 输出的 JSON 无法解析"])
        }

        var map: [String: ParsedSongInfo] = [:]
        for item in results {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (item.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                map[item.id] = ParsedSongInfo(title: title, artist: artist, album: album)
            }
        }

        return map
    }
}
