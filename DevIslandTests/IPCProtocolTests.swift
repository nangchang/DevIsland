import XCTest
@testable import DevIsland

// MARK: - AnyJSON Tests

final class AnyJSONTests: XCTestCase {
    func testRoundTripPrimitives() throws {
        let cases: [AnyJSON] = [.null, .bool(true), .bool(false), .int(42), .double(3.14), .string("hello")]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AnyJSON.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    func testRoundTripObject() throws {
        let obj = AnyJSON.object(["key": .string("value"), "n": .int(1)])
        let data = try JSONEncoder().encode(obj)
        let decoded = try JSONDecoder().decode(AnyJSON.self, from: data)
        XCTAssertEqual(obj, decoded)
    }

    func testRawValue() {
        let obj = AnyJSON.object(["a": .bool(true), "b": .int(2)])
        let raw = obj.rawValue as? [String: Any]
        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?["a"] as? Bool, true)
        XCTAssertEqual(raw?["b"] as? Int, 2)
    }
}

// MARK: - IPCEnvelope Tests

final class IPCEnvelopeTests: XCTestCase {
    func testDecodeValidEnvelope() throws {
        let json = """
        {
            "protocol": "dev-island-hook-ipc",
            "version": 1,
            "requestId": "req-123",
            "sentAt": "2026-05-10T00:00:00Z",
            "token": "tok-abc",
            "source": "claude",
            "payload": {
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash"
            }
        }
        """
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.protocol, "dev-island-hook-ipc")
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.requestId, "req-123")
        XCTAssertEqual(envelope.token, "tok-abc")
        XCTAssertEqual(envelope.source, "claude")
        // Payload fields accessible via AnyJSON
        if case .string(let v) = envelope.payload["hook_event_name"] {
            XCTAssertEqual(v, "PermissionRequest")
        } else {
            XCTFail("Expected string for hook_event_name")
        }
    }

    func testDecodeEnvelopeWithoutToken() throws {
        let json = """
        {
            "protocol": "dev-island-hook-ipc",
            "version": 1,
            "requestId": "req-456",
            "sentAt": "2026-05-10T00:00:00Z",
            "source": "codex",
            "payload": {}
        }
        """
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: Data(json.utf8))
        XCTAssertNil(envelope.token)
    }

    func testRawJSONIsNotAnEnvelope() {
        let raw = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#
        let decoded = try? JSONDecoder().decode(IPCEnvelope.self, from: Data(raw.utf8))
        // Raw JSON lacks the required `protocol` field, so decoding must fail or produce
        // a mismatched protocol value — neither is a valid IPC envelope.
        if let decoded {
            XCTAssertNotEqual(decoded.protocol, IPCEnvelope.protocolName,
                              "Raw JSON must not be treated as a valid IPC envelope")
        } else {
            // Decode failed outright — correct behavior.
            XCTAssertNil(decoded)
        }
    }
}

// MARK: - IPCRichResponse Tests

final class IPCRichResponseTests: XCTestCase {
    func testEncodeApproved() throws {
        let response = IPCRichResponse(requestId: "req-789", decision: "approved")
        let data = try JSONEncoder().encode(response)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["protocol"] as? String, "dev-island-hook-ipc")
        XCTAssertEqual(obj?["version"] as? Int, 1)
        XCTAssertEqual(obj?["requestId"] as? String, "req-789")
        XCTAssertEqual(obj?["decision"] as? String, "approved")
        XCTAssertEqual(obj?["status"] as? String, "ok")
        XCTAssertNil(obj?["providerOutput"])
    }

    func testEncodeDeniedWithReason() throws {
        let response = IPCRichResponse(requestId: "req-000", decision: "denied", reason: "policy blocked")
        let data = try JSONEncoder().encode(response)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["decision"] as? String, "denied")
        XCTAssertEqual(obj?["reason"] as? String, "policy blocked")
    }

    func testFramedData() throws {
        let response = IPCRichResponse(requestId: "req-frm", decision: "pass")
        let framed = try response.framedData()
        XCTAssertGreaterThan(framed.count, 4)
        let length = framed.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(length), framed.count - 4)
        // The body must decode back correctly.
        let body = framed.dropFirst(4)
        let decoded = try JSONDecoder().decode(IPCRichResponse.self, from: body)
        XCTAssertEqual(decoded.requestId, "req-frm")
        XCTAssertEqual(decoded.decision, "pass")
    }
}

// MARK: - BridgeTokenManager Tests

final class BridgeTokenManagerTests: XCTestCase {
    /// Isolated manager that writes to a temp directory instead of Application Support.
    private class TestableTokenManager {
        private let tempDir: URL
        private var cachedToken: String?
        private var tokenFileExists = false

        init() {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevIslandTokenTest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: tempDir)
        }

        private var tokenURL: URL { tempDir.appendingPathComponent("bridge-token") }

        func generateIfNeeded() {
            guard !FileManager.default.fileExists(atPath: tokenURL.path) else {
                reload()
                return
            }
            let token = UUID().uuidString
            try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
            cachedToken = token
            tokenFileExists = true
        }

        func validate(_ incoming: String?) -> Bool {
            guard tokenFileExists, let expected = cachedToken else { return true }
            return incoming == expected
        }

        private func reload() {
            guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else { return }
            cachedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            tokenFileExists = true
        }

