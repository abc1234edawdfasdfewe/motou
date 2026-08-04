import SwiftUI

struct SharedInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TransferStore.self) private var transfer
    @Environment(ConnectionStore.self) private var connection
    @Binding var items: [PendingSharedContent]
    @State private var localError: String?
    @State private var sendingIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if let localError {
                    Section {
                        Label(localError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView(
                        "没有待处理内容",
                        systemImage: "tray",
                        description: Text("从其他 App 分享到墨投后会显示在这里")
                    )
                } else {
                    Section("选择一项投送") {
                        ForEach(items) { pending in
                            Button {
                                send(pending)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: icon(for: pending.item.kind))
                                        .frame(width: 28)
                                        .foregroundStyle(.primary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(title(for: pending))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text(pending.item.createdAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "paperplane")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                !connection.isReady
                                    || transfer.isBusy
                                    || sendingIDs.contains(pending.id)
                            )
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    remove(pending)
                                }
                                .disabled(sendingIDs.contains(pending.id))
                            }
                        }
                    }

                    if !connection.isReady {
                        Section {
                            Label("请先连接墨投设备，再选择要投送的内容", systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("分享收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func send(_ pending: PendingSharedContent) {
        guard connection.isReady else {
            localError = "请先连接墨投设备"
            return
        }
        guard !transfer.isBusy, !sendingIDs.contains(pending.id) else { return }
        sendingIDs.insert(pending.id)
        do {
            switch pending.item.kind {
            case .text:
                transfer.sendText(pending.item.text ?? "") { result in
                    finish(result, pending: pending)
                }
            case .url:
                transfer.sendURL(pending.item.text ?? "") { result in
                    finish(result, pending: pending)
                }
            case .file:
                guard let fileURL = pending.fileURL else {
                    sendingIDs.remove(pending.id)
                    localError = "分享文件已不存在"
                    return
                }
                let managedURL = try ManagedImportStore.claim(fileAt: fileURL)
                transfer.sendFile(
                    url: managedURL,
                    displayName: pending.item.fileName
                ) { result in
                    finish(result, pending: pending)
                }
            }
            localError = nil
        } catch {
            sendingIDs.remove(pending.id)
            localError = error.localizedDescription
        }
    }

    private func finish(
        _ result: Result<Void, Error>,
        pending: PendingSharedContent
    ) {
        sendingIDs.remove(pending.id)
        switch result {
        case .success:
            do {
                try SharedInbox.acknowledge(pending.item)
                items.removeAll { $0.id == pending.id }
                localError = nil
                if items.isEmpty { dismiss() }
            } catch {
                localError = "内容已投送，但收件箱清理失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            localError = error is CancellationError
                ? "投送已取消，可重新选择此条内容"
                : error.localizedDescription
        }
    }

    private func remove(_ pending: PendingSharedContent) {
        do {
            try SharedInbox.acknowledge(pending.item)
            items.removeAll { $0.id == pending.id }
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func title(for pending: PendingSharedContent) -> String {
        pending.item.fileName
            ?? pending.item.text?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).description
            ?? "分享内容"
    }

    private func icon(for kind: SharedInboxItem.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .file: "doc"
        }
    }
}
