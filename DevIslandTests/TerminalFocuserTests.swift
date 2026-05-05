import XCTest
@testable import DevIsland

final class TerminalFocuserTests: XCTestCase {
    func testNormalizedAppName() {
        XCTAssertEqual(TerminalFocuser.normalizedAppName("iterm2"), "iTerm")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("iTerm.app"), "iTerm")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("Terminal"), "Terminal")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("apple terminal"), "Terminal")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("ghostty"), "Ghostty")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("warp"), "Warp")
        XCTAssertNil(TerminalFocuser.normalizedAppName("UnknownApp"))
        XCTAssertNil(TerminalFocuser.normalizedAppName(nil))
    }
}
