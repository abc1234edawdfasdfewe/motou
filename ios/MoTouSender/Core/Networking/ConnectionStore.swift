import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

enum ConnectionStoreError: LocalizedError, Equatable {
    case invalidAddress
    case notReady
    case invalidJSONObject

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "设备地址无效"
        case .notReady:
            return "设备尚未完成 hello 握手"
        case .invalidJSONObject:
            return "待发送内容不是有效的 JSON 对象"
        }
    }
}

@MainActor
@Observable
final class ConnectionStore {
    private(set) var phase: ConnectionPhase = .disconnected(nil)
    private(set) var capabilities: DeviceCapabilities?
    private(set) var pageState: PageState?
    private(set) var lastEvent: InboundEventEnvelope?
    private(set) var connectedDevice: SavedDevice?
    private(set) var currentHost: String?
    private(set) var currentPort: Int?
    private(set) var isApplicationActive = true
    @ObservationIgnored let inboundEvents: AsyncStream<InboundEventEnvelope>

    /// Unexpected disconnects reconnect while the app is in the foreground.
    var autoReconnect = true

    var isReady: Bool { phase == .ready }
    var connectionState: ConnectionPhase { phase }

    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored private let client: WebSocketClient
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private var desiredTarget: Target?
    @ObservationIgnored private var activeAttempt: UUID?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var helloTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var eventToken: UInt64 = 0
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private let inboundEventContinuation: AsyncStream<InboundEventEnvelope>.Continuation

    convenience init() {
        self.init(persistence: PersistenceStore())
    }

    init(persistence: PersistenceStore, client: WebSocketClient = WebSocketClient()) {
        let eventChannel = AsyncStream<InboundEventEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        inboundEvents = eventChannel.stream
        inboundEventContinuation = eventChannel.continuation
        self.persistence = persistence
        self.client = client
        installLifecycleObservers()
    }

    deinit {
        connectionTask?.cancel()
        helloTimeoutTask?.cancel()
        reconnectTask?.cancel()
        inboundEventContinuation.finish()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        let client = client
        Task { await client.disconnect() }
    }

    // MARK: - Connection lifecycle

    func connect(host: String, port: Int = 8383) {
        guard let target = Target(address: host, defaultPort: port) else {
            disconnect()
            phase = .disconnected(ConnectionStoreError.invalidAddress.localizedDescription)
            return
        }
        connect(to: target)
    }

    /// Accepts a QR/manual address such as `192.168.1.20`, `host:8383`, or
    /// `http://192.168.1.20:8383/`.
    @discardableResult
    func connect(address: String, defaultPort: Int = 8383) -> Bool {
        guard let target = Target(address: address, defaultPort: defaultPort) else {
            disconnect()
            phase = .disconnected(ConnectionStoreError.invalidAddress.localizedDescription)
            return false
        }
        connect(to: target)
        return true
    }

    func connect(to device: SavedDevice) {
        connect(host: device.host, port: device.port)
    }

    func reconnect() {
        if let desiredTarget {
            connect(to: desiredTarget)
        } else if let last = persistence.savedDevices.first,
                  let target = Target(address: last.host, defaultPort: last.port) {
            connect(to: target)
        }
    }

    /// A manual disconnect clears the reconnect target. Background suspension does
    /// not, which is what enables foreground reconnection.
    func disconnect() {
        desiredTarget = nil
        activeAttempt = nil
        reconnectAttempt = 0
        currentHost = nil
        currentPort = nil
        cancelConnectionTasks()
        clearConnectedState(reason: nil)
        Task { await client.disconnect() }
    }

