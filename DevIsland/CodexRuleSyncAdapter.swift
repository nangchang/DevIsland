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
    /// Exports DevIsland-managed Codex persistent rules supplied by the caller.
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
        let snapshotRules = rules
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
            rules: snapshotRules
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent(".\(snapshotURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fileManager.fileExists(atPath: snapshotURL.path) {
                _ = try fileManager.replaceItemAt(snapshotURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: snapshotURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        return CodexRuleSyncResult(url: snapshotURL, ruleCount: snapshotRules.count)
    }
}
