import Foundation
import Observation

protocol SettingsSecretStoring {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String) throws
}

enum SettingsStoreError: LocalizedError, Equatable {
    case unknownConfiguration

    var errorDescription: String? {
        switch self {
        case .unknownConfiguration:
            "未找到模型配置"
        }
    }
}

extension KeychainStore: SettingsSecretStoring {
    func set(_ value: String?, for key: String) throws {
        if let value, !value.isEmpty {
            try set(value, for: key)
        } else {
            try removeValue(for: key)
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private static let defaultOCRModel = "PaddleOCR-VL-1.6"

    private struct ConfigurationMetadata: Codable {
        var id: String
        var name: String
        var baseURL: String
        var model: String
    }

    private enum StorageKey {
        static let configurations = "motou.settings.llms.v2"
        static let activeLLM = "motou.settings.llm.active"
        static let ocrModel = "motou.settings.ocr.model"
        static let ocrToken = "ocr.token"

        static func apiKey(for id: String) -> String {
            "llm.\(id).apiKey"
        }
    }

    private(set) var configurations: [LLMConfiguration]
    var activeLLMId: String {
        didSet { defaults.set(activeLLMId, forKey: StorageKey.activeLLM) }
    }
    private var storedOCRModel: String
    var ocrModel: String {
        get { storedOCRModel }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            storedOCRModel = clean.isEmpty ? Self.defaultOCRModel : clean
            defaults.set(storedOCRModel, forKey: StorageKey.ocrModel)
        }
    }
    private(set) var ocrToken: String
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SettingsSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secrets: SettingsSecretStoring = KeychainStore(service: "com.motou.sender.settings")
    ) {
        self.defaults = defaults
        self.secrets = secrets

        let storedMetadata = defaults.data(forKey: StorageKey.configurations)
            .flatMap { try? JSONDecoder().decode([ConfigurationMetadata].self, from: $0) }
        let metadata = Self.mergedMetadata(storedMetadata)
        let loadedConfigurations = metadata.map { item in
            LLMConfiguration(
                id: item.id,
                name: item.name,
                baseURL: item.baseURL,
                apiKey: secrets.string(for: StorageKey.apiKey(for: item.id)) ?? "",
                model: item.model
            )
        }

        let requestedActiveID = defaults.string(forKey: StorageKey.activeLLM) ?? "deepseek"
        let loadedActiveID = loadedConfigurations.contains(where: { $0.id == requestedActiveID })
            ? requestedActiveID
            : (loadedConfigurations.first?.id ?? "deepseek")
        let loadedOCRModel = defaults.string(forKey: StorageKey.ocrModel) ?? Self.defaultOCRModel
        let loadedOCRToken = secrets.string(for: StorageKey.ocrToken) ?? ""

        configurations = loadedConfigurations
        activeLLMId = loadedActiveID
        storedOCRModel = loadedOCRModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultOCRModel
            : loadedOCRModel
        ocrToken = loadedOCRToken
        persistMetadata()
    }

    var activeConfiguration: LLMConfiguration? {
        configurations.first(where: { $0.id == activeLLMId })
            ?? configurations.first(where: { !$0.apiKey.isEmpty })
            ?? configurations.first
    }

    /// Compatibility spelling used by feature stores and views.
    var activeLLM: LLMConfiguration? { activeConfiguration }

    func configuration(id: String) -> LLMConfiguration? {
        configurations.first(where: { $0.id == id })
    }

    func selectConfiguration(id: String) {
        guard configurations.contains(where: { $0.id == id }) else { return }
        activeLLMId = id
    }

    func updateConfiguration(_ configuration: LLMConfiguration) throws {
        var clean = configuration
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.baseURL = clean.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.model = clean.model.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.apiKey = clean.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        try secrets.set(clean.apiKey, for: StorageKey.apiKey(for: clean.id))
        if let index = configurations.firstIndex(where: { $0.id == clean.id }) {
            configurations[index] = clean
        } else {
            configurations.append(clean)
        }
        persistMetadata()
        lastError = nil
    }

    func setAPIKey(_ value: String, for configurationID: String) throws {
        guard var configuration = configuration(id: configurationID) else {
            throw SettingsStoreError.unknownConfiguration
        }
        configuration.apiKey = value
        try updateConfiguration(configuration)
    }

    func setOCRToken(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try secrets.set(clean, for: StorageKey.ocrToken)
        ocrToken = clean
        lastError = nil
    }

    func deleteConfiguration(id: String) throws {
        guard !LLMConfiguration.defaults.contains(where: { $0.id == id }) else { return }
        try secrets.set(nil, for: StorageKey.apiKey(for: id))
        configurations.removeAll(where: { $0.id == id })
        if activeLLMId == id {
            activeLLMId = configurations.first?.id ?? "deepseek"
        }
        persistMetadata()
    }

    func listModels(for configurationID: String, using client: AIClient = AIClient()) async throws -> [String] {
        guard let configuration = configuration(id: configurationID) else {
            throw SettingsStoreError.unknownConfiguration
        }
        do {
            let models = try await client.listModels(for: configuration)
            lastError = nil
            return models
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func testConnection(
        for configurationID: String,
        using client: AIClient = AIClient()
    ) async throws -> AIConnectionTest {
        guard let configuration = configuration(id: configurationID) else {
            throw SettingsStoreError.unknownConfiguration
        }
        do {
            let result = try await client.testConnection(for: configuration)
            lastError = nil
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func chooseModel(_ model: String, for configurationID: String) throws {
        guard var configuration = configuration(id: configurationID) else {
            throw SettingsStoreError.unknownConfiguration
        }
        configuration.model = model
        try updateConfiguration(configuration)
    }

    func record(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func persistMetadata() {
        let metadata = configurations.map {
            ConfigurationMetadata(id: $0.id, name: $0.name, baseURL: $0.baseURL, model: $0.model)
        }
        if let data = try? JSONEncoder().encode(metadata) {
            defaults.set(data, forKey: StorageKey.configurations)
        }
        defaults.set(activeLLMId, forKey: StorageKey.activeLLM)
        defaults.set(ocrModel, forKey: StorageKey.ocrModel)
    }

    private static func mergedMetadata(_ stored: [ConfigurationMetadata]?) -> [ConfigurationMetadata] {
        guard let stored, !stored.isEmpty else {
            return LLMConfiguration.defaults.map {
                ConfigurationMetadata(id: $0.id, name: $0.name, baseURL: $0.baseURL, model: $0.model)
            }
        }

        var result = stored
        for item in LLMConfiguration.defaults where !result.contains(where: { $0.id == item.id }) {
            result.append(ConfigurationMetadata(
                id: item.id,
                name: item.name,
                baseURL: item.baseURL,
                model: item.model
            ))
        }
        return result
    }
}
