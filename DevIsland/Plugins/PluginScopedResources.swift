import AVFoundation
import Foundation
import os

struct PluginScopedFileScope: Equatable, Sendable {
    static let defaultMaxReadBytes: Int64 = 1_000_000
    static let defaultMaxAudioBytes: Int64 = 1_000_000
    static let defaultAudioExtensions: Set<String> = ["mp3", "wav", "ogg"]

    let id: String
    let baseDirectory: URL
    let maxReadBytes: Int64
    let maxAudioBytes: Int64
    let allowedAudioExtensions: Set<String>

    init(
        id: String,
        baseDirectory: URL,
        maxReadBytes: Int64 = Self.defaultMaxReadBytes,
        maxAudioBytes: Int64 = Self.defaultMaxAudioBytes,
        allowedAudioExtensions: Set<String> = Self.defaultAudioExtensions
    ) {
        self.id = id
        self.baseDirectory = baseDirectory
        self.maxReadBytes = maxReadBytes
        self.maxAudioBytes = maxAudioBytes
        self.allowedAudioExtensions = Set(allowedAudioExtensions.map { $0.lowercased() })
    }
}

struct PluginScopedFileInfo: Equatable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let byteCount: Int64?
}

struct PluginScopedFileClient: Sendable {
    private let pluginID: String
    private let permissions: Set<PluginPermission>
    private let broker: PluginScopedFileBroker

    init(
        pluginID: String,
        permissions: Set<PluginPermission>,
        broker: PluginScopedFileBroker
    ) {
        self.pluginID = pluginID
        self.permissions = permissions
        self.broker = broker
    }

    func listDirectory(
        scopeID: String,
        relativePath: String = "",
        maxEntries: Int? = nil
    ) async throws -> [PluginScopedFileInfo] {
        try await broker.listDirectory(
            pluginID: pluginID,
            permissions: permissions,
            scopeID: scopeID,
            relativePath: relativePath,
            maxEntries: maxEntries
        )
    }

    func readText(scopeID: String, relativePath: String) async throws -> String {
        try await broker.readText(
            pluginID: pluginID,
            permissions: permissions,
            scopeID: scopeID,
            relativePath: relativePath
        )
    }

    func metadata(scopeID: String, relativePath: String) async throws -> PluginScopedFileInfo {
        try await broker.metadata(
            pluginID: pluginID,
            permissions: permissions,
            scopeID: scopeID,
            relativePath: relativePath
        )
    }
}

protocol PluginScopedFileScopeProvider {
    static var scopedFilePluginID: String { get }

    static func scopedFileScopes(userDefaults: UserDefaults) -> [PluginScopedFileScope]
    static func scopedFileScopes(settings: AppSettings) -> [PluginScopedFileScope]
}

enum PluginScopedFileError: Error, Equatable {
    case missingPermission
    case unknownScope
    case invalidRelativePath
    case outsideScope
    case notDirectory
    case notRegularFile
    case fileTooLarge(maxBytes: Int64)
    case unsupportedExtension
    case unreadable
    case directoryTooLarge(maxEntries: Int)
}

