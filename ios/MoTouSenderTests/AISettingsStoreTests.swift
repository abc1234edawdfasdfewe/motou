import XCTest
@testable import MoTouSender

final class AISettingsStoreTests: XCTestCase {
    @MainActor
    func testSecretsNeverEnterUserDefaultsMetadata() throws {
        let suiteName = "AISettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = SettingsMemorySecrets()
        let store = SettingsStore(defaults: defaults, secrets: secrets)

        XCTAssertEqual(Set(store.configurations.map(\.id)), Set(["deepseek", "doubao", "kimi"]))
        try store.setAPIKey("super-secret-key", for: "deepseek")
        try store.setOCRToken("super-secret-token")

        let persistedText = defaults.dictionaryRepresentation().description
        XCTAssertFalse(persistedText.contains("super-secret-key"))
        XCTAssertFalse(persistedText.contains("super-secret-token"))
        XCTAssertEqual(store.activeConfiguration?.id, "deepseek")
    }
}

private final class SettingsMemorySecrets: SettingsSecretStoring {
    var values: [String: String] = [:]

    func string(for key: String) -> String? { values[key] }
    func set(_ value: String?, for key: String) throws { values[key] = value }
}
