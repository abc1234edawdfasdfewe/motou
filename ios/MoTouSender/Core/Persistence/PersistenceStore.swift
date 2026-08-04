import Foundation
import Observation

/// Small, synchronous persistence layer for the app's local, user-visible state.
///
/// `UserDefaults` is intentional here: every collection is bounded and consists of
/// compact metadata. File contents and secrets are stored elsewhere.
@MainActor
@Observable
final class PersistenceStore {
    static let maximumSavedDevices = 10
    static let maximumHistoryItems = 10
    static let maximumBooks = 20

    private(set) var savedDevices: [SavedDevice]
    private(set) var historyItems: [HistoryItem]
    private(set) var books: [BookItem]
    private(set) var chatMessages: [ChatMessage]

    /// Compatibility aliases used by simple SwiftUI list views.
    var devices: [SavedDevice] { savedDevices }
    var history: [HistoryItem] { historyItems }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    private enum Key {
        static let devices = "motou.persistence.devices.v1"
        static let history = "motou.persistence.history.v1"
        static let books = "motou.persistence.books.v1"
        static let chat = "motou.persistence.chat.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder()
        decoder = JSONDecoder()

        savedDevices = Self.decode([SavedDevice].self, key: Key.devices, defaults: defaults, decoder: decoder)
            .sorted { $0.lastConnectedAt > $1.lastConnectedAt }
            .uniqued(by: \SavedDevice.id)
            .prefix(Self.maximumSavedDevices)
            .map { $0 }
        historyItems = Array(
            Self.decode([HistoryItem].self, key: Key.history, defaults: defaults, decoder: decoder)
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(Self.maximumHistoryItems)
        )
        let decodedBooks = Self.decode([BookItem].self, key: Key.books, defaults: defaults, decoder: decoder)
            .sorted { $0.openedAt > $1.openedAt }
            .uniqued(by: \BookItem.id)
        books = decodedBooks
            .prefix(Self.maximumBooks)
            .map { $0 }
        chatMessages = Self.decode([ChatMessage].self, key: Key.chat, defaults: defaults, decoder: decoder)
        Self.removeManagedFiles(from: decodedBooks, keeping: books)

        // Repair oversized or duplicated values written by an older app version.
        persist(savedDevices, forKey: Key.devices)
        persist(historyItems, forKey: Key.history)
        persist(books, forKey: Key.books)
    }

    // MARK: - Devices

    func rememberDevice(_ device: SavedDevice) {
        var updated = savedDevices.filter { $0.id != device.id }
        updated.insert(device, at: 0)
        savedDevices = Array(
            updated
                .sorted { $0.lastConnectedAt > $1.lastConnectedAt }
                .prefix(Self.maximumSavedDevices)
        )
        persist(savedDevices, forKey: Key.devices)
    }

    func rememberDevice(name: String, host: String, port: Int, connectedAt: Date = Date()) {
        rememberDevice(
            SavedDevice(
                name: name,
                host: host,
                port: port,
                lastConnectedAt: connectedAt
            )
        )
    }

    func removeDevice(id: SavedDevice.ID) {
        savedDevices.removeAll { $0.id == id }
        persist(savedDevices, forKey: Key.devices)
    }

    func clearDevices() {
        savedDevices.removeAll()
        persist(savedDevices, forKey: Key.devices)
    }

    // MARK: - HTML history

    func addHistory(_ item: HistoryItem) {
        var updated = historyItems.filter { $0.id != item.id }
        updated.insert(item, at: 0)
        historyItems = Array(
            updated
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(Self.maximumHistoryItems)
        )
        persist(historyItems, forKey: Key.history)
    }

    @discardableResult
    func addHistory(title: String, body: String, createdAt: Date = Date()) -> HistoryItem {
        let item = HistoryItem(id: UUID(), title: title, body: body, createdAt: createdAt)
        addHistory(item)
        return item
    }

    func removeHistory(id: HistoryItem.ID) {
        historyItems.removeAll { $0.id == id }
        persist(historyItems, forKey: Key.history)
    }

    func clearHistory() {
        historyItems.removeAll()
        persist(historyItems, forKey: Key.history)
    }

    // MARK: - Books

    func upsertBook(_ item: BookItem) {
        // Recreating a bookmark for the same file should update its existing row and
        // keep progress, rather than consuming a second shelf slot.
        let existing = books.first { $0.id == item.id || $0.bookmark == item.bookmark }
        var value = item
        if let existing, item.lastPage == 0, existing.lastPage > 0 {
            value.lastPage = existing.lastPage
        }

        let previousBooks = books
        var updated = books.filter { candidate in
            candidate.id != existing?.id && candidate.id != item.id && candidate.bookmark != item.bookmark
        }
        updated.insert(value, at: 0)
        books = Array(
            updated
                .sorted { $0.openedAt > $1.openedAt }
                .prefix(Self.maximumBooks)
        )
        Self.removeManagedFiles(from: previousBooks, keeping: books)
        persist(books, forKey: Key.books)
    }

    /// Alias matching the language used by feature coordinators.
    func registerBook(_ item: BookItem) {
        upsertBook(item)
    }

    func updateBookProgress(id: BookItem.ID, lastPage: Int, openedAt: Date = Date()) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let upperBound = max(0, books[index].pageCount - 1)
        books[index].lastPage = min(max(0, lastPage), upperBound)
        books[index].openedAt = openedAt
        books.sort { $0.openedAt > $1.openedAt }
        persist(books, forKey: Key.books)
    }

    func removeBook(id: BookItem.ID) {
        let removed = books.filter { $0.id == id }
        books.removeAll { $0.id == id }
        Self.removeManagedFiles(from: removed, keeping: books)
        persist(books, forKey: Key.books)
    }

    func clearBooks() {
        let removed = books
        books.removeAll()
        Self.removeManagedFiles(from: removed, keeping: books)
        persist(books, forKey: Key.books)
    }

    // MARK: - Chat

    func replaceChatMessages(_ messages: [ChatMessage]) {
        chatMessages = messages
        persist(chatMessages, forKey: Key.chat)
    }

    func appendChatMessage(_ message: ChatMessage) {
        chatMessages.append(message)
        persist(chatMessages, forKey: Key.chat)
    }

    func clearChatMessages() {
        chatMessages.removeAll()
        persist(chatMessages, forKey: Key.chat)
    }

    // MARK: - Coding

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        defaults: UserDefaults,
        decoder: JSONDecoder
    ) -> Value where Value: ExpressibleByArrayLiteral {
        guard let data = defaults.data(forKey: key),
              let value = try? decoder.decode(type, from: data) else {
            return []
        }
        return value
    }

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func removeManagedFiles(from candidates: [BookItem], keeping retained: [BookItem]) {
        let retainedNames = Set(retained.compactMap(\.managedFileName))
        for fileName in candidates.compactMap(\.managedFileName) where !retainedNames.contains(fileName) {
            ManagedImportStore.remove(fileNamed: fileName)
        }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
