import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var pendingNewConfiguration: LLMConfiguration?
    @State private var ocrTokenDraft = ""
    @State private var isShowingOCRToken = false
    @State private var didLoadOCRToken = false
    @State private var isSavingOCRToken = false
    @State private var ocrFeedback: SettingsFeedback?

    var body: some View {
        List {
            Section {
                Picker(
                    "当前服务",
                    selection: Binding(
                        get: { settings.activeLLMId },
                        set: { settings.selectConfiguration(id: $0) }
                    )
                ) {
                    ForEach(settings.configurations) { configuration in
                        Text(configuration.name).tag(configuration.id)
                    }
                }
                .pickerStyle(.navigationLink)

                ForEach(settings.configurations) { configuration in
                    NavigationLink {
                        LLMConfigurationEditor(
                            configuration: configuration,
                            isNew: false
                        )
                    } label: {
                        LLMConfigurationRow(
                            configuration: configuration,
                            isSelected: configuration.id == settings.activeLLMId
                        )
                    }
                }

                Button {
                    pendingNewConfiguration = LLMConfiguration(
                        id: "custom-\(UUID().uuidString.lowercased())",
                        name: "自定义服务",
                        baseURL: "https://",
                        apiKey: "",
                        model: ""
                    )
                } label: {
                    Label("添加自定义服务", systemImage: "plus.circle")
                }
            } header: {
                Text("AI 模型")
            } footer: {
                Text("对话使用 OpenAI 兼容接口。API Key 仅保存在 iOS 钥匙串。")
            }

            Section {
                TextField(
                    "OCR 模型",
                    text: Binding(
                        get: { settings.ocrModel },
                        set: { settings.ocrModel = $0 }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                HStack(spacing: 10) {
                    Group {
                        if isShowingOCRToken {
                            TextField("OCR Token", text: $ocrTokenDraft)
                        } else {
                            SecureField("OCR Token", text: $ocrTokenDraft)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()

                    Button {
                        isShowingOCRToken.toggle()
                    } label: {
                        Image(systemName: isShowingOCRToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isShowingOCRToken ? "隐藏 OCR Token" : "显示 OCR Token")
                }

                Button {
                    saveOCRToken()
                } label: {
                    HStack {
                        Label("保存 OCR Token", systemImage: "key")
                        Spacer()
                        if isSavingOCRToken {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isSavingOCRToken)

                if let ocrFeedback {
                    SettingsFeedbackLabel(feedback: ocrFeedback)
                }
            } header: {
                Text("OCR")
            } footer: {
                Text("默认模型为 PaddleOCR-VL-1.6。Token 保存在 iOS 钥匙串，不会写入普通偏好设置。")
            }

            if let lastError = settings.lastError, ocrFeedback == nil {
                Section {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } header: {
                    Text("最近错误")
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            guard !didLoadOCRToken else { return }
            ocrTokenDraft = settings.ocrToken
            didLoadOCRToken = true
        }
        .sheet(item: $pendingNewConfiguration) { configuration in
            NavigationStack {
                LLMConfigurationEditor(
                    configuration: configuration,
                    isNew: true
                )
            }
            .presentationDetents([.large])
        }
    }

    private func saveOCRToken() {
        guard !isSavingOCRToken else { return }
        isSavingOCRToken = true
        defer { isSavingOCRToken = false }

        do {
            try settings.setOCRToken(ocrTokenDraft)
            ocrTokenDraft = settings.ocrToken
            ocrFeedback = .success(
                settings.ocrToken.isEmpty ? "OCR Token 已移除" : "OCR Token 已安全保存"
            )
        } catch {
            settings.record(error)
            ocrFeedback = .failure(error.localizedDescription)
        }
    }
}

private struct LLMConfigurationRow: View {
    let configuration: LLMConfiguration
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .frame(width: 24)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(configuration.name)
                        .foregroundStyle(.primary)
                    if isSelected {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                Text(configuration.model.isEmpty ? "未选择模型" : configuration.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LLMConfigurationEditor: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LLMConfiguration
    @State private var isShowingAPIKey = false
    @State private var fetchedModels: [String] = []
    @State private var operation: ConfigurationOperation?
    @State private var feedback: SettingsFeedback?
    @State private var isShowingDeleteConfirmation = false

    private let isNew: Bool

    init(configuration: LLMConfiguration, isNew: Bool) {
        _draft = State(initialValue: configuration)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("OpenAI 兼容服务") {
                TextField("名称", text: $draft.name)
                    .textContentType(.organizationName)

                TextField("接口地址", text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                HStack(spacing: 10) {
                    Group {
                        if isShowingAPIKey {
                            TextField("API Key", text: $draft.apiKey)
                        } else {
                            SecureField("API Key", text: $draft.apiKey)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()

                    Button {
                        isShowingAPIKey.toggle()
                    } label: {
                        Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isShowingAPIKey ? "隐藏 API Key" : "显示 API Key")
                }
            } header: {
                Text("凭据")
            } footer: {
                Text("API Key 保存在 iOS 钥匙串，不会显示在日志或普通偏好设置中。")
            }

            Section {
                TextField("模型 ID", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !fetchedModels.isEmpty {
                    Picker("可用模型", selection: $draft.model) {
                        if !draft.model.isEmpty, !fetchedModels.contains(draft.model) {
                            Text(draft.model).tag(draft.model)
                        }
                        ForEach(fetchedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        Label("拉取模型", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(operation != nil)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        Label("测试连接", systemImage: "network")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(operation != nil)
                }

                if let operation {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(operation.message)
                            .foregroundStyle(.secondary)
                    }
                }

                if let feedback {
                    SettingsFeedbackLabel(feedback: feedback)
                }
            } header: {
                Text("模型")
            } footer: {
                Text("“拉取模型”请求 /models；测试连接会在服务未提供模型列表时尝试最小对话请求。")
            }

            if !isNew, !isBuiltInConfiguration {
                Section {
                    Button("删除此服务", role: .destructive) {
                        isShowingDeleteConfirmation = true
                    }
                    .disabled(operation != nil)
                }
            }
        }
        .navigationTitle(isNew ? "添加 AI 服务" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(operation != nil)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(operation != nil)
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { saveAndDismiss() }
                    .fontWeight(.semibold)
                    .disabled(operation != nil)
            }
        }
        .confirmationDialog(
            "删除“\(draft.name)”？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteConfiguration() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该服务的 API Key 也会从钥匙串移除。")
        }
    }

    private var isBuiltInConfiguration: Bool {
        LLMConfiguration.defaults.contains(where: { $0.id == draft.id })
    }

    private func saveAndDismiss() {
        do {
            try validateDraft()
            try settings.updateConfiguration(draft)
            if isNew {
                settings.selectConfiguration(id: draft.id)
            }
            dismiss()
        } catch {
            settings.record(error)
            feedback = .failure(error.localizedDescription)
        }
    }

    private func deleteConfiguration() {
        do {
            try settings.deleteConfiguration(id: draft.id)
            dismiss()
        } catch {
            settings.record(error)
            feedback = .failure(error.localizedDescription)
        }
    }

    @MainActor
    private func fetchModels() async {
        guard operation == nil else { return }
        operation = .fetchingModels
        feedback = nil
        defer { operation = nil }

        do {
            try validateDraft()
            let models: [String]
            if isNew {
                models = try await AIClient().listModels(for: draft)
            } else {
                try settings.updateConfiguration(draft)
                models = try await settings.listModels(for: draft.id)
            }

            fetchedModels = models
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if draft.model.isEmpty, let first = fetchedModels.first {
                draft.model = first
            }
            feedback = .success(
                fetchedModels.isEmpty
                    ? "连接成功，服务未返回可用模型"
                    : "已获取 \(fetchedModels.count) 个模型"
            )
        } catch {
            if !isNew { settings.record(error) }
            feedback = .failure(error.localizedDescription)
        }
    }

    @MainActor
    private func testConnection() async {
        guard operation == nil else { return }
        operation = .testingConnection
        feedback = nil
        defer { operation = nil }

        do {
            try validateDraft()
            let result: AIConnectionTest
            if isNew {
                result = try await AIClient().testConnection(for: draft)
            } else {
                try settings.updateConfiguration(draft)
                result = try await settings.testConnection(for: draft.id)
            }

            if !result.models.isEmpty {
                fetchedModels = result.models
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if draft.model.isEmpty, let first = fetchedModels.first {
                    draft.model = first
                }
            }
            feedback = .success(
                result.usedChatFallback
                    ? "连接成功，已通过对话接口验证"
                    : "连接成功，发现 \(result.models.count) 个模型"
            )
        } catch {
            if !isNew { settings.record(error) }
            feedback = .failure(error.localizedDescription)
        }
    }

    private func validateDraft() throws {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SettingsValidationError.missingName
        }
        if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SettingsValidationError.missingBaseURL
        }
    }
}

private enum ConfigurationOperation {
    case fetchingModels
    case testingConnection

    var message: String {
        switch self {
        case .fetchingModels: "正在拉取模型…"
        case .testingConnection: "正在测试连接…"
        }
    }
}

private enum SettingsFeedback: Equatable {
    case success(String)
    case failure(String)
}

private struct SettingsFeedbackLabel: View {
    let feedback: SettingsFeedback

    var body: some View {
        switch feedback {
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

private enum SettingsValidationError: LocalizedError {
    case missingName
    case missingBaseURL

    var errorDescription: String? {
        switch self {
        case .missingName: "请填写服务名称"
        case .missingBaseURL: "请填写接口地址"
        }
    }
}
