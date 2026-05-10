import Foundation
import SQLite3

final class SQLiteApprovalStore {
    enum StoreError: Error {
        case openFailed(String)
        case createFailed(String)
        case executeFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case unsupportedBindType(String)
        case unsupportedSchemaVersion(Int32)
    }

    static let currentSchemaVersion: Int32 = 1

    static let defaultDatabaseURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("DevIsland", isDirectory: true)
            .appendingPathComponent("approval-proxy.sqlite3")
    }()

    private let databaseURL: URL
    private var database: OpaquePointer?

    init(databaseURL: URL = SQLiteApprovalStore.defaultDatabaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createDatabaseFileIfNeeded()
        try open()
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    @discardableResult
    func insertHookEvent(
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payloadJSON: String,
        receivedAt: Date = Date()
    ) throws -> Int64 {
        try execute(
            """
            INSERT INTO hook_events
                (request_id, provider, session_id, event_name, tool_name, payload_json, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                requestId,
                provider.rawValue,
                sessionId,
                eventName,
                toolName,
                payloadJSON,
                receivedAt.timeIntervalSince1970
            ]
        )
        return sqlite3_last_insert_rowid(database)
    }

    @discardableResult
    func insertDecision(
        hookEventId: Int64?,
        provider: ProviderKind,
        sessionId: String,
        toolName: String,
        action: RuleAction,
        source: ApprovalPolicyDecision.Source,
        reason: String?,
        decidedAt: Date = Date()
    ) throws -> Int64 {
        try execute(
            """
            INSERT INTO approval_decisions
                (hook_event_id, provider, session_id, tool_name, action, source, reason, decided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                hookEventId,
                provider.rawValue,
                sessionId,
                toolName,
                action.rawValue,
                source.rawValue,
                reason,
                decidedAt.timeIntervalSince1970
            ]
        )
        return sqlite3_last_insert_rowid(database)
    }

    func upsertSessionApproval(
        provider: ProviderKind,
        sessionId: String,
        toolName: String,
        pattern: String? = nil,
        action: RuleAction,
        expiresAt: Date?,
        createdAt: Date = Date()
    ) throws {
        let id = "\(provider.rawValue):\(sessionId):\(toolName):\(pattern ?? toolName)"
        try execute(
            """
            INSERT INTO session_cache
                (id, provider, session_id, tool_name, pattern, action, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                action = excluded.action,
                expires_at = excluded.expires_at,
                created_at = excluded.created_at
            """,
            [
                id,
                provider.rawValue,
                sessionId,
                toolName,
                pattern ?? toolName,
                action.rawValue,
                expiresAt?.timeIntervalSince1970,
                createdAt.timeIntervalSince1970
            ]
        )
    }

    func insertRule(_ rule: ApprovalRule) throws {
        try execute(
            """
            INSERT OR REPLACE INTO rules
                (id, provider, tool_name, match_kind, pattern, action, scope, risk_floor,
                 workspace_root, created_at, expires_at, enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                rule.id.uuidString,
                rule.provider.rawValue,
                rule.toolName,
                rule.matchKind.rawValue,
                rule.pattern,
                rule.action.rawValue,
                rule.scope.rawValue,
                rule.riskFloor?.rawValue,
                rule.workspaceRoot,
                rule.createdAt.timeIntervalSince1970,
                rule.expiresAt?.timeIntervalSince1970,
                rule.enabled ? 1 : 0
            ]
        )
    }

    func sessionDecision(for request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision? {
        try firstDecision(
            sql:
                """
                SELECT id, action FROM session_cache
                WHERE provider IN (?, 'any')
                  AND session_id = ?
                  AND tool_name = ?
                  AND (expires_at IS NULL OR expires_at > ?)
                ORDER BY created_at DESC
                LIMIT 1
                """,
            parameters: [
                request.provider.rawValue,
                request.sessionId,
                request.toolName,
                request.now.timeIntervalSince1970
            ],
            source: .sessionCache
        )
    }

    func persistentDecision(for request: ApprovalPolicyRequest) throws -> ApprovalPolicyDecision? {
        // Phase 3 stores all planned MatchKind values, but only exact persistent
        // matching is evaluated until the dedicated matcher layer is introduced.
        try firstDecision(
            sql:
                """
                SELECT id, action FROM rules
                WHERE enabled = 1
                  AND scope = 'persistent'
                  AND provider IN (?, 'any')
                  AND tool_name = ?
                  AND match_kind = 'exact'
                  AND pattern = ?
                  AND (workspace_root IS NULL OR workspace_root = ?)
                  AND (expires_at IS NULL OR expires_at > ?)
                ORDER BY created_at DESC
                LIMIT 1
                """,
            parameters: [
                request.provider.rawValue,
                request.toolName,
                request.toolName,
                request.workspaceRoot,
                request.now.timeIntervalSince1970
            ],
            source: .persistentRule
        )
    }

    func tableNames() throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: cString))
            }
        }
        return names
    }

    func schemaVersion() throws -> Int32 {
        var statement: OpaquePointer?
        let sql = "PRAGMA user_version"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private func createDatabaseFileIfNeeded() throws {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.setAttributes(attributes, ofItemAtPath: databaseURL.path)
            return
        }
        guard fileManager.createFile(atPath: databaseURL.path, contents: Data(), attributes: attributes) else {
            throw StoreError.createFailed("Unable to create \(databaseURL.path)")
        }
    }

    private func open() throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &database, flags, nil) != SQLITE_OK {
            throw StoreError.openFailed(lastErrorMessage)
        }
    }

    private func migrate() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA busy_timeout=5000")
        try execute("PRAGMA foreign_keys=ON")
        let version = try schemaVersion()
        guard version <= Self.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(version)
        }
        try migrateToVersion1()
        try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
    }

    private func migrateToVersion1() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS rules (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                match_kind TEXT NOT NULL,
                pattern TEXT NOT NULL,
                action TEXT NOT NULL,
                scope TEXT NOT NULL,
                risk_floor TEXT,
                workspace_root TEXT,
                created_at REAL NOT NULL,
                expires_at REAL,
                enabled INTEGER NOT NULL DEFAULT 1
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS session_cache (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                pattern TEXT NOT NULL,
                action TEXT NOT NULL,
                expires_at REAL,
                created_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS hook_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                request_id TEXT,
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                event_name TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                received_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS approval_decisions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hook_event_id INTEGER,
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                action TEXT NOT NULL,
                source TEXT NOT NULL,
                reason TEXT,
                decided_at REAL NOT NULL,
                FOREIGN KEY(hook_event_id) REFERENCES hook_events(id)
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS pty_messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                direction TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_session_cache_lookup ON session_cache(provider, session_id, tool_name, expires_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_rules_lookup ON rules(provider, scope, tool_name, pattern, enabled, expires_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_hook_events_session ON hook_events(provider, session_id, received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_decisions_session ON approval_decisions(provider, session_id, decided_at)")
    }

    private func firstDecision(
        sql: String,
        parameters: [Any?],
        source: ApprovalPolicyDecision.Source
    ) throws -> ApprovalPolicyDecision? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let idString = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let actionString = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? RuleAction.prompt.rawValue
        return ApprovalPolicyDecision(
            action: RuleAction(rawValue: actionString) ?? .prompt,
            source: source,
            ruleId: UUID(uuidString: idString)
        )
    }

    private func execute(_ sql: String, _ parameters: [Any?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
            if result == SQLITE_ROW {
                continue
            }
            throw StoreError.stepFailed(lastErrorMessage)
        }
    }

    private func bind(_ parameters: [Any?], to statement: OpaquePointer?) throws {
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case nil:
                result = sqlite3_bind_null(statement, position)
            case let value as String:
                result = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case let value as Int64:
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case let value as Double:
                result = sqlite3_bind_double(statement, position, value)
            case let value as Bool:
                result = sqlite3_bind_int(statement, position, value ? 1 : 0)
            default:
                throw StoreError.unsupportedBindType(String(describing: type(of: value as Any)))
            }
            guard result == SQLITE_OK else {
                throw StoreError.executeFailed(lastErrorMessage)
            }
        }
    }

    private var lastErrorMessage: String {
        if let database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
