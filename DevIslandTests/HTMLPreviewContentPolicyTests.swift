import XCTest
@testable import DevIsland

final class HTMLPreviewContentPolicyTests: XCTestCase {
    func testDocumentDeniesExternalContentAndNavigationCapabilities() {
        let document = HTMLPreviewContentPolicy.document(
            containing: #"<img src="https://example.com/tracker.png"><form action="https://example.com">"#
        )

        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
        XCTAssertTrue(document.contains("base-uri 'none'"))
    }

    func testInputIsLimitedBeforeRendering() {
        let oversized = String(repeating: "a", count: HTMLPreviewContentPolicy.maximumInputLength) + "tail-marker"

        let limited = HTMLPreviewContentPolicy.limit(oversized)

        XCTAssertEqual(limited.count, HTMLPreviewContentPolicy.maximumInputLength)
        XCTAssertFalse(limited.contains("tail-marker"))
    }

    func testOnlyInitialMainFrameDocumentNavigationIsAllowed() {
        XCTAssertTrue(HTMLPreviewContentPolicy.isInitialDocumentNavigation(
            url: URL(string: "about:blank"),
            isMainFrame: true
        ))
        XCTAssertFalse(HTMLPreviewContentPolicy.isInitialDocumentNavigation(
            url: URL(string: "https://example.com"),
            isMainFrame: true
        ))
        XCTAssertFalse(HTMLPreviewContentPolicy.isInitialDocumentNavigation(
            url: URL(string: "about:blank"),
            isMainFrame: false
        ))
    }
}
