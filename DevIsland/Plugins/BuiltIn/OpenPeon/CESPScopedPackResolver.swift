import Foundation

/// A CESP pack discovered through the scoped file broker. `relativeRoot` is the pack
/// directory name relative to the plugin's scope root — the plugin never sees absolute paths.
struct CESPResolvedPack: Equatable {
    let relativeRoot: String
    let manifest: CESPManifest
    let validation: CESPValidationResult

    var displayName: String {
        manifest.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? manifest.name
    }
}

/// Plugin-owned pack discovery over the scoped file broker. Mirrors the host-side
/// `CESPPackStore` scan/active-pack semantics but reads only through `PluginScopedFileClient`
/// relative-path requests, so the plugin owns CESP parsing/validation without touching
/// absolute paths or `FileManager`.
enum CESPScopedPackResolver {
    /// Resolves the active, valid pack the same way `CESPPackStore.activePack` does:
    /// among valid packs (sorted by display name), pick the one whose manifest name matches
    /// `activePackName`, otherwise the first valid pack. Returns `nil` when no valid pack exists.
    static func resolveActivePack(
        scoped: PluginScopedFileClient,
        scopeID: String,
        activePackName: String?
    ) async -> CESPResolvedPack? {
        let rootEntries = (try? await scoped.listDirectory(scopeID: scopeID)) ?? []
        var packs: [CESPResolvedPack] = []

        for entry in rootEntries where entry.isDirectory {
            guard let manifest = await loadManifest(scoped: scoped, scopeID: scopeID, packRoot: entry.relativePath) else {
                continue
            }
            let index = await makeFileIndex(scoped: scoped, scopeID: scopeID, packRoot: entry.relativePath)
            packs.append(
                CESPResolvedPack(
                    relativeRoot: entry.relativePath,
                    manifest: manifest,
                    validation: CESPPackValidator.validate(manifest: manifest, fileIndex: index)
                )
            )
        }

        let validPacks = packs
            .filter { $0.validation.isValid }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if let name = activePackName,
           let match = validPacks.first(where: { $0.manifest.name == name }) {
            return match
        }
        return validPacks.first
    }

    private static func loadManifest(
        scoped: PluginScopedFileClient,
        scopeID: String,
        packRoot: String
    ) async -> CESPManifest? {
        guard let text = try? await scoped.readText(
            scopeID: scopeID,
            relativePath: packRoot + "/openpeon.json"
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(CESPManifest.self, from: Data(text.utf8))
    }

    /// Recursively lists `packRoot` through the broker, recording each regular file's size
    /// keyed by its pack-root-relative path. Broker `relativePath` values are scope-root
    /// relative, so the leading `packRoot/` prefix is stripped to match validator expectations.
    private static func makeFileIndex(
        scoped: PluginScopedFileClient,
        scopeID: String,
        packRoot: String
    ) async -> CESPPackFileIndex {
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        let prefix = packRoot + "/"
        var pending = [packRoot]

        while let directory = pending.popLast() {
            let entries = (try? await scoped.listDirectory(scopeID: scopeID, relativePath: directory)) ?? []
            for entry in entries {
                if entry.isDirectory {
                    pending.append(entry.relativePath)
                } else {
                    let size = entry.byteCount ?? 0
                    total += size
                    if entry.relativePath.hasPrefix(prefix) {
                        sizes[String(entry.relativePath.dropFirst(prefix.count))] = size
                    }
                    if total > CESPPackValidator.maxPackSize {
                        pending.removeAll()
                        break
                    }
                }
            }
        }

        return CESPPackFileIndex(fileSizesByRelativePath: sizes, totalByteCount: total)
    }
}
