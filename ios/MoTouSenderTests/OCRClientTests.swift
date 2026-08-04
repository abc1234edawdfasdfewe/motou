import XCTest
@testable import MoTouSender

final class OCRClientTests: XCTestCase {
    func testJSONLCollectsAllMarkdownSections() throws {
        let jsonl = """
        {"result":{"layoutParsingResults":[{"markdown":{"text":"# 第一页"}},{"markdown":{"text":"段落 A"}}]}}

        {"ignored":true}
        {"result":{"layoutParsingResults":[{"markdown":{"text":"  段落 B  "}}]}}
        """

        XCTAssertEqual(
            try OCRClient.parseJSONLMarkdown(Data(jsonl.utf8)),
            "# 第一页\n\n段落 A\n\n段落 B"
        )
    }

    func testJSONLRejectsEmptyRecognition() {
        XCTAssertThrowsError(try OCRClient.parseJSONLMarkdown(Data("{\"result\":{}}".utf8))) { error in
            XCTAssertEqual(error as? OCRClientError, .emptyResult)
        }
    }
}