        var currentToken: String? { cachedToken }
    }

    func testGenerateCreatesToken() {
        let mgr = TestableTokenManager()
        mgr.generateIfNeeded()
        XCTAssertNotNil(mgr.currentToken)
    }

    func testGenerateIsIdempotent() {
        let mgr = TestableTokenManager()
        mgr.generateIfNeeded()
        let first = mgr.currentToken
        mgr.generateIfNeeded()
        let second = mgr.currentToken
        XCTAssertEqual(first, second)
    }

    func testValidateMatchingToken() {
        let mgr = TestableTokenManager()
        mgr.generateIfNeeded()
        let token = mgr.currentToken!
        XCTAssertTrue(mgr.validate(token))
    }

    func testValidateMismatchedToken() {
        let mgr = TestableTokenManager()
        mgr.generateIfNeeded()
        XCTAssertFalse(mgr.validate("wrong-token"))
    }

    func testValidateNilTokenWithFilePresent() {
        let mgr = TestableTokenManager()
        mgr.generateIfNeeded()
        XCTAssertFalse(mgr.validate(nil))
    }

    func testGraceModeNoTokenFile() {
        let mgr = TestableTokenManager()
        // No generateIfNeeded call — token file absent → grace mode.
        XCTAssertTrue(mgr.validate(nil))
        XCTAssertTrue(mgr.validate("any-value"))
    }
}

// MARK: - AppState + Envelope Integration Tests

final class AppStateEnvelopeTests: XCTestCase {
    var appState: AppState!
    var mockDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        mockDefaults = UserDefaults(suiteName: "AppStateEnvelopeTests")
        mockDefaults.removePersistentDomain(forName: "AppStateEnvelopeTests")
        appState = AppState(
            startServer: false,
            userDefaults: mockDefaults,
            frontmostCheck: { _, _, _, _, _, _, _ in false }
        )
    }

    override func tearDown() {
        appState = nil
        mockDefaults.removePersistentDomain(forName: "AppStateEnvelopeTests")
        mockDefaults = nil
        super.tearDown()
    }

    private func sendAndReceive(_ message: String) -> String {
        var result = ""
        let expectation = XCTestExpectation(description: "response received")
        appState.handleMessage(message, responseHandler: { response in
            result = response
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 2)
        return result
    }

    func testRawJSONSessionStartAutoApproves() {
        let raw = """
        {"hook_event_name":"SessionStart","session_id":"s1","cli_source":"claude"}
        """
        let response = sendAndReceive(raw)
        let obj = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["response"] as? String, "approved")
    }

    func testLegacyResponseCanBeWrappedAsRichResponse() throws {
        let response = AppState.richResponseString(
            fromLegacyResponse: #"{"response":"approved"}"#,
            requestId: "req-rich",
            source: "claude",
            event: "PermissionRequest"
        )

        let data = try XCTUnwrap(response.data(using: .utf8))
        let decoded = try JSONDecoder().decode(IPCRichResponse.self, from: data)
        XCTAssertEqual(decoded.protocol, IPCEnvelope.protocolName)
        XCTAssertEqual(decoded.version, IPCEnvelope.currentVersion)
        XCTAssertEqual(decoded.requestId, "req-rich")
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.decision, "approved")
        let hookOutput = decoded.providerOutput?["hookSpecificOutput"]?.rawValue as? [String: Any]
        XCTAssertEqual(hookOutput?["hookEventName"] as? String, "PermissionRequest")
    }

    func testLegacyDeniedResponseCanBeWrappedAsRichResponse() throws {
        let response = AppState.richResponseString(
            fromLegacyResponse: #"{"response":"denied"}"#,
            requestId: "req-denied",
            source: "claude",
            event: "PermissionRequest"
        )

        let data = try XCTUnwrap(response.data(using: .utf8))
        let decoded = try JSONDecoder().decode(IPCRichResponse.self, from: data)
        XCTAssertEqual(decoded.requestId, "req-denied")
        XCTAssertEqual(decoded.decision, "denied")
        let hookOutput = decoded.providerOutput?["hookSpecificOutput"]?.rawValue as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
    }

    func testProviderContextExtractsEnvelopeSourceAndEvent() {
        let message = """
        {
            "protocol": "dev-island-hook-ipc",
            "version": 1,
            "requestId": "req-context",
            "sentAt": "2026-05-10T00:00:00Z",
            "source": "codex",
            "payload": {
                "hook_event_name": "PermissionRequest",
                "session_id": "s1"
            }
        }
        """

        let context = AppState.providerContext(fromEnvelopeMessage: message)

        XCTAssertEqual(context.source, "codex")
        XCTAssertEqual(context.event, "PermissionRequest")
    }

    func testEnvelopeWithInvalidProtocolFallsBackToRaw() {
        // A JSON object that looks like an envelope but has wrong protocol.
        let raw = """
        {
            "protocol": "unknown-protocol",
            "version": 1,
            "requestId": "x",
            "sentAt": "2026-05-10T00:00:00Z",
            "source": "claude",
            "payload": {"hook_event_name": "SessionStart", "session_id": "s2"}
        }
        """
        // Should NOT crash; falls back to raw JSON path and auto-approve SessionStart.
        let response = sendAndReceive(raw)
        let obj = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["response"] as? String, "approved",
                       "Invalid-protocol envelope should fall back to raw JSON and auto-approve SessionStart")
    }
}
