import CoreFoundation
import Foundation
import Observation

enum TransferStoreError: LocalizedError {
    case notConnected
    case invalidURL
    case invalidTextEncoding
    case downloadFailed
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "请先连接墨投设备"
        case .invalidURL:
            "仅支持 http 或 https 网址"
        case .invalidTextEncoding:
            "无法识别文件的文字编码"
        case .downloadFailed:
            "网页抓取失败"
        case .responseTooLarge:
            "网页内容过大"
        }
    }
}

@MainActor
@Observable
final class TransferStore {
    private(set) var activity: TransferActivity = .idle
    private(set) var progress: TransferProgress?
    private(set) var currentContentID: String?
    private(set) var currentTitle = ""
    private(set) var currentPage = 0
    private(set) var pageCount = 0

    var canGoPrevious: Bool { currentContentID != nil && currentPage > 0 }
    var canGoNext: Bool { currentContentID != nil && currentPage + 1 < pageCount }
    var isBusy: Bool {
        switch activity {
        case .processing, .sending: true
        case .idle, .failed: false
        }
    }

    @ObservationIgnored private let connection: ConnectionStore
    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var activeToken: UUID?
    @ObservationIgnored private var bitmapSource: (any BitmapPageSource)?
    @ObservationIgnored private var bitmapConfiguration: BitmapRenderConfiguration?
    @ObservationIgnored private var sentPages: Set<Int> = []
    @ObservationIgnored private var mode: ContentMode?
    @ObservationIgnored private var currentBook: BookItem?

    convenience init() {
        let persistence = PersistenceStore()
        self.init(
            connection: ConnectionStore(persistence: persistence),
            persistence: persistence
        )
    }

    convenience init(connection: ConnectionStore) {
        self.init(connection: connection, persistence: PersistenceStore())
    }

    init(connection: ConnectionStore, persistence: PersistenceStore) {
        self.connection = connection
        self.persistence = persistence
    }

    deinit {
        operationTask?.cancel()
        prefetchTask?.cancel()
        navigationTask?.cancel()
    }

    // MARK: - Reflowable content

    func sendText(
        _ text: String,
        title: String? = nil,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendParsedDocument(status: "整理文字中…", completion: completion) {
            try PlainTextDocumentParser.parse(text, suggestedTitle: title)
        }
    }

    func sendMarkdown(_ markdown: String, title: String? = nil) {
        sendParsedDocument(status: "解析 Markdown 中…") {
            try MarkdownDocumentParser.parse(markdown, suggestedTitle: title)
        }
    }

    func sendHTML(_ html: String, title: String, recordHistory: Bool = true) {
        sendParsedDocument(status: "清理网页内容中…", recordHistory: recordHistory) {
            let body = SafeHTML.sanitize(html)
            guard !SafeHTML.visibleText(from: body).isEmpty else {
                throw DocumentParsingError.emptyDocument
            }
            return ParsedTextDocument(title: title, body: body)
        }
    }

    func resend(_ item: HistoryItem) {
        sendHTML(item.body, title: item.title, recordHistory: false)
    }

