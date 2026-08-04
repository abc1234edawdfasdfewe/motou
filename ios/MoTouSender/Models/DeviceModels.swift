import Foundation

struct DeviceCapabilities: Codable, Equatable, Sendable {
    struct Screen: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var dpi: Double?
        var density: Double?
    }

    var name: String
    var screen: Screen
    var grayscale: Int
    var color: Bool
    var protocolVersion: Int
    var renderers: [String]

    static let fallback = DeviceCapabilities(
        name: "墨投设备",
        screen: .init(width: 1404, height: 1872, dpi: nil, density: nil),
        grayscale: 16,
        color: false,
        protocolVersion: 2,
        renderers: ["html", "bitmap"]
    )
}

struct SavedDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(host):\(port)" }
    var name: String
    var host: String
    var port: Int
    var lastConnectedAt: Date
}

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: Int
}

enum ConnectionPhase: Equatable, Sendable {
    case disconnected(String?)
    case connecting
    case awaitingHello
    case ready
}

struct PageState: Equatable, Sendable {
    var contentID: String
    var page: Int
    var pages: Int?
    var kind: Kind

    enum Kind: Equatable, Sendable {
        case state
        case rendered
        case navigationRequest
    }
}

enum InboundEvent: Equatable, Sendable {
    case hello(DeviceCapabilities)
    case page(PageState)
    case chatAsk(String)
    case textAsk(String)
    case touch
}
