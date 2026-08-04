import XCTest
@testable import MoTouSender

final class ChatStoreTests: XCTestCase {
    func testMarkdownEscapesRawHTMLAndKeepsWhitelistedFormatting() {
        let html = MarkdownHTMLRenderer.render("# 标题\n\n<script>x</script> **加粗** `a<b`")

        XCTAssertTrue(html.contains("<h1>标题</h1>"))
        XCTAssertTrue(html.contains("&lt;script&gt;x&lt;/script&gt;"))
        XCTAssertTrue(html.contains("<strong>加粗</strong>"))
        XCTAssertTrue(html.contains("<code>a&lt;b</code>"))
        XCTAssertFalse(html.contains("<script>"))
    }

    @MainActor
    func testAskPersistsHistoryUsesLastTwentyAndSyncsWholeChat() async throws {
        let suiteName = "ChatStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = MemorySecrets()
        let settings = SettingsStore(defaults: defaults, secrets: secrets)
        try settings.setAPIKey("test-key", for: "deepseek")

        let oldMessages = (0 ..< 25).map {
            ChatMessage(id: UUID(), role: .user, content: "old-\($0)", createdAt: Date())
        }
        let persistence = MemoryChatPersistence(messages: oldMessages)
        let connection = MemoryChatConnection()
        let ai = AIChatStub(reply: "**完成**")
        let store = ChatStore(
            settings: settings,
            persistence: persistence,
            connection: connection,
            aiClient: ai
        )

        let reply = await store.ask("new-question")

        XCTAssertEqual(reply?.content, "**完成**")
        XCTAssertEqual(store.requestState, .idle)
        XCTAssertEqual(store.messages.count, 27)
        XCTAssertEqual(persistence.chatMessages.count, 27)
        let requestMessages = await ai.receivedMessages
        XCTAssertEqual(requestMessages.count, 21) // system + the latest 20 history messages
        XCTAssertEqual(requestMessages.first?.role, "system")
        XCTAssertEqual(requestMessages.last?.content, "new-question")
        XCTAssertEqual(connection.payloads.count, 2)
        let finalMessages = try XCTUnwrap(connection.payloads.last?["msgs"] as? [[String: Any]])
        XCTAssertEqual(finalMessages.count, 27)
        XCTAssertEqual(finalMessages.last?["html"] as? String, "<p><strong>完成</strong></p>")
    }

    @MainActor
    func testDeviceAskWithoutAPIKeyStillAcknowledgesReceiver() async throws {
        let suiteName = "ChatStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, secrets: MemorySecrets())
        let persistence = MemoryChatPersistence(messages: [])
        let connection = MemoryChatConnection()
        let store = ChatStore(
            settings: settings,
            persistence: persistence,
            connection: connection,
            aiClient: AIChatStub(reply: "unused")
        )

        await store.handle(.chatAsk("继续"), appIsActive: true)

        XCTAssertEqual(store.requestState, .failure("未配置模型 API Key"))
        XCTAssertEqual(connection.payloads.count, 1)
        XCTAssertEqual(connection.payloads[0]["type"] as? String, "chat")
        XCTAssertEqual((connection.payloads[0]["msgs"] as? [[String: Any]])?.count, 0)
    }
}

private final class MemorySecrets: SettingsSecretStoring {
    var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }
    func set(_ value: String?, for key: String) throws { values[key] = value }
}

@MainActor
private final class MemoryChatPersistence: ChatHistoryPersisting {
    private(set) var chatMessages: [ChatMessage]

    init(messages: [ChatMessage]) {
        chatMessages = messages
    }

    func replaceChatMessages(_ messages: [ChatMessage]) { chatMessages = messages }
    func appendChatMessage(_ message: ChatMessage) { chatMessages.append(message) }
    func clearChatMessages() { chatMessages.removeAll() }
}

@MainActor
private final class MemoryChatConnection: ChatDeviceSending {
    private(set) var payloads: [[String: Any]] = []

    func sendJSON(_ payload: [String: Any]) async throws {
        payloads.append(payload)
    }
}

private actor AIChatStub: AIChatting {
    let reply: String
    private(set) var receivedMessages: [AIMessage] = []

    init(reply: String) {
        self.reply = reply
    }

    func chat(
        configuration: LLMConfiguration,
        messages: [AIMessage],
        maxTokens: Int
    ) async throws -> String {
        receivedMessages = messages
        return reply
    }
}
