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
        XCTAssertEqual(TerminalFocuser.normalizedAppName("cmux"), "cmux")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("wezterm"), "WezTerm")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("wez term"), "WezTerm")
        XCTAssertEqual(TerminalFocuser.normalizedAppName("wezterm.app"), "WezTerm")
        XCTAssertNil(TerminalFocuser.normalizedAppName("UnknownApp"))
        XCTAssertNil(TerminalFocuser.normalizedAppName(nil))
    }

    func testWezTermCLIURLUsesBundledCLI() {
        let appURL = URL(fileURLWithPath: "/Applications/WezTerm.app")
        XCTAssertEqual(
            TerminalFocuser.wezTermCLIURL(for: appURL).path,
            "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        )
    }

    func testWezTermActivatePaneArguments() {
        XCTAssertEqual(
            TerminalFocuser.wezTermActivatePaneArguments(paneId: 42),
            ["cli", "activate-pane", "--pane-id", "42"]
        )
    }

    func testWezTermStartNewTabArguments() {
        XCTAssertEqual(
            TerminalFocuser.wezTermStartNewTabArguments(command: "cd /tmp && codex"),
            ["start", "--new-tab", "--", "/bin/zsh", "-lic", "cd /tmp && codex; exec /bin/zsh -l"]
        )
        XCTAssertEqual(
            TerminalFocuser.wezTermStartNewTabArguments(command: ""),
            ["start", "--new-tab", "--", "/bin/zsh", "-l"]
        )
    }

    func testWezTermSpawnTabArguments() {
        XCTAssertEqual(
            TerminalFocuser.wezTermSpawnTabArguments(command: "cd /tmp && codex", windowId: 7),
            ["cli", "spawn", "--window-id", "7", "--", "/bin/zsh", "-lic", "cd /tmp && codex; exec /bin/zsh -l"]
        )
        XCTAssertEqual(
            TerminalFocuser.wezTermSpawnTabArguments(command: "", windowId: "8"),
            ["cli", "spawn", "--window-id", "8", "--", "/bin/zsh", "-l"]
        )
    }

    func testWezTermSocketEnvironment() {
        let socketURL = URL(fileURLWithPath: "/Users/me/.local/share/wezterm/gui-sock-123")
        XCTAssertEqual(
            TerminalFocuser.wezTermSocketEnvironment(socketURL: socketURL),
            ["WEZTERM_UNIX_SOCKET": "/Users/me/.local/share/wezterm/gui-sock-123"]
        )
    }

    func testWezTermPreferredSocketEnvironmentReturnsNilWithoutCandidates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalFocuserTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(TerminalFocuser.wezTermSocketCandidates(in: directory).isEmpty)
        XCTAssertNil(TerminalFocuser.wezTermPreferredSocketEnvironment(in: directory))
    }

    func testWezTermPaneIDMatchesFullTTYOrTTYName() {
        let panesJSON = """
        [
          { "pane_id": 2, "tty_name": "/dev/ttys010" },
          { "pane_id": 3, "tty_name": "/dev/ttys001" }
        ]
        """

        XCTAssertEqual(TerminalFocuser.wezTermPaneID(in: panesJSON, matchingTTY: "/dev/ttys001"), "3")
        XCTAssertEqual(TerminalFocuser.wezTermPaneID(in: panesJSON, matchingTTY: "ttys010"), "2")
        XCTAssertNil(TerminalFocuser.wezTermPaneID(in: panesJSON, matchingTTY: "/dev/ttys999"))
    }

    func testWezTermActiveWindowIDPrefersActivePane() {
        let panesJSON = """
        [
          { "window_id": 4, "pane_id": 2, "is_active": false },
          { "window_id": 9, "pane_id": 3, "is_active": true }
        ]
        """

        XCTAssertEqual(TerminalFocuser.wezTermActiveWindowID(in: panesJSON), "9")
    }

    func testITermManagerNavigationInputsUseLegacySequence() {
        let inputs = TerminalFocuser.iTermManagerNavigationInputs(managerTitle: #"Quote " and \ slash"#)

        XCTAssertEqual(inputs[0], "(ASCII character 17)")
        XCTAssertEqual(inputs[1], "\"/\"")
        XCTAssertEqual(inputs[2], #""Quote \" and \\ slash""#)
        XCTAssertEqual(inputs[3], "(ASCII character 13)")
    }
}
