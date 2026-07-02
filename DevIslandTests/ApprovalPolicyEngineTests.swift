import XCTest
@testable import DevIsland

final class ApprovalPolicyEngineTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalPolicyEngineTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseURL = tempDir.appendingPathComponent("approval-proxy.sqlite3")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        databaseURL = nil
        super.tearDown()
    }

    func testPersistentRulePrecedesSessionCache() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .allow,
            expiresAt: nil
        )
        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            action: .deny,
            scope: .persistent
        ))

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision.action, .deny)
        XCTAssertEqual(decision.source, .persistentRule)
    }

    func testFallsBackToPromptWhenNoRuleMatches() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision, .prompt)
    }

    func testSessionDenyBeatesPersistentAllow() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            action: .allow,
            scope: .persistent
        ))
        try store.upsertSessionApproval(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell",
            action: .deny,
            expiresAt: nil
        )

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "session-1",
            toolName: "shell"
        ))

        XCTAssertEqual(decision.action, .deny)
        XCTAssertEqual(decision.source, .sessionCache)
    }

    func testCommandPrefixMatchesAgainstToolInput() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "run_shell_command",
            matchKind: .commandPrefix,
            pattern: "git ",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "git status"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let denied = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "rm -rf /"]
        ))
        XCTAssertEqual(denied, .prompt)

        // No toolInput → no match
        let noInput = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command"
        ))
        XCTAssertEqual(noInput, .prompt)
    }

    func testCommandPrefixRequiresSafeSuffix() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            matchKind: .commandPrefix,
            pattern: "gh pr view",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "gh pr view 123 --json title"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let noTokenBoundary = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "gh pr viewer"]
        ))
        XCTAssertEqual(noTokenBoundary, .prompt)

        let appendedCommand = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "gh pr view 123; rm -rf /tmp/dev-island-test"]
        ))
        XCTAssertEqual(appendedCommand, .prompt)

        let commandSubstitution = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "gh pr view $(touch /tmp/dev-island-test)"]
        ))
        XCTAssertEqual(commandSubstitution, .prompt)
    }

    func testCommandPrefixAllowsSeededPathPrefixesWithoutShellSyntax() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .codex,
            toolName: "shell",
            matchKind: .commandPrefix,
            pattern: "bash scripts/",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "bash scripts/run-tests.sh"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let pipedCommand = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "bash scripts/run-tests.sh | sh"]
        ))
        XCTAssertEqual(pipedCommand, .prompt)

        let newlineCommand = try engine.evaluate(ApprovalPolicyRequest(
            provider: .codex,
            sessionId: "s1",
            toolName: "shell",
            toolInput: ["command": "bash scripts/run-tests.sh\nwhoami"]
        ))
        XCTAssertEqual(newlineCommand, .prompt)
    }

    func testPathPrefixMatchesAgainstToolInput() throws {
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "write_file",
            matchKind: .pathPrefix,
            pattern: "/tmp/",
            action: .allow,
            scope: .persistent
        ))

        let allowed = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/tmp/output.txt"]
        ))
        XCTAssertEqual(allowed.action, .allow)

        let denied = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/etc/passwd"]
        ))
        XCTAssertEqual(denied, .prompt)
    }

    func testEqualityDiffersOnToolInput() {
        let base = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "git status"],
            now: Date(timeIntervalSince1970: 0)
        )

        // Same toolInput → equal
        let same = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "git status"],
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(base, same)

        // Different command value → not equal
        let diffCommand = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: ["command": "rm -rf /"],
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotEqual(base, diffCommand)

        // Different path value → not equal
        let pathBase = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/tmp/safe.txt"],
            now: Date(timeIntervalSince1970: 0)
        )
        let diffPath = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "write_file",
            toolInput: ["file_path": "/etc/passwd"],
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotEqual(pathBase, diffPath)

        // nil vs non-nil → not equal
        let nilInput = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNotEqual(base, nilInput)

        // both nil → equal
        let nilBase = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        let nilOther = ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "run_shell_command",
            toolInput: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(nilBase, nilOther)
    }

    // MARK: - P1.1: Regex matching (S6 — anchored full-match)

    func testRegexExactMatchDoesNotMatchSubstring() throws {
        // S6 fix: a regex allow rule for "Read" must NOT match "ReadDangerousTool".
        // Before S6, firstMatch did partial matching; after S6 the full string must match.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Read",
            matchKind: .regex,
            pattern: "Read",
            action: .allow,
            scope: .persistent
        ))

        let exactMatch = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "Read"
        ))
        XCTAssertEqual(exactMatch.action, .allow, "Pattern 'Read' should match tool name 'Read'")

        let noPartialMatch = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "ReadDangerousTool"
        ))
        XCTAssertEqual(noPartialMatch, .prompt,
                       "Pattern 'Read' must NOT match 'ReadDangerousTool' (anchored full match)")
    }

    func testRegexWildcardStillMatchesSubstring() throws {
        // A pattern with explicit wildcards should match as intended.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Read.*",
            matchKind: .regex,
            pattern: "Read.*",
            action: .allow,
            scope: .persistent
        ))

        let match = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "ReadDangerousTool"
        ))
        XCTAssertEqual(match.action, .allow, "Pattern 'Read.*' should match 'ReadDangerousTool'")
    }

    func testRegexAlternationFullMatchCorrect() throws {
        // Regression: without ^(?:)$ anchors, firstMatch on "Read|ReadDangerousTool"
        // against "ReadDangerousTool" returns the "Read" branch (range 0..<4),
        // and range comparison would incorrectly reject the match.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Read|ReadDangerousTool",
            matchKind: .regex,
            pattern: "Read|ReadDangerousTool",
            action: .allow,
            scope: .persistent
        ))

        let exactFirst = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "Read"
        ))
        XCTAssertEqual(exactFirst.action, .allow, "First alternation branch 'Read' must match")

        let exactSecond = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "ReadDangerousTool"
        ))
        XCTAssertEqual(exactSecond.action, .allow,
                       "Second alternation branch 'ReadDangerousTool' must match (anchored full-match)")
    }

    func testRegexPatternLengthLimit() throws {
        // Patterns longer than 200 chars must not match anything.
        let longPattern = String(repeating: "a", count: 201)
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "shell",
            matchKind: .regex,
            pattern: longPattern,
            action: .allow,
            scope: .persistent
        ))

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "shell"
        ))
        XCTAssertEqual(decision, .prompt, "Oversized regex pattern must not match")
    }

    func testGlobFNMPATHNAMESemantic() throws {
        // FNM_PATHNAME: '*' does not match '/', so 'bash*' matches 'bash_v2' but not 'bash/nested'.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "bash*",
            matchKind: .glob,
            pattern: "bash*",
            action: .allow,
            scope: .persistent
        ))

        let noSlash = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "bash_v2"
        ))
        XCTAssertEqual(noSlash.action, .allow, "glob 'bash*' should match 'bash_v2'")

        let withSlash = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "bash/nested"
        ))
        XCTAssertEqual(withSlash, .prompt, "glob 'bash*' must not match 'bash/nested' (FNM_PATHNAME)")
    }

    func testPriorityMatrix() throws {
        // Verify all 5 priority levels: persistent deny > session deny > persistent allow > session allow > prompt
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        // No rules → prompt
        let promptDecision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "shell"
        ))
        XCTAssertEqual(promptDecision, .prompt)

        // Session allow → allow
        try store.upsertSessionApproval(provider: .claude, sessionId: "s1", toolName: "shell",
                                        action: .allow, expiresAt: nil)
        let sessionAllow = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "shell"
        ))
        XCTAssertEqual(sessionAllow.source, .sessionCache)
        XCTAssertEqual(sessionAllow.action, .allow)

        // Persistent allow > session allow (already tested in other tests, verify source)
        try store.insertRule(ApprovalRule(
            provider: .claude, toolName: "shell", action: .allow, scope: .persistent
        ))
        let persistentAllow = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "shell"
        ))
        XCTAssertEqual(persistentAllow.source, .persistentRule)
        XCTAssertEqual(persistentAllow.action, .allow)

        // Session deny > persistent allow
        try store.upsertSessionApproval(provider: .claude, sessionId: "s1", toolName: "shell",
                                        action: .deny, expiresAt: nil)
        let sessionDeny = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "shell"
        ))
        XCTAssertEqual(sessionDeny.source, .sessionCache)
        XCTAssertEqual(sessionDeny.action, .deny)

        // Persistent deny > session deny (top priority)
        try store.insertRule(ApprovalRule(
            provider: .claude, toolName: "shell", action: .deny, scope: .persistent
        ))
        let persistentDeny = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude, sessionId: "s1", toolName: "shell"
        ))
        XCTAssertEqual(persistentDeny.source, .persistentRule)
        XCTAssertEqual(persistentDeny.action, .deny)
    }

    // MARK: - Action-aware regex semantics

    func testRegexDenyUsesSubstringMatchToPreserveBroadCoverage() throws {
        // Deny rules use substring match so an unanchored pattern like "Dangerous"
        // still blocks "ReadDangerousTool". Full-match on deny would silently weaken
        // existing rules on upgrade.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Dangerous",
            matchKind: .regex,
            pattern: "Dangerous",
            action: .deny,
            scope: .persistent
        ))

        let substringMatch = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "ReadDangerousTool"
        ))
        XCTAssertEqual(substringMatch.action, .deny,
                       "Regex deny 'Dangerous' must block 'ReadDangerousTool' via substring match")

        let exactMatch = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "Dangerous"
        ))
        XCTAssertEqual(exactMatch.action, .deny,
                       "Regex deny 'Dangerous' must also block exact match 'Dangerous'")
    }

    func testRegexDenyOverridesRegexAllow() throws {
        // Regression: a broad regex deny rule must win even when a narrow regex allow
        // rule also matches the same tool name. Priority: persistent deny > persistent allow.
        let store = try SQLiteApprovalStore(databaseURL: databaseURL)
        let engine = ApprovalPolicyEngine(store: store)

        // Allow rule: full-match — only matches "Read" exactly.
        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Read",
            matchKind: .regex,
            pattern: "Read",
            action: .allow,
            scope: .persistent
        ))
        // Deny rule: substring — matches anything containing "Read".
        try store.insertRule(ApprovalRule(
            provider: .claude,
            toolName: "Read",
            matchKind: .regex,
            pattern: "Read",
            action: .deny,
            scope: .persistent
        ))

        let decision = try engine.evaluate(ApprovalPolicyRequest(
            provider: .claude,
            sessionId: "s1",
            toolName: "Read"
        ))
        XCTAssertEqual(decision.action, .deny,
                       "Persistent deny must win over persistent allow when both regex rules match")
    }
}
