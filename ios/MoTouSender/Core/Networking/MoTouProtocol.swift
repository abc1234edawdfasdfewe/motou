import Foundation

/// Observation-friendly event wrapper. `token` changes for every frame, including
/// two identical consecutive `chat.ask` or navigation messages.
struct InboundEventEnvelope: Identifiable, Equatable, Sendable {
    let token: UInt64
    let event: InboundEvent

    var id: UInt64 { token }
}

enum MoTouProtocol {
    /// Decodes one websocket text frame. Unknown message types and malformed JSON
    /// are deliberately ignored for protocol forward compatibility.
    static func decodeInbound(_ text: String) -> InboundEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any],
              let type = message["type"] as? String else {
            return nil
        }

        switch type {
        case "hello":
            let fallback = DeviceCapabilities.fallback
            let screenMessage = message["screen"] as? [String: Any] ?? [:]
            let width = positiveInt(screenMessage["width"]) ?? fallback.screen.width
            let height = positiveInt(screenMessage["height"]) ?? fallback.screen.height
            let screen = DeviceCapabilities.Screen(
                width: width,
                height: height,
                dpi: double(screenMessage["dpi"]),
                density: double(screenMessage["density"])
            )
            let renderers = stringArray(message["renderer"])
                ?? stringArray(message["renderers"])
                ?? fallback.renderers
            let grayscale = min(max(int(message["grayscale"]) ?? fallback.grayscale, 2), 256)
            let capabilities = DeviceCapabilities(
                name: nonemptyString(message["device"]) ?? fallback.name,
                screen: screen,
                grayscale: grayscale,
                color: bool(message["color"]) ?? fallback.color,
                protocolVersion: max(1, int(message["protocol"]) ?? fallback.protocolVersion),
                renderers: renderers
            )
            return .hello(capabilities)

        case "state":
            guard let page = int(message["page"]) else { return nil }
            return .page(
                PageState(
                    contentID: string(message["id"]) ?? "",
                    page: max(0, page),
                    pages: int(message["pages"]).map { max(1, $0) },
                    kind: .state
                )
            )

        case "rendered":
            guard let page = int(message["page"]) else { return nil }
            return .page(
                PageState(
                    contentID: string(message["id"]) ?? "",
                    page: max(0, page),
                    pages: int(message["pages"]).map { max(1, $0) },
                    kind: .rendered
                )
            )

        case "nav":
            guard let page = int(message["page"]) else { return nil }
            return .page(
                PageState(
                    contentID: string(message["id"]) ?? "",
                    page: max(0, page),
                    pages: int(message["pages"]).map { max(1, $0) },
                    kind: .navigationRequest
                )
            )

        case "chat.ask":
            return .chatAsk(string(message["text"]) ?? "")

        case "text.ask":
            return .textAsk(string(message["text"]) ?? "")

        case "touch":
            return .touch

        default:
            return nil
        }
    }

    static func decodeInbound(_ data: Data) -> InboundEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return decodeInbound(text)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? String }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let value = int(value), value > 0 else { return nil }
        return value
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
