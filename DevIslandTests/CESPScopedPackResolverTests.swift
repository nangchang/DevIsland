import XCTest
@testable import DevIsland

final class CESPScopedPackResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CESPScopedPackResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testResolvesValidPack() async throws {
        try writePack(dir: "sample", name: "sample", soundPath: "sounds/done.wav")

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: "sample"
        )

        XCTAssertEqual(pack?.relativeRoot, "sample")
        XCTAssertEqual(pack?.manifest.name, "sample")
        XCTAssertTrue(pack?.validation.isValid == true)
    }

    func testInvalidVersionPackIsNotResolved() async throws {
        try writePack(dir: "sample", name: "sample", soundPath: "sounds/done.wav", cespVersion: "2.0")

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: "sample"
        )

        XCTAssertNil(pack)
    }

    func testMissingSoundPackIsNotResolved() async throws {
        try writePack(dir: "sample", name: "sample", soundPath: "sounds/missing.wav", createSound: false)

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: "sample"
        )

        XCTAssertNil(pack)
    }

    func testPathTraversalSoundIsNotResolved() async throws {
        try writePack(dir: "sample", name: "sample", soundPath: "../escape.wav", createSound: false)

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: "sample"
        )

        XCTAssertNil(pack)
    }

    func testActiveNameSelectsMatchingPack() async throws {
        try writePack(dir: "a", name: "alpha", soundPath: "sounds/done.wav")
        try writePack(dir: "b", name: "beta", soundPath: "sounds/done.wav")

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: "beta"
        )

        XCTAssertEqual(pack?.manifest.name, "beta")
    }

    func testFallsBackToFirstValidPackByDisplayName() async throws {
        try writePack(dir: "a", name: "alpha", soundPath: "sounds/done.wav")
        try writePack(dir: "b", name: "beta", soundPath: "sounds/done.wav")

        let pack = await CESPScopedPackResolver.resolveActivePack(
            scoped: client(), scopeID: scopeID, activePackName: nil
        )

        XCTAssertEqual(pack?.manifest.name, "alpha")
    }

    // MARK: - Helpers

    private let scopeID = "packs"
    private let pluginID = "openpeon"

    private func client() -> PluginScopedFileClient {
        let scope = PluginScopedFileScope(id: scopeID, baseDirectory: root)
        let broker = PluginScopedFileBroker(scopesByPluginID: [pluginID: [scope]])
        return PluginScopedFileClient(pluginID: pluginID, permissions: [.readScopedFiles], broker: broker)
    }

    private func writePack(
        dir: String,
        name: String,
        soundPath: String,
        cespVersion: String = "1.0",
        createSound: Bool = true
    ) throws {
        let packURL = root.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: packURL, withIntermediateDirectories: true)
        if createSound {
            let soundURL = packURL.appendingPathComponent(soundPath)
            try FileManager.default.createDirectory(
                at: soundURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data([0, 1, 2, 3]).write(to: soundURL)
        }
        let manifest = """
        {
          "cesp_version": "\(cespVersion)",
          "name": "\(name)",
          "version": "1.0.0",
          "categories": {
            "task.complete": {
              "sounds": [
                { "file": "\(soundPath)" }
              ]
            }
          }
        }
        """
        try Data(manifest.utf8).write(to: packURL.appendingPathComponent("openpeon.json"))
    }
}
