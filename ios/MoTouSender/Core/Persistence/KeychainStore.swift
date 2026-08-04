import Foundation
import Security

struct KeychainStore: Sendable {
    enum Error: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串操作失败：\(message)（\(status)）"
            case .invalidUTF8:
                return "钥匙串中的内容不是有效的 UTF-8 文本"
            }
        }
    }

    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.motou.sender.ios") {
        self.service = service
    }

    func string(for key: String) -> String? {
        guard let data = try? data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else { throw Error.invalidUTF8 }
        try set(data, for: key)
    }

    func removeValue(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }

    private func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        return result as? Data
    }

    private func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw Error.unexpectedStatus(updateStatus)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
