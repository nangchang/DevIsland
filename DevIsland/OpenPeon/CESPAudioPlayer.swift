import AVFoundation
import Foundation

// Keep debounce state, retained players, and delegate cleanup in one actor.
// AVAudioPlayer is also safest when created and played on a run-loop thread.
@MainActor
final class CESPAudioPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    static let shared = CESPAudioPlayer()

    private var lastPlayedAt: [CESPCategory: Date] = [:]
    private var lastSoundPathByCategory: [CESPCategory: String] = [:]
    private var players: [AVAudioPlayer] = []

    func play(category: CESPCategory, bypassChecks: Bool = false) {
        let settings = SettingsStore.shared.settings
        let pack = CESPPackStore.shared.activePack(settings: settings)
        play(category: category, pack: pack, settings: settings, bypassChecks: bypassChecks)
    }

    func play(category: CESPCategory, pack: CESPPack?, settings: AppSettings, now: Date = Date(), bypassChecks: Bool = false) {
        if !bypassChecks {
            guard shouldPlay(category: category, pack: pack, settings: settings, now: now) else {
                return
            }
        }

        guard let pack,
              let categoryManifest = pack.manifest.categories[category.rawValue],
              let sound = selectSound(for: category, sounds: categoryManifest.sounds) else {
            return
        }

        let url = pack.rootURL.appendingPathComponent(sound.file).standardizedFileURL
        guard CESPCategory.supportedExtensions.contains(url.pathExtension.lowercased()) else { return }

        lastPlayedAt[category] = now
        lastSoundPathByCategory[category] = sound.file

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(settings.openPeonMasterVolume)
            player.delegate = self
            player.prepareToPlay()
            if player.play() {
                players.append(player)
            }
        } catch {
            print("[DevIsland] OpenPeon playback failed for \(url.path): \(error)")
        }
    }

    func shouldPlay(category: CESPCategory, pack: CESPPack?, settings: AppSettings, now: Date = Date()) -> Bool {
        guard settings.openPeonEnabled,
              !settings.openPeonGlobalMuted,
              !settings.openPeonMutedCategories.contains(category.rawValue),
              let pack,
              pack.validation.isValid,
              pack.manifest.categories[category.rawValue] != nil else {
            return false
        }
        if let last = lastPlayedAt[category] {
            let interval = now.timeIntervalSince(last) * 1000
            if interval < Double(settings.openPeonDebounceMilliseconds) {
                return false
            }
        }
        return true
    }

    func selectSound(for category: CESPCategory, sounds: [CESPSoundManifest]) -> CESPSoundManifest? {
        let playable = sounds.filter {
            CESPCategory.supportedExtensions.contains(URL(fileURLWithPath: $0.file).pathExtension.lowercased())
        }
        guard !playable.isEmpty else { return nil }
        guard playable.count > 1, let previous = lastSoundPathByCategory[category] else {
            return playable.randomElement()
        }
        return playable.filter { $0.file != previous }.randomElement() ?? playable.randomElement()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        players.removeAll { $0 === player }
    }
}
