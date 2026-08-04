import Foundation
import Observation

@MainActor
protocol ChatDeviceSending: AnyObject {
    func sendJSON(_ payload: [String: Any]) async throws
}

extension ConnectionStore: ChatDeviceSending {}

@MainActor
protocol ChatHistoryPersisting: AnyObject {
    var chatMessages: [ChatMessage] { get }
    func replaceChatMessages(_ messages: [ChatMessage])
    func appendChatMessage(_ message: ChatMessage)
    func clearChatMessages()
}

extension PersistenceStore: ChatHistoryPersisting {}

@MainActor
@Observable
final class ChatStore {
    enum RequestState: Equatable {
        case idle
        case requesting
        case failure(String)
    }

    private(set) var messages: [ChatMessage]
    private(set) var requestState: RequestState = .idle
    private(set) var pendingTextSelection: TextSelectionRequest?
    private(set) var lastDeliveryError: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let persistence: ChatHistoryPersisting
    @ObservationIgnored private let connection: ChatDeviceSending
    @ObservationIgnored private let aiClient: AIChatting

    init(
        settings: SettingsStore,
        persistence: ChatHistoryPersisting,
        connection: ChatDeviceSending,
        aiClient: AIChatting = AIClient()
    ) {
        self.settings = settings
        self.persistence = persistence
        self.connection = connection
        self.aiClient = aiClient
        messages = persistence.chatMessages
    }

    convenience init(
        settings: SettingsStore,
        persistence: PersistenceStore,
        connection: ConnectionStore,
        aiClient: AIChatting = AIClient()
    ) {
        self.init(
            settings: settings,
            persistence: persistence as ChatHistoryPersisting,
            connection: connection as ChatDeviceSending,
            aiClient: aiClient
        )
    }

    var history: [ChatMessage] { messages }
    var isRequesting: Bool { requestState == .requesting }
    var failureMessage: String? {
        guard case let .failure(message) = requestState else { return nil }
        return message
    }

    /// Sends one turn from the phone or from `chat.ask` on the device.
    /// A second request is ignored while the first LLM request is in flight.
    @discardableResult
    func ask(
        _ text: String,
        deliverAssistantAsHTML: Bool = false,
        htmlTitle: String? = nil
    ) async -> ChatMessage? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRequesting else { return nil }
        guard let configuration = settings.activeConfiguration,
              !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            requestState = .failure("未配置模型 API Key")
            return nil
        }

        requestState = .requesting
        let userMessage = ChatMessage(id: UUID(), role: .user, content: prompt, createdAt: Date())
        append(userMessage)
        await syncIgnoringFailure()

        let context = messages.suffix(20).map {
            AIMessage(role: $0.role.rawValue, content: $0.content)
        }
        let requestMessages = [
            AIMessage.system("你是简洁有用的中文助手，回答直接、条理清晰。")
        ] + context

        do {
            let reply = try await aiClient.chat(
                configuration: configuration,
                messages: requestMessages,
                maxTokens: 2_048
            )
            try Task.checkCancellation()
            let assistantMessage = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: reply,
                createdAt: Date()
            )
            append(assistantMessage)
            requestState = .idle
            await syncIgnoringFailure()
            if deliverAssistantAsHTML {
                await deliverHTMLIgnoringFailure(
                    assistantMessage,
                    title: htmlTitle ?? String(prompt.prefix(20))
                )
            }
            return assistantMessage
        } catch is CancellationError {
            requestState = .idle
            await syncIgnoringFailure()
            return nil
        } catch {
            requestState = .failure(error.localizedDescription)
            // The receiver uses a fresh chat payload to leave its "thinking" state.
            await syncIgnoringFailure()
            return nil
        }
    }

    /// Routes the two AI-related websocket events. The caller should pass the
    /// current app-active state when lifecycle state is explicitly managed.
    func handle(_ event: InboundEvent, appIsActive: Bool = true) async {
        switch event {
        case let .chatAsk(text):
            guard appIsActive else {
                requestState = .failure("请保持墨投在前台以继续 AI 对话")
                await syncIgnoringFailure()
                return
            }
            if await ask(text) == nil {
                // The receiver enters its thinking state before emitting chat.ask.
                // Always send a chat payload back so missing settings/busy state
                // cannot leave that spinner stuck indefinitely.
                await syncIgnoringFailure()
            }

        case let .textAsk(text):
            guard appIsActive else {
                requestState = .failure("请打开墨投后再使用“问 AI”")
                return
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                pendingTextSelection = TextSelectionRequest(text: clean)
            }

        default:
            break
        }
    }

    /// Completes a `text.ask` request after the user enters the actual question.
    /// The assistant reply is also sent once through the normal HTML reading lane.
    @discardableResult
    func askAboutPendingSelection(prompt: String) async -> ChatMessage? {
        guard let selection = pendingTextSelection else { return nil }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return nil }

        let quote = selection.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let reply = await ask(
            "\(cleanPrompt)\n\n\(quote)",
            deliverAssistantAsHTML: true,
            htmlTitle: String(cleanPrompt.prefix(20))
        )
        if reply != nil, pendingTextSelection?.id == selection.id {
            pendingTextSelection = nil
        }
        return reply
    }

    func dismissPendingTextSelection() {
        pendingTextSelection = nil
    }

    func clear() async {
        guard !isRequesting else { return }
        messages.removeAll()
        persistence.clearChatMessages()
        requestState = .idle
        pendingTextSelection = nil
        await syncIgnoringFailure()
    }

    func clearFailure() {
        if case .failure = requestState {
            requestState = .idle
        }
        lastDeliveryError = nil
    }

    /// Replaces the receiver's chat screen with the complete local conversation.
    func syncToDevice() async throws {
        let payloadMessages: [[String: Any]] = messages.map {
            [
                "role": $0.role.rawValue,
                "html": MarkdownHTMLRenderer.render($0.content)
            ]
        }
        try await connection.sendJSON([
            "type": "chat",
            "msgs": payloadMessages
        ])
        lastDeliveryError = nil
    }

    func deliverLastAssistantAsHTML(title: String = "AI 回答") async throws {
        guard let message = messages.last(where: { $0.role == .assistant }) else { return }
        try await deliverAsHTML(message, title: title)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        persistence.appendChatMessage(message)
    }

    private func deliverAsHTML(_ message: ChatMessage, title: String) async throws {
        try await connection.sendJSON([
            "type": "html",
            "id": "ai-\(UUID().uuidString.lowercased())",
            "title": title.isEmpty ? "AI 回答" : title,
            "body": MarkdownHTMLRenderer.render(message.content)
        ])
        lastDeliveryError = nil
    }

    private func syncIgnoringFailure() async {
        do {
            try await syncToDevice()
        } catch {
            lastDeliveryError = error.localizedDescription
        }
    }

    private func deliverHTMLIgnoringFailure(_ message: ChatMessage, title: String) async {
        do {
            try await deliverAsHTML(message, title: title)
        } catch {
            lastDeliveryError = error.localizedDescription
        }
    }
}
