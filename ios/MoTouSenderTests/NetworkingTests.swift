import XCTest
@testable import MoTouSender

final class NetworkingTests: XCTestCase {
    private struct PingMessage: Encodable {
        let type = "ping"
    }

    func testHelloNegotiatesCapabilities() throws {
        let json = #"{"type":"hello","device":"rk3576","screen":{"width":1404,"height":1788,"dpi":227,"density":1.5},"grayscale":16,"color":false,"protocol":2,"renderer":["html","bitmap"]}"#

        guard case .hello(let value) = MoTouProtocol.decodeInbound(json) else {
            return XCTFail("hello should decode")
        }
        XCTAssertEqual(value.name, "rk3576")
        XCTAssertEqual(value.screen.width, 1404)
        XCTAssertEqual(value.screen.height, 1788)
        XCTAssertEqual(value.screen.dpi, 227)
        XCTAssertEqual(value.screen.density, 1.5)
        XCTAssertEqual(value.grayscale, 16)
        XCTAssertEqual(value.protocolVersion, 2)
        XCTAssertEqual(value.renderers, ["html", "bitmap"])
    }

    func testPageEventsPreserveTheirMeaning() throws {
        guard case .page(let state) = MoTouProtocol.decodeInbound(
            #"{"type":"state","id":"doc","page":2,"pages":12}"#
        ) else {
            return XCTFail("state should decode")
        }
        XCTAssertEqual(state.kind, .state)
        XCTAssertEqual(state.page, 2)
        XCTAssertEqual(state.pages, 12)

        guard case .page(let rendered) = MoTouProtocol.decodeInbound(
            #"{"type":"rendered","id":"comic","page":5}"#
        ) else {
            return XCTFail("rendered should decode")
        }
        XCTAssertEqual(rendered.kind, .rendered)
        XCTAssertNil(rendered.pages)

        guard case .page(let navigation) = MoTouProtocol.decodeInbound(
            #"{"type":"nav","id":"comic","page":8}"#
        ) else {
            return XCTFail("nav should decode")
        }
        XCTAssertEqual(navigation.kind, .navigationRequest)
        XCTAssertEqual(navigation.page, 8)
    }

    func testAskMessagesDecodeAndUnknownTypesAreIgnored() throws {
        XCTAssertEqual(
            MoTouProtocol.decodeInbound(#"{"type":"chat.ask","text":"继续"}"#),
            .chatAsk("继续")
        )
        XCTAssertEqual(
            MoTouProtocol.decodeInbound(#"{"type":"text.ask","text":"选中文字"}"#),
            .textAsk("选中文字")
        )
        XCTAssertNil(MoTouProtocol.decodeInbound(#"{"type":"future.message","value":1}"#))
        XCTAssertNil(MoTouProtocol.decodeInbound("not json"))
    }

    @MainActor
    func testOutboundMessagesAreGatedUntilHello() async {
        let suiteName = "NetworkingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ConnectionStore(persistence: PersistenceStore(defaults: defaults))

        XCTAssertEqual(store.phase, .disconnected(nil))
        do {
            try await store.sendJSON(PingMessage())
            XCTFail("send should not succeed before hello")
        } catch {
            XCTAssertEqual(error as? ConnectionStoreError, .notReady)
        }
    }
}
