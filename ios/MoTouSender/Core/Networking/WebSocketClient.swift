import Foundation

enum WebSocketClientError: LocalizedError, Equatable {
    case notConnected
    case connectionClosed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接墨投设备"
        case .connectionClosed(let reason):
            return reason
        }
    }
}

/// A thin URLSessionWebSocketTask wrapper with one ordered application-frame lane.
///
/// Every outbound call joins the same task chain. A bitmap page is represented by
/// a two-frame batch, so no JSON or data message from another caller can be placed
/// between its `page` metadata and binary body.
actor WebSocketClient {
    enum Event: Sendable, Equatable {
        case opened
        case text(String)
        case data(Data)
        case closed(String)
    }

    private let configuration: URLSessionConfiguration
    private let pingIntervalNanoseconds: UInt64

    private var session: URLSession?
    private var sessionDelegate: SessionDelegate?
    private var task: URLSessionWebSocketTask?
    private var connectionID: UUID?
    private var continuation: AsyncStream<Event>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var sendTail: Task<Void, Swift.Error>?

    init(configuration: URLSessionConfiguration = .default, pingInterval: TimeInterval = 15) {
        let copied = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        copied.waitsForConnectivity = true
        self.configuration = copied
        pingIntervalNanoseconds = UInt64(max(1, pingInterval) * 1_000_000_000)
    }

    /// Starts a new connection and returns its event stream. Starting a connection
    /// always retires any previous socket owned by this client.
    func connect(to url: URL) -> AsyncStream<Event> {
        closeCurrentSocket()

        let id = UUID()
        var streamContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event> { value in
            streamContinuation = value
        }
        guard let streamContinuation else { return stream }

        let delegate = SessionDelegate()
        delegate.onOpen = { [weak self] in
            Task { await self?.socketDidOpen(id: id) }
        }
        delegate.onClose = { [weak self] code, reason in
            Task {
                await self?.terminate(
                    id: id,
                    reason: Self.closeDescription(code: code, reason: reason)
                )
            }
        }

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)

        connectionID = id
        continuation = streamContinuation
        sessionDelegate = delegate
        self.session = session
        self.task = task
        task.resume()

        receiveTask = Task { [weak self, weak task] in
            guard let task else { return }
            await self?.receiveMessages(from: task, id: id)
        }
        return stream
    }

    func send(text: String) async throws {
        try await sendBatch([.string(text)])
    }

    func send(data: Data) async throws {
        try await sendBatch([.data(data)])
    }

    func sendBitmapPage(metadata: String, binary: Data) async throws {
        try await sendBatch([.string(metadata), .data(binary)])
    }

    func disconnect() {
        closeCurrentSocket()
    }

    // MARK: - Ordered sends

    private func sendBatch(_ messages: [URLSessionWebSocketTask.Message]) async throws {
        guard let socket = task, let id = connectionID else {
            throw WebSocketClientError.notConnected
        }

        let predecessor = sendTail
        let operation = Task<Void, Swift.Error> {
            if let predecessor {
                // Its error has already been delivered to its caller. Waiting still
                // preserves ordering; a subsequent send gets its own socket result.
                _ = try? await predecessor.value
            }
            try Task.checkCancellation()
            for message in messages {
                try await socket.send(message)
            }
        }
        sendTail = operation

        do {
            try await operation.value
        } catch {
            terminate(id: id, reason: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Receive and liveness

    private func socketDidOpen(id: UUID) {
        guard connectionID == id else { return }
        continuation?.yield(.opened)
        startPingLoop(id: id)
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask, id: UUID) async {
        do {
            while !Task.isCancelled, connectionID == id {
                switch try await socket.receive() {
                case .string(let text):
                    continuation?.yield(.text(text))
                case .data(let data):
                    continuation?.yield(.data(data))
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            terminate(id: id, reason: error.localizedDescription)
        }
    }

    private func startPingLoop(id: UUID) {
        pingTask?.cancel()
        let interval = pingIntervalNanoseconds
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                    guard let self else { return }
                    try await self.sendPing(id: id)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else { return }
                    await self.terminate(id: id, reason: "心跳失败：\(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func sendPing(id: UUID) async throws {
        guard connectionID == id, let task else {
            throw WebSocketClientError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func terminate(id: UUID, reason: String) {
        guard connectionID == id else { return }
        let eventContinuation = continuation

        connectionID = nil
        continuation = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil

        eventContinuation?.yield(.closed(reason.isEmpty ? "连接已断开" : reason))
        eventContinuation?.finish()
    }

    private func closeCurrentSocket() {
        connectionID = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        continuation?.finish()
        continuation = nil
    }

    private static func closeDescription(
        code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) -> String {
        if let reason, let text = String(data: reason, encoding: .utf8), !text.isEmpty {
            return text
        }
        if code == .normalClosure { return "连接已关闭" }
        return "连接已断开（\(code.rawValue)）"
    }
}

private final class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }
}
