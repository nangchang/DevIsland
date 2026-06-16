import Foundation
import SQLite3

/// SQLite copies bound text immediately when given this destructor, so passing a
/// transient Swift String pointer is safe.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum PluginStorageLimits {
    /// Default cap for the read-only snapshot injected into a runner's context.
    static let snapshotLimit = 64
    /// Equal to `snapshotLimit` so every persisted key is visible in the next
    /// snapshot — v1 plugins read storage only via that snapshot (no per-key get
    /// in `onEvent`), so a higher cap would leave keys writable but invisible.
    static let maxKeys = snapshotLimit
    static let maxKeyLength = 128
    static let maxValueLength = 4096
}

/// Per-plugin durable key-value storage. Implementations are confined to the
/// `PluginStorageProvider` actor, which serializes every call.
protocol PluginStorage {
    func snapshot(limit: Int) throws -> [String: String]
    func get(_ key: String) throws -> String?
    func set(_ key: String, value: String) throws
    func delete(_ key: String) throws
    @discardableResult
    func increment(_ key: String, by delta: Int) throws -> Int
}

/// SQLite-backed plugin storage. A separate, minimal wrapper — it deliberately does
/// not reuse `SQLiteApprovalStore` or the approval persistence queue so plugin I/O
/// never touches the durable approval DB or the hook response path.
final class SQLitePluginStorage: PluginStorage {
    enum StorageError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case keyTooLong
        case valueTooLong
        case quotaExceeded
        case overflow
    }

    private let databaseURL: URL
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            throw StorageError.openFailed(lastError)
        }
        // `deinit` does not run when `init` throws, so a PRAGMA/CREATE failure after a
        // successful open would leak the handle — close it explicitly before rethrowing.
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA busy_timeout=5000")
            try exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    /// Idempotent; `sqlite3_close(nil)` is a no-op so `deinit` is safe after this.
    func close() {
        sqlite3_close(db)
        db = nil
    }

    deinit {
        sqlite3_close(db)
    }

    func snapshot(limit: Int) throws -> [String: String] {
        let stmt = try prepare("SELECT key, value FROM kv LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(clamping: max(0, limit)))
        var result: [String: String] = [:]
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) else { continue }
                result[String(cString: k)] = String(cString: v)
            case SQLITE_DONE:
                return result
            default:
                throw StorageError.stepFailed(lastError)
            }
        }
    }

    func get(_ key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM kv WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        case SQLITE_DONE:
            return nil
        default:
            throw StorageError.stepFailed(lastError)
        }
    }

    func set(_ key: String, value: String) throws {
        guard key.count <= PluginStorageLimits.maxKeyLength else { throw StorageError.keyTooLong }
        guard value.count <= PluginStorageLimits.maxValueLength else { throw StorageError.valueTooLong }
        // A new key beyond the cap is rejected; overwriting an existing key is always allowed.
        if try get(key) == nil, try count() >= PluginStorageLimits.maxKeys {
            throw StorageError.quotaExceeded
        }
        let stmt = try prepare(
            "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageError.stepFailed(lastError) }
    }

    func delete(_ key: String) throws {
        let stmt = try prepare("DELETE FROM kv WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageError.stepFailed(lastError) }
    }

    @discardableResult
    func increment(_ key: String, by delta: Int) throws -> Int {
        let current = Int(try get(key) ?? "0") ?? 0
        // A plugin-supplied delta must not trap the host on overflow; surface it as a
        // throw so the executor logs and drops the effect instead of crashing core.
        let (next, overflow) = current.addingReportingOverflow(delta)
        guard !overflow else { throw StorageError.overflow }
        try set(key, value: String(next))
        return next
    }

    private func count() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM kv")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StorageError.stepFailed(lastError) }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StorageError.prepareFailed(lastError)
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorPointer)
            throw StorageError.stepFailed(message)
        }
    }

    private var lastError: String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }
}

/// Owns per-plugin storage namespaces. All durable writes flow through here via
/// `applyStorageEffect`; `snapshot(forPluginID:)` provides the read-only context
/// injected into runners. Actor isolation makes read-modify-write (increment) atomic.
actor PluginStorageProvider {
    static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("DevIsland/PluginData", isDirectory: true)
    }()

    private let baseDirectory: URL
    private var stores: [String: SQLitePluginStorage] = [:]

    init(baseDirectory: URL = PluginStorageProvider.defaultDirectory) {
        self.baseDirectory = baseDirectory
    }

    func snapshot(forPluginID pluginID: String) -> [String: String] {
        let pluginID = BuiltInPluginID.currentID(for: pluginID)
        do {
            return try store(for: pluginID).snapshot(limit: PluginStorageLimits.snapshotLimit)
        } catch {
            print("[DevIsland] [PluginStorage] snapshot failed for \(pluginID): \(error)")
            return [:]
        }
    }

    func applyStorageEffect(_ effect: PluginEffect, pluginID: String) {
        let pluginID = BuiltInPluginID.currentID(for: pluginID)
        do {
            let storage = try store(for: pluginID)
            switch effect.capability {
            case "storage.keyValue":
                guard let key = effect.payload["key"] else { return }
                if let value = effect.payload["value"] {
                    try storage.set(key, value: value)
                } else {
                    try storage.delete(key)
                }
            case "storage.increment":
                guard let key = effect.payload["key"] else { return }
                let delta = Int(effect.payload["delta"] ?? "1") ?? 1
                try storage.increment(key, by: delta)
            default:
                break
            }
        } catch {
            print("[DevIsland] [PluginStorage] effect \(effect.capability) failed for \(pluginID): \(error)")
        }
    }

    /// Clears a plugin's storage by closing its connection and deleting its
    /// directory (also removes WAL/SHM sidecar files). Re-created lazily on next use.
    func reset(pluginID: String) {
        let pluginID = BuiltInPluginID.currentID(for: pluginID)
        stores.removeValue(forKey: pluginID)?.close()
        try? FileManager.default.removeItem(at: directory(for: pluginID))
    }

    private func store(for pluginID: String) throws -> SQLitePluginStorage {
        migrateLegacyStorageIfNeeded(for: pluginID)
        if let existing = stores[pluginID] { return existing }
        let storage = try SQLitePluginStorage(
            databaseURL: directory(for: pluginID).appendingPathComponent("storage.sqlite")
        )
        stores[pluginID] = storage
        return storage
    }

    private func directory(for pluginID: String) -> URL {
        baseDirectory.appendingPathComponent(Self.sanitize(pluginID), isDirectory: true)
    }

    private func migrateLegacyStorageIfNeeded(for currentID: String) {
        let target = directory(for: currentID)
        let fileManager = FileManager.default
        for legacyID in BuiltInPluginID.legacyIDs(for: currentID) {
            let source = directory(for: legacyID)
            guard source != target, fileManager.fileExists(atPath: source.path) else { continue }
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
            } catch {
                print("[DevIsland] [PluginStorage] migration failed \(legacyID) -> \(currentID): \(error)")
            }
        }
    }

    private static func sanitize(_ pluginID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(pluginID.map { allowed.contains($0) ? $0 : "_" })
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "_plugin" }
        return cleaned
    }
}
