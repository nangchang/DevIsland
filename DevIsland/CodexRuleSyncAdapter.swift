import Foundation

struct CodexRuleSyncSnapshot: Codable, Equatable {
    struct Rule: Codable, Equatable {
        let id: UUID
        let toolName: String
        let matchKind: MatchKind
        let pattern: String
        let action: RuleAction
        let workspaceRoot: String?
        let enabled: Bool
    }

    let version: Int
    let generatedAt: Date
    let rules: [Rule]
}

struct CodexRuleSyncResult: Equatable {
    let url: URL
    let ruleCount: Int
}

protocol CodexRuleSyncAdapter {
    func sync(rules: [ApprovalRule], generatedAt: Date) throws -> CodexRuleSyncResult
}

struct CodexJSONRuleSyncAdapter: CodexRuleSyncAdapter {
    static let defaultSnapshotURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("DevIsland", isDirectory: true)
            .appendingPathComponent("codex-rules.snapshot.json")
    }()

    let snapshotURL: URL
    let fileManager: FileManager

    init(
        snapshotURL: URL = Self.defaultSnapshotURL,
        fileManager: FileManager = .default
    ) {
        self.snapshotURL = snapshotURL
        self.fileManager = fileManager
    }

    func sync(rules: [ApprovalRule], generatedAt: Date = Date()) throws -> CodexRuleSyncResult {
        let codexRules = rules
            .filter { $0.provider == .codex && $0.scope == .persistent }
            .sorted { lhs, rhs in
                if lhs.toolName == rhs.toolName {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.toolName < rhs.toolName
            }
            .map {
                CodexRuleSyncSnapshot.Rule(
                    id: $0.id,
                    toolName: $0.toolName,
                    matchKind: $0.matchKind,
                    pattern: $0.pattern,
                    action: $0.action,
                    workspaceRoot: $0.workspaceRoot,
                    enabled: $0.enabled
                )
            }
        let snapshot = CodexRuleSyncSnapshot(
            version: 1,
            generatedAt: generatedAt,
            rules: codexRules
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: snapshotURL.path) {
            try data.write(to: snapshotURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        } else {
            guard fileManager.createFile(
                atPath: snapshotURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        return CodexRuleSyncResult(url: snapshotURL, ruleCount: codexRules.count)
    }
}
