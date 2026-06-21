import XCTest
@testable import DevIsland

@MainActor
final class CompactAppearancePluginTests: XCTestCase {
    func testContributesAllConfiguredRegions() async throws {
        var settings = AppSettings.defaults
        settings.notchLeftCharacterMode = .specific
        settings.notchLeftCharacterKind = .codex
        settings.notchCenterText = "DevIsland"
        settings.notchRightCharacterMode = .specific
        settings.notchRightCharacterKind = .gemini
        let plugin = CompactAppearancePlugin(settingsProvider: { settings })

        _ = try await plugin.onEvent(event(.pluginStarted), context: context(pluginID: plugin.manifest.id))

        let leading = try XCTUnwrap(try plugin.makeCompactRegionContribution(
            for: .notchCompactLeading,
            context: regionContext(.notchCompactLeading)
        ))
        let center = try XCTUnwrap(try plugin.makeCompactRegionContribution(
            for: .notchCompactCenter,
            context: regionContext(.notchCompactCenter)
        ))
        let trailing = try XCTUnwrap(try plugin.makeCompactRegionContribution(
            for: .notchCompactTrailing,
            context: regionContext(.notchCompactTrailing)
        ))

        XCTAssertEqual(leading.content, .buddy(kind: BuddyKind.codex.rawValue))
        XCTAssertEqual(center.content, .text("DevIsland"))
        XCTAssertEqual(trailing.content, .buddy(kind: BuddyKind.gemini.rawValue))
    }

    func testReturnsNilForHiddenOrEmptyContent() async throws {
        var settings = AppSettings.defaults
        settings.notchLeftCharacterMode = .hidden
        settings.notchCenterText = ""
        settings.notchRightCharacterMode = .hidden
        let plugin = CompactAppearancePlugin(settingsProvider: { settings })

        _ = try await plugin.onEvent(event(.settingsChanged), context: context(pluginID: plugin.manifest.id))

        for region in PluginRegionID.allCases {
            XCTAssertNil(try plugin.makeCompactRegionContribution(
                for: region,
                context: regionContext(region)
            ))
        }
    }

    func testCompactRegionShownForcesRandomBuddyRefresh() async throws {
        let settings = CompactSettingsBox(AppSettings.defaults)
        settings.value.notchLeftCharacterMode = .specific
        settings.value.notchLeftCharacterKind = .codex
        let plugin = CompactAppearancePlugin(
            settingsProvider: { settings.value },
            randomBuddyProvider: { candidates in
                candidates.contains(.gemini) ? .gemini : candidates.first
            }
        )
        _ = try await plugin.onEvent(event(.pluginStarted), context: context(pluginID: plugin.manifest.id))

        settings.value.notchLeftCharacterMode = .random
        settings.value.notchLeftRandomCharacterKinds = [.codex, .gemini]
        _ = try await plugin.onEvent(
            event(.compactRegionShown),
            context: context(pluginID: plugin.manifest.id)
        )

        let leading = try XCTUnwrap(try plugin.makeCompactRegionContribution(
            for: .notchCompactLeading,
            context: regionContext(.notchCompactLeading)
        ))
        XCTAssertEqual(leading.content, .buddy(kind: BuddyKind.gemini.rawValue))
    }

    private func event(_ kind: PluginEventKind) -> PluginEvent {
        PluginEvent(id: UUID(), kind: kind, timestamp: Date())
    }

    private func context(pluginID: String) -> PluginContext {
        PluginContext(pluginID: pluginID, permissions: [.showCompactRegion], storageSnapshot: [:])
    }

    private func regionContext(_ region: PluginRegionID) -> PluginCompactRegionContext {
        PluginCompactRegionContext(region: region, timestamp: Date(), language: .english)
    }
}

@MainActor
private final class CompactSettingsBox {
    var value: AppSettings

    init(_ value: AppSettings) {
        self.value = value
    }
}
