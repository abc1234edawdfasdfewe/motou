import Foundation

struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
}

struct BookItem: Codable, Identifiable, Hashable, Sendable {
    enum Format: String, Codable, Sendable {
        case pdf
        case cbz
    }

    var id: UUID
    var title: String
    var format: Format
    var bookmark: Data
    var pageCount: Int
    var lastPage: Int
    var openedAt: Date
    var managedFileName: String? = nil
}

struct TransferProgress: Equatable, Sendable {
    var contentID: String
    var title: String
    var currentPage: Int
    var pageCount: Int
    var unit: String

    var description: String {
        "第 \(currentPage + 1) / \(pageCount) \(unit)"
    }
}

enum TransferActivity: Equatable, Sendable {
    case idle
    case processing(String)
    case sending(String)
    case failed(String)
}