actor PluginScopedFileBroker {
    private var scopesByPluginID: [String: [String: PluginScopedFileScope]]
    private let fileManager: FileManager

    init(
        scopesByPluginID: [String: [PluginScopedFileScope]] = [:],
        fileManager: FileManager = .default
    ) {
        self.scopesByPluginID = scopesByPluginID.mapValues { scopes in
            Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0) })
        }
        self.fileManager = fileManager
    }

    func setScopes(_ scopes: [PluginScopedFileScope], forPluginID pluginID: String) {
        scopesByPluginID[pluginID] = Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0) })
    }

    func listDirectory(
        pluginID: String,
        permissions: Set<PluginPermission>,
        scopeID: String,
        relativePath: String = "",
        maxEntries: Int? = nil
    ) throws -> [PluginScopedFileInfo] {
        guard permissions.contains(.readScopedFiles) else { throw PluginScopedFileError.missingPermission }
        let scope = try scope(forPluginID: pluginID, scopeID: scopeID)
        let directoryURL = try resolvedURL(in: scope, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginScopedFileError.notDirectory
        }

        if let maxEntries {
            return try cappedDirectoryContents(
                at: directoryURL,
                scope: scope,
                maxEntries: maxEntries
            )
        }

        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return PluginScopedFileInfo(
                relativePath: relativePathFromScope(url, baseDirectory: scope.baseDirectory),
                isDirectory: values.isDirectory == true,
                byteCount: values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
            )
        }
        .sorted { $0.relativePath < $1.relativePath }
    }

    private func cappedDirectoryContents(
        at directoryURL: URL,
        scope: PluginScopedFileScope,
        maxEntries: Int
    ) throws -> [PluginScopedFileInfo] {
        guard maxEntries > 0 else {
            throw PluginScopedFileError.directoryTooLarge(maxEntries: maxEntries)
        }
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw PluginScopedFileError.notDirectory
        }

        var entries: [PluginScopedFileInfo] = []
        for case let url as URL in enumerator {
            guard entries.count < maxEntries else {
                throw PluginScopedFileError.directoryTooLarge(maxEntries: maxEntries)
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            entries.append(PluginScopedFileInfo(
                relativePath: relativePathFromScope(url, baseDirectory: scope.baseDirectory),
                isDirectory: values.isDirectory == true,
                byteCount: values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    func readText(
        pluginID: String,
        permissions: Set<PluginPermission>,
        scopeID: String,
        relativePath: String
    ) throws -> String {
        guard permissions.contains(.readScopedFiles) else { throw PluginScopedFileError.missingPermission }
        let scope = try scope(forPluginID: pluginID, scopeID: scopeID)
        let fileURL = try resolvedRegularFile(in: scope, relativePath: relativePath)
        try enforceFileSize(fileURL, maxBytes: scope.maxReadBytes)
        guard let text = String(data: try Data(contentsOf: fileURL), encoding: .utf8) else {
            throw PluginScopedFileError.unreadable
        }
        return text
    }

    func metadata(
        pluginID: String,
        permissions: Set<PluginPermission>,
        scopeID: String,
        relativePath: String
    ) throws -> PluginScopedFileInfo {
        guard permissions.contains(.readScopedFiles) else { throw PluginScopedFileError.missingPermission }
        let scope = try scope(forPluginID: pluginID, scopeID: scopeID)
        let url = try resolvedURL(in: scope, relativePath: relativePath)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return PluginScopedFileInfo(
            relativePath: relativePathFromScope(url, baseDirectory: scope.baseDirectory),
            isDirectory: values.isDirectory == true,
            byteCount: values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
        )
    }

    func resolvePlayableFile(
        pluginID: String,
        scopeID: String,
        relativePath: String
    ) throws -> URL {
        let scope = try scope(forPluginID: pluginID, scopeID: scopeID)
        let fileURL = try resolvedRegularFile(in: scope, relativePath: relativePath)
        guard scope.allowedAudioExtensions.contains(fileURL.pathExtension.lowercased()) else {
            throw PluginScopedFileError.unsupportedExtension
        }
        try enforceFileSize(fileURL, maxBytes: scope.maxAudioBytes)
        return fileURL
    }

    private func scope(forPluginID pluginID: String, scopeID: String) throws -> PluginScopedFileScope {
        guard let scope = scopesByPluginID[pluginID]?[scopeID] else {
            throw PluginScopedFileError.unknownScope
        }
        return scope
    }

    private func resolvedRegularFile(in scope: PluginScopedFileScope, relativePath: String) throws -> URL {
        let fileURL = try resolvedURL(in: scope, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PluginScopedFileError.notRegularFile
        }
        return fileURL
    }

    private func resolvedURL(in scope: PluginScopedFileScope, relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.contains("\0") {
            throw PluginScopedFileError.invalidRelativePath
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            throw PluginScopedFileError.invalidRelativePath
        }

        let baseURL = scope.baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = trimmed.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(trimmed).resolvingSymlinksInPath().standardizedFileURL
        guard isInsideScope(targetURL, baseURL: baseURL) else {
            throw PluginScopedFileError.outsideScope
        }
        return targetURL
    }

    private func isInsideScope(_ url: URL, baseURL: URL) -> Bool {
        let basePath = baseURL.path
        let path = url.path
        return path == basePath || path.hasPrefix(basePath + "/")
    }

    private func enforceFileSize(_ url: URL, maxBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size <= maxBytes else {
            throw PluginScopedFileError.fileTooLarge(maxBytes: maxBytes)
        }
    }

    private func relativePathFromScope(_ url: URL, baseDirectory: URL) -> String {
        let basePath = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return "" }
        return String(path.dropFirst(basePath.count + 1))
    }
}

@MainActor
final class PluginScopedAudioPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    static let shared = PluginScopedAudioPlayer()

    private var players: [AVAudioPlayer] = []

    func play(url: URL, volume: Float) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = min(max(volume, 0), 1)
            player.delegate = self
            player.prepareToPlay()
            if player.play() {
                players.append(player)
            }
        } catch {
            Log.plugin.error("Plugin audio playback failed for \(url.path, privacy: .private): \(error, privacy: .private)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        players.removeAll { $0 === player }
    }
}
