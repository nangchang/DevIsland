import Foundation
import Combine

@MainActor
final class CESPPackStore: ObservableObject {
    static let shared = CESPPackStore()

    @Published private(set) var packs: [CESPPack] = []
    @Published private(set) var lastReloadErrorPath: String?
    private var reloadID = UUID()

    func reload(settings: AppSettings) {
        reload(packsDirectory: settings.openPeonPacksDirectory)
    }

    func reload(packsDirectory: String) {
        let id = UUID()
        reloadID = id
        let directory = URL(fileURLWithPath: NSString(string: packsDirectory).expandingTildeInPath, isDirectory: true)

        Task.detached(priority: .utility) {
            let result = Self.scanPacks(in: directory)
            await MainActor.run {
                guard self.reloadID == id else { return }
                switch result {
                case .success(let packs):
                    self.packs = packs
                    self.lastReloadErrorPath = nil
                case .failure:
                    self.packs = []
                    self.lastReloadErrorPath = directory.path
                }
            }
        }
    }

    private nonisolated static func scanPacks(in directory: URL) -> Result<[CESPPack], Error> {
        let fileManager = FileManager.default
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let packs = entries
                .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
                .compactMap { CESPPackValidator.loadPack(at: $0, fileManager: fileManager) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return .success(packs)
        } catch {
            return .failure(error)
        }
    }

    func activePack(settings: AppSettings) -> CESPPack? {
        let validPacks = packs.filter { $0.validation.isValid }
        if let activeName = settings.openPeonActivePackName,
           let pack = validPacks.first(where: { $0.manifest.name == activeName }) {
            return pack
        }
        return validPacks.first
    }

    func hasSounds(for category: CESPCategory, settings: AppSettings) -> Bool {
        guard let pack = activePack(settings: settings),
              let categoryManifest = pack.manifest.categories[category.rawValue] else {
            return false
        }
        return categoryManifest.sounds.contains { sound in
            ["wav", "mp3"].contains(URL(fileURLWithPath: sound.file).pathExtension.lowercased())
        }
    }
}
