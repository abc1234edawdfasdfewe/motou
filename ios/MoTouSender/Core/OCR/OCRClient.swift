import Foundation

struct OCRResult: Equatable, Sendable {
    var markdown: String
}

enum OCRClientError: LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidJobURL
    case invalidResponse
    case http(operation: String, status: Int, message: String)
    case missingJobID
    case missingResultURL
    case jobFailed(String)
    case timedOut
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "请先在设置中填写 OCR Token"
        case .invalidJobURL:
            "OCR 服务地址无效"
        case .invalidResponse:
            "OCR 服务返回异常"
        case let .http(operation, status, message):
            message.isEmpty
                ? "OCR \(operation)失败（HTTP \(status)）"
                : "OCR \(operation)失败（HTTP \(status)）：\(message)"
        case .missingJobID:
            "OCR 未返回 jobId"
        case .missingResultURL:
            "OCR 完成但未返回结果地址"
        case let .jobFailed(message):
            message.isEmpty ? "OCR 识别失败" : "OCR 识别失败：\(message)"
        case .timedOut:
            "OCR 识别超时"
        case .emptyResult:
            "OCR 未识别到文字"
        }
    }
}

/// PaddleOCR-VL asynchronous job client.
struct OCRClient: Sendable {
    static let defaultJobURL = URL(string: "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs")!

    private let session: URLSession
    private let jobURL: URL
    private let pollInterval: Duration
    private let clock = ContinuousClock()

    init(
        session: URLSession = .shared,
        jobURL: URL = Self.defaultJobURL,
        pollInterval: Duration = .seconds(2)
    ) {
        self.session = session
        self.jobURL = jobURL
        self.pollInterval = pollInterval
    }

    /// Submits an image, polls every two seconds and downloads the JSONL result.
    /// The complete operation is cancelled after 120 seconds by default.
    func recognize(
        token: String,
        model: String = "PaddleOCR-VL-1.6",
        imageData: Data,
        fileName: String = "photo.jpg",
        maxWait: Duration = .seconds(120)
    ) async throws -> OCRResult {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            throw OCRClientError.missingToken
        }

        return try await withThrowingTaskGroup(of: OCRResult.self) { group in
            group.addTask {
                let jobID = try await submit(
                    token: cleanToken,
                    model: model,
                    imageData: imageData,
                    fileName: fileName
                )
                let resultURL = try await poll(token: cleanToken, jobID: jobID)
                let markdown = try await fetchMarkdown(from: resultURL)
                return OCRResult(markdown: markdown)
            }
            group.addTask {
                try await clock.sleep(for: maxWait)
                throw OCRClientError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw OCRClientError.invalidResponse
            }
            return result
        }
    }

    static func parseJSONLMarkdown(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OCRClientError.invalidResponse
        }

        var sections: [String] = []
        text.enumerateLines { line, _ in
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLine.isEmpty,
                  let lineData = cleanLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let layouts = result["layoutParsingResults"] as? [[String: Any]]
            else { return }

            for layout in layouts {
                guard let markdown = layout["markdown"] as? [String: Any],
                      let value = markdown["text"] as? String
                else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sections.append(trimmed)
                }
            }
        }

        guard !sections.isEmpty else {
            throw OCRClientError.emptyResult
        }
        return sections.joined(separator: "\n\n")
    }

    private func submit(
        token: String,
        model: String,
        imageData: Data,
        fileName: String
    ) async throws -> String {
        let boundary = "----motou\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: jobURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            model: model,
            imageData: imageData,
            fileName: fileName
        )

        let data = try await responseData(for: request, operation: "提交")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any]
        else {
            throw OCRClientError.invalidResponse
        }
        guard let jobID = payload["jobId"] as? String, !jobID.isEmpty else {
            throw OCRClientError.missingJobID
        }
        return jobID
    }

    private func poll(token: String, jobID: String) async throws -> URL {
        let statusURL = jobURL.appendingPathComponent(jobID)
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: statusURL, timeoutInterval: 20)
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let data = try await responseData(for: request, operation: "查询")
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["data"] as? [String: Any]
            else {
                throw OCRClientError.invalidResponse
            }

            let state = (payload["state"] as? String)?.lowercased() ?? ""
            switch state {
            case "done", "success", "succeeded":
                guard let result = payload["resultUrl"] as? [String: Any],
                      let value = result["jsonUrl"] as? String,
                      let url = URL(string: value)
                else {
                    throw OCRClientError.missingResultURL
                }
                return url
            case "failed", "failure", "error":
                let message = (payload["errorMsg"] as? String)
                    ?? (payload["message"] as? String)
                    ?? ""
                throw OCRClientError.jobFailed(message)
            default:
                try await clock.sleep(for: pollInterval)
            }
        }
    }

    private func fetchMarkdown(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json, application/x-ndjson, text/plain", forHTTPHeaderField: "Accept")
        let data = try await responseData(for: request, operation: "结果下载")
        return try Self.parseJSONLMarkdown(data)
    }

    private func responseData(for request: URLRequest, operation: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: Data(data.prefix(240)), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OCRClientError.http(operation: operation, status: http.statusCode, message: body)
        }
        return data
    }

    private func multipartBody(
        boundary: String,
        model: String,
        imageData: Data,
        fileName: String
    ) -> Data {
        let optionalPayload = "{\"useDocOrientationClassify\":false,\"useDocUnwarping\":false,\"useChartRecognition\":false}"
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(model.trimmingCharacters(in: .whitespacesAndNewlines))\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"optionalPayload\"\r\n\r\n")
        body.appendUTF8("\(optionalPayload)\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName(fileName))\"\r\n")
        body.appendUTF8("Content-Type: \(contentType(for: fileName))\r\n\r\n")
        body.append(imageData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    private func safeFileName(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    private func contentType(for fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "png": "image/png"
        case "heic", "heif": "image/heic"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
