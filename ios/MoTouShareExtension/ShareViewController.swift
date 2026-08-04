import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在加入墨投…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await importItems() }
    }

    @MainActor
    private func importItems() async {
        do {
            let providers = extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .flatMap { $0.attachments ?? [] } ?? []

            guard !providers.isEmpty else {
                throw ShareError.noContent
            }

            var imported = 0
            for provider in providers {
                if try await importProvider(provider) {
                    imported += 1
                }
            }
            guard imported > 0 else { throw ShareError.unsupported }

            spinner.stopAnimating()
            statusLabel.text = "已加入墨投（\(imported) 项）\n打开墨投后会自动处理"
            try? await Task.sleep(for: .milliseconds(650))
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            spinner.stopAnimating()
            statusLabel.text = error.localizedDescription
            try? await Task.sleep(for: .seconds(1))
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func importProvider(_ provider: NSItemProvider) async throws -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(from: provider, type: .fileURL)
            try SharedInbox.enqueue(fileAt: url, preferredName: provider.suggestedName)
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await loadFile(from: provider, type: .image)
            defer { try? FileManager.default.removeItem(at: url) }
            try SharedInbox.enqueue(fileAt: url, preferredName: provider.suggestedName)
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(from: provider, type: .url)
            try SharedInbox.enqueue(text: url.absoluteString, kind: .url)
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let text = try await loadText(from: provider)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: SharedInboxItem.Kind = URL(string: trimmed)?.scheme?.hasPrefix("http") == true
                ? .url : .text
            try SharedInbox.enqueue(text: trimmed, kind: kind)
            return true
        }

        if let registered = provider.registeredTypeIdentifiers.first,
           let type = UTType(registered) {
            let url = try await loadFile(from: provider, type: type)
            defer { try? FileManager.default.removeItem(at: url) }
            try SharedInbox.enqueue(fileAt: url, preferredName: provider.suggestedName)
            return true
        }
        return false
    }

    private func loadFile(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    do {
                        let temporary = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: temporary)
                        continuation.resume(returning: temporary)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: ShareError.noContent)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let text = String(data: data, encoding: .utf8),
                          let url = URL(string: text) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ShareError.noContent)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                } else {
                    continuation.resume(throwing: ShareError.noContent)
                }
            }
        }
    }
}

private enum ShareError: LocalizedError {
    case noContent
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noContent:
            return "没有可投送的内容"
        case .unsupported:
            return "暂不支持这类分享内容"
        }
    }
}
