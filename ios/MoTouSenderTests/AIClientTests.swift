import XCTest
@testable import MoTouSender

final class AIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testEndpointAddsVersionOnlyWhenNeeded() throws {
        XCTAssertEqual(
            try AIClient.endpoint(baseURL: "https://api.deepseek.com/", path: "chat/completions").absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
        XCTAssertEqual(
            try AIClient.endpoint(baseURL: "https://api.moonshot.cn/v1", path: "models").absoluteString,
            "https://api.moonshot.cn/v1/models"
        )
        XCTAssertEqual(
            try AIClient.endpoint(baseURL: "https://ark.cn-beijing.volces.com/api/v3", path: "models").absoluteString,
            "https://ark.cn-beijing.volces.com/api/v3/models"
        )
    }

    func testListModelsAndChatUseOpenAIShape() async throws {
        var requests: [URLRequest] = []
        URLProtocolStub.handler = { request in
            requests.append(request)
            if request.url?.path.hasSuffix("/models") == true {
                return (200, #"{"data":[{"id":"model-a"},{"id":"model-b"}]}"#.data(using: .utf8)!)
            }
            return (200, #"{"choices":[{"message":{"content":"  回答  "}}]}"#.data(using: .utf8)!)
        }
        let client = AIClient(session: makeSession())
        let configuration = LLMConfiguration(
            id: "ark",
            name: "Ark",
            baseURL: "https://example.com/api/v3",
            apiKey: "secret",
            model: "model-a"
        )

        let models = try await client.listModels(for: configuration)
        let reply = try await client.chat(configuration: configuration, messages: [.user("你好")])
        XCTAssertEqual(models, ["model-a", "model-b"])
        XCTAssertEqual(reply, "回答")
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v3/models", "/api/v3/chat/completions"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })

        let body = try requestBodyData(try XCTUnwrap(requests.last))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "model-a")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testConnectionFallsBackToMinimalChat() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/models") == true {
                return (404, #"{"error":{"message":"not supported"}}"#.data(using: .utf8)!)
            }
            return (200, #"{"choices":[{"message":{"content":"ok"}}]}"#.data(using: .utf8)!)
        }
        let client = AIClient(session: makeSession())
        let configuration = LLMConfiguration(
            id: "custom",
            name: "Custom",
            baseURL: "https://example.com",
            apiKey: "key",
            model: "chat-model"
        )

        let result = try await client.testConnection(for: configuration)
        XCTAssertEqual(result, AIConnectionTest(models: [], usedChatFallback: true))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
