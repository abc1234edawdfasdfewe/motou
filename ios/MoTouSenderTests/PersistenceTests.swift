import XCTest
@testable import MoTouSender

final class PersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testDeviceAndHistoryLimitsSurviveReload() {
        var store = PersistenceStore(defaults: defaults)
        for index in 0..<14 {
            store.rememberDevice(
                name: "device-\(index)",
                host: "192.168.1.\(index)",
                port: 8383,
                connectedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            store.addHistory(
                title: "title-\(index)",
                body: "<p>\(index)</p>",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(store.savedDevices.count, 10)
        XCTAssertEqual(store.historyItems.count, 10)
        XCTAssertEqual(store.savedDevices.first?.name, "device-13")
        XCTAssertEqual(store.historyItems.first?.title, "title-13")

        store = PersistenceStore(defaults: defaults)
        XCTAssertEqual(store.savedDevices.count, 10)
        XCTAssertEqual(store.historyItems.count, 10)
        XCTAssertEqual(store.savedDevices.first?.name, "device-13")
    }

    @MainActor
    func testOversizedReflowBodyIsNotPersistedUsingUTF16Limit() {
        let store = PersistenceStore(defaults: defaults)
        let atLimit = String(
            repeating: "😀",
            count: PersistenceStore.maximumHistoryBodyUTF16CodeUnits / 2
        )
        XCTAssertEqual(atLimit.utf16.count, PersistenceStore.maximumHistoryBodyUTF16CodeUnits)

        store.addHistory(title: "at-limit", body: atLimit)
        store.addHistory(title: "too-large", body: atLimit + "x")

        XCTAssertEqual(store.historyItems.map(\.title), ["at-limit"])
        let reloaded = PersistenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.historyItems.map(\.title), ["at-limit"])
    }

    @MainActor
    func testShelfLimitAndProgressClamping() {
        let store = PersistenceStore(defaults: defaults)
        var newestID: UUID?
        for index in 0..<24 {
            let id = UUID()
            newestID = id
            store.upsertBook(
                BookItem(
                    id: id,
                    title: "book-\(index)",
                    format: .pdf,
                    bookmark: Data("bookmark-\(index)".utf8),
                    pageCount: 10,
                    lastPage: 0,
                    openedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        XCTAssertEqual(store.books.count, 20)
        XCTAssertEqual(store.books.first?.id, newestID)
        store.updateBookProgress(id: newestID!, lastPage: 99)
        XCTAssertEqual(store.books.first(where: { $0.id == newestID })?.lastPage, 9)
    }

    @MainActor
    func testChatMessagesArePersisted() {
        let store = PersistenceStore(defaults: defaults)
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            content: "你好",
            createdAt: Date()
        )
        store.appendChatMessage(message)

        let reloaded = PersistenceStore(defaults: defaults)
        XCTAssertEqual(reloaded.chatMessages, [message])
        reloaded.clearChatMessages()
        XCTAssertTrue(reloaded.chatMessages.isEmpty)
    }
}
