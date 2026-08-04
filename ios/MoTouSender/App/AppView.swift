import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case cast
    case chat
    case shelf
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cast: "投送"
        case .chat: "AI 对话"
        case .shelf: "书架"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .cast: "paperplane"
        case .chat: "bubble.left.and.bubble.right"
        case .shelf: "books.vertical"
        case .settings: "gearshape"
        }
    }
}

struct AppView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ConnectionStore.self) private var connection
    @Environment(TransferStore.self) private var transfer
    @Environment(ChatStore.self) private var chat

    @State private var selectedTab: AppTab = .cast
    @State private var presentedSheet: AppSheet?
    @State private var sharedItems: [PendingSharedContent] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CastView()
            }
            .tabItem { Label(AppTab.cast.title, systemImage: AppTab.cast.systemImage) }
            .tag(AppTab.cast)

            NavigationStack {
                ChatView()
            }
            .tabItem { Label(AppTab.chat.title, systemImage: AppTab.chat.systemImage) }
            .tag(AppTab.chat)

            NavigationStack {
                ShelfView()
            }
            .tabItem { Label(AppTab.shelf.title, systemImage: AppTab.shelf.systemImage) }
            .tag(AppTab.shelf)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
            .tag(AppTab.settings)
        }
        .tint(.primary)
        .task {
            for await envelope in connection.inboundEvents {
                guard !Task.isCancelled else { return }
                route(envelope.event)
            }
        }
        .task {
            loadSharedInbox()
        }
        .onOpenURL { _ in
            loadSharedInbox()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loadSharedInbox() }
        }
        .overlay(alignment: .top) {
            if !sharedItems.isEmpty {
                Button {
                    presentedSheet = .sharedInbox
                } label: {
                    Label("收到 \(sharedItems.count) 项分享内容", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .sharedInbox:
                SharedInboxView(items: $sharedItems)
            case .textAsk:
                TextAskSheet()
            }
        }
    }

    private func loadSharedInbox() {
        guard let incoming = try? SharedInbox.pendingItems(), !incoming.isEmpty else { return }
        let knownIDs = Set(sharedItems.map(\.id))
        sharedItems.append(contentsOf: incoming.compactMap {
            guard !knownIDs.contains($0.item.id) else { return nil }
            return PendingSharedContent(item: $0.item, fileURL: $0.fileURL)
        })
        presentedSheet = .sharedInbox
    }

    private func route(_ event: InboundEvent) {
        switch event {
        case .page(let state):
            transfer.handle(state)
        case .chatAsk, .textAsk:
            let appIsActive = connection.isApplicationActive
            Task { @MainActor in
                await chat.handle(event, appIsActive: appIsActive)
                if case .textAsk = event, chat.pendingTextSelection != nil {
                    presentedSheet = .textAsk
                }
            }
        case .hello, .touch:
            break
        }
    }
}

private enum AppSheet: String, Identifiable {
    case sharedInbox
    case textAsk

    var id: String { rawValue }
}

struct PendingSharedContent: Identifiable {
    var id: UUID { item.id }
    var item: SharedInboxItem
    var fileURL: URL?
}
