import XCTest
@testable import DevIsland

final class PluginScopedResourcesTests: XCTestCase {
    func testReadTextRequiresPermissionAndStaysWithinScope() async throws {
        let root = try makeTempDirectory()
        try Data("hello".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            OpenPeonPlugin.pluginID: [PluginScopedFileScope(id: "packs", baseDirectory: root)]
        ])

        await XCTAssertThrowsErrorAsync(
            try await broker.readText(
                pluginID: OpenPeonPlugin.pluginID,
                permissions: [],
                scopeID: "packs",
                relativePath: "manifest.json"
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .missingPermission)
        }

        let text = try await broker.readText(
            pluginID: OpenPeonPlugin.pluginID,
            permissions: [.readScopedFiles],
            scopeID: "packs",
            relativePath: "manifest.json"
        )
        XCTAssertEqual(text, "hello")

        await XCTAssertThrowsErrorAsync(
            try await broker.readText(
                pluginID: OpenPeonPlugin.pluginID,
                permissions: [.readScopedFiles],
                scopeID: "packs",
                relativePath: "../manifest.json"
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .invalidRelativePath)
        }
    }

    func testListDirectoryReturnsScopedRelativePaths() async throws {
        let root = try makeTempDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sounds"),
            withIntermediateDirectories: true
        )
        try Data("a".utf8).write(to: root.appendingPathComponent("sounds/a.wav"))
        try Data("b".utf8).write(to: root.appendingPathComponent("sounds/b.wav"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            OpenPeonPlugin.pluginID: [PluginScopedFileScope(id: "packs", baseDirectory: root)]
        ])

        let files = try await broker.listDirectory(
            pluginID: OpenPeonPlugin.pluginID,
            permissions: [.readScopedFiles],
            scopeID: "packs",
            relativePath: "sounds"
        )

        XCTAssertEqual(files.map(\.relativePath), ["sounds/a.wav", "sounds/b.wav"])
        XCTAssertEqual(files.map(\.byteCount), [1, 1])
    }

    func testListDirectoryCanRejectDirectoriesAboveEntryCap() async throws {
        let root = try makeTempDirectory()
        try Data("a".utf8).write(to: root.appendingPathComponent("a.wav"))
        try Data("b".utf8).write(to: root.appendingPathComponent("b.wav"))
        try Data("c".utf8).write(to: root.appendingPathComponent("c.wav"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            OpenPeonPlugin.pluginID: [PluginScopedFileScope(id: "packs", baseDirectory: root)]
        ])

        await XCTAssertThrowsErrorAsync(
            try await broker.listDirectory(
                pluginID: OpenPeonPlugin.pluginID,
                permissions: [.readScopedFiles],
                scopeID: "packs",
                maxEntries: 2
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .directoryTooLarge(maxEntries: 2))
        }
    }

    func testPlayableFileRejectsUnsupportedExtensionAndOversizeFile() async throws {
        let root = try makeTempDirectory()
        try Data("audio".utf8).write(to: root.appendingPathComponent("done.wav"))
        try Data("text".utf8).write(to: root.appendingPathComponent("done.txt"))
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            OpenPeonPlugin.pluginID: [
                PluginScopedFileScope(
                    id: "packs",
                    baseDirectory: root,
                    maxAudioBytes: 3,
                    allowedAudioExtensions: ["wav"]
                )
            ]
        ])

        await XCTAssertThrowsErrorAsync(
            try await broker.resolvePlayableFile(
                pluginID: OpenPeonPlugin.pluginID,
                scopeID: "packs",
                relativePath: "done.txt"
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .unsupportedExtension)
        }

        await XCTAssertThrowsErrorAsync(
            try await broker.resolvePlayableFile(
                pluginID: OpenPeonPlugin.pluginID,
                scopeID: "packs",
                relativePath: "done.wav"
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .fileTooLarge(maxBytes: 3))
        }
    }

    func testSymlinkCannotEscapeScope() async throws {
        let root = try makeTempDirectory()
        let outside = try makeTempDirectory()
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let broker = PluginScopedFileBroker(scopesByPluginID: [
            OpenPeonPlugin.pluginID: [PluginScopedFileScope(id: "packs", baseDirectory: root)]
        ])

        await XCTAssertThrowsErrorAsync(
            try await broker.readText(
                pluginID: OpenPeonPlugin.pluginID,
                permissions: [.readScopedFiles],
                scopeID: "packs",
                relativePath: "escape/secret.txt"
            )
        ) { error in
            XCTAssertEqual(error as? PluginScopedFileError, .outsideScope)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginScopedResourcesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
