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

    static let currentSchemaVersion: Int32 = 6

    static func deterministicRuleID(
        provider: ProviderKind,
        toolName: String,
        scope: RuleScope,
        workspaceRoot: String?
    ) -> UUID {
        let key = "\(provider.rawValue)|\(scope.rawValue)|\(toolName)|\(workspaceRoot ?? "")"
        let digest = customHash128(key)
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func customHash128(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            first ^= UInt64(byte)
            first = first &* 0x100000001b3
            second ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            second = second &* 0x100000001b3
        }
        return first.bigEndianBytes + second.bigEndianBytes
    }

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
        id: Int64? = nil,
        requestId: String?,
        provider: ProviderKind,
        sessionId: String,
        eventName: String,
        toolName: String,
        payloadJSON: String,
        receivedAt: Date = Date()
    ) throws -> Int64 {
        let sql: String
        var parameters: [Any?] = [
            requestId,
            provider.rawValue,
            sessionId,
            eventName,
            toolName,
            payloadJSON,
            receivedAt.timeIntervalSince1970
        ]

        if let id {
            sql = """
                INSERT INTO hook_events
                    (id, request_id, provider, session_id, event_name, tool_name, payload_json, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            parameters.insert(id, at: 0)
        } else {
            sql = """
                INSERT INTO hook_events
                    (request_id, provider, session_id, event_name, tool_name, payload_json, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
        }

        try execute(sql, parameters)
        return id ?? sqlite3_last_insert_rowid(database)
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

    func rules(provider: ProviderKind? = nil, scope: RuleScope? = nil) throws -> [ApprovalRule] {
        var clauses: [String] = []
        var parameters: [Any?] = []
        if let provider {
            clauses.append("provider = ?")
            parameters.append(provider.rawValue)
        }
        if let scope {
            clauses.append("scope = ?")
            parameters.append(scope.rawValue)
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        return try fetchRules(
            sql:
                """
                SELECT id, provider, tool_name, match_kind, pattern, action, scope, risk_floor,
                       workspace_root, created_at, expires_at, enabled
                FROM rules
                \(whereClause)
                ORDER BY created_at DESC
                """,
            parameters: parameters
        )
    }

    func replayLog(limit: Int = 200) throws -> [ReplayLogEntry] {
        try fetchReplayLog(
            sql:
                """
                WITH latest_decisions AS (
                    SELECT
                        hook_event_id,
                        action,
                        source,
                        reason,
                        decided_at,
                        ROW_NUMBER() OVER(PARTITION BY hook_event_id ORDER BY decided_at DESC) AS row_number
                    FROM approval_decisions
                )
                SELECT e.id, e.request_id, e.provider, e.session_id, e.event_name, e.tool_name,
                       e.payload_json, e.received_at,
                       d.action, d.source, d.reason, d.decided_at
                FROM hook_events e
                LEFT JOIN latest_decisions d ON d.hook_event_id = e.id AND d.row_number = 1
                ORDER BY e.received_at DESC
                LIMIT ?
                """,
            parameters: [max(1, limit)]
        )
    }

    func replayLog(sessionId: String, limit: Int = 100) throws -> [ReplayLogEntry] {
        try fetchReplayLog(
            sql:
                """
                WITH latest_decisions AS (
                    SELECT
                        hook_event_id,
                        action,
                        source,
                        reason,
                        decided_at,
                        ROW_NUMBER() OVER(PARTITION BY hook_event_id ORDER BY decided_at DESC) AS row_number
                    FROM approval_decisions
                )
                SELECT e.id, e.request_id, e.provider, e.session_id, e.event_name, e.tool_name,
                       e.payload_json, e.received_at,
                       d.action, d.source, d.reason, d.decided_at
                FROM hook_events e
                LEFT JOIN latest_decisions d ON d.hook_event_id = e.id AND d.row_number = 1
                WHERE e.session_id = ?
                ORDER BY e.received_at DESC
                LIMIT ?
                """,
            parameters: [sessionId, max(1, limit)]
        )
    }

    // Normalized form used for lifecycle event matching: lowercase, underscores/hyphens stripped.
    // Matches HookEventNormalizer.normalizedName in Swift.
    private static let sqlNormalize = "lower(replace(replace(event_name,'_',''),'-',''))"

    func openSessions(since: Date) throws -> [OpenSessionRecord] {
        let n = Self.sqlNormalize
        let sql = """
            WITH starts AS (
                SELECT session_id, provider, MIN(received_at) AS start_at
                FROM hook_events
                WHERE \(n) IN ('sessionstart', 'startup', 'init')
                  AND received_at > ?
                GROUP BY session_id
            ),
            ended AS (
                SELECT DISTINCT session_id FROM hook_events
                WHERE \(n) IN ('exit', 'shutdown', 'sessionend', 'devislanddismissed')
            ),
            latest AS (
                SELECT e.session_id, e.payload_json, e.event_name, e.tool_name, e.received_at,
                       ROW_NUMBER() OVER (PARTITION BY e.session_id ORDER BY e.received_at DESC) AS rn
                FROM hook_events e
                JOIN starts s ON s.session_id = e.session_id
                WHERE e.session_id NOT IN (SELECT session_id FROM ended)
            )
            SELECT s.session_id, s.provider, l.payload_json, l.event_name, l.tool_name,
                   l.received_at, s.start_at
            FROM starts s
            JOIN latest l ON l.session_id = s.session_id AND l.rn = 1
            ORDER BY s.start_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind([since.timeIntervalSince1970], to: statement)

        var records: [OpenSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sessionId = columnString(statement, 0),
                let providerRaw = columnString(statement, 1),
                let provider = ProviderKind(rawValue: providerRaw),
                let payloadJSON = columnString(statement, 2),
                let eventName = columnString(statement, 3),
                let toolName = columnString(statement, 4)
            else { continue }
            let lastActiveAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let startAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            records.append(OpenSessionRecord(
                sessionId: sessionId,
                provider: provider,
                lastPayloadJSON: payloadJSON,
                lastEventName: eventName,
                lastToolName: toolName,
                lastActiveAt: lastActiveAt,
                startAt: startAt
            ))
        }
        return records
    }

    func closedSessions(since: Date) throws -> [ClosedSessionRecord] {
        let n = Self.sqlNormalize
        let sql = """
            WITH starts AS (
                SELECT session_id, provider, MIN(received_at) AS start_at
                FROM hook_events
                WHERE \(n) IN ('sessionstart', 'startup', 'init')
                  AND received_at > ?
                GROUP BY session_id
            ),
            ended AS (
                SELECT session_id, MAX(received_at) AS ended_at
                FROM hook_events
                WHERE \(n) IN ('exit', 'shutdown', 'sessionend', 'devislanddismissed')
                GROUP BY session_id
            ),
            latest AS (
                SELECT e.session_id, e.payload_json, e.event_name, e.tool_name, e.received_at,
                       ROW_NUMBER() OVER (PARTITION BY e.session_id ORDER BY e.received_at DESC) AS rn
                FROM hook_events e
                JOIN starts s ON s.session_id = e.session_id
                JOIN ended en ON en.session_id = e.session_id
            ),
            with_meta AS (
                SELECT e.session_id, e.payload_json AS meta_payload,
                       ROW_NUMBER() OVER (PARTITION BY e.session_id ORDER BY e.received_at DESC) AS rn
                FROM hook_events e
                JOIN starts s ON s.session_id = e.session_id
                JOIN ended en ON en.session_id = e.session_id
                WHERE json_extract(e.payload_json, '$.cwd') IS NOT NULL
            )
            SELECT s.session_id, s.provider, l.payload_json, l.event_name, l.tool_name,
                   s.start_at, en.ended_at, m.meta_payload
            FROM starts s
            JOIN ended en ON en.session_id = s.session_id
            JOIN latest l ON l.session_id = s.session_id AND l.rn = 1
            LEFT JOIN with_meta m ON m.session_id = s.session_id AND m.rn = 1
            ORDER BY en.ended_at DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind([since.timeIntervalSince1970], to: statement)

        var records: [ClosedSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sessionId = columnString(statement, 0),
                let providerRaw = columnString(statement, 1),
                let provider = ProviderKind(rawValue: providerRaw),
                let payloadJSON = columnString(statement, 2),
                let eventName = columnString(statement, 3),
                let toolName = columnString(statement, 4)
            else { continue }
            let startAt  = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let endedAt  = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let metaPayload = columnString(statement, 7) ?? payloadJSON
            let meta = (try? JSONSerialization.jsonObject(with: Data(metaPayload.utf8))) as? [String: Any]
            records.append(ClosedSessionRecord(
                sessionId: sessionId,
                provider: provider,
                lastPayloadJSON: payloadJSON,
                lastEventName: eventName,
                lastToolName: toolName,
                startAt: startAt,
                endedAt: endedAt,
                workspaceRoot: meta?["cwd"] as? String,
                terminalApp: meta?["terminal_app"] as? String,
                terminalTitle: meta?["terminal_title"] as? String
            ))
        }
        return records
    }

    func deleteRule(id: UUID) throws {
        try execute("DELETE FROM rules WHERE id = ?", [id.uuidString])
    }

    func manualAllowCount(toolName: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM approval_decisions WHERE tool_name = ? AND action = 'allow' AND source = 'user'"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, toolName, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func hasPersistentAllowRule(toolName: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM rules WHERE enabled = 1 AND scope = 'persistent' AND action = 'allow' AND tool_name = ? AND (expires_at IS NULL OR expires_at > ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, toolName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    func sessionInsightsSummary(since: Date) throws -> SessionInsightsSummary {
        let sinceTs = since.timeIntervalSince1970
        let n = Self.sqlNormalize

        // Decision breakdown: bucket by (action, source)
        var manualApproved = 0, manualDenied = 0, autoApproved = 0, autoDenied = 0
        var stmt: OpaquePointer?
        let decisionSQL = """
            SELECT action, source, COUNT(*) FROM approval_decisions
            WHERE decided_at > ? GROUP BY action, source
            """
        guard sqlite3_prepare_v2(database, decisionSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, sinceTs)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let action = columnString(stmt, 0) ?? ""
            let source = columnString(stmt, 1) ?? ""
            let count  = Int(sqlite3_column_int(stmt, 2))
            switch (action, source) {
            case ("allow", "user"):  manualApproved += count
            case ("deny",  "user"):  manualDenied   += count
            case ("allow", _):       autoApproved   += count
            case ("deny",  _):       autoDenied     += count
            default: break
            }
        }

        // Top 5 manually-approved tools
        var topTools: [(tool: String, count: Int)] = []
        var toolStmt: OpaquePointer?
        let toolSQL = """
            SELECT tool_name, COUNT(*) AS cnt FROM approval_decisions
            WHERE action = 'allow' AND source = 'user' AND decided_at > ?
            GROUP BY tool_name ORDER BY cnt DESC LIMIT 5
            """
        guard sqlite3_prepare_v2(database, toolSQL, -1, &toolStmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(toolStmt) }
        sqlite3_bind_double(toolStmt, 1, sinceTs)
        while sqlite3_step(toolStmt) == SQLITE_ROW {
            if let tool = columnString(toolStmt, 0) {
                topTools.append((tool: tool, count: Int(sqlite3_column_int(toolStmt, 1))))
            }
        }

        // Session counts (by end time) and average duration
        var totalClosed = 0, todayClosed = 0
        var avgDuration: Double? = nil
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var sessStmt: OpaquePointer?
        let sessSQL = """
            WITH starts AS (
                SELECT session_id, MIN(received_at) AS start_at
                FROM hook_events
                WHERE \(n) IN ('sessionstart', 'startup', 'init') AND received_at > ?
                GROUP BY session_id
            ),
            ended AS (
                SELECT session_id, MAX(received_at) AS ended_at
                FROM hook_events
                WHERE \(n) IN ('exit', 'shutdown', 'sessionend', 'devislanddismissed')
                  AND received_at > ?
                GROUP BY session_id
            )
            SELECT
                COUNT(*) AS total,
                SUM(CASE WHEN en.ended_at >= ? THEN 1 ELSE 0 END) AS today,
                AVG(CASE WHEN en.ended_at - s.start_at > 10 THEN en.ended_at - s.start_at END) AS avg_dur
            FROM starts s
            JOIN ended en ON en.session_id = s.session_id
            WHERE en.ended_at > s.start_at
            """
        guard sqlite3_prepare_v2(database, sessSQL, -1, &sessStmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(sessStmt) }
        sqlite3_bind_double(sessStmt, 1, sinceTs)
        sqlite3_bind_double(sessStmt, 2, sinceTs)
        sqlite3_bind_double(sessStmt, 3, todayStart)
        if sqlite3_step(sessStmt) == SQLITE_ROW {
            totalClosed = Int(sqlite3_column_int(sessStmt, 0))
            todayClosed = Int(sqlite3_column_int(sessStmt, 1))
            if sqlite3_column_type(sessStmt, 2) != SQLITE_NULL {
                let val = sqlite3_column_double(sessStmt, 2)
                if val > 0 { avgDuration = val }
            }
        }

        return SessionInsightsSummary(
            since: since,
            totalClosedSessions: totalClosed,
            todayClosedSessions: todayClosed,
            manualApproved: manualApproved,
            manualDenied: manualDenied,
            autoApproved: autoApproved,
            autoDenied: autoDenied,
            topApprovedTools: topTools,
            averageDurationSeconds: avgDuration
        )
    }

    func pruneOldLogs(replayRetentionDays: Int, ptyRetentionDays: Int) throws {
        guard replayRetentionDays > 0, ptyRetentionDays > 0 else { return }
        let replayCutoff = Date().timeIntervalSince1970 - Double(replayRetentionDays) * 86_400
        let ptyCutoff    = Date().timeIntervalSince1970 - Double(ptyRetentionDays) * 86_400
        // Delete decisions referencing old hook events, then the hook events themselves.
        // Decisions with hook_event_id IS NULL are pruned by decided_at.
        try execute(
            "DELETE FROM approval_decisions WHERE hook_event_id IN (SELECT id FROM hook_events WHERE received_at < ?)",
            [replayCutoff]
        )
        try execute(
            "DELETE FROM approval_decisions WHERE hook_event_id IS NULL AND decided_at < ?",
            [replayCutoff]
        )
        try execute("DELETE FROM hook_events WHERE received_at < ?", [replayCutoff])
        try execute("DELETE FROM pty_messages WHERE created_at < ?", [ptyCutoff])
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
        // Deprecated: use persistentCandidates + ApprovalPolicyEngine for pattern matching.
        // Kept for backward compatibility with tests that call this directly.
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

    /// Returns all enabled persistent rules for the request's provider and workspace,
    /// ordered deny-first then most-recent-first. Pattern evaluation is done in Swift
    /// by ApprovalPolicyEngine so non-exact match kinds are included.
    func persistentCandidates(for request: ApprovalPolicyRequest) throws -> [ApprovalRule] {
        try fetchRules(
            sql:
                """
                SELECT id, provider, tool_name, match_kind, pattern, action, scope, risk_floor,
                       workspace_root, created_at, expires_at, enabled
                FROM rules
                WHERE enabled = 1
                  AND scope = 'persistent'
                  AND provider IN (?, 'any')
                  AND (workspace_root IS NULL OR workspace_root = ?)
                  AND (expires_at IS NULL OR expires_at > ?)
                ORDER BY
                  CASE action WHEN 'deny' THEN 0 ELSE 1 END,
                  created_at DESC
                """,
            parameters: [
                request.provider.rawValue,
                request.workspaceRoot,
                request.now.timeIntervalSince1970
            ]
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
        if version < 2 { try migrateToVersion2() }
        if version < 3 { try migrateToVersion3() }
        if version < 4 { try migrateToVersion4() }
        if version < 5 { try migrateToVersion5() }
        if version < 6 { try migrateToVersion6() }
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

    private func migrateToVersion3() throws {
        try execute("CREATE INDEX IF NOT EXISTS idx_hook_events_received_at ON hook_events(received_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_decisions_hook_event_id ON approval_decisions(hook_event_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_decisions_decided_at ON approval_decisions(decided_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_pty_messages_created_at ON pty_messages(created_at)")
    }

    // Seeds built-in allow rules derived from historical approval data.
    // INSERT OR IGNORE preserves any user-modified rule with the same ID.
    // UUIDs use the A1B2C3D4-0001- prefix to identify seeded rules at a glance.
    // created_at = 0 so user-created rules (later timestamps) take priority in deny-first ordering.
    //
    // Each rule is duplicated for both 'Bash' and 'shell' tool names so Claude Code
    // and Codex (which uses 'shell') both benefit from the same defaults.
    // gh patterns are scoped to read-only subcommands to avoid allowing gh pr create/merge etc.
    private func migrateToVersion4() throws {
        let seed: [(id: String, toolName: String, pattern: String)] = [
            // Bash variants
            ("A1B2C3D4-0001-0000-0000-000000000001", "Bash", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000002", "Bash", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000003", "Bash", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000004", "Bash", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000005", "Bash", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000006", "Bash", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000007", "Bash", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000008", "Bash", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000009", "Bash", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000000A", "Bash", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000000B", "Bash", "screencapture /tmp/"),
            // shell variants (Codex uses 'shell' as tool_name)
            ("A1B2C3D4-0001-0000-0000-000000000011", "shell", "xcodebuild build"),
            ("A1B2C3D4-0001-0000-0000-000000000012", "shell", "xcodebuild test"),
            ("A1B2C3D4-0001-0000-0000-000000000013", "shell", "xcodegen generate"),
            ("A1B2C3D4-0001-0000-0000-000000000014", "shell", "bash scripts/"),
            ("A1B2C3D4-0001-0000-0000-000000000015", "shell", "gh pr list"),
            ("A1B2C3D4-0001-0000-0000-000000000016", "shell", "gh pr view"),
            ("A1B2C3D4-0001-0000-0000-000000000017", "shell", "gh pr diff"),
            ("A1B2C3D4-0001-0000-0000-000000000018", "shell", "gh pr checks"),
            ("A1B2C3D4-0001-0000-0000-000000000019", "shell", "gh issue list"),
            ("A1B2C3D4-0001-0000-0000-00000000001A", "shell", "gh issue view"),
            ("A1B2C3D4-0001-0000-0000-00000000001B", "shell", "screencapture /tmp/"),
        ]
        for entry in seed {
            try execute(
                """
                INSERT OR IGNORE INTO rules
                    (id, provider, tool_name, match_kind, pattern, action, scope,
                     risk_floor, workspace_root, created_at, expires_at, enabled)
                VALUES (?, 'any', ?, 'commandPrefix', ?, 'allow', 'persistent',
                        NULL, NULL, 0, NULL, 1)
                """,
                [entry.id, entry.toolName, entry.pattern]
            )
        }
    }

    private func migrateToVersion5() throws {
        // session_id 단독 필터링 쿼리 성능을 위한 인덱스
        // 기존 idx_hook_events_session(provider, session_id, received_at)은 session_id로만
        // 조회 시 leading column이 맞지 않아 풀스캔이 발생한다.
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_hook_events_session_id ON hook_events(session_id, received_at DESC)"
        )
    }

    private func migrateToVersion6() throws {
        // manualAllowCount(toolName:)이 tool_name + action + source로 필터링하므로
        // 복합 인덱스를 추가해 결정 로그 누적 시 풀스캔을 방지한다.
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_decisions_tool_action_source ON approval_decisions(tool_name, action, source)"
        )
    }

    private func migrateToVersion2() throws {
        // Check before ALTER so a retry after an interrupted migration doesn't fail.
        var stmt: OpaquePointer?
        let checkSQL = "SELECT COUNT(*) FROM pragma_table_info('pty_messages') WHERE name='provider'"
        guard sqlite3_prepare_v2(database, checkSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(stmt) }
        let columnExists = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
        if !columnExists {
            try execute("ALTER TABLE pty_messages ADD COLUMN provider TEXT NOT NULL DEFAULT ''")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_pty_messages_session ON pty_messages(session_id, created_at DESC)")
    }

    // MARK: - PTY

    @discardableResult
    func insertPTYMessage(
        sessionId: String,
        provider: ProviderKind,
        direction: PTYDirection,
        content: String,
        createdAt: Date = Date()
    ) throws -> Int64 {
        try execute(
            """
            INSERT INTO pty_messages (session_id, provider, direction, message, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [sessionId, provider.rawValue, direction.rawValue, content, createdAt.timeIntervalSince1970]
        )
        return sqlite3_last_insert_rowid(database)
    }

    func ptyMessages(sessionId: String? = nil, limit: Int = 500) throws -> [PTYMessage] {
        let wherePart = sessionId != nil ? "WHERE session_id = ?" : ""
        let sql = """
            SELECT id, session_id, provider, direction, message, created_at
            FROM pty_messages
            \(wherePart)
            ORDER BY created_at DESC
            LIMIT ?
            """
        var parameters: [Any?] = []
        if let sessionId { parameters.append(sessionId) }
        parameters.append(limit)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        var messages: [PTYMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sessionIdVal = columnString(statement, 1),
                let directionRaw = columnString(statement, 3),
                let direction = PTYDirection(rawValue: directionRaw),
                let content = columnString(statement, 4)
            else { continue }
            let providerRaw = columnString(statement, 2) ?? ""
            let provider = ProviderKind(rawValue: providerRaw) ?? .any
            messages.append(PTYMessage(
                id: sqlite3_column_int64(statement, 0),
                sessionId: sessionIdVal,
                provider: provider,
                direction: direction,
                content: content,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            ))
        }
        return messages
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

    private func fetchRules(sql: String, parameters: [Any?]) throws -> [ApprovalRule] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        var rules: [ApprovalRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = columnString(statement, 0).flatMap(UUID.init(uuidString:)),
                let provider = columnString(statement, 1).flatMap(ProviderKind.init(rawValue:)),
                let toolName = columnString(statement, 2),
                let matchKind = columnString(statement, 3).flatMap(MatchKind.init(rawValue:)),
                let pattern = columnString(statement, 4),
                let action = columnString(statement, 5).flatMap(RuleAction.init(rawValue:)),
                let scope = columnString(statement, 6).flatMap(RuleScope.init(rawValue:))
            else {
                continue
            }

            let riskFloor = columnString(statement, 7).flatMap(ToolRiskLevel.init(rawValue:))
            let workspaceRoot = columnString(statement, 8)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            let expiresAt = sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            let enabled = sqlite3_column_int(statement, 11) != 0
            rules.append(ApprovalRule(
                id: id,
                provider: provider,
                toolName: toolName,
                matchKind: matchKind,
                pattern: pattern,
                action: action,
                scope: scope,
                riskFloor: riskFloor,
                workspaceRoot: workspaceRoot,
                createdAt: createdAt,
                expiresAt: expiresAt,
                enabled: enabled
            ))
        }
        return rules
    }

    private func fetchReplayLog(sql: String, parameters: [Any?]) throws -> [ReplayLogEntry] {
        enum Column {
            static let id: Int32 = 0
            static let requestId: Int32 = 1
            static let provider: Int32 = 2
            static let sessionId: Int32 = 3
            static let eventName: Int32 = 4
            static let toolName: Int32 = 5
            static let payloadJSON: Int32 = 6
            static let receivedAt: Int32 = 7
            static let decisionAction: Int32 = 8
            static let decisionSource: Int32 = 9
            static let decisionReason: Int32 = 10
            static let decidedAt: Int32 = 11
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        var entries: [ReplayLogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let provider = columnString(statement, Column.provider).flatMap(ProviderKind.init(rawValue:)),
                let sessionId = columnString(statement, Column.sessionId),
                let eventName = columnString(statement, Column.eventName),
                let toolName = columnString(statement, Column.toolName),
                let payloadJSON = columnString(statement, Column.payloadJSON)
            else {
                continue
            }
            let receivedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, Column.receivedAt))
            let decidedAt = sqlite3_column_type(statement, Column.decidedAt) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, Column.decidedAt))
            entries.append(ReplayLogEntry(
                id: sqlite3_column_int64(statement, Column.id),
                requestId: columnString(statement, Column.requestId),
                provider: provider,
                sessionId: sessionId,
                eventName: eventName,
                toolName: toolName,
                payloadJSON: payloadJSON,
                receivedAt: receivedAt,
                decisionAction: columnString(statement, Column.decisionAction).flatMap(RuleAction.init(rawValue:)),
                decisionSource: columnString(statement, Column.decisionSource).flatMap(ApprovalPolicyDecision.Source.init(rawValue:)),
                decisionReason: columnString(statement, Column.decisionReason),
                decidedAt: decidedAt
            ))
        }
        return entries
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
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

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
