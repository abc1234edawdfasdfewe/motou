import SwiftUI

struct TextAskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatStore.self) private var chat
    @State private var prompt = "请解释这段内容"

    var body: some View {
        NavigationStack {
            Form {
                Section("墨水屏选中文字") {
                    Text(chat.pendingTextSelection?.text ?? "")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                Section("你想问什么？") {
                    TextField("输入提示词", text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let failure = chat.failureMessage {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await chat.askAboutPendingSelection(prompt: prompt) != nil {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if chat.isRequesting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(chat.isRequesting ? "思考中…" : "提问并投送回答")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isRequesting)
                }
            }
            .navigationTitle("问 AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        chat.dismissPendingTextSelection()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(chat.isRequesting)
    }
}