    func sendURL(
        _ url: URL,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let token = beginOperation(status: "抓取网页正文中…") else {
            completion?(.failure(TransferStoreError.notConnected))
            return
        }
        let proxyURL = Self.fetchProxyURL(
            host: connection.currentHost,
            port: connection.currentPort
        )
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await Self.fetchArticle(from: url, proxyURL: proxyURL)
                try Task.checkCancellation()
                try await self.publish(document, token: token, recordHistory: true)
                completion?(.success(()))
            } catch is CancellationError {
                self.finishCancellation(for: token)
                completion?(.failure(CancellationError()))
            } catch {
                self.fail(error, token: token)
                completion?(.failure(error))
            }
        }
    }

    func sendURL(
        _ text: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            activity = .failed(TransferStoreError.invalidURL.localizedDescription)
            completion?(.failure(TransferStoreError.invalidURL))
            return
        }
        sendURL(url, completion: completion)
    }

    // MARK: - Bitmap content

    /// Data is preferred over UIImage so decoding and orientation correction stay off the main actor.
    func sendImage(data: Data, name: String = "图片") {
        sendImages([(name: name, data: data)], title: name)
    }

    func sendImages(_ images: [(name: String, data: Data)], title: String = "图片") {
        let values = images.map { NamedImageData(name: $0.name, data: $0.data) }
        guard let token = beginOperation(status: "处理图片中…") else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await Self.runDetached {
                    try ImageBitmapDocument(images: values, sortNaturally: true)
                }
                try Task.checkCancellation()
                try await self.beginBitmap(
                    source: source,
                    title: Self.displayTitle(for: title),
                    token: token,
                    book: nil
                )
            } catch is CancellationError {
                self.finishCancellation(for: token)
            } catch {
                self.fail(error, token: token)
            }
        }
    }

    /// Routes reflowable documents, ebooks, Office files, images, PDF and CBZ.
    func sendFile(
        url: URL,
        displayName: String? = nil,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendFile(
            url: url,
            reopening: nil,
            displayName: displayName,
            completion: completion
        )
    }

    func reopen(_ book: BookItem) {
        do {
            let result = try SecurityScopedBookmark.resolveRefreshingIfNeeded(book.bookmark)
            var refreshed = book
            if result.resolved.isStale {
                refreshed.bookmark = result.bookmark
                refreshed.openedAt = Date()
                persistence.upsertBook(refreshed)
            }
            sendFile(
                url: result.resolved.url,
                reopening: refreshed,
                displayName: refreshed.title,
                completion: nil
            )
        } catch {
            if let managedFileName = book.managedFileName,
               let managedURL = try? ManagedImportStore.url(for: managedFileName),
               FileManager.default.fileExists(atPath: managedURL.path) {
                sendFile(
                    url: managedURL,
                    reopening: book,
                    displayName: book.title,
                    completion: nil
                )
                return
            }
            removeBook(book)
            activity = .failed("原文件已移动或无权访问，已从书架移除")
        }
    }

    func removeBook(_ book: BookItem) {
        if currentBook?.id == book.id {
            currentBook = nil
        }
        persistence.removeBook(id: book.id)
    }

    // MARK: - Page control and device feedback

    func previousPage() {
        goToPage(currentPage - 1)
    }

    func nextPage() {
        goToPage(currentPage + 1)
    }

    func goToPage(_ requestedPage: Int) {
        guard
            let contentID = currentContentID,
            let token = activeToken,
            pageCount > 0
        else { return }
        let page = min(max(0, requestedPage), pageCount - 1)
        guard page != currentPage || mode == .bitmap else { return }

        currentPage = page
        updateProgress()
        updateBookProgress()
        if mode == .bitmap {
            schedulePrefetch(around: page, token: token)
        }

        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connection.sendJSON(
                    NavigationMessage(type: "nav", id: contentID, page: page)
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.activeToken == token else { return }
                self.activity = .failed(error.localizedDescription)
            }
        }
    }

    /// Feed ConnectionStore.pageState here whenever its observation token changes.
    func handle(_ state: PageState) {
        guard
            let contentID = currentContentID,
            state.contentID.isEmpty || state.contentID == contentID,
            let token = activeToken
        else { return }

        if let pages = state.pages, mode == .html {
            pageCount = max(1, pages)
        }
        if pageCount > 0 {
            currentPage = min(max(0, state.page), pageCount - 1)
        } else {
            currentPage = max(0, state.page)
        }
        updateProgress()
        updateBookProgress()

        switch state.kind {
        case .navigationRequest:
            if mode == .bitmap {
                // A nav request means the receiver no longer has this page, even
                // if it was sent earlier and still appears in our local cache set.
                sentPages.remove(currentPage)
                schedulePrefetch(around: currentPage, token: token)
            }
        case .rendered:
            if mode == .bitmap {
                schedulePrefetch(around: currentPage, token: token)
            }
        case .state:
            break
        }
    }

    func cancel() {
        cancelTasks()
        activeToken = nil
        bitmapSource = nil
        bitmapConfiguration = nil
        sentPages.removeAll()
        activity = .idle
    }

    // MARK: - Operations

    private func sendParsedDocument(
        status: String,
        recordHistory: Bool = true,
        completion: ((Result<Void, Error>) -> Void)? = nil,
        parser: @escaping @Sendable () throws -> ParsedTextDocument
    ) {
        guard let token = beginOperation(status: status) else {
            completion?(.failure(TransferStoreError.notConnected))
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await Self.runDetached(parser)
                try Task.checkCancellation()
                try await self.publish(document, token: token, recordHistory: recordHistory)
                completion?(.success(()))
            } catch is CancellationError {
                self.finishCancellation(for: token)
                completion?(.failure(CancellationError()))
            } catch {
                self.fail(error, token: token)
                completion?(.failure(error))
            }
        }
    }

    private func publish(
        _ document: ParsedTextDocument,
        token: UUID,
        recordHistory: Bool
    ) async throws {
        guard activeToken == token else { throw CancellationError() }
        let document = try ReflowDocumentLimits.validate(document)
        let id = Self.newContentID()
        activity = .sending("正在投送…")
        try await connection.sendJSON(
            HTMLMessage(type: "html", id: id, title: document.title, body: document.body)
        )
        try Task.checkCancellation()
        guard activeToken == token else { throw CancellationError() }

        currentContentID = id
        currentTitle = document.title
        currentPage = 0
        pageCount = 1
        mode = .html
        progress = TransferProgress(
            contentID: id,
            title: document.title,
            currentPage: 0,
            pageCount: 1,
            unit: "页"
        )
        if recordHistory {
            persistence.addHistory(title: document.title, body: document.body)
        }
        operationTask = nil
        activity = .idle
    }

    private func sendFile(
        url: URL,
        reopening book: BookItem?,
        displayName: String?,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        let managedFileName = ManagedImportStore.fileNameIfManaged(url)
        guard let token = beginOperation(status: "读取文件中…") else {
            if book == nil { ManagedImportStore.remove(fileNamed: managedFileName) }
            completion?(.failure(TransferStoreError.notConnected))
            return
        }
        // Start the security scope synchronously while the document-picker
        // grant is still active, then keep it alive through detached parsing.
        // Starting access only after hopping to an async worker can lose the
        // provider's short-lived authorization (notably iCloud Drive .md files).
        let accessLease = SecurityScopedFileLease(url: url)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await Self.runDetached {
                    _ = accessLease
                    return try Self.prepareFile(at: url, suggestedName: displayName)
                }
                try Task.checkCancellation()
                switch prepared {
                case let .text(document):
                    try await self.publish(document, token: token, recordHistory: true)
                    if book == nil { ManagedImportStore.remove(fileNamed: managedFileName) }
                case let .bitmap(source, title, format):
                    let savedBook = self.makeBook(
                        url: url,
                        title: title,
                        format: format,
                        pageCount: source.pageCount,
                        reopening: book,
                        managedFileName: managedFileName
                    )
                    try await self.beginBitmap(
                        source: source,
                        title: title,
                        token: token,
                        book: savedBook
                    )
                    if savedBook == nil, book == nil {
                        ManagedImportStore.remove(fileNamed: managedFileName)
                    }
                }
                completion?(.success(()))
            } catch is CancellationError {
                if book == nil { ManagedImportStore.remove(fileNamed: managedFileName) }
                self.finishCancellation(for: token)
                completion?(.failure(CancellationError()))
            } catch {
                if book == nil {
                    ManagedImportStore.remove(fileNamed: managedFileName)
                }
                self.fail(error, token: token)
                completion?(.failure(error))
            }
        }
    }

    private func beginBitmap(
        source: any BitmapPageSource,
        title: String,
        token: UUID,
        book: BookItem?
    ) async throws {
        guard activeToken == token else { throw CancellationError() }
        guard let capabilities = connection.capabilities else {
            throw TransferStoreError.notConnected
        }
        let id = Self.newContentID()
        let configuration = BitmapRenderConfiguration(
            width: capabilities.screen.width,
            height: capabilities.screen.height,
            grayscaleLevels: min(16, max(2, capabilities.grayscale))
        )

        activity = .sending("准备位图文档…")
        try await connection.sendJSON(
            ContentBeginMessage(
                type: "content.begin",
                id: id,
                kind: "bitmap",
                title: title,
                pageCount: source.pageCount,
                live: false
            )
        )
        try Task.checkCancellation()
        guard activeToken == token else { throw CancellationError() }

        currentContentID = id
        currentTitle = title
        currentPage = min(max(0, book?.lastPage ?? 0), max(0, source.pageCount - 1))
        pageCount = source.pageCount
        mode = .bitmap
        bitmapSource = source
        bitmapConfiguration = configuration
        currentBook = book
        sentPages.removeAll()
        progress = TransferProgress(
            contentID: id,
            title: title,
            currentPage: currentPage,
            pageCount: source.pageCount,
            unit: "页"
        )

        // Do not report the transfer as complete until the receiver has the
        // first visible bitmap page. This keeps Share Extension items
        // retryable when rendering or the binary WebSocket send fails.
        try await renderAndSendBitmapPage(
            currentPage,
            source: source,
            configuration: configuration,
            contentID: id,
            token: token
        )
        if currentPage > 0 {
            activity = .sending("跳转到第 \(currentPage + 1) 页…")
            try await connection.sendJSON(
                NavigationMessage(type: "nav", id: id, page: currentPage)
            )
            try Task.checkCancellation()
            guard activeToken == token else { throw CancellationError() }
        }
        if let book {
            persistence.upsertBook(book)
        }
        operationTask = nil
        activity = .idle
        schedulePrefetch(around: currentPage, token: token)
    }

    /// The receiver's cache contract is exactly current-1 ... current+2.
    private func schedulePrefetch(around center: Int, token: UUID) {
        guard
            activeToken == token,
            mode == .bitmap,
            let source = bitmapSource,
            let configuration = bitmapConfiguration,
            let id = currentContentID,
            pageCount > 0
        else { return }

        prefetchTask?.cancel()
        let lower = max(0, center - 1)
        let upper = min(pageCount - 1, center + 2)
        let window = Array(lower...upper)
        // The Android receiver evicts pages outside current ±3. Mirror that
        // contract so an old "sent" marker never prevents a later resend.
        sentPages = Set(sentPages.filter { abs($0 - center) <= 3 })
        let priorityOrder = [center, center + 1, center - 1, center + 2]
            .filter { window.contains($0) }
        let remaining = window.filter { !priorityOrder.contains($0) }
        let pages = priorityOrder + remaining

        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                for index in pages where !self.sentPages.contains(index) {
                    try await self.renderAndSendBitmapPage(
                        index,
                        source: source,
                        configuration: configuration,
                        contentID: id,
                        token: token
                    )
                }
                guard self.activeToken == token else { return }
                self.prefetchTask = nil
                self.activity = .idle
            } catch is CancellationError {
                return
            } catch {
                self.fail(error, token: token)
            }
        }
    }

    private func renderAndSendBitmapPage(
        _ index: Int,
        source: any BitmapPageSource,
        configuration: BitmapRenderConfiguration,
        contentID: String,
        token: UUID
    ) async throws {
        try Task.checkCancellation()
        guard activeToken == token, currentContentID == contentID else {
            throw CancellationError()
        }
        activity = .processing("渲染第 \(index + 1) 页…")
        let data = try await Self.runDetached {
            try source.renderPage(at: index, configuration: configuration)
        }
        try Task.checkCancellation()
        guard activeToken == token, currentContentID == contentID else {
            throw CancellationError()
        }
        activity = .sending("发送第 \(index + 1) 页…")
        try await connection.sendBitmapPage(
            metadata: BitmapPageMessage(
                type: "page",
                id: contentID,
                index: index,
                format: "png"
            ),
            binary: data
        )
        try Task.checkCancellation()
        guard activeToken == token, currentContentID == contentID else {
            throw CancellationError()
        }
        sentPages.insert(index)
    }

    private func beginOperation(status: String) -> UUID? {
        guard connection.phase == .ready else {
            activity = .failed(TransferStoreError.notConnected.localizedDescription)
            return nil
        }
        cancelTasks()
        let token = UUID()
        activeToken = token
        bitmapSource = nil
        bitmapConfiguration = nil
        sentPages.removeAll()
        mode = nil
        currentBook = nil
        activity = .processing(status)
        return token
    }

    private func cancelTasks() {
        operationTask?.cancel()
        operationTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        navigationTask?.cancel()
        navigationTask = nil
    }

    private func fail(_ error: Error, token: UUID) {
        guard activeToken == token else { return }
        operationTask = nil
        prefetchTask = nil
        activity = .failed(error.localizedDescription)
    }

    private func finishCancellation(for token: UUID) {
        guard activeToken == token else { return }
        operationTask = nil
        prefetchTask = nil
        activity = .idle
    }

    private func updateProgress() {
        guard let contentID = currentContentID else { return }
        progress = TransferProgress(
            contentID: contentID,
            title: currentTitle,
            currentPage: currentPage,
            pageCount: max(1, pageCount),
            unit: "页"
        )
    }

    private func updateBookProgress() {
        guard var book = currentBook else { return }
        book.lastPage = currentPage
        book.openedAt = Date()
        currentBook = book
        persistence.updateBookProgress(id: book.id, lastPage: currentPage, openedAt: book.openedAt)
    }

    private func makeBook(
        url: URL,
        title: String,
        format: BookItem.Format?,
        pageCount: Int,
        reopening: BookItem?,
        managedFileName: String?
    ) -> BookItem? {
        guard let format else { return nil }
        let bookmark: Data
        do {
            bookmark = try SecurityScopedBookmark.create(for: url)
        } catch {
            // A reopened bookmark is still valid even if refreshing is denied.
            guard let reopening else { return nil }
            bookmark = reopening.bookmark
        }
        return BookItem(
            id: reopening?.id ?? UUID(),
            title: title,
            format: format,
            bookmark: bookmark,
            pageCount: pageCount,
            lastPage: min(reopening?.lastPage ?? 0, max(0, pageCount - 1)),
            openedAt: Date(),
            managedFileName: reopening?.managedFileName ?? managedFileName
        )
    }

    // MARK: - Detached parsing helpers

    nonisolated private static func runDetached<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func prepareFile(
        at url: URL,
        suggestedName: String?
    ) throws -> PreparedFile {
        let maximumFileMegabytes = 512
        let reportedFileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let fileSize = reportedFileSize,
           fileSize > maximumFileMegabytes * 1_024 * 1_024 {
            throw DocumentParsingError.fileTooLarge(maximumMegabytes: maximumFileMegabytes)
        }
        if Task.isCancelled { throw CancellationError() }
        let cleanSuggestedName = suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = cleanSuggestedName?.isEmpty == false
            ? cleanSuggestedName!
            : url.lastPathComponent
        let fileExtension = DocumentImportTypes.preferredExtension(
            for: url,
            suggestedName: effectiveName
        ) ?? ""
        let title = displayTitle(for: effectiveName)
        if fileExtension == "pdf" {
            return .bitmap(
                source: try PDFBitmapDocument(url: url),
                title: title,
                format: .pdf
            )
        }
        if fileExtension == "cbz" || fileExtension == "zip" {
            return .bitmap(
                source: try CBZBitmapDocument(url: url),
                title: title,
                format: .cbz
            )
        }
        guard DocumentImportTypes.supportedExtensions.contains(fileExtension) else {
            throw DocumentParsingError.unsupportedFile(fileExtension.isEmpty ? "未知格式" : fileExtension)
        }
        let isImage = DocumentImportTypes.imageExtensions.contains(fileExtension)
        if !isImage, let fileSize = reportedFileSize {
            try ReflowDocumentLimits.validateInputByteCount(fileSize)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DocumentParsingError.unreadableFile
        }
        if Task.isCancelled { throw CancellationError() }
        if isImage {
            guard data.count <= maximumFileMegabytes * 1_024 * 1_024 else {
                throw DocumentParsingError.fileTooLarge(maximumMegabytes: maximumFileMegabytes)
            }
        } else {
            // File-provider metadata can be absent or stale; always enforce
            // the format-level limit again against the bytes actually read.
            try ReflowDocumentLimits.validateInputByteCount(data.count)
        }
        switch fileExtension {
        case "txt", "log", "csv", "json", "xml", "yaml", "yml", "ini", "conf":
            let text = try decodeText(data)
            return .text(try ReflowDocumentLimits.validate(
                PlainTextDocumentParser.parse(text, suggestedTitle: title)
            ))
        case "md", "markdown":
            let text = try decodeText(data)
            return .text(try ReflowDocumentLimits.validate(
                MarkdownDocumentParser.parse(text, suggestedTitle: title)
            ))
        case "html", "htm":
            let text = try decodeText(data)
            return .text(try ReflowDocumentLimits.validate(WebArticleExtractor.extract(from: text)))
        case "docx":
            if CompoundFile.hasSignature(data) {
                throw DocumentParsingError.encryptedDocument("Word")
            }
            return .text(try ReflowDocumentLimits.validate(
                DocxExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "doc":
            return .text(try ReflowDocumentLimits.validate(
                LegacyWordExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "pptx":
            return .text(try ReflowDocumentLimits.validate(
                PPTXExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "ppt":
            return .text(try ReflowDocumentLimits.validate(
                LegacyPowerPointExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "xlsx":
            return .text(try ReflowDocumentLimits.validate(
                XLSXExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "xls":
            return .text(try ReflowDocumentLimits.validate(
                LegacyExcelExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "epub":
            return .text(try ReflowDocumentLimits.validate(
                EPUBExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "mobi", "azw", "azw3":
            return .text(try ReflowDocumentLimits.validate(
                KindleBookExtractor.extract(from: data, suggestedTitle: title)
            ))
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff":
            return .bitmap(
                source: try ImageBitmapDocument(
                    images: [NamedImageData(name: url.lastPathComponent, data: data)],
                    sortNaturally: false
                ),
                title: title,
                format: nil
            )
        default:
            preconditionFailure("validated file extension must be routed")
        }
    }

    nonisolated private static func fetchArticle(
        from url: URL,
        proxyURL: URL?
    ) async throws -> ParsedTextDocument {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TransferStoreError.invalidURL
        }
        let result: (Data, URLResponse)
        if let proxyURL {
            do {
                result = try await fetchArticleThroughDevice(url, proxyURL: proxyURL)
            } catch {
                try Task.checkCancellation()
                result = try await fetchArticleDirectly(url)
            }
        } else {
            result = try await fetchArticleDirectly(url)
        }
        let (data, response) = result
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw TransferStoreError.downloadFailed
        }
        guard data.count <= 12 * 1_024 * 1_024 else {
            throw TransferStoreError.responseTooLarge
        }
        let html = decodeWebText(data, encodingName: response.textEncodingName)
        guard let html else { throw TransferStoreError.invalidTextEncoding }
        return try WebArticleExtractor.extract(from: html, sourceURL: url)
    }

    nonisolated private static func fetchArticleThroughDevice(
        _ sourceURL: URL,
        proxyURL: URL
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": sourceURL.absoluteString
        ])
        let result = try await URLSession.shared.data(for: request)
        guard
            let response = result.1 as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw TransferStoreError.downloadFailed
        }
        return result
    }

    nonisolated private static func fetchArticleDirectly(
        _ url: URL
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile",
            forHTTPHeaderField: "User-Agent"
        )
        return try await URLSession.shared.data(for: request)
    }

    nonisolated private static func fetchProxyURL(host: String?, port: Int?) -> URL? {
        guard let host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port ?? 8383
        components.path = "/fetch"
        return components.url
    }

    nonisolated private static func decodeText(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) { return value }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let value = String(data: data, encoding: .utf32LittleEndian) { return value }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let value = String(data: data, encoding: .utf32BigEndian) { return value }
        if data.starts(with: [0xFF, 0xFE]), let value = String(data: data, encoding: .utf16LittleEndian) {
            return value
        }
        if data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16BigEndian) {
            return value
        }
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .unicode) { return value }
        if let value = String(data: data, encoding: .windowsCP1252) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        throw TransferStoreError.invalidTextEncoding
    }

    nonisolated private static func decodeWebText(_ data: Data, encodingName: String?) -> String? {
        if let encodingName {
            let lowered = encodingName.lowercased()
            if lowered.contains("gb") {
                let gb18030 = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                )
                if let value = String(data: data, encoding: gb18030) { return value }
            }
            if lowered.contains("big5") {
                let big5 = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.big5.rawValue)
                    )
                )
                if let value = String(data: data, encoding: big5) { return value }
            }
            if lowered.contains("1252"), let value = String(data: data, encoding: .windowsCP1252) {
                return value
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated private static func displayTitle(for name: String) -> String {
        let value = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名内容" : value
    }

    nonisolated private static func newContentID() -> String {
        "c-\(UUID().uuidString.lowercased())"
    }
}

private enum ContentMode {
    case html
    case bitmap
}

private enum PreparedFile: Sendable {
    case text(ParsedTextDocument)
    case bitmap(source: any BitmapPageSource, title: String, format: BookItem.Format?)
}

private struct HTMLMessage: Encodable, Sendable {
    var type: String
    var id: String
    var title: String
    var body: String
}

private struct ContentBeginMessage: Encodable, Sendable {
    var type: String
    var id: String
    var kind: String
    var title: String
    var pageCount: Int
    var live: Bool
}

private struct BitmapPageMessage: Encodable, Sendable {
    var type: String
    var id: String
    var index: Int
    var format: String
}

private struct NavigationMessage: Encodable, Sendable {
    var type: String
    var id: String
    var page: Int
}
