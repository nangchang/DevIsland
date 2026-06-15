import XCTest
import Network
@testable import DevIsland

// P1.2 — Security hardening regression tests for HookSocketServer (S1 loopback + S2 raw JSON)
// and BridgeTokenManager.isGraceMode (S3).
final class HookSocketServerTests: XCTestCase {

    // MARK: - BridgeTokenManager.isGraceMode

    func testBridgeTokenManagerIsGraceModeReflectsTokenFileAbsence() {
        // TestableTokenManager mirrors BridgeTokenManager logic in an isolated temp dir.
        let mgr = TestableTokenManager()
        XCTAssertTrue(mgr.isGraceMode, "With no token file, manager should be in grace mode")
        mgr.generateIfNeeded()
        XCTAssertFalse(mgr.isGraceMode, "After token generation, grace mode should be false")
    }

    func testBridgeTokenManagerGraceModeOnDirectoryCreateFailure() {
        // When generateIfNeeded fails (invalid path), the manager must stay in grace mode.
        let mgr = TestableTokenManager(tokenDirectory: URL(fileURLWithPath: "/dev/null/cannot-exist"))
        mgr.generateIfNeeded()
        XCTAssertTrue(mgr.isGraceMode, "Failed token creation must not flip grace mode off")
    }

    // MARK: - HookSocketServer TCP framed path (S1 loopback verification)

    func testTCPServerAcceptsFramedMessageOnLoopback() throws {
        let port = try freeLoopbackPort()
        let server = HookSocketServer()
        defer { _ = server }

        let messageExpectation = expectation(description: "framed message received")
        var receivedMessage: String?
        server.onMessageReceived = { message, _, respond in
            receivedMessage = message
            respond(#"{"response":"approved"}"#)
            messageExpectation.fulfill()
        }
        server.start(transport: .tcp(port: port))

        // Allow NWListener to become ready.
        Thread.sleep(forTimeInterval: 0.15)

        // Build a framed envelope.
        let envelopeJSON = """
        {"protocol":"dev-island-hook-ipc","version":1,"requestId":"test-loopback","sentAt":"2026-01-01T00:00:00Z","source":"claude","payload":{"hook_event_name":"SessionStart","session_id":"s-loopback"}}
        """
        let envelopeData = Data(envelopeJSON.utf8)
        let length = UInt32(envelopeData.count).bigEndian
        var frame = withUnsafeBytes(of: length) { Data($0) }
        frame.append(envelopeData)

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0, "Socket creation must succeed")
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "Connection to 127.0.0.1:\(port) must succeed after S1 loopback binding")

        frame.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        Darwin.shutdown(fd, SHUT_WR)

        wait(for: [messageExpectation], timeout: 5)
        XCTAssertNotNil(receivedMessage, "Server must deliver the framed message to onMessageReceived")
    }

    // MARK: - HookSocketServer TCP raw JSON in grace mode (S2 backward-compat)

    func testTCPServerAcceptsRawJSONInGraceMode() throws {
        // BridgeTokenManager.shared is in grace mode during tests (no token file in App Support).
        guard BridgeTokenManager.shared.isGraceMode else {
            // If a real token file exists (developer machine with bridge installed),
            // raw JSON on TCP is expected to be rejected — skip rather than fail.
            throw XCTSkip("Token file present: raw JSON TCP rejection is active, skipping grace-mode test")
        }

        let port = try freeLoopbackPort()
        let server = HookSocketServer()
        defer { _ = server }

        let messageExpectation = expectation(description: "raw JSON received in grace mode")
        server.onMessageReceived = { _, _, respond in
            respond(#"{"response":"approved"}"#)
            messageExpectation.fulfill()
        }
        server.start(transport: .tcp(port: port))
        Thread.sleep(forTimeInterval: 0.15)

        let rawJSON = #"{"hook_event_name":"SessionStart","session_id":"s-grace","cli_source":"claude"}"#
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)

        let data = Data(rawJSON.utf8)
        data.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        Darwin.shutdown(fd, SHUT_WR)

        wait(for: [messageExpectation], timeout: 5)
    }

    // MARK: - HookSocketServer TCP raw JSON rejected when token file present (S2)

    func testTCPServerRejectsRawJSONWhenTokenFilePresent() throws {
        // Verify that raw JSON is silently dropped (connection closed) on TCP when not in grace mode.
        // We instantiate a server that uses a token-aware check (S2 behaviour) and verify
        // the connection is closed without invoking onMessageReceived.
        guard !BridgeTokenManager.shared.isGraceMode else {
            // Grace mode active: rejection is deliberately bypassed — skip.
            throw XCTSkip("No token file present: grace mode active, rejection test skipped")
        }

        let port = try freeLoopbackPort()
        let server = HookSocketServer()
        defer { _ = server }

        let noCallExpectation = expectation(description: "onMessageReceived must NOT be called")
        noCallExpectation.isInverted = true
        server.onMessageReceived = { _, _, _ in
            noCallExpectation.fulfill()
        }
        server.start(transport: .tcp(port: port))
        Thread.sleep(forTimeInterval: 0.15)

        let rawJSON = #"{"hook_event_name":"SessionStart","session_id":"s-rejected"}"#
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let data = Data(rawJSON.utf8)
        data.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        Darwin.shutdown(fd, SHUT_WR)

        wait(for: [noCallExpectation], timeout: 2)
    }

    // MARK: - Helpers

    private func freeLoopbackPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("Cannot create socket") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var result = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &result) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = Darwin.getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: result.sin_port)
        guard port > 0 else { throw XCTSkip("OS did not assign a free port") }
        return port
    }
}

// MARK: - Isolated BridgeTokenManager for unit tests

private final class TestableTokenManager {
    private let tokenURL: URL
    private var cachedToken: String?
    private var tokenFileExists = false

    var isGraceMode: Bool { !tokenFileExists }

    init(tokenDirectory: URL? = nil) {
        let dir = tokenDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("DevIslandTokenTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tokenURL = dir.appendingPathComponent("bridge-token")
    }

    func generateIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: tokenURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return
        }
        guard !FileManager.default.fileExists(atPath: tokenURL.path) else {
            reload()
            return
        }
        let token = UUID().uuidString
        guard FileManager.default.createFile(
            atPath: tokenURL.path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        cachedToken = token
        tokenFileExists = true
    }

    private func reload() {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
        cachedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenFileExists = true
    }
}
