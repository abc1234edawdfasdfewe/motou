import Foundation

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date
}

struct LLMConfiguration: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String

    static let defaults: [LLMConfiguration] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", apiKey: "", model: "deepseek-chat"),
        .init(id: "doubao", name: "豆包（火山方舟）", baseURL: "https://ark.cn-beijing.volces.com/api/v3", apiKey: "", model: ""),
        .init(id: "kimi", name: "Kimi（Moonshot）", baseURL: "https://api.moonshot.cn/v1", apiKey: "", model: "moonshot-v1-8k")
    ]
}

struct TextSelectionRequest: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
}