    func applicationDidEnterBackground() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        activeAttempt = nil
        cancelConnectionTasks()
        if desiredTarget != nil {
            clearConnectedState(reason: "应用进入后台，连接已暂停")
        }
        Task { await client.disconnect() }
    }

    func applicationDidBecomeActive() {
        let wasInactive = !isApplicationActive
        isApplicationActive = true
        guard wasInactive,
              desiredTarget != nil,
              !isReady,
              activeAttempt == nil else { return }
        reconnectAttempt = 0
        reconnect()
    }

    // MARK: - Sending

    func sendJSON<Payload: Encodable>(_ payload: Payload) async throws {
        try requireReady()
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        try await client.send(text: text)
    }

    /// Convenience overload for dynamic JSON assembled by chat/UI coordinators.
    func sendJSON(_ payload: [String: Any]) async throws {
        try requireReady()
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        try await client.send(text: text)
    }

    func sendData(_ data: Data) async throws {
        try requireReady()
        try await client.send(data: data)
    }

    func sendBitmapPage<Metadata: Encodable>(
        metadata: Metadata,
        binary: Data
    ) async throws {
        try requireReady()
        let data = try encoder.encode(metadata)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        try await client.sendBitmapPage(metadata: text, binary: binary)
    }

    func sendBitmapPage(metadata: [String: Any], binary: Data) async throws {
        try requireReady()
        guard JSONSerialization.isValidJSONObject(metadata) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        let data = try JSONSerialization.data(withJSONObject: metadata)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionStoreError.invalidJSONObject
        }
        try await client.sendBitmapPage(metadata: text, binary: binary)
    }

    // MARK: - Internals

    private func connect(to target: Target) {
        desiredTarget = target
        reconnectTask?.cancel()
        reconnectTask = nil
        beginConnection(to: target)
    }

    private func beginConnection(to target: Target) {
        guard isApplicationActive else {
            clearConnectedState(reason: "等待应用回到前台")
            return
        }

        connectionTask?.cancel()
        helloTimeoutTask?.cancel()
        let attempt = UUID()
        activeAttempt = attempt
        currentHost = target.host
        currentPort = target.port
        capabilities = nil
        connectedDevice = nil
        pageState = nil
        phase = .connecting

        helloTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.activeAttempt == attempt,
                  self.phase != .ready else { return }
            self.handleClosed(reason: "连接超时：未收到设备 hello", attempt: attempt)
            await self.client.disconnect()
        }

        connectionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.activeAttempt == attempt else { return }
            let stream = await self.client.connect(to: target.url)
            guard self.activeAttempt == attempt else { return }

            for await event in stream {
                guard !Task.isCancelled, self.activeAttempt == attempt else { return }
                self.handle(event, target: target, attempt: attempt)
            }

            guard !Task.isCancelled, self.activeAttempt == attempt else { return }
            self.handleClosed(reason: "连接已断开", attempt: attempt)
        }
    }

    private func handle(_ event: WebSocketClient.Event, target: Target, attempt: UUID) {
        guard activeAttempt == attempt else { return }
        switch event {
        case .opened:
            if phase != .ready { phase = .awaitingHello }

        case .text(let text):
            guard let event = MoTouProtocol.decodeInbound(text) else { return }
            handleInbound(event, target: target, attempt: attempt)

        case .data:
            // The current protocol has no device-to-sender binary message.
            break

        case .closed(let reason):
            handleClosed(reason: reason, attempt: attempt)
        }
    }

    private func handleInbound(_ event: InboundEvent, target: Target, attempt: UUID) {
        guard activeAttempt == attempt else { return }

        if case .hello(let value) = event {
            capabilities = value
            phase = .ready
            helloTimeoutTask?.cancel()
            helloTimeoutTask = nil
            reconnectAttempt = 0

            let device = SavedDevice(
                name: value.name,
                host: target.host,
                port: target.port,
                lastConnectedAt: Date()
            )
            connectedDevice = device
            persistence.rememberDevice(device)
            publish(event)
            return
        }

        // The server sends hello first. Ignoring pre-handshake frames keeps ready
        // semantically tied to negotiated screen and grayscale capabilities.
        guard phase == .ready else { return }
        if case .page(let value) = event {
            pageState = value
        }
        publish(event)
    }

    private func publish(_ event: InboundEvent) {
        eventToken &+= 1
        let envelope = InboundEventEnvelope(token: eventToken, event: event)
        lastEvent = envelope
        inboundEventContinuation.yield(envelope)
    }

    private func handleClosed(reason: String, attempt: UUID) {
        guard activeAttempt == attempt else { return }
        activeAttempt = nil
        connectionTask = nil
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        clearConnectedState(reason: reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard autoReconnect, isApplicationActive, let target = desiredTarget else { return }
        reconnectTask?.cancel()
        let delay = min(15, 2 << min(reconnectAttempt, 3))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.autoReconnect,
                  self.isApplicationActive,
                  self.desiredTarget == target,
                  self.activeAttempt == nil else { return }
            self.beginConnection(to: target)
        }
    }

    private func clearConnectedState(reason: String?) {
        capabilities = nil
        pageState = nil
        connectedDevice = nil
        phase = .disconnected(reason)
    }

    private func cancelConnectionTasks() {
        connectionTask?.cancel()
        connectionTask = nil
        helloTimeoutTask?.cancel()
        helloTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func requireReady() throws {
        guard phase == .ready else { throw ConnectionStoreError.notReady }
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        isApplicationActive = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applicationDidEnterBackground() }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applicationDidBecomeActive() }
            }
        )
        #endif
    }
}

private struct Target: Equatable, Sendable {
    let host: String
    let port: Int

    var url: URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/channel"
        // Construction has already been validated by init.
        return components.url!
    }

    init?(address rawAddress: String, defaultPort: Int) {
        guard (1...65_535).contains(defaultPort) else { return nil }
        let value = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let parsed: URLComponents?
        if value.contains("://") {
            parsed = URLComponents(string: value)
        } else {
            parsed = URLComponents(string: "//\(value)")
        }

        guard var host = parsed?.host, !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let port = parsed?.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }

        var validation = URLComponents()
        validation.scheme = "ws"
        validation.host = host
        validation.port = port
        validation.path = "/channel"
        guard validation.url != nil else { return nil }

        self.host = host
        self.port = port
    }
}
