import Foundation
import Combine

@MainActor
final class CESPPackStore: ObservableObject {
    static let shared = CESPPackStore()

    @Published private(set) var packs: [CESPPack] = []
    @Published private(set) var lastReloadError: String?

    func reload(settings: AppSettings) {
        reload(packsDirectory: settings.openPeonPacksDirectory)
    }

    func reload(packsDirectory: String) {
        let directory = URL(fileURLWithPath: NSString(string: packsDirectory).expandingTildeInPath, isDirectory: true)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            packs = []
            lastReloadError = "Could not read \(directory.path)"
            return
        }

        packs = entries
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .compactMap { CESPPackValidator.loadPack(at: $0, fileManager: fileManager) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        lastReloadError = nil
    }

    func activePack(settings: AppSettings) -> CESPPack? {
        let validPacks = packs.filter { $0.validation.isValid }
        if let activeName = settings.openPeonActivePackName,
           let pack = validPacks.first(where: { $0.manifest.name == activeName }) {
            return pack
        }
        return validPacks.first
    }
}
