import Foundation

/// Runtime decision state for `OpenPeonPlugin`. Owns debounce timing and last-played sound
/// tracking and turns a CESP category into an `audio.playFile` effect.
///
/// `@MainActor`-isolated so the mutable debounce/selection state stays serialized even though
/// `PluginRunner` (an actor) may re-enter `onEvent` at suspension points. The actual file I/O
/// runs on the broker actor via `await`, so the main thread is never blocked on disk.
@MainActor
final class OpenPeonRuntime {
    private var lastPlayedAt: [CESPCategory: Date] = [:]
    private var lastSoundPathByCategory: [CESPCategory: String] = [:]

    nonisolated init() {}

    /// Returns an `audio.playFile` effect for `category`, or `[]` when nothing should play.
    /// Cheap gates (enabled, mute, debounce) run before any file access so the broker scan
    /// frequency is bounded by the debounce interval.
    func resolveEffects(
        category: CESPCategory,
        scoped: PluginScopedFileClient,
        scopeID: String,
        settings: AppSettings,
        now: Date = Date()
    ) async -> [PluginEffect] {
        guard settings.openPeonEnabled,
              !settings.openPeonGlobalMuted,
              !settings.openPeonMutedCategories.contains(category.rawValue) else {
            return []
        }
        if let last = lastPlayedAt[category] {
            let interval = now.timeIntervalSince(last) * 1000
            if interval < Double(settings.openPeonDebounceMilliseconds) {
                return []
            }
        }

        guard let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: scoped,
            scopeID: scopeID,
            activePackName: settings.openPeonActivePackName
        ),
            let categoryManifest = pack.manifest.categories[category.rawValue],
            let sound = selectSound(for: category, sounds: categoryManifest.sounds) else {
            return []
        }

        lastPlayedAt[category] = now
        lastSoundPathByCategory[category] = sound.file

        return [
            PluginEffect(
                capability: "audio.playFile",
                payload: [
                    "scope": scopeID,
                    "path": pack.relativeRoot + "/" + sound.file,
                    "volume": String(settings.openPeonMasterVolume)
                ]
            )
        ]
    }

    /// Picks a playable sound for the category, avoiding an immediate repeat when the category
    /// has more than one playable sound. Mirrors `CESPAudioPlayer.selectSound`.
    private func selectSound(for category: CESPCategory, sounds: [CESPSoundManifest]) -> CESPSoundManifest? {
        let playable = sounds.filter {
            CESPCategory.supportedExtensions.contains(URL(fileURLWithPath: $0.file).pathExtension.lowercased())
        }
        guard !playable.isEmpty else { return nil }
        guard playable.count > 1, let previous = lastSoundPathByCategory[category] else {
            return playable.randomElement()
        }
        return playable.filter { $0.file != previous }.randomElement() ?? playable.randomElement()
    }
}
