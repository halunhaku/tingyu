import Foundation

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatCompletionRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let temperature: Double?

    public init(model: String, messages: [ChatMessage], temperature: Double? = 0.1) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
    }
}

public struct ChatCompletionResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public struct Message: Codable, Sendable {
            public let role: String?
            public let content: String?
        }
        public let message: Message?
    }
    public let choices: [Choice]?
}

public enum AIProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case deepseek = "DeepSeek"
    case qwen = "通义千问 (Qwen)"
    case kimi = "Kimi (Moonshot)"
    case openai = "OpenAI"
    case ollama = "本地 Ollama"
    case custom = "自定义"

    public var id: String { rawValue }

    public var defaultBaseURL: String {
        switch self {
        case .deepseek:
            return "https://api.deepseek.com/v1"
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:
            return "https://api.moonshot.cn/v1"
        case .openai:
            return "https://api.openai.com/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        case .custom:
            return "https://api.openai.com/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepseek:
            return "deepseek-chat"
        case .qwen:
            return "qwen-plus"
        case .kimi:
            return "moonshot-v1-8k"
        case .openai:
            return "gpt-4o-mini"
        case .ollama:
            return "qwen2.5:7b"
        case .custom:
            return "gpt-4o-mini"
        }
    }
}

public final class AIService: @unchecked Sendable {
    public static let shared = AIService()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: config)
    }

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "tingyu_ai_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "tingyu_ai_enabled") }
    }

    public var baseURL: String {
        get { UserDefaults.standard.string(forKey: "tingyu_ai_base_url") ?? AIProviderPreset.deepseek.defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "tingyu_ai_base_url") }
    }

    public var model: String {
        get { UserDefaults.standard.string(forKey: "tingyu_ai_model") ?? AIProviderPreset.deepseek.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "tingyu_ai_model") }
    }

    public func getApiKey() -> String {
        KeychainService.shared.get(for: "tingyu_ai_api_key") ?? ""
    }

    public func setApiKey(_ key: String) {
        try? KeychainService.shared.save(password: key, for: "tingyu_ai_api_key")
    }

    public func complete(messages: [ChatMessage], temperature: Double = 0.1) async throws -> String {
        var cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanBase.hasSuffix("/") {
            cleanBase = String(cleanBase.dropLast())
        }

        guard let url = URL(string: "\(cleanBase)/chat/completions") else {
            throw NSError(domain: "AIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiKey = getApiKey()
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(model: model, messages: messages, temperature: temperature)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AIService", code: -2, userInfo: [NSLocalizedDescriptionKey: "网络响应异常"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "AIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "AI 服务报错 (\(httpResponse.statusCode)): \(errorText)"])
        }

        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = chatResponse.choices?.first?.message?.content else {
            throw NSError(domain: "AIService", code: -3, userInfo: [NSLocalizedDescriptionKey: "未获取到有效的 AI 回复"])
        }

        return content
    }

    public func testConnection() async throws -> Bool {
        let testMsg = [ChatMessage(role: "user", content: "hi")]
        let res = try await complete(messages: testMsg, temperature: 0.1)
        return !res.isEmpty
    }
}
