import Foundation

struct SharedInboxItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case url
        case file
    }

    var id: UUID
    var kind: Kind
    var text: String?
    var fileName: String?
    var storedFileName: String?
    var createdAt: Date
}

enum SharedInbox {
    static let appGroupID = "group.com.motou.sender"

    private static let pendingKey = "motou.share.pending.v1"
    private static let folderName = "ShareInbox"

    enum InboxError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "App Group 尚未配置，请在签名能力中启用 \(appGroupID)"
            }
        }
    }

    static func enqueue(text: String, kind: SharedInboxItem.Kind) throws {
        let item = SharedInboxItem(
            id: UUID(),
            kind: kind,
            text: text,
            fileName: nil,
            storedFileName: nil,
            createdAt: Date()
        )
        try append(item)
    }

    static func enqueue(fileAt sourceURL: URL, preferredName: String? = nil) throws {
        let folder = try inboxFolder()
        let originalName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (originalName?.isEmpty == false ? originalName : nil)
            ?? sourceURL.lastPathComponent
        let preferredExtension = (displayName as NSString).pathExtension
        let candidateExtension = preferredExtension.isEmpty
            ? sourceURL.pathExtension
            : preferredExtension
        let safeExtension = candidateExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .prefix(16)
        let suffix = safeExtension.isEmpty ? "" : ".\(safeExtension)"
        let storedName = "\(UUID().uuidString)\(suffix)"
        let destination = folder.appendingPathComponent(storedName, isDirectory: false)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let item = SharedInboxItem(
            id: UUID(),
            kind: .file,
            text: nil,
            fileName: displayName,
            storedFileName: storedName,
            createdAt: Date()
        )
        try append(item)
    }

    static func pendingItems() throws -> [(item: SharedInboxItem, fileURL: URL?)] {
        let defaults = try groupDefaults()
        let data = defaults.data(forKey: pendingKey)
        let items = data.flatMap { try? JSONDecoder().decode([SharedInboxItem].self, from: $0) } ?? []

        let folder = try inboxFolder()
        return items.map { item in
            let url = item.storedFileName.map { folder.appendingPathComponent($0, isDirectory: false) }
            return (item, url)
        }
    }

    static func acknowledge(_ item: SharedInboxItem, deleteFile: Bool = true) throws {
        let defaults = try groupDefaults()
        let data = defaults.data(forKey: pendingKey)
        var items = data.flatMap { try? JSONDecoder().decode([SharedInboxItem].self, from: $0) } ?? []
        items.removeAll { $0.id == item.id }
        if items.isEmpty {
            defaults.removeObject(forKey: pendingKey)
        } else {
            defaults.set(try JSONEncoder().encode(items), forKey: pendingKey)
        }
        if deleteFile, let storedFileName = item.storedFileName {
            let url = try inboxFolder().appendingPathComponent(storedFileName, isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func removeConsumedFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func append(_ item: SharedInboxItem) throws {
        let defaults = try groupDefaults()
        var items: [SharedInboxItem] = []
        if let data = defaults.data(forKey: pendingKey) {
            items = (try? JSONDecoder().decode([SharedInboxItem].self, from: data)) ?? []
        }
        items.append(item)
        if items.count > 30 {
            let overflow = items.count - 30
            let evicted = items.prefix(overflow)
            items.removeFirst(overflow)
            if let folder = try? inboxFolder() {
                for item in evicted {
                    guard let storedFileName = item.storedFileName else { continue }
                    try? FileManager.default.removeItem(
                        at: folder.appendingPathComponent(storedFileName, isDirectory: false)
                    )
                }
            }
        }
        defaults.set(try JSONEncoder().encode(items), forKey: pendingKey)
    }

    private static func groupDefaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw InboxError.appGroupUnavailable
        }
        return defaults
    }

    private static func inboxFolder() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw InboxError.appGroupUnavailable
        }
        let folder = container.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
