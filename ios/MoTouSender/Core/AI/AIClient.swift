import Foundation

struct AIMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String

    static func system(_ content: String) -> Self {
        .init(role: "system", content: content)
    }

    static func user(_ content: String) -> Self {
        .init(role: "user", content: content)
    }
}

struct AIConnectionTest: Equatable, Sendable {
    var models: [String]
    var usedChatFallback: Bool
}

protocol AIChatting: Sendable {
    func chat(
        configuration: LLMConfiguration,
        messages: [AIMessage],
        maxTokens: Int
    ) async throws -> String
}

enum AIClientError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case missingAPIKey
    case missingModel
    case invalidResponse
    case http(status: Int, message: String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "接口地址无效"
        case .missingAPIKey:
            "API Key 为空"
        case .missingModel:
            "模型名未填写"
        case .invalidResponse:
            "服务返回了无法解析的数据"
        case let .http(status, message):
            message.isEmpty ? "请求失败（HTTP \(status)）" : "\(message)（HTTP \(status)）"
        case .emptyReply:
            "模型返回了空内容"
        }
    }
}

/// OpenAI-compatible client used by DeepSeek, Volcengine Ark and Moonshot.
///
/// API keys are accepted only in memory and are never logged or persisted here.
struct AIClient: Sendable {
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [AIMessage]
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String?
        }

        let error: APIError?
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Appends `/v1` only when the supplied base URL does not already contain
    /// a version path component. This preserves provider roots such as `/api/v3`.
    static func endpoint(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else {
            throw AIClientError.invalidBaseURL
        }

        var baseParts = components.path.split(separator: "/").map(String.init)
        let hasVersionComponent = baseParts.contains { part in
            guard part.first?.lowercased() == "v" else { return false }
            return !part.dropFirst().isEmpty && part.dropFirst().allSatisfy(\.isNumber)
        }
        if !hasVersionComponent {
            baseParts.append("v1")
        }
        baseParts.append(contentsOf: path.split(separator: "/").map(String.init))
        components.path = "/" + baseParts.joined(separator: "/")

        guard let url = components.url else {
            throw AIClientError.invalidBaseURL
        }
        return url
    }

    func listModels(for configuration: LLMConfiguration) async throws -> [String] {
        let apiKey = try validatedAPIKey(configuration.apiKey)
        var request = URLRequest(
            url: try Self.endpoint(baseURL: configuration.baseURL, path: "models"),
            timeoutInterval: 20
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await responseData(for: request)
        guard let response = try? decoder.decode(ModelsResponse.self, from: data) else {
            throw AIClientError.invalidResponse
        }
        return response.data.map(\.id).filter { !$0.isEmpty }
    }

    /// Tests `/models` first. Providers that intentionally omit that endpoint
    /// are tested with a one-token chat completion instead.
    func testConnection(for configuration: LLMConfiguration) async throws -> AIConnectionTest {
        _ = try Self.endpoint(baseURL: configuration.baseURL, path: "models")
        _ = try validatedAPIKey(configuration.apiKey)

        do {
            let models = try await listModels(for: configuration)
            return .init(models: models, usedChatFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw error
            }
            _ = try await chat(
                configuration: configuration,
                messages: [.user("hi")],
                maxTokens: 1
            )
            return .init(models: [], usedChatFallback: true)
        }
    }

    func chat(
        configuration: LLMConfiguration,
        messages: [AIMessage],
        maxTokens: Int = 2_048
    ) async throws -> String {
        let apiKey = try validatedAPIKey(configuration.apiKey)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIClientError.missingModel
        }

        var request = URLRequest(
            url: try Self.endpoint(baseURL: configuration.baseURL, path: "chat/completions"),
            timeoutInterval: 60
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(ChatRequest(
            model: model,
            messages: messages,
            maxTokens: max(1, maxTokens),
            stream: false
        ))

        let data = try await responseData(for: request)
        guard let response = try? decoder.decode(ChatResponse.self, from: data) else {
            throw AIClientError.invalidResponse
        }
        guard let reply = response.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty
        else {
            throw AIClientError.emptyReply
        }
        return reply
    }

    private func validatedAPIKey(_ value: String) throws -> String {
        let apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        return apiKey
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let apiMessage = (try? decoder.decode(ErrorEnvelope.self, from: data))?
                .error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIClientError.http(status: http.statusCode, message: apiMessage ?? fallback ?? "")
        }
        return data
    }
}

extension AIClient: AIChatting {}
