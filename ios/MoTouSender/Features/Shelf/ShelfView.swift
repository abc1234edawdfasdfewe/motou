import SwiftUI

struct ShelfView: View {
    @Environment(PersistenceStore.self) private var persistence
    @Environment(TransferStore.self) private var transfer

    @State private var pendingDeletion: PendingDeletion?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if transfer.activity != .idle {
                    transferFeedback
                }

                booksSection
                historySection
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                performPendingDeletion()
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
    }

    @ViewBuilder
    private var transferFeedback: some View {
        ShelfSectionCard(title: "当前任务", systemImage: "waveform.path.ecg") {
            switch transfer.activity {
            case .idle:
                EmptyView()
            case .processing(let message), .sending(let message):
                HStack(spacing: 12) {
                    ProgressView()
                    Text(message)
                        .font(.subheadline)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if let progress = transfer.progress {
                Divider()
                HStack {
                    Text(progress.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(progress.description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var booksSection: some View {
        ShelfSectionCard(title: "我的书架", systemImage: "books.vertical") {
            if persistence.books.isEmpty {
                EmptyShelfState(
                    icon: "book.closed",
                    title: "书架还是空的",
                    detail: "从“投送”页打开 PDF 或 CBZ 后，会自动保存阅读进度。"
                )
            } else {
                ForEach(Array(persistence.books.enumerated()), id: \.element.id) { index, book in
                    BookRow(
                        book: book,
                        isBusy: transfer.isBusy,
                        onContinue: { transfer.reopen(book) },
                        onDelete: { pendingDeletion = .book(book) }
                    )

                    if index < persistence.books.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        ShelfSectionCard(title: "投送历史", systemImage: "clock.arrow.circlepath") {
            if persistence.historyItems.isEmpty {
                EmptyShelfState(
                    icon: "clock",
                    title: "暂无历史记录",
                    detail: "投送文字、Markdown 或网页后，可在这里快速重发。"
                )
            } else {
                ForEach(Array(persistence.historyItems.enumerated()), id: \.element.id) { index, item in
                    HistoryRow(
                        item: item,
                        isBusy: transfer.isBusy,
                        onResend: { transfer.resend(item) },
                        onDelete: { pendingDeletion = .history(item) }
                    )

                    if index < persistence.historyItems.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .book:
            "从书架移除？"
        case .history:
            "删除这条历史记录？"
        case nil:
            "确认删除？"
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .book(let book):
            "“\(book.title)”的阅读进度会被移除，原文件不会被删除。"
        case .history(let item):
            "“\(item.title)”将不再出现在投送历史中。"
        case nil:
            ""
        }
    }

    private func performPendingDeletion() {
        switch pendingDeletion {
        case .book(let book):
            transfer.removeBook(book)
        case .history(let item):
            persistence.removeHistory(id: item.id)
        case nil:
            break
        }
        pendingDeletion = nil
    }
}

private enum PendingDeletion {
    case book(BookItem)
    case history(HistoryItem)
}

private struct BookRow: View {
    var book: BookItem
    var isBusy: Bool
    var onContinue: () -> Void
    var onDelete: () -> Void

    private var completedPages: Int {
        guard book.pageCount > 0 else { return 0 }
        return min(max(0, book.lastPage + 1), book.pageCount)
    }

    private var progress: Double {
        guard book.pageCount > 0 else { return 0 }
        return Double(completedPages) / Double(book.pageCount)
    }

    private var formatLabel: String {
        switch book.format {
        case .pdf: "PDF"
        case .cbz: "CBZ"
        }
    }

    private var formatIcon: String {
        switch book.format {
        case .pdf: "doc.richtext"
        case .cbz: "photo.stack"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: formatIcon)
                    .font(.title3)
                    .frame(width: 42, height: 48)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(formatLabel)
                        Text("·")
                        Text("上次阅读")
                        Text(book.openedAt, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Menu {
                    Button("继续阅读", systemImage: "book.pages") {
                        onContinue()
                    }
                    .disabled(isBusy)

                    Button("从书架移除", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("更多操作")
            }

            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(.primary)
                HStack {
                    Text(book.pageCount > 0 ? "第 \(completedPages) / \(book.pageCount) 页" : "尚未读取")
                    Spacer()
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button(action: onContinue) {
                Label("继续阅读", systemImage: "book.pages")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(isBusy)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryRow: View {
    var item: HistoryItem
    var isBusy: Bool
    var onResend: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onResend) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Menu {
                Button("重新投送", systemImage: "paperplane") {
                    onResend()
                }
                .disabled(isBusy)

                Button("删除记录", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 36)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyShelfState: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct ShelfSectionCard<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }
}
