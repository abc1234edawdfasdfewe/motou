import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CastView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(BonjourDiscovery.self) private var discovery
    @Environment(TransferStore.self) private var transfer
    @Environment(PersistenceStore.self) private var persistence
    @Environment(SettingsStore.self) private var settings

    @State private var address = ""
    @State private var draft = ""
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var ocrPhoto: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var sheet: CastSheet?
    @State private var capturedImage: UIImage?
    @State private var isRunningOCR = false
    @State private var localError: String?

    private let fileTypes = DocumentImportTypes.allowedContentTypes

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                connectionCard
                composerCard
                contentActionsCard
                transferStatusCard
                historyCard
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("墨投")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if discovery.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        discovery.start()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新发现设备")
                }
            }
        }
        .onAppear {
            if address.isEmpty {
                if let host = connection.currentHost {
                    address = host
                } else if let recent = persistence.savedDevices.first {
                    address = recent.port == 8383 ? recent.host : "\(recent.host):\(recent.port)"
                }
            }
            discovery.start()
        }
        .onDisappear { discovery.stop() }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items) }
        }
        .onChange(of: ocrPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { ocrPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CastViewError.imageReadFailed
                    }
                    await runOCR(data)
                } catch {
                    localError = error.localizedDescription
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFiles
        )
        .sheet(item: $sheet) { destination in
            switch destination {
            case .qr:
                QRScannerSheet { value in
                    address = value
                    _ = connection.connect(address: value)
                    sheet = nil
                } onError: { message in
                    localError = message
                    sheet = nil
                }
            case .camera:
                CameraPicker { image in
                    capturedImage = image
                    sheet = nil
                } onCancel: {
                    sheet = nil
                }
                .ignoresSafeArea()
            case .jump:
                PageJumpSheet()
            }
        }
        .confirmationDialog(
            "如何处理这张照片？",
            isPresented: Binding(
                get: { capturedImage != nil },
                set: { if !$0 { capturedImage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("OCR 识别文字并投送") {
                guard let data = capturedImage?.jpegData(compressionQuality: 0.95) else { return }
                capturedImage = nil
                Task { await runOCR(data) }
            }
            Button("直接投送原图") {
                guard let data = capturedImage?.jpegData(compressionQuality: 0.95) else { return }
                capturedImage = nil
                transfer.sendImage(data: data, name: "拍照")
            }
            Button("取消", role: .cancel) { capturedImage = nil }
        }
    }

    private var connectionCard: some View {
        Card(title: "连接设备", systemImage: "display.and.arrow.down") {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionTitle).font(.subheadline.weight(.semibold))
                    Text(connectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if connection.phase == .connecting || connection.phase == .awaitingHello {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                TextField("设备 IP、主机名或 URL", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                Button(connection.isReady ? "断开" : "连接") {
                    connection.isReady ? connection.disconnect() : connect()
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
            }

            HStack {
                Button { sheet = .qr } label: {
                    Label("扫码连接", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("仅连接可信局域网")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !discovery.devices.isEmpty {
                Divider()
                Text("在线设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(discovery.devices) { device in
                    Button {
                        address = device.port == 8383 ? device.host : "\(device.host):\(device.port)"
                        connection.connect(host: device.host, port: device.port)
                    } label: {
                        DeviceRow(
                            name: device.name,
                            detail: "\(device.host):\(device.port)",
                            online: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !persistence.savedDevices.isEmpty {
                Divider()
                Text("最近设备").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(persistence.savedDevices) { device in
                    Button {
                        address = device.port == 8383 ? device.host : "\(device.host):\(device.port)"
                        connection.connect(to: device)
                    } label: {
                        DeviceRow(name: device.name, detail: device.host, online: false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("移除", role: .destructive) {
                            persistence.removeDevice(id: device.id)
                        }
                    }
                }
            }
        }
    }

    private var composerCard: some View {
        Card(title: "文字与网址", systemImage: "text.alignleft") {
            TextEditor(text: $draft)
                .frame(minHeight: 118)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("输入文字或粘贴网址…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button {
                    if UIPasteboard.general.hasStrings {
                        draft = UIPasteboard.general.string ?? ""
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    sendDraft()
                } label: {
                    Label("投送", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var contentActionsCard: some View {
        Card(title: "添加内容", systemImage: "plus.square.on.square") {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 20, matching: .images) {
                    ActionTile(title: "照片 / 漫画", subtitle: "可多选并自然排序", icon: "photo.on.rectangle.angled")
                }
                .buttonStyle(.plain)

                Button { isFileImporterPresented = true } label: {
                    ActionTile(title: "选择文件", subtitle: "电子书 · Office · Markdown · PDF", icon: "folder")
                }
                .buttonStyle(.plain)

                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        sheet = .camera
                    } else {
                        localError = "当前设备没有可用相机"
                    }
                } label: {
                    ActionTile(title: "相机拍摄", subtitle: "直接投图或 OCR", icon: "camera")
                }
                .buttonStyle(.plain)

                PhotosPicker(selection: $ocrPhoto, matching: .images) {
                    ActionTile(title: "OCR 扫描", subtitle: "识别文字后排版", icon: "text.viewfinder")
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var transferStatusCard: some View {
        if transfer.progress != nil || transfer.activity != .idle || localError != nil || isRunningOCR {
            Card(title: "当前任务", systemImage: "waveform.path.ecg") {
                if isRunningOCR {
                    HStack { ProgressView(); Text("OCR 识别中…") }
                }

                switch transfer.activity {
                case .idle:
                    EmptyView()
                case .processing(let message), .sending(let message):
                    HStack { ProgressView(); Text(message) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if let localError {
                    Label(localError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .onTapGesture { self.localError = nil }
                }

                if let progress = transfer.progress {
                    Divider()
                    Text(progress.title).font(.headline).lineLimit(1)
                    HStack {
                        Button { transfer.previousPage() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!transfer.canGoPrevious)

                        Spacer()
                        Button(progress.description) { sheet = .jump }
                            .font(.subheadline.monospacedDigit())
                        Spacer()

                        Button { transfer.nextPage() } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!transfer.canGoNext)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var historyCard: some View {
        if !persistence.historyItems.isEmpty {
            Card(title: "最近投送", systemImage: "clock.arrow.circlepath") {
                ForEach(persistence.historyItems) { item in
                    Button {
                        transfer.resend(item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(1).foregroundStyle(.primary)
                                Text(item.createdAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "paperplane").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            persistence.removeHistory(id: item.id)
                        }
                    }
                    if item.id != persistence.historyItems.last?.id { Divider() }
                }
            }
        }
    }

    private var connectionTitle: String {
        switch connection.phase {
        case .disconnected: "未连接"
        case .connecting: "正在建立连接"
        case .awaitingHello: "等待设备握手"
        case .ready: "已连接"
        }
    }

    private var connectionDetail: String {
        switch connection.phase {
        case .disconnected(let reason):
            return reason ?? "输入 IP、扫码或选择在线设备"
        case .connecting:
            return "连接 ws://…:8383/channel"
        case .awaitingHello:
            return "正在读取屏幕能力"
        case .ready:
            guard let value = connection.capabilities else { return "设备已就绪" }
            return "\(value.name) · \(value.screen.width)×\(value.screen.height) · \(value.grayscale) 灰阶"
        }
    }

    private var connectionColor: Color {
        switch connection.phase {
        case .ready: .green
        case .connecting, .awaitingHello: .orange
        case .disconnected: .secondary
        }
    }

    private func connect() {
        guard connection.connect(address: address) else {
            localError = "设备地址无效"
            return
        }
        localError = nil
    }

    private func sendDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            transfer.sendURL(url)
        } else {
            transfer.sendText(value)
        }
        draft = ""
    }

    @MainActor
    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        defer { selectedPhotos = [] }
        do {
            var values: [(name: String, data: Data)] = []
            let maximumLongEdge = CGFloat(max(
                connection.capabilities?.screen.width ?? 1_920,
                connection.capabilities?.screen.height ?? 1_920
            ))
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try OCRImageProcessor.jpegData(
                        from: data,
                        maximumLongEdge: maximumLongEdge,
                        quality: 0.92
                    )
                }.value
                values.append(("照片 \(index + 1).jpg", prepared))
            }
            guard !values.isEmpty else { throw CastViewError.imageReadFailed }
            if values.count == 1, let first = values.first {
                transfer.sendImage(data: first.data, name: first.name)
            } else {
                transfer.sendImages(values, title: "漫画·\(values.count) 张")
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            if urls.count == 1, let first = urls.first {
                transfer.sendFile(url: first)
                return
            }
            let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"])
            guard urls.allSatisfy({ imageExtensions.contains($0.pathExtension.lowercased()) }) else {
                throw CastViewError.multipleFilesMustBeImages
            }
            let maximumLongEdge = CGFloat(max(
                connection.capabilities?.screen.width ?? 1_920,
                connection.capabilities?.screen.height ?? 1_920
            ))
            Task {
                do {
                    let images = try await Task.detached(priority: .userInitiated) {
                        var images: [(name: String, data: Data)] = []
                        images.reserveCapacity(urls.count)
                        for url in urls {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            let prepared = try OCRImageProcessor.jpegData(
                                from: data,
                                maximumLongEdge: maximumLongEdge,
                                quality: 0.92
                            )
                            images.append((url.lastPathComponent, prepared))
                        }
                        return images
                    }.value
                    transfer.sendImages(images, title: "漫画·\(images.count) 张")
                } catch {
                    localError = error.localizedDescription
                }
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    @MainActor
    private func runOCR(_ input: Data) async {
        guard !settings.ocrToken.isEmpty else {
            localError = "请先在设置中填写 OCR Token"
            return
        }
        isRunningOCR = true
        defer { isRunningOCR = false }
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) {
                try OCRImageProcessor.jpegData(from: input)
            }.value
            let result = try await OCRClient().recognize(
                token: settings.ocrToken,
                model: settings.ocrModel,
                imageData: jpeg
            )
            transfer.sendMarkdown(result.markdown, title: "扫描·\(Date.now.formatted(date: .numeric, time: .shortened))")
        } catch {
            localError = error.localizedDescription
        }
    }
}

private enum CastSheet: String, Identifiable {
    case qr
    case camera
    case jump

    var id: String { rawValue }
}

private enum CastViewError: LocalizedError {
    case imageReadFailed
    case multipleFilesMustBeImages

    var errorDescription: String? {
        switch self {
        case .imageReadFailed: "图片读取失败"
        case .multipleFilesMustBeImages: "多选时仅支持全部为图片"
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct DeviceRow: View {
    var name: String
    var detail: String
    var online: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
        }
        .contentShape(Rectangle())
    }
}

private struct ActionTile: View {
    var title: String
    var subtitle: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onResult: (String) -> Void
    var onError: (String) -> Void

    var body: some View {
        NavigationStack {
            QRScannerView(onResult: onResult, onError: onError)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描设备二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
    }
}

private struct PageJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TransferStore.self) private var transfer
    @State private var page = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("页码范围 1 – \(max(1, transfer.pageCount))") {
                    TextField("页码", text: $page)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("跳转页码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        guard let value = Int(page), (1...transfer.pageCount).contains(value) else { return }
                        transfer.goToPage(value - 1)
                        dismiss()
                    }
                    .disabled(Int(page).map { !(1...transfer.pageCount).contains($0) } ?? true)
                }
            }
            .onAppear { page = String(transfer.currentPage + 1) }
        }
        .presentationDetents([.medium])
    }
}
