import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var chat
    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var connection
    @Environment(SpeechRecognizer.self) private var speech
    @Environment(SpeechSynthesizer.self) private var speaker

    @State private var draft = ""
    @State private var showClearConfirmation = false
    @State private var localError: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chat.messages.isEmpty {
                        ContentUnavailableView(
                            "开始一段对话",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("回答会同步到已连接的墨水屏；也可由墨水屏继续追问")
                        )
                        .padding(.top, 90)
                    } else {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message) {
                                speaker.speak(message.content)
                            }
                            .id(message.id)
                        }
                    }

                    if chat.isRequesting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在思考…").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }

                    if let error = chat.failureMessage ?? chat.lastDeliveryError ?? localError {
                        Button {
                            chat.clearFailure()
                            localError = nil
                        } label: {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) { _, _ in
                guard let id = chat.messages.last?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationTitle("AI 对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("模型", selection: Binding(
                        get: { settings.activeLLMId },
                        set: { settings.selectConfiguration(id: $0) }
                    )) {
                        ForEach(settings.configurations) { configuration in
                            Text(configuration.name).tag(configuration.id)
                        }
                    }
                } label: {
                    Label(settings.activeConfiguration?.name ?? "模型", systemImage: "cpu")
                }

                Menu {
                    Button {
                        Task {
                            do { try await chat.syncToDevice() }
                            catch { localError = error.localizedDescription }
                        }
                    } label: {
                        Label("同步整段对话", systemImage: "display.and.arrow.down")
                    }
                    .disabled(!connection.isReady)

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清空对话", systemImage: "trash")
                    }
                    .disabled(chat.messages.isEmpty || chat.isRequesting)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: speech.transcript) { _, transcript in
            if !transcript.isEmpty { draft = transcript }
        }
        .confirmationDialog(
            "清空全部对话记录？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task { await chat.clear() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if case let .failure(message) = speech.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 9) {
                Button {
                    Task {
                        if speech.isListening {
                            speech.stop()
                        } else {
                            await speech.start()
                        }
                    }
                } label: {
                    Image(systemName: speech.isListening ? "waveform.circle.fill" : "mic.circle")
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: speech.isListening)
                }
                .accessibilityLabel(speech.isListening ? "停止语音输入" : "开始语音输入")

                TextField("输入消息", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .submitLabel(.send)
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isRequesting)
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isRequesting else { return }
        draft = ""
        speech.stop()
        Task {
            if let reply = await chat.ask(text) {
                speaker.speak(reply.content)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var speak: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 44) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .background(
                        message.role == .user ? Color.primary : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 17)
                    )

                HStack(spacing: 7) {
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if message.role == .assistant {
                        Button(action: speak) {
                            Image(systemName: "speaker.wave.2")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("朗读回答")
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 44) }
        }
        .padding(.horizontal, 14)
    }
}
