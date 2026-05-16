import XCTest
@testable import DevIsland

@MainActor
final class OpenPeonAudioSelectionTests: XCTestCase {
    func testMutedCategorySuppressesPlayback() {
        var settings = AppSettings.defaults
        settings.openPeonEnabled = true
        settings.openPeonMutedCategories = [CESPCategory.inputRequired.rawValue]

        XCTAssertFalse(CESPAudioPlayer.shared.shouldPlay(
            category: .inputRequired,
            pack: makePack(),
            settings: settings
        ))
    }

    func testDisabledOpenPeonSuppressesPlayback() {
        var settings = AppSettings.defaults
        settings.openPeonEnabled = false
        settings.openPeonMutedCategories = []

        XCTAssertFalse(CESPAudioPlayer.shared.shouldPlay(
            category: .taskComplete,
            pack: makePack(),
            settings: settings
        ))
    }

    func testSelectSoundSkipsUnsupportedOggForMVPPlayback() {
        let sound = CESPAudioPlayer.shared.selectSound(
            for: .taskComplete,
            sounds: [CESPSoundManifest(file: "sounds/done.ogg", label: nil)]
        )

        XCTAssertNil(sound)
    }

    private func makePack() -> CESPPack {
        let manifest = CESPManifest(
            cespVersion: "1.0",
            name: "sample-pack",
            displayName: nil,
            version: "1.0.0",
            categories: [
                CESPCategory.taskComplete.rawValue: CESPCategoryManifest(
                    sounds: [CESPSoundManifest(file: "sounds/done.wav", label: nil)]
                ),
                CESPCategory.inputRequired.rawValue: CESPCategoryManifest(
                    sounds: [CESPSoundManifest(file: "sounds/input.wav", label: nil)]
                )
            ]
        )
        return CESPPack(
            rootURL: URL(fileURLWithPath: "/tmp/sample-pack", isDirectory: true),
            manifest: manifest,
            validation: CESPValidationResult()
        )
    }
}
